import SwiftUI

struct ManagedArchiveImportView: View {
    let model: ManagedArchiveImportViewModel
    let onPrepare: @MainActor (ManagedLocalImportScope) -> Void
    let onConfirm: @MainActor () -> Void
    @State private var distributionMode: ManagedInstallDistributionMode = .global
    @State private var selectedAgents: Set<SkillPlatform> = [.codex]

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if let message = model.errorMessage {
                Label(message, systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
                    .accessibilityElement(children: .combine)
            }
            scopePicker
            content
        }
    }

    private var scopePicker: some View {
        ManagedInstallScopePicker(
            mode: $distributionMode,
            selectedAgents: $selectedAgents,
            isDisabled: model.isWorking || model.state != .selecting
        )
    }

    @ViewBuilder
    private var content: some View {
        switch model.state {
        case .idle:
            ContentUnavailableView(String(localized: "Choose a ZIP archive", bundle: SkillsManagerLocalizationResources.bundle), systemImage: "archivebox")
        case .selecting:
            selection
        case .preparing:
            ProgressView(String(localized: "Preparing previews…", bundle: SkillsManagerLocalizationResources.bundle))
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        case .ready:
            preview
        case .executing:
            execution
        case .completed:
            results
        }
    }

    private var selection: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Button {
                    model.selectAllSafe()
                } label: {
                    Text("Select safe", bundle: SkillsManagerLocalizationResources.bundle)
                }
                    .disabled(model.availableCandidateCount == 0)
                    .accessibilityIdentifier("archive.select-safe")
                Button {
                    model.clearSelection()
                } label: {
                    Text("Clear", bundle: SkillsManagerLocalizationResources.bundle)
                }
                    .disabled(model.selectedCount == 0)
                    .accessibilityIdentifier("archive.clear-selection")
                Spacer()
                Text(String(
                    localized: LocalizedStringResource(
            "\(model.selectedCount) selected",
            bundle: SkillsManagerLocalizationResources.bundle
        )))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            List(model.candidates) { candidate in
                candidateRow(candidate)
            }
            .listStyle(.inset)
            .frame(minHeight: 260)
            HStack {
                Spacer()
                Button {
                    onPrepare(requestedScope)
                } label: {
                    Text("Review selected…", bundle: SkillsManagerLocalizationResources.bundle)
                }
                .buttonStyle(.borderedProminent)
                .disabled(!model.canPrepare || !scopeIsValid)
                .accessibilityIdentifier("archive.review-selected")
            }
        }
    }

    private func candidateRow(
        _ candidate: SkillImportWorker.ArchiveCandidate
    ) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Toggle(
                isOn: Binding(
                    get: { model.isSelected(candidate.id) },
                    set: { _ in model.toggleSelection(candidate.id) }
                )
            ) {
                VStack(alignment: .leading, spacing: 3) {
                    Text(verbatim: candidate.displayName)
                        .font(.headline)
                    Text(verbatim: candidate.canonicalSubpath.isEmpty ? "." : candidate.canonicalSubpath)
                        .font(.caption.monospaced())
                        .foregroundStyle(.secondary)
                    if let slug = candidate.slug {
                        Text(String(
                            localized: LocalizedStringResource(
            "Slug: \(slug.value)",
            bundle: SkillsManagerLocalizationResources.bundle
        )))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    if let reason = candidate.blockedReason {
                        Text(blockedReasonText(reason))
                            .font(.caption)
                            .foregroundStyle(.orange)
                    }
                }
            }
            .toggleStyle(.checkbox)
            .disabled(!candidate.isImportable)
            .accessibilityLabel(candidate.displayName)
            .accessibilityValue(
            candidate.blockedReason
                    .map(blockedReasonText)
                    ?? String(localized: "Importable", bundle: SkillsManagerLocalizationResources.bundle)
            )
            .accessibilityIdentifier("archive.candidate.\(candidate.canonicalSubpath)")
        }
        .padding(.vertical, 4)
    }

    private var preview: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label {
                Text(
                    "Nothing has been written. Confirm once to import the selected Skills in order.",
                    bundle: SkillsManagerLocalizationResources.bundle
                )
            } icon: {
                Image(systemName: "eye")
            }
            .foregroundStyle(.secondary)
            List(model.previewItems) { item in
                VStack(alignment: .leading, spacing: 3) {
                    Text(verbatim: item.candidate.displayName).font(.headline)
                    Text(verbatim: item.candidate.canonicalSubpath.isEmpty ? "." : item.candidate.canonicalSubpath)
                        .font(.caption.monospaced())
                        .foregroundStyle(.secondary)
                    if let slug = item.preview?.distributionSlug {
                        Text(String(
                            localized: LocalizedStringResource(
            "Slug: \(slug.value)",
            bundle: SkillsManagerLocalizationResources.bundle
        )))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    if let reason = item.reason {
                        Label {
                            Text(verbatim: reason)
                        } icon: {
                            Image(systemName: "xmark.circle")
                        }
                            .font(.caption)
                            .foregroundStyle(.orange)
                    }
                    if let preview = item.preview,
                       preview.plan.status == .blocked {
                        Label {
                            Text(
                                "Distribution is blocked. This Skill will be added without enabling.",
                                bundle: SkillsManagerLocalizationResources.bundle
                            )
                        } icon: {
                            Image(systemName: "exclamationmark.triangle")
                        }
                        .font(.caption)
                        .foregroundStyle(.orange)
                        ForEach(
                            Array(preview.plan.conflicts.enumerated()),
                            id: \.offset
                        ) { _, conflict in
                            Text(verbatim: "\(conflict.reason.localizedDisplayName): \(conflict.canonicalLocator)")
                                .font(.caption.monospaced())
                                .textSelection(.enabled)
                        }
                    }
                }
                .padding(.vertical, 3)
                .accessibilityElement(children: .combine)
            }
            .listStyle(.inset)
            .frame(minHeight: 260)
            HStack {
                Button {
                    model.cancelPreview()
                } label: {
                    Text("Back", bundle: SkillsManagerLocalizationResources.bundle)
                }
                Spacer()
                Button {
                    onConfirm()
                } label: {
                    Text(
                        model.hasBlockedDistribution
                            ? "Add selected to library"
                            : "Import selected",
                        bundle: SkillsManagerLocalizationResources.bundle
                    )
                }
                .buttonStyle(.borderedProminent)
                .disabled(!model.canConfirm)
                .accessibilityIdentifier("archive.confirm")
            }
        }
    }

    private var execution: some View {
        VStack(alignment: .leading, spacing: 8) {
            ProgressView(String(localized: "Importing selected Skills…", bundle: SkillsManagerLocalizationResources.bundle))
            List(model.resultItems) { result in
                resultRow(result)
            }
            .listStyle(.inset)
        }
    }

    private var results: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label(
                model.summary.failed == 0
                    ? String(localized: "Batch import finished.", bundle: SkillsManagerLocalizationResources.bundle)
                    : String(localized: "Batch import finished with failures.", bundle: SkillsManagerLocalizationResources.bundle),
                systemImage: model.summary.failed == 0
                    ? "checkmark.circle"
                    : "exclamationmark.triangle"
            )
            .foregroundStyle(model.summary.failed == 0 ? .green : .orange)
            List(model.resultItems) { result in
                resultRow(result)
            }
            .listStyle(.inset)
        }
    }

    private func resultRow(
        _ result: ManagedArchiveImportResultItem
    ) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(verbatim: result.displayName).font(.headline)
            Text(verbatim: result.canonicalSubpath.isEmpty ? "." : result.canonicalSubpath)
                .font(.caption.monospaced())
                .foregroundStyle(.secondary)
            switch result.management {
            case .imported(let status):
                Text(managementText(status)).foregroundStyle(.green)
            case .skipped(let reason), .failed(let reason):
                Text(verbatim: reason).foregroundStyle(.orange)
            }
        }
        .padding(.vertical, 3)
        .accessibilityElement(children: .combine)
    }

    private var scopeIsValid: Bool {
        distributionMode == .global || !selectedAgents.isEmpty
    }

    private var requestedScope: ManagedLocalImportScope {
        distributionMode == .global ? .global : .agents(selectedAgents)
    }

    private func managementText(_ status: ManagedLocalImportResultStatus) -> String {
        switch status {
        case .distributed: String(localized: "Imported and enabled", bundle: SkillsManagerLocalizationResources.bundle)
        case .noDistributionChanges, .alreadyManaged: String(localized: "Imported", bundle: SkillsManagerLocalizationResources.bundle)
        case .managedUndistributed: String(localized: "Imported but not enabled", bundle: SkillsManagerLocalizationResources.bundle)
        case .managedDistributionIndeterminate, .managementIndeterminate:
            String(localized: "Imported; status needs attention", bundle: SkillsManagerLocalizationResources.bundle)
        case .updateRequired: String(localized: "Update required", bundle: SkillsManagerLocalizationResources.bundle)
        case .updated: String(localized: "Updated", bundle: SkillsManagerLocalizationResources.bundle)
        case .updatedDistributionNeedsAttention, .updateIndeterminate:
            String(localized: "Updated; status needs attention", bundle: SkillsManagerLocalizationResources.bundle)
        }
    }

    private func blockedReasonText(_ reason: String) -> String {
        switch reason {
        case "The selected item must be a regular folder, not a symbolic link.":
            return String(localized: "The selected item must be a regular folder, not a symbolic link.", bundle: SkillsManagerLocalizationResources.bundle)
        case "The selected item doesn’t contain a SKILL.md file.":
            return String(localized: "The selected item doesn’t contain a SKILL.md file.", bundle: SkillsManagerLocalizationResources.bundle)
        case "The selected item contains more than one Skill folder.":
            return String(localized: "The selected item contains more than one Skill folder.", bundle: SkillsManagerLocalizationResources.bundle)
        case "The Skill candidate could not be validated safely.":
            return String(localized: "The Skill candidate could not be validated safely.", bundle: SkillsManagerLocalizationResources.bundle)
        case let value where value.hasPrefix("The Skill manifest must be a regular file: "):
            let path = String(value.dropFirst("The Skill manifest must be a regular file: ".count))
            return String(localized: LocalizedStringResource(
                "The Skill manifest must be a regular file: \(path)",
                bundle: SkillsManagerLocalizationResources.bundle
            ))
        case let value where value.hasPrefix("The zip archive is unsafe or invalid: "):
            let detail = String(value.dropFirst("The zip archive is unsafe or invalid: ".count))
            return String(localized: LocalizedStringResource(
                "The zip archive is unsafe or invalid: \(detail)",
                bundle: SkillsManagerLocalizationResources.bundle
            ))
        case let value where value.hasPrefix("The Skill contents are unsafe or invalid: "):
            let detail = String(value.dropFirst("The Skill contents are unsafe or invalid: ".count))
            return String(localized: LocalizedStringResource(
                "The Skill contents are unsafe or invalid: \(detail)",
                bundle: SkillsManagerLocalizationResources.bundle
            ))
        default:
            return reason
        }
    }

}
