import Foundation

actor SkillConsistencyAuditService {
    private struct Capture: Sendable {
        let manifest: SkillConsistencyAuditManifest
        let discoveryObservations: [SkillDiscoveryObservation]
    }

    private let writer: JournaledSSOTWriter
    private let homeURL: URL
    private let betweenCaptures: @Sendable () async throws -> Void

    init(
        writer: JournaledSSOTWriter,
        homeURL: URL = FileManager.default.homeDirectoryForCurrentUser,
        betweenCaptures: @escaping @Sendable () async throws -> Void = {}
    ) {
        self.writer = writer
        self.homeURL = homeURL
        self.betweenCaptures = betweenCaptures
    }

    func prepare() async throws -> SkillConsistencyAuditPrepared {
        do {
            try Task.checkCancellation()
            let first = try await Self.capture(writer: writer, homeURL: homeURL)
            let firstBytes = try SkillConsistencyAuditManifestCodec.encode(first.manifest)
            try await betweenCaptures()
            try Task.checkCancellation()
            let second = try await Self.capture(writer: writer, homeURL: homeURL)
            let secondBytes = try SkillConsistencyAuditManifestCodec.encode(second.manifest)
            guard firstBytes == secondBytes else {
                throw SkillConsistencyAuditError.sourceChanged
            }
            return SkillConsistencyAuditPrepared(
                manifest: second.manifest,
                canonicalBytes: secondBytes,
                discoveryObservations: second.discoveryObservations
            )
        } catch is CancellationError {
            throw CancellationError()
        } catch let error as SkillConsistencyAuditError {
            throw error
        } catch {
            throw SkillConsistencyAuditWire.stableError(error)
        }
    }

    private static func capture(
        writer: JournaledSSOTWriter,
        homeURL: URL
    ) async throws -> Capture {
        try Task.checkCancellation()
        let healthDiagnostics = try await writer.healthDiagnostics()
        try Task.checkCancellation()
        let catalog = try await writer.discoveryCatalog()
        try Task.checkCancellation()
        let managed = try await writer.managedLocalCatalogReadback()
        try Task.checkCancellation()

        let managedByID = try validate(catalog: catalog, managed: managed)
        let skillIDs = catalog.managedSkills.map(\.skillID)
            .sorted(by: SkillConsistencyAuditWire.skillIDPrecedes)
        var managedSkills: [SkillConsistencyAuditManagedSkill] = []
        var distributions: [SkillConsistencyAuditDistribution] = []
        var bindingsBySkillID: [SkillID: [DistributionBinding]] = [:]
        var reconcileBySkillID: [SkillID: DistributionReconcileResult] = [:]

        for skillID in skillIDs {
            try Task.checkCancellation()
            guard let local = managedByID[skillID],
                  let domain = try await writer.storedDomainReadback(skillID),
                  domain.payload.skill.skillID == skillID,
                  domain.payload.skill == local.skill,
                  domain.payload.providerProvenance == local.providerProvenance else {
                throw SkillConsistencyAuditError.inconsistentCatalog
            }
            managedSkills.append(try SkillConsistencyAuditWire.managedSkill(
                skillID: skillID,
                domain: domain,
                bindings: local.bindings
            ))
            bindingsBySkillID[skillID] = local.bindings

            try Task.checkCancellation()
            let reconcile = try await writer.reconcileDistribution(skillID: skillID)
            reconcileBySkillID[skillID] = reconcile
            distributions.append(
                try SkillConsistencyAuditWire.distribution(
                    skillID: skillID,
                    result: reconcile
                )
            )
        }

        try Task.checkCancellation()
        let customPaths = try await writer.loadCustomPaths().map(customPath)
        try Task.checkCancellation()
        let targetCatalog = await writer.currentDistributionCatalog()
        let discoveryResult = try SkillDiscoveryScanner().scan(
            roots: SkillDiscoveryRootPlan.make(
                homeURL: homeURL,
                customPaths: customPaths,
                catalog: targetCatalog
            ),
            catalog: catalog,
            checkpoint: { try Task.checkCancellation() }
        )
        try Task.checkCancellation()

        let root = try managed.root.verifiedRoot()
        return Capture(
            manifest: SkillConsistencyAuditManifest(
                schema: "skills-manager-consistency-audit/v1",
                coverage: discoveryResult.rootDiagnostics.isEmpty ? .complete : .incomplete,
                health: LibraryRuntimeDiagnostic.normalized(healthDiagnostics)
                    .map(SkillConsistencyAuditWire.health),
                root: SkillConsistencyAuditManagedRoot(
                    registeredLocator: SkillConsistencyAuditWire.locator(managed.root.registeredURL),
                    canonicalLocator: SkillConsistencyAuditWire.locator(managed.root.canonicalURL),
                    identity: try ManagedItemIdentityCodec.encode(root.identity)
                ),
                managedSkills: managedSkills,
                distributions: distributions,
                discovery: try SkillConsistencyAuditWire.discovery(
                    discoveryResult,
                    homeURL: homeURL,
                    bindingsBySkillID: bindingsBySkillID,
                    reconcileBySkillID: reconcileBySkillID,
                    catalog: targetCatalog
                )
            ),
            discoveryObservations: discoveryResult.observations
        )
    }

    private static func validate(
        catalog: SkillDiscoveryCatalog,
        managed: ManagedLocalCatalogReadback
    ) throws -> [SkillID: ManagedLocalSkillReadback] {
        let authorityIDs = catalog.managedSkills.map(\.skillID)
        guard Set(authorityIDs).count == authorityIDs.count else {
            throw SkillConsistencyAuditError.inconsistentCatalog
        }
        let groups = Dictionary(grouping: managed.skills, by: { $0.skill.skillID })
        guard groups.count == authorityIDs.count,
              Set(groups.keys) == Set(authorityIDs),
              groups.values.allSatisfy({ $0.count == 1 }) else {
            throw SkillConsistencyAuditError.inconsistentCatalog
        }
        return groups.mapValues { $0[0] }
    }

    private static func customPath(_ record: SQLiteCustomPathRecord) -> CustomSkillPath {
        CustomSkillPath(
            id: record.id,
            url: record.url,
            displayName: record.displayName,
            addedAt: Date(timeIntervalSince1970: Double(record.addedAtMilliseconds) / 1_000),
            mode: record.mode
        )
    }
}
