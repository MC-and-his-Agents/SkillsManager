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

            experimentalNotice

            Section("Search Results") {
                searchContent
            }
        }
        .listStyle(.sidebar)
    }

    private var experimentalNotice: some View {
        Label {
            Text(
                "Experimental source. Search terms are sent to skills.sh using an "
                    + "undocumented public interface that may become unavailable."
            )
            .font(.caption)
        } icon: {
            Image(systemName: "exclamationmark.triangle")
        }
        .foregroundStyle(.secondary)
        .accessibilityElement(children: .combine)
    }

    @ViewBuilder
    private var searchContent: some View {
        let trimmed = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty || store.searchState == .idle {
            Text("Search skills.sh to discover experimental results.")
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
                .accessibilityHint("Loads the next page of experimental skills.sh results")
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

    var body: some View {
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
                            "Temporarily unavailable for installation. The repository path "
                                + "and immutable revision have not been verified yet."
                        )
                    } icon: {
                        Image(systemName: "lock.shield")
                    }
                    .foregroundStyle(.secondary)
                    .accessibilityElement(children: .combine)

                    Label {
                        Text(
                            "Experimental source: this undocumented skills.sh interface "
                                + "may become unavailable."
                        )
                    } icon: {
                        Image(systemName: "exclamationmark.triangle")
                    }
                    .foregroundStyle(.secondary)
                    .accessibilityElement(children: .combine)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding()
            }
            .navigationTitle(item.name)
            .navigationSubtitle("skills.sh · Experimental")
        } else {
            ContentUnavailableView(
                "Select a skill",
                systemImage: "magnifyingglass",
                description: Text(
                    "Choose an experimental skills.sh result. Installation is not available yet."
                )
            )
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
            Text("\(item.installs.formatted()) installs · Not installable yet")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(.vertical, 6)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(
            "\(item.name), \(item.installs.formatted()) installs, source \(item.source), "
                + "temporarily unavailable for installation"
        )
    }
}

private extension SkillsShSearchItem {
    var resultID: SkillsShSearchResultID {
        SkillsShSearchResultID(self)
    }
}
