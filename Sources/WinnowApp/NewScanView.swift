import AppKit
import WinnowCore
import SwiftUI

struct NewScanView: View {
    @Environment(AppModel.self) private var model
    @State private var dropTargeted = false

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
                            remove: { model.draft.locations.removeAll { $0.id == loc.id } })
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
                    .disabled(model.job != nil || model.draft.locations.isEmpty || model.draft.tools.isEmpty)
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
    let remove: () -> Void

    var body: some View {
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
            Tag(text: local ? (external ? "外接磁盘" : "本机") : "网络卷", tone: local ? .plain : .orange)
            Spacer()
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
