import SwiftUI

struct SkillBatchUpdateView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(SkillBatchUpdateViewModel.self) private var model

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            header
            stateBanner
            List(model.items) { item in
                SkillBatchUpdateRow(item: item)
            }
            .listStyle(.inset)
            .frame(minHeight: 340)
            controls
        }
        .padding(20)
        .frame(minWidth: 680, minHeight: 520)
        .interactiveDismissDisabled(!model.controls.canClose)
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Batch Updates")
                .font(.title2.bold())
            Text("Check managed Skills, review every conflict, then update selected items.")
                .foregroundStyle(.secondary)
            Text(SkillBatchUpdatePresentation.summary(model.summary))
                .font(.caption)
                .foregroundStyle(.secondary)
                .accessibilityLabel(
                    "Batch update summary. "
                        + SkillBatchUpdatePresentation.summary(model.summary)
                )
        }
    }

    @ViewBuilder
    private var stateBanner: some View {
        switch model.state {
        case .blocked(let message):
            Label(message, systemImage: "lock.trianglebadge.exclamationmark")
                .foregroundStyle(.orange)
                .accessibilityElement(children: .combine)
        case .empty:
            Label("No managed Skills are available.", systemImage: "tray")
                .foregroundStyle(.secondary)
        case .checking:
            progress("Checking Skills…")
        case .executing:
            progress(
                model.stopRequested
                    ? "Finishing the current Skill before stopping…"
                    : "Updating selected Skills…"
            )
        case .completed:
            Label(
                model.summary[.failed] > 0 || model.summary[.needsAttention] > 0
                    ? "Batch finished with items that need review."
                    : "Batch finished.",
                systemImage:
                    model.summary[.failed] > 0 || model.summary[.needsAttention] > 0
                        ? "exclamationmark.triangle"
                        : "checkmark.circle"
            )
            .accessibilityElement(children: .combine)
        case .idle, .review:
            EmptyView()
        }
    }

    private func progress(_ title: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            ProgressView(
                value: Double(model.summary.completed),
                total: Double(max(model.summary.total, 1))
            )
            Text(title)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(title)
        .accessibilityValue("\(model.summary.completed) of \(model.summary.total)")
    }

    private var controls: some View {
        HStack {
            Button("Check All") {
                Task { await model.checkAll() }
            }
            .keyboardShortcut("r", modifiers: [.command, .shift])
            .disabled(!model.controls.canCheck)

            Button("Select Ready") {
                model.selectReady()
            }
            .disabled(!model.controls.canSelectReady)

            Button("Update Selected") {
                Task { await model.executeSelected() }
            }
            .buttonStyle(.borderedProminent)
            .disabled(!model.controls.canUpdate)
            .accessibilityLabel(
                model.selectedCount == 0
                    ? "Update Selected, no Skills selected"
                    : "Update \(model.selectedCount) selected Skills"
            )

            if model.controls.canStop {
                Button(model.stopRequested ? "Stopping…" : "Stop") {
                    model.stop()
                }
                .disabled(model.stopRequested)
                .keyboardShortcut(.cancelAction)
                .accessibilityLabel("Stop after the current Skill")
            }

            Spacer()

            Button("Close") {
                dismiss()
            }
            .keyboardShortcut(.cancelAction)
            .disabled(!model.controls.canClose)
        }
    }
}

private struct SkillBatchUpdateRow: View {
    @Environment(SkillBatchUpdateViewModel.self) private var model
    let item: SkillBatchUpdateItem

    var body: some View {
        let presentation = SkillBatchUpdatePresentation.row(for: item)
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .top, spacing: 10) {
                selection
                HStack(alignment: .top, spacing: 10) {
                    Image(systemName: presentation.systemImage)
                        .foregroundStyle(iconStyle)
                        .frame(width: 18)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(item.displayName)
                            .font(.headline)
                            .lineLimit(1)
                        Text(presentation.title)
                        if let detail = presentation.detail {
                            Text(detail)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
                .accessibilityElement(children: .combine)
                .accessibilityLabel(item.displayName)
                .accessibilityValue(presentation.accessibilityValue)
                Spacer()
                if item.allowsRetry {
                    Button("Retry") {
                        Task { await model.retry(item.skillID) }
                    }
                    .disabled(model.operationActive)
                    .accessibilityLabel("Recheck \(item.displayName)")
                }
            }

            if item.phase == .decisionRequired {
                ForEach(item.scopes) { scope in
                    Picker(
                        scope.title,
                        selection: decisionBinding(scope.scopeKey)
                    ) {
                        Text("Choose an action")
                            .tag(nil as ManagedSkillUpdateCopyDecision?)
                        ForEach(ManagedSkillUpdateCopyDecision.allCases, id: \.self) {
                            Text($0.batchDisplayName)
                                .tag($0 as ManagedSkillUpdateCopyDecision?)
                        }
                    }
                    .disabled(model.operationActive)
                    .accessibilityLabel("Copy decision for \(scope.title)")
                }
            }
        }
        .padding(.vertical, 6)
    }

    @ViewBuilder
    private var selection: some View {
        if item.isActionable {
            Toggle(
                "Select \(item.displayName)",
                isOn: Binding(
                    get: { item.isSelected },
                    set: { model.select(item.skillID, selected: $0) }
                )
            )
            .labelsHidden()
            .disabled(model.operationActive)
        }
    }

    private var iconStyle: AnyShapeStyle {
        switch item.finalResult {
        case .failed, .conflict, .needsAttention:
            AnyShapeStyle(Color.orange)
        default:
            AnyShapeStyle(.secondary)
        }
    }

    private func decisionBinding(
        _ scopeKey: String
    ) -> Binding<ManagedSkillUpdateCopyDecision?> {
        Binding(
            get: {
                model.selectedDecision(
                    skillID: item.skillID,
                    scopeKey: scopeKey
                )
            },
            set: { value in
                if let value {
                    model.choose(value, skillID: item.skillID, scopeKey: scopeKey)
                }
            }
        )
    }
}
