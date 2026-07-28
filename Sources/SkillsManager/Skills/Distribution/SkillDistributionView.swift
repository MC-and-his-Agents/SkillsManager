import SwiftUI

struct SkillDistributionView: View {
    @Environment(SkillDistributionViewModel.self) private var model

    var body: some View {
        GroupBox("Distribution") {
            VStack(alignment: .leading, spacing: 14) {
                stateContent
            }
            .padding(.top, 4)
            .frame(maxWidth: .infinity, alignment: .leading)
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
            statusMessage("Select a managed Skill to configure distribution.", systemImage: "link")
        case .loading:
            ProgressView("Loading distribution state…")
        case .failed(let problem):
            VStack(alignment: .leading, spacing: 10) {
                statusMessage(problem.message, systemImage: "exclamationmark.triangle")
                Button("Retry") {
                    Task { await model.refreshCurrent() }
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
                Label(status.displayName, systemImage: status.systemImage)
                    .font(.headline)
                    .accessibilityLabel("Distribution status: \(status.displayName)")
                Spacer()
                Button {
                    Task { await model.refreshCurrent() }
                } label: {
                    if model.isRefreshing {
                        ProgressView()
                            .controlSize(.small)
                    } else {
                        Label("Refresh distribution", systemImage: "arrow.clockwise")
                            .labelStyle(.iconOnly)
                    }
                }
                .disabled(model.isRefreshing || model.isPreparingPreview || model.isApplying)
                .help(model.isRefreshing ? "Refreshing distribution" : "Refresh distribution")
                .accessibilityLabel(
                    model.isRefreshing ? "Refreshing distribution" : "Refresh distribution"
                )
            }

            modeSelection
            agentSelection

            if model.willConvertGlobalToDedicated {
                Label(
                    "Applying this selection will replace the global target with Agent-specific targets.",
                    systemImage: "arrow.triangle.branch"
                )
                .foregroundStyle(.secondary)
            } else if model.draftUsesGlobalTarget {
                Text(
                    model.selectedSyncMode == .symlink
                        ? "The compatible Agent set uses one link in ~/.agents/skills."
                        : "The compatible Agent set uses one Copy in ~/.agents/skills."
                )
                    .foregroundStyle(.secondary)
            }

            if model.hasUnappliedDraft {
                Label("Agent selection has unapplied changes.", systemImage: "pencil.circle")
                    .foregroundStyle(.secondary)
                    .accessibilityLabel("Agent selection has unapplied changes")
            }

            if !model.currentTargets.isEmpty {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Current targets")
                        .font(.headline)
                    ForEach(model.currentTargets) { target in
                        VStack(alignment: .leading, spacing: 2) {
                            Text(target.syncMode.displayName)
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
                    Label("Independent local Fork", systemImage: "arrow.triangle.branch")
                        .font(.headline)
                    Text("Based on \(lineage.parentLabel)")
                    Text("Source \(lineage.fingerprintLabel)")
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
                    Label("Preview changes", systemImage: "eye")
                }
            }
            .buttonStyle(.borderedProminent)
            .disabled(!model.canPreparePreview)
            .accessibilityLabel(
                model.isPreparingPreview ? "Preparing distribution preview" : "Preview changes"
            )
            .accessibilityHint("Shows planned distribution changes before anything is written.")

            Button("Remove from all Agents…") {
                model.removeFromAllAgents()
                Task { await model.preparePreview() }
            }
            .disabled(model.selectedAgents.isEmpty || !model.canPreparePreview)
            .accessibilityHint(
                "Previews removal of managed distribution targets. The managed Skill is retained."
            )
            Text("This removes only managed distribution targets. The Skill remains in the managed library.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private var modeSelection: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Mode")
                .font(.headline)
            Picker(
                "Distribution mode",
                selection: Binding(
                    get: { model.selectedSyncMode },
                    set: { model.setSyncMode($0) }
                )
            ) {
                Text("Symlink").tag(DistributionSyncMode.symlink)
                Text("Copy").tag(DistributionSyncMode.copy)
            }
            .pickerStyle(.segmented)
            .disabled(model.isApplying)
            .accessibilityValue(model.selectedSyncMode.displayName)
            Text(
                model.selectedSyncMode == .symlink
                    ? "Agents use the managed Skill directly."
                    : "Each target receives a managed Copy."
            )
            .font(.caption)
            .foregroundStyle(.secondary)
        }
    }

    private var agentSelection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Agents")
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
                            Text(row.platform.rawValue)
                            Text(row.isCurrentlyEnabled ? "Enabled now" : "Disabled now")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        Text(row.locator)
                            .font(.caption.monospaced())
                            .foregroundStyle(.secondary)
                            .textSelection(.enabled)
                        if !row.readsGlobalTarget {
                            Text("Uses an Agent-specific target")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
                .accessibilityLabel("\(row.platform.rawValue) distribution")
                .accessibilityValue(
                    row.isSelected
                        ? "Selected; currently \(row.isCurrentlyEnabled ? "enabled" : "disabled")"
                        : "Not selected; currently \(row.isCurrentlyEnabled ? "enabled" : "disabled")"
                )
                .accessibilityHint("Target: \(row.locator)")
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

    private func feedback(_ message: String, systemImage: String, tint: Color) -> some View {
        Label(message, systemImage: systemImage)
            .foregroundStyle(tint)
            .accessibilityElement(children: .combine)
    }
}

private struct SkillDistributionPreviewView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(SkillDistributionViewModel.self) private var model

    let preview: SkillDistributionViewModel.PendingPreview

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Distribution preview")
                .font(.title.bold())
            Text("Review every target before applying changes.")
                .foregroundStyle(.secondary)

            if preview.plan.status == .blocked {
                blockedConflicts
            } else if preview.rows.isEmpty {
                Label("No distribution changes are needed.", systemImage: "checkmark.circle")
            } else {
                List(preview.rows) { row in
                    VStack(alignment: .leading, spacing: 3) {
                        Label(row.kind.displayName, systemImage: row.kind.systemImage)
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
                Button(preview.plan.status == .blocked ? "Close" : "Cancel") {
                    model.cancelPreview()
                    dismiss()
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
                            Text(preview.plan.status == .noOp ? "Confirm" : "Apply")
                        }
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(model.isApplying)
                    .keyboardShortcut(.defaultAction)
                    .accessibilityLabel(
                        model.isApplying
                            ? "Applying distribution changes"
                            : (preview.plan.status == .noOp ? "Confirm" : "Apply")
                    )
                }
            }
        }
        .padding(20)
        .frame(minWidth: 560, minHeight: 380)
        .interactiveDismissDisabled(model.isApplying)
    }

    private var blockedConflicts: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label("Changes cannot be applied", systemImage: "exclamationmark.triangle")
                .font(.headline)
            ForEach(Array(preview.plan.conflicts.enumerated()), id: \.offset) { _, conflict in
                VStack(alignment: .leading, spacing: 2) {
                    Text(conflict.reason.displayName)
                    Text(conflict.canonicalLocator)
                        .font(.callout.monospaced())
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                }
                .accessibilityElement(children: .combine)
            }

            ForEach(preview.driftDecisions) { decision in
                VStack(alignment: .leading, spacing: 8) {
                    Text("Local changes at \(decision.locator)")
                        .font(.headline)
                    Text(
                        "Discard restores the managed Skill and cannot be undone. "
                            + "Choose Fork to preserve the local content independently."
                    )
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    HStack {
                        Button("Discard local changes", role: .destructive) {
                            Task { await model.discardLocalChanges(decision) }
                        }
                        .disabled(model.isApplying)
                        .accessibilityHint(
                            "Replaces this Copy with the current managed Skill."
                        )
                        Button("Keep as independent Fork") {
                            Task { await model.keepAsFork(decision) }
                        }
                        .disabled(model.isApplying)
                        .accessibilityHint(
                            "Preserves the local content as a separately managed Skill."
                        )
                    }
                }
                .padding(.top, 6)
            }
        }
    }
}
