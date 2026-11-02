import Foundation

/// Reads the pretty JSON files written by czkawka_cli (`-p`).
public enum ResultParser {
    /// Hash mode writes `{"<size>": [[entry, ...], ...]}`; size-name mode writes `[[entry, ...], ...]`.
    /// Reference mode nests `[ref, [entries]]`; both shapes are flattened.
    public static func duplicates(_ data: Data, config: ScanConfig) throws -> [DupGroup] {
        let root = try JSONSerialization.jsonObject(with: data)
        var rawGroups: [Any] = []
        if let dict = root as? [String: Any] {
            for value in dict.values { rawGroups += (value as? [Any]) ?? [] }
        } else if let list = root as? [Any] {
            rawGroups = list
        }

        var seen = Set<String>()
        var groups: [DupGroup] = []
        for raw in rawGroups {
            var files: [FileEntry] = []
            for entry in flatten(raw) {
                guard let path = entry["path"] as? String, seen.insert(path).inserted else { continue }
                files.append(FileEntry(path: path,
                                       size: (entry["size"] as? NSNumber)?.uint64Value ?? 0,
                                       modified: (entry["modified_date"] as? NSNumber)?.int64Value ?? 0,
                                       isReference: config.isReference(path)))
            }
            // A group only matters if it has a copy that may be removed.
            guard files.count > 1, files.contains(where: { !$0.isReference }) else { continue }
            files.sort { $0.path < $1.path }
            groups.append(DupGroup(id: groups.count, size: files[0].size, files: files))
        }
        return groups
    }

    public static func emptyFolders(_ data: Data, config: ScanConfig) throws -> [EmptyFolder] {
        let root = try JSONSerialization.jsonObject(with: data)
        let list = (root as? [Any]) ?? []
        var result: [EmptyFolder] = []
        var seen = Set<String>()
        for item in list {
            let path = (item as? String) ?? ((item as? [String: Any])?["path"] as? String)
            guard let path, !config.isReference(path), seen.insert(path).inserted else { continue }
            result.append(EmptyFolder(path: path))
        }
        return result.sorted { $0.path < $1.path }
    }

    private static func flatten(_ value: Any) -> [[String: Any]] {
        if let dict = value as? [String: Any] { return [dict] }
        if let list = value as? [Any] { return list.flatMap(flatten) }
        return []
    }
}
