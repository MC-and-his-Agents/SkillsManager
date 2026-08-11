import Foundation
import Testing

@testable import SkillsManager

@Suite("Skill consistency convergence", .serialized)
struct SkillConsistencyConvergenceTests {
    @Test("same-fingerprint agent duplicate is backed up and removed")
    func convergesAgentDuplicate() async throws {
        let workspace = try WriterWorkspace(distributionEnabled: true)
        let writer = try await workspace.openWriter()
        _ = try await writer.migrateLegacy(homeURL: workspace.distributionHomeURL)

        let snapshot = try workspace.snapshot(content: "# Duplicate")
        let skillID = SkillID()
        let payload = try workspace.payload(
            skillID: skillID,
            name: "Duplicate",
            snapshot: snapshot
        )
        _ = try await writer.create(payload: payload, sourceSnapshot: snapshot)
        let catalog = DistributionTargetCatalog.current(homeURL: workspace.distributionHomeURL)
        let plan = try await writer.distributionPlan(
            skillID: skillID,
            desiredConfiguration: .init(
                scope: .global(payload.skill.defaultDistributionSlug),
                syncMode: .symlink
            ),
            requiredAdapterCodes: Set(catalog.globalReaders.map(\.storageKey)),
            catalog: catalog
        )
        _ = try await writer.applyDistribution(skillID: skillID, plan: plan)

        let agentRoot = workspace.distributionHomeURL
            .appendingPathComponent(".codex/skills", isDirectory: true)
        try FileManager.default.createDirectory(at: agentRoot, withIntermediateDirectories: true)
        let duplicate = agentRoot.appendingPathComponent("duplicate", isDirectory: true)
        try FileManager.default.createDirectory(at: duplicate, withIntermediateDirectories: false)
        try Data("# Duplicate".utf8).write(
            to: duplicate.appendingPathComponent("SKILL.md"),
            options: .atomic
        )

        let auditService = SkillConsistencyAuditService(
            writer: writer,
            homeURL: workspace.distributionHomeURL
        )
        let audit = try await auditService.prepare()
        let observation = try #require(audit.discoveryObservations.first {
            $0.roots.contains {
                $0.scope.kind == .agent
                    && $0.scope.adapterCode == SkillPlatform.codex.storageKey
            } && $0.symbolicLinkIdentity == nil
        })
        #expect(observation.matchedSkillID == skillID)
        #expect(observation.fingerprint == payload.skill.contentFingerprint)
        #expect(audit.manifest.discovery.occupancies.contains {
            $0.relativeLocatorKey == observation.relativeLocatorKey
                && $0.relation == .sameFingerprint
                && $0.entries.contains { !$0.roots.isEmpty }
        })
        let findings = try SkillConsistencyPresentation.historicalFindings(audit)
        #expect(findings.contains {
            $0.observation?.relativeLocatorKey == observation.relativeLocatorKey
                && $0.actions.contains {
                    if case .migrate = $0 { return true }
                    return false
                }
        })

        let service = HistoricalSkillMigrationService(
            writer: writer,
            homeURL: workspace.distributionHomeURL,
            nowMilliseconds: { 42 }
        )
        let preview = try await service.prepare(
            audit: audit,
            observation: observation,
            importAction: .claimExisting
        )
        let result = try await service.confirm(preview.token)
        let rerun = try await service.confirm(preview.token)

        #expect(result.distribution.outcome == .applied)
        #expect(rerun.distribution.operationID == result.distribution.operationID)
        #expect(!FileManager.default.fileExists(atPath: duplicate.path))
        #expect(try workspace.integer("SELECT count(*) FROM distribution_bindings") == 1)
        #expect(try workspace.integer("SELECT count(*) FROM skill_backups") == 1)
        #expect(try workspace.integer("SELECT count(*) FROM local_skill_origins") == 0)

        let finalAudit = try await auditService.prepare()
        let visibleScopes = finalAudit.discoveryObservations
            .filter { $0.relativeLocatorKey == payload.skill.defaultDistributionSlug.collisionKey }
            .flatMap(\.roots)
        #expect(visibleScopes.filter { $0.scope.kind == .global }.count == 1)
        #expect(visibleScopes.filter {
            $0.scope.kind == .agent && $0.scope.adapterCode == SkillPlatform.codex.storageKey
        }.isEmpty)
    }

    @Test("same-fingerprint ordinary global target is backed up and replaced")
    func replacesOrdinaryGlobalTarget() async throws {
        let workspace = try WriterWorkspace(distributionEnabled: true)
        let writer = try await workspace.openWriter()
        _ = try await writer.migrateLegacy(homeURL: workspace.distributionHomeURL)

        let snapshot = try workspace.snapshot(content: "# Global duplicate")
        let skillID = SkillID()
        let payload = try workspace.payload(
            skillID: skillID,
            name: "Global Duplicate",
            snapshot: snapshot
        )
        _ = try await writer.create(payload: payload, sourceSnapshot: snapshot)
        let catalog = DistributionTargetCatalog.current(homeURL: workspace.distributionHomeURL)
        let plan = try await writer.distributionPlan(
            skillID: skillID,
            desiredConfiguration: .init(
                scope: .global(payload.skill.defaultDistributionSlug),
                syncMode: .symlink
            ),
            requiredAdapterCodes: Set(catalog.globalReaders.map(\.storageKey)),
            catalog: catalog
        )
        _ = try await writer.applyDistribution(skillID: skillID, plan: plan)

        let target = workspace.distributionHomeURL
            .appendingPathComponent(
                ".agents/skills/\(payload.skill.defaultDistributionSlug.value)",
                isDirectory: true
            )
        try FileManager.default.removeItem(at: target)
        try FileManager.default.createDirectory(at: target, withIntermediateDirectories: false)
        try Data("# Global duplicate".utf8).write(
            to: target.appendingPathComponent("SKILL.md"),
            options: .atomic
        )

        let auditService = SkillConsistencyAuditService(
            writer: writer,
            homeURL: workspace.distributionHomeURL
        )
        let audit = try await auditService.prepare()
        let observation = try #require(audit.discoveryObservations.first {
            $0.roots.contains {
                $0.scope.kind == .global
            } && $0.symbolicLinkIdentity == nil
        })
        #expect(observation.matchedSkillID == skillID)
        #expect(observation.fingerprint == payload.skill.contentFingerprint)

        let service = HistoricalSkillMigrationService(
            writer: writer,
            homeURL: workspace.distributionHomeURL,
            nowMilliseconds: { 42 }
        )
        let preview = try await service.prepare(
            audit: audit,
            observation: observation,
            importAction: .claimExisting
        )
        let result = try await service.confirm(preview.token)

        #expect(result.distribution.outcome == .applied)
        #expect(FileManager.default.fileExists(atPath: target.path))
        #expect(try FileManager.default.destinationOfSymbolicLink(
            atPath: target.path
        ) == workspace.root.appendingPathComponent(skillID.directoryName).path)
        #expect(try workspace.integer("SELECT count(*) FROM skill_backups") == 1)
        #expect(try workspace.integer("SELECT count(*) FROM local_skill_origins") == 0)
    }

    @Test("agent selection removes a redundant ordinary global target")
    func removesGlobalDuplicateForAgentSelection() async throws {
        let workspace = try WriterWorkspace(distributionEnabled: true)
        let writer = try await workspace.openWriter()
        _ = try await writer.migrateLegacy(homeURL: workspace.distributionHomeURL)

        let snapshot = try workspace.snapshot(content: "# Agent primary")
        let skillID = SkillID()
        let payload = try workspace.payload(
            skillID: skillID,
            name: "Agent Primary",
            snapshot: snapshot
        )
        _ = try await writer.create(payload: payload, sourceSnapshot: snapshot)
        let slug = payload.skill.defaultDistributionSlug
        let catalog = DistributionTargetCatalog.current(homeURL: workspace.distributionHomeURL)
        let plan = try await writer.distributionPlan(
            skillID: skillID,
            desiredConfiguration: .init(scope: .agents([.codex], slug), syncMode: .symlink),
            requiredAdapterCodes: [SkillPlatform.codex.storageKey],
            catalog: catalog
        )
        _ = try await writer.applyDistribution(skillID: skillID, plan: plan)

        let codexTarget = workspace.distributionHomeURL
            .appendingPathComponent(".codex/skills", isDirectory: true)
            .appendingPathComponent(slug.value, isDirectory: true)
        #expect(FileManager.default.fileExists(atPath: codexTarget.path))

        let globalRoot = workspace.distributionHomeURL
            .appendingPathComponent(".agents/skills", isDirectory: true)
        try FileManager.default.createDirectory(at: globalRoot, withIntermediateDirectories: true)
        let globalTarget = globalRoot.appendingPathComponent(slug.value, isDirectory: true)
        try FileManager.default.createDirectory(at: globalTarget, withIntermediateDirectories: false)
        try Data("# Agent primary".utf8).write(
            to: globalTarget.appendingPathComponent("SKILL.md"),
            options: .atomic
        )

        let audit = try await SkillConsistencyAuditService(
            writer: writer,
            homeURL: workspace.distributionHomeURL
        ).prepare()
        let observation = try #require(audit.discoveryObservations.first {
            $0.roots.contains { $0.scope.kind == .global }
                && $0.symbolicLinkIdentity == nil
        })
        #expect(observation.matchedSkillID == skillID)
        #expect(audit.manifest.discovery.occupancies.contains {
            $0.relativeLocatorKey == observation.relativeLocatorKey
                && $0.relation == .sameFingerprint
        })

        let service = HistoricalSkillMigrationService(
            writer: writer,
            homeURL: workspace.distributionHomeURL,
            nowMilliseconds: { 42 }
        )
        let preview = try await service.prepare(
            audit: audit,
            observation: observation,
            importAction: .claimExisting
        )
        #expect(preview.sourceLocator == globalTarget.standardizedFileURL.path)
        #expect(preview.targetLocator == codexTarget.standardizedFileURL.path)
        let result = try await service.confirm(preview.token)

        #expect(result.distribution.outcome == .applied)
        #expect(!FileManager.default.fileExists(atPath: globalTarget.path))
        #expect(FileManager.default.fileExists(atPath: codexTarget.path))
        #expect(try await writer.loadDistributionSelection(skillID: skillID).bindings.map(\.scope) == [.agent(.codex)])
        #expect(try workspace.integer("SELECT count(*) FROM skill_backups") == 1)
        #expect(try workspace.integer("SELECT count(*) FROM local_skill_origins") == 0)

        let finalAudit = try await SkillConsistencyAuditService(
            writer: writer,
            homeURL: workspace.distributionHomeURL
        ).prepare()
        let visibleScopes = finalAudit.discoveryObservations
            .filter { $0.relativeLocatorKey == slug.collisionKey }
            .flatMap(\.roots)
        #expect(visibleScopes.filter {
            $0.scope.kind == .agent && $0.scope.adapterCode == SkillPlatform.codex.storageKey
        }.count == 1)
        #expect(visibleScopes.filter { $0.scope.kind == .global }.isEmpty)
        #expect(visibleScopes.filter {
            $0.scope.kind == .agent && $0.scope.adapterCode != SkillPlatform.codex.storageKey
        }.isEmpty)
    }

    @Test("Codex compatibility root is cleaned without becoming a binding")
    func convergesCompatibilityRootAsSourceOnly() async throws {
        let workspace = try WriterWorkspace(distributionEnabled: true)
        let writer = try await workspace.openWriter()
        _ = try await writer.migrateLegacy(homeURL: workspace.distributionHomeURL)

        let snapshot = try workspace.snapshot(content: "# Compatibility")
        let skillID = SkillID()
        let payload = try workspace.payload(
            skillID: skillID,
            name: "Compatibility",
            snapshot: snapshot
        )
        _ = try await writer.create(payload: payload, sourceSnapshot: snapshot)
        let catalog = DistributionTargetCatalog.current(homeURL: workspace.distributionHomeURL)
        let plan = try await writer.distributionPlan(
            skillID: skillID,
            desiredConfiguration: .init(
                scope: .global(payload.skill.defaultDistributionSlug),
                syncMode: .symlink
            ),
            requiredAdapterCodes: Set(catalog.globalReaders.map(\.storageKey)),
            catalog: catalog
        )
        _ = try await writer.applyDistribution(skillID: skillID, plan: plan)

        let compatibilityRoot = workspace.distributionHomeURL
            .appendingPathComponent(".codex/skills/public", isDirectory: true)
        try FileManager.default.createDirectory(at: compatibilityRoot, withIntermediateDirectories: true)
        let compatibilityTarget = compatibilityRoot.appendingPathComponent(
            payload.skill.defaultDistributionSlug.value,
            isDirectory: true
        )
        try FileManager.default.createDirectory(at: compatibilityTarget, withIntermediateDirectories: false)
        try Data("# Compatibility".utf8).write(
            to: compatibilityTarget.appendingPathComponent("SKILL.md"),
            options: .atomic
        )

        let audit = try await SkillConsistencyAuditService(
            writer: writer,
            homeURL: workspace.distributionHomeURL
        ).prepare()
        let observation = try #require(audit.discoveryObservations.first {
            $0.roots.contains {
                $0.scope.kind == .agent
                    && $0.scope.adapterCode == SkillPlatform.codex.storageKey
                    && ($0.scope.pathVariant == ".codex/skills/public"
                        || $0.scope.pathVariant?.hasSuffix("/.codex/skills/public") == true)
            } && $0.symbolicLinkIdentity == nil
        })
        #expect(audit.manifest.discovery.occupancies.contains {
            $0.relativeLocatorKey == observation.relativeLocatorKey
                && $0.relation == .sameFingerprint
        })

        let service = HistoricalSkillMigrationService(
            writer: writer,
            homeURL: workspace.distributionHomeURL,
            nowMilliseconds: { 42 }
        )
        let preview = try await service.prepare(
            audit: audit,
            observation: observation,
            importAction: .claimExisting
        )
        #expect(preview.sourceLocator == compatibilityTarget.standardizedFileURL.path)
        #expect(
            preview.targetLocator
                == workspace.distributionHomeURL
                    .appendingPathComponent(
                        ".agents/skills/\(payload.skill.defaultDistributionSlug.value)",
                        isDirectory: true
                    )
                    .standardizedFileURL.path
        )
        let result = try await service.confirm(preview.token)

        #expect(result.distribution.outcome == .applied)
        #expect(!FileManager.default.fileExists(atPath: compatibilityTarget.path))
        #expect(try await writer.loadDistributionSelection(skillID: skillID).bindings.map(\.scope) == [.global])
        #expect(try workspace.integer("SELECT count(*) FROM distribution_bindings") == 1)
        #expect(try workspace.integer("SELECT count(*) FROM skill_backups") == 1)
        #expect(try workspace.integer("SELECT count(*) FROM local_skill_origins") == 0)
    }
}
