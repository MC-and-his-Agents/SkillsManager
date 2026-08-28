import SwiftUI

struct SkillUpdateCheckView: View {
    @Environment(SkillUpdateCheckViewModel.self) private var model

    var body: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 10) {
                stateContent
                // 结果反馈统一由详情页顶部 banner 呈现（SkillDetailFeedbackBanner）。
            }
            .padding(.top, 4)
            .frame(maxWidth: .infinity, alignment: .leading)
        } label: {
            Text("Update check", bundle: SkillsManagerLocalizationResources.bundle)
        }
        .sheet(item: updatePreviewBinding) { preview in
            SkillUpdateConfirmationView(preview: preview)
        }
    }

    @ViewBuilder
    private var stateContent: some View {
        switch model.loadState {
        case .blocked(let message):
            status(message, systemImage: "lock.trianglebadge.exclamationmark")
        case .empty:
            localizedStatus(
                "Select a managed Skill to check for updates.",
                systemImage: "arrow.clockwise"
            )
        case .loading:
            ProgressView(String(localized: "Loading the last update check…", bundle: SkillsManagerLocalizationResources.bundle))
        case .failed(let problem):
            VStack(alignment: .leading, spacing: 8) {
                status(localizedManagedSkillUpdateCheckProblem(problem), systemImage: "exclamationmark.triangle")
                Button {
                    Task { await model.refreshCurrent() }
                } label: {
                    Text("Retry", bundle: SkillsManagerLocalizationResources.bundle)
                }
            }
        case .loaded(let snapshot):
            loaded(snapshot)
        }
    }

    private func loaded(_ snapshot: ManagedSkillUpdateCheckSnapshot?) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            if let snapshot {
                Label {
                    Text(verbatim: checkStatusText(snapshot.status))
                } icon: {
                    Image(systemName: snapshot.status.systemImage)
                }
                .font(.headline)
                .accessibilityLabel(Text(
                    String(
                        localized: LocalizedStringResource(
            "Update status: \(checkStatusText(snapshot.status))",
            bundle: SkillsManagerLocalizationResources.bundle
        ))
                ))
                Text(
                    Date(
                        timeIntervalSince1970:
                            Double(snapshot.checkedAtMilliseconds) / 1_000
                    ).formatted(date: .abbreviated, time: .shortened)
                )
                .font(.caption)
                .foregroundStyle(.secondary)
                if let reason = snapshot.capabilityReason {
                    Text(verbatim: localizedManagedSkillUpdateCapabilityReason(reason) ?? reason)
                        .foregroundStyle(.secondary)
                }
                if !snapshot.sourceChangedScopeKeys.isEmpty {
                    Label {
                        Text(
                            "Copy content is behind the managed Skill and needs to be synchronized.",
                            bundle: SkillsManagerLocalizationResources.bundle
                        )
                    } icon: {
                        Image(systemName: "arrow.triangle.2.circlepath")
                    }
                    .foregroundStyle(.orange)
                    .accessibilityElement(children: .combine)
                }
                // Review/Check 入口统一在详情页 ActionBar（单一入口）。
            } else {
                Text("This Skill has not been checked yet.", bundle: SkillsManagerLocalizationResources.bundle)
                    .foregroundStyle(.secondary)
            }

        }
    }

    private func status(_ message: String, systemImage: String) -> some View {
        Label(message, systemImage: systemImage)
            .foregroundStyle(.secondary)
            .accessibilityElement(children: .combine)
    }

    private func localizedStatus(
        _ message: LocalizedStringResource,
        systemImage: String
    ) -> some View {
        Label {
            Text(message)
        } icon: {
            Image(systemName: systemImage)
        }
        .foregroundStyle(.secondary)
        .accessibilityElement(children: .combine)
    }

    private func executionStatusText(_ status: ManagedSkillUpdateExecutionStatus) -> String {
        return switch status {
        case .cancelled: String(localized: "Update cancelled", bundle: SkillsManagerLocalizationResources.bundle)
        case .noChange: String(localized: "Already up to date", bundle: SkillsManagerLocalizationResources.bundle)
        case .backupReadyUpdateNotStarted:
            String(localized: "Backup completed; recheck before trying the update again", bundle: SkillsManagerLocalizationResources.bundle)
        case .copyDecisionsAppliedUpdateNotCompleted:
            String(localized: "Copy decisions were saved; recheck before updating the parent Skill", bundle: SkillsManagerLocalizationResources.bundle)
        case .updated: String(localized: "Skill updated", bundle: SkillsManagerLocalizationResources.bundle)
        case .updatedNeedsAttention:
            String(localized: "Skill updated; distribution needs attention", bundle: SkillsManagerLocalizationResources.bundle)
        case .updateRolledBack: String(localized: "Update rolled back", bundle: SkillsManagerLocalizationResources.bundle)
        case .updateIndeterminate: String(localized: "Update state could not be confirmed", bundle: SkillsManagerLocalizationResources.bundle)
        case .needsRepair: String(localized: "Managed Skill needs repair", bundle: SkillsManagerLocalizationResources.bundle)
        }
    }

    private func checkStatusText(_ status: ManagedSkillUpdateCheckStatus) -> String {
        return switch status {
        case .upToDate: String(localized: "Up to date", bundle: SkillsManagerLocalizationResources.bundle)
        case .remoteChanged: String(localized: "Update available", bundle: SkillsManagerLocalizationResources.bundle)
        case .localModified: String(localized: "Managed content was modified locally", bundle: SkillsManagerLocalizationResources.bundle)
        case .copyDrift: String(localized: "Copy target has local changes", bundle: SkillsManagerLocalizationResources.bundle)
        case .capabilityUnavailable: String(localized: "Update checking unavailable", bundle: SkillsManagerLocalizationResources.bundle)
        case .conflict: String(localized: "Update state needs attention", bundle: SkillsManagerLocalizationResources.bundle)
        }
    }

    private var updatePreviewBinding: Binding<ManagedSkillUpdateExecutionPreview?> {
        Binding(
            get: { model.pendingUpdate },
            set: { value in
                guard value == nil, model.pendingUpdate != nil, !model.isUpdating else { return }
                Task { await model.cancelUpdate() }
            }
        )
    }
}

private struct SkillUpdateConfirmationView: View {
    @Environment(SkillUpdateCheckViewModel.self) private var model
    let preview: ManagedSkillUpdateExecutionPreview

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(String(
                localized: LocalizedStringResource(
            "Update \(preview.displayName)",
            bundle: SkillsManagerLocalizationResources.bundle
        )))
                .font(.title2.bold())
            LabeledContent {
                Text(verbatim: preview.currentSourceDescription)
            } label: {
                Text("Current source", bundle: SkillsManagerLocalizationResources.bundle)
            }
            LabeledContent {
                Text(verbatim: preview.candidateSourceDescription)
            } label: {
                Text("Candidate source", bundle: SkillsManagerLocalizationResources.bundle)
            }
            LabeledContent {
                Text(verbatim: preview.distributionDescription)
            } label: {
                Text("Distribution", bundle: SkillsManagerLocalizationResources.bundle)
            }
            Text("The current managed content will be backed up before it is replaced.", bundle: SkillsManagerLocalizationResources.bundle)
                .foregroundStyle(.secondary)

            ForEach(preview.copyChoices) { choice in
                VStack(alignment: .leading, spacing: 6) {
                    Text(verbatim: choice.targetDescription).font(.headline)
                    Picker(
                        "Local Copy",
                        selection: decisionBinding(choice.scopeKey)
                    ) {
                        Text("Choose an action", bundle: SkillsManagerLocalizationResources.bundle).tag(nil as ManagedSkillUpdateCopyDecision?)
                        Text("Discard local changes", bundle: SkillsManagerLocalizationResources.bundle)
                            .tag(ManagedSkillUpdateCopyDecision.discard as ManagedSkillUpdateCopyDecision?)
                        Text("Keep changes as a Fork", bundle: SkillsManagerLocalizationResources.bundle)
                            .tag(ManagedSkillUpdateCopyDecision.fork as ManagedSkillUpdateCopyDecision?)
                        Text("Cancel this update", bundle: SkillsManagerLocalizationResources.bundle)
                            .tag(ManagedSkillUpdateCopyDecision.cancel as ManagedSkillUpdateCopyDecision?)
                    }
                    .accessibilityLabel(Text(String(
                        localized: LocalizedStringResource(
            "Action for \(choice.targetDescription)",
            bundle: SkillsManagerLocalizationResources.bundle
        ))))
                }
            }

            if model.isUpdating {
                ProgressView(String(localized: "Verifying, backing up, updating, and refreshing distribution…", bundle: SkillsManagerLocalizationResources.bundle))
                    .accessibilityLabel(Text("Updating Skill", bundle: SkillsManagerLocalizationResources.bundle))
            }

            HStack {
                Spacer()
                Button {
                    Task { await model.cancelUpdate() }
                } label: {
                    Text("Cancel", bundle: SkillsManagerLocalizationResources.bundle)
                }
                .disabled(model.isUpdating)
                Button {
                    Task { await model.confirmUpdate() }
                } label: {
                    Text("Confirm update", bundle: SkillsManagerLocalizationResources.bundle)
                }
                .buttonStyle(.borderedProminent)
                .disabled(!model.canConfirmUpdate)
            }
        }
        .padding(20)
        .frame(minWidth: 520)
        .interactiveDismissDisabled(model.isUpdating)
    }

    private func decisionBinding(
        _ scopeKey: String
    ) -> Binding<ManagedSkillUpdateCopyDecision?> {
        Binding(
            get: { model.selectedDecision(for: scopeKey) },
            set: { value in
                if let value { model.select(value, scopeKey: scopeKey) }
            }
        )
    }

}

private extension ManagedSkillUpdateCheckStatus {
    var displayName: String {
        switch self {
        case .upToDate: "Up to date"
        case .remoteChanged: "Update available"
        case .localModified: "Managed content was modified locally"
        case .copyDrift: "Copy target has local changes"
        case .capabilityUnavailable: "Update checking unavailable"
        case .conflict: "Update state needs attention"
        }
    }

    var systemImage: String {
        switch self {
        case .upToDate: "checkmark.circle"
        case .remoteChanged: "arrow.down.circle"
        case .localModified: "pencil.circle"
        case .copyDrift: "exclamationmark.arrow.triangle.2.circlepath"
        case .capabilityUnavailable: "questionmark.circle"
        case .conflict: "exclamationmark.triangle"
        }
    }
}
