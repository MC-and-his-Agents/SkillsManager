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
            Text("Distribution", bundle: SkillsManagerLocalizationResources.bundle)
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
            ProgressView(String(localized: "Loading distribution state…", bundle: SkillsManagerLocalizationResources.bundle))
        case .failed(let problem):
            VStack(alignment: .leading, spacing: 10) {
                statusMessage(problem.message, systemImage: "exclamationmark.triangle")
                Button {
                    Task { await model.refreshCurrent() }
                } label: {
                    Text("Retry", bundle: SkillsManagerLocalizationResources.bundle)
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
                        String(
                            localized: LocalizedStringResource(
            "Distribution status: \(statusText(status))",
            bundle: SkillsManagerLocalizationResources.bundle
        ))
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
                            Text("Refresh distribution", bundle: SkillsManagerLocalizationResources.bundle)
                        } icon: {
                            Image(systemName: "arrow.clockwise")
                        }
                            .labelStyle(.iconOnly)
                    }
                }
                .disabled(model.isRefreshing || model.isPreparingPreview || model.isApplying)
                .help(Text(
                    model.isRefreshing ? "Refreshing distribution" : "Refresh distribution",
                    bundle: SkillsManagerLocalizationResources.bundle
                ))
                .accessibilityLabel(Text(
                    model.isRefreshing ? "Refreshing distribution" : "Refresh distribution",
                    bundle: SkillsManagerLocalizationResources.bundle
                ))
            }

            modeSelection
            agentSelection

            if model.willConvertGlobalToDedicated {
                Label {
                    Text(
                        "Applying this selection will replace the global target with Agent-specific targets.",
                        bundle: SkillsManagerLocalizationResources.bundle
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
                    , bundle: SkillsManagerLocalizationResources.bundle
                )
                    .foregroundStyle(.secondary)
            }

            if model.hasUnappliedDraft {
                Label {
                    Text("Agent selection has unapplied changes.", bundle: SkillsManagerLocalizationResources.bundle)
                } icon: {
                    Image(systemName: "pencil.circle")
                }
                    .foregroundStyle(.secondary)
                    .accessibilityLabel(Text(
                        "Agent selection has unapplied changes",
                        bundle: SkillsManagerLocalizationResources.bundle
                    ))
            }

            if !model.currentTargets.isEmpty {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Current targets", bundle: SkillsManagerLocalizationResources.bundle)
                        .font(.headline)
                    ForEach(model.currentTargets) { target in
                        VStack(alignment: .leading, spacing: 2) {
                            Text(verbatim: syncModeText(target.syncMode))
                                .font(.caption)
                                .foregroundStyle(.secondary)
                            Text(verbatim: target.locator)
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
                        Text("Independent local Fork", bundle: SkillsManagerLocalizationResources.bundle)
                    } icon: {
                        Image(systemName: "arrow.triangle.branch")
                    }
                        .font(.headline)
                    Text(
                        String(
                            localized: LocalizedStringResource(
            "Based on \(lineage.parentLabel)",
            bundle: SkillsManagerLocalizationResources.bundle
        ))
                    )
                    Text(
                        String(
                            localized: LocalizedStringResource(
            "Source \(lineage.fingerprintLabel)",
            bundle: SkillsManagerLocalizationResources.bundle
        ))
                    )
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

            // 结果反馈统一由详情页顶部 banner 呈现（SkillDetailFeedbackBanner），
            // 此处不再重复显示 successMessage/problem。

            Button {
                Task { await model.preparePreview() }
            } label: {
                if model.isPreparingPreview {
                    ProgressView()
                } else {
                    Label {
                        Text("Preview changes", bundle: SkillsManagerLocalizationResources.bundle)
                    } icon: {
                        Image(systemName: "eye")
                    }
                }
            }
            .buttonStyle(.borderedProminent)
            .disabled(!model.canPreparePreview)
            .accessibilityLabel(Text(
                model.isPreparingPreview ? "Preparing distribution preview" : "Preview changes",
                bundle: SkillsManagerLocalizationResources.bundle
            ))
            .accessibilityHint(Text(
                "Shows planned distribution changes before anything is written.",
                bundle: SkillsManagerLocalizationResources.bundle
            ))

            Button {
                model.removeFromAllAgents()
                Task { await model.preparePreview() }
            } label: {
                Text("Remove from all Agents…", bundle: SkillsManagerLocalizationResources.bundle)
            }
            .disabled(model.selectedAgents.isEmpty || !model.canPreparePreview)
            .accessibilityHint(Text(
                "Previews removal of managed distribution targets. The managed Skill is retained.",
                bundle: SkillsManagerLocalizationResources.bundle
            ))
            Text("This removes only managed distribution targets. The Skill remains in the managed library.", bundle: SkillsManagerLocalizationResources.bundle)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private var modeSelection: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Mode", bundle: SkillsManagerLocalizationResources.bundle)
                .font(.headline)
            Picker(
                selection: Binding(
                    get: { model.selectedSyncMode },
                    set: { model.setSyncMode($0) }
                )
            ) {
                Text("Symlink", bundle: SkillsManagerLocalizationResources.bundle).tag(DistributionSyncMode.symlink)
                Text("Copy", bundle: SkillsManagerLocalizationResources.bundle).tag(DistributionSyncMode.copy)
            } label: {
                Text("Distribution mode", bundle: SkillsManagerLocalizationResources.bundle)
            }
            .pickerStyle(.segmented)
            .disabled(model.isApplying)
            .accessibilityValue(Text(verbatim: syncModeText(model.selectedSyncMode)))
            if model.selectedSyncMode == .symlink {
                Text("Agents use the managed Skill directly.", bundle: SkillsManagerLocalizationResources.bundle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                Text("Each target receives a managed Copy.", bundle: SkillsManagerLocalizationResources.bundle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    /// Agent 选择编辑统一在详情页 ActionBar chips（单一编辑形态）。
    /// 本区域只读呈现当前 draft 与现状，不再提供第二套 Toggle。
    @ViewBuilder
    private var agentSelection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Agents", bundle: SkillsManagerLocalizationResources.bundle)
                .font(.headline)
            ForEach(model.agentRows) { row in
                HStack(alignment: .top, spacing: 6) {
                    VStack(alignment: .leading, spacing: 2) {
                        HStack(spacing: 6) {
                            Text(verbatim: platformText(row.platform))
                            Text(
                                row.isCurrentlyEnabled ? "Enabled now" : "Disabled now",
                                bundle: SkillsManagerLocalizationResources.bundle
                            )
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        Text(verbatim: row.locator)
                            .font(.caption.monospaced())
                            .foregroundStyle(.secondary)
                            .textSelection(.enabled)
                        if !row.readsGlobalTarget {
                            Text("Uses an Agent-specific target", bundle: SkillsManagerLocalizationResources.bundle)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
                .accessibilityElement(children: .combine)
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

    private func statusText(_ status: SkillDistributionViewModel.Status) -> String {
        return switch status {
        case .notConfigured: String(localized: "Not configured", bundle: SkillsManagerLocalizationResources.bundle)
        case .inSync: String(localized: "In sync", bundle: SkillsManagerLocalizationResources.bundle)
        case .drifted: String(localized: "Needs update", bundle: SkillsManagerLocalizationResources.bundle)
        case .needsRepair: String(localized: "Needs repair", bundle: SkillsManagerLocalizationResources.bundle)
        case .operationInProgress: String(localized: "Operation in progress", bundle: SkillsManagerLocalizationResources.bundle)
        }
    }

    private func syncModeText(_ mode: DistributionSyncMode) -> String {
        return switch mode {
        case .symlink: String(localized: "Symlink", bundle: SkillsManagerLocalizationResources.bundle)
        case .copy: String(localized: "Copy", bundle: SkillsManagerLocalizationResources.bundle)
        }
    }

    private func platformText(_ platform: SkillPlatform) -> String {
        return switch platform {
        case .codex: String(localized: "Codex", bundle: SkillsManagerLocalizationResources.bundle)
        case .claude: String(localized: "Claude Code", bundle: SkillsManagerLocalizationResources.bundle)
        case .opencode: String(localized: "OpenCode", bundle: SkillsManagerLocalizationResources.bundle)
        case .copilot: String(localized: "GitHub Copilot", bundle: SkillsManagerLocalizationResources.bundle)
        }
    }
}

private struct SkillDistributionPreviewView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(SkillDistributionViewModel.self) private var model

    let preview: SkillDistributionViewModel.PendingPreview

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Distribution preview", bundle: SkillsManagerLocalizationResources.bundle)
                .font(.title.bold())
            Text("Review every target before applying changes.", bundle: SkillsManagerLocalizationResources.bundle)
                .foregroundStyle(.secondary)

            if preview.plan.status == .blocked {
                blockedConflicts
            } else if preview.rows.isEmpty {
                Label {
                    Text("No distribution changes are needed.", bundle: SkillsManagerLocalizationResources.bundle)
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
                        Text(verbatim: row.locator)
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
                        bundle: SkillsManagerLocalizationResources.bundle
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
                                Text("Confirm", bundle: SkillsManagerLocalizationResources.bundle)
                            } else {
                                Text("Apply", bundle: SkillsManagerLocalizationResources.bundle)
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
                        bundle: SkillsManagerLocalizationResources.bundle
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
                Text("Changes cannot be applied", bundle: SkillsManagerLocalizationResources.bundle)
            } icon: {
                Image(systemName: "exclamationmark.triangle")
            }
                .font(.headline)
            ForEach(Array(preview.plan.conflicts.enumerated()), id: \.offset) { _, conflict in
                VStack(alignment: .leading, spacing: 2) {
                    Text(verbatim: conflict.reason.localizedDisplayName)
                    Text(verbatim: conflict.canonicalLocator)
                        .font(.callout.monospaced())
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                }
                .accessibilityElement(children: .combine)
            }

            ForEach(preview.driftDecisions) { decision in
                VStack(alignment: .leading, spacing: 8) {
                    Text(
                        String(
                            localized: LocalizedStringResource(
            "Local changes at \(decision.locator)",
            bundle: SkillsManagerLocalizationResources.bundle
        ))
                    )
                        .font(.headline)
                    Text(
                        String(
                            localized: "Discard restores the managed Skill and cannot be undone. Choose Fork to preserve the local content independently.",
                            bundle: SkillsManagerLocalizationResources.bundle
                        )
                    )
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    HStack {
                        Button(role: .destructive) {
                            Task { await model.discardLocalChanges(decision) }
                        } label: {
                            Text("Discard local changes", bundle: SkillsManagerLocalizationResources.bundle)
                        }
                        .disabled(model.isApplying)
                        .accessibilityHint(Text(
                            "Replaces this Copy with the current managed Skill.",
                            bundle: SkillsManagerLocalizationResources.bundle
                        ))
                        Button {
                            Task { await model.keepAsFork(decision) }
                        } label: {
                            Text("Keep as independent Fork", bundle: SkillsManagerLocalizationResources.bundle)
                        }
                        .disabled(model.isApplying)
                        .accessibilityHint(Text(
                            "Preserves the local content as a separately managed Skill.",
                            bundle: SkillsManagerLocalizationResources.bundle
                        ))
                    }
                }
                .padding(.top, 6)
            }
        }
    }

    private func previewKindText(_ kind: SkillDistributionViewModel.PreviewRow.Kind) -> String {
        return switch kind {
        case .remove: String(localized: "Remove target", bundle: SkillsManagerLocalizationResources.bundle)
        case .create: String(localized: "Create target", bundle: SkillsManagerLocalizationResources.bundle)
        case .refresh: String(localized: "Refresh Copy", bundle: SkillsManagerLocalizationResources.bundle)
        case .replace: String(localized: "Change distribution mode", bundle: SkillsManagerLocalizationResources.bundle)
        case .binding: String(localized: "Update saved target", bundle: SkillsManagerLocalizationResources.bundle)
        case .configuration: String(localized: "Save Agent selection", bundle: SkillsManagerLocalizationResources.bundle)
        case .noChange: String(localized: "No change", bundle: SkillsManagerLocalizationResources.bundle)
        }
    }

}
