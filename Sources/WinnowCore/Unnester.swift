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
        var found: [Item] = []
        for root in roots {
            let rootURL = URL(fileURLWithPath: root)
            guard let e = FileManager.default.enumerator(at: rootURL, includingPropertiesForKeys: [.isDirectoryKey, .isPackageKey, .isSymbolicLinkKey],
                                                         options: [.skipsHiddenFiles, .skipsPackageDescendants]) else { continue }
            for case let url as URL in e where isPlainFolder(url) {
                let path = url.path
                guard let entries = visible(path), entries.count == 1 else { continue }
                let child = url.appendingPathComponent(entries[0])
                if isPlainFolder(child) {
                    found.append(Item(outer: path, inner: child.path))
                    e.skipDescendants()
                }
            }
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
