import SwiftUI

struct ManagedLocalImportPreviewView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(ManagedLocalImportViewModel.self) private var model

    let preview: ManagedLocalImportPreview
    let onConfirm: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(verbatim: preview.disposition == .updateRequired
                ? String(localized: "Review Update", bundle: .module)
                : String(localized: "Review Import", bundle: .module))
                .font(.title.bold())
            Text(verbatim: preview.disposition == .updateRequired
                ? String(localized: "The current managed content will be backed up before replacement.", bundle: .module)
                : String(localized: "The Skill will be added to the managed library before distribution.", bundle: .module))
                .foregroundStyle(.secondary)

            if let source = preview.source {
                sourceDetails(source, slug: preview.distributionSlug)
            }

            if preview.disposition == .alreadyManaged {
                Label {
                    Text(
                        "This Skill is already managed. Change its Agent access from the Skill details.",
                        bundle: .module
                    )
                } icon: {
                    Image(systemName: "checkmark.circle")
                }
            } else if preview.disposition == .updateRequired {
                Label {
                    Text(
                        "Update the managed SSOT while keeping its Skill identity and current Agent access.",
                        bundle: .module
                    )
                } icon: {
                    Image(systemName: "arrow.triangle.2.circlepath")
                }
            } else if preview.plan.status == .blocked {
                conflictList
            } else if preview.plan.filesystemActions.isEmpty {
                Label {
                    Text("No distribution file changes are needed.", bundle: .module)
                } icon: {
                    Image(systemName: "checkmark.circle")
                }
            } else {
                actionList
            }

            if let problem = model.problem {
                Label(localizedManagedLocalImportProblem(problem), systemImage: "exclamationmark.triangle")
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

    private func sourceDetails(
        _ source: ManagedInstallSourcePreview,
        slug: DefaultDistributionSlug
    ) -> some View {
        GroupBox {
            Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 6) {
                sourceRow(String(localized: "Repository", bundle: .module), source.repositoryURL.value)
                sourceRow(String(localized: "Subpath", bundle: .module), source.subpath.value)
                sourceRow(String(localized: "Revision", bundle: .module), source.revision.value)
                sourceRow(String(localized: "Target slug", bundle: .module), slug.value)
                sourceRow(String(localized: "Archive", bundle: .module), source.downloadURL.value)
                sourceRow(
                    String(localized: "Provider alias", bundle: .module),
                    "\(source.alias.provider): \(source.alias.identifier)"
                )
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        } label: {
            Text("Verified source", bundle: .module)
        }
    }

    @ViewBuilder
    private func sourceRow(_ title: String, _ value: String) -> some View {
        GridRow {
            Text(verbatim: title)
                .foregroundStyle(.secondary)
            Text(verbatim: value)
                .font(.callout.monospaced())
                .textSelection(.enabled)
        }
        .accessibilityElement(children: .combine)
    }

    private var actionList: some View {
        List(preview.plan.filesystemActions, id: \.entry.canonicalLocator) { action in
            VStack(alignment: .leading, spacing: 3) {
                let presentation = actionPresentation(action.kind)
                Label {
                    Text(verbatim: presentation.title)
                } icon: {
                    Image(systemName: presentation.systemImage)
                }
                Text(action.entry.canonicalLocator)
                    .font(.callout.monospaced())
                    .textSelection(.enabled)
            }
            .accessibilityElement(children: .combine)
        }
    }

    private var actions: some View {
        HStack {
            Button {
                model.cancelPreview()
                dismiss()
            } label: {
                Text(canConfirm ? "Cancel" : "Close", bundle: .module)
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
                        Text(verbatim: confirmTitle)
                    }
                }
                .buttonStyle(.borderedProminent)
                .disabled(model.isExecuting)
                .keyboardShortcut(.defaultAction)
                .accessibilityLabel(Text(verbatim: model.isExecuting
                    ? String(localized: "Updating managed Skill state", bundle: .module)
                    : confirmTitle))
            }
        }
    }

    private var conflictList: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label {
                Text(verbatim: preview.allowsBlockedCreate
                    ? String(localized: "Distribution is blocked. The Skill can still be added to the managed library.", bundle: .module)
                    : String(localized: "Distribution is blocked. No Skill will be imported until this is resolved.", bundle: .module))
            } icon: {
                Image(systemName: "exclamationmark.triangle")
            }
            ForEach(Array(preview.plan.conflicts.enumerated()), id: \.offset) { _, conflict in
                Text(verbatim: "\(conflict.reason.localizedDisplayName): \(conflict.canonicalLocator)")
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
            String(localized: "Done", bundle: .module)
        case .updateRequired:
            String(localized: "Update", bundle: .module)
        case .createNew where preview.plan.status == .blocked:
            String(localized: "Add without enabling", bundle: .module)
        case .createNew:
            String(localized: "Import", bundle: .module)
        }
    }

    private func actionPresentation(
        _ kind: DistributionFilesystemActionKind
    ) -> (title: String, systemImage: String) {
        switch kind {
        case .createSymlink:
            (String(localized: "Create managed link", bundle: .module), "link.badge.plus")
        case .removeSymlink:
            (String(localized: "Remove managed link", bundle: .module), "link.badge.minus")
        case .createCopy:
            (String(localized: "Create managed copy", bundle: .module), "folder.badge.plus")
        case .refreshCopy, .discardCopyDrift:
            (String(localized: "Refresh managed copy", bundle: .module), "arrow.triangle.2.circlepath")
        case .removeCopy:
            (String(localized: "Remove managed copy", bundle: .module), "folder.badge.minus")
        case .replaceSymlinkWithCopy:
            (String(localized: "Replace link with copy", bundle: .module), "folder")
        case .replaceCopyWithSymlink:
            (String(localized: "Replace copy with link", bundle: .module), "link")
        }
    }

}
