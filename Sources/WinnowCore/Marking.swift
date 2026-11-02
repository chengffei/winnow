import Foundation

public enum Marking {
    /// Index of the copy the rule keeps, ignoring reference copies.
    public static func keeperIndex(_ files: [FileEntry], rule: AutoRule) -> Int? {
        let candidates = files.indices.filter { !files[$0].isReference }
        guard !candidates.isEmpty else { return nil }

        func depth(_ i: Int) -> Int { files[i].path.split(separator: "/").count }
        func oldest(_ idx: [Int]) -> Int {
            idx.min { a, b in
                (files[a].modified, depth(a), files[a].path) < (files[b].modified, depth(b), files[b].path)
            }!
        }

        switch rule {
        case .oldest:
            return oldest(candidates)
        case .newest:
            return candidates.min { a, b in
                (-files[a].modified, depth(a), files[a].path) < (-files[b].modified, depth(b), files[b].path)
            }
        case .shortestPath:
            return candidates.min { a, b in
                (depth(a), files[a].path.count, files[a].path) < (depth(b), files[b].path.count, files[b].path)
            }
        case .preferFolder(let folder):
            let inside = candidates.filter { Paths.contains(folder, files[$0].path) }
            return oldest(inside.isEmpty ? candidates : inside)
        }
    }

    /// Marks every copy but one for removal. Groups the user edited are skipped.
    /// With a reference copy present, the reference is what stays and every other copy goes.
    public static func apply(_ rule: AutoRule, to group: inout DupGroup) {
        guard !group.edited else { return }
        let hasReference = group.files.contains { $0.isReference }
        let keeper = hasReference ? nil : keeperIndex(group.files, rule: rule)
        for i in group.files.indices {
            if group.files[i].isReference {
                group.files[i].mark = .keep
            } else {
                group.files[i].mark = (hasReference || i != keeper) ? .delete : .keep
            }
        }
    }

    public static func apply(_ rule: AutoRule, to record: inout ScanRecord) {
        record.rule = rule
        for i in record.groups.indices { apply(rule, to: &record.groups[i]) }
    }

    /// Keeps every copy everywhere and forgets manual edits.
    public static func clearAll(_ record: inout ScanRecord) {
        for g in record.groups.indices {
            record.groups[g].edited = false
            for f in record.groups[g].files.indices { record.groups[g].files[f].mark = .keep }
        }
        for i in record.emptyFolders.indices { record.emptyFolders[i].mark = .keep }
    }

    /// Changes one copy by hand. Refuses to mark a reference copy, or the last kept copy, for removal.
    @discardableResult
    public static func set(_ mark: Mark, path: String, in group: inout DupGroup) -> Bool {
        guard let i = group.files.firstIndex(where: { $0.path == path }) else { return false }
        if group.files[i].mark == mark { return true }
        if mark == .delete {
            if group.files[i].isReference { return false }
            let othersKept = group.files.indices.contains { $0 != i && group.files[$0].mark == .keep }
            if !othersKept { return false }
        }
        group.files[i].mark = mark
        group.edited = true
        return true
    }
}
