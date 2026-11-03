import AppKit
import WinnowCore
import SwiftUI

struct NewScanView: View {
    @Environment(AppModel.self) private var model
    @State private var dropTargeted = false
    @State private var showMore = ProcessInfo.processInfo.environment["WINNOW_SNAPSHOT_MORE"] != nil

    static let sizes: [(UInt64, String)] = [(1, "不限"), (8 * 1024, "8 KB（默认）"), (1 << 20, "1 MB"),
                                             (10 << 20, "10 MB"), (100 << 20, "100 MB")]

    var body: some View {
        @Bindable var model = model
        ScrollView {
            VStack(alignment: .leading, spacing: 28) {
                Step(number: 1, title: "扫描哪里",
                     hint: "可以把文件夹直接拖进来。打开「只作对照」的位置，里面的文件只用来比对，永远不会被标记删除。") {
                    locations
                }
                Step(number: 2, title: "找什么", hint: "可以多选，一次扫完。") {
                    HStack(spacing: 10) {
                        ToolTile(title: "重复文件", detail: "内容完全一样的文件", on: binding(.duplicates))
                        ToolTile(title: "空文件夹", detail: "里面什么都没有", on: binding(.emptyFolders))
                    }
                    .frame(maxWidth: 520)
                }
                if model.draft.tools.contains(.duplicates) {
                    Step(number: 3, title: "怎么比对重复文件", hint: nil) {
                        Picker("", selection: $model.draft.method) {
                            Text("按内容（推荐）").tag(CompareMethod.hash)
                            Text("按大小和文件名").tag(CompareMethod.sizeName)
                        }
                        .pickerStyle(.segmented)
                        .labelsHidden()
                        .fixedSize()
                        HStack(alignment: .top, spacing: 16) {
                            Explain(title: "按内容", text: "逐字节比，结果可以放心删。要把候选文件读一遍，网络卷上较慢。")
                            Explain(title: "按大小和文件名", text: "很快出结果，但同名同大小不一定相同，只适合先摸底。")
                        }
                        .padding(.top, 6)
                        moreConditions
                    }
                }
            }
            .padding(.horizontal, 36)
            .padding(.vertical, 28)
            .frame(maxWidth: 880, alignment: .leading)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .safeAreaInset(edge: .bottom, spacing: 0) { footer }
        .navigationTitle("新建扫描")
        .dropDestination(for: URL.self) { urls, _ in
            add(urls)
            return true
        } isTargeted: { dropTargeted = $0 }
    }

    private var locations: some View {
        VStack(spacing: 0) {
            ForEach(model.draft.locations) { loc in
                LocationRow(location: loc,
                            reference: Binding(
                                get: { model.draft.locations.first { $0.id == loc.id }?.isReference ?? false },
                                set: { v in
                                    if let i = model.draft.locations.firstIndex(where: { $0.id == loc.id }) {
                                        model.draft.locations[i].isReference = v
                                    }
                                }),
                            exclude: { chooseExcluded(in: loc.path) },
                            remove: {
                                let gone = model.draft.excluded(in: loc.path)
                                model.draft.excluded.removeAll { gone.contains($0) }
                                model.draft.locations.removeAll { $0.id == loc.id }
                            })
                ForEach(model.draft.excluded(in: loc.path), id: \.self) { path in
                    ExcludedRow(path: path, root: loc.path) { model.draft.excluded.removeAll { $0 == path } }
                }
                Divider()
            }
            HStack {
                Button {
                    choose()
                } label: {
                    Label("添加位置…", systemImage: "plus")
                }
                .buttonStyle(.link)
                Spacer()
                Text("已自动跳过废纸篓、系统缓存、NAS 回收站和缩略图目录")
                    .font(.caption).foregroundStyle(.secondary)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .background(Color.primary.opacity(0.025))
        }
        .clipShape(RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10)
            .strokeBorder(dropTargeted ? Color.accentColor : Color(nsColor: .separatorColor), lineWidth: dropTargeted ? 2 : 1))
    }

    private var moreConditions: some View {
        @Bindable var model = model
        return VStack(alignment: .leading, spacing: 0) {
            Button {
                withAnimation(.easeOut(duration: 0.15)) { showMore.toggle() }
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: "chevron.right")
                        .font(.system(size: 10, weight: .semibold))
                        .rotationEffect(.degrees(showMore ? 90 : 0))
                        .foregroundStyle(.secondary)
                    (Text("更多条件　").fontWeight(.medium) + Text(conditionSummary).foregroundStyle(.secondary))
                        .font(.callout)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            if showMore {
            VStack(alignment: .leading, spacing: 14) {
                HStack(spacing: 12) {
                    Text("最小文件大小").frame(width: 84, alignment: .leading)
                    Picker("", selection: $model.draft.minSize) {
                        ForEach(Self.sizes, id: \.0) { Text($0.1).tag($0.0) }
                    }
                    .labelsHidden()
                    .fixedSize()
                    Text("更小的文件不检查，它们重复了也占不了多少空间。").font(.caption).foregroundStyle(.secondary)
                }
                HStack(alignment: .firstTextBaseline, spacing: 12) {
                    Text("文件类型").frame(width: 84, alignment: .leading)
                    HStack(spacing: 6) {
                        Chip(title: "全部", on: model.draft.kinds.isEmpty) { model.draft.kinds = [] }
                        ForEach(FileKind.allCases, id: \.self) { kind in
                            Chip(title: Self.kindName(kind), on: model.draft.kinds.contains(kind)) {
                                if model.draft.kinds.contains(kind) { model.draft.kinds.remove(kind) } else { model.draft.kinds.insert(kind) }
                            }
                        }
                    }
                }
                Text("要跳过某个子文件夹，在第 1 步对应位置上点「排除子文件夹」。")
                    .font(.caption).foregroundStyle(.secondary)
            }
            .padding(.top, 12)
            .padding(.leading, 16)
            }
        }
        .padding(.top, 10)
    }

    private var conditionSummary: String {
        let d = model.draft
        var parts: [String] = []
        parts.append(d.minSize <= 1 ? "不限大小" : "跳过小于 \(Fmt.bytes(d.minSize)) 的文件")
        parts.append(d.kinds.isEmpty ? "全部类型" : "只查" + FileKind.allCases.filter(d.kinds.contains).map(Self.kindName).joined(separator: "、"))
        if !d.excluded.isEmpty { parts.append("排除 \(d.excluded.count) 个文件夹") }
        return parts.joined(separator: " · ")
    }

    static func kindName(_ kind: FileKind) -> String {
        switch kind {
        case .photos: return "照片"
        case .videos: return "视频"
        case .music: return "音乐"
        case .documents: return "文档"
        case .archives: return "压缩包和安装包"
        }
    }

    private func chooseExcluded(in root: String) {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = true
        panel.directoryURL = URL(fileURLWithPath: root)
        panel.prompt = "排除"
        panel.message = "选「\(Paths.displayName(root))」里扫描时要跳过的文件夹"
        guard panel.runModal() == .OK else { return }
        for url in panel.urls {
            let path = url.standardizedFileURL.path
            if Paths.contains(root, path), path != root, !model.draft.excluded.contains(path) {
                model.draft.excluded.append(path)
            }
        }
    }

    private var footer: some View {
        VStack(spacing: 0) {
            Divider()
            HStack {
                Text(footerText).font(.callout).foregroundStyle(.secondary)
                Spacer()
                Button("开始扫描") { model.startScan() }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
                    .keyboardShortcut(.defaultAction)
                    .disabled(model.job != nil || model.draft.locations.isEmpty || model.draft.tools.isEmpty
                              || model.draft.locations.contains { !FileManager.default.fileExists(atPath: $0.path) })
            }
            .padding(.horizontal, 24)
            .padding(.vertical, 12)
        }
        .background(.bar)
    }

    private var footerText: String {
        if model.job != nil { return "已有一个扫描在进行，完成后才能开始新的。" }
        if model.draft.locations.isEmpty { return "先添加要扫描的位置。" }
        if model.draft.tools.isEmpty { return "至少选一项要找的内容。" }
        let missing = model.draft.locations.filter { !FileManager.default.fileExists(atPath: $0.path) }
        if !missing.isEmpty {
            return "\(missing.map { Paths.displayName($0.path) }.joined(separator: "、")) 没有连接。连上或移除后才能扫描。"
        }
        let scanned = model.draft.locations.filter { !$0.isReference }.count
        if scanned == 0 { return "所有位置都是「只作对照」，没有可以清理的地方。" }
        let network = model.draft.locations.contains { !Processor.isLocal($0.path) }
        return "将扫描 \(model.draft.locations.count) 个位置" + (network ? "。含网络卷，按内容比对可能需要几小时。" : "。")
    }

    private func binding(_ tool: Tool) -> Binding<Bool> {
        Binding(get: { model.draft.tools.contains(tool) },
                set: { on in
                    if on { model.draft.tools.insert(tool) } else { model.draft.tools.remove(tool) }
                })
    }

    private func choose() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = true
        panel.prompt = "添加"
        if panel.runModal() == .OK { add(panel.urls) }
    }

    private func add(_ urls: [URL]) {
        for url in urls {
            var isDir: ObjCBool = false
            guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir), isDir.boolValue else { continue }
            let path = url.standardizedFileURL.path
            if !model.draft.locations.contains(where: { $0.path == path }) {
                model.draft.locations.append(Location(path: path))
            }
        }
    }
}

private struct Step<Content: View>: View {
    let number: Int
    let title: String
    let hint: String?
    @ViewBuilder let content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text("\(number)").font(.system(size: 12, weight: .semibold, design: .monospaced)).foregroundStyle(.secondary)
                Text(title).font(.system(size: 15, weight: .semibold))
            }
            if let hint {
                Text(hint).font(.caption).foregroundStyle(.secondary).padding(.bottom, 6)
            } else {
                Spacer().frame(height: 6)
            }
            content
        }
    }
}

private struct LocationRow: View {
    let location: Location
    @Binding var reference: Bool
    let exclude: () -> Void
    let remove: () -> Void

    var body: some View {
        let connected = FileManager.default.fileExists(atPath: location.path)
        let local = Processor.isLocal(location.path)
        let external = local && location.path.hasPrefix("/Volumes/")
        HStack(spacing: 12) {
            Image(systemName: local ? (external ? "externaldrive" : "folder") : "server.rack")
                .frame(width: 20)
                .foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 1) {
                Text(Paths.displayName(location.path)).fontWeight(.medium)
                Text(location.path).font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
            }
            if connected {
                Tag(text: local ? (external ? "外接磁盘" : "本机") : "网络卷", tone: local ? .plain : .orange)
            } else {
                Tag(text: "未连接", tone: .orange)
            }
            Spacer()
            Button("排除子文件夹…", action: exclude)
                .buttonStyle(.link)
                .font(.caption)
            Toggle("只作对照", isOn: $reference)
                .toggleStyle(.switch)
                .controlSize(.mini)
                .font(.caption)
            Button(action: remove) {
                Image(systemName: "minus.circle")
            }
            .buttonStyle(.borderless)
            .help("移除这个位置")
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
    }
}

private struct ToolTile: View {
    let title: String
    let detail: String
    @Binding var on: Bool

    var body: some View {
        Button {
            on.toggle()
        } label: {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(title).fontWeight(.semibold).foregroundStyle(.primary)
                    Text(detail).font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Image(systemName: on ? "checkmark.square.fill" : "square")
                    .foregroundStyle(on ? Color.accentColor : Color.secondary)
            }
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 10).fill(on ? Color.accentColor.opacity(0.06) : Color.clear))
            .overlay(RoundedRectangle(cornerRadius: 10)
                .strokeBorder(on ? Color.accentColor : Color(nsColor: .separatorColor), lineWidth: on ? 2 : 1))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

private struct Explain: View {
    let title: String
    let text: String

    var body: some View {
        (Text(title + "：").fontWeight(.semibold) + Text(text).foregroundStyle(.secondary))
            .font(.caption)
            .frame(maxWidth: 300, alignment: .leading)
    }
}

struct Tag: View {
    enum Tone { case plain, orange, green, blue }
    let text: String
    var tone: Tone = .plain

    var body: some View {
        Text(text)
            .font(.system(size: 11))
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .foregroundStyle(color)
            .background(RoundedRectangle(cornerRadius: 5).fill(color.opacity(tone == .plain ? 0.1 : 0.12)))
    }

    private var color: Color {
        switch tone {
        case .plain: return .secondary
        case .orange: return .orange
        case .green: return .green
        case .blue: return .accentColor
        }
    }
}

private struct ExcludedRow: View {
    let path: String
    let root: String
    let remove: () -> Void

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "eye.slash").foregroundStyle(.secondary).frame(width: 20)
            Text("跳过").font(.caption).foregroundStyle(.secondary)
            Text(String(path.dropFirst(root.count)).split(separator: "/").joined(separator: " › "))
                .font(.caption)
                .lineLimit(1)
                .truncationMode(.middle)
                .help(path)
            Spacer()
            Button(action: remove) { Image(systemName: "xmark.circle.fill").foregroundStyle(.tertiary) }
                .buttonStyle(.borderless)
                .help("不再排除")
        }
        .padding(.leading, 46)
        .padding(.trailing, 14)
        .padding(.bottom, 8)
    }
}

private struct Chip: View {
    let title: String
    let on: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(.callout)
                .padding(.horizontal, 10)
                .padding(.vertical, 4)
                .foregroundStyle(on ? Color.white : Color.primary)
                .background(Capsule().fill(on ? Color.accentColor : Color.primary.opacity(0.07)))
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
    }
}
