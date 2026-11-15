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
        /// Files much smaller than the largest one and not named after it: links, notes, promo pictures.
        public let extras: Set<String>
        /// Files that go with a main file, such as its subtitles: each one's path and its main file's path.
        public let companions: [String: String]
        public var include = true

        public var inner: String { inners[0] }
        public var innerName: String { (inner as NSString).lastPathComponent }

        public init(outer: String, inner: String) {
            self.outer = outer
            self.inners = [inner]
            self.holdsFolder = true
            self.extras = []
            self.companions = [:]
        }

        /// `sizes` go with `files`; without them every file counts as a main file.
        public init(outer: String, files: [String], sizes: [UInt64]? = nil) {
            self.outer = outer
            self.inners = files
            self.holdsFolder = false
            let roles = sizes.map { Unnester.classify(zip(files, $0).map { ($0, $1) }) }
            self.extras = roles?.extras ?? []
            self.companions = roles?.companions ?? [:]
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
        /// Small extras moved to a staging folder: where they were and where they are. Absent in older records.
        public var aside: [Renamer.Move]?
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
        let found = FastWalk.walk(roots, list: FastWalk.details) { dir, entries -> (found: [Item], descend: [String]) in
            if !rootSet.contains(dir) {
                if entries.count == 1, entries[0].isFolder {
                    return ([Item(outer: dir, inner: dir + "/" + entries[0].name)], [])
                }
                if !entries.isEmpty, entries.count <= maxFiles, !entries.contains(where: \.isFolder) {
                    let files = entries.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
                    return ([Item(outer: dir, files: files.map { dir + "/" + $0.name }, sizes: files.map(\.size))], [])
                }
            }
            return ([], entries.filter(\.isFolder).map { dir + "/" + $0.name })
        }
        return found.sorted { $0.outer.localizedStandardCompare($1.outer) == .orderedAscending }
    }

    /// Sorts a folder's files into main files, their companions and small extras.
    /// A main file is at least a tenth the size of the largest. A smaller file named like a main file
    /// up to a dot ("Movie.chs.srt" beside "Movie.mkv") is its companion. The rest are extras.
    static func classify(_ files: [(path: String, size: UInt64)]) -> (extras: Set<String>, companions: [String: String]) {
        guard files.count > 1, let largest = files.map(\.size).max(), largest > 0 else { return ([], [:]) }
        func name(_ path: String) -> String { (path as NSString).lastPathComponent }
        let mains = files.filter { $0.size >= largest / 10 }
        let stems = mains.compactMap { main -> (stem: String, path: String)? in
            let stem = (name(main.path) as NSString).deletingPathExtension
            return stem.isEmpty || stem == name(main.path) ? nil : (stem.lowercased() + ".", main.path)
        }.sorted { $0.stem.count > $1.stem.count }
        var extras = Set<String>()
        var companions: [String: String] = [:]
        for file in files where file.size < largest / 10 {
            if let main = stems.first(where: { name(file.path).lowercased().hasPrefix($0.stem) }) {
                companions[file.path] = main.path
            } else {
                extras.insert(file.path)
            }
        }
        return (extras, companions)
    }

    /// What moves out of the folder and under which name. With `setAside` the small extras are left out.
    /// With `rename` the items take the outer folder's name and keep their own extension; several main
    /// files are numbered ("Name 1.mkv", "Name 2.mkv") and a companion follows its main file ("Name 1.chs.srt").
    public static func moves(for item: Item, rename: Bool, setAside: Bool = false) -> [(from: String, name: String)] {
        let moved = setAside ? item.inners.filter { !item.extras.contains($0) } : item.inners
        func own(_ path: String) -> String { (path as NSString).lastPathComponent }
        guard rename else { return moved.map { ($0, own($0)) } }
        let base = (item.outer as NSString).lastPathComponent
        if item.holdsFolder { return moved.map { ($0, base) } }
        // Main files are numbered first, then any extras that come along.
        let numbered = moved.filter { item.companions[$0] == nil && !item.extras.contains($0) } + moved.filter(item.extras.contains)
        var label: [String: String] = [:]
        for (i, path) in numbered.enumerated() { label[path] = numbered.count > 1 ? "\(base) \(i + 1)" : base }
        return moved.map { path in
            if let main = item.companions[path], let mainLabel = label[main] {
                let stem = (own(main) as NSString).deletingPathExtension
                return (path, mainLabel + String(own(path).dropFirst(stem.count)))
            }
            return (path, (label[path] ?? base) + fileExtension(own(path)))
        }
    }

    /// The names the moved items end up with.
    public static func names(for item: Item, rename: Bool, setAside: Bool = false) -> [String] {
        moves(for: item, rename: rename, setAside: setAside).map(\.name)
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
    /// With `setAside` each folder's small extras go to a dated staging folder at the top of their drive.
    public static func apply(_ items: [Item], to destination: String? = nil, trashEmptied: Bool, rename: Bool = false,
                             setAside: Bool = false, date: Date = Date(), home: String = NSHomeDirectory()) -> Batch {
        var batch = Batch()
        var aside: [Renamer.Move] = []
        var log: [Renamer.Move] = []
        var reasons: [Reason] = []
        let fm = FileManager.default
        for item in items where item.include {
            func skip(_ reason: Reason) {
                batch.failures.append(item.inner)
                reasons.append(reason)
            }
            let dest = destination ?? (item.outer as NSString).deletingLastPathComponent
            let moved = moves(for: item, rename: rename, setAside: setAside)
            let targets = moved.map { (dest as NSString).appendingPathComponent($0.name) }
            let extras = setAside ? item.inners.filter(item.extras.contains) : []
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
            let hold = item.outer + ".winnow-" + UUID().uuidString.prefix(8)
            if swap {
                ok = step(moved[0].from, hold)
            } else {
                for (from, to) in zip(moved.map(\.from), targets) where ok { ok = step(from, to) }
            }
            var staged: [Renamer.Move] = []
            for path in extras where ok {
                let target = Processor.freeName(Processor.stagingTarget(for: path, date: date, home: home).target)
                try? fm.createDirectory(atPath: (target as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
                ok = step(path, target)
                if ok { staged.append(Renamer.Move(from: path, to: target)) }
            }
            if swap {
                ok = ok && removeOuter() && step(hold, targets[0])
            } else if ok, trashEmptied, visible(item.outer)?.isEmpty == true {
                _ = removeOuter()
            }
            guard ok else {
                _ = revert(steps)
                skip(.refused); continue
            }
            batch.moves += zip(moved.map(\.from), targets).map { Renamer.Move(from: $0, to: $1) }
            aside += staged
            if let gone { batch.trashed.append(Renamer.Move(from: item.outer, to: gone)) }
            log += steps
        }
        batch.log = log
        batch.aside = aside
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
