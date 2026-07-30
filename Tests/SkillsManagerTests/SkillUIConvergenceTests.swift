import Foundation
import Testing

@testable import SkillsManager

@Suite("SkillBatchUpdate and SkillConsistency UI convergence")
@MainActor
struct SkillBatchUpdateConsistencyPresentationTests {
    @Test("Local identity uses deterministic metadata precedence")
    func localIdentityPrecedence() throws {
        let skillID = SkillID()
        let parentID = SkillID()
        let source = SkillSourceRecord(
            skillID: skillID,
            repositoryURL: try NormalizedRepositoryURL("https://github.com/example/repo"),
            subpath: try RepositorySubpath("skills/demo")
        )
        let rootSource = SkillSourceRecord(
            skillID: skillID,
            repositoryURL: source.repositoryURL,
            subpath: try RepositorySubpath("")
        )
        let lineage = try SkillForkLineageRecord(
            forkSkillID: skillID,
            parentSkillID: parentID,
            forkedFromFingerprint: SkillContentFingerprint(currentDigest: Data(repeating: 1, count: 32)),
            createdAtMilliseconds: 1
        )
        let provenance = try [
            provider("zeta", skillID: skillID),
            provider("skills.sh", skillID: skillID),
            provider("clawdhub", skillID: skillID),
        ]

        #expect(SkillStore.identitySummary(
            source: source,
            forkLineage: lineage,
            providerProvenance: provenance,
            displayNames: [parentID: "Parent Skill"]
        ) == "Fork of Parent Skill")
        #expect(SkillStore.identitySummary(
            source: source,
            forkLineage: nil,
            providerProvenance: provenance,
            displayNames: [:]
        ) == "\(source.repositoryURL.value) · skills/demo")
        #expect(SkillStore.identitySummary(
            source: rootSource,
            forkLineage: nil,
            providerProvenance: provenance,
            displayNames: [:]
        ) == source.repositoryURL.value)
        #expect(SkillStore.identitySummary(
            source: nil,
            forkLineage: nil,
            providerProvenance: provenance,
            displayNames: [:]
        ) == "Discovered via Clawdhub, skills.sh, zeta")
        #expect(SkillStore.identitySummary(
            source: nil,
            forkLineage: lineage,
            providerProvenance: [],
            displayNames: [:]
        ) == "Fork of \(parentID.directoryName)")
        #expect(SkillStore.identitySummary(
            source: nil,
            forkLineage: nil,
            providerProvenance: [],
            displayNames: [:]
        ) == "Local")
    }

    @Test("Batch filtering and active item do not mutate results")
    func batchFilteringAndActiveItem() {
        let completedID = SkillID()
        let activeID = SkillID()
        let queuedID = SkillID()
        let model = SkillBatchUpdateViewModel()
        model.items = [
            SkillBatchUpdateItem(
                skillID: completedID,
                displayName: "Alpha",
                phase: .result(.updated, nil)
            ),
            SkillBatchUpdateItem(
                skillID: activeID,
                displayName: "Beta",
                phase: .updating
            ),
            SkillBatchUpdateItem(
                skillID: queuedID,
                displayName: "Gamma",
                phase: .queued
            ),
        ]

        let summary = model.summary
        #expect(SkillBatchUpdatePresentation.filteredItems(
            model.items,
            query: "  BETA "
        ).map(\.skillID) == [activeID])
        #expect(SkillBatchUpdatePresentation.filteredItems(
            model.items,
            query: "missing"
        ).isEmpty)
        #expect(SkillBatchUpdatePresentation.filteredItems(
            model.items,
            query: " "
        ) == model.items)
        #expect(model.activeSkillID == activeID)
        #expect(model.summary == summary)
        #expect(model.items.first?.finalResult == .updated)

        model.items[1].phase = .result(.updated, nil)
        model.items[2].phase = .checking
        #expect(model.activeSkillID == queuedID)
        #expect(model.items.first?.finalResult == .updated)
    }

    @Test("Consistency filtering searches title detail and locator")
    func consistencyFiltering() {
        let findings = [
            finding(id: "one", title: "Missing link", detail: "Codex target", locator: "/one"),
            finding(id: "two", title: "Copy drift", detail: "Claude target", locator: "/two"),
        ]

        #expect(SkillConsistencyPresentation.filteredFindings(
            findings,
            query: "missing"
        ).map(\.id) == ["one"])
        #expect(SkillConsistencyPresentation.filteredFindings(
            findings,
            query: "CLAUDE"
        ).map(\.id) == ["two"])
        #expect(SkillConsistencyPresentation.filteredFindings(
            findings,
            query: "/one"
        ).map(\.id) == ["one"])
        #expect(SkillConsistencyPresentation.filteredFindings(
            findings,
            query: "none"
        ).isEmpty)
        #expect(SkillConsistencyPresentation.filteredFindings(
            findings,
            query: " "
        ) == findings)
    }

    private func provider(
        _ code: String,
        skillID: SkillID
    ) throws -> ProviderProvenanceRecord {
        let slug = try DefaultDistributionSlug(validating: "shared-skill")
        return try ProviderProvenanceRecord(
            skillID: skillID,
            identity: ProviderAliasIdentity(provider: code, identifier: slug.value),
            identifierKey: slug.collisionKey
        )
    }

    private func finding(
        id: String,
        title: String,
        detail: String,
        locator: String?
    ) -> SkillConsistencyPresentation.Finding {
        SkillConsistencyPresentation.Finding(
            id: id,
            title: title,
            detail: detail,
            locator: locator,
            severity: .warning,
            actions: [.keepForNow],
            observation: nil,
            skillID: nil,
            affectedFindingIDs: [id]
        )
    }
}

@Suite("RemoteSkillStore retry presentation", .serialized)
@MainActor
struct RemoteSkillStoreRetryPresentationTests {
    @Test("List operations can retry after a stable unavailable state")
    func listRetries() async {
        let probe = ClawdhubRetryProbe()
        let store = RemoteSkillStore(client: await probe.client)

        await store.loadLatest()
        if case .failed = store.latestState {} else {
            Issue.record("Expected the first latest request to fail")
        }
        await store.loadLatest()
        #expect(store.latestState == .loaded)
        #expect(await probe.latestCalls == 2)

        await store.search(query: "swift")
        if case .failed = store.searchState {} else {
            Issue.record("Expected the first search request to fail")
        }
        await store.search(query: "swift")
        #expect(store.searchState == .loaded)
        #expect(await probe.searchCalls == 2)
        #expect(ClawdhubAvailabilityPresentation.title == "Clawdhub unavailable")
    }

    @Test("Cached detail remains visible and truthful across retries")
    func cachedDetailRetry() async {
        let probe = ClawdhubRetryProbe()
        let store = RemoteSkillStore(client: await probe.client)
        let skill = RemoteSkill(
            id: UUID().uuidString,
            slug: UUID().uuidString,
            displayName: "Cached Skill",
            summary: nil,
            latestVersion: "1.0.0",
            updatedAt: nil,
            downloads: nil,
            stars: nil
        )
        RemoteSkillDetailCache.shared.set(
            CachedSkillDetail(markdown: "# Cached", owner: nil),
            slug: skill.slug,
            version: skill.latestVersion
        )
        store.latestSkills = [skill]
        store.selectedSkillID = skill.id

        await store.loadSelectedSkill()
        #expect(store.detailState == .cachedUnavailable)
        #expect(store.detailMarkdown == "# Cached")
        await store.loadSelectedSkill()
        #expect(store.detailState == .cachedUnavailable)
        #expect(store.detailMarkdown == "# Cached")
        #expect(await probe.detailCalls == 2)
        #expect(
            ClawdhubAvailabilityPresentation.cachedDetail
                == "Clawdhub unavailable — cached content may be out of date."
        )
    }
}

private actor ClawdhubRetryProbe {
    private(set) var latestCalls = 0
    private(set) var searchCalls = 0
    private(set) var detailCalls = 0

    var client: RemoteSkillClient {
        RemoteSkillClient(
            fetchLatest: { limit in try await self.latest(limit: limit) },
            search: { query, limit in try await self.search(query: query, limit: limit) },
            download: { _, _ in throw RemoteSkillClientError.providerUnavailable },
            fetchDetail: { slug in try await self.detail(slug: slug) },
            fetchLatestVersion: { _ in nil }
        )
    }

    private func latest(limit: Int) throws -> [RemoteSkill] {
        latestCalls += 1
        if latestCalls == 1 { throw RemoteSkillClientError.providerUnavailable }
        return []
    }

    private func search(query: String, limit: Int) throws -> [RemoteSkill] {
        searchCalls += 1
        if searchCalls == 1 { throw RemoteSkillClientError.providerUnavailable }
        return []
    }

    private func detail(slug: String) throws -> RemoteSkillOwner? {
        detailCalls += 1
        throw RemoteSkillClientError.providerUnavailable
    }
}
