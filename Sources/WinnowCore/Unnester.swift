import Foundation

/// Finds folders that hold nothing but one folder, and moves that inner folder somewhere else.
public enum Unnester {
    public struct Item: Identifiable, Equatable, Sendable {
        public var id: String { outer }
        /// The folder that only wraps another one.
        public let outer: String
        /// The single folder inside it.
        public let inner: String
        public var include = true

        public var innerName: String { (inner as NSString).lastPathComponent }

        public init(outer: String, inner: String) {
            self.outer = outer
            self.inner = inner
        }
    }

    public struct Batch: Codable, Equatable, Sendable {
        public var moves: [Renamer.Move] = []
        /// Emptied outer folders sent to the Trash: where they were, and where they are in the Trash.
        public var trashed: [Renamer.Move] = []
        public var failures: [String] = []

        public var isEmpty: Bool { moves.isEmpty && trashed.isEmpty }

        public init() {}
    }

    /// Visible entries of a folder; hidden files such as .DS_Store do not count.
    static func visible(_ path: String) -> [String]? {
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: path) else { return nil }
        return names.filter { !$0.hasPrefix(".") }
    }

    static func isPlainFolder(_ url: URL) -> Bool {
        let v = try? url.resourceValues(forKeys: [.isDirectoryKey, .isPackageKey, .isSymbolicLinkKey])
        return v?.isDirectory == true && v?.isPackage != true && v?.isSymbolicLink != true
    }

    /// Folders under `roots` (the roots themselves excluded) whose only visible entry is a folder.
    /// In a chain A/B/C only A is listed: moving B out brings C along.
    public static func plan(roots: [String]) -> [Item] {
        let rootSet = Set(roots)
        let found = FastWalk.walk(roots) { dir, entries -> (found: [Item], descend: [String]) in
            if !rootSet.contains(dir), entries.count == 1, entries[0].isFolder {
                return ([Item(outer: dir, inner: dir + "/" + entries[0].name)], [])
            }
            return ([], entries.filter(\.isFolder).map { dir + "/" + $0.name })
        }
        return found.sorted { $0.outer.localizedStandardCompare($1.outer) == .orderedAscending }
    }

    /// Moves each included inner folder into `destination`, then trashes the outer folder if it is left empty.
    /// Items that changed since the preview, or whose name is taken in the destination, are skipped.
    public static func apply(_ items: [Item], to destination: String, trashEmptied: Bool) -> Batch {
        var batch = Batch()
        let fm = FileManager.default
        for item in items where item.include {
            let target = (destination as NSString).appendingPathComponent(item.innerName)
            guard visible(item.outer) == [item.innerName],
                  !Paths.contains(item.inner, destination),
                  !fm.fileExists(atPath: target) else {
                batch.failures.append(item.inner); continue
            }
            do {
                try fm.moveItem(atPath: item.inner, toPath: target)
                batch.moves.append(Renamer.Move(from: item.inner, to: target))
            } catch {
                batch.failures.append(item.inner); continue
            }
            if trashEmptied, visible(item.outer)?.isEmpty == true {
                var result: NSURL?
                if (try? fm.trashItem(at: URL(fileURLWithPath: item.outer), resultingItemURL: &result)) != nil, let result {
                    batch.trashed.append(Renamer.Move(from: item.outer, to: (result as URL).path))
                }
            }
        }
        return batch
    }

    /// Takes outer folders back out of the Trash, then moves the inner folders home.
    public static func undo(_ batch: Batch) -> Renamer.Outcome {
        var outcome = Renamer.Outcome()
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
