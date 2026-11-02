import Foundation

/// One JSON file per scan under Application Support, so a long NAS scan survives a restart.
public enum Store {
    public static var directory: URL {
        if let env = ProcessInfo.processInfo.environment["WINNOW_STORE"] { return URL(fileURLWithPath: env) }
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return base.appendingPathComponent("Winnow/scans", isDirectory: true)
    }

    public static func loadAll() -> [ScanRecord] {
        let dir = directory
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: dir.path) else { return [] }
        let decoder = JSONDecoder()
        return names.filter { $0.hasSuffix(".json") }
            .compactMap { try? decoder.decode(ScanRecord.self, from: Data(contentsOf: dir.appendingPathComponent($0))) }
            .sorted { $0.date > $1.date }
    }

    public static func save(_ record: ScanRecord) {
        let dir = directory
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        guard let data = try? JSONEncoder().encode(record) else { return }
        try? data.write(to: dir.appendingPathComponent("\(record.id.uuidString).json"), options: .atomic)
    }

    public static func delete(_ id: UUID) {
        try? FileManager.default.removeItem(at: directory.appendingPathComponent("\(id.uuidString).json"))
    }
}
