import SwiftUI

struct ManagedLocalImportPreviewView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(ManagedLocalImportViewModel.self) private var model

    let preview: ManagedLocalImportPreview
    let onConfirm: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(preview.disposition == .updateRequired ? "Review Update" : "Review Import")
                .font(.title.bold())
            Text(preview.disposition == .updateRequired
                ? "The current managed content will be backed up before replacement."
                : "The Skill will be added to the managed library before distribution.")
                .foregroundStyle(.secondary)

            if let source = preview.source {
                sourceDetails(source)
            }

            if preview.disposition == .alreadyManaged {
                Label(
                    "This Skill is already managed. Change its Agent access from the Skill details.",
                    systemImage: "checkmark.circle"
                )
            } else if preview.disposition == .updateRequired {
                Label(
                    "Update the managed SSOT while keeping its Skill identity and current Agent access.",
                    systemImage: "arrow.triangle.2.circlepath"
                )
            } else if preview.plan.status == .blocked {
                conflictList
            } else if preview.plan.filesystemActions.isEmpty {
                Label("No distribution file changes are needed.", systemImage: "checkmark.circle")
            } else {
                actionList
            }

            if let problem = model.problem {
                Label(problem.localizedDescription, systemImage: "exclamationmark.triangle")
                    .foregroundStyle(.orange)
            }

            Spacer()
            actions
        }
        .padding(20)
        .frame(minWidth: 560, minHeight: 380)
        .interactiveDismissDisabled(model.isExecuting)
        .onChange(of: model.result?.status) { _, result in
            if result != nil {
                dismiss()
            }
        }
    }

    private func sourceDetails(_ source: ManagedInstallSourcePreview) -> some View {
        GroupBox("Verified source") {
            Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 6) {
                sourceRow("Repository", source.repositoryURL.value)
                sourceRow("Subpath", source.subpath.value)
                sourceRow("Revision", source.revision.value)
                sourceRow("Archive", source.downloadURL.value)
                sourceRow(
                    "Provider alias",
                    "\(source.alias.provider): \(source.alias.identifier)"
                )
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    @ViewBuilder
    private func sourceRow(_ title: String, _ value: String) -> some View {
        GridRow {
            Text(title)
                .foregroundStyle(.secondary)
            Text(value)
                .font(.callout.monospaced())
                .textSelection(.enabled)
        }
        .accessibilityElement(children: .combine)
    }

    private var actionList: some View {
        List(preview.plan.filesystemActions, id: \.entry.canonicalLocator) { action in
            VStack(alignment: .leading, spacing: 3) {
                let presentation = actionPresentation(action.kind)
                Label(presentation.title, systemImage: presentation.systemImage)
                Text(action.entry.canonicalLocator)
                    .font(.callout.monospaced())
                    .textSelection(.enabled)
            }
            .accessibilityElement(children: .combine)
        }
    }

    private var actions: some View {
        HStack {
            Button(canConfirm ? "Cancel" : "Close") {
                model.cancelPreview()
                dismiss()
            }
            .keyboardShortcut(.cancelAction)
            .disabled(model.isExecuting)

            Spacer()

            if canConfirm {
                Button {
                    onConfirm()
                } label: {
                    if model.isExecuting {
                        ProgressView()
                    } else {
                        Text(confirmTitle)
                    }
                }
                .buttonStyle(.borderedProminent)
                .disabled(model.isExecuting)
                .keyboardShortcut(.defaultAction)
                .accessibilityLabel(
                    model.isExecuting ? "Updating managed Skill state" : confirmTitle
                )
            }
        }
    }

    private var conflictList: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label(
                preview.allowsBlockedCreate
                    ? "Distribution is blocked. The Skill can still be added to the managed library."
                    : "Distribution is blocked. No Skill will be imported until this is resolved.",
                systemImage: "exclamationmark.triangle"
            )
            ForEach(Array(preview.plan.conflicts.enumerated()), id: \.offset) { _, conflict in
                Text("\(conflict.reason.rawValue): \(conflict.canonicalLocator)")
                    .font(.callout.monospaced())
                    .textSelection(.enabled)
            }
        }
    }

    private var canConfirm: Bool {
        preview.disposition != .createNew
            || preview.plan.status != .blocked
            || preview.allowsBlockedCreate
    }

    private var confirmTitle: String {
        switch preview.disposition {
        case .alreadyManaged:
            "Done"
        case .updateRequired:
            "Update"
        case .createNew where preview.plan.status == .blocked:
            "Add without enabling"
        case .createNew:
            "Import"
        }
    }

    private func actionPresentation(
        _ kind: DistributionFilesystemActionKind
    ) -> (title: String, systemImage: String) {
        switch kind {
        case .createSymlink:
            ("Create managed link", "link.badge.plus")
        case .removeSymlink:
            ("Remove managed link", "link.badge.minus")
        case .createCopy:
            ("Create managed copy", "folder.badge.plus")
        case .refreshCopy, .discardCopyDrift:
            ("Refresh managed copy", "arrow.triangle.2.circlepath")
        case .removeCopy:
            ("Remove managed copy", "folder.badge.minus")
        case .replaceSymlinkWithCopy:
            ("Replace link with copy", "folder")
        case .replaceCopyWithSymlink:
            ("Replace copy with link", "link")
        }
    }
}
