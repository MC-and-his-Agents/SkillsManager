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
                    prompt: Text("Filter batch updates", bundle: SkillsManagerLocalizationResources.bundle)
                )
                .overlay {
                    if !model.items.isEmpty, visibleItems.isEmpty {
                        ContentUnavailableView(
                            String(localized: "No matching Skills", bundle: SkillsManagerLocalizationResources.bundle),
                            systemImage: "magnifyingglass",
                            description: Text("Clear the filter to restore the complete batch.", bundle: SkillsManagerLocalizationResources.bundle)
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
            Text("Batch Updates", bundle: SkillsManagerLocalizationResources.bundle)
                .font(.title2.bold())
            Text("Check managed Skills, review every conflict, then update selected items.", bundle: SkillsManagerLocalizationResources.bundle)
                .foregroundStyle(.secondary)
            Text(String(
                localized: LocalizedStringResource(
            "Batch update summary: \(localizedSummary())",
            bundle: SkillsManagerLocalizationResources.bundle
        )))
                .font(.caption)
                .foregroundStyle(.secondary)
                .accessibilityLabel(Text(String(
                    localized: LocalizedStringResource(
            "Batch update summary: \(localizedSummary())",
            bundle: SkillsManagerLocalizationResources.bundle
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
                Text("No managed Skills are available.", bundle: SkillsManagerLocalizationResources.bundle)
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
                    bundle: SkillsManagerLocalizationResources.bundle
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
            localized: LocalizedStringResource(
            "\(model.summary.completed) of \(model.summary.total)",
            bundle: SkillsManagerLocalizationResources.bundle
        ))))
    }

    private var controls: some View {
        HStack {
            Button {
                Task { await model.checkAll() }
            } label: {
                Text("Check All", bundle: SkillsManagerLocalizationResources.bundle)
            }
            .keyboardShortcut("r", modifiers: [.command, .shift])
            .disabled(!model.controls.canCheck)

            Button {
                model.selectReady()
            } label: {
                Text("Select Ready", bundle: SkillsManagerLocalizationResources.bundle)
            }
            .disabled(!model.controls.canSelectReady)

            Button {
                Task { await model.executeSelected() }
            } label: {
                Text("Update Selected", bundle: SkillsManagerLocalizationResources.bundle)
            }
            .buttonStyle(.borderedProminent)
            .disabled(!model.controls.canUpdate)
            .accessibilityLabel(Text("Update Selected", bundle: SkillsManagerLocalizationResources.bundle))

            if model.controls.canStop {
                Button {
                    model.stop()
                } label: {
                    Text(model.stopRequested ? "Stopping…" : "Stop", bundle: SkillsManagerLocalizationResources.bundle)
                }
                .disabled(model.stopRequested)
                .keyboardShortcut(.cancelAction)
                .accessibilityLabel(Text("Stop after the current Skill", bundle: SkillsManagerLocalizationResources.bundle))
            }

            Spacer()

            Button {
                dismiss()
            } label: {
                Text("Close", bundle: SkillsManagerLocalizationResources.bundle)
            }
            .keyboardShortcut(.cancelAction)
            .disabled(!model.controls.canClose)
        }
    }

    private func localizedSummary() -> String {
        if model.summary.total == 0 {
            return String(localized: "No managed Skills.", bundle: SkillsManagerLocalizationResources.bundle)
        }
        let values = SkillBatchUpdateResult.allCases.compactMap { result -> String? in
            let count = model.summary[result]
            guard count > 0 else { return nil }
            let title = resultText(result)
            return String(
                localized: LocalizedStringResource(
            "\(title): \(count)",
            bundle: SkillsManagerLocalizationResources.bundle
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
            localized: LocalizedStringResource(
            "\(completed) of \(total) complete.",
            bundle: SkillsManagerLocalizationResources.bundle
        ))
    }

    private func resultText(_ result: SkillBatchUpdateResult) -> String {
        return switch result {
        case .updated: String(localized: "Updated", bundle: SkillsManagerLocalizationResources.bundle)
        case .upToDate: String(localized: "Up to date", bundle: SkillsManagerLocalizationResources.bundle)
        case .forked: String(localized: "Updated; local changes kept as Fork", bundle: SkillsManagerLocalizationResources.bundle)
        case .conflict: String(localized: "Conflict", bundle: SkillsManagerLocalizationResources.bundle)
        case .skipped: String(localized: "Skipped", bundle: SkillsManagerLocalizationResources.bundle)
        case .cancelled: String(localized: "Cancelled", bundle: SkillsManagerLocalizationResources.bundle)
        case .failed: String(localized: "Failed", bundle: SkillsManagerLocalizationResources.bundle)
        case .needsAttention: String(localized: "Needs attention", bundle: SkillsManagerLocalizationResources.bundle)
        }
    }

    private func progressTitleText(_ title: String) -> String {
        return switch title {
        case "Checking Skills…": String(localized: "Checking Skills…", bundle: SkillsManagerLocalizationResources.bundle)
        case "Finishing the current Skill before stopping…":
            String(localized: "Finishing the current Skill before stopping…", bundle: SkillsManagerLocalizationResources.bundle)
        case "Updating selected Skills…": String(localized: "Updating selected Skills…", bundle: SkillsManagerLocalizationResources.bundle)
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
                        Text("Retry", bundle: SkillsManagerLocalizationResources.bundle)
                    }
                    .disabled(model.operationActive)
                    .accessibilityLabel(Text(String(
                        localized: LocalizedStringResource(
            "Recheck \(item.displayName)",
            bundle: SkillsManagerLocalizationResources.bundle
        ))))
                }
            }

            if item.phase == .decisionRequired {
                ForEach(item.scopes) { scope in
                    Picker(
                        scopeTitle(scope),
                        selection: decisionBinding(scope.scopeKey)
                    ) {
                        Text("Choose an action", bundle: SkillsManagerLocalizationResources.bundle)
                            .tag(nil as ManagedSkillUpdateCopyDecision?)
                        ForEach(ManagedSkillUpdateCopyDecision.allCases, id: \.self) {
                            Text(verbatim: decisionText($0))
                                .tag($0 as ManagedSkillUpdateCopyDecision?)
                        }
                    }
                    .disabled(model.operationActive)
                    .accessibilityLabel(Text(String(
                        localized: LocalizedStringResource(
            "Copy decision for \(scopeTitle(scope))",
            bundle: SkillsManagerLocalizationResources.bundle
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
                    localized: LocalizedStringResource(
            "Select \(item.displayName)",
            bundle: SkillsManagerLocalizationResources.bundle
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
        case "Waiting": String(localized: "Waiting", bundle: SkillsManagerLocalizationResources.bundle)
        case "Checking": String(localized: "Checking", bundle: SkillsManagerLocalizationResources.bundle)
        case "Update available": String(localized: "Update available", bundle: SkillsManagerLocalizationResources.bundle)
        case "Copy decision required": String(localized: "Copy decision required", bundle: SkillsManagerLocalizationResources.bundle)
        case "Preparing": String(localized: "Preparing", bundle: SkillsManagerLocalizationResources.bundle)
        case "Updating": String(localized: "Updating", bundle: SkillsManagerLocalizationResources.bundle)
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
            String(localized: "Reading the local Skill and remote source.", bundle: SkillsManagerLocalizationResources.bundle)
        case "This Skill can be updated safely.":
            String(localized: "This Skill can be updated safely.", bundle: SkillsManagerLocalizationResources.bundle)
        case "Choose how to handle every modified Copy.":
            String(localized: "Choose how to handle every modified Copy.", bundle: SkillsManagerLocalizationResources.bundle)
        case "Revalidating the Skill and remote source.":
            String(localized: "Revalidating the Skill and remote source.", bundle: SkillsManagerLocalizationResources.bundle)
        case "Backing up, replacing, and refreshing distribution.":
            String(localized: "Backing up, replacing, and refreshing distribution.", bundle: SkillsManagerLocalizationResources.bundle)
        case "The managed Skill and its distribution are current.":
            String(localized: "The managed Skill and its distribution are current.", bundle: SkillsManagerLocalizationResources.bundle)
        case "No update was required.":
            String(localized: "No update was required.", bundle: SkillsManagerLocalizationResources.bundle)
        case "The parent Skill was updated and local changes are independent.":
            String(localized: "The parent Skill was updated and local changes are independent.", bundle: SkillsManagerLocalizationResources.bundle)
        case "Recheck after resolving local or remote changes.":
            String(localized: "Recheck after resolving local or remote changes.", bundle: SkillsManagerLocalizationResources.bundle)
        case "This available update was not selected.":
            String(localized: "This available update was not selected.", bundle: SkillsManagerLocalizationResources.bundle)
        case "No update was started for this Skill.":
            String(localized: "No update was started for this Skill.", bundle: SkillsManagerLocalizationResources.bundle)
        case "The operation did not complete.":
            String(localized: "The operation did not complete.", bundle: SkillsManagerLocalizationResources.bundle)
        case "Review this Skill before trying again.":
            String(localized: "Review this Skill before trying again.", bundle: SkillsManagerLocalizationResources.bundle)
        default:
            presentation.detail
        }
    }

    private func accessibilityValue(for item: SkillBatchUpdateItem) -> String {
        switch item.phase {
        case .queued:
            return String(
                localized: LocalizedStringResource(
            "\(item.displayName), waiting",
            bundle: SkillsManagerLocalizationResources.bundle
        ))
        case .checking:
            return String(
                localized: LocalizedStringResource(
            "\(item.displayName), checking for updates",
            bundle: SkillsManagerLocalizationResources.bundle
        ))
        case .ready:
            return String(
                localized: LocalizedStringResource(
            "\(item.displayName), update available",
            bundle: SkillsManagerLocalizationResources.bundle
        ))
        case .decisionRequired:
            return String(
                localized: LocalizedStringResource(
            "\(item.displayName), Copy decision required",
            bundle: SkillsManagerLocalizationResources.bundle
        ))
        case .preparing:
            return String(
                localized: LocalizedStringResource(
            "\(item.displayName), preparing update",
            bundle: SkillsManagerLocalizationResources.bundle
        ))
        case .updating:
            return String(
                localized: LocalizedStringResource(
            "\(item.displayName), updating",
            bundle: SkillsManagerLocalizationResources.bundle
        ))
        case .result(let result, _):
            let resultText = resultText(result)
            return String(
                localized: LocalizedStringResource(
            "\(item.displayName), \(resultText)",
            bundle: SkillsManagerLocalizationResources.bundle
        ))
        }
    }

    private func scopeTitle(_ scope: SkillBatchUpdateScope) -> String {
        if scope.scopeKey == "global" {
            return String(localized: "Global shared target", bundle: SkillsManagerLocalizationResources.bundle)
        }
        let prefix = "agent:"
        guard scope.scopeKey.hasPrefix(prefix) else { return scope.title }
        let key = String(scope.scopeKey.dropFirst(prefix.count))
        switch key {
        case SkillPlatform.codex.storageKey: return String(localized: "Codex", bundle: SkillsManagerLocalizationResources.bundle)
        case SkillPlatform.claude.storageKey: return String(localized: "Claude Code", bundle: SkillsManagerLocalizationResources.bundle)
        case SkillPlatform.opencode.storageKey: return String(localized: "OpenCode", bundle: SkillsManagerLocalizationResources.bundle)
        case SkillPlatform.copilot.storageKey: return String(localized: "GitHub Copilot", bundle: SkillsManagerLocalizationResources.bundle)
        default: return scope.title
        }
    }

    private func decisionText(_ decision: ManagedSkillUpdateCopyDecision) -> String {
        return switch decision {
        case .discard: String(localized: "Discard local changes", bundle: SkillsManagerLocalizationResources.bundle)
        case .fork: String(localized: "Keep changes as a Fork", bundle: SkillsManagerLocalizationResources.bundle)
        case .cancel: String(localized: "Cancel this Skill update", bundle: SkillsManagerLocalizationResources.bundle)
        }
    }

    private func resultText(_ result: SkillBatchUpdateResult) -> String {
        return switch result {
        case .updated: String(localized: "Updated", bundle: SkillsManagerLocalizationResources.bundle)
        case .upToDate: String(localized: "Up to date", bundle: SkillsManagerLocalizationResources.bundle)
        case .forked: String(localized: "Updated; local changes kept as Fork", bundle: SkillsManagerLocalizationResources.bundle)
        case .conflict: String(localized: "Conflict", bundle: SkillsManagerLocalizationResources.bundle)
        case .skipped: String(localized: "Skipped", bundle: SkillsManagerLocalizationResources.bundle)
        case .cancelled: String(localized: "Cancelled", bundle: SkillsManagerLocalizationResources.bundle)
        case .failed: String(localized: "Failed", bundle: SkillsManagerLocalizationResources.bundle)
        case .needsAttention: String(localized: "Needs attention", bundle: SkillsManagerLocalizationResources.bundle)
        }
    }
}
