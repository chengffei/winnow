import Darwin
import Foundation

/// Walks folder trees with getattrlistbulk, several folders at a time.
/// One call returns a whole folder's names and types, so a network drive is not asked about each file;
/// on an SMB NAS with 40,000 files this took 13 s against 51 s for FileManager's enumerator.
public enum FastWalk {
    public struct Entry: Sendable {
        public let name: String
        public let isFolder: Bool
    }

    /// Folders that hold NAS housekeeping, never the user's files.
    public static let skippedFolders: Set<String> = ["@eaDir", "#recycle", "#snapshot", "@Recycle", "@Recently-Snapshot"]

    /// Visible entries of one folder: hidden names are dropped, and packages such as .app count as files.
    public static func entries(_ dir: String) -> [Entry]? {
        let fd = open(dir, O_RDONLY | O_DIRECTORY)
        guard fd >= 0 else { return nil }
        defer { close(fd) }
        var list = attrlist()
        list.bitmapcount = u_short(ATTR_BIT_MAP_COUNT)
        list.commonattr = attrgroup_t(UInt32(bitPattern: Int32(bitPattern: UInt32(ATTR_CMN_RETURNED_ATTRS)) | ATTR_CMN_NAME | ATTR_CMN_OBJTYPE))
        let size = 128 * 1024
        let buf = UnsafeMutableRawPointer.allocate(byteCount: size, alignment: 8)
        defer { buf.deallocate() }
        var out: [Entry] = []
        while true {
            let n = getattrlistbulk(fd, &list, buf, size, 0)
            if n < 0 { return out.isEmpty ? nil : out }
            if n == 0 { break }
            var p = buf
            for _ in 0..<n {
                let length = Int(p.loadUnaligned(as: UInt32.self))
                let fields = p + 4 + MemoryLayout<attribute_set_t>.size
                let offset = Int(fields.loadUnaligned(as: Int32.self))
                let name = String(cString: (fields + offset).assumingMemoryBound(to: CChar.self))
                let type = (fields + 8).loadUnaligned(as: UInt32.self)
                p += length
                guard !name.hasPrefix(".") else { continue }
                var folder = type == VDIR.rawValue
                if folder, name.contains("."), isPackage(dir + "/" + name) { folder = false }
                out.append(Entry(name: name, isFolder: folder))
            }
        }
        return out
    }

    public struct Detail: Sendable {
        public let name: String
        public let isFolder: Bool
        /// Bytes in the file; 0 for a folder.
        public let size: UInt64
        /// Modification time in whole seconds.
        public let modified: Int64
    }

    /// Like `entries`, with each file's size and modification time from the same call,
    /// so nothing more is asked of a network drive.
    public static func details(_ dir: String) -> [Detail]? {
        let fd = open(dir, O_RDONLY | O_DIRECTORY)
        guard fd >= 0 else { return nil }
        defer { close(fd) }
        var list = attrlist()
        list.bitmapcount = u_short(ATTR_BIT_MAP_COUNT)
        list.commonattr = attrgroup_t(UInt32(bitPattern: Int32(bitPattern: UInt32(ATTR_CMN_RETURNED_ATTRS)) | ATTR_CMN_NAME | ATTR_CMN_OBJTYPE | ATTR_CMN_MODTIME))
        list.fileattr = attrgroup_t(ATTR_FILE_DATALENGTH)
        let size = 256 * 1024
        let buf = UnsafeMutableRawPointer.allocate(byteCount: size, alignment: 8)
        defer { buf.deallocate() }
        var out: [Detail] = []
        while true {
            let n = getattrlistbulk(fd, &list, buf, size, 0)
            if n < 0 { return out.isEmpty ? nil : out }
            if n == 0 { break }
            var p = buf
            for _ in 0..<n {
                let length = Int(p.loadUnaligned(as: UInt32.self))
                defer { p += length }
                // What came back is listed first; each attribute that did follows in a fixed order.
                let common = (p + 4).loadUnaligned(as: UInt32.self)
                let file = (p + 4 + 12).loadUnaligned(as: UInt32.self)
                var at = p + 4 + MemoryLayout<attribute_set_t>.size
                var name = ""
                if common & UInt32(ATTR_CMN_NAME) != 0 {
                    let offset = Int(at.loadUnaligned(as: Int32.self))
                    name = String(cString: (at + offset).assumingMemoryBound(to: CChar.self))
                    at += 8
                }
                var type: UInt32 = 0
                if common & UInt32(ATTR_CMN_OBJTYPE) != 0 {
                    type = at.loadUnaligned(as: UInt32.self)
                    at += 4
                }
                var modified: Int64 = 0
                if common & UInt32(ATTR_CMN_MODTIME) != 0 {
                    modified = Int64(at.loadUnaligned(as: Int.self))
                    at += 16
                }
                var bytes: UInt64 = 0
                if file & UInt32(ATTR_FILE_DATALENGTH) != 0 {
                    bytes = UInt64(max(at.loadUnaligned(as: Int64.self), 0))
                }
                guard !name.isEmpty, !name.hasPrefix(".") else { continue }
                var folder = type == VDIR.rawValue
                if folder, name.contains("."), isPackage(dir + "/" + name) { folder = false }
                out.append(Detail(name: name, isFolder: folder, size: folder ? 0 : bytes, modified: modified))
            }
        }
        return out
    }

    static func isPackage(_ path: String) -> Bool {
        (try? URL(fileURLWithPath: path).resourceValues(forKeys: [.isPackageKey]))?.isPackage == true
    }

    /// Calls `visit` for every folder under `roots`, up to `width` at once, so it must be thread-safe.
    /// `visit` returns what to collect and which subfolders to go into.
    public static func walk<T>(_ roots: [String], width: Int = 8,
                               visit: @escaping @Sendable (_ dir: String, _ entries: [Entry]) -> (found: [T], descend: [String])) -> [T] {
        walk(roots, width: width, list: entries, visit: visit)
    }

    /// The same walk over any listing of a folder. `unreadable` is told about folders that could not be listed.
    public static func walk<E, T>(_ roots: [String], width: Int = 8, list: @escaping @Sendable (String) -> [E]?,
                                  unreadable: (@Sendable (String) -> Void)? = nil,
                                  visit: @escaping @Sendable (_ dir: String, _ entries: [E]) -> (found: [T], descend: [String])) -> [T] {
        let cond = NSCondition()
        var queue = roots.map { $0.count > 1 && $0.hasSuffix("/") ? String($0.dropLast()) : $0 }
        var busy = 0
        var results: [T] = []
        let group = DispatchGroup()
        for _ in 0..<max(width, 1) {
            group.enter()
            Thread.detachNewThread {
                while true {
                    cond.lock()
                    while queue.isEmpty && busy > 0 { cond.wait() }
                    guard let dir = queue.popLast() else {
                        cond.broadcast()
                        cond.unlock()
                        break
                    }
                    busy += 1
                    cond.unlock()

                    let listed = list(dir)
                    if listed == nil { unreadable?(dir) }
                    let (found, descend) = listed.map { visit(dir, $0) } ?? ([], [])

                    cond.lock()
                    results += found
                    queue += descend.filter { !skippedFolders.contains(($0 as NSString).lastPathComponent) }
                    busy -= 1
                    cond.broadcast()
                    cond.unlock()
                }
                group.leave()
            }
        }
        group.wait()
        return results
    }
}
