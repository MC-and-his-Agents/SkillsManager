import CryptoKit
import Foundation
import Testing

@testable import SkillsManager

@Suite("Journaled SSOT update backup", .serialized)
struct JournaledSSOTWriterUpdateBackupTests {
    private enum Stop: Error { case requested }

    @Test("publishes and validates the old content before replacing")
    func backsUpBeforeReplacement() async throws {
        let context = try await UpdateBackupContext()
        let baseline = try await context.writer.managedSkillUpdateBaseline(context.skillID)
        let replacement = try context.workspace.snapshot(content: "new")

        let result = try await context.writer.replaceManagedSkillWithBackup(
            expected: baseline,
            replacementPayload: context.workspace.payload(
                skillID: context.skillID,
                name: "New",
                snapshot: replacement
            ),
            sourceSnapshot: replacement,
            operationID: SSOTOperationID(),
            backupID: SkillBackupID()
        )

        #expect(result.backup.state == .available)
        #expect(result.replacement.state.outcome == .applied)
        #expect(try await context.writer.validateBackup(result.backup.backupID) == result.backup)
        #expect(try context.workspace.scalar("SELECT display_name FROM skills") == "New")
        let manifest = try SkillBackupManifestV1.decode(
            context.backupManifest(result.backup)
        )
        #expect(manifest.payload.skill.displayName.value == "Old")
        #expect(manifest.databaseRevision == 0)
    }

    @Test("rejects a drifted baseline without creating a backup")
    func rejectsBaselineDrift() async throws {
        let context = try await UpdateBackupContext()
        let baseline = try await context.writer.managedSkillUpdateBaseline(context.skillID)
        let drift = try context.workspace.snapshot(content: "drift")
        _ = try await context.writer.replace(
            payload: context.workspace.payload(
                skillID: context.skillID,
                name: "Drift",
                snapshot: drift
            ),
            sourceSnapshot: drift,
            expectedOld: try SSOTReplacementExpectation(
                identity: baseline.finalIdentity,
                fingerprint: baseline.domain.payload.skill.contentFingerprint,
                databaseRevision: baseline.domain.revision
            )
        )
        let attempted = try context.workspace.snapshot(content: "attempted")

        await #expect(throws: ManagedSkillUpdateBackupError.baselineDrift) {
            _ = try await context.writer.replaceManagedSkillWithBackup(
                expected: baseline,
                replacementPayload: context.workspace.payload(
                    skillID: context.skillID,
                    name: "Attempted",
                    snapshot: attempted
                ),
                sourceSnapshot: attempted,
                operationID: SSOTOperationID(),
                backupID: SkillBackupID()
            )
        }
        #expect(try await context.writer.listBackups(
            originalSkillID: context.skillID
        ).isEmpty)
    }

    @Test("recovers prepared final, staging, and absent backup states")
    func recoversPreparingStates() async throws {
        let context = try await UpdateBackupContext()
        let template = try await context.createAvailableBackup()
        let final = try context.insertPreparingCopy(
            of: template,
            placement: .final,
            timestamp: 200
        )
        let staging = try context.insertPreparingCopy(
            of: template,
            placement: .staging,
            timestamp: 300
        )
        let absent = try context.insertAbsentPreparing(
            basedOn: template,
            timestamp: 400
        )

        try await context.writer.recoverIndependentUpdateBackups()

        #expect(try context.loadBackup(final.backupID)?.state == .available)
        #expect(try context.loadBackup(staging.backupID)?.state == .available)
        #expect(try context.loadBackup(absent.backupID) == nil)
        #expect(FileManager.default.fileExists(
            atPath: context.backupURL(staging.locator).path
        ))
    }

    @Test("corrupt prepared backup needs repair only for its own Skill")
    func scopesRepairBlockerToSkill() async throws {
        let context = try await UpdateBackupContext()
        let other = try await context.createSecondSkill()
        let template = try await context.createAvailableBackup()
        let corrupt = try context.insertPreparingCopy(
            of: template,
            placement: .final,
            timestamp: 500
        )
        try Data("tampered".utf8).write(
            to: context.backupURL(corrupt.locator)
                .appendingPathComponent(SkillBackupFileSystem.filesName)
                .appendingPathComponent("SKILL.md")
        )

        try await context.writer.recoverIndependentUpdateBackups()

        #expect(try context.loadBackup(corrupt.backupID)?.state == .needsRepair)
        await #expect(throws: ManagedSkillUpdateBackupError.backupNeedsRepair) {
            _ = try await context.writer.managedSkillUpdateBaseline(context.skillID)
        }
        _ = try await context.writer.managedSkillUpdateBaseline(other)
    }

    @Test("deletion-owned preparing backup is excluded")
    func excludesDeletionBackup() async throws {
        let workspace = try WriterWorkspace()
        var hooks = JournaledSSOTWriterHooks()
        hooks.deletionCheckpoint = { point in
            if point == .afterPreparedInsert { throw Stop.requested }
        }
        let writer = try await workspace.openWriter(hooks: hooks)
        let snapshot = try workspace.snapshot(content: "delete")
        let skillID = SkillID()
        _ = try await writer.create(
            payload: workspace.payload(
                skillID: skillID,
                name: "Delete",
                snapshot: snapshot
            ),
            sourceSnapshot: snapshot
        )
        let backupID = SkillBackupID()
        let preview = try await writer.deletionPreview(skillID: skillID)
        await #expect(throws: SSOTWriterCheckpointInterruption.self) {
            _ = try await writer.deleteManagedSkill(
                preview: preview,
                operationID: SSOTOperationID(),
                backupID: backupID
            )
        }

        try await writer.recoverIndependentUpdateBackups()

        let connection = try SQLiteConnection(url: workspace.database)
        #expect(try SkillBackupStore(connection: connection)
            .load(backupID)?.state == .preparing)
    }

    @Test("backup failure leaves the managed replacement untouched")
    func backupFailureDoesNotReplace() async throws {
        let context = try await UpdateBackupContext(nowMilliseconds: 100)
        let backupID = SkillBackupID()
        _ = try await context.update(content: "first", backupID: backupID)
        let baseline = try await context.writer.managedSkillUpdateBaseline(context.skillID)
        let second = try context.workspace.snapshot(content: "second")

        await #expect(throws: SkillBackupFileSystemError.destinationExists) {
            _ = try await context.writer.replaceManagedSkillWithBackup(
                expected: baseline,
                replacementPayload: context.workspace.payload(
                    skillID: context.skillID,
                    name: "Second",
                    snapshot: second
                ),
                sourceSnapshot: second,
                operationID: SSOTOperationID(),
                backupID: backupID
            )
        }
        #expect(try context.workspace.scalar("SELECT display_name FROM skills") == "first")
        #expect(try context.workspace.integer("SELECT db_revision FROM skills") == 1)
    }

    @Test("an unfinished replacement blocks a fresh update before backup")
    func pendingReplacementBlocksFreshUpdate() async throws {
        let workspace = try WriterWorkspace()
        var writer: JournaledSSOTWriter? = try await workspace.openWriter()
        let skillID = SkillID()
        let old = try workspace.snapshot(content: "old")
        _ = try await writer!.create(
            payload: workspace.payload(skillID: skillID, name: "Old", snapshot: old),
            sourceSnapshot: old
        )
        writer = nil

        var hooks = JournaledSSOTWriterHooks()
        hooks.checkpoint = { point, _ in
            if point == .afterPreparedInsert || point == .beforeReplacementSwap {
                throw Stop.requested
            }
        }
        writer = try await workspace.openWriter(hooks: hooks)
        let baseline = try await writer!.managedSkillUpdateBaseline(skillID)
        let pending = try workspace.snapshot(content: "pending")
        await #expect(throws: SSOTWriterCheckpointInterruption.self) {
            _ = try await writer!.replace(
                payload: workspace.payload(
                    skillID: skillID,
                    name: "Pending",
                    snapshot: pending
                ),
                sourceSnapshot: pending,
                expectedOld: try SSOTReplacementExpectation(
                    identity: baseline.finalIdentity,
                    fingerprint: baseline.domain.payload.skill.contentFingerprint,
                    databaseRevision: baseline.domain.revision
                )
            )
        }
        let attempted = try workspace.snapshot(content: "attempted")

        await #expect(throws: CopyForkError.operationInProgress) {
            _ = try await writer!.replaceManagedSkillWithBackup(
                expected: baseline,
                replacementPayload: workspace.payload(
                    skillID: skillID,
                    name: "Attempted",
                    snapshot: attempted
                ),
                sourceSnapshot: attempted,
                operationID: SSOTOperationID(),
                backupID: SkillBackupID()
            )
        }

        #expect(try workspace.integer("SELECT count(*) FROM skill_backups") == 0)
        #expect(try workspace.integer("SELECT count(*) FROM skill_operations") == 2)
    }

    @Test("a repair-blocked replacement blocks a fresh update before backup")
    func repairReplacementBlocksFreshUpdate() async throws {
        let workspace = try WriterWorkspace()
        var hooks = JournaledSSOTWriterHooks()
        hooks.checkpoint = { point, _ in
            if point == .afterPreparedInsert { throw Stop.requested }
        }
        let writer = try await workspace.openWriter(hooks: hooks)
        let skillID = SkillID()
        let snapshot = try workspace.snapshot(content: "corrupt")
        await #expect(throws: SSOTWriterCheckpointInterruption.self) {
            _ = try await writer.create(
                payload: workspace.payload(
                    skillID: skillID,
                    name: "Corrupt",
                    snapshot: snapshot
                ),
                sourceSnapshot: snapshot
            )
        }
        try workspace.mutateIgnoringTrigger(
            named: "skill_operations_immutable_ownership",
            "UPDATE skill_operations SET domain_payload = X'00'"
        )

        await #expect(throws: JournaledSSOTWriterError.self) {
            _ = try await writer.managedSkillUpdateBaseline(skillID)
        }

        #expect(try workspace.integer("SELECT count(*) FROM skill_backups") == 0)
        #expect(try workspace.integer(
            "SELECT count(*) FROM skill_operations WHERE outcome = 'needsRepair'"
        ) == 1)
    }
}

private final class UpdateBackupContext: @unchecked Sendable {
    enum Placement { case final, staging }

    let workspace: WriterWorkspace
    let writer: JournaledSSOTWriter
    let skillID: SkillID

    init(nowMilliseconds: Int64? = nil) async throws {
        workspace = try WriterWorkspace()
        var hooks = JournaledSSOTWriterHooks()
        if let nowMilliseconds {
            hooks.nowMilliseconds = { nowMilliseconds }
        }
        writer = try await workspace.openWriter(hooks: hooks)
        skillID = SkillID()
        let snapshot = try workspace.snapshot(content: "old")
        _ = try await writer.create(
            payload: workspace.payload(
                skillID: skillID,
                name: "Old",
                snapshot: snapshot
            ),
            sourceSnapshot: snapshot
        )
    }

    func update(
        content: String,
        backupID: SkillBackupID = SkillBackupID()
    ) async throws -> ManagedSkillUpdateWriteResult {
        let baseline = try await writer.managedSkillUpdateBaseline(skillID)
        let snapshot = try workspace.snapshot(content: content)
        return try await writer.replaceManagedSkillWithBackup(
            expected: baseline,
            replacementPayload: workspace.payload(
                skillID: skillID,
                name: content,
                snapshot: snapshot
            ),
            sourceSnapshot: snapshot,
            operationID: SSOTOperationID(),
            backupID: backupID
        )
    }

    func createAvailableBackup() async throws -> SkillBackupRecord {
        try await update(content: "updated").backup
    }

    func createSecondSkill() async throws -> SkillID {
        let secondID = SkillID()
        let snapshot = try workspace.snapshot(content: "second-skill")
        _ = try await writer.create(
            payload: workspace.payload(
                skillID: secondID,
                name: "Second-Skill",
                snapshot: snapshot
            ),
            sourceSnapshot: snapshot
        )
        return secondID
    }

    func insertPreparingCopy(
        of template: SkillBackupRecord,
        placement: Placement,
        timestamp: Int64
    ) throws -> SkillBackupRecord {
        let backupID = SkillBackupID()
        let locator = "\(skillID.directoryName)/\(timestamp)-"
            + backupID.uuid.uuidString.lowercased()
        let destination: URL
        switch placement {
        case .final:
            destination = backupURL(locator)
        case .staging:
            destination = backupURL("\(skillID.directoryName)/"
                + ".skillsmanager-backup-\(backupID.uuid.uuidString.lowercased()).tmp")
        }
        try FileManager.default.copyItem(
            at: backupURL(template.locator),
            to: destination
        )
        let templateManifest = try SkillBackupManifestV1.decode(
            backupManifest(template)
        )
        let manifestBytes = try SkillBackupManifestV1(
            backupID: backupID,
            payload: templateManifest.payload,
            databaseRevision: templateManifest.databaseRevision,
            distributionSelection: templateManifest.distributionSelection,
            statistics: templateManifest.statistics,
            createdAtMilliseconds: timestamp
        ).encoded()
        try manifestBytes.write(
            to: destination.appendingPathComponent(
                SkillBackupFileSystem.manifestName
            )
        )
        let identity = try ManagedRootReference.capture(at: destination)
            .verifiedRoot().identity
        let record = try SkillBackupRecord(
            backupID: backupID,
            originalSkillID: skillID,
            state: .preparing,
            locator: locator,
            directoryIdentity: identity,
            manifestDigest: Data(SHA256.hash(data: manifestBytes)),
            contentFingerprint: template.contentFingerprint,
            createdAtMilliseconds: timestamp,
            updatedAtMilliseconds: timestamp
        )
        try SkillBackupStore(connection: SQLiteConnection(url: workspace.database))
            .insertPreparing(record)
        return record
    }

    func insertAbsentPreparing(
        basedOn template: SkillBackupRecord,
        timestamp: Int64
    ) throws -> SkillBackupRecord {
        let backupID = SkillBackupID()
        let record = try SkillBackupRecord(
            backupID: backupID,
            originalSkillID: skillID,
            state: .preparing,
            locator: "\(skillID.directoryName)/\(timestamp)-"
                + backupID.uuid.uuidString.lowercased(),
            directoryIdentity: template.directoryIdentity,
            manifestDigest: template.manifestDigest,
            contentFingerprint: template.contentFingerprint,
            createdAtMilliseconds: timestamp,
            updatedAtMilliseconds: timestamp
        )
        try SkillBackupStore(connection: SQLiteConnection(url: workspace.database))
            .insertPreparing(record)
        return record
    }

    func loadBackup(_ backupID: SkillBackupID) throws -> SkillBackupRecord? {
        try SkillBackupStore(connection: SQLiteConnection(url: workspace.database))
            .load(backupID)
    }

    func backupURL(_ locator: String) -> URL {
        workspace.managementRoot
            .appendingPathComponent("skill-backups")
            .appendingPathComponent(locator)
    }

    func backupManifest(_ backup: SkillBackupRecord) throws -> Data {
        try Data(contentsOf: backupURL(backup.locator)
            .appendingPathComponent(SkillBackupFileSystem.manifestName))
    }
}
