import Foundation
import Testing

@testable import SkillsManager

@Suite("Skill database schema v2")
struct SkillSchemaV2Tests {
    @Test("migrates v1 through v2 to v3 atomically and preserves v1 on failure")
    func migratesV1Atomically() throws {
        enum InjectedFailure: Error { case stop }
        let location = try v2DatabaseLocation()
        defer { try? FileManager.default.removeItem(at: location.root) }
        try createV1Database(at: location.database)

        #expect(throws: InjectedFailure.self) {
            _ = try SkillSchemaMigrator.open(at: location.database, beforeV2Commit: {
                throw InjectedFailure.stop
            })
        }

        let rolledBack = try SQLiteConnection(url: location.database)
        #expect(try rolledBack.querySingleInt("PRAGMA user_version") == 1)
        #expect(try rolledBack.userTableNames() == SkillSchemaV1.tableNames)
        #expect(try rolledBack.querySingleInt(
            "SELECT count(*) FROM pragma_table_info('skills') WHERE name = 'db_revision'"
        ) == 0)

        #expect(throws: InjectedFailure.self) {
            _ = try SkillSchemaMigrator.open(at: location.database, beforeV3Commit: {
                throw InjectedFailure.stop
            })
        }
        let rolledBackAtV3 = try SQLiteConnection(url: location.database)
        #expect(try rolledBackAtV3.querySingleInt("PRAGMA user_version") == 1)
        #expect(try rolledBackAtV3.userTableNames() == SkillSchemaV1.tableNames)

        let migrated = try SkillSchemaMigrator.open(at: location.database)
        #expect(try migrated.querySingleInt("PRAGMA user_version") == 3)
        #expect(try migrated.userTableNames() == SkillSchemaV3.tableNames)
        #expect(try migrated.querySingleInt(
            "SELECT count(*) FROM pragma_table_list WHERE name IN "
                + "('skill_operations', 'cleanup_debts') AND strict = 1"
        ) == 2)
    }

    @Test("rejects future and structurally mismatched v2 databases")
    func rejectsFutureAndMismatch() throws {
        let future = try v2DatabaseLocation()
        defer { try? FileManager.default.removeItem(at: future.root) }
        let futureConnection = try SkillSchemaMigrator.open(at: future.database)
        try futureConnection.execute("PRAGMA user_version = 4")
        #expect(throws: SQLiteStoreError.self) {
            _ = try SkillSchemaMigrator.open(at: future.database)
        }

        let mismatch = try v2DatabaseLocation()
        defer { try? FileManager.default.removeItem(at: mismatch.root) }
        let mismatchConnection = try SkillSchemaMigrator.open(at: mismatch.database)
        try mismatchConnection.execute("DROP TRIGGER skill_operations_lifecycle")
        #expect(throws: SQLiteStoreError.self) {
            _ = try SkillSchemaMigrator.open(at: mismatch.database)
        }
    }

    @Test("rejects same-named weakened schema objects")
    func rejectsSameNamedWeakenedObjects() throws {
        let trigger = try v2DatabaseLocation()
        defer { try? FileManager.default.removeItem(at: trigger.root) }
        let triggerConnection = try SkillSchemaMigrator.open(at: trigger.database)
        try triggerConnection.execute("DROP TRIGGER skill_operations_lifecycle")
        try triggerConnection.execute(
            """
            CREATE TRIGGER skill_operations_lifecycle
            BEFORE UPDATE ON skill_operations
            BEGIN
              SELECT 1;
            END
            """
        )
        #expect(throws: SQLiteStoreError.self) {
            _ = try SkillSchemaMigrator.open(at: trigger.database)
        }

        let index = try v2DatabaseLocation()
        defer { try? FileManager.default.removeItem(at: index.root) }
        let indexConnection = try SkillSchemaMigrator.open(at: index.database)
        try indexConnection.execute("DROP INDEX skill_operations_one_unfinished_per_skill")
        try indexConnection.execute(
            """
            CREATE UNIQUE INDEX skill_operations_one_unfinished_per_skill
              ON skill_operations(skill_id) WHERE phase = 'prepared'
            """
        )
        #expect(throws: SQLiteStoreError.self) {
            _ = try SkillSchemaMigrator.open(at: index.database)
        }

        let nonStrict = try v2DatabaseLocation()
        defer { try? FileManager.default.removeItem(at: nonStrict.root) }
        try createStructurallyDriftedV2(at: nonStrict.database) { index, sql in
            index == 1 ? sql.replacingOccurrences(of: ") STRICT", with: ")") : sql
        }
        #expect(throws: SQLiteStoreError.self) {
            _ = try SkillSchemaMigrator.open(at: nonStrict.database)
        }

        let weakenedCheck = try v2DatabaseLocation()
        defer { try? FileManager.default.removeItem(at: weakenedCheck.root) }
        try createStructurallyDriftedV2(at: weakenedCheck.database) { index, sql in
            guard index == 1 else { return sql }
            return sql.replacingOccurrences(
                of: "CHECK (status IN ('managed', 'needsRepair'))",
                with: "CHECK (status IS NOT NULL)"
            )
        }
        #expect(throws: SQLiteStoreError.self) {
            _ = try SkillSchemaMigrator.open(at: weakenedCheck.database)
        }

        let weakenedSource = try v2DatabaseLocation()
        defer { try? FileManager.default.removeItem(at: weakenedSource.root) }
        try createStructurallyDriftedV2(at: weakenedSource.database) { index, sql in
            guard index == 2 else { return sql }
            return sql.replacingOccurrences(
                of: "REFERENCES skills(skill_id) ON DELETE CASCADE",
                with: "REFERENCES skills(skill_id)"
            )
        }
        #expect(throws: SQLiteStoreError.self) {
            _ = try SkillSchemaMigrator.open(at: weakenedSource.database)
        }
    }

    @Test("persists the encoded domain payload across reopen")
    func preservesDomainPayload() throws {
        let location = try v2DatabaseLocation()
        defer { try? FileManager.default.removeItem(at: location.root) }
        let skillID = SkillID(UUID(uuidString: "aaaaaaaa-1111-4222-8333-bbbbbbbbbbbb")!)
        let payload = try SSOTWritePayloadCodec.encode(SSOTSkillWritePayload(skill: try .init(
            skillID: skillID,
            displayName: SkillDisplayName("Demo"),
            defaultDistributionSlug: DefaultDistributionSlug(validating: "demo"),
            contentFingerprint: SkillContentFingerprint(
                algorithmVersion: 1,
                digest: Data(repeating: 0xab, count: 32)
            ),
            createdAtMilliseconds: 0,
            updatedAtMilliseconds: 0
        )))
        do {
            let connection = try SkillSchemaMigrator.open(at: location.database)
            try connection.execute(createOperationInsert(domainPayload: v2Blob(payload)))
        }

        let reopened = try SkillSchemaMigrator.open(at: location.database, accessMode: .readOnly)
        let statement = try reopened.prepare("SELECT domain_payload FROM skill_operations")
        #expect(try statement.step())
        let stored = try #require(statement.blob(at: 0))
        #expect(stored == payload)
        #expect(try SSOTWritePayloadCodec.decode(stored).skill.skillID == skillID)
    }

    @Test("enforces one unfinished operation and lifecycle transitions")
    func enforcesOperationConstraints() throws {
        try withV2Database { connection in
            #expect(v2SQLIsRejected(connection, createOperationInsert(domainPayload: "X''")))
            #expect(v2SQLIsRejected(
                connection,
                createOperationInsert(domainPayload: "zeroblob(131073)")
            ))
            try connection.execute(createOperationInsert())
            #expect(v2SQLIsRejected(connection, createOperationInsert(
                operationID: v2Blob(v2OperationB),
                stagingLocator: ".skillsmanager-tmp-11112222-3333-4444-8555-666677778888"
            )))
            #expect(v2SQLIsRejected(
                connection,
                "UPDATE skill_operations SET phase = 'databaseCommitted', updated_at_ms = 1 "
                    + "WHERE operation_id = \(v2Blob(v2OperationA))"
            ))
            #expect(v2SQLIsRejected(
                connection,
                "UPDATE skill_operations SET operation_id = \(v2Blob(v2OperationB)) "
                    + "WHERE operation_id = \(v2Blob(v2OperationA))"
            ))
            #expect(v2SQLIsRejected(
                connection,
                "UPDATE skill_operations SET domain_payload = X'00' "
                    + "WHERE operation_id = \(v2Blob(v2OperationA))"
            ))
            try connection.execute(
                "UPDATE skill_operations SET outcome = 'needsRepair', last_error = 'identity drift', "
                    + "attempt_count = 1, updated_at_ms = 1 "
                    + "WHERE operation_id = \(v2Blob(v2OperationA))"
            )
            #expect(v2SQLIsRejected(
                connection,
                "UPDATE skill_operations SET phase = 'filesystemApplied', updated_at_ms = 2 "
                    + "WHERE operation_id = \(v2Blob(v2OperationA))"
            ))
            #expect(v2SQLIsRejected(
                connection,
                "UPDATE skill_operations SET attempt_count = 2, updated_at_ms = 2 "
                    + "WHERE operation_id = \(v2Blob(v2OperationA))"
            ))
        }
    }

    @Test("phase advances cannot also change repair outcome or cleanup state")
    func rejectsStateChangesDuringPhaseAdvance() throws {
        try withV2Database { connection in
            try connection.execute(replaceOperationInsert())

            #expect(v2SQLIsRejected(
                connection,
                "UPDATE skill_operations SET phase = 'filesystemApplied', "
                    + "outcome = 'needsRepair', updated_at_ms = 1"
            ))
            #expect(v2SQLIsRejected(
                connection,
                "UPDATE skill_operations SET phase = 'filesystemApplied', "
                    + "cleanup_state = 'completed', updated_at_ms = 1"
            ))
            try connection.execute("UPDATE skill_operations "
                + "SET phase = 'filesystemApplied', updated_at_ms = 1")

            #expect(v2SQLIsRejected(
                connection,
                "UPDATE skill_operations SET phase = 'databaseCommitted', "
                    + "outcome = 'needsRepair', updated_at_ms = 2"
            ))
            #expect(v2SQLIsRejected(
                connection,
                "UPDATE skill_operations SET phase = 'databaseCommitted', "
                    + "cleanup_state = 'completed', updated_at_ms = 2"
            ))
            try connection.execute("UPDATE skill_operations "
                + "SET phase = 'databaseCommitted', updated_at_ms = 2")
        }
    }

    @Test("enforces cleanup debt roles for the operation state")
    func enforcesCleanupDebtRoleMatrix() throws {
        try withV2Database { connection in
            try connection.execute(replaceOperationInsert())
            try connection.execute(
                "UPDATE skill_operations SET phase = 'filesystemApplied', updated_at_ms = 1"
            )
            try connection.execute(
                "UPDATE skill_operations SET phase = 'databaseCommitted', updated_at_ms = 2"
            )
            try connection.execute("BEGIN IMMEDIATE")
            do {
                try connection.execute(
                    "UPDATE skill_operations SET cleanup_state = 'pending', "
                        + "cleanup_debt_id = \(v2Blob(v2DebtA)), updated_at_ms = 3"
                )
                #expect(v2SQLIsRejected(connection, cleanupDebtInsert()))
                try connection.execute(recoveryCleanupDebtInsert())
                try connection.execute("COMMIT")
            } catch {
                try? connection.execute("ROLLBACK")
                throw error
            }
        }
    }

    @Test("binds pending cleanup debt atomically and permits a complete retry")
    func bindsAndCompletesCleanupDebt() throws {
        try withV2Database { connection in
            try connection.execute(createOperationInsert())
            try connection.execute("BEGIN IMMEDIATE")
            do {
                try connection.execute(rolledBackPendingUpdate())
                try connection.execute(cleanupDebtInsert())
                try connection.execute("COMMIT")
            } catch {
                try? connection.execute("ROLLBACK")
                throw error
            }

            #expect(try connection.querySingleInt(
                "SELECT count(*) FROM cleanup_debts"
            ) == 1)
            #expect(try connection.querySingleText(
                "SELECT cleanup_state FROM skill_operations"
            ) == "pending")

            try connection.execute("BEGIN IMMEDIATE")
            do {
                try connection.execute(
                    "UPDATE skill_operations SET cleanup_state = 'completed', "
                        + "cleanup_debt_id = NULL, updated_at_ms = 2 "
                        + "WHERE operation_id = \(v2Blob(v2OperationA))"
                )
                try connection.execute(
                    "DELETE FROM cleanup_debts WHERE cleanup_debt_id = \(v2Blob(v2DebtA))"
                )
                try connection.execute("COMMIT")
            } catch {
                try? connection.execute("ROLLBACK")
                throw error
            }

            #expect(try connection.querySingleInt("SELECT count(*) FROM cleanup_debts") == 0)
            #expect(try connection.querySingleText(
                "SELECT cleanup_state FROM skill_operations"
            ) == "completed")
        }
    }

    @Test("rejects pending without its exact debt at transaction commit")
    func rejectsMissingAndMismatchedDebt() throws {
        try withV2Database { connection in
            try connection.execute(createOperationInsert())
            try connection.execute("BEGIN IMMEDIATE")
            try connection.execute(rolledBackPendingUpdate())
            #expect(throws: SQLiteStoreError.self) {
                try connection.execute("COMMIT")
            }
            try connection.execute("ROLLBACK")

            try connection.execute("BEGIN IMMEDIATE")
            try connection.execute(rolledBackPendingUpdate())
            #expect(v2SQLIsRejected(connection, cleanupDebtInsert(
                expectedRootIdentity: v2Blob(v2OtherIdentity)
            )))
            try connection.execute("ROLLBACK")
        }
    }
}

let v2OperationA = "00112233445546778899aabbccddeeff"
let v2OperationB = "11112222333344448555666677778888"
let v2SkillA = "aaaaaaaa111142228333bbbbbbbbbbbb"
let v2DebtA = "bbbbbbbb222243338444cccccccccccc"
let v2Fingerprint = String(repeating: "ab", count: 32)
let v2OldFingerprint = String(repeating: "cd", count: 32)
let v2ItemIdentity = "0000000100000000000000010000000000000001000040000000000000000000"
let v2RootIdentity = "0000000100000000000000010000000000000009000040000000000000000000"
let v2OtherIdentity = "0000000100000000000000010000000000000002000040000000000000000000"

func v2Blob(_ hex: String) -> String { "X'\(hex)'" }

func createOperationInsert(
    operationID: String = v2Blob(v2OperationA),
    stagingLocator: String = ".skillsmanager-tmp-00112233-4455-4677-8899-aabbccddeeff",
    finalLocator: String = "aaaaaaaa-1111-4222-8333-bbbbbbbbbbbb",
    domainPayload: String = "X'7b7d'"
) -> String {
    """
    INSERT INTO skill_operations(
      operation_id, operation_type, skill_id, domain_payload, phase, outcome,
      staging_locator, final_locator, recovery_locator,
      old_fingerprint_algorithm_version, old_content_fingerprint,
      new_fingerprint_algorithm_version, new_content_fingerprint,
      expected_staged_identity, expected_old_identity, expected_new_identity,
      expected_db_revision, expected_root_identity, cleanup_state, cleanup_debt_id,
      attempt_count, last_error, created_at_ms, updated_at_ms
    ) VALUES (
      \(operationID), 'create', \(v2Blob(v2SkillA)), \(domainPayload), 'prepared', NULL,
      '\(stagingLocator)',
      '\(finalLocator)', NULL, NULL, NULL,
      1, \(v2Blob(v2Fingerprint)), \(v2Blob(v2ItemIdentity)), NULL,
      \(v2Blob(v2ItemIdentity)), 0, \(v2Blob(v2RootIdentity)),
      'notApplicable', NULL, 0, NULL, 0, 0
    )
    """
}

func replaceOperationInsert(domainPayload: String = "X'7b7d'") -> String {
    """
    INSERT INTO skill_operations(
      operation_id, operation_type, skill_id, domain_payload, phase, outcome,
      staging_locator, final_locator, recovery_locator,
      old_fingerprint_algorithm_version, old_content_fingerprint,
      new_fingerprint_algorithm_version, new_content_fingerprint,
      expected_staged_identity, expected_old_identity, expected_new_identity,
      expected_db_revision, expected_root_identity, cleanup_state, cleanup_debt_id,
      attempt_count, last_error, created_at_ms, updated_at_ms
    ) VALUES (
      \(v2Blob(v2OperationA)), 'replace', \(v2Blob(v2SkillA)), \(domainPayload), 'prepared', NULL,
      '.skillsmanager-tmp-00112233-4455-4677-8899-aabbccddeeff',
      'aaaaaaaa-1111-4222-8333-bbbbbbbbbbbb',
      '.skillsmanager-tmp-recovery-00112233-4455-4677-8899-aabbccddeeff',
      1, \(v2Blob(v2OldFingerprint)), 1, \(v2Blob(v2Fingerprint)),
      \(v2Blob(v2ItemIdentity)), \(v2Blob(v2OtherIdentity)),
      \(v2Blob(v2ItemIdentity)), 1, \(v2Blob(v2RootIdentity)),
      'notStarted', NULL, 0, NULL, 0, 0
    )
    """
}

func rolledBackPendingUpdate() -> String {
    """
    UPDATE skill_operations
    SET phase = 'completed', outcome = 'rolledBack', cleanup_state = 'pending',
        cleanup_debt_id = \(v2Blob(v2DebtA)), attempt_count = 1,
        last_error = 'cleanup failed', updated_at_ms = 1
    WHERE operation_id = \(v2Blob(v2OperationA))
    """
}

func cleanupDebtInsert(
    expectedRootIdentity: String = v2Blob(v2RootIdentity)
) -> String {
    """
    INSERT INTO cleanup_debts(
      cleanup_debt_id, operation_id, item_role, recovery_locator,
      expected_item_identity, expected_fingerprint_algorithm_version,
      expected_content_fingerprint, expected_root_identity,
      attempt_count, last_error_code, created_at_ms, updated_at_ms
    ) VALUES (
      \(v2Blob(v2DebtA)), \(v2Blob(v2OperationA)), 'staging',
      '.skillsmanager-tmp-00112233-4455-4677-8899-aabbccddeeff',
      \(v2Blob(v2ItemIdentity)), 1, \(v2Blob(v2Fingerprint)),
      \(expectedRootIdentity), 1, 'ioFailure', 1, 1
    )
    """
}

func recoveryCleanupDebtInsert() -> String {
    """
    INSERT INTO cleanup_debts(
      cleanup_debt_id, operation_id, item_role, recovery_locator,
      expected_item_identity, expected_fingerprint_algorithm_version,
      expected_content_fingerprint, expected_root_identity,
      attempt_count, last_error_code, created_at_ms, updated_at_ms
    ) VALUES (
      \(v2Blob(v2DebtA)), \(v2Blob(v2OperationA)), 'recovery',
      '.skillsmanager-tmp-recovery-00112233-4455-4677-8899-aabbccddeeff',
      \(v2Blob(v2OtherIdentity)), 1, \(v2Blob(v2OldFingerprint)),
      \(v2Blob(v2RootIdentity)), 1, 'ioFailure', 3, 3
    )
    """
}

func v2Blob(_ data: Data) -> String {
    v2Blob(data.map { String(format: "%02x", $0) }.joined())
}

func v2SQLIsRejected(_ connection: SQLiteConnection, _ sql: String) -> Bool {
    do {
        try connection.execute(sql)
        return false
    } catch {
        return true
    }
}

func createStructurallyDriftedV2(
    at url: URL,
    transformV1SQL: (Int, String) -> String,
    transformV2SQL: (Int, String) -> String = { _, sql in sql }
) throws {
    let connection = try SQLiteConnection(url: url)
    try connection.setJournalModeWAL()
    try connection.execute("BEGIN IMMEDIATE")
    do {
        for (index, statement) in SkillSchemaV1.statements.enumerated() {
            try connection.execute(transformV1SQL(index, statement))
        }
        try connection.execute(
            "INSERT INTO schema_metadata(singleton, schema_version) VALUES (1, 1)"
        )
        for (index, statement) in SkillSchemaV2.statements.enumerated() {
            try connection.execute(transformV2SQL(index, statement))
        }
        try connection.execute("UPDATE schema_metadata SET schema_version = 2")
        try connection.execute("PRAGMA user_version = 2")
        try connection.execute("COMMIT")
    } catch {
        try? connection.execute("ROLLBACK")
        throw error
    }
}

func withV2Database(_ body: (SQLiteConnection) throws -> Void) throws {
    let location = try v2DatabaseLocation()
    defer { try? FileManager.default.removeItem(at: location.root) }
    try body(try SkillSchemaMigrator.open(at: location.database))
}

func v2DatabaseLocation() throws -> (root: URL, database: URL) {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("skillsmanager-v2-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
    return (root, root.appendingPathComponent("manager.sqlite"))
}

private func createV1Database(at url: URL) throws {
    let connection = try SQLiteConnection(url: url)
    try connection.setJournalModeWAL()
    try connection.execute("BEGIN IMMEDIATE")
    do {
        for statement in SkillSchemaV1.statements {
            try connection.execute(statement)
        }
        try connection.execute(
            "INSERT INTO schema_metadata(singleton, schema_version) VALUES (1, 1)"
        )
        try connection.execute("PRAGMA user_version = 1")
        try connection.execute("COMMIT")
    } catch {
        try? connection.execute("ROLLBACK")
        throw error
    }
}
