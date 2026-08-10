import Foundation
import Observation

nonisolated struct SkillsShSearchResultID: Hashable, Sendable {
    let source: String
    let skillID: String
    let id: String

    init(_ item: SkillsShSearchItem) {
        source = item.source
        skillID = item.skillID
        id = item.id
    }
}

@MainActor
@Observable final class SkillsShSearchStore {
    enum SearchState: Equatable {
        case idle
        case loading
        case loaded
        case failed(Problem)
    }

    enum PaginationState: Equatable {
        case idle
        case loading
        case canLoadMore
        case finished
        case failed(Problem)
    }

    enum Problem: Equatable {
        case invalidRequest
        case timeout
        case offline
        case network
        case redirectRejected
        case rateLimited(retryAfterSeconds: Int?)
        case providerUnavailable
        case responseTooLarge
        case contractChanged

        var message: String {
            switch self {
            case .invalidRequest:
                return String(localized: "Enter a search query between 2 and 200 characters.", bundle: .module)
            case .timeout:
                return String(localized: "skills.sh did not respond in time.", bundle: .module)
            case .offline:
                return String(localized: "Connect to the internet and try again.", bundle: .module)
            case .network:
                return String(localized: "skills.sh could not be reached.", bundle: .module)
            case .redirectRejected:
                return String(localized: "The skills.sh search endpoint redirected unexpectedly.", bundle: .module)
            case .rateLimited(let seconds):
                guard let seconds else {
                    return String(localized: "skills.sh rate limited this request. Try again later.", bundle: .module)
                }
                let secondsText = String(seconds)
                return String(
                    localized: LocalizedStringResource(
            "skills.sh rate limited this request. Try again in \(secondsText) seconds.",
            bundle: .module
        ))
            case .providerUnavailable:
                return String(localized: "skills.sh is temporarily unavailable.", bundle: .module)
            case .responseTooLarge:
                return String(localized: "skills.sh returned more search data than can be handled safely.", bundle: .module)
            case .contractChanged:
                return String(localized: "The skills.sh search interface has changed.", bundle: .module)
            }
        }
    }

    private struct CacheKey: Hashable {
        let query: String
        let limit: Int
        let offset: Int
    }

    private struct CacheEntry {
        let page: SkillsShSearchPage
        let expiresAt: Date
    }

    private struct ActiveRequest: Equatable {
        let generation: UInt
        let limit: Int
    }

    static let pageSize = 20
    static let maximumLimit = 50
    static let cacheLifetime: TimeInterval = 300
    static let maximumCachedPages = 64

    var items: [SkillsShSearchItem] = []
    var selectedResultID: SkillsShSearchResultID?
    var query = ""
    var searchState: SearchState = .idle
    var paginationState: PaginationState = .idle

    private let client: SkillsShSearchClient
    private let now: () -> Date
    private var cache: [CacheKey: CacheEntry] = [:]
    private var generation: UInt = 0
    private var currentLimit = 0
    private var activeRequest: ActiveRequest?

    init(
        client: SkillsShSearchClient,
        now: @escaping () -> Date = Date.init
    ) {
        self.client = client
        self.now = now
    }

    var selectedItem: SkillsShSearchItem? {
        guard let selectedResultID else { return nil }
        return items.first { SkillsShSearchResultID($0) == selectedResultID }
    }

    func search(query rawQuery: String) async {
        generation &+= 1
        let requestGeneration = generation
        let trimmed = rawQuery.trimmingCharacters(in: .whitespacesAndNewlines)

        query = trimmed
        items = []
        selectedResultID = nil
        currentLimit = 0
        paginationState = .idle
        activeRequest = nil

        guard !trimmed.isEmpty else {
            searchState = .idle
            return
        }

        searchState = .loading
        await loadPage(
            query: trimmed,
            limit: Self.pageSize,
            generation: requestGeneration,
            isInitial: true
        )
    }

    func loadNextPage() async {
        guard searchState == .loaded,
              paginationState == .canLoadMore || isPaginationRetry,
              activeRequest == nil,
              !query.isEmpty else {
            return
        }
        let requestGeneration = generation
        let limit = min(currentLimit + Self.pageSize, Self.maximumLimit)
        paginationState = .loading
        await loadPage(
            query: query,
            limit: limit,
            generation: requestGeneration,
            isInitial: false
        )
    }

    func cancel() {
        generation &+= 1
        activeRequest = nil
        if searchState == .loading {
            searchState = items.isEmpty ? .idle : .loaded
        }
        if paginationState == .loading {
            paginationState = items.isEmpty || currentLimit >= Self.maximumLimit
                ? .idle
                : .canLoadMore
        }
    }

    var cachedPageCount: Int { cache.count }
    var nextRequestedLimit: Int {
        min(currentLimit + Self.pageSize, Self.maximumLimit)
    }

    private var isPaginationRetry: Bool {
        if case .failed = paginationState { return true }
        return false
    }

    private func loadPage(
        query: String,
        limit: Int,
        generation requestGeneration: UInt,
        isInitial: Bool
    ) async {
        let request = ActiveRequest(generation: requestGeneration, limit: limit)
        guard activeRequest == nil || activeRequest?.generation != requestGeneration else {
            return
        }
        activeRequest = request
        let key = CacheKey(query: query, limit: limit, offset: 0)

        do {
            let cached = cachedPage(for: key)
            let page: SkillsShSearchPage
            if let cached {
                page = cached
            } else {
                page = try await client.search(query, limit, 0)
            }
            guard isCurrent(request, query: query) else { return }

            if cached == nil {
                store(page, for: key)
            }
            activeRequest = nil
            apply(page, requestedLimit: limit, isInitial: isInitial)
        } catch is CancellationError {
            guard isCurrent(request, query: query) else { return }
            activeRequest = nil
            if isInitial {
                searchState = items.isEmpty ? .idle : .loaded
                paginationState = .idle
            } else {
                paginationState = items.isEmpty ? .idle : .canLoadMore
            }
        } catch {
            guard isCurrent(request, query: query) else { return }
            activeRequest = nil
            let problem = Self.problem(for: error)
            if isInitial {
                searchState = .failed(problem)
                paginationState = .idle
            } else {
                paginationState = .failed(problem)
            }
        }
    }

    private func apply(
        _ page: SkillsShSearchPage,
        requestedLimit: Int,
        isInitial: Bool
    ) {
        if isInitial {
            items = []
            searchState = .loaded
        }
        let addedCount = merge(page.items)
        currentLimit = requestedLimit
        paginationState = page.items.count < requestedLimit
            || addedCount == 0
            || requestedLimit >= Self.maximumLimit
            ? .finished
            : .canLoadMore

        if let selectedResultID,
           !items.contains(where: { SkillsShSearchResultID($0) == selectedResultID }) {
            self.selectedResultID = nil
        }
    }

    private func merge(_ incoming: [SkillsShSearchItem]) -> Int {
        var positions = Dictionary(
            uniqueKeysWithValues: items.enumerated().map {
                (SkillsShSearchResultID($1), $0)
            }
        )
        var addedCount = 0
        for item in incoming {
            let id = SkillsShSearchResultID(item)
            if let index = positions[id] {
                items[index] = item
            } else {
                positions[id] = items.count
                items.append(item)
                addedCount += 1
            }
        }
        return addedCount
    }

    private func isCurrent(_ request: ActiveRequest, query: String) -> Bool {
        generation == request.generation
            && self.query == query
            && activeRequest == request
    }

    private func cachedPage(for key: CacheKey) -> SkillsShSearchPage? {
        let current = now()
        removeExpiredCache(at: current)
        return cache[key].flatMap { current < $0.expiresAt ? $0.page : nil }
    }

    private func store(_ page: SkillsShSearchPage, for key: CacheKey) {
        let current = now()
        removeExpiredCache(at: current)
        cache[key] = CacheEntry(
            page: page,
            expiresAt: current.addingTimeInterval(Self.cacheLifetime)
        )
        while cache.count > Self.maximumCachedPages,
              let oldest = cache.min(by: { $0.value.expiresAt < $1.value.expiresAt })?.key {
            cache.removeValue(forKey: oldest)
        }
    }

    private func removeExpiredCache(at current: Date) {
        cache = cache.filter { current < $0.value.expiresAt }
    }

    private static func problem(for error: Error) -> Problem {
        guard let error = error as? SkillsShSearchError else { return .network }
        return switch error {
        case .invalidRequest: .invalidRequest
        case .timeout: .timeout
        case .offline: .offline
        case .network: .network
        case .redirectRejected: .redirectRejected
        case .rateLimited(let seconds): .rateLimited(retryAfterSeconds: seconds)
        case .providerUnavailable: .providerUnavailable
        case .responseTooLarge: .responseTooLarge
        case .contractChanged: .contractChanged
        }
    }
}
