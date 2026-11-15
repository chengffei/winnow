import Foundation

/// Lists the files under some folders once, filters that list by name and type as the user types,
/// and moves the chosen files into one folder.
public enum FileSearch {
    public struct File: Identifiable, Equatable, Sendable {
        public var id: String { path }
        public let path: String
        public let name: String
        public let folder: String
        /// Lowercased, without the dot; empty when the name has none.
        public let ext: String
        /// The name folded for matching: case, accents and full-width forms do not matter.
        let key: String
        public var include = false

        public init(path: String) {
            self.path = path
            name = (path as NSString).lastPathComponent
            folder = (path as NSString).deletingLastPathComponent
            ext = (name as NSString).pathExtension.lowercased()
            key = FileSearch.fold(name)
        }
    }

    public struct Query: Equatable, Sendable {
        /// Every word must be in the name.
        public var words: [String] = []
        /// Empty means any type; otherwise the file's extension must be one of these.
        public var extensions: Set<String> = []

        public var isEmpty: Bool { words.isEmpty && extensions.isEmpty }

        /// Words are separated by spaces. A word such as ".mkv" or "*.mkv" asks for that extension;
        /// extensions and `kinds` add up, so ".srt" with Videos ticked finds videos and subtitles.
        public init(text: String = "", kinds: Set<FileKind> = []) {
            for word in text.split(whereSeparator: \.isWhitespace).map(String.init) {
                let bare = word.hasPrefix("*.") ? String(word.dropFirst(2)) : word.hasPrefix(".") ? String(word.dropFirst()) : nil
                if let bare, !bare.isEmpty, !bare.contains(".") {
                    extensions.insert(bare.lowercased())
                } else {
                    words.append(FileSearch.fold(word))
                }
            }
            for kind in kinds { extensions.formUnion(kind.extensions) }
        }

        public func matches(_ file: File) -> Bool {
            (extensions.isEmpty || extensions.contains(file.ext)) && words.allSatisfy { file.key.contains($0) }
        }
    }

    static func fold(_ s: String) -> String {
        s.folding(options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive], locale: nil)
    }

    /// Every visible file under `roots`. Hidden files, package contents and NAS housekeeping folders are left out.
    public static func index(roots: [String], subfolders: Bool = true) -> [File] {
        let paths = FastWalk.walk(roots) { dir, entries -> (found: [String], descend: [String]) in
            (entries.filter { !$0.isFolder }.map { dir + "/" + $0.name },
             subfolders ? entries.filter { $0.isFolder && !FastWalk.skippedFolders.contains($0.name) }.map { dir + "/" + $0.name } : [])
        }
        return Array(Set(paths)).map(File.init)
    }

    public static func filter(_ files: [File], _ query: Query) -> [File] {
        query.isEmpty ? [] : files.filter(query.matches)
    }

    /// Moves files into `destination`. A name already there gets a number, as Finder's Keep Both does:
    /// "a.mkv" becomes "a 2.mkv". Files already in the destination are left alone and not reported.
    public static func move(_ paths: [String], to destination: String) -> Renamer.Outcome {
        var outcome = Renamer.Outcome()
        let fm = FileManager.default
        for path in paths {
            let name = (path as NSString).lastPathComponent
            guard (path as NSString).deletingLastPathComponent != destination else { continue }
            guard fm.fileExists(atPath: path) else { outcome.failures.append(path); continue }
            let ext = (name as NSString).pathExtension
            let stem = ext.isEmpty ? name : (name as NSString).deletingPathExtension
            var target = (destination as NSString).appendingPathComponent(name)
            var n = 2
            while fm.fileExists(atPath: target) {
                target = (destination as NSString).appendingPathComponent(ext.isEmpty ? "\(stem) \(n)" : "\(stem) \(n).\(ext)")
                n += 1
            }
            do {
                try fm.moveItem(atPath: path, toPath: target)
                outcome.done.append(Renamer.Move(from: path, to: target))
            } catch {
                outcome.failures.append(path)
            }
        }
        return outcome
    }

    /// Moves files to a dated staging folder at the top of their drive, keeping their folder structure,
    /// the way removed duplicates are staged. Nothing is deleted.
    public static func setAside(_ paths: [String], date: Date = Date(), home: String = NSHomeDirectory()) -> Renamer.Outcome {
        var outcome = Renamer.Outcome()
        let fm = FileManager.default
        for path in paths {
            guard fm.fileExists(atPath: path) else { outcome.failures.append(path); continue }
            let target = Processor.freeName(Processor.stagingTarget(for: path, date: date, home: home).target)
            do {
                try fm.createDirectory(atPath: (target as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
                try fm.moveItem(atPath: path, toPath: target)
                outcome.done.append(Renamer.Move(from: path, to: target))
            } catch {
                outcome.failures.append(path)
            }
        }
        return outcome
    }

    // MARK: Last batch on disk

    public static var logFile: URL {
        Store.directory.deletingLastPathComponent().appendingPathComponent("last-search-move.json")
    }

    public static func saveLast(_ moves: [Renamer.Move]) {
        let url = logFile
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        if moves.isEmpty { try? FileManager.default.removeItem(at: url); return }
        if let data = try? JSONEncoder().encode(moves) { try? data.write(to: url, options: .atomic) }
    }

    public static func loadLast() -> [Renamer.Move] {
        guard let data = try? Data(contentsOf: logFile) else { return [] }
        return (try? JSONDecoder().decode([Renamer.Move].self, from: data)) ?? []
    }
}
