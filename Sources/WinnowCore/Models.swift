import Foundation

public struct Location: Codable, Hashable, Identifiable {
    public var path: String
    /// Files here are only compared against, never marked for removal.
    public var isReference: Bool
    public var id: String { path }

    public init(path: String, isReference: Bool = false) {
        self.path = path
        self.isReference = isReference
    }
}

public enum Tool: String, Codable, CaseIterable, Hashable {
    case duplicates, emptyFolders
}

public enum CompareMethod: String, Codable, CaseIterable, Hashable {
    case hash, sizeName

    var cliValue: String { self == .hash ? "HASH" : "SIZE_NAME" }
}

public enum FileKind: String, Codable, CaseIterable, Hashable {
    case photos, videos, music, documents, archives

    public var extensions: [String] {
        switch self {
        case .photos:
            return ["jpg", "jpeg", "png", "heic", "heif", "gif", "webp", "tif", "tiff", "bmp", "avif",
                    "dng", "cr2", "cr3", "nef", "arw", "raf", "orf", "rw2"]
        case .videos:
            return ["mp4", "mov", "m4v", "mkv", "avi", "wmv", "flv", "webm", "mpg", "mpeg", "3gp", "mts", "m2ts", "ts"]
        case .music:
            return ["mp3", "flac", "m4a", "aac", "wav", "aif", "aiff", "ogg", "opus", "wma", "ape"]
        case .documents:
            return ["pdf", "doc", "docx", "xls", "xlsx", "ppt", "pptx", "pages", "numbers", "key",
                    "txt", "md", "rtf", "odt", "csv", "epub"]
        case .archives:
            return ["zip", "rar", "7z", "tar", "gz", "tgz", "bz2", "xz", "dmg", "iso", "pkg"]
        }
    }
}

public struct ScanConfig: Codable, Hashable {
    public var locations: [Location]
    public var tools: Set<Tool>
    public var method: CompareMethod
    /// Duplicates smaller than this are not looked at.
    public var minSize: UInt64
    /// Empty means every kind of file.
    public var kinds: Set<FileKind>
    /// Folders inside the locations that are skipped entirely.
    public var excluded: [String]

    public static let defaultMinSize: UInt64 = 8 * 1024

    public init(locations: [Location] = [], tools: Set<Tool> = [.duplicates, .emptyFolders], method: CompareMethod = .hash,
                minSize: UInt64 = ScanConfig.defaultMinSize, kinds: Set<FileKind> = [], excluded: [String] = []) {
        self.locations = locations
        self.tools = tools
        self.method = method
        self.minSize = minSize
        self.kinds = kinds
        self.excluded = excluded
    }

    // Scans saved before these fields existed still load.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        locations = try c.decode([Location].self, forKey: .locations)
        tools = try c.decode(Set<Tool>.self, forKey: .tools)
        method = try c.decode(CompareMethod.self, forKey: .method)
        minSize = try c.decodeIfPresent(UInt64.self, forKey: .minSize) ?? Self.defaultMinSize
        kinds = try c.decodeIfPresent(Set<FileKind>.self, forKey: .kinds) ?? []
        excluded = try c.decodeIfPresent([String].self, forKey: .excluded) ?? []
    }

    /// Excluded folders that lie inside `location`.
    public func excluded(in location: String) -> [String] {
        excluded.filter { Paths.contains(location, $0) && $0 != location }
    }

    public func isReference(_ path: String) -> Bool {
        locations.contains { $0.isReference && Paths.contains($0.path, path) }
    }

    public var title: String {
        joinedList(locations.map { Paths.displayName($0.path) })
    }
}

public enum Mark: String, Codable, Hashable {
    case keep, delete
}

public struct FileEntry: Codable, Hashable, Identifiable {
    public var path: String
    public var size: UInt64
    /// Modification time in whole seconds, as reported by the scanner.
    public var modified: Int64
    public var mark: Mark
    public var isReference: Bool
    public var id: String { path }
    public var name: String { (path as NSString).lastPathComponent }

    public init(path: String, size: UInt64, modified: Int64, mark: Mark = .keep, isReference: Bool = false) {
        self.path = path
        self.size = size
        self.modified = modified
        self.mark = mark
        self.isReference = isReference
    }
}

public struct DupGroup: Codable, Hashable, Identifiable {
    public var id: Int
    public var size: UInt64
    public var files: [FileEntry]
    /// Set once the user changes a mark by hand; auto rules then leave the group alone.
    public var edited: Bool

    public init(id: Int, size: UInt64, files: [FileEntry], edited: Bool = false) {
        self.id = id
        self.size = size
        self.files = files
        self.edited = edited
    }

    public var name: String { files.first(where: { !$0.isReference })?.name ?? files.first?.name ?? "" }
    public var deleteCount: Int { files.reduce(0) { $0 + ($1.mark == .delete ? 1 : 0) } }
    public var reclaimable: UInt64 { UInt64(deleteCount) * size }
    /// The most this group could free, used for a stable sort order.
    public var potential: UInt64 { UInt64(max(files.count - 1, 0)) * size }
}

public struct EmptyFolder: Codable, Hashable, Identifiable {
    public var path: String
    public var mark: Mark
    public var id: String { path }

    public init(path: String, mark: Mark = .delete) {
        self.path = path
        self.mark = mark
    }
}

public struct SkippedItem: Codable, Hashable {
    public var path: String
    public var reason: String

    public init(path: String, reason: String) {
        self.path = path
        self.reason = reason
    }
}

public struct Move: Codable, Hashable {
    public var from: String
    public var to: String

    public init(from: String, to: String) {
        self.from = from
        self.to = to
    }
}

public enum AutoRule: Codable, Hashable {
    case oldest, newest, shortestPath, preferFolder(String)
}

public struct ScanRecord: Codable, Identifiable {
    public var id: UUID
    public var date: Date
    public var config: ScanConfig
    public var groups: [DupGroup]
    public var emptyFolders: [EmptyFolder]
    public var skipped: [SkippedItem]
    public var rule: AutoRule
    /// Items moved to a staging folder, kept so they can be put back.
    public var moves: [Move]

    public init(id: UUID = UUID(), date: Date = Date(), config: ScanConfig, groups: [DupGroup] = [],
                emptyFolders: [EmptyFolder] = [], skipped: [SkippedItem] = [], rule: AutoRule = .oldest, moves: [Move] = []) {
        self.id = id
        self.date = date
        self.config = config
        self.groups = groups
        self.emptyFolders = emptyFolders
        self.skipped = skipped
        self.rule = rule
        self.moves = moves
    }

    public var markedFiles: Int { groups.reduce(0) { $0 + $1.deleteCount } }
    public var markedFolders: Int { emptyFolders.reduce(0) { $0 + ($1.mark == .delete ? 1 : 0) } }
    public var reclaimable: UInt64 { groups.reduce(0) { $0 + $1.reclaimable } }
    public var potential: UInt64 { groups.reduce(0) { $0 + $1.potential } }
}

public enum Paths {
    /// True when `path` is `root` or lies inside it.
    public static func contains(_ root: String, _ path: String) -> Bool {
        let r = root.hasSuffix("/") ? String(root.dropLast()) : root
        return path == r || path.hasPrefix(r + "/") || r.isEmpty
    }

    public static func displayName(_ path: String) -> String {
        path == "/" ? "/" : (path as NSString).lastPathComponent
    }

    /// Splits a path into a short head (volume name, ~ or first folder) and the folders below it.
    public static func crumbs(_ path: String) -> (head: String, rest: [String]) {
        let home = NSHomeDirectory()
        var parts = path.split(separator: "/").map(String.init)
        if parts.count >= 2, parts[0] == "Volumes" {
            let head = parts[1]
            parts.removeFirst(2)
            return (head, parts)
        }
        if contains(home, path) {
            let rel = String(path.dropFirst(home.count)).split(separator: "/").map(String.init)
            return ("~", rel)
        }
        guard !parts.isEmpty else { return ("/", []) }
        let head = parts.removeFirst()
        return (head, parts)
    }
}
