import Foundation

/// Finds folders that only wrap one folder or a few files, and moves what is inside out.
public enum Unnester {
    public struct Item: Identifiable, Equatable, Sendable {
        public var id: String { outer }
        /// The folder that only wraps something.
        public let outer: String
        /// What it holds: one folder, or one or more files.
        public let inners: [String]
        public let holdsFolder: Bool
        public var include = true

        public var inner: String { inners[0] }
        public var innerName: String { (inner as NSString).lastPathComponent }

        public init(outer: String, inner: String) {
            self.outer = outer
            self.inners = [inner]
            self.holdsFolder = true
        }

        public init(outer: String, files: [String]) {
            self.outer = outer
            self.inners = files
            self.holdsFolder = false
        }
    }

    public enum Reason: String, Codable, Sendable {
        /// The folder no longer holds what the preview showed.
        case changed
        /// A name is already used where the items would go.
        case nameTaken
        /// The drive would not move something, for instance a file that is open.
        case refused
    }

    /// Tests turn this off to act like a drive without a Trash, as most network drives are.
    nonisolated(unsafe) static var usesTrash = true

    public struct Batch: Codable, Equatable, Sendable {
        public var moves: [Renamer.Move] = []
        /// Emptied outer folders: where they were, and where they are in the Trash, or "" when deleted for want of one.
        public var trashed: [Renamer.Move] = []
        public var failures: [String] = []
        /// Why each of `failures` was skipped, in the same order. Absent in older records.
        public var reasons: [Reason]?
        /// Every move on disk in the order it happened; Undo replays it backwards. Absent in older records.
        public var log: [Renamer.Move]?

        public var isEmpty: Bool { moves.isEmpty && trashed.isEmpty }

        public init() {}
    }

    /// Visible entries of a folder; hidden files such as .DS_Store do not count.
    static func visible(_ path: String) -> [String]? {
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: path) else { return nil }
        return names.filter { !$0.hasPrefix(".") }
    }

    /// Folders under `roots` (the roots themselves excluded) whose only visible entry is a folder,
    /// or that hold nothing but files, `maxFiles` at most.
    /// In a chain A/B/C only A is listed: moving B out brings C along.
    public static func plan(roots: [String], maxFiles: Int = 0) -> [Item] {
        let rootSet = Set(roots)
        let found = FastWalk.walk(roots) { dir, entries -> (found: [Item], descend: [String]) in
            if !rootSet.contains(dir) {
                if entries.count == 1, entries[0].isFolder {
                    return ([Item(outer: dir, inner: dir + "/" + entries[0].name)], [])
                }
                if !entries.isEmpty, entries.count <= maxFiles, !entries.contains(where: \.isFolder) {
                    let names = entries.map(\.name).sorted { $0.localizedStandardCompare($1) == .orderedAscending }
                    return ([Item(outer: dir, files: names.map { dir + "/" + $0 })], [])
                }
            }
            return ([], entries.filter(\.isFolder).map { dir + "/" + $0.name })
        }
        return found.sorted { $0.outer.localizedStandardCompare($1.outer) == .orderedAscending }
    }

    /// The names the moved items end up with. With `rename` they take the outer folder's name and keep
    /// their own extension; several files are numbered: "Name 1.mkv", "Name 2.srt".
    public static func names(for item: Item, rename: Bool) -> [String] {
        let old = item.inners.map { ($0 as NSString).lastPathComponent }
        guard rename else { return old }
        let base = (item.outer as NSString).lastPathComponent
        return old.enumerated().map { i, name in
            base + (old.count > 1 ? " \(i + 1)" : "") + (item.holdsFolder ? "" : fileExtension(name))
        }
    }

    /// ".mkv", ".tar.gz", or nothing.
    static func fileExtension(_ name: String) -> String {
        let ext = (name as NSString).pathExtension
        guard !ext.isEmpty, !ext.contains(" "), ext.count < name.count - 1 else { return "" }
        let stem = (name as NSString).deletingPathExtension
        return (stem.lowercased().hasSuffix(".tar") && stem.count > 4 ? ".tar" : "") + "." + ext
    }

    /// Moves what each included folder holds into `destination`, or next to that folder when it is nil,
    /// then gets rid of the folder if it is left empty: to the Trash, or deleted on a drive that has none.
    /// Folders that changed since the preview, or whose names are taken in the destination, are skipped whole.
    public static func apply(_ items: [Item], to destination: String? = nil, trashEmptied: Bool, rename: Bool = false) -> Batch {
        var batch = Batch()
        var log: [Renamer.Move] = []
        var reasons: [Reason] = []
        let fm = FileManager.default
        for item in items where item.include {
            func skip(_ reason: Reason) {
                batch.failures.append(item.inner)
                reasons.append(reason)
            }
            let dest = destination ?? (item.outer as NSString).deletingLastPathComponent
            let targets = names(for: item, rename: rename).map { (dest as NSString).appendingPathComponent($0) }
            // A lone item may take the outer folder's own name and place, once that folder is gone.
            let swap = targets.count == 1 && targets[0].compare(item.outer, options: .caseInsensitive) == .orderedSame
            guard let now = visible(item.outer),
                  now.sorted() == item.inners.map({ ($0 as NSString).lastPathComponent }).sorted() else {
                skip(.changed); continue
            }
            guard !item.inners.contains(where: { Paths.contains($0, dest) }),
                  Set(targets.map { $0.lowercased() }).count == targets.count,
                  swap ? trashEmptied : !targets.contains(where: { fm.fileExists(atPath: $0) }) else {
                skip(.nameTaken); continue
            }
            var steps: [Renamer.Move] = []
            var gone: String?
            // A network drive can refuse a move for a moment while something still has the file open.
            func step(_ from: String, _ to: String) -> Bool {
                if (try? fm.moveItem(atPath: from, toPath: to)) == nil {
                    usleep(400_000)
                    guard (try? fm.moveItem(atPath: from, toPath: to)) != nil else { return false }
                }
                steps.append(Renamer.Move(from: from, to: to))
                return true
            }
            func removeOuter() -> Bool {
                var result: NSURL?
                if usesTrash, (try? fm.trashItem(at: URL(fileURLWithPath: item.outer), resultingItemURL: &result)) != nil, let result {
                    gone = (result as URL).path
                    steps.append(Renamer.Move(from: item.outer, to: (result as URL).path))
                    return true
                }
                // No Trash here. A folder holding nothing but Finder's own leftovers is deleted; Undo makes it again.
                guard let left = try? fm.contentsOfDirectory(atPath: item.outer),
                      left.allSatisfy({ $0 == ".DS_Store" || $0.hasPrefix("._") }) else { return false }
                for name in left { try? fm.removeItem(atPath: item.outer + "/" + name) }
                guard rmdir(item.outer) == 0 else { return false }
                gone = ""
                steps.append(Renamer.Move(from: item.outer, to: ""))
                return true
            }
            var ok = true
            if swap {
                let hold = item.outer + ".winnow-" + UUID().uuidString.prefix(8)
                ok = step(item.inner, hold) && removeOuter() && step(hold, targets[0])
            } else {
                for (from, to) in zip(item.inners, targets) where ok { ok = step(from, to) }
                if ok, trashEmptied, visible(item.outer)?.isEmpty == true { _ = removeOuter() }
            }
            guard ok else {
                _ = revert(steps)
                skip(.refused); continue
            }
            batch.moves += zip(item.inners, targets).map { Renamer.Move(from: $0, to: $1) }
            if let gone { batch.trashed.append(Renamer.Move(from: item.outer, to: gone)) }
            log += steps
        }
        batch.log = log
        batch.reasons = reasons
        return batch
    }

    /// Takes steps back, last first. A step with nowhere to come back from is a deleted empty folder, made again.
    static func revert(_ steps: [Renamer.Move]) -> [String] {
        var failures: [String] = []
        for step in steps.reversed() {
            if step.to.isEmpty {
                if (try? FileManager.default.createDirectory(atPath: step.from, withIntermediateDirectories: false)) == nil {
                    failures.append(step.from)
                }
            } else {
                failures += Renamer.undo([step]).failures
            }
        }
        return failures
    }

    /// Replays the batch backwards: outer folders come back and their contents go home.
    public static func undo(_ batch: Batch) -> Renamer.Outcome {
        var outcome = Renamer.Outcome()
        if let log = batch.log {
            outcome.failures = revert(log)
            outcome.done = batch.moves
                .filter { FileManager.default.fileExists(atPath: $0.from) }
                .map { Renamer.Move(from: $0.to, to: $0.from) }
            return outcome
        }
        for t in batch.trashed.reversed() {
            let back = Renamer.undo([t])
            outcome.failures += back.failures
        }
        let back = Renamer.undo(batch.moves)
        outcome.done = back.done
        outcome.failures += back.failures
        return outcome
    }

    // MARK: Last batch on disk

    public static var logFile: URL {
        Store.directory.deletingLastPathComponent().appendingPathComponent("last-unnest.json")
    }

    public static func saveLast(_ batch: Batch) {
        let url = logFile
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        if batch.isEmpty { try? FileManager.default.removeItem(at: url); return }
        if let data = try? JSONEncoder().encode(batch) { try? data.write(to: url, options: .atomic) }
    }

    public static func loadLast() -> Batch {
        guard let data = try? Data(contentsOf: logFile) else { return Batch() }
        return (try? JSONDecoder().decode(Batch.self, from: data)) ?? Batch()
    }
}
