import Foundation

/// Locations and settings the user chose to keep, for any of the three tools.
/// Nothing is added on its own: only what is saved by hand ends up here.
public struct Favorite: Codable, Identifiable, Equatable {
    public enum Kind: String, Codable, Sendable { case scan, rename, nested, search }

    public var id = UUID()
    public var name: String
    public var kind: Kind
    /// New Scan: the whole configuration.
    public var scan: ScanConfig?
    /// Remove Text from Names and Nested Folders: where to look.
    public var folders: [String] = []
    public var texts: [String] = []
    public var subfolders = true
    public var maxFiles = 1
    public var takeFolderName = false
    public var trashEmptied = true
    public var destination: String?
    /// Find Files: the types ticked. What was typed is in `texts`.
    public var kinds: [FileKind] = []

    public init(name: String = "", kind: Kind) {
        self.name = name
        self.kind = kind
    }

    // Favorites saved before a field existed still load.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        name = try c.decode(String.self, forKey: .name)
        kind = try c.decode(Kind.self, forKey: .kind)
        scan = try c.decodeIfPresent(ScanConfig.self, forKey: .scan)
        folders = try c.decodeIfPresent([String].self, forKey: .folders) ?? []
        texts = try c.decodeIfPresent([String].self, forKey: .texts) ?? []
        subfolders = try c.decodeIfPresent(Bool.self, forKey: .subfolders) ?? true
        maxFiles = try c.decodeIfPresent(Int.self, forKey: .maxFiles) ?? 1
        takeFolderName = try c.decodeIfPresent(Bool.self, forKey: .takeFolderName) ?? false
        trashEmptied = try c.decodeIfPresent(Bool.self, forKey: .trashEmptied) ?? true
        destination = try c.decodeIfPresent(String.self, forKey: .destination)
        kinds = try c.decodeIfPresent([FileKind].self, forKey: .kinds) ?? []
    }
}

public enum Favorites {
    public static var file: URL {
        Store.directory.deletingLastPathComponent().appendingPathComponent("favorites.json")
    }

    public static func load() -> [Favorite] {
        guard let data = try? Data(contentsOf: file) else { return [] }
        return (try? JSONDecoder().decode([Favorite].self, from: data)) ?? []
    }

    public static func save(_ favorites: [Favorite]) {
        let url = file
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        if let data = try? JSONEncoder().encode(favorites) { try? data.write(to: url, options: .atomic) }
    }
}
