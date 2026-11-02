import WinnowCore
import SwiftUI

/// The only way anything gets removed: re-checks the disk, then stages, trashes or deletes.
struct ProcessSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    let id: UUID
    /// Snapshot hook: skip the disk check.
    var preset: SafetyReport?

    @State private var report: SafetyReport?
    @State private var networkCount = 0
    @State private var action: ProcessAction = .stage
    @State private var confirmText = ""
    @State private var running = false
    @State private var doneCount = 0
    @State private var outcome: ProcessOutcome?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if let outcome {
                result(outcome)
            } else if let report {
                form(report)
            } else {
                HStack(spacing: 10) {
                    ProgressView().controlSize(.small)
                    Text("正在逐个核对标记的项目…")
                }
                .padding(.vertical, 30)
                .frame(maxWidth: .infinity)
            }
        }
        .padding(24)
        .frame(width: 540)
        .task { await check() }
    }

    private func check() async {
        guard report == nil, let record = model.record(id) else { return }
        let network = record.config.locations.filter { !Processor.isLocal($0.path) }.map(\.path)
        let r = if let preset { preset } else { await Task.detached { Processor.check(record) }.value }
        networkCount = r.items.filter { item in network.contains { Paths.contains($0, item.path) } }.count
        if networkCount > 0 && action == .trash { action = .stage }
        report = r
    }

    @ViewBuilder
    private func form(_ report: SafetyReport) -> some View {
        let items = report.items
        let bytes = items.reduce(UInt64(0)) { $0 + $1.size }
        Text("处理 \(Fmt.number(items.count)) 项？").font(.title3.weight(.semibold))
        Text("将释放 \(Fmt.bytes(bytes))。" + (networkCount > 0 ? "其中 \(Fmt.number(networkCount)) 项在网络卷上。" : ""))
            .foregroundStyle(.secondary)
            .padding(.top, 2)

        VStack(spacing: 10) {
            Option(selected: action == .stage, disabled: false, title: "移到暂存文件夹（推荐）",
                   detail: "放进所在磁盘顶层的「\(Processor.stagingPrefix)日期」文件夹，保留原目录结构。本机磁盘上的放在个人文件夹里。确认没问题后再手动删，也可以一键还原。") {
                action = .stage
            }
            Option(selected: action == .trash, disabled: networkCount > 0, title: "移到废纸篓",
                   detail: networkCount > 0 ? "网络卷不支持废纸篓，选了会直接删除，所以这里不可选。" : "可以在废纸篓里找回。") {
                action = .trash
            }
            Option(selected: action == .delete, disabled: false, title: "直接删除",
                   detail: "无法恢复。需要输入「删除」两个字确认。") {
                action = .delete
            }
            if action == .delete {
                TextField("输入「删除」确认", text: $confirmText)
                    .textFieldStyle(.roundedBorder)
            }
        }
        .padding(.top, 16)

        VStack(alignment: .leading, spacing: 6) {
            CheckLine(ok: report.everyGroupKeepsOne, text: "每组至少保留 1 份")
            CheckLine(ok: report.noReferenceMarked, text: "「只作对照」的位置里没有项目被标记")
            if report.changed.isEmpty {
                CheckLine(ok: true, text: "标记的项目在扫描后都没有改动过")
            } else {
                CheckLine(ok: nil, text: "\(report.changed.count) 项在扫描后有变化或已不在，将跳过")
            }
            if !report.unsafeGroups.isEmpty {
                CheckLine(ok: nil, text: "\(report.unsafeGroups.count) 组要保留的那份已不在或变了，这些组不处理")
            }
            if model.record(id)?.config.method == .sizeName, items.contains(where: { !$0.isFolder }) {
                CheckLine(ok: nil, text: "按大小和文件名比对，文件内容没有核实")
            }
        }
        .font(.callout)
        .padding(.top, 16)

        if running {
            ProgressView(value: Double(doneCount), total: Double(max(items.count, 1)))
                .padding(.top, 16)
        }

        HStack {
            Spacer()
            Button("取消") { dismiss() }
                .keyboardShortcut(.cancelAction)
                .disabled(running)
            Button(buttonTitle(items.count)) { run(items) }
                .buttonStyle(.borderedProminent)
                .tint(action == .delete ? .red : .accentColor)
                .keyboardShortcut(.defaultAction)
                .disabled(running || report.blocking || items.isEmpty || (action == .delete && confirmText != "删除"))
        }
        .padding(.top, 20)
    }

    private func buttonTitle(_ n: Int) -> String {
        switch action {
        case .stage: return "移动 \(Fmt.number(n)) 项"
        case .trash: return "移到废纸篓"
        case .delete: return "永久删除 \(Fmt.number(n)) 项"
        }
    }

    private func run(_ items: [PlanItem]) {
        running = true
        let act = action
        Task {
            let outcome = await Task.detached {
                Processor.execute(act, items: items) { n in
                    if n % 25 == 0 || n == items.count {
                        Task { @MainActor in doneCount = n }
                    }
                }
            }.value
            model.mutate(id) { Processor.applyOutcome(outcome, to: &$0) }
            self.outcome = outcome
            running = false
        }
    }

    @ViewBuilder
    private func result(_ outcome: ProcessOutcome) -> some View {
        let verb = action == .stage ? "移到暂存文件夹" : (action == .trash ? "移到废纸篓" : "删除")
        Text(outcome.failures.isEmpty ? "完成" : "部分完成").font(.title3.weight(.semibold))
        Text("已\(verb) \(Fmt.number(outcome.done.count)) 项，释放 \(Fmt.bytes(outcome.done.reduce(0) { $0 + $1.size }))。")
            .foregroundStyle(.secondary)
            .padding(.top, 2)
        if !outcome.failures.isEmpty {
            Text("\(outcome.failures.count) 项失败：").padding(.top, 14)
            ScrollView {
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(Array(outcome.failures.enumerated()), id: \.offset) { _, f in
                        VStack(alignment: .leading, spacing: 1) {
                            PathCrumbs(path: f.path)
                            Text(f.reason).font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(maxHeight: 180)
        }
        HStack {
            Spacer()
            Button("完成") { dismiss() }.keyboardShortcut(.defaultAction)
        }
        .padding(.top, 20)
    }
}

private struct Option: View {
    let selected: Bool
    let disabled: Bool
    let title: String
    let detail: String
    let pick: () -> Void

    var body: some View {
        Button(action: pick) {
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: selected ? "largecircle.fill.circle" : "circle")
                    .foregroundStyle(selected ? Color.accentColor : Color.secondary)
                    .padding(.top, 1)
                VStack(alignment: .leading, spacing: 2) {
                    Text(title).fontWeight(.semibold).foregroundStyle(.primary)
                    Text(detail).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 0)
            }
            .padding(12)
            .background(RoundedRectangle(cornerRadius: 10).fill(selected ? Color.accentColor.opacity(0.06) : .clear))
            .overlay(RoundedRectangle(cornerRadius: 10)
                .strokeBorder(selected ? Color.accentColor : Color(nsColor: .separatorColor), lineWidth: selected ? 2 : 1))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(disabled)
        .opacity(disabled ? 0.5 : 1)
    }
}

private struct CheckLine: View {
    /// nil = warning that does not block.
    let ok: Bool?
    let text: String

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: ok == true ? "checkmark.circle.fill" : (ok == false ? "xmark.circle.fill" : "exclamationmark.triangle.fill"))
                .foregroundStyle(ok == true ? Color.green : (ok == false ? Color.red : Color.orange))
            Text(text)
        }
    }
}
