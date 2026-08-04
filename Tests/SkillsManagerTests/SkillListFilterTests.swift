import Testing

@testable import SkillsManager

@Suite("Unified Skill list filters")
@MainActor
struct SkillListFilterTests {
    @Test("structured sources use OR matching and deterministic labels")
    func structuredSourceMatching() {
        let multi = SkillListOriginProjection(
            hasRepositorySource: true,
            providers: ["skills.sh", "clawdhub"]
        )
        let unknown = SkillListOriginProjection(
            hasRepositorySource: false,
            providers: ["future-provider"]
        )
        let local = SkillListOriginProjection(
            hasRepositorySource: false,
            providers: []
        )

        #expect(multi.labels.map(\.text) == ["Repository", "ClawHub", "skills.sh"])
        #expect(unknown.labels.map(\.text) == ["future-provider"])
        #expect(local.sources == [.local])

        for source in [SkillListSource.repository, .clawHub, .skillsSh] {
            let filters = SkillListFilters(source: .source(source))
            #expect(filters.includesManaged(origin: multi, enabledPlatforms: []))
        }
        #expect(!SkillListFilters(source: .source(.local)).includesManaged(
            origin: unknown,
            enabledPlatforms: []
        ))
        #expect(SkillListFilters().includesManaged(
            origin: unknown,
            enabledPlatforms: []
        ))
    }

    @Test("all discovery states stay in Needs Import without changing their identity")
    func discoveryStatusMembership() {
        let statuses: [SkillDiscoveryStatus] = [
            .managed, .claimable, .unmanaged, .conflict, .permissionDenied, .damaged,
        ]
        let origin = SkillListOriginProjection(hasRepositorySource: false, providers: [])
        let needsImport = SkillListFilters(status: .needsImport)

        for status in statuses {
            #expect(needsImport.includesDiscovery(status: status, origin: origin))
            #expect(status.displayName.isEmpty == false)
        }
        #expect(!SkillListFilters(status: .managed).includesDiscovery(
            status: .claimable,
            origin: origin
        ))
    }

    @Test("remote providers are excluded without changing their provider state")
    func remoteVisibility() {
        #expect(SkillListFilters(status: .available).includesRemote(.clawHub))
        #expect(SkillListFilters(status: .available).includesRemote(.skillsSh))
        #expect(!SkillListFilters(status: .managed).includesRemote(.clawHub))
        #expect(!SkillListFilters(source: .source(.skillsSh)).includesRemote(.clawHub))
        #expect(!SkillListFilters(agent: .agent(.codex)).includesRemote(.skillsSh))
    }

    @Test("global and dedicated bindings produce effective Agent coverage")
    func effectiveAgentCoverage() throws {
        let skillID = SkillID()
        let slug = try DefaultDistributionSlug(validating: "demo")
        let global = try DistributionBinding(
            skillID: skillID,
            scope: .global,
            distributionSlug: slug,
            createdAtMilliseconds: 1,
            updatedAtMilliseconds: 1
        )
        let claude = try DistributionBinding(
            skillID: skillID,
            scope: .agent(.claude),
            distributionSlug: slug,
            createdAtMilliseconds: 1,
            updatedAtMilliseconds: 1
        )
        let platforms = SkillStore.enabledPlatforms(for: [global, claude])

        #expect(platforms == Set(DistributionTargetCatalog.current.globalReaders).union([.claude]))
        #expect(platforms.count == 4)
        #expect(SkillListFilters(agent: .agent(.claude)).includesManaged(
            origin: SkillListOriginProjection(hasRepositorySource: false, providers: []),
            enabledPlatforms: platforms
        ))
        #expect(SkillListAgentSummary.text(count: 0) == "0 Agents")
        #expect(SkillListAgentSummary.text(count: 1) == "1 Agent")
        #expect(SkillListAgentSummary.text(count: 4) == "4 Agents")
    }

    @Test("selection is retained only while its filtered row remains visible")
    func selectionReconciliation() {
        let selected = UnifiedSkillSelection.managed("alpha")
        #expect(reconciledSkillSelection(
            selected,
            visibleSelections: [selected, .managed("beta")]
        ) == selected)
        #expect(reconciledSkillSelection(
            selected,
            visibleSelections: [.managed("beta")]
        ) == nil)
    }

    @Test("an asynchronous initial selection cannot target a hidden row")
    func hiddenInitialSelectionIsRejected() {
        let hiddenInitial = UnifiedSkillSelection.managed("first-managed")
        let visibleRemote = UnifiedSkillSelection.clawHub("remote")

        #expect(reconciledSkillSelection(
            hiddenInitial,
            visibleSelections: [visibleRemote]
        ) == nil)
    }
}
