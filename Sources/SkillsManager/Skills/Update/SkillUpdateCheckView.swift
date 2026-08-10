import SwiftUI

struct SkillUpdateCheckView: View {
    @Environment(SkillUpdateCheckViewModel.self) private var model

    var body: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 10) {
                stateContent
                if let problem = model.problem {
                    Label(
                        problem.localizedDescription,
                        systemImage: "exclamationmark.triangle"
                    )
                    .foregroundStyle(.orange)
                    .accessibilityElement(children: .combine)
                }
                if let problem = model.updateProblem {
                    Label(
                        problem.localizedDescription,
                        systemImage: "exclamationmark.triangle"
                    )
                    .foregroundStyle(.orange)
                    .accessibilityElement(children: .combine)
                }
                if let result = model.updateResult {
                    Label {
                        Text(verbatim: executionStatusText(result))
                    } icon: {
                        Image(systemName: result.systemImage)
                    }
                        .foregroundStyle(result.requiresAttention ? .orange : .secondary)
                        .accessibilityLabel(Text(
                            "Update result: \(executionStatusText(result))",
                            bundle: .module
                        ))
                }
            }
            .padding(.top, 4)
            .frame(maxWidth: .infinity, alignment: .leading)
        } label: {
            Text("Update check", bundle: .module)
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
            ProgressView(String(localized: "Loading the last update check…", bundle: .module))
        case .failed(let problem):
            VStack(alignment: .leading, spacing: 8) {
                status(problem.localizedDescription, systemImage: "exclamationmark.triangle")
                Button {
                    Task { await model.refreshCurrent() }
                } label: {
                    Text("Retry", bundle: .module)
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
                    "Update status: \(checkStatusText(snapshot.status))",
                    bundle: .module
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
                    Text(reason).foregroundStyle(.secondary)
                }
                if !snapshot.sourceChangedScopeKeys.isEmpty {
                    Label {
                        Text(
                            "Copy content is behind the managed Skill and needs to be synchronized.",
                            bundle: .module
                        )
                    } icon: {
                        Image(systemName: "arrow.triangle.2.circlepath")
                    }
                    .foregroundStyle(.orange)
                    .accessibilityElement(children: .combine)
                }
                if snapshot.hasExecutableRemoteUpdate {
                    Button {
                        Task { await model.prepareUpdate(snapshot) }
                    } label: {
                        if model.isPreparingUpdate {
                            ProgressView().controlSize(.small)
                        } else {
                            Label {
                                Text("Review update", bundle: .module)
                            } icon: {
                                Image(systemName: "arrow.down.circle")
                            }
                        }
                    }
                    .disabled(model.isPreparingUpdate || model.isUpdating)
                    .accessibilityLabel(
                        Text(
                            model.isPreparingUpdate ? "Preparing update" : "Review Skill update",
                            bundle: .module
                        )
                    )
                }
            } else {
                Text("This Skill has not been checked yet.", bundle: .module)
                    .foregroundStyle(.secondary)
            }

            Button {
                Task { await model.checkCurrent() }
            } label: {
                if model.isChecking {
                    ProgressView().controlSize(.small)
                } else {
                    Label {
                        Text("Check now", bundle: .module)
                    } icon: {
                        Image(systemName: "arrow.clockwise")
                    }
                }
            }
            .disabled(model.isChecking)
            .accessibilityLabel(Text(
                model.isChecking ? "Checking for updates" : "Check for updates",
                bundle: .module
            ))
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
        case .cancelled: String(localized: "Update cancelled", bundle: .module)
        case .noChange: String(localized: "Already up to date", bundle: .module)
        case .backupReadyUpdateNotStarted:
            String(localized: "Backup completed; recheck before trying the update again", bundle: .module)
        case .copyDecisionsAppliedUpdateNotCompleted:
            String(localized: "Copy decisions were saved; recheck before updating the parent Skill", bundle: .module)
        case .updated: String(localized: "Skill updated", bundle: .module)
        case .updatedNeedsAttention:
            String(localized: "Skill updated; distribution needs attention", bundle: .module)
        case .updateRolledBack: String(localized: "Update rolled back", bundle: .module)
        case .updateIndeterminate: String(localized: "Update state could not be confirmed", bundle: .module)
        case .needsRepair: String(localized: "Managed Skill needs repair", bundle: .module)
        }
    }

    private func checkStatusText(_ status: ManagedSkillUpdateCheckStatus) -> String {
        return switch status {
        case .upToDate: String(localized: "Up to date", bundle: .module)
        case .remoteChanged: String(localized: "Update available", bundle: .module)
        case .localModified: String(localized: "Managed content was modified locally", bundle: .module)
        case .copyDrift: String(localized: "Copy target has local changes", bundle: .module)
        case .capabilityUnavailable: String(localized: "Update checking unavailable", bundle: .module)
        case .conflict: String(localized: "Update state needs attention", bundle: .module)
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
            Text("Update \(preview.displayName)", bundle: .module)
                .font(.title2.bold())
            LabeledContent("Current source", value: preview.currentSourceDescription)
            LabeledContent("Candidate source", value: preview.candidateSourceDescription)
            LabeledContent("Distribution", value: preview.distributionDescription)
            Text("The current managed content will be backed up before it is replaced.", bundle: .module)
                .foregroundStyle(.secondary)

            ForEach(preview.copyChoices) { choice in
                VStack(alignment: .leading, spacing: 6) {
                    Text(choice.targetDescription).font(.headline)
                    Picker(
                        "Local Copy",
                        selection: decisionBinding(choice.scopeKey)
                    ) {
                        Text("Choose an action", bundle: .module).tag(nil as ManagedSkillUpdateCopyDecision?)
                        Text("Discard local changes", bundle: .module)
                            .tag(ManagedSkillUpdateCopyDecision.discard as ManagedSkillUpdateCopyDecision?)
                        Text("Keep changes as a Fork", bundle: .module)
                            .tag(ManagedSkillUpdateCopyDecision.fork as ManagedSkillUpdateCopyDecision?)
                        Text("Cancel this update", bundle: .module)
                            .tag(ManagedSkillUpdateCopyDecision.cancel as ManagedSkillUpdateCopyDecision?)
                    }
                    .accessibilityLabel(Text("Action for \(choice.targetDescription)", bundle: .module))
                }
            }

            if model.isUpdating {
                ProgressView(String(localized: "Verifying, backing up, updating, and refreshing distribution…", bundle: .module))
                    .accessibilityLabel(Text("Updating Skill", bundle: .module))
            }

            HStack {
                Spacer()
                Button {
                    Task { await model.cancelUpdate() }
                } label: {
                    Text("Cancel", bundle: .module)
                }
                .disabled(model.isUpdating)
                Button {
                    Task { await model.confirmUpdate() }
                } label: {
                    Text("Confirm update", bundle: .module)
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
