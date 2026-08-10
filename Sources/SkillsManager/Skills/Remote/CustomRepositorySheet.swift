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
            if let problem = model.operationProblem {
                Label(problem.message, systemImage: "exclamationmark.triangle")
                    .foregroundStyle(.orange)
                    .accessibilityElement(children: .combine)
            }
            HStack {
                Button {
                    Task { await model.refreshAll() }
                } label: {
                    Text("Refresh All", bundle: .module)
                }
                    .disabled(model.repositories.isEmpty || model.isRefreshing || model.isMutating)
                    .accessibilityIdentifier("repository.refresh-all")
                Spacer()
                Button {
                    dismiss()
                } label: {
                    Text("Done", bundle: .module)
                }
                    .keyboardShortcut(.defaultAction)
                    .accessibilityIdentifier("repository.done")
            }
        }
        .padding(20)
        .frame(minWidth: 680, minHeight: 500)
        .confirmationDialog(
            Text("Remove this discovery source?", bundle: .module),
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
                Text("Remove Repository", bundle: .module)
            }
            Button(role: .cancel) {
                pendingRemoval = nil
            } label: {
                Text("Cancel", bundle: .module)
            }
        } message: { _ in
            Text("This removes only the discovery source. Installed Skills are not deleted.", bundle: .module)
        }
        .interactiveDismissDisabled(model.isMutating)
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("GitHub Repositories", bundle: .module).font(.title.bold())
            Text("Discover Skills from public GitHub repositories.", bundle: .module)
                .foregroundStyle(.secondary)
        }
    }

    private var addForm: some View {
        Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 10) {
            GridRow {
                Text("Repository", bundle: .module)
                TextField("https://github.com/owner/repository", text: $repositoryURL)
                    .textFieldStyle(.roundedBorder)
                    .accessibilityLabel(Text("GitHub repository URL", bundle: .module))
            }
            GridRow {
                Text("Ref", bundle: .module)
                TextField("Default branch", text: $requestedRef)
                    .textFieldStyle(.roundedBorder)
                    .accessibilityLabel(Text(
                        "Optional Git branch, tag, or commit reference",
                        bundle: .module
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
                        Text("Add Repository", bundle: .module)
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
                localized("No GitHub repositories"),
                systemImage: "shippingbox",
                description: Text("Add a public repository to discover its Skills.", bundle: .module)
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
                Text(record.displayName).font(.headline)
                Text(record.repositoryURL.value)
                    .font(.caption.monospaced())
                    .foregroundStyle(.secondary)
                Text(refLabel(record.requestedRef))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Label {
                    Text(record.enabled ? "Enabled" : "Disabled", bundle: .module)
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
            .help(Text("Refresh repository", bundle: .module))
            .accessibilityLabel(Text("Refresh \(record.displayName)", bundle: .module))
            Button(role: .destructive) {
                pendingRemoval = record
            } label: {
                Image(systemName: "trash")
            }
            .buttonStyle(.borderless)
            .disabled(model.isMutating)
            .help(Text("Remove repository", bundle: .module))
            .accessibilityLabel(Text("Remove \(record.displayName)", bundle: .module))
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
                Text("Not refreshed", bundle: .module)
            } icon: {
                Image(systemName: "circle.dashed")
            }
        case .loading:
            ProgressView().controlSize(.small)
                .accessibilityLabel(Text("Refreshing", bundle: .module))
        case .loaded(let count):
            Label {
                Text("\(count) Skills", bundle: .module)
            } icon: {
                Image(systemName: "checkmark.circle")
            }
        case .empty:
            Label {
                Text("No Skills", bundle: .module)
            } icon: {
                Image(systemName: "tray")
            }
        case .failed(let problem):
            Label {
                Text("Failed", bundle: .module)
            } icon: {
                Image(systemName: "exclamationmark.triangle")
            }
                .help(Text(problem.message))
                .accessibilityValue(Text(problem.message))
        }
    }

    private func refLabel(_ ref: CustomRepositoryRef) -> String {
        switch ref {
        case .defaultBranch: "Default branch"
        case .explicit(let value): "Ref: \(value)"
        }
    }

    private func localized(_ value: String) -> String {
        String(localized: String.LocalizationValue(value), bundle: .module)
    }
}
