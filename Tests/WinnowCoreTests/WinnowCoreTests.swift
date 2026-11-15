import XCTest
@testable import WinnowCore

final class ParserTests: XCTestCase {
    func testProgressLines() {
        var p = ProgressParser()
        p.feed("\u{1B}[2KScanning size of \u{2068}18647\u{2069} file \u{1B}[34m\u{2588}\u{1B}[0m\r")
        XCTAssertEqual(p.progress.filesFound, 18647)
        XCTAssertEqual(p.progress.stage, .collecting)
        p.feed("\u{1B}[2KAnalyzed partial hash of \u{2068}5579/6544\u{2069} files (\u{2068}43.59 MiB / 51.12 MiB\u{2069}) [====>  ]\r")
        XCTAssertEqual(p.progress.stage, .prehash)
        XCTAssertEqual(p.progress.done, 5579)
        XCTAssertEqual(p.progress.total, 6544)
        XCTAssertEqual(p.progress.bytesTotal, UInt64(51.12 * 1024 * 1024))
        p.feed("\u{1B}[2KAnalyzed full hash of \u{2068}0/5054\u{2069} files (\u{2068}0 B / 498.73 MiB\u{2069}) [   ]\r")
        XCTAssertEqual(p.progress.stage, .fullhash)
        XCTAssertEqual(p.progress.bytesDone, 0)
        p.feed("\u{1B}[2KLoading hash cache \u{1B}[34m\u{2588}\u{1B}[0m\r")
        XCTAssertEqual(p.progress.note, "Loading hash cache \u{2588}")
    }

    func testWarnings() {
        var p = ProgressParser()
        p.feed("-----WARNINGS-----\nCannot open dir \u{2068}/x/noperm\u{2069}, reason \u{2068}Permission denied (os error 13)\u{2069}\n---END OF WARNINGS---\nScanning size of 3 file\n")
        p.finish()
        XCTAssertEqual(p.skipped, [SkippedItem(path: "/x/noperm", reason: "Permission denied (os error 13)")])
        XCTAssertEqual(p.progress.filesFound, 3)
    }

    func testDuplicateFormats() throws {
        let config = ScanConfig(locations: [Location(path: "/a"), Location(path: "/ref", isReference: true)])
        let hash = #"{"5":[[{"path":"/a/1","modified_date":10,"size":5},{"path":"/a/2","modified_date":20,"size":5}],[{"path":"/ref/1","modified_date":1,"size":5},{"path":"/ref/2","modified_date":1,"size":5}]]}"#
        let g = try ResultParser.duplicates(Data(hash.utf8), config: config)
        XCTAssertEqual(g.count, 1, "groups made only of reference copies are dropped")
        XCTAssertEqual(g[0].files.map(\.path), ["/a/1", "/a/2"])

        let sizeName = #"[[{"path":"/a/x","modified_date":1,"size":9},{"path":"/ref/x","modified_date":2,"size":9}]]"#
        let s = try ResultParser.duplicates(Data(sizeName.utf8), config: config)
        XCTAssertEqual(s[0].files.filter(\.isReference).map(\.path), ["/ref/x"])

        let nested = #"{"9":[[{"path":"/ref/z","modified_date":1,"size":9},[{"path":"/a/z","modified_date":1,"size":9}]]]}"#
        XCTAssertEqual(try ResultParser.duplicates(Data(nested.utf8), config: config)[0].files.count, 2)

        let empty = #"["/a/e", "/ref/e"]"#
        XCTAssertEqual(try ResultParser.emptyFolders(Data(empty.utf8), config: config).map(\.path), ["/a/e"])
    }
}

final class MarkingTests: XCTestCase {
    func group(_ files: [FileEntry]) -> DupGroup { DupGroup(id: 0, size: 1, files: files) }

    func testRules() {
        var g = group([
            FileEntry(path: "/v/a/b/c/new", size: 1, modified: 30),
            FileEntry(path: "/v/old", size: 1, modified: 10),
            FileEntry(path: "/v/p/mid", size: 1, modified: 20)
        ])
        Marking.apply(.oldest, to: &g)
        XCTAssertEqual(g.files.filter { $0.mark == .keep }.map(\.path), ["/v/old"])
        Marking.apply(.newest, to: &g)
        XCTAssertEqual(g.files.filter { $0.mark == .keep }.map(\.path), ["/v/a/b/c/new"])
        Marking.apply(.preferFolder("/v/p"), to: &g)
        XCTAssertEqual(g.files.filter { $0.mark == .keep }.map(\.path), ["/v/p/mid"])
        XCTAssertEqual(g.reclaimable, 2)
    }

    func testReferenceAndManualEdits() {
        var g = group([
            FileEntry(path: "/ref/x", size: 1, modified: 99, isReference: true),
            FileEntry(path: "/a/x", size: 1, modified: 1)
        ])
        Marking.apply(.oldest, to: &g)
        XCTAssertEqual(g.files.map(\.mark), [.keep, .delete])
        XCTAssertFalse(Marking.set(.delete, path: "/ref/x", in: &g))

        var h = group([FileEntry(path: "/a", size: 1, modified: 1), FileEntry(path: "/b", size: 1, modified: 2)])
        Marking.apply(.oldest, to: &h)
        XCTAssertFalse(Marking.set(.delete, path: "/a", in: &h), "the last kept copy cannot be marked")
        XCTAssertTrue(Marking.set(.keep, path: "/b", in: &h))
        XCTAssertTrue(h.edited)
        Marking.apply(.newest, to: &h)
        XCTAssertEqual(h.files.map(\.mark), [.keep, .keep], "edited groups are left alone")
    }
}

final class ProcessorTests: XCTestCase {
    var root: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("winnow-test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        root = URL(fileURLWithPath: ScanRunner.realPath(root.path))
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    func write(_ rel: String, _ bytes: Data) throws -> String {
        let url = root.appendingPathComponent(rel)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try bytes.write(to: url)
        return url.path
    }

    /// Full path through the real CLI: scan, auto-mark, check, stage into a fake home, restore.
    func testScanStageRestore() async throws {
        try XCTSkipIf(ScanRunner.locateCLI() == nil, "czkawka_cli not installed")
        let blob = Data((0..<20000).map { UInt8($0 % 251) })
        let a = try write("data/a/x.bin", blob)
        _ = try write("data/b/x.bin", blob)
        _ = try write("data/b/sub/x.bin", blob)
        let refBlob = Data((0..<30000).map { UInt8($0 % 241) })
        _ = try write("ref/z.bin", refBlob)
        let z = try write("data/a/z.bin", refBlob)
        try FileManager.default.createDirectory(at: root.appendingPathComponent("data/empty/inner"), withIntermediateDirectories: true)
        // Our own staging folders must never be scanned.
        _ = try write("data/\(Processor.stagingPrefix)2026-01-01/x.bin", blob)

        let config = ScanConfig(locations: [Location(path: root.path + "/data"),
                                            Location(path: root.path + "/ref", isReference: true)])
        var record = try await ScanRunner().run(config) { _ in }
        XCTAssertEqual(record.groups.count, 2)
        XCTAssertEqual(record.emptyFolders.map(\.path), [root.path + "/data/empty"])
        let zGroup = record.groups.first { $0.size == 30000 }!
        XCTAssertEqual(zGroup.files.first { $0.path == z }?.mark, .delete, "copy of a reference file is marked")
        XCTAssertEqual(record.markedFiles, 3)

        // A marked file edited after the scan is skipped.
        let xGroup = record.groups.first { $0.size == 20000 }!
        let marked = xGroup.files.first { $0.mark == .delete }!.path
        try Data("changed".utf8).write(to: URL(fileURLWithPath: marked))
        var report = Processor.check(record)
        XCTAssertFalse(report.blocking)
        XCTAssertEqual(report.changed, [marked])
        XCTAssertEqual(report.items.count, 3, "2 files + 1 folder")

        let home = root.path + "/home"
        let outcome = Processor.execute(.stage, items: report.items, home: home)
        XCTAssertTrue(outcome.failures.isEmpty, "\(outcome.failures)")
        XCTAssertTrue(outcome.stagingRoots.allSatisfy { $0.hasPrefix(home + "/" + Processor.stagingPrefix) })
        XCTAssertTrue(FileManager.default.fileExists(atPath: a), "oldest copy kept")
        XCTAssertFalse(FileManager.default.fileExists(atPath: z))
        Processor.applyOutcome(outcome, to: &record)
        XCTAssertEqual(record.groups.count, 1)
        XCTAssertEqual(record.moves.count, 3)

        let back = Processor.restore(record.moves)
        XCTAssertTrue(back.failures.isEmpty)
        XCTAssertTrue(FileManager.default.fileExists(atPath: z))
        XCTAssertTrue(FileManager.default.fileExists(atPath: root.path + "/data/empty"))
        report = Processor.check(record)
        _ = report
    }

    func testStagingTargetOnHome() {
        let t = Processor.stagingTarget(for: "/Users/x/Movies/a.mov", date: Date(timeIntervalSince1970: 0), home: "/Users/x")
        XCTAssertEqual(t.root, "/Users/x/\(Processor.stagingPrefix)1970-01-01")
        XCTAssertEqual(t.target, t.root + "/Movies/a.mov")
    }
}

final class ConditionTests: XCTestCase {
    func testOldConfigStillLoads() throws {
        let old = #"{"locations":[{"path":"/a","isReference":false}],"tools":["duplicates"],"method":"hash"}"#
        let c = try JSONDecoder().decode(ScanConfig.self, from: Data(old.utf8))
        XCTAssertEqual(c.minSize, ScanConfig.defaultMinSize)
        XCTAssertTrue(c.kinds.isEmpty)
        XCTAssertTrue(c.excluded.isEmpty)
    }

    func testArguments() {
        let c = ScanConfig(locations: [Location(path: "/v")], minSize: 1 << 20, kinds: [.music], excluded: ["/v/skip"])
        let dup = ScanRunner.arguments(.duplicates, config: c, output: "/o.json")
        XCTAssertTrue(dup.contains("1048576"))
        XCTAssertEqual(dup[dup.firstIndex(of: "-x")! + 1], FileKind.music.extensions.joined(separator: ","))
        XCTAssertEqual(dup[dup.firstIndex(of: "-e")! + 1], "/v/skip")
        let empty = ScanRunner.arguments(.emptyFolders, config: c, output: "/o.json")
        XCTAssertFalse(empty.contains("-x"), "size and kinds only apply to duplicates")
        XCTAssertTrue(empty.contains("/v/skip"))
        XCTAssertEqual(c.excluded(in: "/v"), ["/v/skip"])
        XCTAssertEqual(c.excluded(in: "/w"), [])
        XCTAssertTrue(dup.contains("-u"))
        XCTAssertFalse(dup.contains("-T"))
    }

    func testOptions() throws {
        let c = ScanConfig(locations: [Location(path: "/v")])
        let o = ScanOptions(speed: .minimal, useCache: false, alwaysSkip: ["node_modules", "*.tmp", " "])
        XCTAssertEqual(o.skipPatterns, ["*/node_modules", "*/node_modules/*", "*.tmp"])
        let dup = ScanRunner.arguments(.duplicates, config: c, options: o, output: "/o.json")
        XCTAssertEqual(dup[dup.firstIndex(of: "-T")! + 1], "1")
        XCTAssertTrue(dup.contains("-H"))
        XCTAssertFalse(dup.contains("-u"))
        XCTAssertTrue(dup.contains("*/node_modules/*"))
        let empty = ScanRunner.arguments(.emptyFolders, config: c, options: o, output: "/o.json")
        XCTAssertTrue(empty.contains("*.tmp"))
        XCTAssertFalse(empty.contains("-H"))
        let old = try JSONDecoder().decode(ScanOptions.self, from: Data("{}".utf8))
        XCTAssertEqual(old, ScanOptions())
    }

    /// Real CLI: only photos, nothing under 8 KB, one folder skipped.
    func testConditionsWithCLI() async throws {
        try XCTSkipIf(ScanRunner.locateCLI() == nil, "czkawka_cli not installed")
        var root = FileManager.default.temporaryDirectory.appendingPathComponent("winnow-cond-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        root = URL(fileURLWithPath: ScanRunner.realPath(root.path))
        defer { try? FileManager.default.removeItem(at: root) }
        func put(_ rel: String, _ data: Data) throws {
            let u = root.appendingPathComponent(rel)
            try FileManager.default.createDirectory(at: u.deletingLastPathComponent(), withIntermediateDirectories: true)
            try data.write(to: u)
        }
        let big = Data((0..<20000).map { UInt8($0 % 251) })
        let big2 = Data((0..<20000).map { UInt8($0 % 239) })
        let small = Data((0..<3000).map { UInt8($0 % 233) })
        try put("a/p.JPG", big); try put("b/p.JPG", big)
        try put("a/v.mov", big2); try put("b/v.mov", big2)
        try put("a/s.jpg", small); try put("b/s.jpg", small)
        try put("skip/p.JPG", big)
        let config = ScanConfig(locations: [Location(path: root.path)], tools: [.duplicates],
                                kinds: [.photos], excluded: [root.path + "/skip"])
        let record = try await ScanRunner().run(config) { _ in }
        XCTAssertEqual(record.groups.count, 1)
        XCTAssertEqual(Set(record.groups[0].files.map { ($0.path as NSString).lastPathComponent }), ["p.JPG"])
        XCTAssertEqual(record.groups[0].files.count, 2, "the excluded folder is skipped")
    }
}

final class RenamerTests: XCTestCase {
    var root: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("winnow-rename-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root.appendingPathComponent("sub"), withIntermediateDirectories: true)
        root = URL(fileURLWithPath: ScanRunner.realPath(root.path))
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    func touch(_ rel: String) { FileManager.default.createFile(atPath: root.appendingPathComponent(rel).path, contents: Data("x".utf8)) }
    func exists(_ rel: String) -> Bool { FileManager.default.fileExists(atPath: root.appendingPathComponent(rel).path) }

    func testStrip() {
        XCTAssertEqual(Renamer.strip("【网】三体.epub", removing: "【网】"), "三体.epub")
        XCTAssertEqual(Renamer.strip("三体 www.x.com .pdf", removing: "www.x.com"), "三体.pdf")
        XCTAssertEqual(Renamer.strip("a-AD-b-AD", removing: "-AD"), "a-b")
        XCTAssertEqual(Renamer.strip("AD.pdf", removing: "AD"), ".pdf")
        XCTAssertEqual(Renamer.strip("【书香网】三体 高清版.pdf", removing: ["书香网", "高清版", "【书香网】"]), "三体.pdf")
    }

    func testPlanApplyUndo() throws {
        touch("【网】a.txt"); touch("sub/【网】b.txt"); touch("sub/b.txt")      // b is taken on disk
        touch("【网】c.txt"); touch("c【网】.txt")                              // both would become c.txt
        touch("【网】.txt"); touch(".【网】hidden"); touch("plain.txt")
        try FileManager.default.createDirectory(at: root.appendingPathComponent("【网】folder"), withIntermediateDirectories: true)

        let items = Renamer.plan(roots: [root.path], text: "【网】")
        let byName = Dictionary(uniqueKeysWithValues: items.map { ($0.oldName, $0) })
        XCTAssertEqual(Set(byName.keys), ["【网】a.txt", "【网】b.txt", "【网】c.txt", "c【网】.txt", "【网】.txt"], "no folders, no hidden files")
        XCTAssertNil(byName["【网】a.txt"]?.problem)
        XCTAssertEqual(byName["【网】b.txt"]?.problem, .nameTaken)
        XCTAssertEqual(byName["【网】c.txt"]?.problem, .nameTaken)
        XCTAssertEqual(byName["c【网】.txt"]?.problem, .nameTaken)
        XCTAssertEqual(byName["【网】.txt"]?.problem, .emptyName)
        XCTAssertEqual(Renamer.plan(roots: [root.path], text: "【网】", subfolders: false).count, 4)
        touch("plain-AD.txt")
        XCTAssertEqual(Renamer.plan(roots: [root.path], texts: ["【网】", "-AD", ""]).count, 6, "a name with any of the texts is found")
        try FileManager.default.removeItem(at: root.appendingPathComponent("plain-AD.txt"))

        let outcome = Renamer.apply(items)
        XCTAssertEqual(outcome.done.count, 1)
        XCTAssertTrue(exists("a.txt")); XCTAssertFalse(exists("【网】a.txt"))
        XCTAssertTrue(exists("sub/【网】b.txt"), "blocked items are untouched")

        // Things that change after the preview are skipped, and the rest of the batch still runs.
        touch("x【网】.txt"); touch("y【网】.txt")
        let later = Renamer.plan(roots: [root.path], text: "【网】").filter { $0.oldName.hasPrefix("x") || $0.oldName.hasPrefix("y") }
        try FileManager.default.removeItem(atPath: root.appendingPathComponent("x【网】.txt").path)
        touch("y.txt")
        let skipped = Renamer.apply(later)
        XCTAssertEqual(skipped.done.count, 0)
        XCTAssertEqual(skipped.failures.count, 2)
        XCTAssertTrue(exists("y【网】.txt"))

        let back = Renamer.undo(outcome.done)
        XCTAssertEqual(back.done.count, 1)
        XCTAssertTrue(exists("【网】a.txt")); XCTAssertFalse(exists("a.txt"))
    }
}

extension UnnesterTests {
    /// A network drive usually has no Trash: emptied folders are deleted, and Undo makes them again.
    func testDriveWithoutTrash() throws {
        Unnester.usesTrash = false
        defer { Unnester.usesTrash = true }
        dir("nas/Wrap/Inner"); touch("nas/Wrap/Inner/f.txt"); touch("nas/Wrap/.DS_Store")   // inner takes the outer's name
        dir("nas/One"); touch("nas/One/x.mkv")
        dir("nas/Kept"); touch("nas/Kept/y.mkv"); touch("nas/Kept/.nomedia")                 // a hidden file of the user's
        dir("nas/Held/Sub"); touch("nas/Held/Sub/f.txt"); touch("nas/Held/.nomedia")

        let batch = Unnester.apply(Unnester.plan(roots: [p("nas")], maxFiles: 1), trashEmptied: true, rename: true)
        XCTAssertTrue(exists("nas/Wrap/f.txt"), "Inner is now called Wrap")
        XCTAssertFalse(exists("nas/Wrap/Inner"))
        XCTAssertTrue(exists("nas/One.mkv"))
        var isDir: ObjCBool = false
        XCTAssertFalse(exists("nas/One"), "the emptied folder is deleted")
        XCTAssertTrue(exists("nas/Kept.mkv")); XCTAssertTrue(exists("nas/Kept/.nomedia"), "a folder with a hidden file of the user's stays")
        XCTAssertEqual(batch.failures, [p("nas/Held/Sub")]); XCTAssertEqual(batch.reasons, [.refused])
        XCTAssertTrue(exists("nas/Held/Sub/f.txt"), "put back when its folder could not go")
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: p("nas")).filter { $0.contains(".winnow-") }, [])

        let back = Unnester.undo(batch)
        XCTAssertTrue(back.failures.isEmpty, "\(back.failures)")
        XCTAssertTrue(exists("nas/Wrap/Inner/f.txt")); XCTAssertTrue(exists("nas/One/x.mkv")); XCTAssertTrue(exists("nas/Kept/y.mkv"))
        XCTAssertTrue(FileManager.default.fileExists(atPath: p("nas/One"), isDirectory: &isDir) && isDir.boolValue)
    }
}

extension UnnesterTests {
    func write(_ rel: String, bytes: Int) {
        let url = root.appendingPathComponent(rel)
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        FileManager.default.createFile(atPath: url.path, contents: Data(count: bytes))
    }

    /// One big file with subtitles and clutter: the file takes the folder's name, subtitles follow, clutter is staged.
    func testMainFileAndExtras() throws {
        write("dl/Film.2023/abc.mkv", bytes: 50_000); write("dl/Film.2023/abc.srt", bytes: 300); write("dl/Film.2023/ABC.chs.srt", bytes: 300)
        write("dl/Film.2023/visit-us.url", bytes: 50); write("dl/Film.2023/readme.txt", bytes: 80)
        write("dl/Show/e1.mkv", bytes: 40_000); write("dl/Show/e2.mkv", bytes: 45_000); write("dl/Show/e2.srt", bytes: 100); write("dl/Show/ad.jpg", bytes: 900)
        write("dl/Same/a.txt", bytes: 100); write("dl/Same/b.txt", bytes: 120)                 // no small file: both are main

        let items = Unnester.plan(roots: [p("dl")], maxFiles: 10)
        XCTAssertEqual(items.map(\.outer), [p("dl/Film.2023"), p("dl/Same"), p("dl/Show")])
        let film = items[0], show = items[2]
        XCTAssertEqual(film.extras, [p("dl/Film.2023/readme.txt"), p("dl/Film.2023/visit-us.url")])
        XCTAssertEqual(Unnester.names(for: film, rename: true, setAside: true).sorted(), ["Film.2023.chs.srt", "Film.2023.mkv", "Film.2023.srt"])
        XCTAssertEqual(Unnester.names(for: show, rename: true, setAside: true), ["Show 1.mkv", "Show 2.mkv", "Show 2.srt"])
        XCTAssertEqual(Unnester.names(for: show, rename: true), ["Show 3.jpg", "Show 1.mkv", "Show 2.mkv", "Show 2.srt"], "kept extras are numbered after the main files")
        XCTAssertEqual(Unnester.names(for: items[1], rename: true, setAside: true), ["Same 1.txt", "Same 2.txt"])
        XCTAssertEqual(Unnester.names(for: film, rename: false, setAside: true).count, 3)

        let home = p("home")
        let batch = Unnester.apply(items, trashEmptied: true, rename: true, setAside: true, home: home)
        XCTAssertTrue(batch.failures.isEmpty, "\(batch.reasons ?? [])")
        XCTAssertTrue(exists("dl/Film.2023.mkv")); XCTAssertTrue(exists("dl/Film.2023.srt")); XCTAssertTrue(exists("dl/Film.2023.chs.srt"))
        XCTAssertTrue(exists("dl/Show 2.srt")); XCTAssertFalse(exists("dl/Film.2023")); XCTAssertFalse(exists("dl/Show"))
        XCTAssertEqual(batch.aside?.count, 3)
        XCTAssertTrue(batch.aside!.allSatisfy { $0.to.contains(Processor.stagingPrefix) && FileManager.default.fileExists(atPath: $0.to) })
        XCTAssertTrue(batch.aside!.contains { $0.to.hasSuffix("/dl/Film.2023/readme.txt") }, "staged files keep their folder structure")

        let back = Unnester.undo(batch)
        XCTAssertTrue(back.failures.isEmpty, "\(back.failures)")
        for f in ["dl/Film.2023/abc.mkv", "dl/Film.2023/ABC.chs.srt", "dl/Film.2023/visit-us.url", "dl/Show/ad.jpg", "dl/Same/b.txt"] {
            XCTAssertTrue(exists(f), f)
        }
    }
}

final class SuggestionTests: XCTestCase {
    func testClutterIsFound() {
        var names = (1...6).map { "【书香网】Book \($0) www.example.com.epub" }
        names += (1...5).map { "Trip \($0)-HD.mp4" }
        names += ["notes.txt", "[once] only.txt"]
        let found = Suggestions.find(in: names)
        XCTAssertEqual(found.prefix(2).map(\.text).sorted(), ["www.example.com", "【书香网】"])
        XCTAssertEqual(found.first?.count, 6)
        XCTAssertTrue(found.contains { $0.text == "-HD" && $0.count == 5 })
        XCTAssertFalse(found.contains { $0.text.contains("once") }, "a text in one name is not clutter")
    }
}

final class QuickScanTests: XCTestCase {
    /// The quick scan must find exactly what the engine finds by size and name.
    func testMatchesTheEngine() async throws {
        guard ScanRunner.locateCLI() != nil else { throw XCTSkip("czkawka_cli not found") }
        var root = FileManager.default.temporaryDirectory.appendingPathComponent("winnow-quick-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        root = URL(fileURLWithPath: ScanRunner.realPath(root.path))
        defer { try? FileManager.default.removeItem(at: root) }
        func write(_ rel: String, _ bytes: Int) {
            let url = root.appendingPathComponent(rel)
            try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            FileManager.default.createFile(atPath: url.path, contents: Data(count: bytes))
        }
        write("a/clip.mp4", 20_000); write("b/clip.mp4", 20_000); write("c/deep/clip.mp4", 20_000)
        write("a/clip.mov", 20_000)                                     // same size, other name
        write("a/doc.pdf", 9_000); write("b/doc.pdf", 9_001)            // same name, other size
        write("a/small.txt", 100); write("b/small.txt", 100)            // under the minimum
        write("a/pic.jpg", 30_000); write("skip/pic.jpg", 30_000)       // excluded folder
        write("a/song.mp3", 12_000); write("b/node_modules/song.mp3", 12_000); write("ref/song.mp3", 12_000)

        var config = ScanConfig(locations: [Location(path: root.appendingPathComponent("a").path), Location(path: root.appendingPathComponent("b").path),
                                            Location(path: root.appendingPathComponent("c").path), Location(path: root.appendingPathComponent("skip").path),
                                            Location(path: root.appendingPathComponent("ref").path, isReference: true)],
                                tools: [.duplicates], method: .sizeName, excluded: [root.appendingPathComponent("skip").path])
        let options = ScanOptions(alwaysSkip: ["node_modules"])
        func shape(_ groups: [DupGroup]) -> Set<[String]> { Set(groups.map { $0.files.map { "\($0.path) \($0.size) \($0.isReference)" } }) }

        let quick = QuickScan.duplicates(config, options: options)
        XCTAssertEqual(quick.groups.count, 2)
        // Ask the engine itself, not the runner, which now takes the quick path for this method.
        let out = root.appendingPathComponent("dup.json")
        let p = Process()
        p.executableURL = ScanRunner.locateCLI()
        p.arguments = ScanRunner.arguments(.duplicates, config: config, options: options, output: out.path)
        p.standardOutput = FileHandle.nullDevice; p.standardError = FileHandle.nullDevice
        try p.run(); p.waitUntilExit()
        let engine = try ResultParser.duplicates(Data(contentsOf: out), config: config)
        XCTAssertEqual(shape(quick.groups), shape(engine))
        let times = Dictionary(uniqueKeysWithValues: engine.flatMap(\.files).map { ($0.path, $0.modified) })
        for f in quick.groups.flatMap(\.files) { XCTAssertEqual(f.modified, times[f.path], f.path) }

        config.kinds = [.music]
        XCTAssertEqual(QuickScan.duplicates(config, options: options).groups.map(\.name), ["song.mp3"])
        let record = try await ScanRunner().run(config, options: options) { _ in }
        XCTAssertEqual(record.groups.map(\.name), ["song.mp3"])
    }
}

final class FileSearchTests: XCTestCase {
    var root: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("winnow-search-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        root = URL(fileURLWithPath: ScanRunner.realPath(root.path))
    }

    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: root) }

    func touch(_ rel: String) {
        let url = root.appendingPathComponent(rel)
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        FileManager.default.createFile(atPath: url.path, contents: Data(rel.utf8))
    }
    func exists(_ rel: String) -> Bool { FileManager.default.fileExists(atPath: root.appendingPathComponent(rel).path) }
    func p(_ rel: String) -> String { root.appendingPathComponent(rel).path }

    func testFindMoveUndo() throws {
        for f in ["src/A/Movie One.MKV", "src/A/movie one.srt", "src/B/clip.mp4", "src/B/clip.txt", "src/B/Café.pdf",
                  "src/.hidden.mkv", "src/@eaDir/thumb.mkv", "src/C/clip.mp4", "dest/clip.mp4"] { touch(f) }
        let all = FileSearch.index(roots: [p("src")])
        XCTAssertEqual(all.count, 6, "hidden files and NAS housekeeping folders are left out")
        XCTAssertTrue(FileSearch.index(roots: [p("src")], subfolders: false).isEmpty)

        func names(_ text: String, _ kinds: Set<FileKind> = []) -> [String] {
            FileSearch.filter(all, FileSearch.Query(text: text, kinds: kinds)).map(\.name).sorted()
        }
        XCTAssertEqual(names(""), [], "nothing is listed until something is asked for")
        XCTAssertEqual(names("ONE movie"), ["Movie One.MKV", "movie one.srt"], "every word, any case, any order")
        XCTAssertEqual(names("cafe"), ["Café.pdf"])
        XCTAssertEqual(names(".mkv"), ["Movie One.MKV"])
        XCTAssertEqual(names("*.srt", [.videos]), ["Movie One.MKV", "clip.mp4", "clip.mp4", "movie one.srt"], "types add up")
        XCTAssertEqual(names("clip", [.videos]), ["clip.mp4", "clip.mp4"])
        XCTAssertEqual(names("1.5"), [], "a word with a dot inside is part of a name, not an extension")

        let out = FileSearch.move([p("src/B/clip.mp4"), p("src/C/clip.mp4"), p("src/A/Movie One.MKV"), p("dest/clip.mp4"), p("src/gone.mp4")], to: p("dest"))
        XCTAssertEqual(out.done.map(\.to), [p("dest/clip 2.mp4"), p("dest/clip 3.mp4"), p("dest/Movie One.MKV")])
        XCTAssertEqual(out.failures, [p("src/gone.mp4")])
        XCTAssertEqual(try String(contentsOfFile: p("dest/clip.mp4")), "dest/clip.mp4", "the file already there is untouched")
        XCTAssertFalse(exists("src/B/clip.mp4"))

        let back = Renamer.undo(out.done)
        XCTAssertTrue(back.failures.isEmpty)

        let staged = FileSearch.setAside([p("src/B/clip.txt"), p("src/gone.txt")], home: p("home"))
        XCTAssertEqual(staged.failures, [p("src/gone.txt")])
        XCTAssertTrue(staged.done[0].to.contains(Processor.stagingPrefix) && staged.done[0].to.hasSuffix("/src/B/clip.txt"))
        XCTAssertTrue(Renamer.undo(staged.done).failures.isEmpty); XCTAssertTrue(exists("src/B/clip.txt"))
        XCTAssertTrue(exists("src/B/clip.mp4")); XCTAssertTrue(exists("src/C/clip.mp4")); XCTAssertTrue(exists("src/A/Movie One.MKV"))
        XCTAssertFalse(exists("dest/clip 2.mp4"))
    }
}

final class FavoriteTests: XCTestCase {
    func testRoundTrip() throws {
        var scan = Favorite(name: "NAS", kind: .scan)
        scan.scan = ScanConfig(locations: [Location(path: "/Volumes/hdd0")], minSize: 1 << 20)
        var nested = Favorite(name: "Downloads", kind: .nested)
        nested.folders = ["/Volumes/hdd0/Downloads"]; nested.maxFiles = 3; nested.takeFolderName = true
        nested.trashEmptied = false; nested.destination = "/Volumes/hdd0/Sorted"
        let back = try JSONDecoder().decode([Favorite].self, from: JSONEncoder().encode([scan, nested]))
        XCTAssertEqual(back, [scan, nested])
        // A favorite saved before Find Files existed has no `kinds`.
        let old = #"[{"id":"7B0A3B5E-0000-4000-8000-000000000001","name":"Books","kind":"rename","folders":["/b"],"texts":["x"],"subfolders":false,"maxFiles":1,"takeFolderName":false,"trashEmptied":true}]"#
        let loaded = try JSONDecoder().decode([Favorite].self, from: Data(old.utf8))
        XCTAssertEqual(loaded[0].texts, ["x"]); XCTAssertEqual(loaded[0].kinds, []); XCTAssertFalse(loaded[0].subfolders)
    }
}

final class UnnesterTests: XCTestCase {
    var root: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("winnow-unnest-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        root = URL(fileURLWithPath: ScanRunner.realPath(root.path))
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    func dir(_ rel: String) { try? FileManager.default.createDirectory(at: root.appendingPathComponent(rel), withIntermediateDirectories: true) }
    func touch(_ rel: String) { FileManager.default.createFile(atPath: root.appendingPathComponent(rel).path, contents: Data("x".utf8)) }
    func exists(_ rel: String) -> Bool { FileManager.default.fileExists(atPath: root.appendingPathComponent(rel).path) }
    func p(_ rel: String) -> String { root.appendingPathComponent(rel).path }

    func testPlanMoveUndo() throws {
        dir("src/A/B"); touch("src/A/B/f.txt"); touch("src/A/.DS_Store")    // hidden files do not count
        dir("src/C/D/E"); touch("src/C/D/E/f.txt")                          // chain: only C is listed
        dir("src/F/G"); touch("src/F/note.txt")                             // has a file too
        dir("src/H/I"); dir("src/H/J")                                      // two folders
        dir("src/K/L"); dir("dest/L")                                       // name taken in destination
        dir("src/M/N"); dir("src/M/N.app")                                  // a package counts as content
        dir("dest/keep")

        let items = Unnester.plan(roots: [p("src")])
        XCTAssertEqual(items.map(\.outer), [p("src/A"), p("src/C"), p("src/K")])
        XCTAssertEqual(items[1].inner, p("src/C/D"))
        XCTAssertTrue(Unnester.plan(roots: [p("src/A")]).isEmpty, "the location itself is not listed")

        let batch = Unnester.apply(items, to: p("dest"), trashEmptied: true)
        XCTAssertEqual(batch.moves.map(\.to), [p("dest/B"), p("dest/D")])
        XCTAssertEqual(batch.failures, [p("src/K/L")])
        XCTAssertTrue(exists("dest/B/f.txt")); XCTAssertTrue(exists("dest/D/E/f.txt"))
        XCTAssertFalse(exists("src/C"), "emptied outer folder went to the Trash")
        XCTAssertFalse(exists("src/A"), "a folder left with only .DS_Store counts as empty")
        XCTAssertEqual(batch.trashed.map(\.from), [p("src/A"), p("src/C")])

        let back = Unnester.undo(batch)
        XCTAssertTrue(back.failures.isEmpty, "\(back.failures)")
        XCTAssertTrue(exists("src/A/B/f.txt")); XCTAssertTrue(exists("src/C/D/E/f.txt"))
        XCTAssertFalse(exists("dest/B"))

        // Without trashing, the outer folder stays behind empty.
        let kept = Unnester.apply([Unnester.Item(outer: p("src/C"), inner: p("src/C/D"))], to: p("dest"), trashEmptied: false)
        XCTAssertTrue(kept.trashed.isEmpty)
        XCTAssertTrue(exists("src/C")); XCTAssertTrue(exists("dest/D"))
    }

    func testFilesMoveOutAndTakeFolderName() throws {
        dir("dl/Movie.2023"); touch("dl/Movie.2023/abc.mkv"); touch("dl/Movie.2023/.DS_Store")
        dir("dl/Show"); touch("dl/Show/e2.mkv"); touch("dl/Show/e1.mkv"); touch("dl/Show/e10.srt")
        dir("dl/Big"); for i in 1...4 { touch("dl/Big/\(i).txt") }           // over the limit
        dir("dl/Mixed/sub"); touch("dl/Mixed/a.txt")                          // files and a folder
        dir("dl/Pack"); touch("dl/Pack/src.tar.gz")
        dir("dl/Taken"); touch("dl/Taken/x.pdf"); touch("dl/Taken.pdf")       // new name already there
        dir("dl/Same/Same"); touch("dl/Same/Same/f.txt")                      // inner takes the outer's place
        dir("dl/Bare"); touch("dl/Bare/README")                               // no extension: also takes its place
        dir("dl/Skip"); touch("dl/Skip/s.txt")

        XCTAssertEqual(Unnester.plan(roots: [p("dl")]).map(\.outer), [p("dl/Same")], "files are off by default")
        XCTAssertEqual(Unnester.plan(roots: [p("dl")], maxFiles: 1).map(\.outer),
                       [p("dl/Bare"), p("dl/Movie.2023"), p("dl/Pack"), p("dl/Same"), p("dl/Skip"), p("dl/Taken")])
        var items = Unnester.plan(roots: [p("dl")], maxFiles: 3)
        XCTAssertEqual(items.map(\.outer), [p("dl/Bare"), p("dl/Movie.2023"), p("dl/Pack"), p("dl/Same"), p("dl/Show"), p("dl/Skip"), p("dl/Taken")])
        XCTAssertEqual(Unnester.names(for: items[4], rename: true), ["Show 1.mkv", "Show 2.mkv", "Show 3.srt"])
        XCTAssertEqual(Unnester.names(for: items[4], rename: false), ["e1.mkv", "e2.mkv", "e10.srt"])
        items[5].include = false

        let batch = Unnester.apply(items, trashEmptied: true, rename: true)
        XCTAssertEqual(batch.failures, [p("dl/Taken/x.pdf")])
        for f in ["dl/Movie.2023.mkv", "dl/Show 1.mkv", "dl/Show 2.mkv", "dl/Show 3.srt", "dl/Pack.tar.gz", "dl/Same/f.txt", "dl/Bare"] {
            XCTAssertTrue(exists(f), f)
        }
        var isDir: ObjCBool = true
        FileManager.default.fileExists(atPath: p("dl/Bare"), isDirectory: &isDir)
        XCTAssertFalse(isDir.boolValue, "the file replaced its folder")
        XCTAssertFalse(exists("dl/Same/Same")); XCTAssertFalse(exists("dl/Movie.2023")); XCTAssertFalse(exists("dl/Show"))
        XCTAssertTrue(exists("dl/Skip/s.txt"), "unticked rows are left alone")
        XCTAssertTrue(exists("dl/Taken/x.pdf")); XCTAssertTrue(exists("dl/Big/1.txt")); XCTAssertTrue(exists("dl/Mixed/a.txt"))
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: p("dl")).filter { $0.contains(".winnow-") }, [])

        let saved = try JSONDecoder().decode(Unnester.Batch.self, from: JSONEncoder().encode(batch))
        let back = Unnester.undo(saved)
        XCTAssertTrue(back.failures.isEmpty, "\(back.failures)")
        XCTAssertEqual(back.done.count, batch.moves.count)
        for f in ["dl/Movie.2023/abc.mkv", "dl/Movie.2023/.DS_Store", "dl/Show/e1.mkv", "dl/Show/e2.mkv", "dl/Show/e10.srt",
                  "dl/Pack/src.tar.gz", "dl/Same/Same/f.txt", "dl/Bare/README"] {
            XCTAssertTrue(exists(f), f)
        }
        XCTAssertFalse(exists("dl/Movie.2023.mkv")); XCTAssertFalse(exists("dl/Show 1.mkv"))

        // Without renaming, to a chosen place; taking the folder's own place needs the folder trashed.
        dir("out")
        let plain = Unnester.apply(Unnester.plan(roots: [p("dl")], maxFiles: 1).filter { $0.outer == p("dl/Movie.2023") }, to: p("out"), trashEmptied: false)
        XCTAssertTrue(exists("out/abc.mkv")); XCTAssertTrue(exists("dl/Movie.2023")); XCTAssertTrue(plain.trashed.isEmpty)
        let stuck = Unnester.apply([Unnester.Item(outer: p("dl/Same"), inner: p("dl/Same/Same"))], trashEmptied: false)
        XCTAssertEqual(stuck.failures, [p("dl/Same/Same")])

        XCTAssertEqual(stuck.reasons, [.nameTaken])
        XCTAssertEqual(batch.reasons, [.nameTaken])

        // A record written before `log` existed still decodes.
        let old = try JSONDecoder().decode(Unnester.Batch.self, from: Data(#"{"moves":[],"trashed":[],"failures":[]}"#.utf8))
        XCTAssertNil(old.log)
    }
}
