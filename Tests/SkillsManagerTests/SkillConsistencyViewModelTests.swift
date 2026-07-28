import Darwin
import Foundation
import Testing

@testable import SkillsManager

@Suite("Skill consistency presentation and view model", .serialized)
struct SkillConsistencyViewModelTests {
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
        let observation = try historicalObservation()
        let wire = try SkillConsistencyAuditWire.discoveryObservation(observation)
        let manifest = SkillConsistencyAuditManifest(
            schema: base.manifest.schema,
            coverage: base.manifest.coverage,
            health: base.manifest.health,
            root: base.manifest.root,
            managedSkills: base.manifest.managedSkills,
            distributions: base.manifest.distributions,
            discovery: SkillConsistencyAuditDiscovery(
                roots: [],
                rootDiagnostics: [],
                observations: [wire]
            )
        )
        let prepared = SkillConsistencyAuditPrepared(
            manifest: manifest,
            canonicalBytes: try SkillConsistencyAuditManifestCodec.encode(manifest),
            discoveryObservations: [observation]
        )

        #expect(try SkillConsistencyPresentation.makeSnapshot(prepared).findings.isEmpty)
    }

    @Test("operation and repair states disable write actions")
    func terminalSafetyStatesDisableWrites() throws {
        let operation = try SkillConsistencyPresentation.makeSnapshot(
            repairPrepared(
                missingScopes: ["global"],
                reconcileStatus: .operationInProgress
            )
        )
        let repair = try SkillConsistencyPresentation.makeSnapshot(
            repairPrepared(
                missingScopes: ["global"],
                reconcileStatus: .needsRepair
            )
        )

        #expect(operation.status == .operationInProgress)
        #expect(!operation.allowsWrites)
        #expect(repair.status == .needsRepair)
        #expect(!repair.allowsWrites)
    }

    @MainActor
    @Test("incomplete audit disables every write action")
    func incompleteAuditDisablesWrites() async throws {
        let probe = ConsistencyDependencyProbe(
            audits: [try repairPrepared(missingScopes: ["global"], incomplete: true)]
        )
        let model = SkillConsistencyViewModel()
        model.activate(dependencies: probe.dependencies)

        await model.refresh()
        let finding = try #require(model.snapshot?.findings.first {
            $0.actions.contains(.disableMissingBinding(scopeKeys: ["global"]))
        })
        await model.prepare(
            findingID: finding.id,
            action: .disableMissingBinding(scopeKeys: ["global"])
        )

        #expect(model.snapshot?.status == .incomplete)
        #expect(model.pendingPreview == nil)
        #expect(await probe.prepareRepairCallCount == 0)
    }

    @MainActor
    @Test("duplicate confirmation produces one write and succeeds only after fresh audit")
    func duplicateConfirmIsSingleShot() async throws {
        let findingAudit = try repairPrepared(missingScopes: ["global"])
        let healthyAudit = try repairPrepared(missingScopes: [])
        let probe = ConsistencyDependencyProbe(
            audits: [findingAudit, healthyAudit],
            delaySecondAudit: true
        )
        let model = SkillConsistencyViewModel()
        model.activate(dependencies: probe.dependencies)
        await model.refresh()
        let finding = try #require(model.snapshot?.findings.first)

        await model.prepare(
            findingID: finding.id,
            action: .rebuildMissingSymlinks(scopeKeys: ["global"])
        )
        #expect(model.pendingPreview != nil)

        let first = Task { @MainActor in await model.confirmPreview() }
        while await probe.auditCallCount < 2 {
            await Task.yield()
        }
        await model.confirmPreview()
        await first.value

        #expect(await probe.confirmRepairCallCount == 1)
        #expect(model.successMessage != nil)
        #expect(model.problem == nil)
        #expect(model.snapshot?.status == .healthy)
    }

    @MainActor
    @Test("terminal write is not success when the fresh audit still contains the finding")
    func unresolvedFindingIsPartial() async throws {
        let findingAudit = try repairPrepared(missingScopes: ["global"])
        let probe = ConsistencyDependencyProbe(audits: [findingAudit, findingAudit])
        let model = SkillConsistencyViewModel()
        model.activate(dependencies: probe.dependencies)
        await model.refresh()
        let finding = try #require(model.snapshot?.findings.first)

        await model.prepare(
            findingID: finding.id,
            action: .disableMissingBinding(scopeKeys: ["global"])
        )
        await model.confirmPreview()

        #expect(await probe.confirmRepairCallCount == 1)
        #expect(model.successMessage == nil)
        #expect(model.problem?.kind == .partial)
    }

    @MainActor
    @Test("refresh expires a pending preview without a write")
    func refreshExpiresPreview() async throws {
        let findingAudit = try repairPrepared(missingScopes: ["global"])
        let probe = ConsistencyDependencyProbe(audits: [findingAudit, findingAudit])
        let model = SkillConsistencyViewModel()
        model.activate(dependencies: probe.dependencies)
        await model.refresh()
        let finding = try #require(model.snapshot?.findings.first)
        await model.prepare(
            findingID: finding.id,
            action: .disableMissingBinding(scopeKeys: ["global"])
        )

        await model.refresh()
        await model.confirmPreview()

        #expect(model.pendingPreview == nil)
        #expect(await probe.confirmRepairCallCount == 0)
    }

    @MainActor
    @Test("historical migration verifies a fresh audit before reporting success")
    func migrationRequiresFreshAudit() async throws {
        let observation = try historicalObservation()
        let wire = try SkillConsistencyAuditWire.discoveryObservation(observation)
        let findingAudit = try prepared(
            discovery: [wire],
            rawObservations: [observation]
        )
        let healthyAudit = try prepared(discovery: [], rawObservations: [])
        let probe = ConsistencyDependencyProbe(audits: [findingAudit, healthyAudit])
        let model = SkillConsistencyViewModel()
        model.activate(dependencies: probe.dependencies)
        await model.refresh()
        let finding = try #require(model.snapshot?.findings.first)

        await model.prepare(
            findingID: finding.id,
            action: .migrate(importAction: .importNew, independent: false)
        )
        await model.confirmPreview()

        #expect(await probe.confirmMigrationCallCount == 1)
        #expect(model.successMessage != nil)
        #expect(model.snapshot?.status == .healthy)
    }

    @MainActor
    @Test("conflict import preview preserves independent Skill identity semantics")
    func conflictPreviewNamesIndependentIdentity() async throws {
        let observation = try historicalObservation(
            status: .conflict,
            reason: .ambiguousSource
        )
        let wire = try SkillConsistencyAuditWire.discoveryObservation(observation)
        let audit = try prepared(
            discovery: [wire],
            rawObservations: [observation]
        )
        let probe = ConsistencyDependencyProbe(audits: [audit])
        let model = SkillConsistencyViewModel()
        model.activate(dependencies: probe.dependencies)
        await model.refresh()
        let finding = try #require(model.snapshot?.findings.first)

        await model.prepare(
            findingID: finding.id,
            action: .migrate(importAction: .importNew, independent: true)
        )

        #expect(
            model.pendingPreview?.title
                == "Import as independent Skill, back up and migrate"
        )
        #expect(
            model.pendingPreview?.details.contains(
                "Identity: new independent Skill UUID"
            ) == true
        )
    }
}

private actor ConsistencyDependencyProbe {
    private var audits: [SkillConsistencyAuditPrepared]
    private let delaySecondAudit: Bool
    private(set) var auditCallCount = 0
    private(set) var prepareRepairCallCount = 0
    private(set) var confirmRepairCallCount = 0
    private(set) var confirmMigrationCallCount = 0

    init(
        audits: [SkillConsistencyAuditPrepared],
        delaySecondAudit: Bool = false
    ) {
        self.audits = audits
        self.delaySecondAudit = delaySecondAudit
    }

    nonisolated var dependencies: SkillConsistencyDependencies {
        SkillConsistencyDependencies(
            audit: {
                try await self.nextAudit()
            },
            prepareRepair: { skillID, action in
                await self.recordPrepareRepair()
                return SkillConsistencyRepairPreview(
                    confirmationID: UUID(),
                    skillID: skillID,
                    action: action,
                    auditCanonicalBytes: Data(),
                    selectionToken: Data(),
                    planCanonicalBytes: Data()
                )
            },
            confirmRepair: { _ in
                await self.recordConfirmRepair()
                return .applied(SSOTOperationID())
            },
            prepareMigration: { _, observation, _ in
                return HistoricalSkillMigrationPreview(
                    token: HistoricalSkillMigrationToken(),
                    skillID: observation.matchedSkillID ?? SkillID(),
                    sourceScope: .global,
                    sourceLocator: "~/.agents/skills/demo",
                    targetLocator: "~/.agents/skills/demo",
                    backupID: SkillBackupID(),
                    operationID: SSOTOperationID(),
                    ssotAbsoluteTarget: "/tmp/.SkillsManager/skills/demo",
                    ssotIdentity: nil,
                    canonicalAudit: Data(),
                    canonicalPlan: Data()
                )
            },
            confirmMigration: { _ in
                await self.recordConfirmMigration()
            }
        )
    }

    private func nextAudit() async throws -> SkillConsistencyAuditPrepared {
        auditCallCount += 1
        if delaySecondAudit, auditCallCount == 2 {
            try await Task.sleep(for: .milliseconds(50))
        }
        guard !audits.isEmpty else { throw SkillConsistencyAuditError.sourceChanged }
        if audits.count == 1 { return audits[0] }
        return audits.removeFirst()
    }

    private func recordPrepareRepair() {
        prepareRepairCallCount += 1
    }

    private func recordConfirmRepair() {
        confirmRepairCallCount += 1
    }

    private func recordConfirmMigration() {
        confirmMigrationCallCount += 1
    }
}

private func repairPrepared(
    missingScopes: Set<String>,
    incomplete: Bool = false,
    reconcileStatus: DistributionReconcileStatus? = nil
) throws -> SkillConsistencyAuditPrepared {
    let skillID = SkillID(UUID(uuidString: "00000000-0000-0000-0000-000000000111")!)
    let slug = try DefaultDistributionSlug(validating: "demo")
    let fingerprint = try SkillContentFingerprint(
        currentDigest: Data(repeating: 1, count: 32)
    )
    let record = try ManagedSkillRecord(
        skillID: skillID,
        displayName: SkillDisplayName("Demo"),
        defaultDistributionSlug: slug,
        contentFingerprint: fingerprint,
        createdAtMilliseconds: 1,
        updatedAtMilliseconds: 1
    )
    let payload = try SSOTWritePayloadCodec.encode(
        SSOTSkillWritePayload(skill: record)
    )
    let scopes = missingScopes.isEmpty ? ["global"] : missingScopes.sorted()
    let bindings = scopes.map { scope in
        SkillConsistencyAuditBinding(
            skillID: skillID.directoryName,
            scopeKey: scope,
            scopeKind: scope == "global" ? "global" : "agent",
            adapterCode: scope.hasPrefix("agent:")
                ? String(scope.dropFirst("agent:".count))
                : nil,
            slug: slug.value,
            slugKey: slug.collisionKey,
            syncMode: DistributionSyncMode.symlink.rawValue,
            copyBaseline: nil,
            createdAtMilliseconds: 1,
            updatedAtMilliseconds: 1
        )
    }
    let targets = bindings.map { binding in
        SkillConsistencyAuditDistributionTarget(
            scopeKey: binding.scopeKey,
            scopeKind: binding.scopeKind,
            adapterCode: binding.adapterCode,
            slug: binding.slug,
            slugKey: binding.slugKey,
            canonicalLocator: "~/.agents/skills/\(slug.value)",
            observation: missingScopes.contains(binding.scopeKey)
                ? .init(
                    kind: "missing",
                    skillID: nil,
                    ssotDirectoryName: nil,
                    copyState: nil,
                    copyEvidence: nil
                )
                : .init(
                    kind: "managed",
                    skillID: skillID.directoryName,
                    ssotDirectoryName: skillID.directoryName,
                    copyState: nil,
                    copyEvidence: nil
                )
        )
    }
    let diagnostic = SkillConsistencyAuditRootDiagnostic(
        root: auditRoot(),
        reason: SkillDiscoveryReason.rootReadFailed.rawValue
    )
    let manifest = SkillConsistencyAuditManifest(
        schema: "skills-manager-consistency-audit/v1",
        coverage: incomplete ? .incomplete : .complete,
        health: [],
        root: managedRoot(),
        managedSkills: [
            SkillConsistencyAuditManagedSkill(
                skillID: skillID.directoryName,
                revision: 1,
                payload: payload,
                bindings: bindings
            ),
        ],
        distributions: [
            SkillConsistencyAuditDistribution(
                skillID: skillID.directoryName,
                status: (reconcileStatus
                    ?? (missingScopes.isEmpty ? .inSync : .drifted)).rawValue,
                targets: targets
            ),
        ],
        discovery: SkillConsistencyAuditDiscovery(
            roots: [],
            rootDiagnostics: incomplete ? [diagnostic] : [],
            observations: []
        )
    )
    return SkillConsistencyAuditPrepared(
        manifest: manifest,
        canonicalBytes: try SkillConsistencyAuditManifestCodec.encode(manifest),
        discoveryObservations: []
    )
}

private func historicalObservation(
    status: SkillDiscoveryStatus = .unmanaged,
    reason: SkillDiscoveryReason? = nil
) throws -> SkillDiscoveryObservation {
    let identity = ManagedItemIdentity(
        persistedComponents: .init(
            device: 1,
            inode: 2,
            fileType: UInt32(S_IFDIR),
            generation: 0
        )
    )
    let root = SkillDiscoveryRoot(
        scope: .global,
        url: URL(fileURLWithPath: "/tmp/.agents/skills", isDirectory: true)
    )
    return SkillDiscoveryObservation(
        roots: [root],
        rootIdentity: identity,
        rawRelativeLocator: "demo",
        relativeLocator: "demo",
        relativeLocatorKey: "demo",
        candidateIdentity: identity,
        fingerprint: try SkillContentFingerprint(
            currentDigest: Data(repeating: 2, count: 32)
        ),
        providerAliases: [],
        status: status,
        reason: reason,
        matchedSkillID: nil,
        matchedSourceKey: nil
    )
}

private func prepared(
    discovery: [SkillConsistencyAuditDiscoveryObservation],
    rawObservations: [SkillDiscoveryObservation]
) throws -> SkillConsistencyAuditPrepared {
    let manifest = SkillConsistencyAuditManifest(
        schema: "skills-manager-consistency-audit/v1",
        coverage: .complete,
        health: [],
        root: managedRoot(),
        managedSkills: [],
        distributions: [],
        discovery: SkillConsistencyAuditDiscovery(
            roots: [],
            rootDiagnostics: [],
            observations: discovery
        )
    )
    return SkillConsistencyAuditPrepared(
        manifest: manifest,
        canonicalBytes: try SkillConsistencyAuditManifestCodec.encode(manifest),
        discoveryObservations: rawObservations
    )
}

private func managedRoot() -> SkillConsistencyAuditManagedRoot {
    SkillConsistencyAuditManagedRoot(
        registeredLocator: "/tmp/.SkillsManager/skills",
        canonicalLocator: "/tmp/.SkillsManager/skills",
        identity: Data([1])
    )
}

private func auditRoot() -> SkillConsistencyAuditDiscoveryRoot {
    SkillConsistencyAuditDiscoveryRoot(
        scopeKey: "global",
        kind: "global",
        adapterCode: nil,
        pathVariant: nil,
        customPathID: nil,
        locator: "/tmp/.agents/skills"
    )
}
