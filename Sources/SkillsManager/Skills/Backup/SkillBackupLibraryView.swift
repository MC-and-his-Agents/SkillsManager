import SwiftUI

struct SkillBackupLibraryView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(SkillLifecycleViewModel.self) private var model

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Skill Backups")
                        .font(.title.bold())
                    Text("Verified backups remain available after a managed Skill is deleted.")
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button {
                    Task { await model.refreshBackupsOnly() }
                } label: {
                    if model.isRefreshingBackups {
                        ProgressView()
                            .controlSize(.small)
                    } else {
                        Label("Refresh backups", systemImage: "arrow.clockwise")
                            .labelStyle(.iconOnly)
                    }
                }
                .disabled(model.isRefreshingBackups || model.isMutating)
                .help("Refresh backups")
                .accessibilityLabel("Refresh backups")
            }

            stateContent

            if let problem = model.problem {
                Label(problem.message, systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
                    .accessibilityElement(children: .combine)
            }

            HStack {
                Spacer()
                Button("Done") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                    .disabled(model.isMutating)
            }
        }
        .padding(20)
        .frame(minWidth: 720, minHeight: 520)
        .interactiveDismissDisabled(model.isMutating)
        .sheet(item: pendingRestoreBinding) { pending in
            SkillRestoreConfirmationView(pending: pending)
                .environment(model)
        }
    }

    @ViewBuilder
    private var stateContent: some View {
        switch model.backupState {
        case .blocked(let message):
            ContentUnavailableView(
                "Backups unavailable",
                systemImage: "lock.trianglebadge.exclamationmark",
                description: Text(message)
            )
        case .loading:
            ProgressView("Loading and validating backups…")
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        case .failed(let problem):
            ContentUnavailableView(
                "Backups unavailable",
                systemImage: "exclamationmark.triangle",
                description: Text(problem.message)
            )
        case .loaded:
            loadedContent
        }
    }

    @ViewBuilder
    private var loadedContent: some View {
        if model.backups.isEmpty, model.recoverableDeletions.isEmpty {
            ContentUnavailableView(
                "No backups",
                systemImage: "archivebox",
                description: Text("Deleting a managed Skill creates a verified backup here.")
            )
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            List {
                if !model.recoverableDeletions.isEmpty {
                    Section("Deletion operations") {
                        ForEach(model.recoverableDeletions, id: \.operationID) { readback in
                            deletionRow(readback)
                        }
                    }
                }
                Section("Backups") {
                    ForEach(model.backups) { item in
                        backupRow(item)
                    }
                }
            }
        }
    }

    private func deletionRow(_ readback: SkillDeletionResult) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: readback.status.systemImage)
                .foregroundStyle(.secondary)
                .frame(width: 18)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 3) {
                Text(readback.status.displayName)
                    .font(.headline)
                Text("Skill \(readback.skillID.directoryName)")
                    .font(.caption.monospaced())
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Button("Retry") {
                Task { await model.retryDeletion(readback) }
            }
            .disabled(model.isMutating)
            .accessibilityHint("Continues this journaled deletion operation.")
        }
        .accessibilityElement(children: .contain)
    }

    private func backupRow(_ item: SkillBackupCatalogItem) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: item.availability.systemImage)
                .foregroundStyle(.secondary)
                .frame(width: 18)
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 4) {
                Text(item.summary?.content.displayName ?? "Backup \(item.backupID.uuid.uuidString)")
                    .font(.headline)
                    .lineLimit(1)
                Text(item.createdAt.formatted(date: .abbreviated, time: .standard))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                HStack(spacing: 8) {
                    Text(item.availability.displayName)
                    if let summary = item.summary {
                        Text(summary.content.contentFingerprint.shortDisplayName)
                        Text(summary.content.statistics.byteCountDescription)
                        Text("\(summary.targets.count) target\(summary.targets.count == 1 ? "" : "s")")
                    }
                }
                .font(.caption)
                .foregroundStyle(.secondary)
                if let source = item.summary?.sourceLocator {
                    Text(source)
                        .font(.caption.monospaced())
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .textSelection(.enabled)
                }
                if let problem = item.problem {
                    Text(problem.localizedDescription)
                        .font(.caption)
                        .foregroundStyle(.orange)
                }
            }

            Spacer()

            if item.availability == .available {
                Button(item.isPinned ? "Unpin" : "Pin") {
                    Task { await model.setBackupPinned(item, isPinned: !item.isPinned) }
                }
                .disabled(model.isMutating)
                .accessibilityLabel(item.isPinned ? "Unpin backup" : "Pin backup")

                if model.preparingRestoreBackupID == item.backupID {
                    ProgressView()
                        .controlSize(.small)
                        .accessibilityLabel("Preparing restore preview")
                } else {
                    Button("Restore…") {
                        Task { await model.prepareRestore(item) }
                    }
                    .disabled(model.isMutating)
                    .accessibilityHint("Opens a verified restore preview.")
                }
            }
        }
        .padding(.vertical, 4)
        .accessibilityElement(children: .contain)
    }

    private var pendingRestoreBinding: Binding<SkillLifecycleViewModel.PendingRestore?> {
        Binding(
            get: { model.pendingRestore },
            set: { if $0 == nil { model.cancelRestorePreview() } }
        )
    }
}

private struct SkillRestoreConfirmationView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(SkillLifecycleViewModel.self) private var model

    let pending: SkillLifecycleViewModel.PendingRestore

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text("Restore Skill")
                .font(.title.bold())
            Text(pending.preview.summary.content.displayName)
                .font(.title3)
                .foregroundStyle(.secondary)

            if let result = model.restoreResult {
                resultContent(result)
            } else {
                previewContent
            }

            if model.isRestoring {
                ProgressView("Restoring verified backup…")
                    .accessibilityLabel("Restoring verified Skill backup")
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
        .frame(minWidth: 620, minHeight: 500)
        .interactiveDismissDisabled(model.isRestoring)
    }

    private var previewContent: some View {
        GroupBox("Verified manifest") {
            VStack(alignment: .leading, spacing: 10) {
                LabeledContent(
                    "Original Skill ID",
                    value: pending.preview.originalSkillID.directoryName
                )
                LabeledContent(
                    "Target Skill ID",
                    value: pending.preview.targetSkillID.directoryName
                )
                LabeledContent(
                    "Restore mode",
                    value: pending.preview.targetSkillID == pending.preview.originalSkillID
                        ? "Original identity" : "Independent Skill"
                )
                LabeledContent(
                    "Content",
                    value: pending.preview.summary.content.contentFingerprint.shortDisplayName
                )
                LabeledContent(
                    "Files",
                    value: "\(pending.preview.summary.content.statistics.fileCount)"
                )
                LabeledContent(
                    "Size",
                    value: pending.preview.summary.content.statistics.byteCountDescription
                )
                if let source = pending.preview.summary.sourceLocator {
                    LabeledContent("Source", value: source)
                }

                Divider()
                Toggle(
                    "Also restore the original Agent targets",
                    isOn: Binding(
                        get: { model.restoreDistribution },
                        set: { model.restoreDistribution = $0 }
                    )
                )
                    .disabled(pending.preview.summary.targets.isEmpty || model.isRestoring)
                    .accessibilityHint(
                        "If a target conflicts, the Skill remains restored without Agent links."
                    )
                if pending.preview.summary.targets.isEmpty {
                    Text("This backup did not have any Agent targets.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(pending.preview.summary.targets) { target in
                        Text(target.canonicalLocator)
                            .font(.caption.monospaced())
                            .foregroundStyle(.secondary)
                            .textSelection(.enabled)
                    }
                }
            }
            .padding(.top, 4)
        }
    }

    private func resultContent(_ result: SkillRestoreResult) -> some View {
        GroupBox("Result") {
            VStack(alignment: .leading, spacing: 8) {
                Text(result.status.displayName)
                    .font(.headline)
                LabeledContent("Restored Skill ID", value: result.restoredSkillID.directoryName)
                ForEach(result.warnings, id: \.self) { warning in
                    Label(
                        skillRestoreWarningDescription(warning),
                        systemImage: "exclamationmark.triangle"
                    )
                    .foregroundStyle(.orange)
                }
            }
            .padding(.top, 4)
        }
    }

    @ViewBuilder
    private var actions: some View {
        HStack {
            if model.restoreResult == nil {
                Button("Cancel") {
                    model.cancelRestorePreview()
                    dismiss()
                }
                .keyboardShortcut(.cancelAction)
                .disabled(model.isRestoring)
            }

            Spacer()

            if model.restoreResult != nil {
                Button("Done") {
                    model.finishRestorePresentation()
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(model.isRestoring)
            } else {
                Button("Restore") {
                    Task { await model.confirmRestore() }
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
                .disabled(model.isRestoring)
                .accessibilityLabel(
                    model.isRestoring ? "Restore in progress" : "Restore verified backup"
                )
            }
        }
    }
}
