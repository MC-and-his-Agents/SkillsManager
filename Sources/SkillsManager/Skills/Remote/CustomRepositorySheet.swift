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
                Button("Refresh All") { Task { await model.refreshAll() } }
                    .disabled(model.repositories.isEmpty || model.isRefreshing || model.isMutating)
                Spacer()
                Button("Done") { dismiss() }
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(minWidth: 680, minHeight: 500)
        .confirmationDialog(
            "Remove this discovery source?",
            isPresented: Binding(
                get: { pendingRemoval != nil },
                set: { if !$0 { pendingRemoval = nil } }
            ),
            presenting: pendingRemoval
        ) { record in
            Button("Remove Repository", role: .destructive) {
                Task {
                    if await model.remove(record) { pendingRemoval = nil }
                }
            }
            Button("Cancel", role: .cancel) { pendingRemoval = nil }
        } message: { _ in
            Text("This removes only the discovery source. Installed Skills are not deleted.")
        }
        .interactiveDismissDisabled(model.isMutating)
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("GitHub Repositories").font(.title.bold())
            Text("Discover Skills from public GitHub repositories.")
                .foregroundStyle(.secondary)
        }
    }

    private var addForm: some View {
        Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 10) {
            GridRow {
                Text("Repository")
                TextField("https://github.com/owner/repository", text: $repositoryURL)
                    .textFieldStyle(.roundedBorder)
                    .accessibilityLabel("GitHub repository URL")
            }
            GridRow {
                Text("Ref")
                TextField("Default branch", text: $requestedRef)
                    .textFieldStyle(.roundedBorder)
                    .accessibilityLabel("Optional Git branch, tag, or commit reference")
            }
            GridRow {
                Color.clear.frame(width: 1, height: 1)
                HStack {
                    Spacer()
                    Button("Add Repository") {
                        let url = repositoryURL
                        let ref = requestedRef
                        Task {
                            await model.add(repositoryURL: url, requestedRef: ref)
                            guard model.operationProblem == nil else { return }
                            repositoryURL = ""
                            requestedRef = ""
                        }
                    }
                    .buttonStyle(.borderedProminent)
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
                "No GitHub repositories",
                systemImage: "shippingbox",
                description: Text("Add a public repository to discover its Skills.")
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
                Label(record.enabled ? "Enabled" : "Disabled", systemImage: record.enabled
                    ? "checkmark.circle" : "pause.circle")
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
            .help("Refresh repository")
            .accessibilityLabel("Refresh \(record.displayName)")
            Button(role: .destructive) {
                pendingRemoval = record
            } label: {
                Image(systemName: "trash")
            }
            .buttonStyle(.borderless)
            .disabled(model.isMutating)
            .help("Remove repository")
            .accessibilityLabel("Remove \(record.displayName)")
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
            Label("Not refreshed", systemImage: "circle.dashed")
        case .loading:
            ProgressView().controlSize(.small).accessibilityLabel("Refreshing")
        case .loaded(let count):
            Label("\(count) Skills", systemImage: "checkmark.circle")
        case .empty:
            Label("No Skills", systemImage: "tray")
        case .failed(let problem):
            Label("Failed", systemImage: "exclamationmark.triangle")
                .help(problem.message)
                .accessibilityValue(problem.message)
        }
    }

    private func refLabel(_ ref: CustomRepositoryRef) -> String {
        switch ref {
        case .defaultBranch: "Default branch"
        case .explicit(let value): "Ref: \(value)"
        }
    }
}
