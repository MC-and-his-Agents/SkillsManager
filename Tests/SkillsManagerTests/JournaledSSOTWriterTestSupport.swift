import Darwin
import Foundation

@testable import SkillsManager

final class WriterWorkspace: @unchecked Sendable {
    let workspace: URL
    let managementRoot: URL
    let root: URL
    let source: URL
    let database: URL
    let verifiedManagementRoot: VerifiedSSOTRoot
    let verifiedRoot: VerifiedSSOTRoot

    init() throws {
        workspace = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        managementRoot = workspace.appendingPathComponent("management", isDirectory: true)
        root = managementRoot.appendingPathComponent("skills", isDirectory: true)
        source = workspace.appendingPathComponent("source", isDirectory: true)
        database = managementRoot.appendingPathComponent("manager.sqlite")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: false)
        guard Darwin.chmod(managementRoot.path, 0o700) == 0 else {
            throw CocoaError(.fileWriteUnknown)
        }
        guard Darwin.chmod(root.path, 0o700) == 0 else { throw CocoaError(.fileWriteUnknown) }
        let managementDescriptor = Darwin.open(
            managementRoot.path,
            O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC
        )
        guard managementDescriptor >= 0 else { throw CocoaError(.fileReadUnknown) }
        defer { Darwin.close(managementDescriptor) }
        verifiedManagementRoot = try VerifiedSSOTRoot(
            existingRootURL: managementRoot,
            descriptor: managementDescriptor
        )
        let rootDescriptor = Darwin.open(
            root.path,
            O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC
        )
        guard rootDescriptor >= 0 else { throw CocoaError(.fileReadUnknown) }
        defer { Darwin.close(rootDescriptor) }
        verifiedRoot = try VerifiedSSOTRoot(
            existingRootURL: root,
            descriptor: rootDescriptor
        )
    }

    deinit { try? FileManager.default.removeItem(at: workspace) }

    func openWriter(
        hooks: JournaledSSOTWriterHooks = .init()
    ) async throws -> JournaledSSOTWriter {
        try await JournaledSSOTWriter.open(
            managementRoot: verifiedManagementRoot,
            ssotRoot: verifiedRoot,
            databaseURL: database,
            hooks: hooks
        )
    }

    func snapshot(content: String) throws -> SkillContentSnapshot {
        try Data(content.utf8).write(
            to: source.appendingPathComponent("SKILL.md"),
            options: .atomic
        )
        return try SkillContentSnapshot.capture(at: source)
    }

    func payload(
        skillID: SkillID = SkillID(),
        name: String,
        snapshot: SkillContentSnapshot,
        sourceKey: String? = nil
    ) throws -> SSOTSkillWritePayload {
        let skill = try ManagedSkillRecord(
            skillID: skillID,
            displayName: SkillDisplayName(name),
            defaultDistributionSlug: DefaultDistributionSlug(validating: name.lowercased()),
            contentFingerprint: SkillContentFingerprint(currentDigest: snapshot.fingerprintDigest),
            createdAtMilliseconds: 1,
            updatedAtMilliseconds: 1
        )
        let source = try sourceKey.map {
            SkillSourceRecord(
                sourceID: SourceID(),
                skillID: skillID,
                repositoryURL: try NormalizedRepositoryURL("https://example.com/shared"),
                subpath: try RepositorySubpath($0)
            )
        }
        return try SSOTSkillWritePayload(skill: skill, source: source)
    }

    func integer(_ sql: String) throws -> Int64? {
        try SQLiteConnection(url: database, accessMode: .readOnly).querySingleInt(sql)
    }

    func scalar(_ sql: String) throws -> String? {
        try SQLiteConnection(url: database, accessMode: .readOnly).querySingleText(sql)
    }

    func execute(_ sql: String) throws {
        try SQLiteConnection(url: database).execute(sql)
    }

    func operationID(for skillID: SkillID) throws -> UUID {
        let connection = try SQLiteConnection(url: database, accessMode: .readOnly)
        let statement = try connection.prepare(
            "SELECT operation_id FROM skill_operations WHERE skill_id = ?"
        )
        try statement.bind(skillID.bytes, at: 1)
        guard try statement.step() else { throw CocoaError(.fileReadUnknown) }
        return try SkillID(bytes: statement.blob(at: 0)!).uuid
    }

    func operationID(type: SSOTOperationType) throws -> UUID {
        let connection = try SQLiteConnection(url: database, accessMode: .readOnly)
        let statement = try connection.prepare(
            "SELECT operation_id FROM skill_operations WHERE operation_type = ? ORDER BY created_at_ms DESC"
        )
        try statement.bind(type.rawValue, at: 1)
        guard try statement.step() else { throw CocoaError(.fileReadUnknown) }
        return try SkillID(bytes: statement.blob(at: 0)!).uuid
    }

    func internalItemCount() throws -> Int {
        try FileManager.default.contentsOfDirectory(atPath: root.path)
            .filter { $0.hasPrefix(".skillsmanager-tmp-") }
            .count
    }

    func bindPendingRecoveryDebt(operationID: UUID) throws -> SSOTCleanupDebtID {
        let connection = try SQLiteConnection(url: database)
        let debtID = SSOTCleanupDebtID()
        try connection.execute("BEGIN IMMEDIATE")
        do {
            let update = try connection.prepare(
                """
                UPDATE skill_operations
                SET cleanup_state = 'pending', cleanup_debt_id = ?
                WHERE operation_id = ? AND phase = 'databaseCommitted'
                  AND outcome IS NULL AND cleanup_state = 'notStarted'
                """
            )
            try update.bind(debtID.bytes, at: 1)
            try update.bind(SSOTOperationID(operationID).bytes, at: 2)
            _ = try update.step()
            guard try connection.querySingleInt("SELECT changes()") == 1 else {
                throw SSOTJournalStoreError.stateConflict
            }

            let insert = try connection.prepare(
                """
                INSERT INTO cleanup_debts(
                  cleanup_debt_id, operation_id, item_role, recovery_locator,
                  expected_item_identity, expected_fingerprint_algorithm_version,
                  expected_content_fingerprint, expected_root_identity,
                  attempt_count, last_error_code, created_at_ms, updated_at_ms
                )
                SELECT ?, operation_id, 'recovery', recovery_locator,
                       expected_old_identity, old_fingerprint_algorithm_version,
                       old_content_fingerprint, expected_root_identity,
                       0, 'interrupted-cleanup', updated_at_ms, updated_at_ms
                FROM skill_operations WHERE operation_id = ?
                """
            )
            try insert.bind(debtID.bytes, at: 1)
            try insert.bind(SSOTOperationID(operationID).bytes, at: 2)
            _ = try insert.step()
            guard try connection.querySingleInt("SELECT changes()") == 1 else {
                throw SSOTJournalStoreError.stateConflict
            }
            try connection.execute("COMMIT")
            return debtID
        } catch {
            try? connection.execute("ROLLBACK")
            throw error
        }
    }

    func removeOperationItem(_ operationID: UUID) throws {
        try FileManager.default.removeItem(
            at: root.appendingPathComponent(
                ".skillsmanager-tmp-\(operationID.uuidString.lowercased())"
            )
        )
    }

    func mutateIgnoringTrigger(named name: String, _ mutation: String) throws {
        let allowed = [
            "skill_operations_immutable_ownership",
            "skill_operations_lifecycle",
            "cleanup_debts_immutable_ownership",
        ]
        guard allowed.contains(name) else { throw SSOTJournalStoreError.invalidRecord }
        let connection = try SQLiteConnection(url: database)
        let trigger = try connection.querySingleText(
            "SELECT sql FROM sqlite_schema "
                + "WHERE type = 'trigger' AND name = '\(name)'"
        )
        guard let trigger else { throw SSOTJournalStoreError.invalidRecord }
        try connection.execute("BEGIN IMMEDIATE")
        do {
            try connection.execute("DROP TRIGGER \(name)")
            try connection.execute(mutation)
            try connection.execute(trigger)
            try connection.execute("COMMIT")
        } catch {
            try? connection.execute("ROLLBACK")
            throw error
        }
    }
}
