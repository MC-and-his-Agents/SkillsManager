import SwiftUI

struct CustomRepositorySheet: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(CustomRepositoryViewModel.self) private var model

    @State private var repositoryURL = ""
    @State private var requestedRef = ""
    @State private var pendingRemoval: CustomRepositoryCatalogRecord?

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            header
            addForm
            Divider()
            repositoryList
            if let message = model.runtimeBlockMessage ?? model.operationProblem?.message {
                Label(message, systemImage: "exclamationmark.triangle")
                    .foregroundStyle(.orange)
                    .accessibilityElement(children: .combine)
            }
            HStack {
                Button {
                    Task { await model.refreshAll() }
                } label: {
                    Text("Refresh All", bundle: SkillsManagerLocalizationResources.bundle)
                }
                    .disabled(model.repositories.isEmpty || model.isRefreshing || model.isMutating)
                    .accessibilityIdentifier("repository.refresh-all")
                Spacer()
                Button {
                    dismiss()
                } label: {
                    Text("Done", bundle: SkillsManagerLocalizationResources.bundle)
                }
                    .keyboardShortcut(.defaultAction)
                    .accessibilityIdentifier("repository.done")
            }
        }
        .padding(20)
        .frame(minWidth: 680, minHeight: 500)
        .confirmationDialog(
            Text("Remove this discovery source?", bundle: SkillsManagerLocalizationResources.bundle),
            isPresented: Binding(
                get: { pendingRemoval != nil },
                set: { if !$0 { pendingRemoval = nil } }
            ),
            presenting: pendingRemoval
        ) { record in
            Button(role: .destructive) {
                Task {
                    if await model.remove(record) { pendingRemoval = nil }
                }
            } label: {
                Text("Remove Repository", bundle: SkillsManagerLocalizationResources.bundle)
            }
            Button(role: .cancel) {
                pendingRemoval = nil
            } label: {
                Text("Cancel", bundle: SkillsManagerLocalizationResources.bundle)
            }
        } message: { _ in
            Text("This removes only the discovery source. Installed Skills are not deleted.", bundle: SkillsManagerLocalizationResources.bundle)
        }
        .interactiveDismissDisabled(model.isMutating)
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("GitHub Repositories", bundle: SkillsManagerLocalizationResources.bundle).font(.title.bold())
            Text("Discover Skills from public GitHub repositories.", bundle: SkillsManagerLocalizationResources.bundle)
                .foregroundStyle(.secondary)
        }
    }

    private var addForm: some View {
        Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 10) {
            GridRow {
                Text("Repository", bundle: SkillsManagerLocalizationResources.bundle)
                TextField("https://github.com/owner/repository", text: $repositoryURL)
                    .textFieldStyle(.roundedBorder)
                    .accessibilityLabel(Text("GitHub repository URL", bundle: SkillsManagerLocalizationResources.bundle))
            }
            GridRow {
                Text("Ref", bundle: SkillsManagerLocalizationResources.bundle)
                TextField("Default branch", text: $requestedRef)
                    .textFieldStyle(.roundedBorder)
                    .accessibilityLabel(Text(
                        "Optional Git branch, tag, or commit reference",
                        bundle: SkillsManagerLocalizationResources.bundle
                    ))
            }
            GridRow {
                Color.clear.frame(width: 1, height: 1)
                HStack {
                    Spacer()
                    Button {
                        let url = repositoryURL
                        let ref = requestedRef
                        Task {
                            await model.add(repositoryURL: url, requestedRef: ref)
                            guard model.operationProblem == nil else { return }
                            repositoryURL = ""
                            requestedRef = ""
                        }
                    } label: {
                        Text("Add Repository", bundle: SkillsManagerLocalizationResources.bundle)
                    }
                    .buttonStyle(.borderedProminent)
                    .accessibilityIdentifier("repository.add")
                    .disabled(repositoryURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                        || model.isMutating)
                }
            }
        }
    }

    @ViewBuilder
    private var repositoryList: some View {
        if model.repositories.isEmpty {
            ContentUnavailableView(
                String(localized: "No GitHub repositories", bundle: SkillsManagerLocalizationResources.bundle),
                systemImage: "shippingbox",
                description: Text("Add a public repository to discover its Skills.", bundle: SkillsManagerLocalizationResources.bundle)
            )
            .frame(maxHeight: .infinity)
        } else {
            List(model.repositories, id: \.repositoryID) { record in
                repositoryRow(record)
            }
            .frame(maxHeight: .infinity)
        }
    }

    private func repositoryRow(_ record: CustomRepositoryCatalogRecord) -> some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                Text(verbatim: record.displayName).font(.headline)
                Text(verbatim: record.repositoryURL.value)
                    .font(.caption.monospaced())
                    .foregroundStyle(.secondary)
                Text(verbatim: refLabel(record.requestedRef))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Label {
                    Text(record.enabled ? "Enabled" : "Disabled", bundle: SkillsManagerLocalizationResources.bundle)
                } icon: {
                    Image(systemName: record.enabled
                        ? "checkmark.circle" : "pause.circle")
                }
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            repositoryState(model.state(for: record.repositoryID))
            Button {
                Task { await model.refresh(repositoryID: record.repositoryID) }
            } label: {
                Image(systemName: "arrow.clockwise")
            }
            .buttonStyle(.borderless)
            .disabled(model.state(for: record.repositoryID) == .loading || model.isMutating)
            .help(Text("Refresh repository", bundle: SkillsManagerLocalizationResources.bundle))
            .accessibilityLabel(Text(
                String(
                    localized: LocalizedStringResource(
            "Refresh \(record.displayName)",
            bundle: SkillsManagerLocalizationResources.bundle
        ))
            ))
            Button(role: .destructive) {
                pendingRemoval = record
            } label: {
                Image(systemName: "trash")
            }
            .buttonStyle(.borderless)
            .disabled(model.isMutating)
            .help(Text("Remove repository", bundle: SkillsManagerLocalizationResources.bundle))
            .accessibilityLabel(Text(
                String(
                    localized: LocalizedStringResource(
            "Remove \(record.displayName)",
            bundle: SkillsManagerLocalizationResources.bundle
        ))
            ))
        }
        .padding(.vertical, 4)
        .accessibilityElement(children: .contain)
    }

    @ViewBuilder
    private func repositoryState(
        _ state: CustomRepositoryViewModel.RepositoryState
    ) -> some View {
        switch state {
        case .idle:
            Label {
                Text("Not refreshed", bundle: SkillsManagerLocalizationResources.bundle)
            } icon: {
                Image(systemName: "circle.dashed")
            }
        case .loading:
            ProgressView().controlSize(.small)
                .accessibilityLabel(Text("Refreshing", bundle: SkillsManagerLocalizationResources.bundle))
        case .loaded(let count):
            Label {
                Text(String(
                    localized: LocalizedStringResource(
            "\(count) Skills",
            bundle: SkillsManagerLocalizationResources.bundle
        )))
            } icon: {
                Image(systemName: "checkmark.circle")
            }
        case .empty:
            Label {
                Text("No Skills", bundle: SkillsManagerLocalizationResources.bundle)
            } icon: {
                Image(systemName: "tray")
            }
        case .failed(let problem):
            Label {
                Text("Failed", bundle: SkillsManagerLocalizationResources.bundle)
            } icon: {
                Image(systemName: "exclamationmark.triangle")
            }
                .help(Text(verbatim: problem.message))
                .accessibilityValue(Text(verbatim: problem.message))
        }
    }

    private func refLabel(_ ref: CustomRepositoryRef) -> String {
        switch ref {
        case .defaultBranch: "Default branch"
        case .explicit(let value): "Ref: \(value)"
        }
    }

}
