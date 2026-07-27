import SwiftUI

struct ManagedLocalImportPreviewView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(ManagedLocalImportViewModel.self) private var model

    let preview: ManagedLocalImportPreview
    let onConfirm: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Review Import")
                .font(.title.bold())
            Text("The Skill will be added to the managed library before distribution.")
                .foregroundStyle(.secondary)

            if preview.plan.status == .blocked {
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
            Button(preview.plan.status == .blocked ? "Close" : "Cancel") {
                model.cancelPreview()
                dismiss()
            }
            .keyboardShortcut(.cancelAction)
            .disabled(model.isExecuting)

            Spacer()

            if preview.plan.status != .blocked {
                Button {
                    onConfirm()
                } label: {
                    if model.isExecuting {
                        ProgressView()
                    } else {
                        Text("Import")
                    }
                }
                .buttonStyle(.borderedProminent)
                .disabled(model.isExecuting)
                .keyboardShortcut(.defaultAction)
                .accessibilityLabel(
                    model.isExecuting ? "Importing Skill" : "Import Skill"
                )
            }
        }
    }

    private var conflictList: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label(
                "Distribution is blocked. No Skill will be imported until this is resolved.",
                systemImage: "exclamationmark.triangle"
            )
            ForEach(Array(preview.plan.conflicts.enumerated()), id: \.offset) { _, conflict in
                Text("\(conflict.reason.rawValue): \(conflict.canonicalLocator)")
                    .font(.callout.monospaced())
                    .textSelection(.enabled)
            }
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
        }
    }
}
