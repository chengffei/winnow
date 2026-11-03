import Foundation

public enum ProcessAction: String, CaseIterable {
    case stage, trash, delete
}

public struct PlanItem: Hashable {
    public var path: String
    public var size: UInt64
    /// Expected modification time; nil for folders.
    public var modified: Int64?
    public var groupID: Int?

    public var isFolder: Bool { groupID == nil }
}

public struct SafetyReport {
    /// Every group still has a kept copy in the marks.
    public var everyGroupKeepsOne = true
    public var noReferenceMarked = true
    /// Marked items that changed or vanished since the scan; they are skipped.
    public var changed: [String] = []
    /// Groups whose kept copies are gone or changed; nothing in them is touched.
    public var unsafeGroups: [Int] = []
    /// Items that pass every check.
    public var items: [PlanItem] = []

    public var blocking: Bool { !everyGroupKeepsOne || !noReferenceMarked }

    public init() {}
}

public struct ProcessOutcome {
    public var done: [PlanItem] = []
    public var moves: [Move] = []
    public var failures: [(path: String, reason: String)] = []
    public var stagingRoots: [String] = []
}

public enum Processor {
    public static let stagingPrefix = "_Winnow-Staging-"
    /// Folder names used before 0.2, still recognised so old staging folders are skipped and restorable.
    public static let legacyStagingPrefixes = ["_待清理_"]
    public static var allStagingPrefixes: [String] { [stagingPrefix] + legacyStagingPrefixes }

    public static func plan(_ record: ScanRecord) -> [PlanItem] {
        var items: [PlanItem] = []
        for g in record.groups {
            for f in g.files where f.mark == .delete {
                items.append(PlanItem(path: f.path, size: f.size, modified: f.modified, groupID: g.id))
            }
        }
        for folder in record.emptyFolders where folder.mark == .delete {
            items.append(PlanItem(path: folder.path, size: 0, modified: nil, groupID: nil))
        }
        return items
    }

    /// Looks at the disk again. Slow on network volumes; call off the main thread.
    public static func check(_ record: ScanRecord) -> SafetyReport {
        var report = SafetyReport()
        for g in record.groups {
            let marked = g.files.filter { $0.mark == .delete }
            guard !marked.isEmpty else { continue }
            if marked.contains(where: { $0.isReference || record.config.isReference($0.path) }) {
                report.noReferenceMarked = false
            }
            let kept = g.files.filter { $0.mark == .keep }
            if kept.isEmpty { report.everyGroupKeepsOne = false; continue }
            // At least one kept copy must still be there, unchanged.
            guard kept.contains(where: { unchanged($0.path, size: $0.size, modified: $0.modified) }) else {
                report.unsafeGroups.append(g.id)
                continue
            }
            for f in marked where !f.isReference {
                if unchanged(f.path, size: f.size, modified: f.modified) {
                    report.items.append(PlanItem(path: f.path, size: f.size, modified: f.modified, groupID: g.id))
                } else {
                    report.changed.append(f.path)
                }
            }
        }
        for folder in record.emptyFolders where folder.mark == .delete {
            if record.config.isReference(folder.path) { report.noReferenceMarked = false; continue }
            if isStillEmpty(folder.path) {
                report.items.append(PlanItem(path: folder.path, size: 0, modified: nil, groupID: nil))
            } else {
                report.changed.append(folder.path)
            }
        }
        return report
    }

    static func unchanged(_ path: String, size: UInt64, modified: Int64) -> Bool {
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: path),
              attrs[.type] as? FileAttributeType == .typeRegular,
              let s = (attrs[.size] as? NSNumber)?.uint64Value,
              let m = attrs[.modificationDate] as? Date else { return false }
        return s == size && Int64(m.timeIntervalSince1970) == modified
    }

    /// Empty means no files below it other than Finder's .DS_Store.
    static func isStillEmpty(_ path: String) -> Bool {
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: path, isDirectory: &isDir), isDir.boolValue,
              let walker = FileManager.default.enumerator(atPath: path) else { return false }
        for case let rel as String in walker {
            if (rel as NSString).lastPathComponent == ".DS_Store" { continue }
            var sub: ObjCBool = false
            FileManager.default.fileExists(atPath: path + "/" + rel, isDirectory: &sub)
            if !sub.boolValue { return false }
        }
        return true
    }

    public static func isLocal(_ path: String) -> Bool {
        let values = try? URL(fileURLWithPath: path).resourceValues(forKeys: [.volumeIsLocalKey])
        return values?.volumeIsLocal ?? true
    }

    /// Where a staged item goes: a dated folder at the top of its own volume, so the move is a rename.
    /// Items on the startup disk go under the home folder instead, since / is not writable.
    public static func stagingTarget(for path: String, date: Date, home: String = NSHomeDirectory()) -> (root: String, target: String) {
        let folder = stagingPrefix + dayString(date)
        let volume = (try? URL(fileURLWithPath: path).resourceValues(forKeys: [.volumeURLKey]))?.volume?.path ?? "/"
        let base: String
        let rel: String
        if volume != "/" && Paths.contains(volume, path) {
            base = volume
            rel = String(path.dropFirst(volume.count))
        } else if Paths.contains(home, path) {
            base = home
            rel = String(path.dropFirst(home.count))
        } else {
            base = home
            rel = path
        }
        let root = (base as NSString).appendingPathComponent(folder)
        return (root, root + (rel.hasPrefix("/") ? rel : "/" + rel))
    }

    static func dayString(_ date: Date) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd"
        return f.string(from: date)
    }

    public static func execute(_ action: ProcessAction, items: [PlanItem], date: Date = Date(),
                               home: String = NSHomeDirectory(), progress: ((Int) -> Void)? = nil) -> ProcessOutcome {
        let fm = FileManager.default
        var outcome = ProcessOutcome()
        var roots = Set<String>()
        for (n, item) in items.enumerated() {
            do {
                switch action {
                case .stage:
                    let (root, target) = stagingTarget(for: item.path, date: date, home: home)
                    let dest = freeName(target)
                    try fm.createDirectory(atPath: (dest as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
                    try fm.moveItem(atPath: item.path, toPath: dest)
                    outcome.moves.append(Move(from: item.path, to: dest))
                    roots.insert(root)
                case .trash:
                    try fm.trashItem(at: URL(fileURLWithPath: item.path), resultingItemURL: nil)
                case .delete:
                    try fm.removeItem(atPath: item.path)
                }
                outcome.done.append(item)
            } catch {
                outcome.failures.append((item.path, error.localizedDescription))
            }
            progress?(n + 1)
        }
        outcome.stagingRoots = roots.sorted()
        return outcome
    }

    /// Puts staged items back, newest move first. Returns the moves that could not be undone.
    public static func restore(_ moves: [Move]) -> (restored: [Move], failures: [(path: String, reason: String)]) {
        let fm = FileManager.default
        var restored: [Move] = []
        var failures: [(String, String)] = []
        for m in moves.reversed() {
            if fm.fileExists(atPath: m.from) {
                failures.append((m.from, L("Something with the same name is already there")))
                continue
            }
            do {
                try fm.createDirectory(atPath: (m.from as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
                try fm.moveItem(atPath: m.to, toPath: m.from)
                restored.append(m)
            } catch {
                failures.append((m.to, error.localizedDescription))
            }
        }
        return (restored, failures)
    }

    /// Drops processed items from the record; groups left with one copy are no longer duplicates.
    public static func applyOutcome(_ outcome: ProcessOutcome, to record: inout ScanRecord) {
        let done = Set(outcome.done.map(\.path))
        for g in record.groups.indices {
            record.groups[g].files.removeAll { done.contains($0.path) }
        }
        record.groups.removeAll { $0.files.count < 2 || !$0.files.contains(where: { !$0.isReference }) }
        record.emptyFolders.removeAll { done.contains($0.path) }
        record.moves += outcome.moves
    }

    static func freeName(_ path: String) -> String {
        let fm = FileManager.default
        guard fm.fileExists(atPath: path) else { return path }
        let ns = path as NSString
        let ext = ns.pathExtension
        let stem = (ns.lastPathComponent as NSString).deletingPathExtension
        let dir = ns.deletingLastPathComponent
        var n = 2
        while true {
            let name = ext.isEmpty ? "\(stem) \(n)" : "\(stem) \(n).\(ext)"
            let candidate = (dir as NSString).appendingPathComponent(name)
            if !fm.fileExists(atPath: candidate) { return candidate }
            n += 1
        }
    }
}
