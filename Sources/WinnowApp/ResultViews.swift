import AppKit
import WinnowCore
import SwiftUI
import UniformTypeIdentifiers

// MARK: Duplicates

enum SortKey: String, CaseIterable {
    case reclaim = "按可释放空间"
    case size = "按单个文件大小"
    case copies = "按份数"
    case name = "按名称"
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
            ContentUnavailableView("这条记录已删除", systemImage: "trash")
        }
    }

    private func content(_ record: ScanRecord) -> some View {
        let groups = visible(record)
        return HStack(spacing: 0) {
            VStack(spacing: 0) {
                HStack {
                    Text(sort.rawValue + "排序")
                    Spacer()
                    Text("已标记 \(Fmt.number(record.markedFiles)) 个")
                }
                .font(.caption)
                .foregroundStyle(.secondary)
                .padding(.horizontal, 14)
                .padding(.vertical, 8)
                Divider()
                if groups.isEmpty {
                    ContentUnavailableView(record.groups.isEmpty ? "没有找到重复文件" : "没有匹配的结果",
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
                    ContentUnavailableView("选一组查看", systemImage: "doc.on.doc")
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .safeAreaInset(edge: .top, spacing: 0) { StagedBanner(id: id) }
        .safeAreaInset(edge: .bottom, spacing: 0) { ProcessBar(record: record) { showProcess = true } }
        .navigationTitle("重复文件")
        .navigationSubtitle("\(Fmt.number(record.groups.count)) 组 · 可释放 \(Fmt.bytes(record.reclaimable))")
        .searchable(text: $query, placement: .toolbar, prompt: "搜索文件名或路径")
        .toolbar {
            ToolbarItemGroup {
                AutoMarkMenu(id: id, rule: record.rule)
                Picker("排序", selection: $sort) {
                    ForEach(SortKey.allCases, id: \.self) { Text($0.rawValue).tag($0) }
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
            item("每组保留最早的一份（推荐，原件通常最早）", .oldest)
            item("每组保留最新的一份", .newest)
            item("每组保留路径最短的一份", .shortestPath)
            Button {
                let panel = NSOpenPanel()
                panel.canChooseDirectories = true
                panel.canChooseFiles = false
                panel.prompt = "优先保留这里的"
                if panel.runModal() == .OK, let url = panel.url {
                    apply(.preferFolder(url.standardizedFileURL.path))
                }
            } label: {
                if case .preferFolder(let f) = rule {
                    Label("优先保留在「\(Paths.displayName(f))」里的", systemImage: "checkmark")
                } else {
                    Text("优先保留在指定文件夹里的…")
                }
            }
            Divider()
            Button("全部取消标记") { model.mutate(id) { Marking.clearAll(&$0) } }
        } label: {
            Label("自动标记", systemImage: "wand.and.stars")
        }
        .help("手动改过的组不会被自动标记覆盖")
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
                Text("\(group.files.count) 份 · 每份 \(Fmt.bytes(group.size))")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Spacer(minLength: 8)
            VStack(alignment: .trailing, spacing: 1) {
                Text(Fmt.bytes(group.reclaimable)).fontWeight(.semibold).monospacedDigit()
                Text("可释放").font(.caption2).foregroundStyle(.secondary)
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
        let kind = UTType(filenameExtension: ext)?.localizedDescription ?? "文件"
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                HStack(spacing: 16) {
                    FileIcon(name: group.name, size: 72)
                    VStack(alignment: .leading, spacing: 3) {
                        Text(group.name).font(.title3.weight(.semibold)).textSelection(.enabled)
                        Text("\(kind) · \(Fmt.bytes(group.size)) · \(group.files.count) 份"
                             + (record.config.method == .hash ? "内容完全相同" : "大小和文件名相同"))
                            .font(.callout).foregroundStyle(.secondary)
                        if record.config.method == .sizeName {
                            Text("内容没有逐字节核对，处理前建议打开确认。").font(.callout).foregroundStyle(.orange)
                        }
                    }
                }
                VStack(spacing: 0) {
                    ForEach(Array(group.files.enumerated()), id: \.element.id) { i, file in
                        CopyRow(file: file, isOldest: file.path == oldest && group.files.count > 1) { mark in
                            refusal = set(mark, file.path) ? nil
                                : (file.isReference ? "这份在「只作对照」的位置里，不会删除。" : "每组至少要保留一份。")
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
            return "这组有「只作对照」位置里的副本，以它为准，其余副本都标记删除。"
        }
        if group.edited { return "这组手动改过，自动标记不会覆盖。" }
        return "按「\(Self.ruleName(record.rule))」自动标记。手动改过的组不会被再次自动标记覆盖。"
    }

    static func ruleName(_ rule: AutoRule) -> String {
        switch rule {
        case .oldest: return "每组保留最早的一份"
        case .newest: return "每组保留最新的一份"
        case .shortestPath: return "每组保留路径最短的一份"
        case .preferFolder(let f): return "优先保留在\(Paths.displayName(f))里的"
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
                Label("对照", systemImage: "lock.fill")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .frame(width: 96, alignment: .leading)
                    .help("这份在「只作对照」的位置里，不会删除")
            } else {
                KeepDeletePill(mark: file.mark, set: set)
                    .frame(width: 96, alignment: .leading)
            }
            VStack(alignment: .leading, spacing: 2) {
                PathCrumbs(path: file.path)
                Text("修改于 \(Fmt.day(file.modified))" + (isOldest ? " · 最早" : ""))
                    .font(.caption2).foregroundStyle(.secondary)
            }
            Spacer(minLength: 8)
            Button("在访达中显示") {
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
            segment("保留", .keep, .green)
            segment("删除", .delete, .red)
        }
        .padding(2)
        .background(RoundedRectangle(cornerRadius: 7).fill(Color.primary.opacity(0.07)))
    }

    private func segment(_ title: String, _ value: Mark, _ color: Color) -> some View {
        let on = mark == value
        return Button {
            set(value)
        } label: {
            Text(title)
                .font(.system(size: 12, weight: on ? .semibold : .regular))
                .foregroundStyle(on ? color : Color.secondary)
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
        (Text(c.head).fontWeight(.medium).foregroundStyle(.primary)
            + Text(c.rest.isEmpty ? "" : " › " + c.rest.joined(separator: " › ")).foregroundStyle(.secondary))
            .font(.system(size: 12))
            .lineLimit(2)
            .truncationMode(.middle)
            .help(path)
            .textSelection(.enabled)
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
                    Text("还没有删除任何东西").font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Button("核对并处理…", action: action)
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
        var parts: [String] = []
        if record.markedFiles > 0 { parts.append("\(Fmt.number(record.markedFiles)) 个文件") }
        if record.markedFolders > 0 { parts.append("\(Fmt.number(record.markedFolders)) 个空文件夹") }
        if parts.isEmpty { return "没有标记任何项目" }
        return "已标记 " + parts.joined(separator: "、") + (record.markedFiles > 0 ? "，将释放 \(Fmt.bytes(record.reclaimable))" : "")
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
                        Text("已移到暂存文件夹 \(Fmt.number(record.moves.count)) 项。确认没问题后可以在访达里删掉暂存文件夹。")
                    }
                    Spacer()
                    if !record.moves.isEmpty {
                        Button("打开暂存文件夹") { open(record.moves) }
                        Button("全部还原") { restore(record.moves) }.disabled(working)
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
        guard let i = parts.firstIndex(where: { $0.hasPrefix(Processor.stagingPrefix) }) else { return nil }
        return parts[...i].joined(separator: "/")
    }

    private func restore(_ moves: [Move]) {
        working = true
        Task {
            let result = await Task.detached { Processor.restore(moves) }.value
            let restored = Set(result.restored)
            model.mutate(id) { $0.moves.removeAll { restored.contains($0) } }
            message = result.failures.isEmpty
                ? "已还原 \(Fmt.number(result.restored.count)) 项。重新扫描可以看到最新结果。"
                : "已还原 \(Fmt.number(result.restored.count)) 项，\(result.failures.count) 项没能还原（原位置已有同名项目或无法访问）。"
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
                    ContentUnavailableView("没有找到空文件夹", systemImage: "checkmark.circle")
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
                                Button("在访达中显示") {
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
            .navigationTitle("空文件夹")
            .navigationSubtitle("\(Fmt.number(record.emptyFolders.count)) 个，只含空文件夹的也算")
            .toolbar {
                ToolbarItemGroup {
                    Button("全部标记") { setAll(.delete) }
                    Button("全部取消") { setAll(.keep) }
                }
            }
            .sheet(isPresented: $showProcess) { ProcessSheet(id: id) }
        } else {
            ContentUnavailableView("这条记录已删除", systemImage: "trash")
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
            Text("这些位置没能读取，扫描时跳过了，里面的重复文件不在结果里。")
                .foregroundStyle(.secondary)
            HStack {
                Button("打开「完全磁盘访问权限」设置") {
                    NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles")!)
                }
                Text("给本应用授权后重新扫描。网络卷上的权限要在 NAS 上改。").font(.caption).foregroundStyle(.secondary)
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
        .navigationTitle("没有权限")
        .navigationSubtitle("\(items.count) 个位置被跳过")
    }

    static func reason(_ text: String) -> String {
        if text.contains("Permission denied") || text.contains("Operation not permitted") { return "没有读取权限" }
        return text
    }
}
