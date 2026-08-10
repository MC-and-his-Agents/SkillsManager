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
            ContentUnavailableView(String(localized: "Choose a ZIP archive", bundle: .module), systemImage: "archivebox")
        case .selecting:
            selection
        case .preparing:
            ProgressView(String(localized: "Preparing previews…", bundle: .module))
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
                    Text("Select safe", bundle: .module)
                }
                    .disabled(model.availableCandidateCount == 0)
                    .accessibilityIdentifier("archive.select-safe")
                Button {
                    model.clearSelection()
                } label: {
                    Text("Clear", bundle: .module)
                }
                    .disabled(model.selectedCount == 0)
                    .accessibilityIdentifier("archive.clear-selection")
                Spacer()
                Text("\(model.selectedCount) selected", bundle: .module)
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
                    Text("Review selected…", bundle: .module)
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
                    Text(candidate.displayName)
                        .font(.headline)
                    Text(candidate.canonicalSubpath.isEmpty ? "." : candidate.canonicalSubpath)
                        .font(.caption.monospaced())
                        .foregroundStyle(.secondary)
                    if let slug = candidate.slug {
                        Text("Slug: \(slug.value)", bundle: .module)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    if let reason = candidate.blockedReason {
                        Text(reason)
                            .font(.caption)
                            .foregroundStyle(.orange)
                    }
                }
            }
            .toggleStyle(.checkbox)
            .disabled(!candidate.isImportable)
            .accessibilityLabel(candidate.displayName)
            .accessibilityValue(candidate.blockedReason ?? "Importable")
            .accessibilityIdentifier("archive.candidate.\(candidate.canonicalSubpath)")
        }
        .padding(.vertical, 4)
    }

    private var preview: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label {
                Text(
                    "Nothing has been written. Confirm once to import the selected Skills in order.",
                    bundle: .module
                )
            } icon: {
                Image(systemName: "eye")
            }
            .foregroundStyle(.secondary)
            List(model.previewItems) { item in
                VStack(alignment: .leading, spacing: 3) {
                    Text(item.candidate.displayName).font(.headline)
                    Text(item.candidate.canonicalSubpath.isEmpty ? "." : item.candidate.canonicalSubpath)
                        .font(.caption.monospaced())
                        .foregroundStyle(.secondary)
                    if let slug = item.preview?.distributionSlug {
                        Text("Slug: \(slug.value)", bundle: .module)
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
                                bundle: .module
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
                            Text("\(conflict.reason.displayName): \(conflict.canonicalLocator)", bundle: .module)
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
                    Text("Back", bundle: .module)
                }
                Spacer()
                Button {
                    onConfirm()
                } label: {
                    Text(
                        model.hasBlockedDistribution
                            ? "Add selected to library"
                            : "Import selected",
                        bundle: .module
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
            ProgressView(String(localized: "Importing selected Skills…", bundle: .module))
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
                    ? "Batch import finished."
                    : "Batch import finished with failures.",
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
            Text(result.displayName).font(.headline)
            Text(result.canonicalSubpath.isEmpty ? "." : result.canonicalSubpath)
                .font(.caption.monospaced())
                .foregroundStyle(.secondary)
            switch result.management {
            case .imported(let status):
                Text(managementText(status)).foregroundStyle(.green)
            case .skipped(let reason), .failed(let reason):
                Text(reason).foregroundStyle(.orange)
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
        case .distributed: "Imported and enabled"
        case .noDistributionChanges, .alreadyManaged: "Imported"
        case .managedUndistributed: "Imported but not enabled"
        case .managedDistributionIndeterminate, .managementIndeterminate:
            "Imported; status needs attention"
        case .updateRequired: "Update required"
        case .updated: "Updated"
        case .updatedDistributionNeedsAttention, .updateIndeterminate:
            "Updated; status needs attention"
        }
    }

}
