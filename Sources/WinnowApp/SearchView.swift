import AppKit
import WinnowCore
import SwiftUI

/// Finds files by name or type and moves the ticked ones into one folder.
/// File names are read once per set of locations; typing only filters that list, so results follow each keystroke.
struct SearchView: View {
    @State private var folders: [String]
    @State private var text: String
    @State private var kinds: Set<FileKind>
    @State private var subfolders: Bool
    /// Every file in the locations; nil until they have been read.
    @State private var index: [FileSearch.File]?
    @State private var matches: [FileSearch.File] = []
    @State private var selection = Set<String>()
    @State private var sortOrder = [KeyPathComparator(\FileSearch.File.name, comparator: .localizedStandard)]
    @State private var destination: String?
    @State private var moving: (done: Int, total: Int)?
    @State private var lastBatch: [Renamer.Move]
    @State private var message: String?

    /// Snapshot mode passes its own files and must not read folders or saved state.
    private let demo: Bool
    static let shownLimit = 5_000

    init(folders: [String] = [], text: String = "", kinds: Set<FileKind> = [], files: [FileSearch.File]? = nil,
         destination: String? = nil, favorite: Favorite? = nil) {
        demo = files != nil
        _folders = State(initialValue: favorite?.folders ?? folders)
        _text = State(initialValue: favorite?.texts.first ?? text)
        _kinds = State(initialValue: favorite.map { Set($0.kinds) } ?? kinds)
        _subfolders = State(initialValue: favorite?.subfolders ?? true)
        _index = State(initialValue: files)
        _matches = State(initialValue: files.map { FileSearch.filter($0, FileSearch.Query(text: text, kinds: kinds)) } ?? [])
        let saved = files == nil ? UserDefaults.standard.string(forKey: "searchDestination") : nil
        _destination = State(initialValue: favorite?.destination ?? destination ?? saved)
        _lastBatch = State(initialValue: files == nil ? FileSearch.loadLast() : [])
    }

    private var query: FileSearch.Query { FileSearch.Query(text: text, kinds: kinds) }
    private var ticked: [FileSearch.File] { matches.filter(\.include) }
    private var shown: [FileSearch.File] { matches.count > Self.shownLimit ? Array(matches.prefix(Self.shownLimit)) : matches }

    private struct Source: Hashable {
        let folders: [String]
        let subfolders: Bool
    }

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
        .navigationTitle(L("Find Files"))
        .task(id: Source(folders: folders, subfolders: subfolders)) { await read() }
        .onChange(of: query) { refilter() }
        .onChange(of: sortOrder) { _, new in matches.sort(using: new) }
    }

    private var form: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(L("Finds files by name or type in the locations, then moves the ones you tick into one folder."))
                .font(.callout).foregroundStyle(.secondary)
            FolderList(folders: $folders)
            HStack(spacing: 12) {
                HStack(spacing: 6) {
                    Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                    TextField(L("Part of a name, or an extension such as .mkv"), text: $text)
                        .textFieldStyle(.plain)
                    if !text.isEmpty {
                        Button { text = "" } label: { Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary) }
                            .buttonStyle(.borderless)
                            .help(L("Clear"))
                    }
                }
                .padding(.horizontal, 8).padding(.vertical, 5)
                .background(RoundedRectangle(cornerRadius: 7).fill(Color(nsColor: .textBackgroundColor)))
                .overlay(RoundedRectangle(cornerRadius: 7).strokeBorder(Color(nsColor: .separatorColor)))
                .frame(maxWidth: 380)
                Toggle(L("Include subfolders"), isOn: $subfolders)
                    .toggleStyle(.checkbox)
                Spacer()
                FavoriteButton(suggested: FavoriteButton.name(for: folders), disabled: folders.isEmpty) {
                    var favorite = Favorite(kind: .search)
                    favorite.folders = folders
                    favorite.texts = [text]
                    favorite.kinds = FileKind.allCases.filter(kinds.contains)
                    favorite.subfolders = subfolders
                    favorite.destination = destination
                    return favorite
                }
            }
            HStack(spacing: 6) {
                ForEach(FileKind.allCases, id: \.self) { kind in
                    Toggle(NewScanView.kindName(kind), isOn: Binding(
                        get: { kinds.contains(kind) },
                        set: { on in if on { kinds.insert(kind) } else { kinds.remove(kind) } }))
                        .toggleStyle(.button)
                        .help(kind.extensions.map { "." + $0 }.joined(separator: " "))
                }
            }
            .controlSize(.small)
        }
    }

    @ViewBuilder private var results: some View {
        if folders.isEmpty {
            ContentUnavailableView(L("Nothing Found Yet"), systemImage: "magnifyingglass",
                                   description: Text(L("Add a location to search in.")))
        } else if let index {
            if query.isEmpty {
                ContentUnavailableView(L("%ld Files Here", index.count), systemImage: "magnifyingglass",
                                       description: Text(L("Type part of a name or pick a type to narrow them down.")))
            } else if matches.isEmpty {
                ContentUnavailableView(L("No Matches"), systemImage: "magnifyingglass",
                                       description: Text(L("No file here matches. Words separated by spaces must all be in the name.")))
            } else {
                table
            }
        } else {
            VStack(spacing: 10) {
                ProgressView()
                Text(L("Reading file names…")).font(.callout).foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private var table: some View {
        Table(shown, selection: $selection, sortOrder: $sortOrder) {
            TableColumn("") { file in
                Toggle("", isOn: includeBinding(file.path)).labelsHidden()
            }
            .width(24)
            TableColumn(L("Name"), value: \.name) { file in
                Text(file.name).lineLimit(1).truncationMode(.middle).help(file.path)
            }
            TableColumn(L("Folder"), value: \.folder) { file in
                Text(file.folder).font(.caption).foregroundStyle(.secondary)
                    .lineLimit(1).truncationMode(.head).help(file.folder)
            }
            TableColumn("") { file in
                Button { Finder.show([file.path]) } label: { Image(systemName: "magnifyingglass") }
                    .buttonStyle(.borderless)
                    .help(L("Show in Finder"))
            }
            .width(24)
        }
        .contextMenu(forSelectionType: String.self) { ids in
            if !ids.isEmpty {
                Button(L("Show in Finder")) { Finder.show(Array(ids)) }
                Divider()
                Button(L("Check")) { setInclude(ids, true) }
                Button(L("Uncheck")) { setInclude(ids, false) }
            }
        } primaryAction: { Finder.show(Array($0)) }
    }

    private var footer: some View {
        VStack(spacing: 0) {
            Divider()
            HStack(spacing: 12) {
                Text(message ?? footerText).font(.callout).foregroundStyle(.secondary).lineLimit(2)
                Spacer()
                Button(L("Check All")) { setInclude(Set(matches.map(\.path)), true) }.disabled(matches.isEmpty)
                Button(L("Uncheck All")) { setInclude(Set(matches.map(\.path)), false) }.disabled(ticked.isEmpty)
                if !lastBatch.isEmpty {
                    Button(L("Undo Last Move (%ld)", lastBatch.count), action: undo)
                }
                Button(destination.map { L("To: %@", Paths.displayName($0)) } ?? L("Choose Destination…")) { _ = chooseDestination() }
                    .help(destination ?? "")
                Button(L("Set Aside"), action: setAside)
                    .disabled(ticked.isEmpty || moving != nil)
                    .help(L("Moves the ticked files to a dated staging folder at the top of their drive, keeping their folders. Nothing is deleted; remove the staging folder yourself once you are sure."))
                Button(L("Move %ld Files", ticked.count), action: move)
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
                    .disabled(ticked.isEmpty || moving != nil)
                    .help(L("A file whose name is already in the destination gets a number added, so nothing is replaced."))
            }
            .padding(.horizontal, 24)
            .padding(.vertical, 12)
        }
        .background(.bar)
    }

    private var footerText: String {
        if let moving { return L("Moving %ld of %ld…", moving.done, moving.total) }
        guard index != nil, !query.isEmpty, !matches.isEmpty else { return L("Files are moved, not copied. Undo puts them back.") }
        if matches.count > Self.shownLimit {
            return L("%ld files match, the first %ld are listed; %ld ticked.", matches.count, Self.shownLimit, ticked.count)
        }
        return L("%ld files match; %ld ticked.", matches.count, ticked.count)
    }

    // MARK: Reading and filtering

    private func read() async {
        guard !demo else { return }
        index = nil
        matches = []
        message = nil
        guard !folders.isEmpty else { return }
        let roots = folders, deep = subfolders
        let found = await Task.detached { FileSearch.index(roots: roots, subfolders: deep) }.value
        guard !Task.isCancelled else { return }
        index = found
        refilter()
    }

    /// Ticks survive a change of search: a file ticked before is still ticked when it shows up again.
    private func refilter() {
        guard let index else { return }
        message = nil
        selection = []
        var found = FileSearch.filter(index, query)
        found.sort(using: sortOrder)
        matches = found
    }

    private func includeBinding(_ path: String) -> Binding<Bool> {
        Binding(get: { matches.first { $0.path == path }?.include ?? false },
                set: { v in setInclude(selection.contains(path) ? selection : [path], v) })
    }

    /// Ticking a row that is part of the selection ticks the whole selection.
    private func setInclude(_ paths: Set<String>, _ value: Bool) {
        for i in matches.indices where paths.contains(matches[i].path) { matches[i].include = value }
        guard var all = index else { return }
        for i in all.indices where paths.contains(all[i].path) { all[i].include = value }
        index = all
    }

    // MARK: Moving

    private func chooseDestination() -> Bool {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.prompt = L("Choose")
        panel.message = L("Choose the folder to move the files into")
        if let destination { panel.directoryURL = URL(fileURLWithPath: destination) }
        guard panel.runModal() == .OK, let url = panel.url else { return false }
        destination = url.standardizedFileURL.path
        if !demo { UserDefaults.standard.set(destination, forKey: "searchDestination") }
        return true
    }

    /// Asks for a destination first when none is set, or when the one remembered is gone.
    private func move() {
        if destination.map({ !FileManager.default.fileExists(atPath: $0) }) ?? true {
            guard chooseDestination() else { return }
        }
        guard let destination else { return }
        run(to: destination)
    }

    private func setAside() { run(to: nil) }

    /// Moves the ticked files to `destination`, or to the staging folder when it is nil.
    private func run(to destination: String?) {
        let paths = ticked.map(\.path)
        moving = (0, paths.count)
        Task {
            var done: [Renamer.Move] = [], failed = 0
            // In small batches, so the count in the footer moves along on a slow drive.
            for start in stride(from: 0, to: paths.count, by: 20) {
                let part = Array(paths[start..<min(start + 20, paths.count)])
                let outcome = await Task.detached {
                    destination.map { FileSearch.move(part, to: $0) } ?? FileSearch.setAside(part)
                }.value
                done += outcome.done
                failed += outcome.failures.count
                moving = (min(start + 20, paths.count), paths.count)
            }
            lastBatch = done
            FileSearch.saveLast(done)
            let gone = Set(done.map(\.from))
            matches.removeAll { gone.contains($0.path) }
            index?.removeAll { gone.contains($0.path) }
            moving = nil
            let place = destination.map { Paths.displayName($0) } ?? L("the staging folder")
            message = failed == 0
                ? L("Moved %ld files to %@.", done.count, place)
                : L("Moved %ld files to %@; %ld could not be moved.", done.count, place, failed)
        }
    }

    private func undo() {
        let batch = lastBatch
        moving = (0, batch.count)
        Task {
            let outcome = await Task.detached { Renamer.undo(batch) }.value
            lastBatch = []
            FileSearch.saveLast([])
            moving = nil
            await read()
            message = outcome.failures.isEmpty
                ? L("Moved %ld files back.", outcome.done.count)
                : L("Moved %ld files back; %ld could not be restored.", outcome.done.count, outcome.failures.count)
        }
    }
}
