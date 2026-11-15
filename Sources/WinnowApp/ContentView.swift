import WinnowCore
import SwiftUI

struct ContentView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var model = model
        NavigationSplitView {
            Sidebar()
                .navigationSplitViewColumnWidth(min: 210, ideal: 240, max: 320)
        } detail: {
            switch model.route ?? .newScan {
            case .newScan:
                NewScanView()
            case .scanning:
                ScanningView()
            case .rename:
                RenameView(favorite: model.opened(.rename)).id(model.openedCount)
            case .nested:
                NestedFoldersView(favorite: model.opened(.nested)).id(model.openedCount)
            case .result(let id, let category):
                switch category {
                case .duplicates: DuplicatesView(id: id).id(id)
                case .emptyFolders: EmptyFoldersView(id: id).id(id)
                case .skipped: SkippedView(id: id).id(id)
                }
            }
        }
        .alert(L("The scan did not finish"), isPresented: Binding(get: { model.scanError != nil },
                                                                 set: { if !$0 { model.scanError = nil } })) {
            Button(L("OK")) {}
        } message: {
            Text(model.scanError ?? "")
        }
    }
}

struct Sidebar: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var model = model
        List(selection: $model.route) {
            Label(L("New Scan"), systemImage: "plus")
                .tag(Route.newScan)
            Label(L("Remove Text from Names"), systemImage: "pencil.line")
                .tag(Route.rename)
            Label(L("Nested Folders"), systemImage: "tray.and.arrow.up")
                .tag(Route.nested)

            if !model.favorites.isEmpty {
                Section(L("Favorites")) {
                    ForEach(model.favorites) { favorite in
                        Button { model.open(favorite) } label: {
                            SidebarRow(title: favorite.name, subtitle: Self.kindName(favorite.kind), icon: "star")
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .contextMenu {
                            Button(L("Remove from Favorites")) { model.removeFavorite(favorite.id) }
                        }
                    }
                }
            }

            if let job = model.job {
                Section(L("In Progress")) {
                    SidebarRow(title: job.config.title, subtitle: ScanningView.summary(job), icon: "clock")
                        .tag(Route.scanning)
                }
            }

            ForEach(model.records.prefix(8)) { record in
                Section("\(record.config.title) · \(Fmt.short(record.date))") {
                    if record.config.tools.contains(.duplicates) {
                        SidebarRow(title: L("Duplicate Files"), subtitle: L("%@ can be freed", Fmt.bytes(record.reclaimable)),
                                   icon: "doc.on.doc", count: record.groups.count)
                            .tag(Route.result(record.id, .duplicates))
                            .contextMenu { deleteButton(record.id) }
                    }
                    if record.config.tools.contains(.emptyFolders) {
                        SidebarRow(title: L("Empty Folders"), subtitle: nil, icon: "folder", count: record.emptyFolders.count)
                            .tag(Route.result(record.id, .emptyFolders))
                            .contextMenu { deleteButton(record.id) }
                    }
                    if !record.skipped.isEmpty {
                        SidebarRow(title: L("No Access"), subtitle: nil, icon: "exclamationmark.circle", count: record.skipped.count)
                            .tag(Route.result(record.id, .skipped))
                            .contextMenu { deleteButton(record.id) }
                    }
                }
            }
        }
        .listStyle(.sidebar)
    }

    static func kindName(_ kind: Favorite.Kind) -> String {
        switch kind {
        case .scan: return L("New Scan")
        case .rename: return L("Remove Text from Names")
        case .nested: return L("Nested Folders")
        }
    }

    private func deleteButton(_ id: UUID) -> some View {
        Button(L("Delete This Record")) { model.deleteRecord(id) }
    }
}

struct SidebarRow: View {
    let title: String
    let subtitle: String?
    let icon: String
    var count: Int?

    var body: some View {
        HStack {
            Label {
                VStack(alignment: .leading, spacing: 1) {
                    Text(title).lineLimit(1)
                    if let subtitle {
                        Text(subtitle).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                    }
                }
            } icon: {
                Image(systemName: icon)
            }
            Spacer(minLength: 4)
            if let count {
                Text(Fmt.number(count)).font(.callout).foregroundStyle(.secondary).monospacedDigit()
            }
        }
    }
}

/// Saves the page's current locations and settings as a favorite, after asking for a name.
struct FavoriteButton: View {
    @Environment(AppModel.self) private var model
    let suggested: String
    let disabled: Bool
    let make: () -> Favorite
    @State private var asking = false
    @State private var name = ""

    var body: some View {
        Button {
            name = suggested
            asking = true
        } label: {
            Label(L("Add to Favorites…"), systemImage: "star")
        }
        .disabled(disabled)
        .alert(L("Add to Favorites"), isPresented: $asking) {
            TextField(L("Name"), text: $name)
            Button(L("Save")) {
                var favorite = make()
                let typed = name.trimmingCharacters(in: .whitespaces)
                favorite.name = typed.isEmpty ? suggested : typed
                model.addFavorite(favorite)
            }
            Button(L("Cancel"), role: .cancel) {}
        } message: {
            Text(L("Saves the locations and settings on this page. Open it from the sidebar to bring them back."))
        }
    }

    static func name(for folders: [String]) -> String {
        joinedList(folders.map { Paths.displayName($0) })
    }
}
