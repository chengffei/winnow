import WinnowCore
import SwiftUI

struct ScanningView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        if let job = model.job {
            content(job)
                .navigationTitle(job.config.title)
                .navigationSubtitle(L("Scanning"))
        } else {
            ContentUnavailableView(L("No scan in progress"), systemImage: "checkmark.circle")
        }
    }

    private func content(_ job: Job) -> some View {
        let stages = Self.stages(job)
        return ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                Text(job.config.tools.contains(.duplicates) ? L("Looking for duplicate files") : L("Looking for empty folders"))
                    .font(.title2.weight(.semibold))
                TimelineView(.periodic(from: .now, by: 1)) { ctx in
                    Text(L("%@ elapsed. You can close the window; you will be notified when it is done.",
                           Fmt.duration(ctx.date.timeIntervalSince(job.started))))
                        .foregroundStyle(.secondary)
                }
                .padding(.top, 4)
                .padding(.bottom, 18)

                ForEach(Array(stages.enumerated()), id: \.offset) { i, stage in
                    StageRow(index: i + 1, stage: stage)
                    if i < stages.count - 1 { Divider() }
                }

                Button(L("Stop")) { model.cancelScan() }
                    .padding(.top, 20)
            }
            .frame(width: 540, alignment: .leading)
            .padding(.vertical, 48)
            .frame(maxWidth: .infinity)
        }
    }

    struct Stage {
        enum State { case done, running, waiting }
        var title: String
        var state: State
        var detail: String
        var fraction: Double?
    }

    static func stages(_ job: Job) -> [Stage] {
        let p = job.progress
        var result: [Stage] = []
        let dup = job.config.tools.contains(.duplicates)
        func state(_ s: ScanProgress.Stage) -> Stage.State {
            p.stage == s ? .running : (p.stage > s ? .done : .waiting)
        }
        if dup {
            let found = p.filesFound > 0 ? L("%@ files", Fmt.number(p.filesFound)) : L("Listing files")
            result.append(Stage(title: L("Collect files"), state: state(.collecting), detail: found))
            if job.config.method == .hash {
                var pre = Stage(title: L("Narrow down by size"), state: state(.prehash),
                                detail: L("Only files of the same size can match; reading the start of each rules out more"))
                if p.stage == .prehash, p.total > 0 {
                    pre.detail = L("%@ of %@ candidates", Fmt.number(p.done), Fmt.number(p.total))
                    pre.fraction = Double(p.done) / Double(p.total)
                } else if p.stage == .fullhash, p.total > 0 {
                    pre.detail = L("%@ candidates left, %@", Fmt.number(p.total), Fmt.bytes(p.bytesTotal))
                }
                result.append(pre)
                var full = Stage(title: L("Compare contents"), state: state(.fullhash), detail: L("Comparing the remaining candidates byte by byte"))
                if p.stage == .fullhash, p.bytesTotal > 0 {
                    var parts = [L("%@ of %@", Fmt.bytes(p.bytesDone), Fmt.bytes(p.bytesTotal))]
                    if job.speed > 0 {
                        parts.append(L("%@/s", Fmt.bytes(UInt64(job.speed))))
                        let left = Double(p.bytesTotal &- min(p.bytesDone, p.bytesTotal)) / job.speed
                        parts.append(L("about %@ left", Fmt.duration(left)))
                    }
                    full.detail = parts.joined(separator: " · ")
                    full.fraction = Double(p.bytesDone) / Double(p.bytesTotal)
                }
                result.append(full)
            } else {
                result.append(Stage(title: L("Compare sizes and names"), state: p.stage > .collecting ? .done : .waiting,
                                    detail: L("File contents are not read")))
            }
        }
        if job.config.tools.contains(.emptyFolders) {
            result.append(Stage(title: L("Find empty folders"), state: state(.emptyFolders), detail: L("Checking every folder for files")))
        }
        if !p.note.isEmpty, let i = result.firstIndex(where: { $0.state == .running }), result[i].fraction == nil {
            result[i].detail += " · " + translate(p.note)
        }
        return result
    }

    static func translate(_ note: String) -> String {
        if note.contains("cache") { return note.hasPrefix("Saving") ? L("saving cache") : L("loading cache") }
        if note.hasPrefix("Hiding") { return L("skipping hard links") }
        return note
    }

    static func summary(_ job: Job) -> String {
        let p = job.progress
        if p.stage == .fullhash, p.bytesTotal > 0 {
            return L("Comparing contents %ld%%", Int(Double(p.bytesDone) / Double(p.bytesTotal) * 100))
        }
        switch p.stage {
        case .collecting: return p.filesFound > 0 ? L("%@ files found", Fmt.number(p.filesFound)) : L("Listing files")
        case .prehash: return L("Narrowing down")
        case .fullhash: return L("Compare contents")
        case .emptyFolders: return L("Find empty folders")
        }
    }
}

private struct StageRow: View {
    let index: Int
    let stage: ScanningView.Stage

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            ZStack {
                switch stage.state {
                case .done:
                    Circle().fill(Color.green)
                    Image(systemName: "checkmark").font(.system(size: 10, weight: .bold)).foregroundStyle(.white)
                case .running:
                    Circle().fill(Color.accentColor)
                    Text("\(index)").font(.system(size: 11, weight: .semibold)).foregroundStyle(.white)
                case .waiting:
                    Circle().strokeBorder(Color(nsColor: .separatorColor), lineWidth: 1.5)
                }
            }
            .frame(width: 20, height: 20)
            VStack(alignment: .leading, spacing: 4) {
                Text(stage.title).fontWeight(.semibold)
                    .foregroundStyle(stage.state == .waiting ? .secondary : .primary)
                if stage.state == .running {
                    if let f = stage.fraction {
                        ProgressView(value: min(max(f, 0), 1))
                    } else {
                        ProgressView().progressViewStyle(.linear)
                    }
                }
                Text(stage.state == .waiting ? L("Waiting") : stage.detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }
        }
        .padding(.vertical, 12)
    }
}
