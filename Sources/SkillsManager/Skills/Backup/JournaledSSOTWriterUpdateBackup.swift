import Foundation

nonisolated struct ManagedSkillUpdateBaseline: Sendable {
    let domain: StoredSkillDomainSnapshot
    let finalIdentity: ManagedItemIdentity
    let distributionSelection: DistributionSelectionReadback
}

nonisolated struct ManagedSkillUpdateWriteResult: Sendable {
    let backup: SkillBackupRecord
    let replacement: SSOTJournalRecord
}

nonisolated enum ManagedSkillUpdateBackupError: LocalizedError, Equatable {
    case skillNotFound
    case baselineDrift
    case backupNeedsRepair

    var errorDescription: String? {
        switch self {
        case .skillNotFound:
            "The managed Skill was not found."
        case .baselineDrift:
            "The managed Skill changed while the update was being prepared."
        case .backupNeedsRepair:
            "A backup for this Skill requires repair before it can be updated."
        }
    }
}

extension JournaledSSOTWriter {
    func managedSkillUpdateBaseline(
        _ skillID: SkillID
    ) throws -> ManagedSkillUpdateBaseline {
        try requireAuthority()
        try recoverAll()
        try recoverIndependentUpdateBackups()
        try requireNoUpdateBackupRepair(skillID)
        guard let domain = try journal.storedDomain(skillID),
              let identity = try fileSystem.managedRootGuard.itemIdentity(
                at: fileSystem.finalURL(skillID: skillID)
              ) else {
            throw ManagedSkillUpdateBackupError.skillNotFound
        }
        _ = try fileSystem.captureExpectedFinal(
            skillID: skillID,
            expectedIdentity: identity,
            expectedFingerprint: domain.payload.skill.contentFingerprint
        )
        return ManagedSkillUpdateBaseline(
            domain: domain,
            finalIdentity: identity,
            distributionSelection: try loadDistributionSelection(skillID: skillID)
        )
    }

    func replaceManagedSkillWithBackup(
        expected: ManagedSkillUpdateBaseline,
        replacementPayload: SSOTSkillWritePayload,
        sourceSnapshot: SkillContentSnapshot,
        operationID: SSOTOperationID,
        backupID: SkillBackupID
    ) throws -> ManagedSkillUpdateWriteResult {
        try requireAuthority()
        let skillID = expected.domain.payload.skill.skillID
        guard replacementPayload.skill.skillID == skillID,
              replacementPayload.localOrigins.isEmpty,
              replacementPayload.skill.contentFingerprint.digest
                == sourceSnapshot.fingerprintDigest else {
            throw JournaledSSOTWriterError.invalidInput
        }
        try CopyForkAdmission(connection: connection).requireAvailable(
            skillIDs: [skillID]
        )
        try recoverAll()
        try recoverIndependentUpdateBackups()
        try requireNoUpdateBackupRepair(skillID)
        let oldSnapshot = try validateUpdateBaseline(expected)
        let backup = try publishUpdateBackup(
            baseline: expected,
            snapshot: oldSnapshot,
            backupID: backupID
        )
        try hooks.afterUpdateBackupPublished(backupID)
        _ = try validateUpdateBaseline(expected)
        let replacement = try replace(
            payload: replacementPayload,
            sourceSnapshot: sourceSnapshot,
            expectedOld: try SSOTReplacementExpectation(
                identity: expected.finalIdentity,
                fingerprint: expected.domain.payload.skill.contentFingerprint,
                databaseRevision: expected.domain.revision
            ),
            operationID: operationID
        )
        return ManagedSkillUpdateWriteResult(
            backup: backup,
            replacement: replacement
        )
    }

    func recoverIndependentUpdateBackups() throws {
        try requireAuthority()
        let store = try SkillBackupStore(connection: connection)
        for backup in try store.independentPreparing() {
            do {
                try backupFileSystem.ensurePublished(
                    backupID: backup.backupID.uuid,
                    publication: SkillBackupPublication(
                        locator: backup.locator,
                        identity: backup.directoryIdentity,
                        manifestDigest: backup.manifestDigest,
                        contentFingerprint: backup.contentFingerprint
                    )
                )
                try validateUpdateBackup(backup)
                let available = try backupReplacement(
                    backup,
                    state: .available,
                    updatedAtMilliseconds: deletionTimestamp(
                        after: backup.updatedAtMilliseconds
                    )
                )
                try requireAuthority()
                try store.replace(expected: backup, with: available)
            } catch SkillBackupFileSystemError.preparedContentMissing {
                try requireAuthority()
                try store.deletePreparingInCurrentTransaction(expected: backup)
            } catch where isUpdateBackupIntegrityError(error) {
                let repair = try backupReplacement(
                    backup,
                    state: .needsRepair,
                    lastError: String(error.localizedDescription.prefix(4_096)),
                    updatedAtMilliseconds: deletionTimestamp(
                        after: backup.updatedAtMilliseconds
                    )
                )
                try requireAuthority()
                try store.replace(expected: backup, with: repair)
            } catch {
                throw error
            }
        }
    }

    func updateBackupReadback(_ backupID: SkillBackupID) throws -> SkillBackupRecord? {
        try requireAuthority()
        try recoverIndependentUpdateBackups()
        return try SkillBackupStore(connection: connection).load(backupID)
    }

    private func validateUpdateBaseline(
        _ expected: ManagedSkillUpdateBaseline
    ) throws -> SkillContentSnapshot {
        let skillID = expected.domain.payload.skill.skillID
        guard let current = try journal.storedDomain(skillID),
              current.revision == expected.domain.revision,
              try SSOTWritePayloadCodec.encode(current.payload)
                == SSOTWritePayloadCodec.encode(expected.domain.payload),
              try fileSystem.managedRootGuard.itemIdentity(
                at: fileSystem.finalURL(skillID: skillID)
              ) == expected.finalIdentity,
              try canonicalUpdateSelection(
                loadDistributionSelection(skillID: skillID)
              ) == canonicalUpdateSelection(expected.distributionSelection) else {
            throw ManagedSkillUpdateBackupError.baselineDrift
        }
        do {
            return try fileSystem.captureExpectedFinal(
                skillID: skillID,
                expectedIdentity: expected.finalIdentity,
                expectedFingerprint: expected.domain.payload.skill.contentFingerprint
            )
        } catch SSOTOperationFileSystemError.itemChanged {
            throw ManagedSkillUpdateBackupError.baselineDrift
        }
    }

    private func publishUpdateBackup(
        baseline: ManagedSkillUpdateBaseline,
        snapshot: SkillContentSnapshot,
        backupID: SkillBackupID
    ) throws -> SkillBackupRecord {
        try publishIndependentBackup(
            domain: baseline.domain,
            selection: baseline.distributionSelection,
            snapshot: snapshot,
            backupID: backupID,
            createdAtMilliseconds: deletionTimestamp()
        )
    }

    func publishIndependentBackup(
        domain: StoredSkillDomainSnapshot,
        selection: DistributionSelectionReadback,
        snapshot: SkillContentSnapshot,
        backupID: SkillBackupID,
        createdAtMilliseconds createdAt: Int64,
        migrationMetadata: SkillBackupMigrationMetadata? = nil
    ) throws -> SkillBackupRecord {
        let skillID = domain.payload.skill.skillID
        let manifest = try SkillBackupManifestV1(
            backupID: backupID,
            payload: domain.payload,
            databaseRevision: domain.revision,
            distributionSelection: SkillBackupDistributionSelection(
                selection
            ),
            statistics: snapshot.statistics,
            createdAtMilliseconds: createdAt,
            migrationMetadata: migrationMetadata
        )
        let manifestBytes = try manifest.encoded()
        let store = try SkillBackupStore(connection: connection)
        _ = try backupFileSystem.publish(
            snapshot: snapshot,
            skillID: skillID,
            backupID: backupID.uuid,
            createdAtMilliseconds: createdAt,
            manifestBytes: manifestBytes,
            expectedFingerprint: domain.payload.skill.contentFingerprint,
            beforePromotion: { publication in
                try self.insertUpdateBackupPreparation(
                    publication: publication,
                    backupID: backupID,
                    skillID: skillID,
                    createdAtMilliseconds: createdAt
                )
            },
            afterPreparationRecorded: {},
            afterPromotion: {}
        )
        guard let preparing = try store.load(backupID),
              preparing.state == .preparing else {
            throw SkillBackupStoreError.conflict
        }
        try validateUpdateBackup(preparing)
        let available = try backupReplacement(
            preparing,
            state: .available,
            updatedAtMilliseconds: deletionTimestamp(
                after: preparing.updatedAtMilliseconds
            )
        )
        try requireAuthority()
        try store.replace(expected: preparing, with: available)
        return available
    }

    private func validateUpdateBackup(_ backup: SkillBackupRecord) throws {
        _ = try validatedBackupManifest(backup)
    }

    func validatedBackupManifest(
        _ backup: SkillBackupRecord
    ) throws -> SkillBackupManifestV1 {
        let validated = try backupFileSystem.validate(
            locator: backup.locator,
            expectedIdentity: backup.directoryIdentity,
            expectedManifestDigest: backup.manifestDigest,
            expectedFingerprint: backup.contentFingerprint
        )
        let manifest = try SkillBackupManifestV1.decode(validated.manifestBytes)
        guard manifest.backupID == backup.backupID,
              manifest.originalSkillID == backup.originalSkillID,
              manifest.contentFingerprint == backup.contentFingerprint else {
            throw SkillBackupManifestError.invalidManifest
        }
        return manifest
    }

    private func insertUpdateBackupPreparation(
        publication: SkillBackupPublication,
        backupID: SkillBackupID,
        skillID: SkillID,
        createdAtMilliseconds: Int64
    ) throws {
        try requireAuthority()
        try SkillBackupStore(connection: connection).insertPreparing(
            try SkillBackupRecord(
                backupID: backupID,
                originalSkillID: skillID,
                state: .preparing,
                locator: publication.locator,
                directoryIdentity: publication.identity,
                manifestDigest: publication.manifestDigest,
                contentFingerprint: publication.contentFingerprint,
                createdAtMilliseconds: createdAtMilliseconds,
                updatedAtMilliseconds: createdAtMilliseconds
            )
        )
    }

    private func requireNoUpdateBackupRepair(_ skillID: SkillID) throws {
        guard try SkillBackupStore(connection: connection)
            .list(originalSkillID: skillID)
            .contains(where: { $0.state == .needsRepair }) == false else {
            throw ManagedSkillUpdateBackupError.backupNeedsRepair
        }
    }
}

private nonisolated struct CanonicalUpdateSelection: Equatable {
    let isExplicitlyConfigured: Bool
    let bindingIntents: [DistributionBindingIntent]
}

private nonisolated func canonicalUpdateSelection(
    _ selection: DistributionSelectionReadback
) throws -> CanonicalUpdateSelection {
    let canonical = try SkillBackupDistributionSelection(selection)
    return CanonicalUpdateSelection(
        isExplicitlyConfigured: canonical.isExplicitlyConfigured,
        bindingIntents: canonical.bindingIntents
    )
}

private nonisolated func isUpdateBackupIntegrityError(_ error: Error) -> Bool {
    if let fileSystem = error as? SkillBackupFileSystemError {
        return switch fileSystem {
        case .invalidLocator, .destinationExists, .contentChanged,
             .manifestChanged, .itemChanged:
            true
        case .preparedContentMissing, .posix:
            false
        }
    }
    if error is SkillBackupManifestError { return true }
    if let path = error as? ManagedPathError {
        return switch path {
        case .itemNotFound, .itemChanged, .destinationAlreadyExists,
             .unsupportedItemType:
            true
        default:
            false
        }
    }
    return false
}
