import SwiftUI

struct SkillDeletionView: View {
    @Environment(SkillLifecycleViewModel.self) private var model

    var body: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 14) {
                stateContent
            }
            .padding(.top, 4)
            .frame(maxWidth: .infinity, alignment: .leading)
        } label: {
            Text("Skills Manager", bundle: .module)
        }
        .sheet(item: pendingDeletionBinding) { pending in
            SkillDeletionConfirmationView(pending: pending)
                .environment(model)
        }
    }

    @ViewBuilder
    private var stateContent: some View {
        switch model.deletionState {
        case .blocked(let message):
            status(message, systemImage: "lock.trianglebadge.exclamationmark")
        case .empty:
            localizedStatus(
                "Select a managed Skill to review deletion.",
                systemImage: "archivebox"
            )
        case .loading:
            ProgressView(String(localized: "Verifying managed Skill…", bundle: .module))
        case .failed(let problem):
            VStack(alignment: .leading, spacing: 10) {
                status(problem.message, systemImage: "exclamationmark.triangle")
                Button {
                    Task { await model.refreshCurrent() }
                } label: {
                    Text("Retry", bundle: .module)
                }
                .disabled(model.isRefreshingDeletion || model.isMutating)
            }
        case .ready(let preview):
            readyContent(preview)
        }
    }

    private func readyContent(_ preview: SkillDeletionPreview) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Label {
                    Text(verbatim: deletionStatusText(preview.status))
                } icon: {
                    Image(systemName: preview.status.systemImage)
                }
                    .font(.headline)
                    .accessibilityLabel(Text(
                        String(
                            localized: LocalizedStringResource(
            "Managed Skill status: \(deletionStatusText(preview.status))",
            bundle: .module
        ))
                    ))
                Spacer()
                Button {
                    Task { await model.refreshCurrent() }
                } label: {
                    if model.isRefreshingDeletion {
                        ProgressView()
                            .controlSize(.small)
                    } else {
                        Label {
                            Text("Refresh managed Skill", bundle: .module)
                        } icon: {
                            Image(systemName: "arrow.clockwise")
                        }
                            .labelStyle(.iconOnly)
                    }
                }
                .disabled(model.isRefreshingDeletion || model.isMutating)
                .help(Text("Refresh managed Skill", bundle: .module))
                .accessibilityLabel(Text("Refresh managed Skill", bundle: .module))
            }

            if let content = preview.content {
                VStack(alignment: .leading, spacing: 6) {
                    LabeledContent {
                        Text(verbatim: content.contentFingerprint.shortDisplayName)
                    } label: {
                        Text("Content", bundle: .module)
                    }
                    LabeledContent {
                        Text(content.statistics.fileCount.formatted(.number))
                    } label: {
                        Text("Files", bundle: .module)
                    }
                    LabeledContent {
                        Text(verbatim: content.statistics.byteCountDescription)
                    } label: {
                        Text("Size", bundle: .module)
                    }
                }
            }

            VStack(alignment: .leading, spacing: 6) {
                Text("Current Agent targets", bundle: .module)
                    .font(.headline)
                if preview.targets.isEmpty {
                    Text("Not enabled for any Agent.", bundle: .module)
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(preview.targets) { target in
                        Text(verbatim: target.canonicalLocator)
                            .font(.callout.monospaced())
                            .textSelection(.enabled)
                    }
                }
            }

            if let problem = model.problem {
                feedback(
                    problem.message,
                    systemImage: "exclamationmark.triangle.fill",
                    color: .orange
                )
            }
            if let message = model.successMessage {
                feedback(message, systemImage: "checkmark.circle.fill", color: .green)
            }

            if preview.status == .ready {
                Button(role: .destructive) {
                    model.prepareDeletion()
                } label: {
                    Text("Delete from Skills Manager…", bundle: .module)
                }
                .disabled(model.isMutating || preview.token == nil)
                .accessibilityHint(Text(
                    "Opens a confirmation showing the backup, Agent links, and managed content that will be removed.",
                    bundle: .module
                ))
            } else if let operation = preview.operation {
                Button {
                    Task { await model.retryDeletion(operation) }
                } label: {
                    Text("Retry deletion", bundle: .module)
                }
                .disabled(model.isMutating)
                .accessibilityHint(Text("Continues the interrupted deletion safely.", bundle: .module))
            }

            Text(
                "This is different from removing Agent links. It backs up the Skill, removes all managed Agent links, and deletes the managed Skill itself.",
                bundle: .module
            )
            .font(.caption)
            .foregroundStyle(.secondary)
        }
    }

    private var pendingDeletionBinding: Binding<SkillLifecycleViewModel.PendingDeletion?> {
        Binding(
            get: { model.pendingDeletion },
            set: { if $0 == nil { model.cancelDeletionPreview() } }
        )
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

    private func feedback(
        _ message: String,
        systemImage: String,
        color: Color
    ) -> some View {
        Label(message, systemImage: systemImage)
            .foregroundStyle(color)
            .accessibilityElement(children: .combine)
    }

    private func deletionStatusText(_ status: SkillDeletionStatus) -> String {
        return switch status {
        case .ready: String(localized: "Ready", bundle: .module)
        case .operationInProgress: String(localized: "Operation in progress", bundle: .module)
        case .needsRepair: String(localized: "Needs repair", bundle: .module)
        case .completed: String(localized: "Completed", bundle: .module)
        case .cleanupPending: String(localized: "Cleanup pending", bundle: .module)
        case .rolledBack: String(localized: "Rolled back", bundle: .module)
        }
    }
}

private struct SkillDeletionConfirmationView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(SkillLifecycleViewModel.self) private var model

    let pending: SkillLifecycleViewModel.PendingDeletion

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text("Delete from Skills Manager?", bundle: .module)
                .font(.title.bold())
            Text(verbatim: pending.preview.displayName)
                .font(.title3)
                .foregroundStyle(.secondary)

            if let result = model.deletionResult {
                resultContent(result)
            } else {
                impactContent
            }

            if model.isDeleting || model.isRetryingDeletion {
                ProgressView(deletionProgressText())
                .accessibilityLabel(Text(verbatim: deletionProgressAccessibilityText()))
            }
            if let problem = model.problem {
                Label(problem.message, systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
                    .accessibilityElement(children: .combine)
            }
            if let message = model.successMessage {
                Label(message, systemImage: "checkmark.circle.fill")
                    .foregroundStyle(.green)
                    .accessibilityElement(children: .combine)
            }

            Spacer()
            actions
        }
        .padding(20)
        .frame(minWidth: 620, minHeight: 470)
        .interactiveDismissDisabled(model.isMutating)
    }

    private var impactContent: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 10) {
                impactRow("Create a verified backup", systemImage: "archivebox")
                targetImpactRow
                ForEach(pending.preview.targets) { target in
                    Text(verbatim: target.canonicalLocator)
                        .font(.callout.monospaced())
                        .textSelection(.enabled)
                        .accessibilityLabel(Text(
                            String(
                                localized: LocalizedStringResource(
            "Managed Agent target \(target.canonicalLocator)",
            bundle: .module
        ))
                        ))
                }
                impactRow("Delete the managed Skill and its library record", systemImage: "trash")
                impactRow("Keep the backup in the backup library", systemImage: "checkmark.shield")
                if let content = pending.preview.content {
                    Divider()
                    LabeledContent {
                        Text(content.statistics.fileCount.formatted(.number))
                    } label: {
                        Text("Files", bundle: .module)
                    }
                    LabeledContent {
                        Text(verbatim: content.statistics.byteCountDescription)
                    } label: {
                        Text("Size", bundle: .module)
                    }
                }
            }
            .padding(.top, 4)
            .frame(maxWidth: .infinity, alignment: .leading)
        } label: {
            Text("Impact", bundle: .module)
        }
    }

    private func resultContent(_ result: SkillDeletionResult) -> some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 8) {
                Label {
                    Text(verbatim: deletionStatusText(result.status))
                } icon: {
                    Image(systemName: result.status.systemImage)
                }
                    .font(.headline)
                LabeledContent {
                    Text("Saved in Skill Backups", bundle: .module)
                } label: {
                    Text("Backup", bundle: .module)
                }
            }
            .padding(.top, 4)
        } label: {
            Text("Result", bundle: .module)
        }
    }

    @ViewBuilder
    private var actions: some View {
        HStack {
            if model.deletionResult == nil {
                Button {
                    model.cancelDeletionPreview()
                    dismiss()
                } label: {
                    Text("Cancel", bundle: .module)
                }
                .keyboardShortcut(.cancelAction)
                .disabled(model.isDeleting)
            }

            Spacer()

            if let result = model.deletionResult {
                if [.cleanupPending, .needsRepair, .operationInProgress].contains(result.status) {
                    Button {
                        Task { await model.retryDeletion(result) }
                    } label: {
                        Text("Retry", bundle: .module)
                    }
                    .disabled(model.isMutating)
                }
                Button {
                    model.finishDeletionPresentation()
                    dismiss()
                } label: {
                    Text("Done", bundle: .module)
                }
                .keyboardShortcut(.defaultAction)
                .disabled(model.isMutating)
            } else {
                Button(role: .destructive) {
                    Task { await model.confirmDeletion() }
                } label: {
                    Text("Delete", bundle: .module)
                }
                .disabled(model.isDeleting)
                .accessibilityLabel(Text(
                    model.isDeleting ? "Deletion in progress" : "Delete from Skills Manager",
                    bundle: .module
                ))
            }
        }
    }

    private func impactRow(_ title: LocalizedStringResource, systemImage: String) -> some View {
        Label {
            Text(title)
        } icon: {
            Image(systemName: systemImage)
        }
            .accessibilityElement(children: .combine)
    }

    private var targetImpactRow: some View {
        let targetDescription = String(
            localized: LocalizedStringResource(
            "Managed Agent targets: \(pending.preview.targets.count)",
            bundle: .module
        ))
        return Label {
            Text(String(
                localized: LocalizedStringResource(
            "Remove \(targetDescription)",
            bundle: .module
        )))
        } icon: {
            Image(systemName: "link.badge.minus")
        }
        .accessibilityElement(children: .combine)
    }

    private func deletionProgressText() -> String {
        String(
            localized: model.isDeleting ? "Backing up and deleting…" : "Continuing deletion…",
            bundle: .module
        )
    }

    private func deletionProgressAccessibilityText() -> String {
        String(
            localized: model.isDeleting
                ? "Backing up and deleting the managed Skill"
                : "Continuing the managed Skill deletion",
            bundle: .module
        )
    }

    private func deletionStatusText(_ status: SkillDeletionStatus) -> String {
        return switch status {
        case .ready: String(localized: "Ready", bundle: .module)
        case .operationInProgress: String(localized: "Operation in progress", bundle: .module)
        case .needsRepair: String(localized: "Needs repair", bundle: .module)
        case .completed: String(localized: "Completed", bundle: .module)
        case .cleanupPending: String(localized: "Cleanup pending", bundle: .module)
        case .rolledBack: String(localized: "Rolled back", bundle: .module)
        }
    }
}
