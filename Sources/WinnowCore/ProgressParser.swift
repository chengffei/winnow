import Foundation

public struct ScanProgress: Equatable {
    public enum Stage: Int, Comparable {
        case collecting, prehash, fullhash, emptyFolders

        public static func < (a: Stage, b: Stage) -> Bool { a.rawValue < b.rawValue }
    }

    public var stage: Stage = .collecting
    public var filesFound = 0
    public var done = 0
    public var total = 0
    public var bytesDone: UInt64 = 0
    public var bytesTotal: UInt64 = 0
    /// Housekeeping step the scanner reports, such as loading its cache.
    public var note = ""

    public init() {}
}

/// Turns czkawka_cli terminal output (progress bars redrawn with \r, run under a pty) into progress values.
/// Tied to the bundled CLI version; unknown lines are ignored.
public struct ProgressParser {
    public private(set) var progress = ScanProgress()
    public private(set) var skipped: [SkippedItem] = []
    private var pending = ""
    private var inWarnings = false

    public init(stage: ScanProgress.Stage = .collecting) {
        progress.stage = stage
    }

    public mutating func feed(_ text: String) {
        pending += text
        var lines = pending.components(separatedBy: CharacterSet(charactersIn: "\r\n"))
        pending = lines.removeLast()
        for line in lines { handle(Self.clean(line)) }
    }

    public mutating func finish() {
        handle(Self.clean(pending))
        pending = ""
    }

    static let ansi = try! NSRegularExpression(pattern: "\u{1B}\\[[0-9;?]*[A-Za-z]")
    static let sizeLine = try! NSRegularExpression(pattern: "^Scanning size of (\\d+) file")
    static let hashLine = try! NSRegularExpression(
        pattern: "^Analyzed (partial|full) hash of (\\d+)/(\\d+) files \\(([\\d.]+ ?[KMGTP]?i?B) / ([\\d.]+ ?[KMGTP]?i?B)\\)")
    static let dirWarning = try! NSRegularExpression(pattern: "^Cannot open dir (.+), reason (.+)$")

    static func clean(_ line: String) -> String {
        let range = NSRange(line.startIndex..., in: line)
        var s = ansi.stringByReplacingMatches(in: line, range: range, withTemplate: "")
        s.unicodeScalars.removeAll { $0.value < 0x20 || $0 == "\u{2068}" || $0 == "\u{2069}" }
        return s.trimmingCharacters(in: .whitespaces)
    }

    mutating func handle(_ line: String) {
        guard !line.isEmpty else { return }
        if line.hasPrefix("---") {
            inWarnings = line.contains("WARNINGS") && !line.contains("END OF")
            return
        }
        if inWarnings {
            if let m = Self.match(Self.dirWarning, line) {
                skipped.append(SkippedItem(path: m[1], reason: m[2]))
            } else {
                skipped.append(SkippedItem(path: "", reason: line))
            }
            return
        }
        if let m = Self.match(Self.sizeLine, line) {
            if progress.stage == .collecting { progress.filesFound = Int(m[1]) ?? progress.filesFound }
            progress.note = ""
        } else if let m = Self.match(Self.hashLine, line) {
            progress.stage = m[1] == "partial" ? .prehash : .fullhash
            progress.done = Int(m[2]) ?? 0
            progress.total = Int(m[3]) ?? 0
            progress.bytesDone = Self.bytes(m[4])
            progress.bytesTotal = Self.bytes(m[5])
            progress.note = ""
        } else if line.hasPrefix("Loading") || line.hasPrefix("Saving") || line.hasPrefix("Hiding") {
            progress.note = line.components(separatedBy: " [").first ?? line
        }
    }

    static func match(_ re: NSRegularExpression, _ s: String) -> [String]? {
        guard let m = re.firstMatch(in: s, range: NSRange(s.startIndex..., in: s)) else { return nil }
        return (0..<m.numberOfRanges).map { i in
            Range(m.range(at: i), in: s).map { String(s[$0]) } ?? ""
        }
    }

    /// "43.59 MiB" → bytes.
    static func bytes(_ text: String) -> UInt64 {
        let scanner = Scanner(string: text)
        guard let value = scanner.scanDouble() else { return 0 }
        let unit = text.trimmingCharacters(in: CharacterSet(charactersIn: "0123456789. "))
        let power: Double
        switch unit.first {
        case "K": power = 1
        case "M": power = 2
        case "G": power = 3
        case "T": power = 4
        case "P": power = 5
        default: power = 0
        }
        let base: Double = unit.contains("i") ? 1024 : 1000
        return UInt64(value * pow(base, power))
    }
}
