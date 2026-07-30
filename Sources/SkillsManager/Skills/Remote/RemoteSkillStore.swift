import Foundation
import Observation

@MainActor
@Observable final class RemoteSkillStore {
    enum LoadState: Equatable {
        case idle
        case loading
        case loaded
        case failed(String)
    }

    enum DetailState: Equatable {
        case idle
        case loading
        case loaded
        case cachedRefreshing
        case cachedUnavailable
        case failed(String)
    }

    enum PaginationState: Equatable {
        case idle
        case loading
        case canLoadMore
        case finished
        case failed(String)
    }

    var latestSkills: [RemoteSkill] = []
    var searchResults: [RemoteSkill] = []
    var latestState: LoadState = .idle
    var searchState: LoadState = .idle
    var latestPaginationState: PaginationState = .idle
    var searchPaginationState: PaginationState = .idle
    var selectedSkillID: RemoteSkill.ID?
    var detailMarkdown: String = ""
    var detailState: DetailState = .idle
    var detailOwner: RemoteSkillOwner?

    private let apiClient: RemoteSkillClient
    private let fileWorker = SkillFileWorker()
    private let detailCache = RemoteSkillDetailCache.shared
    private var latestGeneration = 0
    private var latestCursor: String?
    private var activeLatestPageGeneration: Int?
    private var activeSearchToken = 0
    private var activeSearchQuery = ""
    private var currentSearchLimit = 0
    private var activeSearchPageToken: Int?

    private static let searchPageSize = 20
    private static let maximumSearchLimit = 50

    init(client: RemoteSkillClient) {
        self.apiClient = client
    }

    var client: RemoteSkillClient {
        apiClient
    }

    var selectedSkill: RemoteSkill? {
        (searchResults + latestSkills).first { $0.id == selectedSkillID }
    }

    func loadLatest(limit: Int = 12) async {
        latestGeneration += 1
        let generation = latestGeneration
        latestState = .loading
        latestPaginationState = .idle
        latestCursor = nil
        do {
            let page = try await apiClient.fetchLatest(limit, nil)
            guard generation == latestGeneration else { return }
            latestSkills = Self.merged([], with: page.items).items
            latestCursor = page.nextCursor
            latestState = .loaded
            latestPaginationState = page.nextCursor == nil ? .finished : .canLoadMore
        } catch is CancellationError {
            guard generation == latestGeneration else { return }
            latestState = .idle
            latestPaginationState = .idle
        } catch {
            guard generation == latestGeneration else { return }
            latestState = .failed(error.localizedDescription)
        }
    }

    func loadMoreLatest(limit: Int = 12) async {
        guard latestState == .loaded,
              latestPaginationState == .canLoadMore || isLatestPaginationRetry,
              activeLatestPageGeneration != latestGeneration,
              let cursor = latestCursor else {
            return
        }
        let generation = latestGeneration
        activeLatestPageGeneration = generation
        latestPaginationState = .loading
        defer {
            if activeLatestPageGeneration == generation {
                activeLatestPageGeneration = nil
            }
        }

        do {
            let page = try await apiClient.fetchLatest(limit, cursor)
            guard generation == latestGeneration else { return }
            latestSkills = Self.merged(latestSkills, with: page.items).items
            latestCursor = page.nextCursor
            latestPaginationState = page.nextCursor == nil ? .finished : .canLoadMore
        } catch is CancellationError {
            guard generation == latestGeneration else { return }
            latestPaginationState = .canLoadMore
        } catch {
            guard generation == latestGeneration else { return }
            latestPaginationState = .failed(error.localizedDescription)
        }
    }

    func search(query: String, limit: Int = 20) async {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        let previousResultIDs = Set(searchResults.map(\.id))
        activeSearchQuery = trimmed
        activeSearchToken += 1
        let token = activeSearchToken
        searchResults = []
        if selectedSkillID.map(previousResultIDs.contains) == true {
            selectedSkillID = nil
        }
        searchPaginationState = .idle
        currentSearchLimit = 0
        guard !trimmed.isEmpty else {
            searchState = .idle
            return
        }

        searchState = .loading
        do {
            let results = try await apiClient.search(trimmed, limit)
            guard token == activeSearchToken, activeSearchQuery == trimmed else {
                return
            }
            searchResults = Self.merged([], with: results).items
            currentSearchLimit = limit
            searchState = .loaded
            searchPaginationState = Self.paginationState(
                responseCount: results.count,
                addedCount: searchResults.count,
                requestedLimit: limit
            )
        } catch is CancellationError {
            guard token == activeSearchToken else { return }
            searchState = .idle
            searchPaginationState = .idle
        } catch {
            guard token == activeSearchToken else { return }
            searchState = .failed(error.localizedDescription)
        }
    }

    func loadMoreSearch() async {
        guard searchState == .loaded,
              searchPaginationState == .canLoadMore || isSearchPaginationRetry,
              activeSearchPageToken != activeSearchToken,
              !activeSearchQuery.isEmpty else {
            return
        }
        let token = activeSearchToken
        let query = activeSearchQuery
        let requestedLimit = min(
            currentSearchLimit + Self.searchPageSize,
            Self.maximumSearchLimit
        )
        activeSearchPageToken = token
        searchPaginationState = .loading
        defer {
            if activeSearchPageToken == token {
                activeSearchPageToken = nil
            }
        }

        do {
            let results = try await apiClient.search(query, requestedLimit)
            guard token == activeSearchToken, query == activeSearchQuery else { return }
            let merged = Self.merged(searchResults, with: results)
            searchResults = merged.items
            currentSearchLimit = requestedLimit
            searchPaginationState = Self.paginationState(
                responseCount: results.count,
                addedCount: merged.addedCount,
                requestedLimit: requestedLimit
            )
        } catch is CancellationError {
            guard token == activeSearchToken else { return }
            searchPaginationState = .canLoadMore
        } catch {
            guard token == activeSearchToken else { return }
            searchPaginationState = .failed(error.localizedDescription)
        }
    }

    func loadSelectedSkill() async {
        guard let skill = selectedSkill else {
            detailState = .idle
            detailMarkdown = ""
            detailOwner = nil
            return
        }

        // Check NSCache first (application-level cache)
        if let cached = detailCache.get(slug: skill.slug, version: skill.latestVersion) {
            detailMarkdown = cached.markdown
            detailOwner = cached.owner
            detailState = .cachedRefreshing
        } else {
            detailState = .loading
            detailMarkdown = ""
            detailOwner = nil
        }

        // Fetch from network (URLCache may provide HTTP-level caching)
        do {
            let owner = try await apiClient.fetchDetail(skill.slug)
            let archive = try await apiClient.download(skill.slug, skill.latestVersion)
            let markdown = stripFrontmatter(from: try await fileWorker.loadRawMarkdown(from: archive))

            guard skill.id == selectedSkillID else { return }

            // Update NSCache with fresh data
            detailCache.set(
                CachedSkillDetail(markdown: markdown, owner: owner),
                slug: skill.slug,
                version: skill.latestVersion
            )

            detailOwner = owner
            detailMarkdown = markdown
            detailState = .loaded
        } catch {
            guard skill.id == selectedSkillID else { return }

            // Keep cached content visible without hiding the failed refresh.
            if detailState == .cachedRefreshing {
                detailState = .cachedUnavailable
            } else {
                detailState = .failed(error.localizedDescription)
                detailMarkdown = ""
            }
        }
    }

    private var isLatestPaginationRetry: Bool {
        if case .failed = latestPaginationState { return true }
        return false
    }

    private var isSearchPaginationRetry: Bool {
        if case .failed = searchPaginationState { return true }
        return false
    }

    private static func merged(
        _ existing: [RemoteSkill],
        with incoming: [RemoteSkill]
    ) -> (items: [RemoteSkill], addedCount: Int) {
        var items = existing
        var positions = Dictionary(
            uniqueKeysWithValues: items.enumerated().map { ($1.id, $0) }
        )
        var addedCount = 0
        for skill in incoming {
            if let index = positions[skill.id] {
                items[index] = skill
            } else {
                positions[skill.id] = items.count
                items.append(skill)
                addedCount += 1
            }
        }
        return (items, addedCount)
    }

    private static func paginationState(
        responseCount: Int,
        addedCount: Int,
        requestedLimit: Int
    ) -> PaginationState {
        if responseCount < requestedLimit
            || addedCount == 0
            || requestedLimit >= maximumSearchLimit {
            return .finished
        }
        return .canLoadMore
    }
}
