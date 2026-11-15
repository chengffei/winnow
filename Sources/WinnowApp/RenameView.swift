import AppKit
import WinnowCore
import SwiftUI

/// Finds files whose names contain any of several texts and takes them out, after a preview.
struct RenameView: View {
    @State private var folders: [String]
    /// Texts to take out; kept between launches, since the same ad tags come back.
    @State private var texts: [String]
    @State private var text = ""
    @State private var subfolders = true
    @State private var items: [Renamer.Item]
    @State private var searchedTexts: [String]?
    @State private var searching = false
    @State private var lastBatch: [Renamer.Move] = Renamer.loadLast()
    @State private var message: String?
    @State private var selection = Set<String>()

    private let persists: Bool

    /// `texts` is passed only by snapshot mode, which must not touch the saved list.
    init(folders: [String] = [], texts: [String]? = nil, items: [Renamer.Item] = [], searched: Bool = false, favorite: Favorite? = nil) {
        persists = texts == nil
        let saved = texts ?? favorite?.texts ?? UserDefaults.standard.stringArray(forKey: "removeTexts") ?? []
        _folders = State(initialValue: favorite?.folders ?? folders)
        _subfolders = State(initialValue: favorite?.subfolders ?? true)
        _texts = State(initialValue: saved)
        _items = State(initialValue: items)
        _searchedTexts = State(initialValue: searched ? saved : nil)
    }

    /// Adds what is typed; a pasted list adds one text per line.
    private func addTyped() {
        for line in text.components(separatedBy: .newlines) where !line.isEmpty && !texts.contains(line) {
            texts.append(line)
        }
        text = ""
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
        .onChange(of: texts) { _, new in
            if persists { UserDefaults.standard.set(new, forKey: "removeTexts") }
        }
    }

    private var form: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(L("Finds files whose names contain any of the texts and takes them all out. Nothing changes until you click Rename."))
                .font(.callout).foregroundStyle(.secondary)
            FolderList(folders: $folders)

            HStack(spacing: 12) {
                TextField(L("Text to remove, then Return"), text: $text)
                    .textFieldStyle(.roundedBorder)
                    .frame(maxWidth: 320)
                    .onSubmit(addTyped)
                Toggle(L("Include subfolders"), isOn: $subfolders)
                    .toggleStyle(.checkbox)
                Spacer()
                FavoriteButton(suggested: FavoriteButton.name(for: folders), disabled: folders.isEmpty) {
                    var favorite = Favorite(kind: .rename)
                    favorite.folders = folders
                    favorite.texts = texts
                    favorite.subfolders = subfolders
                    return favorite
                }
                Button(L("Find Files"), action: find)
                    .disabled(folders.isEmpty || (texts.isEmpty && text.isEmpty) || searching)
            }
            if !texts.isEmpty {
                FlowLayout(spacing: 6) {
                    ForEach(texts, id: \.self) { t in
                        HStack(spacing: 4) {
                            Text(t).lineLimit(1)
                            Button { texts.removeAll { $0 == t } } label: {
                                Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary)
                            }
                            .buttonStyle(.borderless)
                            .help(L("Remove"))
                        }
                        .font(.callout)
                        .padding(.leading, 10).padding(.trailing, 6).padding(.vertical, 3)
                        .background(Capsule().fill(Color.primary.opacity(0.07)))
                    }
                    Button(L("Clear All")) { texts = [] }
                        .buttonStyle(.link)
                        .font(.callout)
                }
            }
        }
    }

    @ViewBuilder private var results: some View {
        if searching {
            ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if let searched = searchedTexts, items.isEmpty {
            ContentUnavailableView(L("No Matches"), systemImage: "magnifyingglass",
                                   description: Text(L("No file name contains %@.", joinedList(searched.map { "“\($0)”" }))))
        } else if searchedTexts == nil {
            ContentUnavailableView(L("Nothing Found Yet"), systemImage: "textformat",
                                   description: Text(L("Add a location, type the text, then click Find Files.")))
        } else {
            Table(items, selection: $selection) {
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
                TableColumn("") { item in
                    Button { showInFinder([item.path]) } label: { Image(systemName: "magnifyingglass") }
                        .buttonStyle(.borderless)
                        .help(L("Show in Finder"))
                }
                .width(24)
            }
            .contextMenu(forSelectionType: String.self) { ids in
                if !ids.isEmpty {
                    Button(L("Show in Finder")) { showInFinder(ids) }
                    Divider()
                    Button(L("Check")) { setInclude(ids, true) }
                    Button(L("Uncheck")) { setInclude(ids, false) }
                }
            } primaryAction: { showInFinder($0) }
        }
    }

    private var footer: some View {
        VStack(spacing: 0) {
            Divider()
            HStack {
                Text(message ?? footerText).font(.callout).foregroundStyle(.secondary)
                Spacer()
                Button(L("Check All")) { setInclude(Set(items.map(\.id)), true) }.disabled(items.isEmpty)
                Button(L("Uncheck All")) { setInclude(Set(items.map(\.id)), false) }.disabled(items.isEmpty)
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
        guard searchedTexts != nil, !items.isEmpty else { return L("Files are renamed in place. Undo puts the old names back.") }
        let blocked = items.filter { $0.problem != nil }.count
        return blocked == 0 ? L("%ld files found.", items.count)
                            : L("%ld files found; %ld are left out because of a name problem.", items.count, blocked)
    }

    private func showInFinder(_ paths: Set<String>) { Finder.show(Array(paths)) }

    private func includeBinding(_ path: String) -> Binding<Bool> {
        Binding(get: { items.first { $0.path == path }?.include ?? false },
                set: { v in setInclude(selection.contains(path) ? selection : [path], v) })
    }

    /// Ticking a row that is part of the selection ticks the whole selection; rows with a name problem stay out.
    private func setInclude(_ paths: Set<String>, _ value: Bool) {
        for i in items.indices where paths.contains(items[i].path) && items[i].problem == nil { items[i].include = value }
    }

    private func find() {
        addTyped()
        guard !folders.isEmpty, !texts.isEmpty else { return }
        let roots = folders, needles = texts, deep = subfolders
        searching = true
        message = nil
        Task {
            let found = await Task.detached { Renamer.plan(roots: roots, texts: needles, subfolders: deep) }.value
            items = found
            searchedTexts = needles
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
        if searchedTexts != nil { find() }
    }
}

/// Lays children out left to right and wraps to a new line when the row is full.
struct FlowLayout: Layout {
    var spacing: CGFloat = 6

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let rows = arrange(width: proposal.width ?? .infinity, subviews: subviews)
        return CGSize(width: rows.map(\.width).max() ?? 0, height: rows.last.map { $0.y + $0.height } ?? 0)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        for row in arrange(width: bounds.width, subviews: subviews) {
            for (i, x) in zip(row.indices, row.xs) {
                subviews[i].place(at: CGPoint(x: bounds.minX + x, y: bounds.minY + row.y), proposal: .unspecified)
            }
        }
    }

    private struct Row { var indices: [Int] = []; var xs: [CGFloat] = []; var width: CGFloat = 0; var y: CGFloat = 0; var height: CGFloat = 0 }

    private func arrange(width: CGFloat, subviews: Subviews) -> [Row] {
        var rows = [Row()]
        for (i, view) in subviews.enumerated() {
            let size = view.sizeThatFits(.unspecified)
            if !rows[rows.count - 1].indices.isEmpty, rows[rows.count - 1].width + spacing + size.width > width {
                let last = rows[rows.count - 1]
                rows.append(Row(y: last.y + last.height + spacing))
            }
            var row = rows[rows.count - 1]
            let x = row.indices.isEmpty ? 0 : row.width + spacing
            row.indices.append(i); row.xs.append(x)
            row.width = x + size.width
            row.height = max(row.height, size.height)
            rows[rows.count - 1] = row
        }
        return rows
    }
}
