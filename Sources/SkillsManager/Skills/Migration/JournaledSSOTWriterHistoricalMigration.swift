import Foundation

extension JournaledSSOTWriter {
    func historicalMigrationSSOTExpectation(
        skillID: SkillID,
        requiresExisting: Bool
    ) throws -> HistoricalSkillMigrationSSOTExpectation {
        try requireAuthority()
        let target = fileSystem.finalURL(skillID: skillID).standardizedFileURL.path
        if requiresExisting {
            return .existing(
                try historicalMigrationSSOTEvidence(
                    skillID: skillID,
                    expectedAbsoluteTarget: target
                )
            )
        }
        guard try fileSystem.managedRootGuard.itemIdentity(
            at: fileSystem.finalURL(skillID: skillID)
        ) == nil else {
            throw HistoricalSkillMigrationError.stalePreview
        }
        return .absent(absoluteTarget: target)
    }

    func requireHistoricalMigrationSSOTExpectation(
        _ expectation: HistoricalSkillMigrationSSOTExpectation,
        skillID: SkillID
    ) throws -> DistributionCopySourceEvidence? {
        try requireAuthority()
        switch expectation {
        case .absent(let absoluteTarget):
            guard fileSystem.finalURL(skillID: skillID).standardizedFileURL.path
                    == absoluteTarget,
                  try fileSystem.managedRootGuard.itemIdentity(
                    at: fileSystem.finalURL(skillID: skillID)
                  ) == nil else {
                throw HistoricalSkillMigrationError.stalePreview
            }
            return nil
        case .existing(let expected):
            let current = try historicalMigrationSSOTEvidence(
                skillID: skillID,
                expectedAbsoluteTarget: expected.absoluteTarget
            )
            guard current == expected else {
                throw HistoricalSkillMigrationError.stalePreview
            }
            return current
        }
    }

    func historicalMigrationSSOTEvidence(
        skillID: SkillID,
        expectedAbsoluteTarget: String
    ) throws -> DistributionCopySourceEvidence {
        try requireAuthority()
        let evidence = try copyDistribution.fileSystem.copySource(
            for: skillID
        ).decisionEvidence()
        guard evidence.absoluteTarget == expectedAbsoluteTarget else {
            throw HistoricalSkillMigrationError.stalePreview
        }
        return evidence
    }

    func historicalMigrationPlan(
        skillID: SkillID,
        scope: DistributionBindingScope,
        slug: DefaultDistributionSlug
    ) throws -> DistributionPlan {
        try requireAuthority()
        let selection = try loadDistributionSelection(skillID: skillID)
        let ownership = try DistributionLinkOwnershipStore(connection: connection)
            .load(skillID: skillID)
        guard selection.bindings.isEmpty, ownership.isEmpty,
              let entry = DistributionTargetCatalog.current.entry(for: scope, slug: slug) else {
            throw HistoricalSkillMigrationError.invalidSelection
        }
        let desired = DistributionBindingIntent(
            skillID: skillID,
            scope: scope,
            distributionSlug: slug,
            syncMode: .symlink
        )
        return DistributionPlan(
            status: .executable,
            filesystemActions: [
                DistributionFilesystemAction(
                    kind: .replaceCopyWithSymlink,
                    entry: entry,
                    ssotLocator: DistributionTargetCatalog.current.ssotLocator(for: skillID)
                ),
            ],
            bindingsChanged: true,
            bindingReplacement: [desired],
            configurationChanged: !selection.isExplicitlyConfigured,
            expectedOldConfigured: selection.isExplicitlyConfigured,
            desiredConfigured: true,
            conflicts: []
        )
    }

    func captureHistoricalMigrationSource(
        _ source: HistoricalSkillMigrationSource
    ) throws -> DistributionCopyCapture {
        try requireAuthority()
        guard let entry = try historicalMigrationEntry(source) else {
            throw HistoricalSkillMigrationError.invalidSelection
        }
        let capture = try copyDistribution.fileSystem.captureCopy(
            entry,
            expectedRootIdentity: source.rootIdentity,
            expectedEntryIdentity: source.candidateIdentity
        )
        guard capture.evidence.contentFingerprint == source.fingerprint else {
            throw HistoricalSkillMigrationError.sourceChanged
        }
        return capture
    }

    func existingHistoricalMigrationBackup(
        skillID: SkillID,
        source: HistoricalSkillMigrationSource
    ) throws -> HistoricalSkillMigrationExistingBackup? {
        try requireAuthority()
        try recoverIndependentUpdateBackups()
        let matches = try SkillBackupStore(connection: connection)
            .list(originalSkillID: skillID)
            .compactMap { backup -> (SkillBackupRecord, SkillBackupMigrationMetadata)? in
                guard backup.state == .available else { return nil }
                let manifest = try validatedBackupManifest(backup)
                guard let metadata = manifest.migrationMetadata,
                      metadata.sourceScope == source.scope,
                      metadata.rawLocator == source.rawLocator,
                      metadata.normalizedLocator == source.normalizedLocator,
                      metadata.rootIdentity == source.rootIdentity,
                      metadata.candidateIdentity == source.candidateIdentity,
                      metadata.fingerprint == source.fingerprint else {
                    return nil
                }
                return (backup, metadata)
            }
        guard matches.count <= 1 else {
            throw HistoricalSkillMigrationError.needsRepair
        }
        guard let (backup, metadata) = matches.first else { return nil }
        let operationID: SSOTOperationID
        do {
            let operation = try copyDistribution.operationStore.load(metadata.operationID)
            if operation.phase == .completed, operation.outcome == .rolledBack {
                operationID = SSOTOperationID()
            } else if operation.outcome == .needsRepair {
                throw HistoricalSkillMigrationError.needsRepair
            } else {
                operationID = metadata.operationID
            }
        } catch DistributionOperationStoreError.operationNotFound {
            operationID = metadata.operationID
        }
        return HistoricalSkillMigrationExistingBackup(
            backup: backup,
            metadata: metadata,
            operationID: operationID
        )
    }

    func performHistoricalMigration(
        skill: ManagedSkillRecord,
        request: HistoricalSkillMigrationRequest
    ) throws -> HistoricalSkillMigrationResult {
        try requireAuthority()
        try recoverAll()
        try recoverIndependentUpdateBackups()
        try copyDistribution.recoverAll()
        let currentSSOT = try historicalMigrationSSOTEvidence(
            skillID: request.skillID,
            expectedAbsoluteTarget: request.ssotEvidence.absoluteTarget
        )
        guard skill.skillID == request.skillID,
              currentSSOT == request.ssotEvidence,
              let domain = try journal.storedDomain(request.skillID),
              domain.payload.skill == skill,
              domain.payload.skill.contentFingerprint == request.source.fingerprint,
              try hasExactHistoricalOrigin(domain.payload, source: request.source) else {
            throw HistoricalSkillMigrationError.sourceChanged
        }
        let plan = try historicalMigrationPlan(
            skillID: request.skillID,
            scope: request.source.scope,
            slug: DefaultDistributionSlug(validating: request.source.normalizedLocator)
        )
        guard try plan.canonicalJSONData() == request.canonicalPlan,
              try request.plan.canonicalJSONData() == request.canonicalPlan else {
            throw HistoricalSkillMigrationError.stalePreview
        }
        let capture = try captureHistoricalMigrationSource(request.source)
        let selection = try loadDistributionSelection(skillID: request.skillID)
        let metadata = try SkillBackupMigrationMetadata(
            operationID: request.operationID,
            sourceScope: request.source.scope,
            rawLocator: request.source.rawLocator,
            normalizedLocator: request.source.normalizedLocator,
            rootIdentity: request.source.rootIdentity,
            candidateIdentity: request.source.candidateIdentity,
            fingerprint: request.source.fingerprint,
            createdAtMilliseconds: request.createdAtMilliseconds
        )
        let backup: SkillBackupRecord
        do {
            backup = try ensureHistoricalMigrationBackup(
                domain: domain,
                selection: selection,
                capture: capture,
                request: request,
                metadata: metadata
            )
        } catch let problem as HistoricalSkillMigrationError {
            throw problem
        } catch let backup as SkillBackupFileSystemError {
            throw backup
        } catch let manifest as SkillBackupManifestError {
            throw manifest
        } catch let store as SkillBackupStoreError {
            throw store
        } catch {
            throw HistoricalSkillMigrationError.backupUnavailable
        }
        try hooks.historicalMigrationBackupPublished(request.skillID)
        let currentSSOTAfterBackup = try historicalMigrationSSOTEvidence(
            skillID: request.skillID,
            expectedAbsoluteTarget: request.ssotEvidence.absoluteTarget
        )
        guard currentSSOTAfterBackup == request.ssotEvidence else {
            throw HistoricalSkillMigrationError.stalePreview
        }
        let current = try captureHistoricalMigrationSource(request.source)
        guard current.evidence == capture.evidence else {
            throw HistoricalSkillMigrationError.sourceChanged
        }
        let approval = DistributionHistoricalMigrationApproval(
            source: current.evidence,
            backup: backup,
            metadata: try validatedBackupManifest(backup).migrationMetadata
                ?? metadata
        )
        let operation = try applyOrReadHistoricalMigration(
            request: request,
            plan: plan,
            approval: approval
        )
        guard operation.phase == .completed, operation.outcome == .applied,
              try copyDistribution.reconcile(skillID: request.skillID).status == .inSync else {
            throw HistoricalSkillMigrationError.needsRepair
        }
        return HistoricalSkillMigrationResult(
            skill: skill,
            backup: backup,
            distribution: operation
        )
    }

    private func ensureHistoricalMigrationBackup(
        domain: StoredSkillDomainSnapshot,
        selection: DistributionSelectionReadback,
        capture: DistributionCopyCapture,
        request: HistoricalSkillMigrationRequest,
        metadata: SkillBackupMigrationMetadata
    ) throws -> SkillBackupRecord {
        if let existing = try existingHistoricalMigrationBackup(
            skillID: request.skillID,
            source: request.source
        ) {
            return existing.backup
        }
        return try publishIndependentBackup(
            domain: domain,
            selection: selection,
            snapshot: capture.snapshot,
            backupID: request.backupID,
            createdAtMilliseconds: request.createdAtMilliseconds,
            migrationMetadata: metadata
        )
    }

    private func applyOrReadHistoricalMigration(
        request: HistoricalSkillMigrationRequest,
        plan: DistributionPlan,
        approval: DistributionHistoricalMigrationApproval
    ) throws -> DistributionOperationRecord {
        do {
            let existing = try copyDistribution.operationStore.load(request.operationID)
            guard existing.skillID == request.skillID,
                  existing.planPayload == request.canonicalPlan else {
                throw HistoricalSkillMigrationError.needsRepair
            }
            if existing.phase == .completed, existing.outcome == .applied {
                return existing
            }
            if existing.phase == .completed || existing.outcome == .needsRepair {
                throw HistoricalSkillMigrationError.needsRepair
            }
            try copyDistribution.recoverAll()
            return try copyDistribution.operationStore.load(request.operationID)
        } catch DistributionOperationStoreError.operationNotFound {
            return try copyDistribution.apply(
                skillID: request.skillID,
                plan: plan,
                expectedOldBindings: [],
                approvedCopySource: request.ssotEvidence,
                approvedHistoricalMigration: approval,
                operationID: request.operationID,
                nowMilliseconds: request.createdAtMilliseconds
            )
        }
    }

    private func hasExactHistoricalOrigin(
        _ payload: SSOTSkillWritePayload,
        source: HistoricalSkillMigrationSource
    ) throws -> Bool {
        payload.localOrigins.contains {
            $0.scope == source.discoveryScope
                && $0.rawLocator == source.rawLocator
                && $0.normalizedLocator == source.normalizedLocator
                && $0.collisionKey == SkillContentPath.collisionKey(
                    for: source.normalizedLocator
                )
                && $0.fingerprint == source.fingerprint
        }
    }

    private func historicalMigrationEntry(
        _ source: HistoricalSkillMigrationSource
    ) throws -> DistributionTargetEntry? {
        let slug = try DefaultDistributionSlug(validating: source.normalizedLocator)
        return DistributionTargetCatalog.current.entry(for: source.scope, slug: slug)
    }
}
