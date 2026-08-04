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
            Text("Batch Import")
                .font(.title2.bold())
            Text("Review discovered local Skills, then import them in a safe, stable order.")
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
                "No Discovery candidates",
                systemImage: "tray",
                description: Text("Refresh Discovery before opening Batch Import.")
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
                Button("Select safe") { model.selectAllSafe() }
                    .keyboardShortcut("a", modifiers: [.command, .shift])
                    .disabled(model.availableCandidateCount == 0)
                Button("Clear") { model.clearSelection() }
                    .keyboardShortcut(.delete, modifiers: [.command])
                    .disabled(model.selectedCount == 0)
                Spacer()
                Text("\(model.selectedCount) selected")
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
                    Text(candidate.observation.status.displayName)
                        .font(.caption)
                        .foregroundStyle(candidate.observation.status.tint)
                    if let reason = candidate.observation.reason {
                        Text(reason.displayName)
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
                        Text("+\(candidate.aliases.count - 1) verified alias locations")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .toggleStyle(.checkbox)
            .disabled(!candidate.isSelectable)
            .accessibilityLabel(candidate.observation.displayName)
            .accessibilityValue(candidateAccessibilityValue(candidate))

            if candidate.observation.status == .conflict,
               candidate.allowedActions.contains(.importNew) {
                Button("Import as new") {
                    model.setAction(.importNew, for: candidate.id)
                }
                .buttonStyle(.bordered)
                .disabled(model.isSelected(candidate.id))
                .accessibilityHint("Explicitly selects this conflict for an independent import.")
            }
        }
        .padding(.vertical, 4)
    }

    private var previewContent: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label(
                "Nothing has been written. Confirm once to begin the ordered import.",
                systemImage: "eye"
            )
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
                LabeledContent("Slug", value: slug.value)
            }
            if let source = item.sourceURLs.first {
                LabeledContent("Source", value: source.path)
            }
            if let plan = item.plan {
                LabeledContent("Distribution", value: distributionName(plan.status))
                if !plan.conflicts.isEmpty {
                    Text(plan.conflicts.map(\.reason.rawValue).joined(separator: ", "))
                        .font(.caption)
                        .foregroundStyle(.orange)
                }
            }
            if let reason = item.reason {
                Label(reason, systemImage: item.token == nil ? "xmark.circle" : "info.circle")
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
            Label(
                model.summary.needsAttention == 0
                    ? "Batch import finished."
                    : "Batch import finished with items that need attention.",
                systemImage: model.summary.needsAttention == 0
                    ? "checkmark.circle"
                    : "exclamationmark.triangle"
            )
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
            LabeledContent("Management", value: managementName(result.management))
            LabeledContent("Distribution", value: distributionName(result.distribution))
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
            Text(title)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(title)
        .accessibilityValue("\(model.resultItems.count) of \(model.preview?.items.count ?? model.selectedCount)")
    }

    @ViewBuilder
    private var controls: some View {
        HStack {
            if model.state == .selecting || model.state == .ready {
                Button("Cancel") {
                    model.cancelPreview()
                    dismiss()
                }
                .keyboardShortcut(.cancelAction)
            } else if model.state == .completed {
                Button("Close") {
                    model.reset()
                    dismiss()
                }
                .keyboardShortcut(.cancelAction)
            }
            Spacer()
            if model.state == .selecting {
                Button {
                    Task { await model.preparePreview() }
                } label: {
                    Label("Preview selected", systemImage: "eye")
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
                    Label("Import selected", systemImage: "tray.and.arrow.down")
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
            "\(model.summary.created) created · \(model.summary.claimed) claimed · "
                + "\(model.summary.skipped) skipped · \(model.summary.failed) failed"
        default:
            "\(model.availableCandidateCount) candidates available · \(model.selectedCount) selected"
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
        let selection = model.isSelected(candidate.id) ? "Selected" : "Not selected"
        let action = model.action(for: candidate.id).map(actionName) ?? "No action selected"
        return [selection, candidate.observation.status.displayName, action]
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
        case .created: "Created"
        case .claimed: "Claimed; existing bindings preserved"
        case .alreadyManaged: "Already managed"
        case .failed(let message): "Failed: \(message)"
        case .skipped(let reason): "Skipped: \(reason)"
        }
    }

    private func distributionName(
        _ result: SkillDiscoveryBatchDistributionResult
    ) -> String {
        switch result {
        case .distributed: "Distributed"
        case .noChanges: "No changes"
        case .managedUndistributed: "Managed but not enabled"
        case .indeterminate(let message): "Needs attention: \(message)"
        case .notApplicable(let message): message
        }
    }
}
