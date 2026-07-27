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

            Picker("Scope", selection: scopeBinding) {
                Text("Global").tag(SkillDistributionViewModel.ScopeChoice.global)
                Text("Specific Agents").tag(SkillDistributionViewModel.ScopeChoice.agents)
            }
            .pickerStyle(.segmented)
            .disabled(model.isApplying)

            if model.scopeChoice == .global {
                globalScopeDescription
            } else {
                agentSelection
            }

            if !model.currentTargets.isEmpty {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Current targets")
                        .font(.headline)
                    ForEach(model.currentTargets) { target in
                        Text(target.locator)
                            .font(.callout.monospaced())
                            .textSelection(.enabled)
                    }
                }
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
            .accessibilityHint("Shows planned link changes before anything is written.")
        }
    }

    private var globalScopeDescription: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Creates one link in ~/.agents/skills.")
                .foregroundStyle(.secondary)
            Text("Used by \(platformNames(model.globalReaders)).")
            if !model.globalNonReaders.isEmpty {
                Text("\(platformNames(model.globalNonReaders)) requires an Agent-specific target.")
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var agentSelection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Agents")
                .font(.headline)
            ForEach(SkillPlatform.allCases) { platform in
                Toggle(
                    platform.rawValue,
                    isOn: Binding(
                        get: { model.selectedAgents.contains(platform) },
                        set: { model.setAgent(platform, selected: $0) }
                    )
                )
                .disabled(model.isApplying)
            }
            if model.selectedAgents.isEmpty {
                Text("Select at least one Agent.")
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var scopeBinding: Binding<SkillDistributionViewModel.ScopeChoice> {
        Binding(
            get: { model.scopeChoice },
            set: { model.chooseScope($0) }
        )
    }

    private var previewBinding: Binding<SkillDistributionViewModel.PendingPreview?> {
        Binding(
            get: { model.pendingPreview },
            set: { if $0 == nil { model.cancelPreview() } }
        )
    }

    private func platformNames(_ platforms: [SkillPlatform]) -> String {
        platforms.map(\.rawValue).joined(separator: ", ")
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
        }
    }
}
