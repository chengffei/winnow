import AppKit
import WinnowCore
import Observation
import SwiftUI
import UserNotifications

enum Category: String, Hashable {
    case duplicates, emptyFolders, skipped
}

enum Route: Hashable {
    case newScan
    case scanning
    case result(UUID, Category)
}

struct Job {
    var config: ScanConfig
    var progress = ScanProgress()
    var started = Date()
    /// Bytes per second while comparing contents, smoothed.
    var speed: Double = 0
    var lastSample: (date: Date, bytes: UInt64)?
}

@Observable
@MainActor
final class AppModel {
    var records: [ScanRecord]
    var route: Route? = .newScan
    var draft: ScanConfig {
        didSet { saveDraft() }
    }
    var options: ScanOptions {
        didSet {
            guard persists, let data = try? JSONEncoder().encode(options) else { return }
            UserDefaults.standard.set(data, forKey: "options")
        }
    }
    var job: Job?
    var scanError: String?

    /// Snapshot mode passes demo records and must not touch the user's saved settings.
    @ObservationIgnored private let persists: Bool
    @ObservationIgnored private var runner: ScanRunner?
    @ObservationIgnored private var saveTasks: [UUID: Task<Void, Never>] = [:]

    init(records: [ScanRecord]? = nil, draft: ScanConfig? = nil) {
        self.persists = records == nil
        self.records = records ?? Store.loadAll()
        if let draft {
            self.draft = draft
        } else if let data = UserDefaults.standard.data(forKey: "draft"),
                  let saved = try? JSONDecoder().decode(ScanConfig.self, from: data) {
            self.draft = saved
        } else {
            self.draft = ScanConfig()
        }
        if let data = UserDefaults.standard.data(forKey: "options"),
           let saved = try? JSONDecoder().decode(ScanOptions.self, from: data) {
            self.options = saved
        } else {
            self.options = ScanOptions()
        }
    }

    private func saveDraft() {
        if let data = try? JSONEncoder().encode(draft) { UserDefaults.standard.set(data, forKey: "draft") }
    }

    // MARK: Scanning

    func startScan() {
        guard job == nil, !draft.locations.isEmpty, !draft.tools.isEmpty else { return }
        let config = draft
        let options = options
        job = Job(config: config)
        route = .scanning
        let runner = ScanRunner()
        self.runner = runner
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert]) { _, _ in }
        Task {
            do {
                let record = try await runner.run(config, options: options) { progress in
                    Task { @MainActor in self.update(progress) }
                }
                records.insert(record, at: 0)
                let snapshot = record
                Task.detached { Store.save(snapshot) }
                job = nil
                route = .result(record.id, config.tools.contains(.duplicates) ? .duplicates : .emptyFolders)
                notifyFinished(record)
            } catch is CancellationError {
                job = nil
                route = .newScan
            } catch {
                job = nil
                scanError = error.localizedDescription
                route = .newScan
            }
            self.runner = nil
        }
    }

    func cancelScan() {
        runner?.cancel()
    }

    private func update(_ progress: ScanProgress) {
        guard var job else { return }
        let now = Date()
        if progress.stage == .fullhash {
            if let last = job.lastSample {
                let dt = now.timeIntervalSince(last.date)
                if dt >= 1.5 {
                    let rate = Double(progress.bytesDone &- last.bytes) / dt
                    if progress.bytesDone >= last.bytes {
                        job.speed = job.speed == 0 ? rate : job.speed * 0.7 + rate * 0.3
                    }
                    job.lastSample = (now, progress.bytesDone)
                }
            } else {
                job.lastSample = (now, progress.bytesDone)
            }
        }
        job.progress = progress
        self.job = job
    }

    private func notifyFinished(_ record: ScanRecord) {
        guard !NSApp.isActive else { return }
        let content = UNMutableNotificationContent()
        content.title = L("Scan finished")
        content.body = L("%@: %ld groups of duplicates, %@ can be freed", record.config.title, record.groups.count, Fmt.bytes(record.reclaimable))
        UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: record.id.uuidString, content: content, trigger: nil))
        NSApp.requestUserAttention(.informationalRequest)
    }

    // MARK: Records

    func record(_ id: UUID) -> ScanRecord? {
        records.first { $0.id == id }
    }

    func mutate(_ id: UUID, _ body: (inout ScanRecord) -> Void) {
        guard let i = records.firstIndex(where: { $0.id == id }) else { return }
        body(&records[i])
        scheduleSave(records[i])
    }

    private func scheduleSave(_ record: ScanRecord) {
        saveTasks[record.id]?.cancel()
        saveTasks[record.id] = Task {
            try? await Task.sleep(for: .milliseconds(600))
            guard !Task.isCancelled else { return }
            await Task.detached { Store.save(record) }.value
        }
    }

    func deleteRecord(_ id: UUID) {
        records.removeAll { $0.id == id }
        Store.delete(id)
        if case .result(let rid, _) = route, rid == id { route = .newScan }
    }
}

enum Fmt {
    static func bytes(_ n: UInt64) -> String {
        ByteCountFormatter.string(fromByteCount: Int64(clamping: n), countStyle: .file)
    }

    static func day(_ seconds: Int64) -> String {
        Date(timeIntervalSince1970: TimeInterval(seconds)).formatted(date: .numeric, time: .omitted)
    }

    static func short(_ date: Date) -> String {
        Calendar.current.isDateInToday(date)
            ? L("Today %@", date.formatted(date: .omitted, time: .shortened))
            : date.formatted(.dateTime.month(.abbreviated).day().hour().minute())
    }

    static func duration(_ seconds: Double) -> String {
        durationFormatter.string(from: max(seconds, 1).rounded()) ?? ""
    }

    static func number(_ n: Int) -> String {
        n.formatted(.number)
    }

    private static let durationFormatter: DateComponentsFormatter = {
        let f = DateComponentsFormatter()
        f.allowedUnits = [.hour, .minute, .second]
        f.unitsStyle = .abbreviated
        f.maximumUnitCount = 2
        return f
    }()
}
