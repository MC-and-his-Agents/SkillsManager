import Foundation
import Testing
@testable import SkillsManager

@Suite("RemoteSkillClient pagination")
struct RemoteSkillClientPaginationTests {
    @Test("uses clawhub.ai and round-trips an opaque latest cursor")
    func latestCursorRequest() async throws {
        let probe = RemoteURLProbe()
        let client = RemoteSkillClient.live(load: probe.loader)
        let cursor = #"{"page":2,"token":"a+b&c"}"#

        _ = try await client.fetchLatest(12, cursor)

        let url = try #require(await probe.urls.first)
        let components = try #require(URLComponents(url: url, resolvingAgainstBaseURL: false))
        #expect(components.scheme == "https")
        #expect(components.host == "clawhub.ai")
        #expect(components.path == "/api/v1/skills")
        #expect(components.queryItems?.first(where: { $0.name == "limit" })?.value == "12")
        #expect(components.queryItems?.first(where: { $0.name == "cursor" })?.value == cursor)
    }
}

@MainActor
@Suite("RemoteSkillStore pagination")
struct RemoteSkillStorePaginationTests {
    @Test("latest pages merge by identity and preserve selection")
    func latestMerge() async {
        let first = remoteSkill("first")
        let updated = remoteSkill("first", name: "Updated")
        let probe = RemotePaginationProbe(
            latest: [
                .success(RemoteSkillPage(items: [first], nextCursor: "next +&")),
                .success(RemoteSkillPage(
                    items: [updated, remoteSkill("second")],
                    nextCursor: nil
                )),
            ]
        )
        let store = RemoteSkillStore(client: probe.client)

        await store.loadLatest()
        store.selectedSkillID = first.id
        await store.loadMoreLatest()

        #expect(store.latestSkills.map(\.id) == ["first", "second"])
        #expect(store.latestSkills[0].displayName == "Updated")
        #expect(store.selectedSkillID == first.id)
        #expect(store.latestPaginationState == .finished)
        #expect(await probe.latestCalls.map(\.cursor) == [nil, "next +&"])
    }

    @Test("empty latest pages remain pageable while the provider returns a cursor")
    func emptyLatestPageWithCursor() async {
        let probe = RemotePaginationProbe(
            latest: [
                .success(RemoteSkillPage(items: [], nextCursor: "two")),
                .success(RemoteSkillPage(items: [], nextCursor: "three")),
                .success(RemoteSkillPage(items: [], nextCursor: nil)),
            ]
        )
        let store = RemoteSkillStore(client: probe.client)

        await store.loadLatest()
        #expect(store.latestPaginationState == .canLoadMore)
        await store.loadMoreLatest()
        #expect(store.latestPaginationState == .canLoadMore)
        await store.loadMoreLatest()
        #expect(store.latestPaginationState == .finished)
    }

    @Test("latest retry keeps the same cursor and existing results")
    func latestRetry() async {
        let first = remoteSkill("first")
        let probe = RemotePaginationProbe(
            latest: [
                .success(RemoteSkillPage(items: [first], nextCursor: "retry")),
                .failure(.providerUnavailable),
                .success(RemoteSkillPage(items: [remoteSkill("second")], nextCursor: nil)),
            ]
        )
        let store = RemoteSkillStore(client: probe.client)

        await store.loadLatest()
        await store.loadMoreLatest()
        #expect(store.latestSkills == [first])
        if case .failed = store.latestPaginationState {} else {
            Issue.record("Expected the page request to fail")
        }

        await store.loadMoreLatest()
        #expect(store.latestSkills.map(\.id) == ["first", "second"])
        #expect(await probe.latestCalls.map(\.cursor) == [nil, "retry", "retry"])
    }

    @Test("search expands limits without deleting prior results or selection")
    func progressiveSearch() async {
        let firstPage = remoteSkills(0..<20)
        let selected = firstPage[0]
        let probe = RemotePaginationProbe(
            search: [
                .success(firstPage),
                .success(remoteSkills(20..<60)),
                .success(remoteSkills(60..<102)),
            ]
        )
        let store = RemoteSkillStore(client: probe.client)

        await store.search(query: "swift")
        store.selectedSkillID = selected.id
        await store.loadMoreSearch()
        #expect(store.searchPaginationState == .canLoadMore)
        #expect(store.selectedSkillID == selected.id)
        await store.loadMoreSearch()

        #expect(store.searchResults.count == 102)
        #expect(store.selectedSkillID == selected.id)
        #expect(store.searchPaginationState == .finished)
        #expect(await probe.searchCalls.map(\.limit) == [20, 40, 50])
    }

    @Test("search retry keeps the same expanded limit")
    func searchRetry() async {
        let firstPage = remoteSkills(0..<20)
        let probe = RemotePaginationProbe(
            search: [
                .success(firstPage),
                .failure(.providerUnavailable),
                .success(remoteSkills(0..<40)),
            ]
        )
        let store = RemoteSkillStore(client: probe.client)

        await store.search(query: "swift")
        await store.loadMoreSearch()
        #expect(store.searchResults == firstPage)
        if case .failed = store.searchPaginationState {} else {
            Issue.record("Expected the page request to fail")
        }
        await store.loadMoreSearch()

        #expect(store.searchResults.count == 40)
        #expect(await probe.searchCalls.map(\.limit) == [20, 40, 40])
    }

    @Test("duplicate load more requests share one in-flight request")
    func duplicateSearchLoadMore() async {
        let probe = ControlledRemoteSearchProbe()
        let store = RemoteSkillStore(client: probe.client)

        let initial = Task { await store.search(query: "swift") }
        await waitForRemoteRequest { await probe.callCount == 1 }
        await probe.resolveNext(with: remoteSkills(0..<20))
        await initial.value

        let first = Task { await store.loadMoreSearch() }
        await waitForRemoteRequest { await probe.callCount == 2 }
        let duplicate = Task { await store.loadMoreSearch() }
        await duplicate.value
        #expect(await probe.callCount == 2)
        await probe.resolveNext(with: remoteSkills(0..<40))
        await first.value

        #expect(store.searchResults.count == 40)
    }

    @Test("a stale search response cannot replace a newer query")
    func staleSearchResponse() async {
        let probe = ControlledRemoteSearchProbe()
        let store = RemoteSkillStore(client: probe.client)

        let old = Task { await store.search(query: "old") }
        await waitForRemoteRequest { await probe.hasPending(query: "old") }
        let current = Task { await store.search(query: "current") }
        await waitForRemoteRequest { await probe.hasPending(query: "current") }
        await probe.resolve(query: "current", with: [remoteSkill("current")])
        await current.value
        await probe.resolve(query: "old", with: [remoteSkill("old")])
        await old.value

        #expect(store.searchResults.map(\.id) == ["current"])
    }
}

private actor RemoteURLProbe {
    private(set) var urls: [URL] = []

    nonisolated var loader: RemoteSkillClient.DataLoader {
        { try await self.load($0) }
    }

    private func load(_ url: URL) throws -> (Data, URLResponse) {
        urls.append(url)
        let data = Data(#"{"items":[],"nextCursor":null}"#.utf8)
        let response = HTTPURLResponse(
            url: url,
            statusCode: 200,
            httpVersion: nil,
            headerFields: ["Content-Type": "application/json"]
        )!
        return (data, response)
    }
}

private struct LatestCall: Sendable {
    let limit: Int
    let cursor: String?
}

private struct RemoteSearchCall: Sendable {
    let query: String
    let limit: Int
}

private actor RemotePaginationProbe {
    private var latestOutcomes: [Result<RemoteSkillPage, RemoteSkillClientError>]
    private var searchOutcomes: [Result<[RemoteSkill], RemoteSkillClientError>]
    private(set) var latestCalls: [LatestCall] = []
    private(set) var searchCalls: [RemoteSearchCall] = []

    init(
        latest: [Result<RemoteSkillPage, RemoteSkillClientError>] = [],
        search: [Result<[RemoteSkill], RemoteSkillClientError>] = []
    ) {
        latestOutcomes = latest
        searchOutcomes = search
    }

    nonisolated var client: RemoteSkillClient {
        RemoteSkillClient(
            fetchLatest: { try await self.latest(limit: $0, cursor: $1) },
            search: { try await self.search(query: $0, limit: $1) },
            download: { _, _ in throw RemoteSkillClientError.providerUnavailable },
            fetchDetail: { _ in nil },
            fetchLatestVersion: { _ in nil }
        )
    }

    private func latest(limit: Int, cursor: String?) throws -> RemoteSkillPage {
        latestCalls.append(LatestCall(limit: limit, cursor: cursor))
        guard !latestOutcomes.isEmpty else {
            throw RemoteSkillClientError.providerUnavailable
        }
        return try latestOutcomes.removeFirst().get()
    }

    private func search(query: String, limit: Int) throws -> [RemoteSkill] {
        searchCalls.append(RemoteSearchCall(query: query, limit: limit))
        guard !searchOutcomes.isEmpty else {
            throw RemoteSkillClientError.providerUnavailable
        }
        return try searchOutcomes.removeFirst().get()
    }
}

private actor ControlledRemoteSearchProbe {
    private struct Pending {
        let query: String
        let continuation: CheckedContinuation<[RemoteSkill], any Error>
    }

    private var pending: [Pending] = []
    private(set) var callCount = 0

    nonisolated var client: RemoteSkillClient {
        RemoteSkillClient(
            fetchLatest: { _, _ in RemoteSkillPage(items: [], nextCursor: nil) },
            search: { query, _ in try await self.search(query: query) },
            download: { _, _ in throw RemoteSkillClientError.providerUnavailable },
            fetchDetail: { _ in nil },
            fetchLatestVersion: { _ in nil }
        )
    }

    func hasPending(query: String) -> Bool {
        pending.contains { $0.query == query }
    }

    func resolveNext(with skills: [RemoteSkill]) {
        guard !pending.isEmpty else { return }
        pending.removeFirst().continuation.resume(returning: skills)
    }

    func resolve(query: String, with skills: [RemoteSkill]) {
        guard let index = pending.firstIndex(where: { $0.query == query }) else { return }
        pending.remove(at: index).continuation.resume(returning: skills)
    }

    private func search(query: String) async throws -> [RemoteSkill] {
        callCount += 1
        return try await withCheckedThrowingContinuation { continuation in
            pending.append(Pending(query: query, continuation: continuation))
        }
    }
}

private func remoteSkill(_ id: String, name: String? = nil) -> RemoteSkill {
    RemoteSkill(
        id: id,
        slug: id,
        displayName: name ?? "Skill \(id)",
        summary: nil,
        latestVersion: "1.0.0",
        updatedAt: nil,
        downloads: nil,
        stars: nil
    )
}

private func remoteSkills(_ range: Range<Int>) -> [RemoteSkill] {
    range.map { remoteSkill(String($0)) }
}

private func waitForRemoteRequest(
    _ condition: @escaping @Sendable () async -> Bool
) async {
    for _ in 0..<1_000 {
        if await condition() { return }
        await Task.yield()
    }
    Issue.record("Timed out waiting for remote request")
}
