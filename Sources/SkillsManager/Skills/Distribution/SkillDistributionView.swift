import SwiftUI

struct SkillDistributionView: View {
    @Environment(SkillDistributionViewModel.self) private var model

    var body: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 14) {
                stateContent
            }
            .padding(.top, 4)
            .frame(maxWidth: .infinity, alignment: .leading)
        } label: {
            Text("Distribution", bundle: .module)
        }
        .sheet(item: previewBinding) { preview in
            SkillDistributionPreviewView(preview: preview)
                .environment(model)
        }
    }

    @ViewBuilder
    private var stateContent: some View {
        switch model.loadState {
        case .blocked(let message):
            statusMessage(message, systemImage: "lock.trianglebadge.exclamationmark")
        case .empty:
            localizedStatusMessage(
                "Select a managed Skill to configure distribution.",
                systemImage: "link"
            )
        case .loading:
            ProgressView(String(localized: "Loading distribution state…", bundle: .module))
        case .failed(let problem):
            VStack(alignment: .leading, spacing: 10) {
                statusMessage(problem.message, systemImage: "exclamationmark.triangle")
                Button {
                    Task { await model.refreshCurrent() }
                } label: {
                    Text("Retry", bundle: .module)
                }
                .disabled(model.isRefreshing || model.isApplying)
            }
        case .ready(let status):
            readyContent(status: status)
        }
    }

    private func readyContent(status: SkillDistributionViewModel.Status) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Label {
                    Text(verbatim: statusText(status))
                } icon: {
                    Image(systemName: status.systemImage)
                }
                    .font(.headline)
                    .accessibilityLabel(Text(
                        "Distribution status: \(statusText(status))",
                        bundle: .module
                    ))
                Spacer()
                Button {
                    Task { await model.refreshCurrent() }
                } label: {
                    if model.isRefreshing {
                        ProgressView()
                            .controlSize(.small)
                    } else {
                        Label {
                            Text("Refresh distribution", bundle: .module)
                        } icon: {
                            Image(systemName: "arrow.clockwise")
                        }
                            .labelStyle(.iconOnly)
                    }
                }
                .disabled(model.isRefreshing || model.isPreparingPreview || model.isApplying)
                .help(Text(
                    model.isRefreshing ? "Refreshing distribution" : "Refresh distribution",
                    bundle: .module
                ))
                .accessibilityLabel(Text(
                    model.isRefreshing ? "Refreshing distribution" : "Refresh distribution",
                    bundle: .module
                ))
            }

            modeSelection
            agentSelection

            if model.willConvertGlobalToDedicated {
                Label {
                    Text(
                        "Applying this selection will replace the global target with Agent-specific targets.",
                        bundle: .module
                    )
                } icon: {
                    Image(systemName: "arrow.triangle.branch")
                }
                .foregroundStyle(.secondary)
            } else if model.draftUsesGlobalTarget {
                Text(
                    model.selectedSyncMode == .symlink
                        ? "The compatible Agent set uses one link in ~/.agents/skills."
                        : "The compatible Agent set uses one Copy in ~/.agents/skills."
                    , bundle: .module
                )
                    .foregroundStyle(.secondary)
            }

            if model.hasUnappliedDraft {
                Label {
                    Text("Agent selection has unapplied changes.", bundle: .module)
                } icon: {
                    Image(systemName: "pencil.circle")
                }
                    .foregroundStyle(.secondary)
                    .accessibilityLabel(Text(
                        "Agent selection has unapplied changes",
                        bundle: .module
                    ))
            }

            if !model.currentTargets.isEmpty {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Current targets", bundle: .module)
                        .font(.headline)
                    ForEach(model.currentTargets) { target in
                        VStack(alignment: .leading, spacing: 2) {
                            Text(verbatim: syncModeText(target.syncMode))
                                .font(.caption)
                                .foregroundStyle(.secondary)
                            Text(target.locator)
                                .font(.callout.monospaced())
                                .textSelection(.enabled)
                        }
                        .accessibilityElement(children: .combine)
                    }
                }
            }

            if let lineage = model.forkLineage {
                VStack(alignment: .leading, spacing: 4) {
                    Label {
                        Text("Independent local Fork", bundle: .module)
                    } icon: {
                        Image(systemName: "arrow.triangle.branch")
                    }
                        .font(.headline)
                    Text("Based on \(lineage.parentLabel)", bundle: .module)
                    Text("Source \(lineage.fingerprintLabel)", bundle: .module)
                        .font(.caption.monospaced())
                    Text(
                        Date(
                            timeIntervalSince1970:
                                Double(lineage.createdAtMilliseconds) / 1_000
                        ).formatted(date: .abbreviated, time: .shortened)
                    )
                    .font(.caption)
                }
                .foregroundStyle(.secondary)
                .accessibilityElement(children: .combine)
            }

            if let message = model.successMessage {
                feedback(message, systemImage: "checkmark.circle.fill", tint: .green)
            }
            if let problem = model.problem {
                feedback(problem.message, systemImage: "exclamationmark.triangle.fill", tint: .orange)
            }

            Button {
                Task { await model.preparePreview() }
            } label: {
                if model.isPreparingPreview {
                    ProgressView()
                } else {
                    Label {
                        Text("Preview changes", bundle: .module)
                    } icon: {
                        Image(systemName: "eye")
                    }
                }
            }
            .buttonStyle(.borderedProminent)
            .disabled(!model.canPreparePreview)
            .accessibilityLabel(Text(
                model.isPreparingPreview ? "Preparing distribution preview" : "Preview changes",
                bundle: .module
            ))
            .accessibilityHint(Text(
                "Shows planned distribution changes before anything is written.",
                bundle: .module
            ))

            Button {
                model.removeFromAllAgents()
                Task { await model.preparePreview() }
            } label: {
                Text("Remove from all Agents…", bundle: .module)
            }
            .disabled(model.selectedAgents.isEmpty || !model.canPreparePreview)
            .accessibilityHint(Text(
                "Previews removal of managed distribution targets. The managed Skill is retained.",
                bundle: .module
            ))
            Text("This removes only managed distribution targets. The Skill remains in the managed library.", bundle: .module)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private var modeSelection: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Mode", bundle: .module)
                .font(.headline)
            Picker(
                selection: Binding(
                    get: { model.selectedSyncMode },
                    set: { model.setSyncMode($0) }
                )
            ) {
                Text("Symlink", bundle: .module).tag(DistributionSyncMode.symlink)
                Text("Copy", bundle: .module).tag(DistributionSyncMode.copy)
            } label: {
                Text("Distribution mode", bundle: .module)
            }
            .pickerStyle(.segmented)
            .disabled(model.isApplying)
            .accessibilityValue(Text(verbatim: syncModeText(model.selectedSyncMode)))
            Text(
                model.selectedSyncMode == .symlink
                    ? "Agents use the managed Skill directly."
                    : "Each target receives a managed Copy."
                , bundle: .module
            )
            .font(.caption)
            .foregroundStyle(.secondary)
        }
    }

    private var agentSelection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Agents", bundle: .module)
                .font(.headline)
            ForEach(model.agentRows) { row in
                Toggle(
                    isOn: Binding(
                        get: { model.selectedAgents.contains(row.platform) },
                        set: { model.setAgent(row.platform, selected: $0) }
                    )
                ) {
                    VStack(alignment: .leading, spacing: 2) {
                        HStack(spacing: 6) {
                            Text(verbatim: platformText(row.platform))
                            Text(
                                row.isCurrentlyEnabled ? "Enabled now" : "Disabled now",
                                bundle: .module
                            )
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        Text(row.locator)
                            .font(.caption.monospaced())
                            .foregroundStyle(.secondary)
                            .textSelection(.enabled)
                        if !row.readsGlobalTarget {
                            Text("Uses an Agent-specific target", bundle: .module)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
                .accessibilityLabel(Text(
                    "\(platformText(row.platform)) distribution",
                    bundle: .module
                ))
                .accessibilityValue(Text(
                    row.isSelected
                        ? "Selected; currently \(row.isCurrentlyEnabled ? "enabled" : "disabled")"
                        : "Not selected; currently \(row.isCurrentlyEnabled ? "enabled" : "disabled")",
                    bundle: .module
                ))
                .accessibilityHint(Text("Target: \(row.locator)", bundle: .module))
                .disabled(model.isApplying)
            }
        }
    }

    private var previewBinding: Binding<SkillDistributionViewModel.PendingPreview?> {
        Binding(
            get: { model.pendingPreview },
            set: { if $0 == nil { model.cancelPreview() } }
        )
    }

    private func statusMessage(_ message: String, systemImage: String) -> some View {
        Label(message, systemImage: systemImage)
            .foregroundStyle(.secondary)
    }

    private func localizedStatusMessage(
        _ message: LocalizedStringResource,
        systemImage: String
    ) -> some View {
        Label {
            Text(message)
        } icon: {
            Image(systemName: systemImage)
        }
        .foregroundStyle(.secondary)
    }

    private func feedback(_ message: String, systemImage: String, tint: Color) -> some View {
        Label(message, systemImage: systemImage)
            .foregroundStyle(tint)
            .accessibilityElement(children: .combine)
    }

    private func statusText(_ status: SkillDistributionViewModel.Status) -> String {
        return switch status {
        case .notConfigured: String(localized: "Not configured", bundle: .module)
        case .inSync: String(localized: "In sync", bundle: .module)
        case .drifted: String(localized: "Needs update", bundle: .module)
        case .needsRepair: String(localized: "Needs repair", bundle: .module)
        case .operationInProgress: String(localized: "Operation in progress", bundle: .module)
        }
    }

    private func syncModeText(_ mode: DistributionSyncMode) -> String {
        return switch mode {
        case .symlink: String(localized: "Symlink", bundle: .module)
        case .copy: String(localized: "Copy", bundle: .module)
        }
    }

    private func platformText(_ platform: SkillPlatform) -> String {
        return switch platform {
        case .codex: String(localized: "Codex", bundle: .module)
        case .claude: String(localized: "Claude Code", bundle: .module)
        case .opencode: String(localized: "OpenCode", bundle: .module)
        case .copilot: String(localized: "GitHub Copilot", bundle: .module)
        }
    }
}

private struct SkillDistributionPreviewView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(SkillDistributionViewModel.self) private var model

    let preview: SkillDistributionViewModel.PendingPreview

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Distribution preview", bundle: .module)
                .font(.title.bold())
            Text("Review every target before applying changes.", bundle: .module)
                .foregroundStyle(.secondary)

            if preview.plan.status == .blocked {
                blockedConflicts
            } else if preview.rows.isEmpty {
                Label {
                    Text("No distribution changes are needed.", bundle: .module)
                } icon: {
                    Image(systemName: "checkmark.circle")
                }
            } else {
                List(preview.rows) { row in
                    VStack(alignment: .leading, spacing: 3) {
                        Label {
                            Text(verbatim: previewKindText(row.kind))
                        } icon: {
                            Image(systemName: row.kind.systemImage)
                        }
                            .font(.headline)
                        Text(row.locator)
                            .font(.callout.monospaced())
                            .textSelection(.enabled)
                    }
                    .accessibilityElement(children: .combine)
                }
            }

            Spacer()
            HStack {
                Button {
                    model.cancelPreview()
                    dismiss()
                } label: {
                    Text(
                        preview.plan.status == .blocked ? "Close" : "Cancel",
                        bundle: .module
                    )
                }
                .keyboardShortcut(.cancelAction)
                .disabled(model.isApplying)

                Spacer()

                if preview.plan.status != .blocked {
                    Button {
                        Task { await model.confirmPreview() }
                    } label: {
                        if model.isApplying {
                            ProgressView()
                        } else {
                            if preview.plan.status == .noOp {
                                Text("Confirm", bundle: .module)
                            } else {
                                Text("Apply", bundle: .module)
                            }
                        }
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(model.isApplying)
                    .keyboardShortcut(.defaultAction)
                    .accessibilityLabel(Text(
                        model.isApplying
                            ? "Applying distribution changes"
                            : (preview.plan.status == .noOp ? "Confirm" : "Apply"),
                        bundle: .module
                    ))
                }
            }
        }
        .padding(20)
        .frame(minWidth: 560, minHeight: 380)
        .interactiveDismissDisabled(model.isApplying)
    }

    private var blockedConflicts: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label {
                Text("Changes cannot be applied", bundle: .module)
            } icon: {
                Image(systemName: "exclamationmark.triangle")
            }
                .font(.headline)
            ForEach(Array(preview.plan.conflicts.enumerated()), id: \.offset) { _, conflict in
                VStack(alignment: .leading, spacing: 2) {
                    Text(verbatim: conflictReasonText(conflict.reason))
                    Text(conflict.canonicalLocator)
                        .font(.callout.monospaced())
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                }
                .accessibilityElement(children: .combine)
            }

            ForEach(preview.driftDecisions) { decision in
                VStack(alignment: .leading, spacing: 8) {
                    Text("Local changes at \(decision.locator)", bundle: .module)
                        .font(.headline)
                    Text(
                        "Discard restores the managed Skill and cannot be undone. "
                            + "Choose Fork to preserve the local content independently."
                    )
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    HStack {
                        Button(role: .destructive) {
                            Task { await model.discardLocalChanges(decision) }
                        } label: {
                            Text("Discard local changes", bundle: .module)
                        }
                        .disabled(model.isApplying)
                        .accessibilityHint(Text(
                            "Replaces this Copy with the current managed Skill.",
                            bundle: .module
                        ))
                        Button {
                            Task { await model.keepAsFork(decision) }
                        } label: {
                            Text("Keep as independent Fork", bundle: .module)
                        }
                        .disabled(model.isApplying)
                        .accessibilityHint(Text(
                            "Preserves the local content as a separately managed Skill.",
                            bundle: .module
                        ))
                    }
                }
                .padding(.top, 6)
            }
        }
    }

    private func previewKindText(_ kind: SkillDistributionViewModel.PreviewRow.Kind) -> String {
        return switch kind {
        case .remove: String(localized: "Remove target", bundle: .module)
        case .create: String(localized: "Create target", bundle: .module)
        case .refresh: String(localized: "Refresh Copy", bundle: .module)
        case .replace: String(localized: "Change distribution mode", bundle: .module)
        case .binding: String(localized: "Update saved target", bundle: .module)
        case .configuration: String(localized: "Save Agent selection", bundle: .module)
        case .noChange: String(localized: "No change", bundle: .module)
        }
    }

    private func conflictReasonText(_ reason: DistributionConflictReason) -> String {
        return switch reason {
        case .invalidDesiredScope: String(localized: "The selected scope is invalid.", bundle: .module)
        case .unsupportedAdapter: String(localized: "The selected Agent is unsupported.", bundle: .module)
        case .globalCoverageMismatch: String(localized: "The global Agent coverage is inconsistent.", bundle: .module)
        case .dedicatedTargetUnavailable: String(localized: "An Agent-specific target is unavailable.", bundle: .module)
        case .targetUnavailable: String(localized: "The target folder is unavailable.", bundle: .module)
        case .currentBindingMissing: String(localized: "A saved link is missing.", bundle: .module)
        case .managedTargetMismatch: String(localized: "The saved link points to a different managed Skill.", bundle: .module)
        case .unknownObject: String(localized: "An unmanaged item already exists at this target.", bundle: .module)
        case .slugOccupied: String(localized: "Another managed Skill already uses this name.", bundle: .module)
        case .copyContentDrift: String(localized: "The managed copy contains local content changes.", bundle: .module)
        case .copyPhysicalDrift: String(localized: "The managed copy contains unexpected files or permissions.", bundle: .module)
        case .copyRootReplaced: String(localized: "The managed copy root was replaced.", bundle: .module)
        case .copyTargetReplaced: String(localized: "The managed copy directory was replaced.", bundle: .module)
        case .copyTargetMissing: String(localized: "The managed copy is missing.", bundle: .module)
        case .copyBaselineInvalid: String(localized: "The managed copy baseline is unavailable or invalid.", bundle: .module)
        }
    }
}
