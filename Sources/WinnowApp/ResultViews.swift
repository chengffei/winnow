import AppKit
import WinnowCore
import SwiftUI
import UniformTypeIdentifiers

// MARK: Duplicates

enum SortKey: String, CaseIterable {
    case reclaim, size, copies, name

    var title: String {
        switch self {
        case .reclaim: return L("By Space Freed")
        case .size: return L("By File Size")
        case .copies: return L("By Number of Copies")
        case .name: return L("By Name")
        }
    }
}

struct DuplicatesView: View {
    @Environment(AppModel.self) private var model
    let id: UUID
    @State private var selected: Int?
    @State private var sort: SortKey = .reclaim
    @State private var query = ""
    @State private var showProcess = false

    var body: some View {
        if let record = model.record(id) {
            content(record)
        } else {
            ContentUnavailableView(L("This record was deleted"), systemImage: "trash")
        }
    }

    private func content(_ record: ScanRecord) -> some View {
        let groups = visible(record)
        return HStack(spacing: 0) {
            VStack(spacing: 0) {
                HStack {
                    Text(sort.title)
                    Spacer()
                    Text(L("%@ marked", Fmt.number(record.markedFiles)))
                }
                .font(.caption)
                .foregroundStyle(.secondary)
                .padding(.horizontal, 14)
                .padding(.vertical, 8)
                Divider()
                if groups.isEmpty {
                    ContentUnavailableView(record.groups.isEmpty ? L("No duplicate files found") : L("No matching results"),
                                           systemImage: record.groups.isEmpty ? "checkmark.circle" : "magnifyingglass")
                } else {
                    List(groups, selection: $selected) { g in
                        GroupRow(group: g).tag(g.id)
                    }
                    .listStyle(.plain)
                }
            }
            .frame(width: 340)
            Divider()
            Group {
                if let gid = selected ?? groups.first?.id, let g = record.groups.first(where: { $0.id == gid }) {
                    GroupDetail(group: g, record: record) { mark, path in
                        var ok = false
                        model.mutate(id) { r in
                            if let i = r.groups.firstIndex(where: { $0.id == gid }) {
                                ok = Marking.set(mark, path: path, in: &r.groups[i])
                            }
                        }
                        return ok
                    }
                    .id(gid)
                } else {
                    ContentUnavailableView(L("Select a group"), systemImage: "doc.on.doc")
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .safeAreaInset(edge: .top, spacing: 0) { StagedBanner(id: id) }
        .safeAreaInset(edge: .bottom, spacing: 0) { ProcessBar(record: record) { showProcess = true } }
        .navigationTitle(L("Duplicate Files"))
        .navigationSubtitle(L("%@ groups · %@ can be freed", Fmt.number(record.groups.count), Fmt.bytes(record.reclaimable)))
        .searchable(text: $query, placement: .toolbar, prompt: L("Search names or paths"))
        .toolbar {
            ToolbarItemGroup {
                AutoMarkMenu(id: id, rule: record.rule)
                Picker(L("Sort"), selection: $sort) {
                    ForEach(SortKey.allCases, id: \.self) { Text($0.title).tag($0) }
                }
                .pickerStyle(.menu)
                .fixedSize()
            }
        }
        .sheet(isPresented: $showProcess) { ProcessSheet(id: id) }
        .onAppear { if selected == nil { selected = groups.first?.id } }
    }

    private func visible(_ record: ScanRecord) -> [DupGroup] {
        var groups = record.groups
        let q = query.trimmingCharacters(in: .whitespaces)
        if !q.isEmpty {
            groups = groups.filter { $0.files.contains { $0.path.localizedCaseInsensitiveContains(q) } }
        }
        switch sort {
        case .reclaim: groups.sort { ($0.potential, $0.id) > ($1.potential, $1.id) }
        case .size: groups.sort { ($0.size, $0.id) > ($1.size, $1.id) }
        case .copies: groups.sort { ($0.files.count, $0.potential) > ($1.files.count, $1.potential) }
        case .name: groups.sort { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        }
        return groups
    }
}

struct AutoMarkMenu: View {
    @Environment(AppModel.self) private var model
    let id: UUID
    let rule: AutoRule

    var body: some View {
        Menu {
            item(L("Keep the oldest copy in each group (recommended; the original is usually oldest)"), .oldest)
            item(L("Keep the newest copy in each group"), .newest)
            item(L("Keep the copy with the shortest path"), .shortestPath)
            Button {
                let panel = NSOpenPanel()
                panel.canChooseDirectories = true
                panel.canChooseFiles = false
                panel.prompt = L("Prefer This Folder")
                if panel.runModal() == .OK, let url = panel.url {
                    apply(.preferFolder(url.standardizedFileURL.path))
                }
            } label: {
                if case .preferFolder(let f) = rule {
                    Label(L("Prefer copies in “%@”", Paths.displayName(f)), systemImage: "checkmark")
                } else {
                    Text(L("Prefer copies in a folder…"))
                }
            }
            Divider()
            Button(L("Unmark All")) { model.mutate(id) { Marking.clearAll(&$0) } }
        } label: {
            Label(L("Auto Mark"), systemImage: "wand.and.stars")
        }
        .help(L("Groups you changed by hand are never overwritten"))
    }

    @ViewBuilder
    private func item(_ title: String, _ r: AutoRule) -> some View {
        Button {
            apply(r)
        } label: {
            if rule == r { Label(title, systemImage: "checkmark") } else { Text(title) }
        }
    }

    private func apply(_ r: AutoRule) {
        model.mutate(id) { Marking.apply(r, to: &$0) }
    }
}

struct GroupRow: View {
    let group: DupGroup

    var body: some View {
        HStack(spacing: 10) {
            FileIcon(name: group.name, size: 32)
            VStack(alignment: .leading, spacing: 2) {
                Text(group.name).lineLimit(1).truncationMode(.middle)
                Text(L("%ld copies · %@ each", group.files.count, Fmt.bytes(group.size)))
                    .font(.caption).foregroundStyle(.secondary)
            }
            Spacer(minLength: 8)
            VStack(alignment: .trailing, spacing: 1) {
                Text(Fmt.bytes(group.reclaimable)).fontWeight(.semibold).monospacedDigit()
                Text(L("can be freed")).font(.caption2).foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 3)
    }
}

struct GroupDetail: View {
    let group: DupGroup
    let record: ScanRecord
    let set: (Mark, String) -> Bool
    @State private var refusal: String?

    var body: some View {
        let oldest = group.files.min { $0.modified < $1.modified }?.path
        let ext = (group.name as NSString).pathExtension
        let kind = UTType(filenameExtension: ext)?.localizedDescription ?? L("File")
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                HStack(spacing: 16) {
                    FileIcon(name: group.name, size: 72)
                    VStack(alignment: .leading, spacing: 3) {
                        Text(group.name).font(.title3.weight(.semibold)).textSelection(.enabled)
                        Text(record.config.method == .hash
                             ? L("%@ · %@ · %ld copies with identical content", kind, Fmt.bytes(group.size), group.files.count)
                             : L("%@ · %@ · %ld copies with the same size and name", kind, Fmt.bytes(group.size), group.files.count))
                            .font(.callout).foregroundStyle(.secondary)
                        if record.config.method == .sizeName {
                            Text(L("Contents were not compared byte by byte. Open the files to check before removing.")).font(.callout).foregroundStyle(.orange)
                        }
                    }
                }
                VStack(spacing: 0) {
                    ForEach(Array(group.files.enumerated()), id: \.element.id) { i, file in
                        CopyRow(file: file, isOldest: file.path == oldest && group.files.count > 1) { mark in
                            refusal = set(mark, file.path) ? nil
                                : (file.isReference ? L("This copy is in a “compare only” location and is never removed.")
                                                    : L("Every group must keep at least one copy."))
                        }
                        if i < group.files.count - 1 { Divider() }
                    }
                }
                .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(Color(nsColor: .separatorColor)))
                if let refusal {
                    Text(refusal).font(.callout).foregroundStyle(.orange)
                }
                Text(note).font(.caption).foregroundStyle(.secondary)
            }
            .padding(24)
            .frame(maxWidth: 760, alignment: .leading)
        }
    }

    private var note: String {
        if group.files.contains(where: \.isReference) {
            return L("This group has a copy in a “compare only” location. That copy is kept and every other copy is marked.")
        }
        if group.edited { return L("You changed this group by hand, so auto marking leaves it alone.") }
        return L("Marked by “%@”. Groups you change by hand are not overwritten by auto marking.", Self.ruleName(record.rule))
    }

    static func ruleName(_ rule: AutoRule) -> String {
        switch rule {
        case .oldest: return L("Keep the oldest copy in each group")
        case .newest: return L("Keep the newest copy in each group")
        case .shortestPath: return L("Keep the copy with the shortest path")
        case .preferFolder(let f): return L("Prefer copies in “%@”", Paths.displayName(f))
        }
    }
}

struct CopyRow: View {
    let file: FileEntry
    let isOldest: Bool
    let set: (Mark) -> Void

    var body: some View {
        HStack(spacing: 12) {
            if file.isReference {
                Label(L("Reference"), systemImage: "lock.fill")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .frame(width: 110, alignment: .leading)
                    .help(L("This copy is in a “compare only” location and is never removed."))
            } else {
                KeepDeletePill(mark: file.mark, set: set)
                    .frame(width: 110, alignment: .leading)
            }
            VStack(alignment: .leading, spacing: 2) {
                PathCrumbs(path: file.path)
                Text(isOldest ? L("Modified %@ · oldest", Fmt.day(file.modified)) : L("Modified %@", Fmt.day(file.modified)))
                    .font(.caption2).foregroundStyle(.secondary)
            }
            Spacer(minLength: 8)
            Button(L("Show in Finder")) {
                NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: file.path)])
            }
            .buttonStyle(.link)
            .font(.caption)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
    }
}

struct KeepDeletePill: View {
    let mark: Mark
    let set: (Mark) -> Void

    var body: some View {
        HStack(spacing: 0) {
            segment(L("Keep"), .keep, .green)
            segment(L("Remove"), .delete, .red)
        }
        .padding(2)
        .background(RoundedRectangle(cornerRadius: 7).fill(Color.primary.opacity(0.07)))
        .fixedSize()
    }

    private func segment(_ title: String, _ value: Mark, _ color: Color) -> some View {
        let on = mark == value
        return Button {
            set(value)
        } label: {
            Text(title)
                .font(.system(size: 12, weight: on ? .semibold : .regular))
                .foregroundStyle(on ? color : Color.secondary)
                .lineLimit(1)
                .padding(.horizontal, 9)
                .padding(.vertical, 3)
                .background(RoundedRectangle(cornerRadius: 5)
                    .fill(on ? Color(nsColor: .controlBackgroundColor) : .clear)
                    .shadow(color: .black.opacity(on ? 0.12 : 0), radius: 1, y: 0.5))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

struct PathCrumbs: View {
    let path: String

    var body: some View {
        let c = Paths.crumbs(path)
        HStack(spacing: 0) {
            Text(c.head).fontWeight(.medium).foregroundStyle(.primary)
            Text(c.rest.isEmpty ? "" : " › " + c.rest.joined(separator: " › ")).foregroundStyle(.secondary)
        }
        .font(.system(size: 12))
        .lineLimit(1)
        .truncationMode(.middle)
        .help(path)
    }
}

/// Icon by file type only, so a slow network volume is never touched.
struct FileIcon: View {
    let name: String
    let size: CGFloat
    var folder = false

    var body: some View {
        let type = folder ? UTType.folder : (UTType(filenameExtension: (name as NSString).pathExtension) ?? .data)
        Image(nsImage: NSWorkspace.shared.icon(for: type))
            .resizable()
            .interpolation(.high)
            .frame(width: size, height: size)
    }
}

// MARK: Shared bars

struct ProcessBar: View {
    let record: ScanRecord
    let action: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            Divider()
            HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 1) {
                    Text(summary).fontWeight(.semibold)
                    Text(L("Nothing has been removed yet")).font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Button(L("Review and Clean Up…"), action: action)
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
                    .disabled(record.markedFiles + record.markedFolders == 0)
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 10)
        }
        .background(.bar)
    }

    private var summary: String {
        let files = record.markedFiles, folders = record.markedFolders
        if files == 0 && folders == 0 { return L("Nothing is marked") }
        if folders == 0 { return L("%@ files marked, %@ will be freed", Fmt.number(files), Fmt.bytes(record.reclaimable)) }
        if files == 0 { return L("%@ empty folders marked", Fmt.number(folders)) }
        return L("%@ files and %@ empty folders marked, %@ will be freed", Fmt.number(files), Fmt.number(folders), Fmt.bytes(record.reclaimable))
    }
}

/// Shown once something was moved to a staging folder: open it, or put everything back.
struct StagedBanner: View {
    @Environment(AppModel.self) private var model
    let id: UUID
    @State private var working = false
    @State private var message: String?

    var body: some View {
        if let record = model.record(id), !record.moves.isEmpty || message != nil {
            VStack(spacing: 0) {
                HStack(spacing: 10) {
                    Image(systemName: "tray.full")
                    if let message {
                        Text(message)
                    } else {
                        Text(L("%@ items were moved to a staging folder. Once you are sure, delete the staging folder in Finder.",
                               Fmt.number(record.moves.count)))
                    }
                    Spacer()
                    if !record.moves.isEmpty {
                        Button(L("Open Staging Folder")) { open(record.moves) }
                        Button(L("Restore All")) { restore(record.moves) }.disabled(working)
                    }
                }
                .font(.callout)
                .padding(.horizontal, 16)
                .padding(.vertical, 8)
                .background(Color.accentColor.opacity(0.08))
                Divider()
            }
        }
    }

    private func open(_ moves: [Move]) {
        let roots = Set(moves.compactMap { Self.stagingRoot($0.to) })
        NSWorkspace.shared.activateFileViewerSelecting(roots.map { URL(fileURLWithPath: $0) })
    }

    static func stagingRoot(_ path: String) -> String? {
        let parts = path.split(separator: "/", omittingEmptySubsequences: false)
        guard let i = parts.firstIndex(where: { part in Processor.allStagingPrefixes.contains { part.hasPrefix($0) } }) else { return nil }
        return parts[...i].joined(separator: "/")
    }

    private func restore(_ moves: [Move]) {
        working = true
        Task {
            let result = await Task.detached { Processor.restore(moves) }.value
            let restored = Set(result.restored)
            model.mutate(id) { $0.moves.removeAll { restored.contains($0) } }
            message = result.failures.isEmpty
                ? L("Restored %@ items. Scan again to see current results.", Fmt.number(result.restored.count))
                : L("Restored %@ items; %@ could not be restored (something with the same name is there, or it cannot be reached).",
                    Fmt.number(result.restored.count), Fmt.number(result.failures.count))
            working = false
        }
    }
}

// MARK: Empty folders

struct EmptyFoldersView: View {
    @Environment(AppModel.self) private var model
    let id: UUID
    @State private var showProcess = false

    var body: some View {
        if let record = model.record(id) {
            Group {
                if record.emptyFolders.isEmpty {
                    ContentUnavailableView(L("No empty folders found"), systemImage: "checkmark.circle")
                } else {
                    List {
                        ForEach(record.emptyFolders) { folder in
                            HStack(spacing: 10) {
                                Toggle("", isOn: Binding(
                                    get: { folder.mark == .delete },
                                    set: { on in
                                        model.mutate(id) { r in
                                            if let i = r.emptyFolders.firstIndex(where: { $0.id == folder.id }) {
                                                r.emptyFolders[i].mark = on ? .delete : .keep
                                            }
                                        }
                                    }))
                                    .toggleStyle(.checkbox)
                                    .labelsHidden()
                                FileIcon(name: folder.path, size: 20, folder: true)
                                PathCrumbs(path: folder.path)
                                Spacer()
                                Button(L("Show in Finder")) {
                                    NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: folder.path)])
                                }
                                .buttonStyle(.link)
                                .font(.caption)
                            }
                            .padding(.vertical, 3)
                        }
                    }
                }
            }
            .safeAreaInset(edge: .top, spacing: 0) { StagedBanner(id: id) }
            .safeAreaInset(edge: .bottom, spacing: 0) { ProcessBar(record: record) { showProcess = true } }
            .navigationTitle(L("Empty Folders"))
            .navigationSubtitle(L("%@ found; folders holding only empty folders count too", Fmt.number(record.emptyFolders.count)))
            .toolbar {
                ToolbarItemGroup {
                    Button(L("Mark All")) { setAll(.delete) }
                    Button(L("Unmark All")) { setAll(.keep) }
                }
            }
            .sheet(isPresented: $showProcess) { ProcessSheet(id: id) }
        } else {
            ContentUnavailableView(L("This record was deleted"), systemImage: "trash")
        }
    }

    private func setAll(_ mark: Mark) {
        model.mutate(id) { r in
            for i in r.emptyFolders.indices { r.emptyFolders[i].mark = mark }
        }
    }
}

// MARK: Skipped

struct SkippedView: View {
    @Environment(AppModel.self) private var model
    let id: UUID

    var body: some View {
        let items = model.record(id)?.skipped ?? []
        VStack(alignment: .leading, spacing: 12) {
            Text(L("These locations could not be read and were skipped, so duplicates inside them are missing from the results."))
                .foregroundStyle(.secondary)
            HStack {
                Button(L("Open Full Disk Access Settings")) {
                    NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles")!)
                }
                Text(L("Allow Winnow there, then scan again. Permissions on a network drive are set on the NAS."))
                    .font(.caption).foregroundStyle(.secondary)
            }
            List(Array(items.enumerated()), id: \.offset) { _, item in
                VStack(alignment: .leading, spacing: 2) {
                    if !item.path.isEmpty { PathCrumbs(path: item.path) }
                    Text(Self.reason(item.reason)).font(.caption).foregroundStyle(.secondary)
                }
                .padding(.vertical, 2)
            }
            .listStyle(.bordered(alternatesRowBackgrounds: true))
        }
        .padding(24)
        .navigationTitle(L("No Access"))
        .navigationSubtitle(L("%@ locations skipped", Fmt.number(items.count)))
    }

    static func reason(_ text: String) -> String {
        if text.contains("Permission denied") || text.contains("Operation not permitted") { return L("No permission to read") }
        return text
    }
}
