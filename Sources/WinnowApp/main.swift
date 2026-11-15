import AppKit
import WinnowCore
import SwiftUI

let arguments = CommandLine.arguments
if let i = arguments.firstIndex(of: "--snapshot"), i + 1 < arguments.count {
    MainActor.assumeIsolated {
        Snapshot.run(to: URL(fileURLWithPath: arguments[i + 1]),
                     screen: ProcessInfo.processInfo.environment["WINNOW_SNAPSHOT_SCREEN"] ?? "dups")
    }
} else {
    WinnowApp.main()
}

struct WinnowApp: App {
    @State private var model = AppModel()

    var body: some Scene {
        Window("Winnow", id: "main") {
            ContentView()
                .environment(model)
                .frame(minWidth: 900, minHeight: 560)
        }
        .defaultSize(width: 1180, height: 760)

        Settings {
            SettingsView()
                .environment(model)
        }
    }
}

/// `WinnowApp --snapshot out.png` renders a screen with demo data offscreen and exits.
/// WINNOW_SNAPSHOT_SCREEN = new | rename | nested | search | scanning | dups | empty | sheet | settings-general | settings-scan. Needs no screen-recording permission.
@MainActor
enum Snapshot {
    static func run(to file: URL, screen: String) {
        let app = NSApplication.shared
        app.setActivationPolicy(.prohibited)
        let record = Demo.record()
        let model = AppModel(records: [record], draft: Demo.config)
        model.favorites = Demo.favorites()
        var size = NSSize(width: 1180, height: 760)
        let root: AnyView
        switch screen {
        case "new":
            model.route = .newScan
            root = AnyView(ContentView().environment(model))
        case "scanning":
            model.job = Demo.job()
            model.route = .scanning
            root = AnyView(ContentView().environment(model))
        case "rename":
            model.route = .rename
            root = AnyView(NavigationSplitView { Sidebar() } detail: { Demo.rename() }.environment(model))
        case "search":
            model.route = .search
            root = AnyView(NavigationSplitView { Sidebar() } detail: { Demo.search() }.environment(model))
        case "nested":
            model.route = .nested
            root = AnyView(NavigationSplitView { Sidebar() } detail: { Demo.nested() }.environment(model))
        case "empty":
            model.route = .result(record.id, .emptyFolders)
            root = AnyView(ContentView().environment(model))
        case "settings-general", "settings-scan":
            size = NSSize(width: 520, height: screen == "settings-general" ? 200 : 560)
            model.options.alwaysSkip = ["node_modules", "*.tmp"]
            root = AnyView(Group {
                if screen == "settings-general" { GeneralSettings() } else { ScanSettings() }
            }
            .environment(model)
            .background(Color(nsColor: .windowBackgroundColor)))
        case "sheet":
            size = NSSize(width: 540, height: 600)
            root = AnyView(ProcessSheet(id: record.id, preset: Demo.report(record)).environment(model)
                .background(Color(nsColor: .windowBackgroundColor)))
        default:
            model.route = .result(record.id, .duplicates)
            root = AnyView(ContentView().environment(model))
        }
        let host = NSHostingView(rootView: root)
        let window = NSWindow(contentRect: NSRect(origin: .zero, size: size), styleMask: [.titled], backing: .buffered, defer: false)
        window.appearance = NSAppearance(named: .aqua)
        window.contentView = host
        Task { @MainActor in
            host.layoutSubtreeIfNeeded()
            try? await Task.sleep(nanoseconds: 800_000_000)
            // WINNOW_SNAPSHOT_SET=key=1 flips a stored setting once the page is up, to check that it redraws.
            var restore: (() -> Void)?
            if let pair = ProcessInfo.processInfo.environment["WINNOW_SNAPSHOT_SET"]?.split(separator: "=", maxSplits: 1), pair.count == 2 {
                let key = String(pair[0]), old = UserDefaults.standard.object(forKey: key)
                UserDefaults.standard.set(pair[1] == "1", forKey: key)
                restore = { UserDefaults.standard.set(old, forKey: key) }
                try? await Task.sleep(nanoseconds: 800_000_000)
            }
            host.layoutSubtreeIfNeeded()
            if let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds) {
                host.cacheDisplay(in: host.bounds, to: rep)
                try? rep.representation(using: .png, properties: [:])?.write(to: file)
            }
            restore?()
            exit(0)
        }
        app.run()
    }
}

enum Demo {
    static let config = ScanConfig(locations: [Location(path: "/Volumes/hdd0"),
                                               Location(path: NSHomeDirectory() + "/Pictures", isReference: true)],
                                   kinds: [.photos, .videos], excluded: ["/Volumes/hdd0/Backups/Time Machine"])

    static func record() -> ScanRecord {
        let base: Int64 = 1_758_000_000
        func g(_ id: Int, _ name: String, _ size: UInt64, _ dirs: [String]) -> DupGroup {
            DupGroup(id: id, size: size, files: dirs.enumerated().map { i, d in
                FileEntry(path: "/Volumes/hdd0/\(d)/\(name)", size: size, modified: base + Int64(i * 86_400 * 12))
            })
        }
        var groups = [
            g(0, "Family Videos 2025.mov", 21_400_000_000, ["Videos/2025", "Backups/MacBook-2022/Movies", "Downloads"]),
            g(1, "Xcode_17.dmg", 11_900_000_000, ["Software", "Downloads"]),
            g(2, "Photos Library Backup.zip", 9_200_000_000, ["Backups", "Backups/Old"]),
            g(3, "Trip Raw Footage.mp4", 2_100_000_000, ["Videos/2026", "Downloads", "Backups/iPhone", "Desktop"]),
            g(4, "ubuntu-24.04.iso", 2_600_000_000, ["Software/OS", "Downloads", "Backups/Software"]),
            g(5, "Annual Report.pdf", 4_800_000, ["Documents/Work", "Downloads"])
        ]
        groups[5].files.append(FileEntry(path: NSHomeDirectory() + "/Pictures/Annual Report.pdf", size: 4_800_000,
                                         modified: base, isReference: true))
        var r = ScanRecord(config: config, groups: groups,
                           emptyFolders: ["Downloads/New Folder", "Backups/MacBook-2022/Movies/Empty", "Videos/2024/Unsorted"].map {
                               EmptyFolder(path: "/Volumes/hdd0/\($0)")
                           },
                           skipped: [SkippedItem(path: "/Volumes/hdd0/@eaDir", reason: "Permission denied (os error 13)")])
        Marking.apply(.oldest, to: &r)
        return r
    }

    static func rename() -> RenameView {
        let dir = "/Volumes/hdd0/Books"
        let names = ["【书香网】三体.epub", "【书香网】球状闪电.epub", "活着【书香网】.pdf", "【书香网】.pdf", "【书香网】围城.pdf"]
        var items = names.map { Renamer.Item(path: dir + "/" + $0, newName: Renamer.strip($0, removing: "【书香网】")) }
        items[3] = Renamer.Item(path: dir + "/" + names[3], newName: ".pdf", problem: .emptyName)
        items[4] = Renamer.Item(path: dir + "/Old/" + names[4], newName: "围城.pdf", problem: .nameTaken)
        return RenameView(folders: [dir], texts: ["【书香网】", "高清版", "www.example.com"], items: items, searched: true)
    }

    static func search() -> SearchView {
        let dir = "/Volumes/hdd0/Downloads"
        let names = ["流浪地球2.2023.BluRay/流浪地球2.mkv", "流浪地球2.2023.BluRay/流浪地球2.chs.srt", "年会录像/a.mp4", "年会录像/b.mp4",
                     "Trip/GoPro 0412.mp4", "Trip/GoPro 0413.mp4", "Trip/notes.txt", "三体全集/三体.epub", "Xcode_17/Xcode_17.dmg"]
        var files = names.map { FileSearch.File(path: "\(dir)/\($0)") }
        for i in [2, 3, 4] { files[i].include = true }
        return SearchView(folders: [dir], text: ".srt", kinds: [.videos], files: files, destination: "/Volumes/hdd0/影视")
    }

    static func favorites() -> [Favorite] {
        var downloads = Favorite(name: "Downloads", kind: .nested)
        downloads.folders = ["/Volumes/hdd0/Downloads"]
        var books = Favorite(name: "Books", kind: .rename)
        books.folders = ["/Volumes/hdd0/Books"]
        return [downloads, books]
    }

    static func nested() -> NestedFoldersView {
        let dir = "/Volumes/hdd0/Downloads"
        var items = [("三体全集", "三体全集"), ("Xcode_17", "Xcode"), ("课程资料-2025", "课程资料"), ("照片备份", "2024")].map {
            Unnester.Item(outer: "\(dir)/\($0.0)", inner: "\(dir)/\($0.0)/\($0.1)")
        }
        items[1].include = false
        items.append(Unnester.Item(outer: "\(dir)/流浪地球2.2023.BluRay", files: ["\(dir)/流浪地球2.2023.BluRay/movie.mkv"]))
        items.append(Unnester.Item(outer: "\(dir)/年会录像", files: ["a.mp4", "a.srt", "b.mp4", "说明.txt", "更多资源.url"].map { "\(dir)/年会录像/\($0)" },
                                   sizes: [900_000_000, 40_000, 700_000_000, 800, 200]))
        return NestedFoldersView(folders: [dir], items: items, searched: true, destination: "/Volumes/hdd0/整理")
    }

    static func job() -> Job {
        var p = ScanProgress()
        p.stage = .fullhash
        p.filesFound = 182_340
        p.done = 9_420
        p.total = 23_118
        p.bytesDone = 312_000_000_000
        p.bytesTotal = 760_000_000_000
        var job = Job(config: config)
        job.progress = p
        job.started = Date().addingTimeInterval(-3_100)
        job.speed = 96_000_000
        return job
    }

    static func report(_ record: ScanRecord) -> SafetyReport {
        var r = SafetyReport()
        r.items = Processor.plan(record)
        r.changed = ["/Volumes/hdd0/Downloads/Xcode_17.dmg"]
        return r
    }
}
