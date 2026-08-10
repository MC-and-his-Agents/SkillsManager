import SwiftUI

struct SkillBackupLibraryView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(SkillLifecycleViewModel.self) private var model

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Skill Backups", bundle: .module)
                        .font(.title.bold())
                    Text("Verified backups remain available after a managed Skill is deleted.", bundle: .module)
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
                        Label {
                            Text("Refresh backups", bundle: .module)
                        } icon: {
                            Image(systemName: "arrow.clockwise")
                        }
                            .labelStyle(.iconOnly)
                    }
                }
                .disabled(model.isRefreshingBackups || model.isMutating)
                .help(Text("Refresh backups", bundle: .module))
                .accessibilityLabel(Text("Refresh backups", bundle: .module))
            }

            stateContent

            if let problem = model.problem {
                Label(problem.message, systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
                    .accessibilityElement(children: .combine)
            }

            HStack {
                Spacer()
                Button {
                    dismiss()
                } label: {
                    Text("Done", bundle: .module)
                }
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
                localized("Backups unavailable"),
                systemImage: "lock.trianglebadge.exclamationmark",
                description: Text(message)
            )
        case .loading:
            ProgressView(localized("Loading and validating backups…"))
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        case .failed(let problem):
            ContentUnavailableView(
                localized("Backups unavailable"),
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
                localized("No backups"),
                systemImage: "archivebox",
                description: Text("Deleting a managed Skill creates a verified backup here.", bundle: .module)
            )
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            List {
                if !model.recoverableDeletions.isEmpty {
                    Section {
                        ForEach(model.recoverableDeletions, id: \.operationID) { readback in
                            deletionRow(readback)
                        }
                    } header: {
                        Text("Deletion operations", bundle: .module)
                    }
                }
                Section {
                    ForEach(model.backups) { item in
                        backupRow(item)
                    }
                } header: {
                    Text("Backups", bundle: .module)
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
                Text(verbatim: localized(readback.status.displayName))
                    .font(.headline)
                Text("Skill \(readback.skillID.directoryName)", bundle: .module)
                    .font(.caption.monospaced())
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Button {
                Task { await model.retryDeletion(readback) }
            } label: {
                Text("Retry", bundle: .module)
            }
            .disabled(model.isMutating)
            .accessibilityHint(Text(
                "Continues this journaled deletion operation.",
                bundle: .module
            ))
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
                Text(verbatim: localized(item.availability.displayName))
                    if let summary = item.summary {
                        Text(summary.content.contentFingerprint.shortDisplayName)
                        Text(summary.content.statistics.byteCountDescription)
                        Text("\(summary.targets.count) target\(summary.targets.count == 1 ? "" : "s")", bundle: .module)
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
                Button {
                    Task { await model.setBackupPinned(item, isPinned: !item.isPinned) }
                } label: {
                    Text(item.isPinned ? "Unpin" : "Pin", bundle: .module)
                }
                .disabled(model.isMutating)
                .accessibilityLabel(Text(
                    item.isPinned ? "Unpin backup" : "Pin backup",
                    bundle: .module
                ))

                if model.preparingRestoreBackupID == item.backupID {
                    ProgressView()
                        .controlSize(.small)
                        .accessibilityLabel(Text("Preparing restore preview", bundle: .module))
                } else {
                    Button {
                        Task { await model.prepareRestore(item) }
                    } label: {
                        Text("Restore…", bundle: .module)
                    }
                    .disabled(model.isMutating)
                    .accessibilityHint(Text(
                        "Opens a verified restore preview.",
                        bundle: .module
                    ))
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

    private func localized(_ value: String) -> String {
        String(localized: String.LocalizationValue(value), bundle: .module)
    }
}

private struct SkillRestoreConfirmationView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(SkillLifecycleViewModel.self) private var model

    let pending: SkillLifecycleViewModel.PendingRestore

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text("Restore Skill", bundle: .module)
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
                ProgressView(localized("Restoring verified backup…"))
                    .accessibilityLabel(Text("Restoring verified Skill backup", bundle: .module))
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
        GroupBox {
            VStack(alignment: .leading, spacing: 10) {
                LabeledContent {
                    Text(pending.preview.originalSkillID.directoryName)
                } label: {
                    Text("Original Skill ID", bundle: .module)
                }
                LabeledContent {
                    Text(pending.preview.targetSkillID.directoryName)
                } label: {
                    Text("Target Skill ID", bundle: .module)
                }
                LabeledContent {
                    Text(verbatim: localized(
                        pending.preview.targetSkillID == pending.preview.originalSkillID
                            ? "Original identity" : "Independent Skill"
                    ))
                } label: {
                    Text("Restore mode", bundle: .module)
                }
                LabeledContent {
                    Text(pending.preview.summary.content.contentFingerprint.shortDisplayName)
                } label: {
                    Text("Content", bundle: .module)
                }
                LabeledContent {
                    Text(pending.preview.summary.content.statistics.fileCount.formatted(.number))
                } label: {
                    Text("Files", bundle: .module)
                }
                LabeledContent {
                    Text(pending.preview.summary.content.statistics.byteCountDescription)
                } label: {
                    Text("Size", bundle: .module)
                }
                if let source = pending.preview.summary.sourceLocator {
                    LabeledContent {
                        Text(source)
                    } label: {
                        Text("Source", bundle: .module)
                    }
                }

                Divider()
                Toggle(
                    isOn: Binding(
                        get: { model.restoreDistribution },
                        set: { model.restoreDistribution = $0 }
                    )
                ) {
                    Text("Also restore the original Agent targets", bundle: .module)
                }
                    .disabled(pending.preview.summary.targets.isEmpty || model.isRestoring)
                    .accessibilityHint(Text(
                        "If a target conflicts, the Skill remains restored without Agent links.",
                        bundle: .module
                    ))
                if pending.preview.summary.targets.isEmpty {
                    Text("This backup did not have any Agent targets.", bundle: .module)
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
        } label: {
            Text("Verified manifest", bundle: .module)
        }
    }

    private func resultContent(_ result: SkillRestoreResult) -> some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 8) {
                Text(verbatim: localized(result.status.displayName))
                    .font(.headline)
                LabeledContent {
                    Text(result.restoredSkillID.directoryName)
                } label: {
                    Text("Restored Skill ID", bundle: .module)
                }
                ForEach(result.warnings, id: \.self) { warning in
                    Label {
                        Text(verbatim: localized(skillRestoreWarningDescription(warning)))
                    } icon: {
                        Image(systemName: "exclamationmark.triangle")
                    }
                    .foregroundStyle(.orange)
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
            if model.restoreResult == nil {
                Button {
                    model.cancelRestorePreview()
                    dismiss()
                } label: {
                    Text("Cancel", bundle: .module)
                }
                .keyboardShortcut(.cancelAction)
                .disabled(model.isRestoring)
            }

            Spacer()

            if model.restoreResult != nil {
                Button {
                    model.finishRestorePresentation()
                    dismiss()
                } label: {
                    Text("Done", bundle: .module)
                }
                .keyboardShortcut(.defaultAction)
                .disabled(model.isRestoring)
            } else {
                Button {
                    Task { await model.confirmRestore() }
                } label: {
                    Text("Restore", bundle: .module)
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
                .disabled(model.isRestoring)
                .accessibilityLabel(Text(
                    model.isRestoring ? "Restore in progress" : "Restore verified backup",
                    bundle: .module
                ))
            }
        }
    }

    private func localized(_ value: String) -> String {
        String(localized: String.LocalizationValue(value), bundle: .module)
    }
}
