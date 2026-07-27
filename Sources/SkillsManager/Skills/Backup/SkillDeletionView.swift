import SwiftUI

struct SkillDeletionView: View {
    @Environment(SkillLifecycleViewModel.self) private var model

    var body: some View {
        GroupBox("Skills Manager") {
            VStack(alignment: .leading, spacing: 14) {
                stateContent
            }
            .padding(.top, 4)
            .frame(maxWidth: .infinity, alignment: .leading)
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
            status("Select a managed Skill to review deletion.", systemImage: "archivebox")
        case .loading:
            ProgressView("Verifying managed Skill…")
        case .failed(let problem):
            VStack(alignment: .leading, spacing: 10) {
                status(problem.message, systemImage: "exclamationmark.triangle")
                Button("Retry") {
                    Task { await model.refreshCurrent() }
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
                Label(preview.status.displayName, systemImage: preview.status.systemImage)
                    .font(.headline)
                    .accessibilityLabel("Managed Skill status: \(preview.status.displayName)")
                Spacer()
                Button {
                    Task { await model.refreshCurrent() }
                } label: {
                    if model.isRefreshingDeletion {
                        ProgressView()
                            .controlSize(.small)
                    } else {
                        Label("Refresh managed Skill", systemImage: "arrow.clockwise")
                            .labelStyle(.iconOnly)
                    }
                }
                .disabled(model.isRefreshingDeletion || model.isMutating)
                .help("Refresh managed Skill")
                .accessibilityLabel("Refresh managed Skill")
            }

            if let content = preview.content {
                VStack(alignment: .leading, spacing: 6) {
                    LabeledContent("Content", value: content.contentFingerprint.shortDisplayName)
                    LabeledContent("Files", value: "\(content.statistics.fileCount)")
                    LabeledContent("Size", value: content.statistics.byteCountDescription)
                }
            }

            VStack(alignment: .leading, spacing: 6) {
                Text("Current Agent targets")
                    .font(.headline)
                if preview.targets.isEmpty {
                    Text("Not enabled for any Agent.")
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(preview.targets) { target in
                        Text(target.canonicalLocator)
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
                Button("Delete from Skills Manager…", role: .destructive) {
                    model.prepareDeletion()
                }
                .disabled(model.isMutating || preview.token == nil)
                .accessibilityHint(
                    "Opens a confirmation showing the backup, Agent links, and managed content that will be removed."
                )
            } else if let operation = preview.operation {
                Button("Retry deletion") {
                    Task { await model.retryDeletion(operation) }
                }
                .disabled(model.isMutating)
                .accessibilityHint("Continues the existing journaled deletion operation.")
            }

            Text(
                "This is different from removing Agent links. It backs up the Skill, "
                    + "removes all managed Agent links, and deletes the managed Skill itself."
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

    private func feedback(
        _ message: String,
        systemImage: String,
        color: Color
    ) -> some View {
        Label(message, systemImage: systemImage)
            .foregroundStyle(color)
            .accessibilityElement(children: .combine)
    }
}

private struct SkillDeletionConfirmationView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(SkillLifecycleViewModel.self) private var model

    let pending: SkillLifecycleViewModel.PendingDeletion

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text("Delete from Skills Manager?")
                .font(.title.bold())
            Text(pending.preview.displayName)
                .font(.title3)
                .foregroundStyle(.secondary)

            if let result = model.deletionResult {
                resultContent(result)
            } else {
                impactContent
            }

            if model.isDeleting {
                ProgressView("Backing up and deleting…")
                    .accessibilityLabel("Backing up and deleting the managed Skill")
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
        .interactiveDismissDisabled(model.isDeleting)
    }

    private var impactContent: some View {
        GroupBox("Impact") {
            VStack(alignment: .leading, spacing: 10) {
                impactRow("Create a verified backup", systemImage: "archivebox")
                impactRow(
                    "Remove \(pending.preview.targets.count) managed Agent target"
                        + (pending.preview.targets.count == 1 ? "" : "s"),
                    systemImage: "link.badge.minus"
                )
                impactRow("Delete the managed SSOT content and active record", systemImage: "trash")
                impactRow("Keep the backup in the backup library", systemImage: "checkmark.shield")
                if let content = pending.preview.content {
                    Divider()
                    LabeledContent(
                        "Content fingerprint",
                        value: content.contentFingerprint.shortDisplayName
                    )
                    LabeledContent("Files", value: "\(content.statistics.fileCount)")
                    LabeledContent("Size", value: content.statistics.byteCountDescription)
                }
            }
            .padding(.top, 4)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func resultContent(_ result: SkillDeletionResult) -> some View {
        GroupBox("Result") {
            VStack(alignment: .leading, spacing: 8) {
                Label(result.status.displayName, systemImage: result.status.systemImage)
                    .font(.headline)
                LabeledContent(
                    "Backup ID",
                    value: result.backupID.uuid.uuidString.lowercased()
                )
                LabeledContent(
                    "Operation ID",
                    value: result.operationID.uuid.uuidString.lowercased()
                )
            }
            .padding(.top, 4)
        }
    }

    @ViewBuilder
    private var actions: some View {
        HStack {
            if model.deletionResult == nil {
                Button("Cancel") {
                    model.cancelDeletionPreview()
                    dismiss()
                }
                .keyboardShortcut(.cancelAction)
                .disabled(model.isDeleting)
            }

            Spacer()

            if let result = model.deletionResult {
                if [.cleanupPending, .needsRepair, .operationInProgress].contains(result.status) {
                    Button("Retry") {
                        Task { await model.retryDeletion(result) }
                    }
                    .disabled(model.isMutating)
                }
                Button("Done") {
                    model.finishDeletionPresentation()
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(model.isMutating)
            } else {
                Button("Delete", role: .destructive) {
                    Task { await model.confirmDeletion() }
                }
                .keyboardShortcut(.defaultAction)
                .disabled(model.isDeleting)
                .accessibilityLabel(
                    model.isDeleting ? "Deletion in progress" : "Delete from Skills Manager"
                )
            }
        }
    }

    private func impactRow(_ title: String, systemImage: String) -> some View {
        Label(title, systemImage: systemImage)
            .accessibilityElement(children: .combine)
    }
}
