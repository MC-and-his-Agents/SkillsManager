import Foundation
import Testing
@testable import SkillsManager

@MainActor
@Suite("skills.sh search store")
struct SkillsShSearchStoreTests {
    @Test("trims queries and stops when a page is shorter than the requested limit")
    func initialSearch() async {
        let probe = SearchProbe(outcomes: [
            .page(page(query: "swift", items: [item("one")], reportedCount: 0)),
        ])
        let store = SkillsShSearchStore(client: probe.client)

        await store.search(query: "  swift\n")

        #expect(await probe.recordedCalls() == [
            .init(query: "swift", limit: 20, offset: 0),
        ])
        #expect(store.items.map(\.id) == ["one"])
        #expect(store.searchState == .loaded)
        #expect(store.paginationState == .finished)
        #expect(store.nextRequestedLimit == 40)
    }

    @Test("empty queries do not request and invalid input stays typed")
    func emptyAndInvalidQueries() async {
        let probe = SearchProbe(outcomes: [.failure(.invalidRequest)])
        let store = SkillsShSearchStore(client: probe.client)

        await store.search(query: " \n ")
        #expect(await probe.recordedCalls().isEmpty)
        #expect(store.searchState == .idle)

        await store.search(query: "x")
        #expect(store.searchState == .failed(.invalidRequest))
        #expect(await probe.recordedCalls().count == 1)
    }

    @Test("pagination expands limits with zero offset and merges stable identities")
    func paginationAndDeduplication() async {
        let firstPage = pageItems(0..<20)
        var secondPage = pageItems(20..<40)
        secondPage.insert(
            SkillsShSearchItem(
                id: firstPage[0].id,
                skillID: firstPage[0].skillID,
                name: "Updated",
                installs: 99,
                source: firstPage[0].source
            ),
            at: 0
        )
        secondPage.append(contentsOf: pageItems(100..<119))
        let thirdPage = secondPage + pageItems(40..<50)
        let probe = SearchProbe(outcomes: [
            .page(page(query: "swift", items: firstPage)),
            .page(page(query: "swift", items: secondPage)),
            .page(page(query: "swift", items: thirdPage)),
        ])
        let store = SkillsShSearchStore(client: probe.client)

        await store.search(query: "swift")
        store.selectedResultID = SkillsShSearchResultID(firstPage[0])
        await store.loadNextPage()
        #expect(store.items.count == 59)
        #expect(store.items[0].name == "Updated")
        #expect(store.selectedResultID == SkillsShSearchResultID(firstPage[0]))
        #expect(store.paginationState == .canLoadMore)
        await store.loadNextPage()
        #expect(store.paginationState == .finished)
        #expect(await probe.recordedCalls().map(\.limit) == [20, 40, 50])
        #expect(await probe.recordedCalls().map(\.offset) == [0, 0, 0])
    }

    @Test("a fully repeated page ends pagination")
    func repeatedPageStops() async {
        let repeated = pageItems(0..<20)
        let probe = SearchProbe(outcomes: [
            .page(page(query: "swift", items: repeated)),
            .page(page(query: "swift", items: repeated)),
        ])
        let store = SkillsShSearchStore(client: probe.client)

        await store.search(query: "swift")
        await store.loadNextPage()

        #expect(store.items == repeated)
        #expect(store.paginationState == .finished)
    }

    @Test("pagination failure preserves results and retries the same limit")
    func paginationRetry() async {
        let firstPage = pageItems(0..<20)
        let expandedPage = pageItems(0..<40)
        let probe = SearchProbe(outcomes: [
            .page(page(query: "swift", items: firstPage)),
            .failure(.timeout),
            .page(page(query: "swift", items: expandedPage)),
        ])
        let store = SkillsShSearchStore(client: probe.client)

        await store.search(query: "swift")
        await store.loadNextPage()
        #expect(store.items == firstPage)
        #expect(store.paginationState == .failed(.timeout))
        #expect(store.nextRequestedLimit == 40)

        await store.loadNextPage()
        #expect(store.items == expandedPage)
        #expect(await probe.recordedCalls().map(\.limit) == [20, 40, 40])
        #expect(await probe.recordedCalls().map(\.offset) == [0, 0, 0])
    }

    @Test("concurrent load more requests do not duplicate the current limit")
    func concurrentLoadMore() async {
        let probe = ControlledSearchProbe()
        let store = SkillsShSearchStore(client: probe.client)

        let initial = Task { await store.search(query: "swift") }
        await waitUntil { await probe.hasPending("swift") }
        await probe.resolve(
            "swift",
            with: page(query: "swift", items: pageItems(0..<20))
        )
        await initial.value

        let first = Task { await store.loadNextPage() }
        await waitUntil { await probe.hasPending("swift") }
        let duplicate = Task { await store.loadNextPage() }
        await duplicate.value
        await probe.resolve(
            "swift",
            with: page(query: "swift", items: pageItems(0..<40))
        )
        await first.value

        #expect(await probe.recordedCalls().map(\.limit) == [20, 40])
        #expect(await probe.recordedCalls().map(\.offset) == [0, 0])
        #expect(store.items.count == 40)
    }

    @Test("cache expires exactly at 300 seconds")
    func cacheExpiryBoundary() async {
        var current = Date(timeIntervalSince1970: 0)
        let probe = SearchProbe(outcomes: [
            .page(page(query: "swift", items: [item("first")])),
            .page(page(query: "swift", items: [item("fresh")])),
        ])
        let store = SkillsShSearchStore(client: probe.client, now: { current })

        await store.search(query: "swift")
        current = Date(timeIntervalSince1970: 299)
        await store.search(query: "swift")
        #expect(store.items.map(\.id) == ["first"])
        #expect(await probe.recordedCalls().count == 1)

        current = Date(timeIntervalSince1970: 300)
        await store.search(query: "swift")
        #expect(store.items.map(\.id) == ["fresh"])
        #expect(await probe.recordedCalls().count == 2)
    }

    @Test("cache remains bounded and evicts the earliest expiry")
    func boundedCache() async {
        var current = Date(timeIntervalSince1970: 0)
        let outcomes = (0...65).map { index in
            SearchOutcome.page(page(query: "query-\(index)", items: [item("item-\(index)")]))
        }
        let probe = SearchProbe(outcomes: outcomes)
        let store = SkillsShSearchStore(client: probe.client, now: { current })

        for index in 0...64 {
            current = Date(timeIntervalSince1970: TimeInterval(index))
            await store.search(query: "query-\(index)")
        }
        #expect(store.cachedPageCount == 64)

        current = Date(timeIntervalSince1970: 65)
        await store.search(query: "query-0")
        #expect(await probe.recordedCalls().count == 66)
        #expect(store.cachedPageCount == 64)
    }

    @Test("a stale transport may overlap but cannot publish or cache")
    func staleResponseIsSuppressed() async {
        let probe = ControlledSearchProbe()
        let store = SkillsShSearchStore(client: probe.client)

        let alpha = Task { await store.search(query: "alpha") }
        await waitUntil { await probe.hasPending("alpha") }
        alpha.cancel()

        let beta = Task { await store.search(query: "beta") }
        await waitUntil { await probe.hasPending("beta") }
        await probe.resolve(
            "beta",
            with: page(query: "beta", items: [item("beta")])
        )
        await beta.value

        await probe.resolve(
            "alpha",
            with: page(query: "alpha", items: [item("alpha")])
        )
        await alpha.value

        #expect(store.query == "beta")
        #expect(store.items.map(\.id) == ["beta"])
        #expect(store.cachedPageCount == 1)
        #expect(store.nextRequestedLimit == 40)
    }

    @Test("a stale failure and explicit cancellation remain silent")
    func staleFailureAndCancellation() async {
        let probe = ControlledSearchProbe()
        let store = SkillsShSearchStore(client: probe.client)

        let old = Task { await store.search(query: "old") }
        await waitUntil { await probe.hasPending("old") }
        old.cancel()
        let current = Task { await store.search(query: "current") }
        await waitUntil { await probe.hasPending("current") }
        await probe.resolve(
            "current",
            with: page(query: "current", items: [item("current")])
        )
        await current.value
        await probe.reject("old", with: .providerUnavailable)
        await old.value
        #expect(store.searchState == .loaded)
        #expect(store.items.map(\.id) == ["current"])

        let cancelled = Task { await store.search(query: "cancelled") }
        await waitUntil { await probe.hasPending("cancelled") }
        cancelled.cancel()
        store.cancel()
        await probe.reject("cancelled", with: .network)
        await cancelled.value
        #expect(store.searchState == .idle)
        #expect(store.searchState != .failed(.network))
    }

    @Test("transport cancellation does not leave loading state stuck")
    func transportCancellation() async {
        let client = SkillsShSearchClient { _, limit, _ in
            if limit == 20 {
                return page(query: "swift", items: pageItems(0..<20))
            }
            throw CancellationError()
        }
        let store = SkillsShSearchStore(client: client)

        await store.search(query: "swift")
        await store.loadNextPage()

        #expect(store.searchState == .loaded)
        #expect(store.paginationState == .canLoadMore)
        #expect(store.items.count == 20)
    }

    @Test("new results clear a selection that no longer exists")
    func selectionIsCleared() async {
        let first = item("first")
        let probe = SearchProbe(outcomes: [
            .page(page(query: "first", items: [first])),
            .page(page(query: "second", items: [item("second")])),
        ])
        let store = SkillsShSearchStore(client: probe.client)

        await store.search(query: "first")
        store.selectedResultID = SkillsShSearchResultID(first)
        #expect(store.selectedItem == first)
        await store.search(query: "second")
        #expect(store.selectedResultID == nil)
        #expect(store.selectedItem == nil)
    }

    @Test("typed client failures keep stable presentation")
    func typedProblems() async {
        let cases: [(SkillsShSearchError, SkillsShSearchStore.Problem)] = [
            (.invalidRequest, .invalidRequest),
            (.timeout, .timeout),
            (.offline, .offline),
            (.network, .network),
            (.redirectRejected, .redirectRejected),
            (.rateLimited(retryAfterSeconds: 12), .rateLimited(retryAfterSeconds: 12)),
            (.providerUnavailable, .providerUnavailable),
            (.responseTooLarge, .responseTooLarge),
            (.contractChanged, .contractChanged),
        ]

        for (error, expected) in cases {
            let probe = SearchProbe(outcomes: [.failure(error)])
            let store = SkillsShSearchStore(client: probe.client)
            await store.search(query: "swift")
            #expect(store.searchState == .failed(expected))
            #expect(!expected.message.isEmpty)
        }
    }
}

private struct SearchCall: Equatable, Sendable {
    let query: String
    let limit: Int
    let offset: Int
}

private enum SearchOutcome: Sendable {
    case page(SkillsShSearchPage)
    case failure(SkillsShSearchError)
}

private actor SearchProbe {
    private var outcomes: [SearchOutcome]
    private var calls: [SearchCall] = []

    init(outcomes: [SearchOutcome]) {
        self.outcomes = outcomes
    }

    nonisolated var client: SkillsShSearchClient {
        SkillsShSearchClient { query, limit, offset in
            try await self.execute(query: query, limit: limit, offset: offset)
        }
    }

    func recordedCalls() -> [SearchCall] { calls }

    private func execute(
        query: String,
        limit: Int,
        offset: Int
    ) throws -> SkillsShSearchPage {
        calls.append(SearchCall(query: query, limit: limit, offset: offset))
        guard !outcomes.isEmpty else { throw SkillsShSearchError.network }
        switch outcomes.removeFirst() {
        case .page(let page):
            return page
        case .failure(let error):
            throw error
        }
    }
}

private actor ControlledSearchProbe {
    private var continuations: [
        String: CheckedContinuation<SkillsShSearchPage, any Error>
    ] = [:]
    private var calls: [SearchCall] = []

    nonisolated var client: SkillsShSearchClient {
        SkillsShSearchClient { query, limit, offset in
            try await self.execute(query: query, limit: limit, offset: offset)
        }
    }

    func hasPending(_ query: String) -> Bool {
        continuations[query] != nil
    }

    func recordedCalls() -> [SearchCall] { calls }

    func resolve(_ query: String, with page: SkillsShSearchPage) {
        continuations.removeValue(forKey: query)?.resume(returning: page)
    }

    func reject(_ query: String, with error: SkillsShSearchError) {
        continuations.removeValue(forKey: query)?.resume(throwing: error)
    }

    private func execute(
        query: String,
        limit: Int,
        offset: Int
    ) async throws -> SkillsShSearchPage {
        calls.append(SearchCall(query: query, limit: limit, offset: offset))
        return try await withCheckedThrowingContinuation { continuation in
            continuations[query] = continuation
        }
    }
}

private func waitUntil(
    _ condition: @escaping @Sendable () async -> Bool
) async {
    for _ in 0..<1_000 {
        if await condition() { return }
        await Task.yield()
    }
    Issue.record("Timed out waiting for asynchronous test state")
}

private func page(
    query: String,
    items: [SkillsShSearchItem],
    reportedCount: Int? = nil
) -> SkillsShSearchPage {
    SkillsShSearchPage(
        query: query,
        items: items,
        reportedCount: reportedCount ?? items.count
    )
}

private func item(_ id: String) -> SkillsShSearchItem {
    SkillsShSearchItem(
        id: id,
        skillID: "skill-\(id)",
        name: "Skill \(id)",
        installs: 1,
        source: "owner/repo"
    )
}

private func pageItems(_ range: Range<Int>) -> [SkillsShSearchItem] {
    range.map { item(String($0)) }
}
