import AppKit
import WinnowCore
import SwiftUI

/// Finds files whose names contain a piece of text and takes that text out, after a preview.
struct RenameView: View {
    @State private var folders: [String]
    @State private var text: String
    @State private var subfolders = true
    @State private var items: [Renamer.Item]
    @State private var searchedText: String?
    @State private var searching = false
    @State private var lastBatch: [Renamer.Move] = Renamer.loadLast()
    @State private var message: String?

    init(folders: [String] = [], text: String = "", items: [Renamer.Item] = [], searched: Bool = false) {
        _folders = State(initialValue: folders)
        _text = State(initialValue: text)
        _items = State(initialValue: items)
        _searchedText = State(initialValue: searched ? text : nil)
    }

    private var included: [Renamer.Item] { items.filter { $0.include && $0.problem == nil } }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            form
                .padding(.horizontal, 36)
                .padding(.top, 28)
                .padding(.bottom, 16)
                .frame(maxWidth: 880, alignment: .leading)
            Divider()
            results
        }
        .safeAreaInset(edge: .bottom, spacing: 0) { footer }
        .navigationTitle(L("Remove Text from Names"))
    }

    private var form: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(L("Finds files whose names contain the text and takes it out. Nothing changes until you click Rename."))
                .font(.callout).foregroundStyle(.secondary)
            FolderList(folders: $folders)

            HStack(spacing: 12) {
                TextField(L("Text to remove"), text: $text)
                    .textFieldStyle(.roundedBorder)
                    .frame(maxWidth: 320)
                    .onSubmit(find)
                Toggle(L("Include subfolders"), isOn: $subfolders)
                    .toggleStyle(.checkbox)
                Spacer()
                Button(L("Find Files"), action: find)
                    .disabled(folders.isEmpty || text.isEmpty || searching)
            }
        }
    }

    @ViewBuilder private var results: some View {
        if searching {
            ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if let searched = searchedText, items.isEmpty {
            ContentUnavailableView(L("No Matches"), systemImage: "magnifyingglass",
                                   description: Text(L("No file name contains “%@”.", searched)))
        } else if searchedText == nil {
            ContentUnavailableView(L("Nothing Found Yet"), systemImage: "textformat",
                                   description: Text(L("Add a location, type the text, then click Find Files.")))
        } else {
            Table(items) {
                TableColumn("") { item in
                    Toggle("", isOn: includeBinding(item.path))
                        .labelsHidden()
                        .disabled(item.problem != nil)
                }
                .width(24)
                TableColumn(L("Current Name")) { item in
                    Text(item.oldName).lineLimit(1).truncationMode(.middle).help(item.path)
                }
                TableColumn(L("New Name")) { item in
                    HStack(spacing: 6) {
                        Text(item.newName).lineLimit(1).truncationMode(.middle)
                            .foregroundStyle(item.problem == nil ? .primary : .secondary)
                        if let problem = item.problem {
                            Tag(text: problem == .nameTaken ? L("Name taken") : L("Name would be empty"), tone: .orange)
                        }
                    }
                }
                TableColumn(L("Folder")) { item in
                    Text(item.folder).font(.caption).foregroundStyle(.secondary)
                        .lineLimit(1).truncationMode(.head).help(item.folder)
                }
            }
        }
    }

    private var footer: some View {
        VStack(spacing: 0) {
            Divider()
            HStack {
                Text(message ?? footerText).font(.callout).foregroundStyle(.secondary)
                Spacer()
                if !lastBatch.isEmpty {
                    Button(L("Undo Last Rename (%ld)", lastBatch.count), action: undo)
                }
                Button(L("Rename %ld Files", included.count), action: rename)
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
                    .disabled(included.isEmpty || searching)
            }
            .padding(.horizontal, 24)
            .padding(.vertical, 12)
        }
        .background(.bar)
    }

    private var footerText: String {
        guard searchedText != nil, !items.isEmpty else { return L("Files are renamed in place. Undo puts the old names back.") }
        let blocked = items.filter { $0.problem != nil }.count
        return blocked == 0 ? L("%ld files found.", items.count)
                            : L("%ld files found; %ld are left out because of a name problem.", items.count, blocked)
    }

    private func includeBinding(_ path: String) -> Binding<Bool> {
        Binding(get: { items.first { $0.path == path }?.include ?? false },
                set: { v in if let i = items.firstIndex(where: { $0.path == path }) { items[i].include = v } })
    }

    private func find() {
        guard !folders.isEmpty, !text.isEmpty else { return }
        let roots = folders, needle = text, deep = subfolders
        searching = true
        message = nil
        Task {
            let found = await Task.detached { Renamer.plan(roots: roots, text: needle, subfolders: deep) }.value
            items = found
            searchedText = needle
            searching = false
        }
    }

    private func rename() {
        let outcome = Renamer.apply(included)
        lastBatch = outcome.done
        Renamer.saveLast(outcome.done)
        message = outcome.failures.isEmpty
            ? L("Renamed %ld files.", outcome.done.count)
            : L("Renamed %ld files; %ld were skipped because they changed or the name was taken.", outcome.done.count, outcome.failures.count)
        let done = Set(outcome.done.map(\.from))
        items.removeAll { done.contains($0.path) }
    }

    private func undo() {
        let outcome = Renamer.undo(lastBatch)
        lastBatch = []
        Renamer.saveLast([])
        message = outcome.failures.isEmpty
            ? L("Restored %ld names.", outcome.done.count)
            : L("Restored %ld names; %ld could not be restored.", outcome.done.count, outcome.failures.count)
        if searchedText != nil { find() }
    }
}
