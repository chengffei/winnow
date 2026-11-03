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

    /// The word typed to confirm a permanent delete, in the user's language.
    private var confirmWord: String { L("delete") }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if let outcome {
                result(outcome)
            } else if let report {
                form(report)
            } else {
                HStack(spacing: 10) {
                    ProgressView().controlSize(.small)
                    Text(L("Checking each marked item again…"))
                }
                .padding(.vertical, 30)
                .frame(maxWidth: .infinity)
            }
        }
        .padding(24)
        .frame(width: 560)
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
        Text(L("Clean up %@ items?", Fmt.number(items.count))).font(.title3.weight(.semibold))
        Text(networkCount > 0
             ? L("This frees %@. %@ of the items are on a network drive.", Fmt.bytes(bytes), Fmt.number(networkCount))
             : L("This frees %@.", Fmt.bytes(bytes)))
            .foregroundStyle(.secondary)
            .padding(.top, 2)

        VStack(spacing: 10) {
            Option(selected: action == .stage, disabled: false, title: L("Move to a staging folder (recommended)"),
                   detail: L("Items go into a dated “%@…” folder at the top of their drive, keeping their folder structure. Items on this Mac’s disk go into your home folder. Delete the folder yourself once you are sure, or restore everything in one click.", Processor.stagingPrefix)) {
                action = .stage
            }
            Option(selected: action == .trash, disabled: networkCount > 0, title: L("Move to Trash"),
                   detail: networkCount > 0 ? L("Network drives have no Trash; this would delete for good, so it is turned off.")
                                            : L("You can get items back from the Trash.")) {
                action = .trash
            }
            Option(selected: action == .delete, disabled: false, title: L("Delete permanently"),
                   detail: L("Cannot be undone. Type “%@” to confirm.", confirmWord)) {
                action = .delete
            }
            if action == .delete {
                TextField(L("Type “%@” to confirm", confirmWord), text: $confirmText)
                    .textFieldStyle(.roundedBorder)
            }
        }
        .padding(.top, 16)

        VStack(alignment: .leading, spacing: 6) {
            CheckLine(ok: report.everyGroupKeepsOne, text: L("Every group keeps at least one copy"))
            CheckLine(ok: report.noReferenceMarked, text: L("Nothing in a “compare only” location is marked"))
            if report.changed.isEmpty {
                CheckLine(ok: true, text: L("No marked item changed since the scan"))
            } else {
                CheckLine(ok: nil, text: L("%@ items changed or are gone since the scan and will be skipped", Fmt.number(report.changed.count)))
            }
            if !report.unsafeGroups.isEmpty {
                CheckLine(ok: nil, text: L("In %@ groups the kept copy is gone or changed; those groups are left alone", Fmt.number(report.unsafeGroups.count)))
            }
            if model.record(id)?.config.method == .sizeName, items.contains(where: { !$0.isFolder }) {
                CheckLine(ok: nil, text: L("Compared by size and name; file contents were not checked"))
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
            Button(L("Cancel")) { dismiss() }
                .keyboardShortcut(.cancelAction)
                .disabled(running)
            Button(buttonTitle(items.count)) { run(items) }
                .buttonStyle(.borderedProminent)
                .tint(action == .delete ? .red : .accentColor)
                .keyboardShortcut(.defaultAction)
                .disabled(running || report.blocking || items.isEmpty
                          || (action == .delete && confirmText.trimmingCharacters(in: .whitespaces).lowercased() != confirmWord.lowercased()))
        }
        .padding(.top, 20)
    }

    private func buttonTitle(_ n: Int) -> String {
        switch action {
        case .stage: return L("Move %@ Items", Fmt.number(n))
        case .trash: return L("Move to Trash")
        case .delete: return L("Delete %@ Items", Fmt.number(n))
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
        let count = Fmt.number(outcome.done.count)
        let freed = Fmt.bytes(outcome.done.reduce(0) { $0 + $1.size })
        Text(outcome.failures.isEmpty ? L("Done") : L("Partly done")).font(.title3.weight(.semibold))
        Text(action == .stage ? L("Moved %@ items to the staging folder, freeing %@.", count, freed)
             : action == .trash ? L("Moved %@ items to the Trash, freeing %@.", count, freed)
             : L("Deleted %@ items, freeing %@.", count, freed))
            .foregroundStyle(.secondary)
            .padding(.top, 2)
        if !outcome.failures.isEmpty {
            Text(L("%@ items failed:", Fmt.number(outcome.failures.count))).padding(.top, 14)
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
            Button(L("Done")) { dismiss() }.keyboardShortcut(.defaultAction)
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
