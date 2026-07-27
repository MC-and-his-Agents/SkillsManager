import Darwin
import Foundation
import Synchronization
import Testing

@testable import SkillsManager

@Suite("Journaled SSOT Skill deletion", .serialized)
struct JournaledSSOTWriterDeletionTests {
    private enum Stop: Error { case requested }

    @Test("maps lifecycle failures to stable public errors")
    func mapsStableErrors() {
        #expect(throws: SkillDeletionError.permissionDenied) {
            try withStableSkillLifecycleErrors(.mutation) {
                throw SkillBackupFileSystemError.posix(operation: "test", code: EACCES)
            }
        }
        #expect(throws: SkillDeletionError.unavailable) {
            try withStableSkillLifecycleErrors(.mutation) {
                throw DistributionSymlinkFileSystemError.unavailable
            }
        }
        #expect(throws: SkillDeletionError.backupCorrupt) {
            try withStableSkillLifecycleErrors(.backupRead) {
                throw SkillBackupFileSystemError.manifestChanged
            }
        }
        #expect(throws: SkillDeletionError.conflict) {
            try withStableSkillLifecycleErrors(.mutation) {
                throw ManagedPathError.itemChanged
            }
        }
    }

    @Test("maps domain and persistence failures to stable public errors")
    func mapsStableDomainErrors() {
        #expect(throws: SkillDeletionError.conflict) {
            try withStableSkillLifecycleErrors(.mutation) {
                throw SkillBackupStoreError.conflict
            }
        }
        #expect(throws: SkillDeletionError.backupCorrupt) {
            try withStableSkillLifecycleErrors(.backupRead) {
                throw SkillBackupManifestError.invalidManifest
            }
        }
        #expect(throws: SkillDeletionError.needsRepair) {
            try withStableSkillLifecycleErrors(.mutation) {
                throw SkillDeletionOperationStoreError.corruptRecord
            }
        }
        #expect(throws: SkillDeletionError.backupCorrupt) {
            try withStableSkillLifecycleErrors(.backupRead) {
                throw SSOTWritePayloadError.invalidPayload
            }
        }
        #expect(throws: SkillDeletionError.conflict) {
            try withStableSkillLifecycleErrors(.mutation) {
                throw SSOTJournalStoreError.stateConflict
            }
        }
        #expect(throws: SkillDeletionError.needsRepair) {
            try withStableSkillLifecycleErrors(.mutation) {
                throw JournaledSSOTWriterError.operationNeedsRepair(
                    SSOTOperationID(),
                    .journalMarkedNeedsRepair
                )
            }
        }
    }

    @Test("deletes only after a valid backup and restores idempotently")
    func deletesAndRestores() async throws {
        let workspace = try WriterWorkspace()
        let writer = try await workspace.openWriter()
        let snapshot = try workspace.snapshot(content: "recoverable")
        let skillID = SkillID()
        _ = try await writer.create(
            payload: workspace.payload(
                skillID: skillID,
                name: "Recoverable",
                snapshot: snapshot
            ),
            sourceSnapshot: snapshot
        )

        let deletion = try await deleteManagedSkill(writer, skillID: skillID)
        #expect(deletion.status == .completed)
        #expect(try workspace.integer("SELECT count(*) FROM skills") == 0)
        #expect(!FileManager.default.fileExists(
            atPath: workspace.root.appendingPathComponent(skillID.directoryName).path
        ))

        let backups = try await writer.listBackups(originalSkillID: skillID)
        #expect(backups.count == 1)
        #expect(backups[0].state == .available)
        let restored = try await restoreBackup(writer, backupID: backups[0].backupID)
        let repeated = try await restoreBackup(writer, backupID: backups[0].backupID)
        #expect(restored.restoredSkillID == skillID)
        #expect(repeated.restoredSkillID == restored.restoredSkillID)
        #expect(repeated.status == restored.status)
        #expect(try workspace.integer("SELECT count(*) FROM skills") == 1)
    }

    @Test("explicit distribution retry updates a stored undistributed result")
    func retriesStoredDistributionResult() async throws {
        let workspace = try WriterWorkspace()
        let writer = try await workspace.openWriter()
        let snapshot = try workspace.snapshot(content: "retry-distribution")
        let skillID = SkillID()
        _ = try await writer.create(
            payload: workspace.payload(skillID: skillID, name: "Retry", snapshot: snapshot),
            sourceSnapshot: snapshot
        )
        _ = try await deleteManagedSkill(writer, skillID: skillID)
        let backup = try await writer.listBackups(originalSkillID: skillID)[0]
        let restored = try await restoreBackup(writer, backupID: backup.backupID)

        let connection = try SQLiteConnection(url: workspace.database)
        let store = try SkillBackupStore(connection: connection)
        let persisted = try #require(try store.load(backup.backupID))
        let storedConflict = try JSONSerialization.data(
            withJSONObject: [
                "restored_skill_id": restored.restoredSkillID.directoryName,
                "schema_version": 1,
                "status": "restoredUndistributed",
                "warnings": ["distribution_conflict"],
            ],
            options: [.sortedKeys, .withoutEscapingSlashes]
        )
        let conflict = try backupReplacement(
            persisted,
            restoreResultJSON: storedConflict,
            updatedAtMilliseconds: persisted.updatedAtMilliseconds + 1
        )
        try store.replace(expected: persisted, with: conflict)

        let retried = try await restoreBackup(
            writer,
            backupID: backup.backupID,
            restoreDistribution: true
        )
        #expect(retried.status == .completed)
        #expect(retried.warnings.isEmpty)
        let repeated = try await restoreBackup(writer, backupID: backup.backupID)
        #expect(repeated.status == retried.status)
        #expect(repeated.warnings == retried.warnings)
    }

    @Test("restore retry treats matching local origin evidence as a no-op")
    func restoreRetryKeepsOriginWarningsStable() async throws {
        let workspace = try WriterWorkspace()
        let writer = try await workspace.openWriter()
        let snapshot = try workspace.snapshot(content: "retry-origin")
        let skillID = SkillID()
        let origin = try LocalSkillOriginRecord(
            skillID: skillID,
            scope: .global,
            rawLocator: "RetryOrigin",
            normalizedLocator: "RetryOrigin",
            collisionKey: SkillContentPath.collisionKey(for: "RetryOrigin"),
            fingerprint: SkillContentFingerprint(currentDigest: snapshot.fingerprintDigest),
            confirmedAtMilliseconds: 1
        )
        _ = try await writer.create(
            payload: workspace.payload(
                skillID: skillID,
                name: "RetryOrigin",
                snapshot: snapshot,
                localOrigins: [origin]
            ),
            sourceSnapshot: snapshot
        )
        _ = try await deleteManagedSkill(writer, skillID: skillID)
        let backup = try await writer.listBackups(originalSkillID: skillID)[0]
        let restored = try await restoreBackup(writer, backupID: backup.backupID)
        #expect(restored.warnings.isEmpty)

        let connection = try SQLiteConnection(url: workspace.database)
        let clear = try connection.prepare(
            """
            UPDATE skill_backups
            SET restore_result_json = NULL, updated_at_ms = updated_at_ms + 1
            WHERE backup_id = ?
            """
        )
        try clear.bind(backup.backupID.bytes, at: 1)
        _ = try clear.step()

        let retried = try await restoreBackup(writer, backupID: backup.backupID)
        #expect(retried.status == .completed)
        #expect(retried.warnings.isEmpty)
        #expect(try workspace.integer("SELECT count(*) FROM local_skill_origins") == 1)
    }

    @Test(
        "restart converges each durable deletion phase",
        arguments: SkillDeletionCheckpoint.allCases
    )
    func recoversDeletion(point: SkillDeletionCheckpoint) async throws {
        let workspace = try WriterWorkspace()
        let fired = Mutex(false)
        var hooks = JournaledSSOTWriterHooks()
        hooks.deletionCheckpoint = { reached in
            guard reached == point else { return }
            let shouldStop = fired.withLock { value in
                guard !value else { return false }
                value = true
                return true
            }
            if shouldStop { throw Stop.requested }
        }
        var writer: JournaledSSOTWriter? = try await workspace.openWriter(hooks: hooks)
        let snapshot = try workspace.snapshot(content: point.rawValue)
        let skillID = SkillID()
        _ = try await writer!.create(
            payload: workspace.payload(skillID: skillID, name: "Crash", snapshot: snapshot),
            sourceSnapshot: snapshot
        )
        do {
            _ = try await deleteManagedSkill(writer!, skillID: skillID)
            Issue.record("Expected deletion checkpoint interruption")
        } catch is SSOTWriterCheckpointInterruption {}
        writer = nil

        let recovered = try await workspace.openWriter()
        let skillCount = try workspace.integer("SELECT count(*) FROM skills")
        if point == .afterDatabaseCommitted || point == .beforeCleanup {
            #expect(skillCount == 0)
        } else {
            #expect(skillCount == 1)
            #expect(FileManager.default.fileExists(
                atPath: workspace.root.appendingPathComponent(skillID.directoryName).path
            ))
        }
        let backups = try await recovered.listBackups(originalSkillID: skillID)
        #expect(backups.count == 1)
        #expect(backups[0].state == .available)
    }

    @Test("missing prepared backup cancels without deleting the active Skill")
    func cancelsMissingPreparedBackup() async throws {
        let workspace = try WriterWorkspace()
        let operationID = SSOTOperationID()
        let backupID = SkillBackupID()
        var hooks = JournaledSSOTWriterHooks()
        hooks.deletionCheckpoint = { point in
            if point == .afterPreparedInsert { throw Stop.requested }
        }
        var writer: JournaledSSOTWriter? = try await workspace.openWriter(hooks: hooks)
        let snapshot = try workspace.snapshot(content: "still-active")
        let skillID = SkillID()
        _ = try await writer!.create(
            payload: workspace.payload(skillID: skillID, name: "Active", snapshot: snapshot),
            sourceSnapshot: snapshot
        )
        await #expect(throws: SSOTWriterCheckpointInterruption.self) {
            _ = try await deleteManagedSkill(
                writer!,
                skillID: skillID,
                operationID: operationID,
                backupID: backupID
            )
        }
        writer = nil
        let staging = workspace.managementRoot
            .appendingPathComponent("skill-backups")
            .appendingPathComponent(skillID.directoryName)
            .appendingPathComponent(
                ".skillsmanager-backup-\(backupID.uuid.uuidString.lowercased()).tmp"
            )
        try FileManager.default.removeItem(at: staging)

        let recovered = try await workspace.openWriter()
        #expect(try workspace.integer("SELECT count(*) FROM skills") == 1)
        #expect(try await recovered.listBackups(originalSkillID: skillID).isEmpty)
        let operation = try await recovered.deletionOperation(operationID)
        #expect(operation.lastError == nil)
        #expect(operation.phase == .completed)
        #expect(operation.outcome == .rolledBack)
        #expect(try await recovered.deletionReadback(operationID).status == .rolledBack)
    }

    @Test("management lock drift blocks backup promotion")
    func lockDriftBlocksBackupPromotion() async throws {
        let workspace = try WriterWorkspace()
        var hooks = JournaledSSOTWriterHooks()
        hooks.deletionCheckpoint = { point in
            guard point == .afterPreparedInsert else { return }
            let lock = workspace.managementRoot
                .appendingPathComponent(SSOTWriterOwnership.lockFileName)
            try FileManager.default.removeItem(at: lock)
            try Data("replacement\n".utf8).write(to: lock)
            guard Darwin.chmod(lock.path, 0o600) == 0 else {
                throw CocoaError(.fileWriteUnknown)
            }
        }
        let writer = try await workspace.openWriter(hooks: hooks)
        let snapshot = try workspace.snapshot(content: "lock-drift")
        let skillID = SkillID()
        _ = try await writer.create(
            payload: workspace.payload(skillID: skillID, name: "Lock", snapshot: snapshot),
            sourceSnapshot: snapshot
        )

        await #expect(throws: SkillDeletionError.unavailable) {
            _ = try await deleteManagedSkill(writer, skillID: skillID)
        }
        #expect(try workspace.integer("SELECT count(*) FROM skills") == 1)
        #expect(try workspace.scalar(
            "SELECT phase FROM skill_deletion_operations"
        ) == "prepared")
    }

    @Test("different active content restores to one stable fork identity")
    func restoresConflictAsIndependentSkill() async throws {
        let workspace = try WriterWorkspace()
        let writer = try await workspace.openWriter()
        let original = try workspace.snapshot(content: "original")
        let originalID = SkillID()
        _ = try await writer.create(
            payload: workspace.payload(
                skillID: originalID,
                name: "Original",
                snapshot: original
            ),
            sourceSnapshot: original
        )
        _ = try await deleteManagedSkill(writer, skillID: originalID)
        let backup = try await writer.listBackups(originalSkillID: originalID)[0]

        let replacement = try workspace.snapshot(content: "replacement")
        _ = try await writer.create(
            payload: workspace.payload(
                skillID: originalID,
                name: "Replacement",
                snapshot: replacement
            ),
            sourceSnapshot: replacement
        )
        let restored = try await restoreBackup(writer, backupID: backup.backupID)
        let repeated = try await restoreBackup(writer, backupID: backup.backupID)
        #expect(restored.restoredSkillID != originalID)
        #expect(repeated.restoredSkillID == restored.restoredSkillID)
        #expect(try workspace.integer("SELECT count(*) FROM skills") == 2)
    }

    @Test("restore keeps an occupied provider locator with its current Skill")
    func restoreOmitsConflictingProviderProvenance() async throws {
        let workspace = try WriterWorkspace()
        let writer = try await workspace.openWriter()
        let identity = try ProviderAliasIdentity(provider: "clawdhub", identifier: "demo")

        let originalSnapshot = try workspace.snapshot(content: "original provenance")
        let originalID = SkillID()
        _ = try await writer.create(
            payload: try payloadWithProvenance(
                workspace.payload(
                    skillID: originalID,
                    name: "Original",
                    snapshot: originalSnapshot
                ),
                identity: identity
            ),
            sourceSnapshot: originalSnapshot
        )
        _ = try await deleteManagedSkill(writer, skillID: originalID)
        let backup = try await writer.listBackups(originalSkillID: originalID)[0]

        let currentSnapshot = try workspace.snapshot(content: "current provenance")
        let currentID = SkillID()
        _ = try await writer.create(
            payload: try payloadWithProvenance(
                workspace.payload(
                    skillID: currentID,
                    name: "Current",
                    snapshot: currentSnapshot
                ),
                identity: identity
            ),
            sourceSnapshot: currentSnapshot
        )

        let result = try await restoreBackup(writer, backupID: backup.backupID)

        #expect(result.restoredSkillID == originalID)
        #expect(result.warnings == [
            "provider_provenance_conflict:clawdhub:demo",
        ])
        #expect(try await writer.providerProvenance(identity)?.skillID == currentID)
        #expect(try await writer.storedDomainReadback(originalID)?
            .payload.providerProvenance.isEmpty == true)
    }

    @Test("tampered backup fails closed")
    func rejectsTamperedBackup() async throws {
        let workspace = try WriterWorkspace()
        let writer = try await workspace.openWriter()
        let snapshot = try workspace.snapshot(content: "trusted")
        let skillID = SkillID()
        _ = try await writer.create(
            payload: workspace.payload(skillID: skillID, name: "Trusted", snapshot: snapshot),
            sourceSnapshot: snapshot
        )
        _ = try await deleteManagedSkill(writer, skillID: skillID)
        let backup = try await writer.listBackups(originalSkillID: skillID)[0]
        let file = workspace.managementRoot
            .appendingPathComponent("skill-backups")
            .appendingPathComponent(backup.locator)
            .appendingPathComponent("skill-files/SKILL.md")
        try Data("tampered".utf8).write(to: file)

        await #expect(throws: (any Error).self) {
            _ = try await restoreBackup(writer, backupID: backup.backupID)
        }
        #expect(try workspace.integer("SELECT count(*) FROM skills") == 0)
    }

    @Test("retention keeps the newest ten valid backups")
    func prunesOldBackups() async throws {
        let workspace = try WriterWorkspace()
        var hooks = JournaledSSOTWriterHooks()
        hooks.nowMilliseconds = { 1 }
        let writer = try await workspace.openWriter(hooks: hooks)
        let snapshot = try workspace.snapshot(content: "retained")
        let skillID = SkillID()
        _ = try await writer.create(
            payload: workspace.payload(skillID: skillID, name: "Retained", snapshot: snapshot),
            sourceSnapshot: snapshot
        )
        for _ in 0..<11 {
            _ = try await deleteManagedSkill(writer, skillID: skillID)
            let backup = try await writer.listBackups(originalSkillID: skillID)
                .first { $0.restoreResultJSON == nil }!
            _ = try await restoreBackup(writer, backupID: backup.backupID)
        }

        let result = try await writer.runBackupRetention(
            originalSkillID: skillID,
            nowMilliseconds: 31 * 24 * 60 * 60 * 1_000
        )
        #expect(result.prunedBackupIDs.count == 1)
        #expect(try await writer.listBackups(originalSkillID: skillID).count == 10)
    }
}

private func deleteManagedSkill(
    _ writer: JournaledSSOTWriter,
    skillID: SkillID,
    operationID: SSOTOperationID = SSOTOperationID(),
    backupID: SkillBackupID = SkillBackupID()
) async throws -> SkillDeletionResult {
    let preview = try await writer.deletionPreview(skillID: skillID)
    return try await writer.deleteManagedSkill(
        preview: preview,
        operationID: operationID,
        backupID: backupID
    )
}

private func restoreBackup(
    _ writer: JournaledSSOTWriter,
    backupID: SkillBackupID,
    restoreDistribution: Bool = false
) async throws -> SkillRestoreResult {
    let preview = try await writer.restorePreview(backupID)
    return try await writer.restoreBackup(
        preview: preview,
        restoreDistribution: restoreDistribution
    )
}

private func payloadWithProvenance(
    _ payload: SSOTSkillWritePayload,
    identity: ProviderAliasIdentity
) throws -> SSOTSkillWritePayload {
    let slug = try DefaultDistributionSlug(validating: identity.identifier)
    return try SSOTSkillWritePayload(
        skill: payload.skill,
        source: payload.source,
        providerAliases: payload.providerAliases,
        providerProvenance: [
            try ProviderProvenanceRecord(
                skillID: payload.skill.skillID,
                identity: identity,
                identifierKey: slug.collisionKey,
                version: try SourceVersion("1.0.0")
            ),
        ],
        localOrigins: payload.localOrigins,
        restoredFromSkillID: payload.restoredFromSkillID
    )
}
