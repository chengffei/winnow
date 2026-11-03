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
    }
}

/// `WinnowApp --snapshot out.png` renders a screen with demo data offscreen and exits.
/// WINNOW_SNAPSHOT_SCREEN = new | scanning | dups | empty | sheet. Needs no screen-recording permission.
@MainActor
enum Snapshot {
    static func run(to file: URL, screen: String) {
        let app = NSApplication.shared
        app.setActivationPolicy(.prohibited)
        let record = Demo.record()
        let model = AppModel(records: [record], draft: Demo.config)
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
        case "empty":
            model.route = .result(record.id, .emptyFolders)
            root = AnyView(ContentView().environment(model))
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
            host.layoutSubtreeIfNeeded()
            if let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds) {
                host.cacheDisplay(in: host.bounds, to: rep)
                try? rep.representation(using: .png, properties: [:])?.write(to: file)
            }
            exit(0)
        }
        app.run()
    }
}

enum Demo {
    static let config = ScanConfig(locations: [Location(path: "/Volumes/hdd0"),
                                               Location(path: NSHomeDirectory() + "/Pictures", isReference: true)],
                                   kinds: [.photos, .videos], excluded: ["/Volumes/hdd0/备份/Time Machine"])

    static func record() -> ScanRecord {
        let base: Int64 = 1_758_000_000
        func g(_ id: Int, _ name: String, _ size: UInt64, _ dirs: [String]) -> DupGroup {
            DupGroup(id: id, size: size, files: dirs.enumerated().map { i, d in
                FileEntry(path: "/Volumes/hdd0/\(d)/\(name)", size: size, modified: base + Int64(i * 86_400 * 12))
            })
        }
        var groups = [
            g(0, "婚礼全程.mov", 21_400_000_000, ["影像/2025/婚礼", "备份/MacBook-2022/Movies", "下载"]),
            g(1, "Xcode_17.dmg", 11_900_000_000, ["软件", "下载"]),
            g(2, "Photos Library 备份.zip", 9_200_000_000, ["备份", "备份/旧"]),
            g(3, "南京 vlog 原片.mp4", 2_100_000_000, ["影像/2026/南京", "下载", "备份/iPhone", "桌面"]),
            g(4, "ubuntu-24.04.iso", 2_600_000_000, ["软件/系统", "下载", "备份/软件"]),
            g(5, "年度报告.pdf", 4_800_000, ["文档/工作", "下载"])
        ]
        groups[5].files.append(FileEntry(path: NSHomeDirectory() + "/Pictures/年度报告.pdf", size: 4_800_000,
                                         modified: base, isReference: true))
        var r = ScanRecord(config: config, groups: groups,
                           emptyFolders: ["下载/新建文件夹", "备份/MacBook-2022/Movies/空", "影像/2024/未整理"].map {
                               EmptyFolder(path: "/Volumes/hdd0/\($0)")
                           },
                           skipped: [SkippedItem(path: "/Volumes/hdd0/@eaDir", reason: "Permission denied (os error 13)")])
        Marking.apply(.oldest, to: &r)
        return r
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
        r.changed = ["/Volumes/hdd0/下载/Xcode_17.dmg"]
        return r
    }
}
