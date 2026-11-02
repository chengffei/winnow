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
