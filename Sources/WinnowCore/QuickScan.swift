import Foundation

/// Finds duplicates by size and name without the scanning engine.
/// The engine asks a drive about each file in turn; on an SMB NAS with 40,000 files that took 206 s.
/// Size and time come with the bulk folder listing, so this takes a small fraction of that.
/// Comparing by content still goes through the engine.
public enum QuickScan {
    /// True when `path` matches one of the engine-style wildcard patterns, where * also crosses folders.
    static func excluded(_ path: String, isFolder: Bool, patterns: [String]) -> Bool {
        let subject = isFolder ? path + "/" : path
        return patterns.contains { fnmatch($0, subject, 0) == 0 }
    }

    private final class Tally: @unchecked Sendable {
        let lock = NSLock()
        var count = 0
        var unreadable: [String] = []
    }

    /// Groups of files with the same size and the same name. Hidden files are not looked at, and neither are
    /// packages such as apps and photo libraries: a package lists as one item of no size, below any minimum.
    public static func duplicates(_ config: ScanConfig, options: ScanOptions = ScanOptions(),
                                  isCancelled: @escaping @Sendable () -> Bool = { false },
                                  onProgress: @escaping @Sendable (Int) -> Void = { _ in }) -> (groups: [DupGroup], skipped: [SkippedItem]) {
        let patterns = ScanRunner.excludedItems + options.skipPatterns
        let barred = config.excluded
        let minSize = max(config.minSize, 1)
        let extensions = Set(FileKind.allCases.filter(config.kinds.contains).flatMap(\.extensions))
        let tally = Tally()

        let roots = config.locations.map(\.path).filter { root in
            !barred.contains { Paths.contains($0, root) } && !excluded(root, isFolder: true, patterns: patterns)
        }
        let files = FastWalk.walk(roots, list: FastWalk.details, unreadable: { dir in
            tally.lock.withLock { tally.unreadable.append(dir) }
        }) { dir, entries -> (found: [FileEntry], descend: [String]) in
            if isCancelled() { return ([], []) }
            var found: [FileEntry] = []
            var descend: [String] = []
            for entry in entries {
                let path = dir + "/" + entry.name
                if entry.isFolder {
                    if !barred.contains(where: { Paths.contains($0, path) }), !excluded(path, isFolder: true, patterns: patterns) {
                        descend.append(path)
                    }
                } else if entry.size >= minSize,
                          extensions.isEmpty || extensions.contains((entry.name as NSString).pathExtension.lowercased()),
                          !excluded(path, isFolder: false, patterns: patterns) {
                    found.append(FileEntry(path: path, size: entry.size, modified: entry.modified, isReference: config.isReference(path)))
                }
            }
            let total = tally.lock.withLock { () -> Int in tally.count += found.count; return tally.count }
            onProgress(total)
            return (found, descend)
        }

        struct Key: Hashable { let size: UInt64; let name: String }
        var byKey: [Key: [FileEntry]] = [:]
        var seen = Set<String>()
        for file in files where seen.insert(file.path).inserted {
            byKey[Key(size: file.size, name: file.name), default: []].append(file)
        }
        // A group only matters if it has a copy that may be removed.
        let groups = byKey.values
            .filter { $0.count > 1 && $0.contains(where: { !$0.isReference }) }
            .map { $0.sorted { $0.path < $1.path } }
            .sorted { ($0[0].size, $1[0].path) > ($1[0].size, $0[0].path) }
            .enumerated().map { DupGroup(id: $0.offset, size: $0.element[0].size, files: $0.element) }
        return (groups, tally.unreadable.sorted().map { SkippedItem(path: $0, reason: L("The folder could not be read")) })
    }
}
