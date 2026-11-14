import AppKit
import WinnowCore
import SwiftUI

/// Finds folders that only wrap one folder, and moves the inner folders to a chosen place.
struct NestedFoldersView: View {
    @State private var folders: [String]
    @State private var items: [Unnester.Item]
    @State private var searched: Bool
    @State private var destination: String?
    @State private var trashEmptied = true
    @State private var busy = false
    @State private var lastBatch = Unnester.loadLast()
    @State private var message: String?

    init(folders: [String] = [], items: [Unnester.Item] = [], searched: Bool = false, destination: String? = nil) {
        _folders = State(initialValue: folders)
        _items = State(initialValue: items)
        _searched = State(initialValue: searched)
        _destination = State(initialValue: destination)
    }

    private var included: [Unnester.Item] { items.filter(\.include) }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 14) {
                Text(L("Finds folders whose only content is one folder, such as A/B, and moves B to the place you choose."))
                    .font(.callout).foregroundStyle(.secondary)
                FolderList(folders: $folders)
                HStack {
                    Spacer()
                    Button(L("Find Folders"), action: find)
                        .disabled(folders.isEmpty || busy)
                }
            }
            .padding(.horizontal, 36)
            .padding(.top, 28)
            .padding(.bottom, 16)
            .frame(maxWidth: 880, alignment: .leading)
            Divider()
            results
        }
        .safeAreaInset(edge: .bottom, spacing: 0) { footer }
        .navigationTitle(L("Nested Folders"))
    }

    @ViewBuilder private var results: some View {
        if busy {
            ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if !searched {
            ContentUnavailableView(L("Nothing Found Yet"), systemImage: "folder",
                                   description: Text(L("Add a location, then click Find Folders.")))
        } else if items.isEmpty {
            ContentUnavailableView(L("No Matches"), systemImage: "checkmark.circle",
                                   description: Text(L("No folder here holds just one folder.")))
        } else {
            Table(items) {
                TableColumn("") { item in
                    Toggle("", isOn: includeBinding(item.outer)).labelsHidden()
                }
                .width(24)
                TableColumn(L("Folder to Move")) { item in
                    Label(item.innerName, systemImage: "folder").lineLimit(1).truncationMode(.middle).help(item.inner)
                }
                TableColumn(L("Now Inside")) { item in
                    Text(item.outer).font(.caption).foregroundStyle(.secondary)
                        .lineLimit(1).truncationMode(.head).help(item.outer)
                }
            }
        }
    }

    private var footer: some View {
        VStack(spacing: 0) {
            Divider()
            HStack(spacing: 12) {
                Text(message ?? footerText).font(.callout).foregroundStyle(.secondary)
                Spacer()
                if !lastBatch.isEmpty {
                    Button(L("Undo Last Move (%ld)", lastBatch.moves.count), action: undo)
                }
                Toggle(L("Move emptied folders to the Trash"), isOn: $trashEmptied)
                    .toggleStyle(.checkbox)
                Button(destination.map { L("To: %@", Paths.displayName($0)) } ?? L("Choose Destination…"), action: chooseDestination)
                    .help(destination ?? "")
                Button(L("Move %ld Folders", included.count), action: move)
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
                    .disabled(included.isEmpty || destination == nil || busy)
            }
            .padding(.horizontal, 24)
            .padding(.vertical, 12)
        }
        .background(.bar)
    }

    private var footerText: String {
        guard searched, !items.isEmpty else { return L("Folders are moved, not copied. Undo puts them back.") }
        return destination == nil ? L("%ld found. Choose where to move them.", items.count) : L("%ld folders found.", items.count)
    }

    private func includeBinding(_ outer: String) -> Binding<Bool> {
        Binding(get: { items.first { $0.outer == outer }?.include ?? false },
                set: { v in if let i = items.firstIndex(where: { $0.outer == outer }) { items[i].include = v } })
    }

    private func find() {
        let roots = folders
        busy = true
        message = nil
        Task {
            items = await Task.detached { Unnester.plan(roots: roots) }.value
            searched = true
            busy = false
        }
    }

    private func chooseDestination() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.prompt = L("Choose")
        if panel.runModal() == .OK, let url = panel.url { destination = url.standardizedFileURL.path }
    }

    private func move() {
        guard let destination else { return }
        let chosen = included, trash = trashEmptied
        busy = true
        Task {
            let batch = await Task.detached { Unnester.apply(chosen, to: destination, trashEmptied: trash) }.value
            lastBatch = batch
            Unnester.saveLast(batch)
            message = batch.failures.isEmpty
                ? L("Moved %ld folders.", batch.moves.count)
                : L("Moved %ld folders; %ld were skipped because they changed or the name is taken in the destination.",
                    batch.moves.count, batch.failures.count)
            let done = Set(batch.moves.map(\.from))
            items.removeAll { done.contains($0.inner) }
            busy = false
        }
    }

    private func undo() {
        let batch = lastBatch
        busy = true
        Task {
            let outcome = await Task.detached { Unnester.undo(batch) }.value
            lastBatch = Unnester.Batch()
            Unnester.saveLast(lastBatch)
            message = outcome.failures.isEmpty
                ? L("Moved %ld folders back.", outcome.done.count)
                : L("Moved %ld folders back; %ld could not be restored.", outcome.done.count, outcome.failures.count)
            busy = false
            if searched { find() }
        }
    }
}
