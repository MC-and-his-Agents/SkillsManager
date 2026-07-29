import SwiftUI

struct SkillUpdateCheckView: View {
    @Environment(SkillUpdateCheckViewModel.self) private var model

    var body: some View {
        GroupBox("Update check") {
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
                    Label(result.displayName, systemImage: result.systemImage)
                        .foregroundStyle(result.requiresAttention ? .orange : .secondary)
                        .accessibilityLabel("Update result: \(result.displayName)")
                }
            }
            .padding(.top, 4)
            .frame(maxWidth: .infinity, alignment: .leading)
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
            status("Select a managed Skill to check for updates.", systemImage: "arrow.clockwise")
        case .loading:
            ProgressView("Loading the last update check…")
        case .failed(let problem):
            VStack(alignment: .leading, spacing: 8) {
                status(problem.localizedDescription, systemImage: "exclamationmark.triangle")
                Button("Retry") { Task { await model.refreshCurrent() } }
            }
        case .loaded(let snapshot):
            loaded(snapshot)
        }
    }

    private func loaded(_ snapshot: ManagedSkillUpdateCheckSnapshot?) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            if let snapshot {
                Label(
                    snapshot.status.displayName,
                    systemImage: snapshot.status.systemImage
                )
                .font(.headline)
                .accessibilityLabel("Update status: \(snapshot.status.displayName)")
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
                    Label(
                        "Copy content is behind the managed Skill and needs to be synchronized.",
                        systemImage: "arrow.triangle.2.circlepath"
                    )
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
                            Label("Review update", systemImage: "arrow.down.circle")
                        }
                    }
                    .disabled(model.isPreparingUpdate || model.isUpdating)
                    .accessibilityLabel(
                        model.isPreparingUpdate ? "Preparing update" : "Review Skill update"
                    )
                }
            } else {
                Text("This Skill has not been checked yet.")
                    .foregroundStyle(.secondary)
            }

            Button {
                Task { await model.checkCurrent() }
            } label: {
                if model.isChecking {
                    ProgressView().controlSize(.small)
                } else {
                    Label("Check now", systemImage: "arrow.clockwise")
                }
            }
            .disabled(model.isChecking)
            .accessibilityLabel(model.isChecking ? "Checking for updates" : "Check for updates")
        }
    }

    private func status(_ message: String, systemImage: String) -> some View {
        Label(message, systemImage: systemImage)
            .foregroundStyle(.secondary)
            .accessibilityElement(children: .combine)
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
            Text("Update \(preview.displayName)")
                .font(.title2.bold())
            LabeledContent("Source", value: preview.sourceDescription)
            Text("The current managed content will be backed up before it is replaced.")
                .foregroundStyle(.secondary)

            ForEach(preview.copyChoices) { choice in
                VStack(alignment: .leading, spacing: 6) {
                    Text(choice.targetDescription).font(.headline)
                    Picker(
                        "Local Copy",
                        selection: decisionBinding(choice.scopeKey)
                    ) {
                        Text("Choose an action").tag(nil as ManagedSkillUpdateCopyDecision?)
                        Text("Discard local changes")
                            .tag(ManagedSkillUpdateCopyDecision.discard as ManagedSkillUpdateCopyDecision?)
                        Text("Keep changes as a Fork")
                            .tag(ManagedSkillUpdateCopyDecision.fork as ManagedSkillUpdateCopyDecision?)
                        Text("Cancel this update")
                            .tag(ManagedSkillUpdateCopyDecision.cancel as ManagedSkillUpdateCopyDecision?)
                    }
                    .accessibilityLabel("Action for \(choice.targetDescription)")
                }
            }

            if model.isUpdating {
                ProgressView("Verifying, backing up, updating, and refreshing distribution…")
                    .accessibilityLabel("Updating Skill")
            }

            HStack {
                Spacer()
                Button("Cancel") {
                    Task { await model.cancelUpdate() }
                }
                .disabled(model.isUpdating)
                Button("Confirm update") {
                    Task { await model.confirmUpdate() }
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

private extension ManagedSkillUpdateCheckSnapshot {
    var hasExecutableRemoteUpdate: Bool {
        guard let candidate else { return false }
        return candidate.contentFingerprint != storedFingerprint
            && (status == .remoteChanged || status == .copyDrift)
    }
}

private extension ManagedSkillUpdateExecutionStatus {
    var displayName: String {
        switch self {
        case .cancelled: "Update cancelled"
        case .noChange: "Already up to date"
        case .backupReadyUpdateNotStarted:
            "Backup completed; recheck before trying the update again"
        case .copyDecisionsAppliedUpdateNotCompleted:
            "Copy decisions were saved; recheck before updating the parent Skill"
        case .updated: "Skill updated"
        case .updatedNeedsAttention: "Skill updated; distribution needs attention"
        case .updateRolledBack: "Update rolled back"
        case .updateIndeterminate: "Update state could not be confirmed"
        case .needsRepair: "Managed Skill needs repair"
        }
    }

    var requiresAttention: Bool {
        switch self {
        case .updated, .noChange, .cancelled: false
        default: true
        }
    }

    var systemImage: String {
        requiresAttention ? "exclamationmark.triangle" : "checkmark.circle"
    }
}
