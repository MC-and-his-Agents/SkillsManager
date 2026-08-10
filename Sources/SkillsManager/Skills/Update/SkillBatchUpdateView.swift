import SwiftUI

struct SkillBatchUpdateView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(SkillBatchUpdateViewModel.self) private var model
    @State private var query = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            header
            stateBanner
            ScrollViewReader { proxy in
                List(visibleItems) { item in
                    SkillBatchUpdateRow(item: item)
                }
                .listStyle(.inset)
                .frame(minHeight: 340)
                .searchable(
                    text: $query,
                    prompt: Text("Filter batch updates", bundle: .module)
                )
                .overlay {
                    if !model.items.isEmpty, visibleItems.isEmpty {
                        ContentUnavailableView(
                            "No matching Skills",
                            systemImage: "magnifyingglass",
                            description: Text("Clear the filter to restore the complete batch.", bundle: .module)
                        )
                    }
                }
                .onChange(of: model.activeSkillID) { _, skillID in
                    guard let skillID,
                          visibleItems.contains(where: { $0.skillID == skillID }) else {
                        return
                    }
                    withAnimation { proxy.scrollTo(skillID, anchor: .center) }
                }
            }
            controls
        }
        .padding(20)
        .frame(minWidth: 680, minHeight: 520)
        .interactiveDismissDisabled(!model.controls.canClose)
    }

    private var visibleItems: [SkillBatchUpdateItem] {
        SkillBatchUpdatePresentation.filteredItems(model.items, query: query)
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Batch Updates", bundle: .module)
                .font(.title2.bold())
            Text("Check managed Skills, review every conflict, then update selected items.", bundle: .module)
                .foregroundStyle(.secondary)
            Text(
                "Batch update summary: \(SkillBatchUpdatePresentation.summary(model.summary))",
                bundle: .module
            )
                .font(.caption)
                .foregroundStyle(.secondary)
                .accessibilityLabel(Text(
                    "Batch update summary: \(SkillBatchUpdatePresentation.summary(model.summary))",
                    bundle: .module
                )
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
            Label {
                Text("No managed Skills are available.", bundle: .module)
            } icon: {
                Image(systemName: "tray")
            }
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
            Label {
                Text(
                    model.summary[.failed] > 0 || model.summary[.needsAttention] > 0
                        ? "Batch finished with items that need review."
                        : "Batch finished.",
                    bundle: .module
                )
            } icon: {
                Image(
                    systemName:
                        model.summary[.failed] > 0 || model.summary[.needsAttention] > 0
                            ? "exclamationmark.triangle"
                            : "checkmark.circle"
                )
            }
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
            Text(verbatim: localized(title))
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(Text(verbatim: localized(title)))
        .accessibilityValue(Text(
            "\(model.summary.completed) of \(model.summary.total)",
            bundle: .module
        ))
    }

    private var controls: some View {
        HStack {
            Button {
                Task { await model.checkAll() }
            } label: {
                Text("Check All", bundle: .module)
            }
            .keyboardShortcut("r", modifiers: [.command, .shift])
            .disabled(!model.controls.canCheck)

            Button {
                model.selectReady()
            } label: {
                Text("Select Ready", bundle: .module)
            }
            .disabled(!model.controls.canSelectReady)

            Button {
                Task { await model.executeSelected() }
            } label: {
                Text("Update Selected", bundle: .module)
            }
            .buttonStyle(.borderedProminent)
            .disabled(!model.controls.canUpdate)
            .accessibilityLabel(Text("Update Selected", bundle: .module))

            if model.controls.canStop {
                Button {
                    model.stop()
                } label: {
                    Text(model.stopRequested ? "Stopping…" : "Stop", bundle: .module)
                }
                .disabled(model.stopRequested)
                .keyboardShortcut(.cancelAction)
                .accessibilityLabel(Text("Stop after the current Skill", bundle: .module))
            }

            Spacer()

            Button {
                dismiss()
            } label: {
                Text("Close", bundle: .module)
            }
            .keyboardShortcut(.cancelAction)
            .disabled(!model.controls.canClose)
        }
    }

    private func localized(_ value: String) -> String {
        String(localized: String.LocalizationValue(value), bundle: .module)
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
                    Button {
                        Task { await model.retry(item.skillID) }
                    } label: {
                        Text("Retry", bundle: .module)
                    }
                    .disabled(model.operationActive)
                    .accessibilityLabel(Text("Recheck \(item.displayName)", bundle: .module))
                }
            }

            if item.phase == .decisionRequired {
                ForEach(item.scopes) { scope in
                    Picker(
                        scope.title,
                        selection: decisionBinding(scope.scopeKey)
                    ) {
                        Text("Choose an action", bundle: .module)
                            .tag(nil as ManagedSkillUpdateCopyDecision?)
                        ForEach(ManagedSkillUpdateCopyDecision.allCases, id: \.self) {
                            Text($0.batchDisplayName)
                                .tag($0 as ManagedSkillUpdateCopyDecision?)
                        }
                    }
                    .disabled(model.operationActive)
                    .accessibilityLabel(Text("Copy decision for \(scope.title)", bundle: .module))
                }
            }
        }
        .padding(.vertical, 6)
    }

    @ViewBuilder
    private var selection: some View {
        if item.isActionable {
            Toggle(
                isOn: Binding(
                    get: { item.isSelected },
                    set: { model.select(item.skillID, selected: $0) }
                )
            ) {
                Text("Select \(item.displayName)", bundle: .module)
            }
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

    private func localized(_ value: String) -> String {
        String(localized: String.LocalizationValue(value), bundle: .module)
    }
}
