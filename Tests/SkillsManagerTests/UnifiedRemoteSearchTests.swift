import Foundation
import Testing

@testable import SkillsManager

@Suite("Unified remote search")
@MainActor
struct UnifiedRemoteSearchTests {
    @Test("providers reject stale results and fail independently before clear")
    func staleFailureIsolationAndClear() async throws {
        let clawHub = RemoteSkillStore(client: RemoteSkillClient(
            fetchLatest: { _, _ in RemoteSkillPage(items: [], nextCursor: nil) },
            search: { query, _ in
                if query == "old" {
                    try await Task.sleep(for: .milliseconds(40))
                }
                return [remoteSkill(query)]
            },
            download: { _, _ in throw RemoteSkillClientError.providerUnavailable },
            fetchDetail: { _ in nil },
            fetchLatestVersion: { _ in nil }
        ))
        let skillsSh = SkillsShSearchStore(client: SkillsShSearchClient {
            query, _, _ in
            if query == "old" {
                try await Task.sleep(for: .milliseconds(50))
                return searchPage(query)
            }
            throw SkillsShSearchError.providerUnavailable
        })

        let oldClawHub = Task { await clawHub.search(query: "old") }
        let oldSkillsSh = Task { await skillsSh.search(query: "old") }
        try await Task.sleep(for: .milliseconds(5))
        async let currentClawHub: Void = clawHub.search(query: "new")
        async let currentSkillsSh: Void = skillsSh.search(query: "new")
        _ = await (currentClawHub, currentSkillsSh)
        await oldClawHub.value
        await oldSkillsSh.value

        #expect(clawHub.searchState == .loaded)
        #expect(clawHub.searchResults.map(\.id) == ["new"])
        #expect(skillsSh.searchState == .failed(.providerUnavailable))
        #expect(skillsSh.items.isEmpty)

        async let clearClawHub: Void = clawHub.search(query: "")
        async let clearSkillsSh: Void = skillsSh.search(query: "")
        _ = await (clearClawHub, clearSkillsSh)

        #expect(clawHub.searchState == .idle)
        #expect(clawHub.searchResults.isEmpty)
        #expect(skillsSh.searchState == .idle)
        #expect(skillsSh.items.isEmpty)
    }

    nonisolated private func remoteSkill(_ id: String) -> RemoteSkill {
        RemoteSkill(
            id: id,
            slug: id,
            displayName: id.capitalized,
            summary: nil,
            latestVersion: nil,
            updatedAt: nil,
            downloads: nil,
            stars: nil
        )
    }

    nonisolated private func searchPage(_ query: String) -> SkillsShSearchPage {
        SkillsShSearchPage(
            query: query,
            items: [SkillsShSearchItem(
                id: query,
                skillID: query,
                name: query.capitalized,
                installs: 1,
                source: "owner/repo"
            )],
            reportedCount: 1
        )
    }
}
