import Foundation
import Testing

@testable import SkillsManager

@Suite("Skill consistency repair", .serialized)
struct SkillConsistencyRepairTests {
    @Test("selection token is order-independent and decision-complete")
    func selectionToken() throws {
        let skillID = SkillID()
        let slug = try DefaultDistributionSlug(validating: "demo")
        let codex = try binding(skillID: skillID, scope: .agent(.codex), slug: slug)
        let claude = try binding(skillID: skillID, scope: .agent(.claude), slug: slug)
        let first = DistributionSelectionReadback(
            bindings: [codex, claude],
            isExplicitlyConfigured: true
        )
        let reordered = DistributionSelectionReadback(
            bindings: [claude, codex],
            isExplicitlyConfigured: true
        )

        #expect(
            try DistributionRepairSelectionToken.encode(first, skillID: skillID)
                == DistributionRepairSelectionToken.encode(reordered, skillID: skillID)
        )
        #expect(
            try DistributionRepairSelectionToken.encode(first, skillID: skillID)
                != DistributionRepairSelectionToken.encode(
                    .init(bindings: [codex, claude], isExplicitlyConfigured: false),
                    skillID: skillID
                )
        )
        #expect(
            try DistributionRepairSelectionToken.encode(first, skillID: skillID)
                != DistributionRepairSelectionToken.encode(
                    .init(
                        bindings: [
                            try binding(
                                skillID: skillID,
                                scope: .agent(.codex),
                                slug: try DefaultDistributionSlug(validating: "other")
                            ),
                            claude,
                        ],
                        isExplicitlyConfigured: true
                    ),
                    skillID: skillID
                )
        )
        #expect(
            try DistributionRepairSelectionToken.encode(
                .init(bindings: [codex], isExplicitlyConfigured: true),
                skillID: skillID
            ) != DistributionRepairSelectionToken.encode(
                .init(
                    bindings: [try copyBinding(skillID: skillID, slug: slug)],
                    isExplicitlyConfigured: true
                ),
                skillID: skillID
            )
        )
    }

    @Test("planner emits only the two persisted repair shapes")
    func plannerShapes() throws {
        let skillID = SkillID()
        let slug = try DefaultDistributionSlug(validating: "demo")
        let bindings = [
            try binding(skillID: skillID, scope: .agent(.codex), slug: slug),
            try binding(skillID: skillID, scope: .agent(.claude), slug: slug),
        ]
        let selection = DistributionSelectionReadback(
            bindings: bindings,
            isExplicitlyConfigured: true
        )
        let observations = try Dictionary(uniqueKeysWithValues: bindings.map {
            let entry = try #require(DistributionTargetCatalog.current.entry(
                for: $0.scope,
                slug: slug
            ))
            return (entry, DistributionTargetObservation.missing)
        })
        let scopes = Set(bindings.map(\.scope.targetScopeKey))

        let rebuild = try DistributionPlanner().repairPlan(
            skillID: skillID,
            selection: selection,
            intent: .rebuildMissingSymlink,
            scopeKeys: scopes,
            observations: observations
        )
        #expect(rebuild.repairIntent == .rebuildMissingSymlink)
        #expect(rebuild.filesystemActions.map(\.kind) == [.createSymlink, .createSymlink])
        #expect(rebuild.bindingReplacement == bindings.map(\.intent))
        #expect(!rebuild.bindingsChanged)

        let disable = try DistributionPlanner().repairPlan(
            skillID: skillID,
            selection: selection,
            intent: .disableMissingBinding,
            scopeKeys: scopes,
            observations: observations
        )
        #expect(disable.repairIntent == .disableMissingBinding)
        #expect(disable.filesystemActions.isEmpty)
        #expect(disable.bindingReplacement.isEmpty)
        #expect(disable.bindingsChanged)

        #expect(throws: DistributionRepairPlanningError.invalidSelection) {
            _ = try DistributionPlanner().repairPlan(
                skillID: skillID,
                selection: selection,
                intent: .rebuildMissingSymlink,
                scopeKeys: [DistributionBindingScope.agent(.codex).targetScopeKey],
                observations: observations
            )
        }
        var unavailable = observations
        unavailable[try #require(unavailable.keys.first)] = .unavailable
        #expect(throws: DistributionRepairPlanningError.unavailable) {
            _ = try DistributionPlanner().repairPlan(
                skillID: skillID,
                selection: selection,
                intent: .rebuildMissingSymlink,
                scopeKeys: scopes,
                observations: unavailable
            )
        }
    }

    @Test("rebuild repairs a missing link and replaces stale ownership")
    func rebuildMissingLink() async throws {
        let fixture = try await RepairFixture()
        try FileManager.default.removeItem(at: fixture.targetURL)
        let service = SkillConsistencyRepairService(
            writer: fixture.writer,
            homeURL: fixture.workspace.distributionHomeURL
        )
        let preview = try await service.prepare(
            skillID: fixture.skillID,
            action: .rebuildMissingSymlink(scopeKeys: ["global"])
        )

        let result = try await service.confirm(preview)

        guard case .applied = result else {
            Issue.record("repair did not apply")
            return
        }
        #expect(try destination(of: fixture.targetURL) != nil)
        #expect(try await fixture.writer.loadDistributionSelection(
            skillID: fixture.skillID
        ).bindings.count == 1)
        await #expect(throws: SkillConsistencyRepairError.stalePreview) {
            _ = try await service.confirm(preview)
        }
    }

    @Test("rebuild accepts an absent ownership row")
    func rebuildWithoutOwnership() async throws {
        let fixture = try await RepairFixture()
        try FileManager.default.removeItem(at: fixture.targetURL)
        try deleteOwnership(fixture)
        let service = SkillConsistencyRepairService(
            writer: fixture.writer,
            homeURL: fixture.workspace.distributionHomeURL
        )
        let preview = try await service.prepare(
            skillID: fixture.skillID,
            action: .rebuildMissingSymlink(scopeKeys: ["global"])
        )

        _ = try await service.confirm(preview)

        #expect(try destination(of: fixture.targetURL) != nil)
        #expect(try ownership(fixture).count == 1)
    }

    @Test("disable removes only missing Binding and ownership")
    func disableMissingBinding() async throws {
        let fixture = try await RepairFixture()
        try FileManager.default.removeItem(at: fixture.targetURL)
        let service = SkillConsistencyRepairService(
            writer: fixture.writer,
            homeURL: fixture.workspace.distributionHomeURL
        )
        let preview = try await service.prepare(
            skillID: fixture.skillID,
            action: .disableMissingBinding(scopeKeys: ["global"])
        )

        _ = try await service.confirm(preview)

        #expect(!FileManager.default.fileExists(atPath: fixture.targetURL.path))
        #expect(try await fixture.writer.loadDistributionSelection(
            skillID: fixture.skillID
        ).bindings.isEmpty)
        #expect(try ownership(fixture).isEmpty)
        #expect(try configuration(fixture))
    }

    @Test("ordinary apply rejects a repair plan")
    func ordinaryApplyRejectsRepair() async throws {
        let fixture = try await RepairFixture()
        try FileManager.default.removeItem(at: fixture.targetURL)
        let selection = try await fixture.writer.loadDistributionSelection(
            skillID: fixture.skillID
        )
        let entry = try #require(DistributionTargetCatalog.current.entry(
            for: .global,
            slug: fixture.slug
        ))
        let plan = try DistributionPlanner().repairPlan(
            skillID: fixture.skillID,
            selection: selection,
            intent: .rebuildMissingSymlink,
            scopeKeys: ["global"],
            observations: [entry: .missing]
        )

        await #expect(throws: DistributionSymlinkExecutorError.self) {
            _ = try await fixture.writer.applyDistribution(
                skillID: fixture.skillID,
                plan: plan
            )
        }
        #expect(!FileManager.default.fileExists(atPath: fixture.targetURL.path))
    }

    @Test("selection change and ownership mismatch expire preview without mutation")
    func stalePreviewAndOwnershipMismatch() async throws {
        let fixture = try await RepairFixture()
        try FileManager.default.removeItem(at: fixture.targetURL)
        let service = SkillConsistencyRepairService(
            writer: fixture.writer,
            homeURL: fixture.workspace.distributionHomeURL
        )
        let selectionPreview = try await service.prepare(
            skillID: fixture.skillID,
            action: .rebuildMissingSymlink(scopeKeys: ["global"])
        )
        try deleteConfiguration(fixture)
        await #expect(throws: SkillConsistencyRepairError.stalePreview) {
            _ = try await service.confirm(selectionPreview)
        }
        #expect(!FileManager.default.fileExists(atPath: fixture.targetURL.path))

        try insertConfiguration(fixture)
        let ownershipPreview = try await service.prepare(
            skillID: fixture.skillID,
            action: .rebuildMissingSymlink(scopeKeys: ["global"])
        )
        try changeOwnershipTarget(fixture)
        let beforeOperations = try operationCount(fixture)
        await #expect(throws: SkillConsistencyRepairError.stalePreview) {
            _ = try await service.confirm(ownershipPreview)
        }
        #expect(try operationCount(fixture) == beforeOperations)
        #expect(!FileManager.default.fileExists(atPath: fixture.targetURL.path))
    }

    @Test("a target that reappears after preview is never overwritten")
    func targetReappears() async throws {
        let fixture = try await RepairFixture()
        try FileManager.default.removeItem(at: fixture.targetURL)
        let service = SkillConsistencyRepairService(
            writer: fixture.writer,
            homeURL: fixture.workspace.distributionHomeURL
        )
        let preview = try await service.prepare(
            skillID: fixture.skillID,
            action: .rebuildMissingSymlink(scopeKeys: ["global"])
        )
        try FileManager.default.createDirectory(
            at: fixture.targetURL,
            withIntermediateDirectories: false
        )
        let sentinel = fixture.targetURL.appendingPathComponent("local.txt")
        try Data("keep".utf8).write(to: sentinel)
        let beforeOperations = try operationCount(fixture)

        await #expect(throws: SkillConsistencyRepairError.stalePreview) {
            _ = try await service.confirm(preview)
        }

        #expect(try Data(contentsOf: sentinel) == Data("keep".utf8))
        #expect(try operationCount(fixture) == beforeOperations)
    }

    @Test("skip never enters the writer")
    func skip() async throws {
        let fixture = try await RepairFixture()
        let service = SkillConsistencyRepairService(
            writer: fixture.writer,
            homeURL: fixture.workspace.distributionHomeURL
        )
        let beforeOperations = try operationCount(fixture)
        let preview = try await service.prepare(
            skillID: fixture.skillID,
            action: .skip
        )

        #expect(try await service.confirm(preview) == .skipped)
        #expect(try operationCount(fixture) == beforeOperations)
    }

    @Test("recovery applies rebuilt ownership and rolls back DB-only disable")
    func recovery() async throws {
        try await recoverRebuild()
        try await recoverDisable()
    }
}
