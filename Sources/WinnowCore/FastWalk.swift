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

    static func isPackage(_ path: String) -> Bool {
        (try? URL(fileURLWithPath: path).resourceValues(forKeys: [.isPackageKey]))?.isPackage == true
    }

    /// Calls `visit` for every folder under `roots`, up to `width` at once, so it must be thread-safe.
    /// `visit` returns what to collect and which subfolders to go into.
    public static func walk<T>(_ roots: [String], width: Int = 8,
                               visit: @escaping @Sendable (_ dir: String, _ entries: [Entry]) -> (found: [T], descend: [String])) -> [T] {
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

                    let (found, descend) = entries(dir).map { visit(dir, $0) } ?? ([], [])

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
