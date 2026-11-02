import WinnowCore
import SwiftUI

struct ScanningView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        if let job = model.job {
            content(job)
                .navigationTitle(job.config.title)
                .navigationSubtitle("正在扫描")
        } else {
            ContentUnavailableView("没有进行中的扫描", systemImage: "checkmark.circle")
        }
    }

    private func content(_ job: Job) -> some View {
        let stages = Self.stages(job)
        return ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                Text(job.config.tools.contains(.duplicates) ? "正在找重复文件" : "正在找空文件夹")
                    .font(.title2.weight(.semibold))
                TimelineView(.periodic(from: .now, by: 1)) { ctx in
                    Text("已用 \(Fmt.duration(ctx.date.timeIntervalSince(job.started)))。可以关掉窗口，扫完会发通知。")
                        .foregroundStyle(.secondary)
                }
                .padding(.top, 4)
                .padding(.bottom, 18)

                ForEach(Array(stages.enumerated()), id: \.offset) { i, stage in
                    StageRow(index: i + 1, stage: stage)
                    if i < stages.count - 1 { Divider() }
                }

                Button("停止") { model.cancelScan() }
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
            let found = p.filesFound > 0 ? "\(Fmt.number(p.filesFound)) 个文件" : "正在列出文件"
            result.append(Stage(title: "收集文件", state: state(.collecting), detail: found))
            if job.config.method == .hash {
                var pre = Stage(title: "按大小筛出候选", state: state(.prehash),
                                detail: "大小相同的才可能重复，再读开头一小段排除明显不同的")
                if p.stage == .prehash, p.total > 0 {
                    pre.detail = "\(Fmt.number(p.done)) / \(Fmt.number(p.total)) 个候选"
                    pre.fraction = Double(p.done) / Double(p.total)
                } else if p.stage > .prehash, p.total > 0, p.stage == .fullhash {
                    pre.detail = "剩 \(Fmt.number(p.total)) 个候选，\(Fmt.bytes(p.bytesTotal))"
                }
                result.append(pre)
                var full = Stage(title: "比对内容", state: state(.fullhash), detail: "逐字节比对剩下的候选")
                if p.stage == .fullhash, p.bytesTotal > 0 {
                    var parts = ["\(Fmt.bytes(p.bytesDone)) / \(Fmt.bytes(p.bytesTotal))"]
                    if job.speed > 0 {
                        parts.append("\(Fmt.bytes(UInt64(job.speed)))/秒")
                        let left = Double(p.bytesTotal &- min(p.bytesDone, p.bytesTotal)) / job.speed
                        parts.append("剩约 \(Fmt.duration(left))")
                    }
                    full.detail = parts.joined(separator: " · ")
                    full.fraction = Double(p.bytesDone) / Double(p.bytesTotal)
                }
                result.append(full)
            } else {
                result.append(Stage(title: "按大小和文件名比对", state: p.stage > .collecting ? .done : .waiting,
                                    detail: "不读文件内容"))
            }
        }
        if job.config.tools.contains(.emptyFolders) {
            result.append(Stage(title: "找空文件夹", state: state(.emptyFolders), detail: "检查每个文件夹里有没有文件"))
        }
        if !p.note.isEmpty, let i = result.firstIndex(where: { $0.state == .running }), result[i].fraction == nil {
            result[i].detail += " · " + translate(p.note)
        }
        return result
    }

    static func translate(_ note: String) -> String {
        if note.contains("cache") { return note.hasPrefix("Saving") ? "保存缓存" : "读取缓存" }
        if note.hasPrefix("Hiding") { return "排除硬链接" }
        return note
    }

    static func summary(_ job: Job) -> String {
        let p = job.progress
        if p.stage == .fullhash, p.bytesTotal > 0 {
            return "比对内容 \(Int(Double(p.bytesDone) / Double(p.bytesTotal) * 100))%"
        }
        switch p.stage {
        case .collecting: return p.filesFound > 0 ? "已找到 \(Fmt.number(p.filesFound)) 个文件" : "正在列出文件"
        case .prehash: return "筛选候选"
        case .fullhash: return "比对内容"
        case .emptyFolders: return "找空文件夹"
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
                Text(stage.state == .waiting ? "等待中" : stage.detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }
        }
        .padding(.vertical, 12)
    }
}
