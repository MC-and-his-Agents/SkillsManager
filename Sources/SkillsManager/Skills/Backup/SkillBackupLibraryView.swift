import SwiftUI

struct SkillBackupLibraryView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(SkillLifecycleViewModel.self) private var model

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Skill Backups", bundle: SkillsManagerLocalizationResources.bundle)
                        .font(.title.bold())
                    Text("Verified backups remain available after a managed Skill is deleted.", bundle: SkillsManagerLocalizationResources.bundle)
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
                            Text("Refresh backups", bundle: SkillsManagerLocalizationResources.bundle)
                        } icon: {
                            Image(systemName: "arrow.clockwise")
                        }
                            .labelStyle(.iconOnly)
                    }
                }
                .disabled(model.isRefreshingBackups || model.isMutating)
                .help(Text("Refresh backups", bundle: SkillsManagerLocalizationResources.bundle))
                .accessibilityLabel(Text("Refresh backups", bundle: SkillsManagerLocalizationResources.bundle))
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
                    Text("Done", bundle: SkillsManagerLocalizationResources.bundle)
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
                String(localized: "Backups unavailable", bundle: SkillsManagerLocalizationResources.bundle),
                systemImage: "lock.trianglebadge.exclamationmark",
                description: Text(verbatim: message)
            )
        case .loading:
            ProgressView(String(localized: "Loading and validating backups…", bundle: SkillsManagerLocalizationResources.bundle))
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        case .failed(let problem):
            ContentUnavailableView(
                String(localized: "Backups unavailable", bundle: SkillsManagerLocalizationResources.bundle),
                systemImage: "exclamationmark.triangle",
                description: Text(verbatim: problem.message)
            )
        case .loaded:
            loadedContent
        }
    }

    @ViewBuilder
    private var loadedContent: some View {
        if model.backups.isEmpty, model.recoverableDeletions.isEmpty {
            ContentUnavailableView(
                String(localized: "No backups", bundle: SkillsManagerLocalizationResources.bundle),
                systemImage: "archivebox",
                description: Text("Deleting a managed Skill creates a verified backup here.", bundle: SkillsManagerLocalizationResources.bundle)
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
                        Text("Deletion operations", bundle: SkillsManagerLocalizationResources.bundle)
                    }
                }
                Section {
                    ForEach(model.backups) { item in
                        backupRow(item)
                    }
                } header: {
                    Text("Backups", bundle: SkillsManagerLocalizationResources.bundle)
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
                Text(verbatim: deletionStatusText(readback.status))
                    .font(.headline)
                Text(
                    String(
                        localized: LocalizedStringResource(
            "Skill \(readback.skillID.directoryName)",
            bundle: SkillsManagerLocalizationResources.bundle
        ))
                )
                    .font(.caption.monospaced())
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Button {
                Task { await model.retryDeletion(readback) }
            } label: {
                Text("Retry", bundle: SkillsManagerLocalizationResources.bundle)
            }
            .disabled(model.isMutating)
            .accessibilityHint(Text(
                "Continues this journaled deletion operation.",
                bundle: SkillsManagerLocalizationResources.bundle
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
                Text(verbatim: item.summary?.content.displayName ?? String(
                    localized: LocalizedStringResource(
            "Backup \(item.backupID.uuid.uuidString)",
            bundle: SkillsManagerLocalizationResources.bundle
        )))
                    .font(.headline)
                    .lineLimit(1)
                Text(verbatim: item.createdAt.formatted(date: .abbreviated, time: .standard))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                HStack(spacing: 8) {
                Text(verbatim: backupAvailabilityText(item.availability))
                    if let summary = item.summary {
                        Text(verbatim: summary.content.contentFingerprint.shortDisplayName)
                        Text(verbatim: summary.content.statistics.byteCountDescription)
                        Text(
                            String(
                                localized: LocalizedStringResource(
            "\(summary.targets.count) target\(summary.targets.count == 1 ? "" : "s")",
            bundle: SkillsManagerLocalizationResources.bundle
        ))
                        )
                    }
                }
                .font(.caption)
                .foregroundStyle(.secondary)
                if let source = item.summary?.sourceLocator {
                    Text(verbatim: source)
                        .font(.caption.monospaced())
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .textSelection(.enabled)
                }
                if let problem = item.problem {
                    Text(deletionErrorText(problem))
                        .font(.caption)
                        .foregroundStyle(.orange)
                }
            }

            Spacer()

            if item.availability == .available {
                Button {
                    Task { await model.setBackupPinned(item, isPinned: !item.isPinned) }
                } label: {
                    Text(item.isPinned ? "Unpin" : "Pin", bundle: SkillsManagerLocalizationResources.bundle)
                }
                .disabled(model.isMutating)
                .accessibilityLabel(Text(
                    item.isPinned ? "Unpin backup" : "Pin backup",
                    bundle: SkillsManagerLocalizationResources.bundle
                ))

                if model.preparingRestoreBackupID == item.backupID {
                    ProgressView()
                        .controlSize(.small)
                        .accessibilityLabel(Text("Preparing restore preview", bundle: SkillsManagerLocalizationResources.bundle))
                } else {
                    Button {
                        Task { await model.prepareRestore(item) }
                    } label: {
                        Text("Restore…", bundle: SkillsManagerLocalizationResources.bundle)
                    }
                    .disabled(model.isMutating)
                    .accessibilityHint(Text(
                        "Opens a verified restore preview.",
                        bundle: SkillsManagerLocalizationResources.bundle
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

    private func backupAvailabilityText(_ availability: SkillBackupCatalogAvailability) -> String {
        return switch availability {
        case .available: String(localized: "Available", bundle: SkillsManagerLocalizationResources.bundle)
        case .preparing: String(localized: "Preparing", bundle: SkillsManagerLocalizationResources.bundle)
        case .pruning: String(localized: "Cleaning up", bundle: SkillsManagerLocalizationResources.bundle)
        case .needsRepair: String(localized: "Needs repair", bundle: SkillsManagerLocalizationResources.bundle)
        case .corrupt: String(localized: "Corrupt", bundle: SkillsManagerLocalizationResources.bundle)
        case .permissionDenied: String(localized: "Permission required", bundle: SkillsManagerLocalizationResources.bundle)
        case .unavailable: String(localized: "Unavailable", bundle: SkillsManagerLocalizationResources.bundle)
        }
    }

    private func deletionErrorText(_ error: SkillDeletionError) -> String {
        switch error {
        case .skillNotFound: String(localized: "The managed Skill was not found.", bundle: SkillsManagerLocalizationResources.bundle)
        case .conflict: String(localized: "The managed Skill changed during deletion.", bundle: SkillsManagerLocalizationResources.bundle)
        case .previewExpired: String(localized: "The preview expired because the managed state changed.", bundle: SkillsManagerLocalizationResources.bundle)
        case .operationInProgress: String(localized: "A deletion operation is already in progress.", bundle: SkillsManagerLocalizationResources.bundle)
        case .needsRepair: String(localized: "The deletion operation requires repair.", bundle: SkillsManagerLocalizationResources.bundle)
        case .backupCorrupt: String(localized: "The Skill backup is missing or corrupt.", bundle: SkillsManagerLocalizationResources.bundle)
        case .permissionDenied: String(localized: "Skills Manager does not have permission for this operation.", bundle: SkillsManagerLocalizationResources.bundle)
        case .unavailable: String(localized: "The deletion service is unavailable.", bundle: SkillsManagerLocalizationResources.bundle)
        }
    }
}

private struct SkillRestoreConfirmationView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(SkillLifecycleViewModel.self) private var model

    let pending: SkillLifecycleViewModel.PendingRestore

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text("Restore Skill", bundle: SkillsManagerLocalizationResources.bundle)
                .font(.title.bold())
                    Text(verbatim: pending.preview.summary.content.displayName)
                .font(.title3)
                .foregroundStyle(.secondary)

            if let result = model.restoreResult {
                resultContent(result)
            } else {
                previewContent
            }

            if model.isRestoring {
                ProgressView(String(localized: "Restoring verified backup…", bundle: SkillsManagerLocalizationResources.bundle))
                    .accessibilityLabel(Text("Restoring verified Skill backup", bundle: SkillsManagerLocalizationResources.bundle))
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
                    Text("Original Skill ID", bundle: SkillsManagerLocalizationResources.bundle)
                }
                LabeledContent {
                    Text(pending.preview.targetSkillID.directoryName)
                } label: {
                    Text("Target Skill ID", bundle: SkillsManagerLocalizationResources.bundle)
                }
                LabeledContent {
                    Text(verbatim: pending.preview.targetSkillID == pending.preview.originalSkillID
                        ? String(localized: "Original identity", bundle: SkillsManagerLocalizationResources.bundle)
                        : String(localized: "Independent Skill", bundle: SkillsManagerLocalizationResources.bundle))
                } label: {
                    Text("Restore mode", bundle: SkillsManagerLocalizationResources.bundle)
                }
                LabeledContent {
                    Text(pending.preview.summary.content.contentFingerprint.shortDisplayName)
                } label: {
                    Text("Content", bundle: SkillsManagerLocalizationResources.bundle)
                }
                LabeledContent {
                    Text(pending.preview.summary.content.statistics.fileCount.formatted(.number))
                } label: {
                    Text("Files", bundle: SkillsManagerLocalizationResources.bundle)
                }
                LabeledContent {
                    Text(pending.preview.summary.content.statistics.byteCountDescription)
                } label: {
                    Text("Size", bundle: SkillsManagerLocalizationResources.bundle)
                }
                if let source = pending.preview.summary.sourceLocator {
                    LabeledContent {
                        Text(verbatim: source)
                    } label: {
                        Text("Source", bundle: SkillsManagerLocalizationResources.bundle)
                    }
                }

                Divider()
                Toggle(
                    isOn: Binding(
                        get: { model.restoreDistribution },
                        set: { model.restoreDistribution = $0 }
                    )
                ) {
                    Text("Also restore the original Agent targets", bundle: SkillsManagerLocalizationResources.bundle)
                }
                    .disabled(pending.preview.summary.targets.isEmpty || model.isRestoring)
                    .accessibilityHint(Text(
                        "If a target conflicts, the Skill remains restored without Agent links.",
                        bundle: SkillsManagerLocalizationResources.bundle
                    ))
                if pending.preview.summary.targets.isEmpty {
                    Text("This backup did not have any Agent targets.", bundle: SkillsManagerLocalizationResources.bundle)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(pending.preview.summary.targets) { target in
                    Text(verbatim: target.canonicalLocator)
                            .font(.caption.monospaced())
                            .foregroundStyle(.secondary)
                            .textSelection(.enabled)
                    }
                }
            }
            .padding(.top, 4)
        } label: {
            Text("Verified manifest", bundle: SkillsManagerLocalizationResources.bundle)
        }
    }

    private func resultContent(_ result: SkillRestoreResult) -> some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 8) {
                Text(verbatim: restoreStatusText(result.status))
                    .font(.headline)
                LabeledContent {
                    Text(verbatim: result.restoredSkillID.directoryName)
                } label: {
                    Text("Restored Skill ID", bundle: SkillsManagerLocalizationResources.bundle)
                }
                ForEach(result.warnings, id: \.self) { warning in
                    Label {
                        Text(verbatim: restoreWarningText(warning))
                    } icon: {
                        Image(systemName: "exclamationmark.triangle")
                    }
                    .foregroundStyle(.orange)
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
            if model.restoreResult == nil {
                Button {
                    model.cancelRestorePreview()
                    dismiss()
                } label: {
                    Text("Cancel", bundle: SkillsManagerLocalizationResources.bundle)
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
                    Text("Done", bundle: SkillsManagerLocalizationResources.bundle)
                }
                .keyboardShortcut(.defaultAction)
                .disabled(model.isRestoring)
            } else {
                Button {
                    Task { await model.confirmRestore() }
                } label: {
                    Text("Restore", bundle: SkillsManagerLocalizationResources.bundle)
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
                .disabled(model.isRestoring)
                .accessibilityLabel(Text(
                    model.isRestoring ? "Restore in progress" : "Restore verified backup",
                    bundle: SkillsManagerLocalizationResources.bundle
                ))
            }
        }
    }

    private func restoreStatusText(_ status: SkillRestoreStatus) -> String {
        return switch status {
        case .ready: String(localized: "Ready to restore", bundle: SkillsManagerLocalizationResources.bundle)
        case .noOp: String(localized: "Matching Skill already exists", bundle: SkillsManagerLocalizationResources.bundle)
        case .completed: String(localized: "Restored", bundle: SkillsManagerLocalizationResources.bundle)
        case .restoredUndistributed: String(localized: "Restored without Agent targets", bundle: SkillsManagerLocalizationResources.bundle)
        }
    }

    private func restoreWarningText(_ warning: String) -> String {
        switch warning {
        case "distribution_conflict":
            return String(localized: "The original Agent targets conflict with current managed content.", bundle: SkillsManagerLocalizationResources.bundle)
        case "source_conflict":
            return String(localized: "The original repository identity is already used by another Skill.", bundle: SkillsManagerLocalizationResources.bundle)
        case "source_unavailable":
            return String(localized: "The original source could not be restored.", bundle: SkillsManagerLocalizationResources.bundle)
        default:
            if warning.hasPrefix("alias_conflict:") {
                return String(localized: "A provider alias is already used and was not restored.", bundle: SkillsManagerLocalizationResources.bundle)
            }
            if warning.hasPrefix("origin_conflict:") {
                return String(localized: "A local origin is already used and was not restored.", bundle: SkillsManagerLocalizationResources.bundle)
            }
            return warning
        }
    }
}
