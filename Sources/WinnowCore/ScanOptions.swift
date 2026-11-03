import Foundation

/// How much of the processor a scan may use.
public enum ScanSpeed: String, Codable, CaseIterable, Sendable {
    case full, reduced, minimal

    /// czkawka_cli `-T` value; 0 means all cores.
    public var threads: Int {
        switch self {
        case .full: return 0
        case .reduced: return max(ProcessInfo.processInfo.activeProcessorCount / 2, 1)
        case .minimal: return 1
        }
    }
}

/// Settings that apply to every scan, kept apart from ScanConfig (which is saved with each result).
public struct ScanOptions: Codable, Equatable, Sendable {
    public var speed: ScanSpeed
    /// Remember hashes of unchanged files between scans.
    public var useCache: Bool
    /// Names or wildcard patterns skipped in every scan, e.g. "node_modules" or "*.tmp".
    public var alwaysSkip: [String]

    public init(speed: ScanSpeed = .full, useCache: Bool = true, alwaysSkip: [String] = []) {
        self.speed = speed
        self.useCache = useCache
        self.alwaysSkip = alwaysSkip
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        speed = try c.decodeIfPresent(ScanSpeed.self, forKey: .speed) ?? .full
        useCache = try c.decodeIfPresent(Bool.self, forKey: .useCache) ?? true
        alwaysSkip = try c.decodeIfPresent([String].self, forKey: .alwaysSkip) ?? []
    }

    /// `-E` patterns for the user's list. A bare name matches a file or folder of that name anywhere.
    public var skipPatterns: [String] {
        alwaysSkip.flatMap { raw -> [String] in
            let s = raw.trimmingCharacters(in: .whitespaces)
            if s.isEmpty { return [] }
            if s.contains("*") || s.contains("/") { return [s] }
            return ["*/\(s)", "*/\(s)/*"]
        }
    }
}

/// czkawka keeps its hash cache here; Krokiet shares it.
public enum HashCache {
    public static var folder: URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Caches/pl.Qarmin.Czkawka")
    }

    private static func files() -> [URL] {
        let all = (try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: [.fileSizeKey])) ?? []
        return all.filter { $0.lastPathComponent.hasPrefix("cache_") }
    }

    public static func size() -> UInt64 {
        files().reduce(0) { $0 + UInt64((try? $1.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0) }
    }

    public static func clear() {
        for f in files() { try? FileManager.default.removeItem(at: f) }
    }
}
