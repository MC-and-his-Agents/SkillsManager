import Foundation
import Testing

@testable import SkillsManager

extension SkillConsistencyViewModelTests {
    @Test("prepared audit carries the raw observation from the stable capture")
    func carriesStableRawObservation() async throws {
        let fixture = try await HistoricalMigrationFixture(content: "# Historical")
        let audit = try await SkillConsistencyAuditService(
            writer: fixture.writer,
            homeURL: fixture.workspace.distributionHomeURL
        ).prepare()
        let raw = try #require(audit.discoveryObservations.first)
        let wire = try SkillConsistencyAuditWire.discoveryObservation(raw)

        #expect(wire.managedDistributionTarget == nil)
        #expect(audit.manifest.discovery.observations.filter { $0 == wire }.count == 1)
    }

    @Test("projection exposes complete rebuild and single-scope disable actions")
    func projectsRepairActions() throws {
        let prepared = try repairPrepared(missingScopes: ["agent:codex", "agent:claude"])
        let snapshot = try SkillConsistencyPresentation.makeSnapshot(prepared)

        #expect(snapshot.status == .findings)
        #expect(snapshot.findings.count == 2)
        for finding in snapshot.findings {
            #expect(finding.actions.contains(
                .rebuildMissingSymlinks(
                    scopeKeys: ["agent:codex", "agent:claude"]
                )
            ))
            #expect(finding.actions.contains {
                if case .disableMissingBinding(let keys) = $0 {
                    return keys.count == 1
                }
                return false
            })
        }
    }

    @Test("ambiguous raw-to-wire binding is visible but cannot migrate")
    func ambiguousHistoricalCandidateFailsClosed() throws {
        let observation = try historicalObservation()
        let wire = try SkillConsistencyAuditWire.discoveryObservation(observation)
        let prepared = try prepared(
            discovery: [wire, wire],
            rawObservations: [observation]
        )

        let finding = try #require(
            SkillConsistencyPresentation.makeSnapshot(prepared).findings.first
        )

        #expect(finding.severity == .blocking)
        #expect(finding.observation == nil)
        #expect(finding.actions == [.keepForNow])
    }

    @Test("managed distribution observations never become migration candidates")
    func excludesManagedDistributionObservation() throws {
        let base = try repairPrepared(missingScopes: [])
        let observation = try historicalObservation(
            symbolicLinkIdentity: symbolicLinkIdentity()
        )
        let prepared = try addingDiscovery(observation, to: base)

        #expect(try SkillConsistencyPresentation.makeSnapshot(prepared).findings.isEmpty)
    }

    @Test("a broken bound Symlink produces only its distribution finding")
    func boundBrokenLinkIsNotAnExternalImport() throws {
        let base = try repairPrepared(missingScopes: ["global"])
        let observation = try historicalObservation(
            status: .damaged,
            reason: .symbolicLinkTargetUnavailable,
            symbolicLinkIdentity: symbolicLinkIdentity(),
            hasSnapshot: false
        )
        let snapshot = try SkillConsistencyPresentation.makeSnapshot(
            addingDiscovery(observation, to: base)
        )

        #expect(snapshot.findings.count == 1)
        #expect(snapshot.findings.allSatisfy { $0.id.hasPrefix("distribution|") })
        #expect(snapshot.findings.allSatisfy { !$0.detail.contains("external Skill link") })
    }

    @Test("a bound Symlink pointing to another Skill stays a distribution finding")
    func boundWrongTargetIsNotAnExternalImport() throws {
        let base = try repairPrepared(missingScopes: [])
        let distribution = try #require(base.manifest.distributions.first)
        let target = try #require(distribution.targets.first)
        let otherSkillID = SkillID().directoryName
        let wrongTarget = SkillConsistencyAuditDistributionTarget(
            scopeKey: target.scopeKey,
            scopeKind: target.scopeKind,
            adapterCode: target.adapterCode,
            slug: target.slug,
            slugKey: target.slugKey,
            canonicalLocator: target.canonicalLocator,
            observation: SkillConsistencyAuditTargetObservation(
                kind: "managed",
                skillID: otherSkillID,
                ssotDirectoryName: otherSkillID,
                copyState: nil,
                copyEvidence: nil
            )
        )
        let manifest = SkillConsistencyAuditManifest(
            schema: base.manifest.schema,
            coverage: base.manifest.coverage,
            health: base.manifest.health,
            root: base.manifest.root,
            managedSkills: base.manifest.managedSkills,
            distributions: [
                SkillConsistencyAuditDistribution(
                    skillID: distribution.skillID,
                    status: DistributionReconcileStatus.drifted.rawValue,
                    targets: [wrongTarget]
                ),
            ],
            discovery: base.manifest.discovery
        )
        let wrongBase = SkillConsistencyAuditPrepared(
            manifest: manifest,
            canonicalBytes: try SkillConsistencyAuditManifestCodec.encode(manifest),
            discoveryObservations: []
        )
        let observation = try historicalObservation(
            symbolicLinkIdentity: symbolicLinkIdentity()
        )
        let snapshot = try SkillConsistencyPresentation.makeSnapshot(
            addingDiscovery(observation, to: wrongBase)
        )

        #expect(snapshot.findings.count == 1)
        #expect(snapshot.findings[0].id.hasPrefix("distribution|"))
        #expect(snapshot.findings[0].detail == "The managed link points to a different Skill.")
    }

    @Test("container observations do not become audit findings")
    func excludesContainerObservation() throws {
        let observation = try historicalObservation(
            status: .damaged,
            reason: .containerDirectory
        )
        let wire = try SkillConsistencyAuditWire.discoveryObservation(observation)
        let audit = try prepared(discovery: [wire], rawObservations: [observation])

        #expect(try SkillConsistencyPresentation.makeSnapshot(audit).findings.isEmpty)
    }

    @Test("external Skill links direct imports to Discovery without migration")
    func externalSkillLinkIsImportOnly() throws {
        let observation = try historicalObservation(
            symbolicLinkIdentity: symbolicLinkIdentity()
        )
        let wire = try SkillConsistencyAuditWire.discoveryObservation(observation)
        let audit = try prepared(discovery: [wire], rawObservations: [observation])

        let finding = try #require(
            SkillConsistencyPresentation.makeSnapshot(audit).findings.first
        )

        #expect(finding.severity == .warning)
        #expect(finding.actions == [.keepForNow])
        #expect(finding.observation == nil)
        #expect(finding.detail.contains("imported from Discovery"))
        #expect(finding.detail.contains("remain unchanged"))
    }

    @Test("an imported external Skill link is omitted when consistent")
    func consistentImportedSkillLinkIsOmitted() throws {
        let observation = try historicalObservation(
            status: .managed,
            symbolicLinkIdentity: symbolicLinkIdentity(),
            matchedSkillID: SkillID()
        )
        let wire = try SkillConsistencyAuditWire.discoveryObservation(observation)
        let audit = try prepared(discovery: [wire], rawObservations: [observation])

        #expect(try SkillConsistencyPresentation.makeSnapshot(audit).findings.isEmpty)
    }

    @Test("external Skill link drift is blocking and never migrates")
    func externalSkillLinkDriftIsBlocking() throws {
        let observation = try historicalObservation(
            status: .conflict,
            reason: .localAssociationDrift,
            symbolicLinkIdentity: symbolicLinkIdentity(),
            matchedSkillID: SkillID()
        )
        let wire = try SkillConsistencyAuditWire.discoveryObservation(observation)
        let audit = try prepared(discovery: [wire], rawObservations: [observation])

        let finding = try #require(
            SkillConsistencyPresentation.makeSnapshot(audit).findings.first
        )

        #expect(finding.severity == .blocking)
        #expect(finding.actions == [.keepForNow])
        #expect(finding.observation == nil)
        #expect(finding.detail.contains("changed after it was imported"))
    }
}
