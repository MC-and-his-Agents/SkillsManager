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
                            String(localized: "No matching Skills", bundle: .module),
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
            Text(String(
                localized: LocalizedStringResource( "Batch update summary: %@",
                defaultValue: "Batch update summary: \(localizedSummary())",
                bundle: .module
            )))
                .font(.caption)
                .foregroundStyle(.secondary)
                .accessibilityLabel(Text(String(
                    localized: LocalizedStringResource( "Batch update summary: %@",
                    defaultValue: "Batch update summary: \(localizedSummary())",
                    bundle: .module
                ))))
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
            progressText("Checking Skills…")
        case .executing:
            if model.stopRequested {
                progressText("Finishing the current Skill before stopping…")
            } else {
                progressText("Updating selected Skills…")
            }
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

    private func progressText(_ title: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            ProgressView(
                value: Double(model.summary.completed),
                total: Double(max(model.summary.total, 1))
            )
            Text(verbatim: progressTitleText(title))
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(Text(verbatim: progressTitleText(title)))
        .accessibilityValue(Text(String(
            localized: LocalizedStringResource( "%lld of %lld",
            defaultValue: "\(model.summary.completed) of \(model.summary.total)",
            bundle: .module
        ))))
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

    private func localizedSummary() -> String {
        if model.summary.total == 0 {
            return String(localized: "No managed Skills.", bundle: .module)
        }
        let values = SkillBatchUpdateResult.allCases.compactMap { result -> String? in
            let count = model.summary[result]
            guard count > 0 else { return nil }
            let title = resultText(result)
            return String(
                localized: LocalizedStringResource( "%@: %lld",
                defaultValue: "\(title): \(count)",
                bundle: .module
            ))
        }
        if values.isEmpty {
            return localizedCompletionText(
                completed: model.summary.completed,
                total: model.summary.total
            )
        }
        let completed = localizedCompletionText(
            completed: model.summary.completed,
            total: model.summary.total
        )
        return completed + " " + values.joined(separator: ", ")
    }

    private func localizedCompletionText(completed: Int, total: Int) -> String {
        String(
            localized: LocalizedStringResource( "%lld of %lld complete.",
            defaultValue: "\(completed) of \(total) complete.",
            bundle: .module
        ))
    }

    private func resultText(_ result: SkillBatchUpdateResult) -> String {
        return switch result {
        case .updated: String(localized: "Updated", bundle: .module)
        case .upToDate: String(localized: "Up to date", bundle: .module)
        case .forked: String(localized: "Updated; local changes kept as Fork", bundle: .module)
        case .conflict: String(localized: "Conflict", bundle: .module)
        case .skipped: String(localized: "Skipped", bundle: .module)
        case .cancelled: String(localized: "Cancelled", bundle: .module)
        case .failed: String(localized: "Failed", bundle: .module)
        case .needsAttention: String(localized: "Needs attention", bundle: .module)
        }
    }

    private func progressTitleText(_ title: String) -> String {
        return switch title {
        case "Checking Skills…": String(localized: "Checking Skills…", bundle: .module)
        case "Finishing the current Skill before stopping…":
            String(localized: "Finishing the current Skill before stopping…", bundle: .module)
        case "Updating selected Skills…": String(localized: "Updating selected Skills…", bundle: .module)
        default: title
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
                        Text(verbatim: titleText(for: item, presentation: presentation))
                        if let detail = detailText(for: item, presentation: presentation) {
                            Text(verbatim: detail)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
                .accessibilityElement(children: .combine)
                .accessibilityLabel(item.displayName)
                .accessibilityValue(Text(verbatim: accessibilityValue(for: item)))
                Spacer()
                if item.allowsRetry {
                    Button {
                        Task { await model.retry(item.skillID) }
                    } label: {
                        Text("Retry", bundle: .module)
                    }
                    .disabled(model.operationActive)
                    .accessibilityLabel(Text(String(
                        localized: LocalizedStringResource( "Recheck %@",
                        defaultValue: "Recheck \(item.displayName)",
                        bundle: .module
                    ))))
                }
            }

            if item.phase == .decisionRequired {
                ForEach(item.scopes) { scope in
                    Picker(
                        scopeTitle(scope),
                        selection: decisionBinding(scope.scopeKey)
                    ) {
                        Text("Choose an action", bundle: .module)
                            .tag(nil as ManagedSkillUpdateCopyDecision?)
                        ForEach(ManagedSkillUpdateCopyDecision.allCases, id: \.self) {
                            Text(verbatim: decisionText($0))
                                .tag($0 as ManagedSkillUpdateCopyDecision?)
                        }
                    }
                    .disabled(model.operationActive)
                    .accessibilityLabel(Text(String(
                        localized: LocalizedStringResource( "Copy decision for %@",
                        defaultValue: "Copy decision for \(scopeTitle(scope))",
                        bundle: .module
                    ))))
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
                Text(String(
                    localized: LocalizedStringResource( "Select %@",
                    defaultValue: "Select \(item.displayName)",
                    bundle: .module
                )))
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

    private func titleText(
        for item: SkillBatchUpdateItem,
        presentation: SkillBatchUpdatePresentation.Row
    ) -> String {
        if case .result(let result, _) = item.phase {
            return resultText(result)
        }
        return switch presentation.title {
        case "Waiting": String(localized: "Waiting", bundle: .module)
        case "Checking": String(localized: "Checking", bundle: .module)
        case "Update available": String(localized: "Update available", bundle: .module)
        case "Copy decision required": String(localized: "Copy decision required", bundle: .module)
        case "Preparing": String(localized: "Preparing", bundle: .module)
        case "Updating": String(localized: "Updating", bundle: .module)
        default: presentation.title
        }
    }

    private func detailText(
        for item: SkillBatchUpdateItem,
        presentation: SkillBatchUpdatePresentation.Row
    ) -> String? {
        if case .result(_, let detail) = item.phase, detail != nil {
            return detail
        }
        return switch presentation.detail {
        case "Reading the local Skill and remote source.":
            String(localized: "Reading the local Skill and remote source.", bundle: .module)
        case "This Skill can be updated safely.":
            String(localized: "This Skill can be updated safely.", bundle: .module)
        case "Choose how to handle every modified Copy.":
            String(localized: "Choose how to handle every modified Copy.", bundle: .module)
        case "Revalidating the Skill and remote source.":
            String(localized: "Revalidating the Skill and remote source.", bundle: .module)
        case "Backing up, replacing, and refreshing distribution.":
            String(localized: "Backing up, replacing, and refreshing distribution.", bundle: .module)
        case "The managed Skill and its distribution are current.":
            String(localized: "The managed Skill and its distribution are current.", bundle: .module)
        case "No update was required.":
            String(localized: "No update was required.", bundle: .module)
        case "The parent Skill was updated and local changes are independent.":
            String(localized: "The parent Skill was updated and local changes are independent.", bundle: .module)
        case "Recheck after resolving local or remote changes.":
            String(localized: "Recheck after resolving local or remote changes.", bundle: .module)
        case "This available update was not selected.":
            String(localized: "This available update was not selected.", bundle: .module)
        case "No update was started for this Skill.":
            String(localized: "No update was started for this Skill.", bundle: .module)
        case "The operation did not complete.":
            String(localized: "The operation did not complete.", bundle: .module)
        case "Review this Skill before trying again.":
            String(localized: "Review this Skill before trying again.", bundle: .module)
        default:
            presentation.detail
        }
    }

    private func accessibilityValue(for item: SkillBatchUpdateItem) -> String {
        switch item.phase {
        case .queued:
            return String(
                localized: LocalizedStringResource( "%@, waiting",
                defaultValue: "\(item.displayName), waiting",
                bundle: .module
            ))
        case .checking:
            return String(
                localized: LocalizedStringResource( "%@, checking for updates",
                defaultValue: "\(item.displayName), checking for updates",
                bundle: .module
            ))
        case .ready:
            return String(
                localized: LocalizedStringResource( "%@, update available",
                defaultValue: "\(item.displayName), update available",
                bundle: .module
            ))
        case .decisionRequired:
            return String(
                localized: LocalizedStringResource( "%@, Copy decision required",
                defaultValue: "\(item.displayName), Copy decision required",
                bundle: .module
            ))
        case .preparing:
            return String(
                localized: LocalizedStringResource( "%@, preparing update",
                defaultValue: "\(item.displayName), preparing update",
                bundle: .module
            ))
        case .updating:
            return String(
                localized: LocalizedStringResource( "%@, updating",
                defaultValue: "\(item.displayName), updating",
                bundle: .module
            ))
        case .result(let result, _):
            let resultText = resultText(result)
            return String(
                localized: LocalizedStringResource( "%@, %@",
                defaultValue: "\(item.displayName), \(resultText)",
                bundle: .module
            ))
        }
    }

    private func scopeTitle(_ scope: SkillBatchUpdateScope) -> String {
        if scope.scopeKey == "global" {
            return String(localized: "Global shared target", bundle: .module)
        }
        let prefix = "agent:"
        guard scope.scopeKey.hasPrefix(prefix) else { return scope.title }
        let key = String(scope.scopeKey.dropFirst(prefix.count))
        switch key {
        case SkillPlatform.codex.storageKey: return String(localized: "Codex", bundle: .module)
        case SkillPlatform.claude.storageKey: return String(localized: "Claude Code", bundle: .module)
        case SkillPlatform.opencode.storageKey: return String(localized: "OpenCode", bundle: .module)
        case SkillPlatform.copilot.storageKey: return String(localized: "GitHub Copilot", bundle: .module)
        default: return scope.title
        }
    }

    private func decisionText(_ decision: ManagedSkillUpdateCopyDecision) -> String {
        return switch decision {
        case .discard: String(localized: "Discard local changes", bundle: .module)
        case .fork: String(localized: "Keep changes as a Fork", bundle: .module)
        case .cancel: String(localized: "Cancel this Skill update", bundle: .module)
        }
    }

    private func resultText(_ result: SkillBatchUpdateResult) -> String {
        return switch result {
        case .updated: String(localized: "Updated", bundle: .module)
        case .upToDate: String(localized: "Up to date", bundle: .module)
        case .forked: String(localized: "Updated; local changes kept as Fork", bundle: .module)
        case .conflict: String(localized: "Conflict", bundle: .module)
        case .skipped: String(localized: "Skipped", bundle: .module)
        case .cancelled: String(localized: "Cancelled", bundle: .module)
        case .failed: String(localized: "Failed", bundle: .module)
        case .needsAttention: String(localized: "Needs attention", bundle: .module)
        }
    }
}
