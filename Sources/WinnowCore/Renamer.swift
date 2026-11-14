import Foundation

/// Removes a piece of text from file names: plan a preview, rename what the user keeps, undo the last batch.
public enum Renamer {
    public enum Problem: String, Codable, Equatable, Sendable {
        /// Another file already has the new name, or two files would end up with the same name.
        case nameTaken
        /// Nothing (or only an extension) would be left.
        case emptyName
    }

    public struct Item: Identifiable, Equatable, Sendable {
        public var id: String { path }
        public let path: String
        public let newName: String
        public var problem: Problem?
        public var include: Bool

        public var folder: String { (path as NSString).deletingLastPathComponent }
        public var oldName: String { (path as NSString).lastPathComponent }
        public var newPath: String { (folder as NSString).appendingPathComponent(newName) }

        public init(path: String, newName: String, problem: Problem? = nil) {
            self.path = path
            self.newName = newName
            self.problem = problem
            self.include = problem == nil
        }
    }

    public struct Move: Codable, Equatable, Sendable {
        public let from: String
        public let to: String
    }

    public struct Outcome: Equatable, Sendable {
        public var done: [Move] = []
        public var failures: [String] = []
    }

    /// The name with every `text` taken out, trimmed of spaces left at either end of the base name.
    public static func strip(_ name: String, removing text: String) -> String {
        strip(name, removing: [text])
    }

    /// Longer texts go first, so "【书香网】" is taken out whole before "书香网" could split it.
    public static func strip(_ name: String, removing texts: [String]) -> String {
        let texts = texts.filter { !$0.isEmpty }.sorted { $0.count > $1.count }
        guard !texts.isEmpty else { return name }
        let removed = texts.reduce(name) { $0.replacingOccurrences(of: $1, with: "") }
        let ext = (removed as NSString).pathExtension
        let base = ext.isEmpty ? removed : String(removed.dropLast(ext.count + 1))
        let trimmed = base.trimmingCharacters(in: .whitespaces)
        return ext.isEmpty ? trimmed : trimmed + "." + ext
    }

    public static func plan(roots: [String], text: String, subfolders: Bool = true) -> [Item] {
        plan(roots: roots, texts: [text], subfolders: subfolders)
    }

    /// Files under `roots` whose names contain any of `texts`, with all of them taken out.
    /// Hidden files, package contents and NAS housekeeping folders are skipped.
    public static func plan(roots: [String], texts: [String], subfolders: Bool = true) -> [Item] {
        let texts = texts.filter { !$0.isEmpty }
        guard !texts.isEmpty else { return [] }
        let fm = FileManager.default
        var paths = FastWalk.walk(roots) { dir, entries -> (found: [String], descend: [String]) in
            (entries.filter { entry in !entry.isFolder && texts.contains { entry.name.contains($0) } }.map { dir + "/" + $0.name },
             subfolders ? entries.filter(\.isFolder).map { dir + "/" + $0.name } : [])
        }
        paths = Array(Set(paths)).sorted()

        var items = paths.map { path -> Item in
            let name = strip((path as NSString).lastPathComponent, removing: texts)
            let base = (name as NSString).deletingPathExtension
            return Item(path: path, newName: name, problem: base.isEmpty || name.hasPrefix(".") ? .emptyName : nil)
        }
        // Two renames landing on one name, or a name another file already has: leave them all out.
        var targets: [String: [Int]] = [:]
        for (i, item) in items.enumerated() where item.problem == nil {
            targets[item.newPath.lowercased(), default: []].append(i)
        }
        let renamed = Set(paths.map { $0.lowercased() })
        for (target, indices) in targets {
            let takenOnDisk = fm.fileExists(atPath: items[indices[0]].newPath) && !renamed.contains(target)
            if indices.count > 1 || takenOnDisk {
                for i in indices { items[i].problem = .nameTaken; items[i].include = false }
            }
        }
        return items
    }

    /// Renames the included items. Each one is checked again first; a file that is gone or a name now taken is skipped.
    public static func apply(_ items: [Item]) -> Outcome {
        var outcome = Outcome()
        let fm = FileManager.default
        for item in items where item.include && item.problem == nil {
            guard fm.fileExists(atPath: item.path) else {
                outcome.failures.append(item.path); continue
            }
            let caseOnly = item.path.lowercased() == item.newPath.lowercased()
            guard caseOnly || !fm.fileExists(atPath: item.newPath) else {
                outcome.failures.append(item.path); continue
            }
            do {
                try fm.moveItem(atPath: item.path, toPath: item.newPath)
                outcome.done.append(Move(from: item.path, to: item.newPath))
            } catch {
                outcome.failures.append(item.path)
            }
        }
        return outcome
    }

    /// Puts the old names back, newest first. Skips a file that moved on or whose old name is taken again.
    public static func undo(_ moves: [Move]) -> Outcome {
        var outcome = Outcome()
        let fm = FileManager.default
        for move in moves.reversed() {
            guard fm.fileExists(atPath: move.to), !fm.fileExists(atPath: move.from) else {
                outcome.failures.append(move.to); continue
            }
            do {
                try fm.moveItem(atPath: move.to, toPath: move.from)
                outcome.done.append(Move(from: move.to, to: move.from))
            } catch {
                outcome.failures.append(move.to)
            }
        }
        return outcome
    }

    // MARK: Last batch, kept on disk so Undo survives a restart

    public static var logFile: URL {
        Store.directory.deletingLastPathComponent().appendingPathComponent("last-rename.json")
    }

    public static func saveLast(_ moves: [Move]) {
        let url = logFile
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        if moves.isEmpty { try? FileManager.default.removeItem(at: url); return }
        if let data = try? JSONEncoder().encode(moves) { try? data.write(to: url, options: .atomic) }
    }

    public static func loadLast() -> [Move] {
        guard let data = try? Data(contentsOf: logFile) else { return [] }
        return (try? JSONDecoder().decode([Move].self, from: data)) ?? []
    }
}
