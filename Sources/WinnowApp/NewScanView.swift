import AppKit
import WinnowCore
import SwiftUI

struct NewScanView: View {
    @Environment(AppModel.self) private var model
    @State private var dropTargeted = false
    @State private var showMore = ProcessInfo.processInfo.environment["WINNOW_SNAPSHOT_MORE"] != nil

    static var sizes: [(UInt64, String)] {
        [(1, L("Any size")), (8 * 1024, L("8 KB (default)")), (1 << 20, "1 MB"), (10 << 20, "10 MB"), (100 << 20, "100 MB")]
    }

    var body: some View {
        @Bindable var model = model
        ScrollView {
            VStack(alignment: .leading, spacing: 28) {
                Step(number: 1, title: L("Where to Look"),
                     hint: L("Drag folders here, or add them below. Files in a “compare only” location are used for matching and are never marked for removal.")) {
                    locations
                }
                Step(number: 2, title: L("What to Find"), hint: L("Pick one or both; they run in one scan.")) {
                    HStack(spacing: 10) {
                        ToolTile(title: L("Duplicate Files"), detail: L("Files with exactly the same content"), on: binding(.duplicates))
                        ToolTile(title: L("Empty Folders"), detail: L("Folders with nothing in them"), on: binding(.emptyFolders))
                    }
                    .frame(maxWidth: 520)
                }
                if model.draft.tools.contains(.duplicates) {
                    Step(number: 3, title: L("How to Compare Duplicates"), hint: nil) {
                        Picker("", selection: $model.draft.method) {
                            Text(L("By content (recommended)")).tag(CompareMethod.hash)
                            Text(L("By size and name")).tag(CompareMethod.sizeName)
                        }
                        .pickerStyle(.segmented)
                        .labelsHidden()
                        .fixedSize()
                        HStack(alignment: .top, spacing: 16) {
                            Explain(title: L("By content"),
                                    text: L("Compares every byte, so results are safe to delete. Candidates are read in full, which is slow on network drives."))
                            Explain(title: L("By size and name"),
                                    text: L("Fast, but files with the same name and size are not always the same. Good for a first look."))
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
        .navigationTitle(L("New Scan"))
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
                    Label(L("Add Location…"), systemImage: "plus")
                }
                .buttonStyle(.link)
                Spacer()
                Text(L("Trash, system caches, NAS recycle bins and thumbnail folders are always skipped"))
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
                    Text(L("More Conditions")).fontWeight(.medium)
                    Text(conditionSummary).foregroundStyle(.secondary)
                }
                .font(.callout)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            if showMore {
                Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: 12, verticalSpacing: 14) {
                    GridRow {
                        Text(L("Minimum size"))
                        HStack(spacing: 12) {
                            Picker("", selection: $model.draft.minSize) {
                                ForEach(Self.sizes, id: \.0) { Text($0.1).tag($0.0) }
                            }
                            .labelsHidden()
                            .fixedSize()
                            Text(L("Smaller files are not checked; duplicates of them take little space."))
                                .font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    GridRow {
                        Text(L("File types"))
                        HStack(spacing: 6) {
                            Chip(title: L("All"), on: model.draft.kinds.isEmpty) { model.draft.kinds = [] }
                            ForEach(FileKind.allCases, id: \.self) { kind in
                                Chip(title: Self.kindName(kind), on: model.draft.kinds.contains(kind)) {
                                    if model.draft.kinds.contains(kind) { model.draft.kinds.remove(kind) } else { model.draft.kinds.insert(kind) }
                                }
                            }
                        }
                    }
                }
                .padding(.top, 12)
                .padding(.leading, 16)
                Text(L("To skip a subfolder, click “Exclude Subfolder” on its location in step 1."))
                    .font(.caption).foregroundStyle(.secondary)
                    .padding(.top, 10)
                    .padding(.leading, 16)
            }
        }
        .padding(.top, 10)
    }

    private var conditionSummary: String {
        let d = model.draft
        var parts: [String] = []
        parts.append(d.minSize <= 1 ? L("any size") : L("skips files under %@", Fmt.bytes(d.minSize)))
        parts.append(d.kinds.isEmpty ? L("all file types")
                     : L("only %@", joinedList(FileKind.allCases.filter(d.kinds.contains).map(Self.kindName))))
        if d.excluded.count == 1 { parts.append(L("1 folder excluded")) } else if !d.excluded.isEmpty { parts.append(L("%ld folders excluded", d.excluded.count)) }
        return parts.joined(separator: " · ")
    }

    static func kindName(_ kind: FileKind) -> String {
        switch kind {
        case .photos: return L("Photos")
        case .videos: return L("Videos")
        case .music: return L("Music")
        case .documents: return L("Documents")
        case .archives: return L("Archives & Installers")
        }
    }

    private func chooseExcluded(in root: String) {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = true
        panel.directoryURL = URL(fileURLWithPath: root)
        panel.prompt = L("Exclude")
        panel.message = L("Choose folders inside “%@” to skip", Paths.displayName(root))
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
                Button(L("Start Scan")) { model.startScan() }
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
        if model.job != nil { return L("Another scan is running. Start a new one when it finishes.") }
        if model.draft.locations.isEmpty { return L("Add a location to scan first.") }
        if model.draft.tools.isEmpty { return L("Pick at least one thing to find.") }
        let missing = model.draft.locations.filter { !FileManager.default.fileExists(atPath: $0.path) }
        if !missing.isEmpty {
            return L("%@ is not connected. Connect or remove it to scan.", joinedList(missing.map { Paths.displayName($0.path) }))
        }
        if model.draft.locations.allSatisfy(\.isReference) {
            return L("Every location is “compare only”, so nothing can be cleaned.")
        }
        let network = model.draft.locations.contains { !Processor.isLocal($0.path) }
        if model.draft.locations.count == 1 {
            return network ? L("Scans 1 location on a network drive; comparing by content may take hours.") : L("Scans 1 location.")
        }
        return network ? L("Scans %ld locations, including a network drive; comparing by content may take hours.", model.draft.locations.count)
                       : L("Scans %ld locations.", model.draft.locations.count)
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
        panel.prompt = L("Add")
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
                Tag(text: local ? (external ? L("External Drive") : L("This Mac")) : L("Network Drive"), tone: local ? .plain : .orange)
            } else {
                Tag(text: L("Not Connected"), tone: .orange)
            }
            Spacer()
            Button(L("Exclude Subfolder…"), action: exclude)
                .buttonStyle(.link)
                .font(.caption)
            Toggle(L("Compare only"), isOn: $reference)
                .toggleStyle(.switch)
                .controlSize(.mini)
                .font(.caption)
            Button(action: remove) {
                Image(systemName: "minus.circle")
            }
            .buttonStyle(.borderless)
            .help(L("Remove this location"))
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
    }
}

private struct ExcludedRow: View {
    let path: String
    let root: String
    let remove: () -> Void

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "eye.slash").foregroundStyle(.secondary).frame(width: 20)
            Text(L("Skip")).font(.caption).foregroundStyle(.secondary)
            Text(String(path.dropFirst(root.count)).split(separator: "/").joined(separator: " › "))
                .font(.caption)
                .lineLimit(1)
                .truncationMode(.middle)
                .help(path)
            Spacer()
            Button(action: remove) { Image(systemName: "xmark.circle.fill").foregroundStyle(.tertiary) }
                .buttonStyle(.borderless)
                .help(L("Stop excluding"))
        }
        .padding(.leading, 46)
        .padding(.trailing, 14)
        .padding(.bottom, 8)
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
        VStack(alignment: .leading, spacing: 1) {
            Text(title).fontWeight(.semibold)
            Text(text).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }
        .font(.caption)
        .frame(maxWidth: 300, alignment: .leading)
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
