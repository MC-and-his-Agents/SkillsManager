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
            Text("Batch Import", bundle: SkillsManagerLocalizationResources.bundle)
                .font(.title2.bold())
            Text("Review discovered local Skills, then import them in a safe, stable order.", bundle: SkillsManagerLocalizationResources.bundle)
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
                String(localized: "No Discovery candidates", bundle: SkillsManagerLocalizationResources.bundle),
                systemImage: "tray",
                description: Text("Refresh Discovery before opening Batch Import.", bundle: SkillsManagerLocalizationResources.bundle)
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
                    Text("Select safe", bundle: SkillsManagerLocalizationResources.bundle)
                }
                        .disabled(model.availableCandidateCount == 0)
                Button {
                    model.clearSelection()
                } label: {
                    Text("Clear", bundle: SkillsManagerLocalizationResources.bundle)
                }
                    .keyboardShortcut(.delete, modifiers: [.command])
                    .disabled(model.selectedCount == 0)
                Spacer()
                Text(
                    String(
                        localized: LocalizedStringResource(
            "\(model.selectedCount) selected",
            bundle: SkillsManagerLocalizationResources.bundle
        ))
                )
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
                Text(verbatim: candidate.observation.displayName)
                        .font(.headline)
                    Text(verbatim: discoveryStatusText(candidate.observation.status))
                        .font(.caption)
                        .foregroundStyle(candidate.observation.status.tint)
                    if let reason = candidate.selectionBlockReason {
                        Text(selectionBlockReasonText(reason))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    } else if let reason = candidate.observation.reason {
                        Text(verbatim: discoveryReasonText(reason))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    if let source = candidate.aliases.first {
                        Text(verbatim: source.url.path)
                            .font(.caption.monospaced())
                            .foregroundStyle(.secondary)
                            .textSelection(.enabled)
                    }
                    if candidate.aliases.count > 1 {
                        Text(
                            String(
                                localized: LocalizedStringResource(
            "+\(candidate.aliases.count - 1) verified alias locations",
            bundle: SkillsManagerLocalizationResources.bundle
        ))
                        )
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
                    Text("Import as new", bundle: SkillsManagerLocalizationResources.bundle)
                }
                .buttonStyle(.bordered)
                .disabled(model.isSelected(candidate.id))
                .accessibilityHint(Text(
                    "Explicitly selects this conflict for an independent import.",
                    bundle: SkillsManagerLocalizationResources.bundle
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
                    bundle: SkillsManagerLocalizationResources.bundle
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
                Text(verbatim: item.displayName).font(.headline)
                Spacer()
                Text(actionName(item.action))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            if let slug = item.distributionSlug {
                LabeledContent {
                    Text(verbatim: slug.value)
                } label: {
                    Text("Slug", bundle: SkillsManagerLocalizationResources.bundle)
                }
            }
            if let source = item.sourceURLs.first {
                LabeledContent {
                    Text(verbatim: source.path)
                } label: {
                    Text("Source", bundle: SkillsManagerLocalizationResources.bundle)
                }
            }
            if let plan = item.plan {
                LabeledContent {
                    Text(verbatim: distributionPlanText(plan.status))
                } label: {
                    Text("Distribution", bundle: SkillsManagerLocalizationResources.bundle)
                }
                if !plan.conflicts.isEmpty {
                    Text(plan.conflicts.map { $0.reason.localizedDisplayName }.joined(separator: ", "))
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
                    bundle: SkillsManagerLocalizationResources.bundle
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
            Text(verbatim: result.displayName).font(.headline)
            LabeledContent {
                Text(verbatim: managementName(result.management))
            } label: {
                Text("Management", bundle: SkillsManagerLocalizationResources.bundle)
            }
            LabeledContent {
                Text(verbatim: distributionName(result.distribution))
            } label: {
                Text("Distribution", bundle: SkillsManagerLocalizationResources.bundle)
            }
            if let source = result.sourceURLs.first {
                Text(verbatim: source.path)
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
            Text(verbatim: progressTitleText(title))
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(Text(verbatim: progressTitleText(title)))
        .accessibilityValue(Text(verbatim: progressAccessibilityValue))
    }

    private var progressAccessibilityValue: String {
        let total = model.preview?.items.count ?? model.selectedCount
        return String(
            localized: LocalizedStringResource(
            "\(model.resultItems.count) of \(total)",
            bundle: SkillsManagerLocalizationResources.bundle
        ))
    }

    @ViewBuilder
    private var controls: some View {
        HStack {
            if model.state == .selecting || model.state == .ready {
                Button {
                    model.cancelPreview()
                    dismiss()
                } label: {
                    Text("Cancel", bundle: SkillsManagerLocalizationResources.bundle)
                }
                .keyboardShortcut(.cancelAction)
            } else if model.state == .completed {
                Button {
                    model.reset()
                    dismiss()
                } label: {
                    Text("Close", bundle: SkillsManagerLocalizationResources.bundle)
                }
                .keyboardShortcut(.cancelAction)
            }
            Spacer()
            if model.state == .selecting {
                Button {
                    Task { await model.preparePreview() }
                } label: {
                    Label {
                        Text("Preview selected", bundle: SkillsManagerLocalizationResources.bundle)
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
                        Text("Import selected", bundle: SkillsManagerLocalizationResources.bundle)
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
            String(
                localized: LocalizedStringResource(
            "\(model.summary.created) created · \(model.summary.claimed) claimed · \(model.summary.skipped) skipped · \(model.summary.failed) failed",
            bundle: SkillsManagerLocalizationResources.bundle
        ))
        default:
            String(
                localized: LocalizedStringResource(
            "\(model.availableCandidateCount) candidates available · \(model.selectedCount) selected",
            bundle: SkillsManagerLocalizationResources.bundle
        ))
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
        let selection = model.isSelected(candidate.id)
            ? String(localized: "Selected", bundle: SkillsManagerLocalizationResources.bundle)
            : String(localized: "Not selected", bundle: SkillsManagerLocalizationResources.bundle)
        let action = model.action(for: candidate.id)
            .map(actionName)
            ?? String(localized: "No action selected", bundle: SkillsManagerLocalizationResources.bundle)
        return [selection, discoveryStatusText(candidate.observation.status), action]
            .joined(separator: ", ")
    }

    private func actionName(_ action: ManagedSkillImportAction) -> String {
        return switch action {
        case .importNew: String(localized: "Import as new", bundle: SkillsManagerLocalizationResources.bundle)
        case .claimExisting: String(localized: "Claim existing", bundle: SkillsManagerLocalizationResources.bundle)
        }
    }

    private func distributionName(_ status: DistributionPlanStatus) -> String {
        return switch status {
        case .executable: String(localized: "Ready to enable with Symlink", bundle: SkillsManagerLocalizationResources.bundle)
        case .noOp: String(localized: "No changes", bundle: SkillsManagerLocalizationResources.bundle)
        case .blocked: String(localized: "Blocked; Skill remains managed", bundle: SkillsManagerLocalizationResources.bundle)
        }
    }

    private func managementName(
        _ result: SkillDiscoveryBatchManagementResult
    ) -> String {
        return switch result {
        case .created: String(localized: "Created", bundle: SkillsManagerLocalizationResources.bundle)
        case .claimed: String(localized: "Claimed; existing bindings preserved", bundle: SkillsManagerLocalizationResources.bundle)
        case .alreadyManaged: String(localized: "Already managed", bundle: SkillsManagerLocalizationResources.bundle)
        case .failed(let message): String(
            localized: LocalizedStringResource(
            "Failed: \(message)",
            bundle: SkillsManagerLocalizationResources.bundle
        ))
        case .skipped(let reason): String(
            localized: LocalizedStringResource(
            "Skipped: \(reason)",
            bundle: SkillsManagerLocalizationResources.bundle
        ))
        }
    }

    private func distributionName(
        _ result: SkillDiscoveryBatchDistributionResult
    ) -> String {
        return switch result {
        case .distributed: String(localized: "Distributed", bundle: SkillsManagerLocalizationResources.bundle)
        case .noChanges: String(localized: "No changes", bundle: SkillsManagerLocalizationResources.bundle)
        case .managedUndistributed: String(localized: "Managed but not enabled", bundle: SkillsManagerLocalizationResources.bundle)
        case .indeterminate(let message): String(
            localized: LocalizedStringResource(
            "Needs attention: \(message)",
            bundle: SkillsManagerLocalizationResources.bundle
        ))
        case .notApplicable(let message): message
        }
    }

    private func discoveryStatusText(_ status: SkillDiscoveryStatus) -> String {
        return switch status {
        case .managed: String(localized: "Managed", bundle: SkillsManagerLocalizationResources.bundle)
        case .claimable: String(localized: "Ready to claim", bundle: SkillsManagerLocalizationResources.bundle)
        case .unmanaged: String(localized: "Unmanaged", bundle: SkillsManagerLocalizationResources.bundle)
        case .conflict: String(localized: "Conflict", bundle: SkillsManagerLocalizationResources.bundle)
        case .permissionDenied: String(localized: "Permission denied", bundle: SkillsManagerLocalizationResources.bundle)
        case .damaged: String(localized: "Damaged", bundle: SkillsManagerLocalizationResources.bundle)
        }
    }

    private func discoveryReasonText(_ reason: SkillDiscoveryReason) -> String {
        return switch reason {
        case .rootPermissionDenied: String(localized: "The scan root cannot be read.", bundle: SkillsManagerLocalizationResources.bundle)
        case .rootChanged: String(localized: "The scan root changed while it was being inspected.", bundle: SkillsManagerLocalizationResources.bundle)
        case .rootUnsupportedType: String(localized: "The scan root is not a directory or supported link.", bundle: SkillsManagerLocalizationResources.bundle)
        case .rootReadFailed: String(localized: "The scan root could not be read.", bundle: SkillsManagerLocalizationResources.bundle)
        case .unknownSymlink: String(localized: "The Skill uses a symbolic link that cannot be trusted.", bundle: SkillsManagerLocalizationResources.bundle)
        case .symbolicLinkTargetUnavailable: String(localized: "The Skill link target is unavailable.", bundle: SkillsManagerLocalizationResources.bundle)
        case .symbolicLinkTargetUnsupported: String(localized: "The Skill link target is not a directory.", bundle: SkillsManagerLocalizationResources.bundle)
        case .candidatePermissionDenied: String(localized: "The Skill folder cannot be read.", bundle: SkillsManagerLocalizationResources.bundle)
        case .sourceChanged: String(localized: "The Skill changed while it was being inspected.", bundle: SkillsManagerLocalizationResources.bundle)
        case .missingSkillManifest: String(localized: "SKILL.md is missing.", bundle: SkillsManagerLocalizationResources.bundle)
        case .containerDirectory: String(localized: "This folder contains Skill subdirectories.", bundle: SkillsManagerLocalizationResources.bundle)
        case .invalidSkillManifest: String(localized: "SKILL.md is not valid UTF-8.", bundle: SkillsManagerLocalizationResources.bundle)
        case .unsupportedEntryType: String(localized: "The Skill contains an unsupported file type.", bundle: SkillsManagerLocalizationResources.bundle)
        case .unsafeContent: String(localized: "The Skill contains an unsafe path or link.", bundle: SkillsManagerLocalizationResources.bundle)
        case .resourceLimitExceeded: String(localized: "The Skill exceeds the safe import limits.", bundle: SkillsManagerLocalizationResources.bundle)
        case .candidateReadFailed: String(localized: "The Skill content could not be read.", bundle: SkillsManagerLocalizationResources.bundle)
        case .ambiguousLocalAssociation: String(localized: "This location is linked to more than one managed Skill.", bundle: SkillsManagerLocalizationResources.bundle)
        case .localAssociationDrift: String(localized: "This location no longer matches its managed Skill.", bundle: SkillsManagerLocalizationResources.bundle)
        case .ambiguousSource: String(localized: "The source metadata matches more than one managed Skill.", bundle: SkillsManagerLocalizationResources.bundle)
        case .ambiguousFingerprint: String(localized: "The content matches more than one managed Skill.", bundle: SkillsManagerLocalizationResources.bundle)
        case .evidenceConflict: String(localized: "The source and content point to different managed Skills.", bundle: SkillsManagerLocalizationResources.bundle)
        case .scopeSlugConflict: String(localized: "More than one Skill uses this name in the same scope.", bundle: SkillsManagerLocalizationResources.bundle)
        }
    }

    private func distributionPlanText(_ status: DistributionPlanStatus) -> String {
        return switch status {
        case .executable: String(localized: "Ready to enable with Symlink", bundle: SkillsManagerLocalizationResources.bundle)
        case .noOp: String(localized: "No changes", bundle: SkillsManagerLocalizationResources.bundle)
        case .blocked: String(localized: "Blocked; Skill remains managed", bundle: SkillsManagerLocalizationResources.bundle)
        }
    }

    private func selectionBlockReasonText(_ reason: String) -> String {
        switch reason {
        case "Verified locations disagree about the managed Skill identity.":
            return String(localized: "Verified locations disagree about the managed Skill identity.", bundle: SkillsManagerLocalizationResources.bundle)
        default:
            return reason
        }
    }

    private func progressTitleText(_ title: String) -> String {
        return switch title {
        case "Preparing secure previews…": String(localized: "Preparing secure previews…", bundle: SkillsManagerLocalizationResources.bundle)
        case "Importing selected Skills…": String(localized: "Importing selected Skills…", bundle: SkillsManagerLocalizationResources.bundle)
        default: title
        }
    }
}
