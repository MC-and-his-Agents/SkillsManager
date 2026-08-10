import SwiftUI

struct SkillDiscoveryBatchView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(SkillStore.self) private var store
    @Environment(SkillDiscoveryViewModel.self) private var discoveryModel
    @Environment(SkillDiscoveryBatchViewModel.self) private var model

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            header
            if let message = model.errorMessage {
                Label(message, systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
                    .accessibilityElement(children: .combine)
            }
            content
            controls
        }
        .padding(20)
        .frame(minWidth: 720, minHeight: 560)
        .interactiveDismissDisabled(!model.canClose)
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Batch Import", bundle: .module)
                .font(.title2.bold())
            Text("Review discovered local Skills, then import them in a safe, stable order.", bundle: .module)
                .foregroundStyle(.secondary)
            Text(summaryText)
                .font(.caption)
                .foregroundStyle(.secondary)
                .accessibilityElement(children: .combine)
        }
    }

    @ViewBuilder
    private var content: some View {
        switch model.state {
        case .idle:
            ContentUnavailableView(
                localized("No Discovery candidates"),
                systemImage: "tray",
                description: Text("Refresh Discovery before opening Batch Import.", bundle: .module)
            )
        case .selecting:
            selectionContent
        case .preparing:
            progressContent("Preparing secure previews…")
        case .ready:
            previewContent
        case .executing:
            executionContent
        case .completed:
            resultsContent
        }
    }

    private var selectionContent: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Button {
                    model.selectAllSafe()
                } label: {
                    Text("Select safe", bundle: .module)
                }
                    .keyboardShortcut("a", modifiers: [.command, .shift])
                    .disabled(model.availableCandidateCount == 0)
                Button {
                    model.clearSelection()
                } label: {
                    Text("Clear", bundle: .module)
                }
                    .keyboardShortcut(.delete, modifiers: [.command])
                    .disabled(model.selectedCount == 0)
                Spacer()
                Text("\(model.selectedCount) selected", bundle: .module)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            ManagedInstallScopePicker(
                mode: modeBinding,
                selectedAgents: agentsBinding,
                isDisabled: false
            )

            List(model.candidates) { candidate in
                candidateRow(candidate)
            }
            .listStyle(.inset)
            .frame(minHeight: 310)
        }
    }

    private func candidateRow(
        _ candidate: SkillDiscoveryBatchCandidate
    ) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Toggle(
                isOn: Binding(
                    get: { model.isSelected(candidate.id) },
                    set: { _ in model.toggleSelection(candidate.id) }
                )
            ) {
                VStack(alignment: .leading, spacing: 3) {
                    Text(candidate.observation.displayName)
                        .font(.headline)
                    Text(localized(candidate.observation.status.displayName))
                        .font(.caption)
                        .foregroundStyle(candidate.observation.status.tint)
                    if let reason = candidate.selectionBlockReason
                        ?? candidate.observation.reason?.displayName {
                        Text(localized(reason))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    if let source = candidate.aliases.first {
                        Text(source.url.path)
                            .font(.caption.monospaced())
                            .foregroundStyle(.secondary)
                            .textSelection(.enabled)
                    }
                    if candidate.aliases.count > 1 {
                        Text("+\(candidate.aliases.count - 1) verified alias locations", bundle: .module)
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .toggleStyle(.checkbox)
            .disabled(!candidate.isSelectable)
            .accessibilityLabel(Text(candidate.observation.displayName))
            .accessibilityValue(Text(candidateAccessibilityValue(candidate)))

            if candidate.observation.status == .conflict,
               candidate.allowedActions.contains(.importNew) {
                Button {
                    model.setAction(.importNew, for: candidate.id)
                } label: {
                    Text("Import as new", bundle: .module)
                }
                .buttonStyle(.bordered)
                .disabled(model.isSelected(candidate.id))
                .accessibilityHint(Text(
                    "Explicitly selects this conflict for an independent import.",
                    bundle: .module
                ))
            }
        }
        .padding(.vertical, 4)
    }

    private var previewContent: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label {
                Text(
                    "Nothing has been written. Confirm once to begin the ordered import.",
                    bundle: .module
                )
            } icon: {
                Image(systemName: "eye")
            }
            .foregroundStyle(.secondary)
            List(model.preview?.items ?? []) { item in
                previewRow(item)
            }
            .listStyle(.inset)
            .frame(minHeight: 350)
        }
    }

    private func previewRow(
        _ item: SkillDiscoveryBatchPreviewItem
    ) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack {
                Text(item.displayName).font(.headline)
                Spacer()
                Text(actionName(item.action))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            if let slug = item.distributionSlug {
                LabeledContent {
                    Text(slug.value)
                } label: {
                    Text("Slug", bundle: .module)
                }
            }
            if let source = item.sourceURLs.first {
                LabeledContent {
                    Text(source.path)
                } label: {
                    Text("Source", bundle: .module)
                }
            }
            if let plan = item.plan {
                LabeledContent {
                    Text(localized(distributionName(plan.status)))
                } label: {
                    Text("Distribution", bundle: .module)
                }
                if !plan.conflicts.isEmpty {
                    Text(plan.conflicts.map(\.reason.rawValue).joined(separator: ", "))
                        .font(.caption)
                        .foregroundStyle(.orange)
                }
            }
            if let reason = item.reason {
                Label {
                    Text(verbatim: reason)
                } icon: {
                    Image(systemName: item.token == nil ? "xmark.circle" : "info.circle")
                }
                    .font(.caption)
                    .foregroundStyle(item.token == nil ? .orange : .secondary)
            }
        }
        .padding(.vertical, 4)
        .accessibilityElement(children: .combine)
    }

    private var executionContent: some View {
        VStack(alignment: .leading, spacing: 12) {
            progressContent("Importing selected Skills…")
            List(model.resultItems) { result in
                resultRow(result)
            }
            .listStyle(.inset)
            .frame(minHeight: 350)
        }
    }

    private var resultsContent: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label {
                Text(
                    model.summary.needsAttention == 0
                        ? "Batch import finished."
                        : "Batch import finished with items that need attention.",
                    bundle: .module
                )
            } icon: {
                Image(systemName: model.summary.needsAttention == 0
                    ? "checkmark.circle"
                    : "exclamationmark.triangle")
            }
            .foregroundStyle(model.summary.needsAttention == 0 ? .green : .orange)
            .accessibilityElement(children: .combine)
            List(model.resultItems) { result in
                resultRow(result)
            }
            .listStyle(.inset)
            .frame(minHeight: 350)
        }
    }

    private func resultRow(
        _ result: SkillDiscoveryBatchResultItem
    ) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(result.displayName).font(.headline)
            LabeledContent {
                Text(verbatim: managementName(result.management))
            } label: {
                Text("Management", bundle: .module)
            }
            LabeledContent {
                Text(verbatim: distributionName(result.distribution))
            } label: {
                Text("Distribution", bundle: .module)
            }
            if let source = result.sourceURLs.first {
                Text(source.path)
                    .font(.caption.monospaced())
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
            }
        }
        .padding(.vertical, 4)
        .accessibilityElement(children: .combine)
    }

    private func progressContent(_ title: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            ProgressView(
                value: Double(model.resultItems.count),
                total: Double(max(model.preview?.items.count ?? model.selectedCount, 1))
            )
            Text(verbatim: localized(title))
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(Text(verbatim: localized(title)))
        .accessibilityValue(Text(verbatim: localized(
            "\(model.resultItems.count) of \(model.preview?.items.count ?? model.selectedCount)"
        )))
    }

    @ViewBuilder
    private var controls: some View {
        HStack {
            if model.state == .selecting || model.state == .ready {
                Button {
                    model.cancelPreview()
                    dismiss()
                } label: {
                    Text("Cancel", bundle: .module)
                }
                .keyboardShortcut(.cancelAction)
            } else if model.state == .completed {
                Button {
                    model.reset()
                    dismiss()
                } label: {
                    Text("Close", bundle: .module)
                }
                .keyboardShortcut(.cancelAction)
            }
            Spacer()
            if model.state == .selecting {
                Button {
                    Task { await model.preparePreview() }
                } label: {
                    Label {
                        Text("Preview selected", bundle: .module)
                    } icon: {
                        Image(systemName: "eye")
                    }
                }
                .buttonStyle(.borderedProminent)
                .disabled(!model.canPreview)
                .keyboardShortcut(.defaultAction)
            } else if model.state == .ready {
                Button {
                    Task {
                        await model.confirm {
                            async let local: Void = store.loadSkills()
                            async let discovery: Void = discoveryModel.refresh()
                            _ = await (local, discovery)
                        }
                    }
                } label: {
                    Label {
                        Text("Import selected", bundle: .module)
                    } icon: {
                        Image(systemName: "tray.and.arrow.down")
                    }
                }
                .buttonStyle(.borderedProminent)
                .disabled(!model.canConfirm)
                .keyboardShortcut(.defaultAction)
            }
        }
    }

    private var summaryText: String {
        switch model.state {
        case .completed:
            "\(model.summary.created) \(localized("created")) · "
                + "\(model.summary.claimed) \(localized("claimed")) · "
                + "\(model.summary.skipped) \(localized("skipped")) · "
                + "\(model.summary.failed) \(localized("failed"))"
        default:
            "\(model.availableCandidateCount) \(localized("candidates available")) · "
                + "\(model.selectedCount) \(localized("selected"))"
        }
    }

    private var modeBinding: Binding<ManagedInstallDistributionMode> {
        Binding(
            get: { model.distributionMode },
            set: { model.distributionMode = $0 }
        )
    }

    private var agentsBinding: Binding<Set<SkillPlatform>> {
        Binding(
            get: { model.selectedAgents },
            set: { model.selectedAgents = $0 }
        )
    }

    private func candidateAccessibilityValue(
        _ candidate: SkillDiscoveryBatchCandidate
    ) -> String {
        let selection = localized(model.isSelected(candidate.id) ? "Selected" : "Not selected")
        let action = model.action(for: candidate.id).map(actionName)
            .map(localized) ?? localized("No action selected")
        return [selection, localized(candidate.observation.status.displayName), action]
            .joined(separator: ", ")
    }

    private func actionName(_ action: ManagedSkillImportAction) -> String {
        switch action {
        case .importNew: "Import as new"
        case .claimExisting: "Claim existing"
        }
    }

    private func distributionName(_ status: DistributionPlanStatus) -> String {
        switch status {
        case .executable: "Ready to enable with Symlink"
        case .noOp: "No changes"
        case .blocked: "Blocked; Skill remains managed"
        }
    }

    private func managementName(
        _ result: SkillDiscoveryBatchManagementResult
    ) -> String {
        switch result {
        case .created: localized("Created")
        case .claimed: localized("Claimed; existing bindings preserved")
        case .alreadyManaged: localized("Already managed")
        case .failed(let message): "\(localized("Failed")): \(message)"
        case .skipped(let reason): "\(localized("Skipped")): \(reason)"
        }
    }

    private func distributionName(
        _ result: SkillDiscoveryBatchDistributionResult
    ) -> String {
        switch result {
        case .distributed: localized("Distributed")
        case .noChanges: localized("No changes")
        case .managedUndistributed: localized("Managed but not enabled")
        case .indeterminate(let message): "\(localized("Needs attention")): \(message)"
        case .notApplicable(let message): message
        }
    }

    private func localized(_ value: String) -> String {
        String(localized: String.LocalizationValue(value), bundle: .module)
    }
}
