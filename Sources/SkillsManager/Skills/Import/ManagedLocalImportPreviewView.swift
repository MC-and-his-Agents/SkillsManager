import SwiftUI

struct ManagedLocalImportPreviewView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(ManagedLocalImportViewModel.self) private var model

    let preview: ManagedLocalImportPreview
    let onConfirm: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(verbatim: preview.disposition == .updateRequired
                ? String(localized: "Review Update", bundle: SkillsManagerLocalizationResources.bundle)
                : String(localized: "Review Import", bundle: SkillsManagerLocalizationResources.bundle))
                .font(.title.bold())
            Text(verbatim: preview.disposition == .updateRequired
                ? String(localized: "The current managed content will be backed up before replacement.", bundle: SkillsManagerLocalizationResources.bundle)
                : String(localized: "The Skill will be added to the managed library before distribution.", bundle: SkillsManagerLocalizationResources.bundle))
                .foregroundStyle(.secondary)

            if let source = preview.source {
                sourceDetails(source, slug: preview.distributionSlug)
            }

            if preview.disposition == .alreadyManaged {
                Label {
                    Text(
                        "This Skill is already managed. Change its Agent access from the Skill details.",
                        bundle: SkillsManagerLocalizationResources.bundle
                    )
                } icon: {
                    Image(systemName: "checkmark.circle")
                }
            } else if preview.disposition == .updateRequired {
                Label {
                    Text(
                        "Update the managed SSOT while keeping its Skill identity and current Agent access.",
                        bundle: SkillsManagerLocalizationResources.bundle
                    )
                } icon: {
                    Image(systemName: "arrow.triangle.2.circlepath")
                }
            } else if preview.plan.status == .blocked {
                conflictList
            } else if preview.plan.filesystemActions.isEmpty {
                Label {
                    Text("No distribution file changes are needed.", bundle: SkillsManagerLocalizationResources.bundle)
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
                sourceRow(String(localized: "Repository", bundle: SkillsManagerLocalizationResources.bundle), source.repositoryURL.value)
                sourceRow(String(localized: "Subpath", bundle: SkillsManagerLocalizationResources.bundle), source.subpath.value)
                sourceRow(String(localized: "Revision", bundle: SkillsManagerLocalizationResources.bundle), source.revision.value)
                sourceRow(String(localized: "Target slug", bundle: SkillsManagerLocalizationResources.bundle), slug.value)
                sourceRow(String(localized: "Archive", bundle: SkillsManagerLocalizationResources.bundle), source.downloadURL.value)
                sourceRow(
                    String(localized: "Provider alias", bundle: SkillsManagerLocalizationResources.bundle),
                    "\(source.alias.provider): \(source.alias.identifier)"
                )
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        } label: {
            Text("Verified source", bundle: SkillsManagerLocalizationResources.bundle)
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
                Text(canConfirm ? "Cancel" : "Close", bundle: SkillsManagerLocalizationResources.bundle)
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
                    ? String(localized: "Updating managed Skill state", bundle: SkillsManagerLocalizationResources.bundle)
                    : confirmTitle))
            }
        }
    }

    private var conflictList: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label {
                Text(verbatim: preview.allowsBlockedCreate
                    ? String(localized: "Distribution is blocked. The Skill can still be added to the managed library.", bundle: SkillsManagerLocalizationResources.bundle)
                    : String(localized: "Distribution is blocked. No Skill will be imported until this is resolved.", bundle: SkillsManagerLocalizationResources.bundle))
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
            String(localized: "Done", bundle: SkillsManagerLocalizationResources.bundle)
        case .updateRequired:
            String(localized: "Update", bundle: SkillsManagerLocalizationResources.bundle)
        case .createNew where preview.plan.status == .blocked:
            String(localized: "Add without enabling", bundle: SkillsManagerLocalizationResources.bundle)
        case .createNew:
            String(localized: "Import", bundle: SkillsManagerLocalizationResources.bundle)
        }
    }

    private func actionPresentation(
        _ kind: DistributionFilesystemActionKind
    ) -> (title: String, systemImage: String) {
        switch kind {
        case .createSymlink:
            (String(localized: "Create managed link", bundle: SkillsManagerLocalizationResources.bundle), "link.badge.plus")
        case .removeSymlink:
            (String(localized: "Remove managed link", bundle: SkillsManagerLocalizationResources.bundle), "link.badge.minus")
        case .createCopy:
            (String(localized: "Create managed copy", bundle: SkillsManagerLocalizationResources.bundle), "folder.badge.plus")
        case .refreshCopy, .discardCopyDrift:
            (String(localized: "Refresh managed copy", bundle: SkillsManagerLocalizationResources.bundle), "arrow.triangle.2.circlepath")
        case .removeCopy:
            (String(localized: "Remove managed copy", bundle: SkillsManagerLocalizationResources.bundle), "folder.badge.minus")
        case .replaceSymlinkWithCopy:
            (String(localized: "Replace link with copy", bundle: SkillsManagerLocalizationResources.bundle), "folder")
        case .replaceCopyWithSymlink:
            (String(localized: "Replace copy with link", bundle: SkillsManagerLocalizationResources.bundle), "link")
        }
    }

}
