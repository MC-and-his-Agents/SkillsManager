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
            Text("Delete Skill", bundle: SkillsManagerLocalizationResources.bundle)
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
            ProgressView(String(localized: "Verifying managed Skill…", bundle: SkillsManagerLocalizationResources.bundle))
        case .failed(let problem):
            VStack(alignment: .leading, spacing: 10) {
                status(problem.message, systemImage: "exclamationmark.triangle")
                Button {
                    Task { await model.refreshCurrent() }
                } label: {
                    Text("Retry", bundle: SkillsManagerLocalizationResources.bundle)
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
            bundle: SkillsManagerLocalizationResources.bundle
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
                            Text("Refresh Status", bundle: SkillsManagerLocalizationResources.bundle)
                        } icon: {
                            Image(systemName: "arrow.clockwise")
                        }
                            .labelStyle(.iconOnly)
                    }
                }
                .disabled(model.isRefreshingDeletion || model.isMutating)
                .help(Text("Refresh Status", bundle: SkillsManagerLocalizationResources.bundle))
                .accessibilityLabel(Text("Refresh Status", bundle: SkillsManagerLocalizationResources.bundle))
            }

            if let content = preview.content {
                VStack(alignment: .leading, spacing: 6) {
                    LabeledContent {
                        Text(verbatim: content.contentFingerprint.shortDisplayName)
                    } label: {
                        Text("Content", bundle: SkillsManagerLocalizationResources.bundle)
                    }
                    LabeledContent {
                        Text(content.statistics.fileCount.formatted(.number))
                    } label: {
                        Text("Files", bundle: SkillsManagerLocalizationResources.bundle)
                    }
                    LabeledContent {
                        Text(verbatim: content.statistics.byteCountDescription)
                    } label: {
                        Text("Size", bundle: SkillsManagerLocalizationResources.bundle)
                    }
                }
            }

            VStack(alignment: .leading, spacing: 6) {
                Text("Current Agent targets", bundle: SkillsManagerLocalizationResources.bundle)
                    .font(.headline)
                if preview.targets.isEmpty {
                    Text("Not enabled for any Agent.", bundle: SkillsManagerLocalizationResources.bundle)
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(preview.targets) { target in
                        Text(verbatim: target.canonicalLocator)
                            .font(.callout.monospaced())
                            .textSelection(.enabled)
                    }
                }
            }

            // 结果反馈统一由详情页顶部 banner 呈现（SkillDetailFeedbackBanner），
            // 确认 sheet 内的反馈保留在 sheet 中。

            if preview.status == .ready {
                Button(role: .destructive) {
                    model.prepareDeletion()
                } label: {
                    Text("Delete from Skills Manager…", bundle: SkillsManagerLocalizationResources.bundle)
                }
                .disabled(model.isMutating || preview.token == nil)
                .accessibilityHint(Text(
                    "Opens a confirmation showing the backup, Agent links, and managed content that will be removed.",
                    bundle: SkillsManagerLocalizationResources.bundle
                ))
            } else if let operation = preview.operation {
                Button {
                    Task { await model.retryDeletion(operation) }
                } label: {
                    Text("Retry deletion", bundle: SkillsManagerLocalizationResources.bundle)
                }
                .disabled(model.isMutating)
                .accessibilityHint(Text("Continues the interrupted deletion safely.", bundle: SkillsManagerLocalizationResources.bundle))
            }

            Text(
                "This is different from removing Agent links. It backs up the Skill, removes all managed Agent links, and deletes the managed Skill itself.",
                bundle: SkillsManagerLocalizationResources.bundle
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

    private func deletionStatusText(_ status: SkillDeletionStatus) -> String {
        return switch status {
        case .ready: String(localized: "Ready", bundle: SkillsManagerLocalizationResources.bundle)
        case .operationInProgress: String(localized: "Operation in progress", bundle: SkillsManagerLocalizationResources.bundle)
        case .needsRepair: String(localized: "Needs repair", bundle: SkillsManagerLocalizationResources.bundle)
        case .completed: String(localized: "Completed", bundle: SkillsManagerLocalizationResources.bundle)
        case .cleanupPending: String(localized: "Cleanup pending", bundle: SkillsManagerLocalizationResources.bundle)
        case .rolledBack: String(localized: "Rolled back", bundle: SkillsManagerLocalizationResources.bundle)
        }
    }
}

private struct SkillDeletionConfirmationView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(SkillLifecycleViewModel.self) private var model

    let pending: SkillLifecycleViewModel.PendingDeletion

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text("Delete from Skills Manager?", bundle: SkillsManagerLocalizationResources.bundle)
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
            bundle: SkillsManagerLocalizationResources.bundle
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
                        Text("Files", bundle: SkillsManagerLocalizationResources.bundle)
                    }
                    LabeledContent {
                        Text(verbatim: content.statistics.byteCountDescription)
                    } label: {
                        Text("Size", bundle: SkillsManagerLocalizationResources.bundle)
                    }
                }
            }
            .padding(.top, 4)
            .frame(maxWidth: .infinity, alignment: .leading)
        } label: {
            Text("Impact", bundle: SkillsManagerLocalizationResources.bundle)
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
                    Text("Saved in Skill Backups", bundle: SkillsManagerLocalizationResources.bundle)
                } label: {
                    Text("Backup", bundle: SkillsManagerLocalizationResources.bundle)
                }
            }
            .padding(.top, 4)
        } label: {
            Text("Result", bundle: SkillsManagerLocalizationResources.bundle)
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
                    Text("Cancel", bundle: SkillsManagerLocalizationResources.bundle)
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
                        Text("Retry", bundle: SkillsManagerLocalizationResources.bundle)
                    }
                    .disabled(model.isMutating)
                }
                Button {
                    model.finishDeletionPresentation()
                    dismiss()
                } label: {
                    Text("Done", bundle: SkillsManagerLocalizationResources.bundle)
                }
                .keyboardShortcut(.defaultAction)
                .disabled(model.isMutating)
            } else {
                Button(role: .destructive) {
                    Task { await model.confirmDeletion() }
                } label: {
                    Text("Delete", bundle: SkillsManagerLocalizationResources.bundle)
                }
                .disabled(model.isDeleting)
                .accessibilityLabel(Text(
                    model.isDeleting ? "Deletion in progress" : "Delete from Skills Manager",
                    bundle: SkillsManagerLocalizationResources.bundle
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
            bundle: SkillsManagerLocalizationResources.bundle
        ))
        return Label {
            Text(String(
                localized: LocalizedStringResource(
            "Remove \(targetDescription)",
            bundle: SkillsManagerLocalizationResources.bundle
        )))
        } icon: {
            Image(systemName: "link.badge.minus")
        }
        .accessibilityElement(children: .combine)
    }

    private func deletionProgressText() -> String {
        String(
            localized: model.isDeleting ? "Backing up and deleting…" : "Continuing deletion…",
            bundle: SkillsManagerLocalizationResources.bundle
        )
    }

    private func deletionProgressAccessibilityText() -> String {
        String(
            localized: model.isDeleting
                ? "Backing up and deleting the managed Skill"
                : "Continuing the managed Skill deletion",
            bundle: SkillsManagerLocalizationResources.bundle
        )
    }

    private func deletionStatusText(_ status: SkillDeletionStatus) -> String {
        return switch status {
        case .ready: String(localized: "Ready", bundle: SkillsManagerLocalizationResources.bundle)
        case .operationInProgress: String(localized: "Operation in progress", bundle: SkillsManagerLocalizationResources.bundle)
        case .needsRepair: String(localized: "Needs repair", bundle: SkillsManagerLocalizationResources.bundle)
        case .completed: String(localized: "Completed", bundle: SkillsManagerLocalizationResources.bundle)
        case .cleanupPending: String(localized: "Cleanup pending", bundle: SkillsManagerLocalizationResources.bundle)
        case .rolledBack: String(localized: "Rolled back", bundle: SkillsManagerLocalizationResources.bundle)
        }
    }
}
