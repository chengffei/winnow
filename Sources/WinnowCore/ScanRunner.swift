import Foundation

public enum ScanError: LocalizedError {
    case cliMissing
    case failed(String)

    public var errorDescription: String? {
        switch self {
        case .cliMissing: return "找不到扫描组件 czkawka_cli。"
        case .failed(let text): return "扫描出错：\(text)"
        }
    }
}

/// Runs the bundled czkawka_cli for each selected tool and builds a ScanRecord.
/// The CLI only draws progress on a terminal, so it is started under `script` to get a pty.
public final class ScanRunner {
    public static func locateCLI() -> URL? {
        var candidates: [String] = []
        if let env = ProcessInfo.processInfo.environment["WINNOW_CLI"] { candidates.append(env) }
        if let res = Bundle.main.resourceURL?.appendingPathComponent("czkawka_cli").path { candidates.append(res) }
        candidates += [NSHomeDirectory() + "/.local/bin/czkawka_cli", "/opt/homebrew/bin/czkawka_cli"]
        return candidates.first { FileManager.default.isExecutableFile(atPath: $0) }.map { URL(fileURLWithPath: $0) }
    }

    /// Folders that never hold anything worth cleaning: trash, caches, NAS recycle bins and thumbnails,
    /// and our own staging folders.
    public static let excludedItems = [
        "*/.Trash/*", "*/.Trashes/*", "*/.Spotlight-V100/*", "*/.fseventsd/*", "*/.DocumentRevisions-V100/*",
        "*/Library/Caches/*", "*/@eaDir/*", "*/#recycle/*", "*/#snapshot/*", "*/.@__thumb/*", "*/@Recycle/*",
        "*/\(Processor.stagingPrefix)*"
    ]

    private let lock = NSLock()
    private var process: Process?
    private var cancelled = false

    public init() {}

    public func cancel() {
        let p = lock.withLock { () -> Process? in
            cancelled = true
            return process
        }
        guard let p, p.isRunning else { return }
        // Kill the CLI under `script` first; closing the pty alone may leave it running.
        let pkill = Process()
        pkill.executableURL = URL(fileURLWithPath: "/usr/bin/pkill")
        pkill.arguments = ["-TERM", "-P", String(p.processIdentifier)]
        try? pkill.run()
        pkill.waitUntilExit()
        p.terminate()
    }

    /// The CLI reports real paths (/private/var, not /var), so locations are resolved the same way.
    static func realPath(_ path: String) -> String {
        guard let resolved = realpath(path, nil) else { return path }
        defer { free(resolved) }
        return String(cString: resolved)
    }

    public func run(_ config: ScanConfig, onProgress: @escaping (ScanProgress) -> Void) async throws -> ScanRecord {
        guard let cli = Self.locateCLI() else { throw ScanError.cliMissing }
        var config = config
        for i in config.locations.indices { config.locations[i].path = Self.realPath(config.locations[i].path) }
        let work = FileManager.default.temporaryDirectory.appendingPathComponent("winnow-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: work) }

        var record = ScanRecord(config: config)
        var skipped: [SkippedItem] = []
        let dirs = config.locations.flatMap { ["-d", $0.path] }
        let excludes = Self.excludedItems.flatMap { ["-E", $0] }

        if config.tools.contains(.duplicates) {
            let out = work.appendingPathComponent("dup.json")
            let args = ["dup"] + dirs + excludes + ["-s", config.method.cliValue, "-u", "-p", out.path, "-N", "-W"]
            skipped += try await execute(cli, args, output: out, stage: .collecting, onProgress: onProgress)
            if FileManager.default.fileExists(atPath: out.path) {
                record.groups = try ResultParser.duplicates(Data(contentsOf: out), config: config)
            }
        }
        if config.tools.contains(.emptyFolders) {
            let out = work.appendingPathComponent("empty.json")
            let args = ["empty-folders"] + dirs + excludes + ["-p", out.path, "-N"]
            skipped += try await execute(cli, args, output: out, stage: .emptyFolders, onProgress: onProgress)
            if FileManager.default.fileExists(atPath: out.path) {
                record.emptyFolders = try ResultParser.emptyFolders(Data(contentsOf: out), config: config)
            }
        }

        var seen = Set<SkippedItem>()
        record.skipped = skipped.filter { seen.insert($0).inserted }
        record.date = Date()
        Marking.apply(.oldest, to: &record)
        return record
    }

    private func execute(_ cli: URL, _ args: [String], output: URL, stage: ScanProgress.Stage,
                         onProgress: @escaping (ScanProgress) -> Void) async throws -> [SkippedItem] {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/script")
        p.arguments = ["-q", "/dev/null", cli.path] + args
        var env = ProcessInfo.processInfo.environment
        env["LANG"] = "en_US.UTF-8"
        env["LC_ALL"] = "en_US.UTF-8"
        env["TERM"] = "xterm-256color"
        p.environment = env
        p.standardInput = FileHandle.nullDevice
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = pipe

        let state = ParserBox(stage: stage)
        pipe.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            guard !data.isEmpty else { return }
            if let progress = state.feed(data) { onProgress(progress) }
        }

        let alreadyCancelled = lock.withLock { () -> Bool in
            if !cancelled { process = p }
            return cancelled
        }
        if alreadyCancelled { throw CancellationError() }

        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            p.terminationHandler = { _ in cont.resume() }
            do { try p.run() } catch { cont.resume(throwing: error) }
        }
        pipe.fileHandleForReading.readabilityHandler = nil
        if let rest = try? pipe.fileHandleForReading.readToEnd(), let progress = state.feed(rest) { onProgress(progress) }
        let (finalProgress, skipped, lastText) = state.finish()
        onProgress(finalProgress)
        let tail = lastText

        let wasCancelled = lock.withLock { () -> Bool in
            process = nil
            return cancelled
        }
        if wasCancelled { throw CancellationError() }
        // The CLI exits non-zero when it finds something, so only a missing result file is a failure.
        if p.terminationStatus != 0 && !FileManager.default.fileExists(atPath: output.path) {
            throw ScanError.failed(tail.isEmpty ? "退出码 \(p.terminationStatus)" : tail)
        }
        return skipped
    }
}

/// Collects pipe output on a background queue; bytes are split on line ends so UTF-8 is never cut.
private final class ParserBox {
    private let lock = NSLock()
    private var parser: ProgressParser
    private var buffer = Data()
    private var recent: [String] = []

    init(stage: ScanProgress.Stage) { parser = ProgressParser(stage: stage) }

    func feed(_ data: Data) -> ScanProgress? {
        lock.lock(); defer { lock.unlock() }
        buffer.append(data)
        guard let cut = buffer.lastIndex(where: { $0 == 0x0A || $0 == 0x0D }) else { return nil }
        let chunk = buffer[..<buffer.index(after: cut)]
        buffer = Data(buffer[buffer.index(after: cut)...])
        let text = String(decoding: chunk, as: UTF8.self)
        parser.feed(text)
        for line in text.components(separatedBy: CharacterSet(charactersIn: "\r\n")) {
            let c = ProgressParser.clean(line)
            if !c.isEmpty { recent.append(c) }
        }
        if recent.count > 20 { recent.removeFirst(recent.count - 20) }
        return parser.progress
    }

    func finish() -> (ScanProgress, [SkippedItem], String) {
        lock.lock(); defer { lock.unlock() }
        parser.feed(String(decoding: buffer, as: UTF8.self))
        parser.finish()
        buffer = Data()
        return (parser.progress, parser.skipped, recent.suffix(3).joined(separator: " "))
    }
}
