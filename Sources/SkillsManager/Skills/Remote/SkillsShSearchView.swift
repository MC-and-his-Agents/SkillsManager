import SwiftUI

struct SkillsShSearchSidebarView: View {
    @Environment(SkillsShSearchStore.self) private var store

    let searchText: String
    let onRetrySearch: () -> Void
    let onLoadMore: () -> Void
    @Binding var source: SkillSource

    var body: some View {
        @Bindable var store = store
        List(selection: $store.selectedResultID) {
            SidebarHeaderView(
                skillCount: store.items.count,
                source: $source
            )
            .listRowInsets(EdgeInsets(top: 4, leading: 0, bottom: 8, trailing: 0))
            .listRowSeparator(.hidden)
            .listRowBackground(Color.clear)

            Section("Search Results") {
                searchContent
            }
        }
        .listStyle(.sidebar)
    }

    @ViewBuilder
    private var searchContent: some View {
        let trimmed = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty || store.searchState == .idle {
            Text("Search skills.sh to discover Skills.")
                .foregroundStyle(.secondary)
                .padding(.vertical, 8)
        } else {
            switch store.searchState {
            case .idle:
                EmptyView()
            case .loading:
                progressRow("Searching skills.sh")
            case .failed(let problem):
                failureView(problem, retryTitle: "Retry", action: onRetrySearch)
            case .loaded:
                if store.items.isEmpty {
                    Text("No skills found.")
                        .foregroundStyle(.secondary)
                        .padding(.vertical, 8)
                } else {
                    ForEach(store.items, id: \.resultID) { item in
                        SkillsShSearchRow(item: item)
                            .tag(SkillsShSearchResultID(item))
                    }
                    paginationContent
                }
            }
        }
    }

    @ViewBuilder
    private var paginationContent: some View {
        switch store.paginationState {
        case .idle:
            EmptyView()
        case .loading:
            progressRow("Loading more skills.sh results")
        case .canLoadMore:
            Button("Load More", action: onLoadMore)
                .frame(maxWidth: .infinity)
                .accessibilityHint("Loads more skills.sh results")
        case .finished:
            Text("No more unique results.")
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 6)
        case .failed(let problem):
            failureView(problem, retryTitle: "Retry Page", action: onLoadMore)
        }
    }

    private func progressRow(_ label: String) -> some View {
        HStack(spacing: 8) {
            ProgressView()
            Text(label)
                .foregroundStyle(.secondary)
        }
        .padding(.vertical, 8)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(label)
    }

    private func failureView(
        _ problem: SkillsShSearchStore.Problem,
        retryTitle: String,
        action: @escaping () -> Void
    ) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(problem == .invalidRequest ? "Invalid search" : "skills.sh unavailable")
                .font(.headline)
            Text(problem.message)
                .foregroundStyle(.secondary)
            Button(retryTitle, action: action)
        }
        .padding(.vertical, 8)
    }
}

struct SkillsShSearchDetailView: View {
    @Environment(SkillsShSearchStore.self) private var store
    @State private var installItem: SkillsShSearchItem?

    var body: some View {
        Group {
            if let item = store.selectedItem {
                ScrollView {
                    VStack(alignment: .leading, spacing: 16) {
                        Text(item.name)
                            .font(.largeTitle.bold())

                        HStack(spacing: 6) {
                            TagView(text: item.source)
                            TagView(text: "\(item.installs.formatted()) installs")
                        }

                        Label {
                            Text(
                                "Before installation, Skills Manager verifies a unique "
                                    + "repository subpath and immutable GitHub revision."
                            )
                        } icon: {
                            Image(systemName: "lock.shield")
                        }
                        .foregroundStyle(.secondary)
                        .accessibilityElement(children: .combine)

                        Button("Resolve and Install…") {
                            installItem = item
                        }
                        .buttonStyle(.borderedProminent)
                        .accessibilityHint(
                            "Verifies the public GitHub source before showing an install preview"
                        )
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding()
                }
                .navigationTitle(item.name)
                .navigationSubtitle("skills.sh")
            } else {
                ContentUnavailableView(
                    "Select a skill",
                    systemImage: "magnifyingglass",
                    description: Text("Choose a skills.sh result.")
                )
            }
        }
        .sheet(
            isPresented: Binding(
                get: { installItem != nil },
                set: { if !$0 { installItem = nil } }
            )
        ) {
            if let installItem {
                ManagedSkillsShInstallView(item: installItem)
            }
        }
    }
}

private struct SkillsShSearchRow: View {
    let item: SkillsShSearchItem

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(item.name)
                .font(.headline)
            Text(item.source)
                .font(.subheadline)
                .foregroundStyle(.secondary)
            Text("\(item.installs.formatted()) installs")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(.vertical, 6)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(
            "\(item.name), \(item.installs.formatted()) installs, source \(item.source)"
        )
    }
}

private extension SkillsShSearchItem {
    var resultID: SkillsShSearchResultID {
        SkillsShSearchResultID(self)
    }
}
