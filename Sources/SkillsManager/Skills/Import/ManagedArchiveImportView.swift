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
            ContentUnavailableView("Choose a ZIP archive", systemImage: "archivebox")
        case .selecting:
            selection
        case .preparing:
            ProgressView("Preparing previews…")
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
                Button("Select safe") { model.selectAllSafe() }
                    .disabled(model.availableCandidateCount == 0)
                    .accessibilityIdentifier("archive.select-safe")
                Button("Clear") { model.clearSelection() }
                    .disabled(model.selectedCount == 0)
                    .accessibilityIdentifier("archive.clear-selection")
                Spacer()
                Text("\(model.selectedCount) selected")
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
                Button("Review selected…") {
                    onPrepare(requestedScope)
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
                        Text("Slug: \(slug.value)")
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
            Label(
                "Nothing has been written. Confirm once to import the selected Skills in order.",
                systemImage: "eye"
            )
            .foregroundStyle(.secondary)
            List(model.previewItems) { item in
                VStack(alignment: .leading, spacing: 3) {
                    Text(item.candidate.displayName).font(.headline)
                    Text(item.candidate.canonicalSubpath.isEmpty ? "." : item.candidate.canonicalSubpath)
                        .font(.caption.monospaced())
                        .foregroundStyle(.secondary)
                    if let slug = item.preview?.distributionSlug {
                        Text("Slug: \(slug.value)")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    if let reason = item.reason {
                        Label(reason, systemImage: "xmark.circle")
                            .font(.caption)
                            .foregroundStyle(.orange)
                    }
                    if let preview = item.preview,
                       preview.plan.status == .blocked {
                        Label(
                            "Distribution is blocked. This Skill will be added without enabling.",
                            systemImage: "exclamationmark.triangle"
                        )
                        .font(.caption)
                        .foregroundStyle(.orange)
                        ForEach(
                            Array(preview.plan.conflicts.enumerated()),
                            id: \.offset
                        ) { _, conflict in
                            Text("\(conflict.reason.displayName): \(conflict.canonicalLocator)")
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
                Button("Back") { model.cancelPreview() }
                Spacer()
                Button(
                    model.hasBlockedDistribution
                        ? "Add selected to library"
                        : "Import selected"
                ) {
                    onConfirm()
                }
                .buttonStyle(.borderedProminent)
                .disabled(!model.canConfirm)
                .accessibilityIdentifier("archive.confirm")
            }
        }
    }

    private var execution: some View {
        VStack(alignment: .leading, spacing: 8) {
            ProgressView("Importing selected Skills…")
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
