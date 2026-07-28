import Foundation

nonisolated extension DistributionCopyExecutor {
    func requireHistoricalMigrationApproval(
        _ approval: DistributionHistoricalMigrationApproval,
        action: DistributionFilesystemAction,
        operationID: SSOTOperationID
    ) throws {
        let wire = try DistributionHistoricalMigrationBackupWireV2(approval.backup)
        try requireHistoricalMigrationBackup(
            action: action,
            backupWire: wire,
            source: approval.source,
            operationID: operationID
        )
        guard approval.metadata.sourceScope == action.entry.target.scope,
              approval.metadata.rawLocator == action.entry.distributionSlug.value,
              approval.metadata.normalizedLocator == action.entry.distributionSlug.value,
              approval.metadata.rootIdentity == approval.source.rootIdentity,
              approval.metadata.candidateIdentity == approval.source.entryIdentity,
              approval.metadata.fingerprint == approval.source.contentFingerprint else {
            throw DistributionSymlinkExecutorError.conflict
        }
    }

    func requireHistoricalMigrationBackups(
        plan: DistributionPlan,
        preflight: DistributionOperationPreflightV2,
        operationID: SSOTOperationID
    ) throws {
        guard plan.filesystemActions.count == preflight.actions.count else {
            throw DistributionSymlinkExecutorError.needsRepair(
                "historical migration preflight is incomplete"
            )
        }
        for (action, persisted) in zip(plan.filesystemActions, preflight.actions) {
            try requireHistoricalMigrationBackup(
                action: action,
                preflightAction: persisted,
                operationID: operationID
            )
        }
    }

    func requireHistoricalMigrationBackup(
        action: DistributionFilesystemAction,
        preflightAction: DistributionOperationPreflightActionV2,
        operationID: SSOTOperationID
    ) throws {
        guard let wire = preflightAction.historicalMigrationBackup else { return }
        guard let oldCopy = try preflightAction.oldCopy?.evidence() else {
            throw DistributionSymlinkExecutorError.needsRepair(
                "historical migration source evidence is missing"
            )
        }
        try requireHistoricalMigrationBackup(
            action: action,
            backupWire: wire,
            source: oldCopy,
            operationID: operationID
        )
    }

    private func requireHistoricalMigrationBackup(
        action: DistributionFilesystemAction,
        backupWire: DistributionHistoricalMigrationBackupWireV2,
        source: DistributionCopyEvidence,
        operationID: SSOTOperationID
    ) throws {
        guard let backupFileSystem,
              let backupUUID = UUID(uuidString: backupWire.backupID),
              backupUUID.uuidString.lowercased() == backupWire.backupID,
              let backup = try backupStore.load(SkillBackupID(backupUUID)),
              backup.state == .available,
              backup.locator == backupWire.locator,
              try ManagedItemIdentityCodec.decode(backupWire.directoryIdentity)
                == backup.directoryIdentity,
              backup.manifestDigest == backupWire.manifestDigest,
              backup.contentFingerprint == source.contentFingerprint,
              action.ssotLocator == DistributionTargetCatalog.current.ssotLocator(
                for: backup.originalSkillID
              ) else {
            throw HistoricalSkillMigrationError.backupUnavailable
        }
        let validated = try backupFileSystem.validate(
            locator: backup.locator,
            expectedIdentity: backup.directoryIdentity,
            expectedManifestDigest: backup.manifestDigest,
            expectedFingerprint: backup.contentFingerprint
        )
        let manifest = try SkillBackupManifestV1.decode(validated.manifestBytes)
        guard manifest.backupID == backup.backupID,
              manifest.originalSkillID == backup.originalSkillID,
              manifest.contentFingerprint == backup.contentFingerprint,
              manifest.distributionSelection.bindingIntents.isEmpty,
              let metadata = manifest.migrationMetadata,
              try historicalMigrationOperationMatches(
                metadata.operationID,
                current: operationID,
                skillID: backup.originalSkillID
              ),
              metadata.sourceScope == action.entry.target.scope,
              metadata.rawLocator == action.entry.distributionSlug.value,
              metadata.normalizedLocator == action.entry.distributionSlug.value,
              metadata.rootIdentity == source.rootIdentity,
              metadata.candidateIdentity == source.entryIdentity,
              metadata.fingerprint == source.contentFingerprint else {
            throw HistoricalSkillMigrationError.backupUnavailable
        }
    }

    private func historicalMigrationOperationMatches(
        _ recorded: SSOTOperationID,
        current: SSOTOperationID,
        skillID: SkillID
    ) throws -> Bool {
        if recorded == current { return true }
        let previous = try operationStore.load(recorded)
        return previous.skillID == skillID
            && previous.phase == .completed
            && previous.outcome == .rolledBack
    }
}
