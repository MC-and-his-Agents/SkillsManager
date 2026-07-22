import Foundation

nonisolated final class SSOTJournalStore {
    let connection: SQLiteConnection

    init(connection: SQLiteConnection) throws {
        guard connection.accessMode == .readWrite else {
            throw SQLiteStoreError.invalidState("the SSOT journal store requires read-write access")
        }
        self.connection = connection
    }

    func insertPrepared(_ record: SSOTJournalRecord) throws {
        guard record.state.phase == .prepared,
              record.state.outcome == .pending,
              record.cleanupDebtID == nil else {
            throw SSOTJournalStoreError.invalidRecord
        }
        let statement = try connection.prepare(
            """
            INSERT INTO skill_operations(
              operation_id, operation_type, skill_id, phase, outcome,
              staging_locator, final_locator, recovery_locator,
              old_fingerprint_algorithm_version, old_content_fingerprint,
              new_fingerprint_algorithm_version, new_content_fingerprint, domain_payload,
              expected_staged_identity, expected_old_identity, expected_new_identity,
              expected_db_revision, expected_root_identity, cleanup_state, cleanup_debt_id,
              attempt_count, last_error, created_at_ms, updated_at_ms
            ) VALUES (?, ?, ?, ?, NULL, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, NULL, ?, ?, ?, ?)
            """
        )
        try bindPrepared(record, to: statement)
        guard try !statement.step() else {
            throw SSOTJournalStoreError.corruptRecord("INSERT unexpectedly returned a row")
        }
    }

    func loadOperation(_ operationID: SSOTOperationID) throws -> SSOTJournalRecord {
        let statement = try connection.prepare(Self.operationSelect + " WHERE operation_id = ?")
        try statement.bind(operationID.bytes, at: 1)
        guard try statement.step() else { throw SSOTJournalStoreError.operationNotFound }
        let record = try decodeOperation(statement)
        guard try !statement.step() else {
            throw SSOTJournalStoreError.corruptRecord("duplicate operation UUID")
        }
        return record
    }

    func recoverableOperations() throws -> [SSOTJournalRecord] {
        let statement = try connection.prepare(
            Self.operationSelect
                + " WHERE outcome IS NOT 'needsRepair'"
                + " AND (phase <> 'completed' OR cleanup_state = 'pending')"
                + " ORDER BY created_at_ms, operation_id"
        )
        var records: [SSOTJournalRecord] = []
        while try statement.step() {
            records.append(try decodeOperation(statement))
        }
        return records
    }

    func recoverableOperationIDs() throws -> [SSOTOperationID] {
        let statement = try connection.prepare(
            """
            SELECT operation_id FROM skill_operations
            WHERE outcome IS NOT 'needsRepair'
              AND (phase <> 'completed' OR cleanup_state = 'pending')
            ORDER BY created_at_ms, operation_id
            """
        )
        var operationIDs: [SSOTOperationID] = []
        while try statement.step() {
            operationIDs.append(
                try SSOTOperationID(bytes: journalRequiredBlob(statement, 0))
            )
        }
        return operationIDs
    }

    func repairRequiredOperations() throws -> [SSOTJournalRecord] {
        let statement = try connection.prepare(
            Self.operationSelect
                + " WHERE outcome = 'needsRepair' OR cleanup_state = 'needsRepair'"
                + " ORDER BY created_at_ms, operation_id"
        )
        var records: [SSOTJournalRecord] = []
        while try statement.step() {
            records.append(try decodeOperation(statement))
        }
        return records
    }

    func firstRepairRequiredOperation() throws -> (
        operationID: SSOTOperationID,
        code: SSOTRecoveryErrorCode
    )? {
        let statement = try connection.prepare(
            """
            SELECT operation_id, cleanup_state FROM skill_operations
            WHERE outcome = 'needsRepair' OR cleanup_state = 'needsRepair'
            ORDER BY created_at_ms, operation_id LIMIT 1
            """
        )
        guard try statement.step() else { return nil }
        let operationID = try SSOTOperationID(bytes: journalRequiredBlob(statement, 0))
        let code: SSOTRecoveryErrorCode = statement.text(at: 1) == SSOTCleanupState.needsRepair.rawValue
            ? .cleanupIdentityDrift : .journalMarkedNeedsRepair
        return (operationID, code)
    }

    func recordFilesystemApplied(
        operationID: SSOTOperationID,
        updatedAtMilliseconds: Int64
    ) throws {
        try updateState(
            sql: """
            UPDATE skill_operations
            SET phase = 'filesystemApplied', updated_at_ms = ?
            WHERE operation_id = ? AND phase = 'prepared' AND outcome IS NULL
            """,
            operationID: operationID,
            updatedAtMilliseconds: updatedAtMilliseconds
        )
    }

    func completeApplied(
        operationID: SSOTOperationID,
        cleanupState: SSOTCleanupState,
        updatedAtMilliseconds: Int64
    ) throws {
        guard cleanupState == .notApplicable || cleanupState == .completed else {
            throw SSOTJournalStoreError.invalidRecord
        }
        let statement = try connection.prepare(
            """
            UPDATE skill_operations
            SET phase = 'completed', outcome = 'applied', cleanup_state = ?,
                cleanup_debt_id = NULL, updated_at_ms = ?
            WHERE operation_id = ? AND phase = 'databaseCommitted' AND outcome IS NULL
            """
        )
        try statement.bind(cleanupState.rawValue, at: 1)
        try statement.bind(updatedAtMilliseconds, at: 2)
        try statement.bind(operationID.bytes, at: 3)
        try finishMutation(statement)
    }

    func completeRolledBack(
        operationID: SSOTOperationID,
        updatedAtMilliseconds: Int64
    ) throws {
        let statement = try connection.prepare(
            """
            UPDATE skill_operations
            SET phase = 'completed', outcome = 'rolledBack', cleanup_state = 'completed',
                cleanup_debt_id = NULL, updated_at_ms = ?
            WHERE operation_id = ? AND phase = 'prepared' AND outcome IS NULL
            """
        )
        try statement.bind(updatedAtMilliseconds, at: 1)
        try statement.bind(operationID.bytes, at: 2)
        try finishMutation(statement)
    }

    func markNeedsRepair(
        operationID: SSOTOperationID,
        errorCode: SSOTRecoveryErrorCode,
        detail: String,
        updatedAtMilliseconds: Int64
    ) throws {
        let error = boundedJournalError(
            "\(errorCode.rawValue): \(detail)",
            maximumBytes: SSOTRecoveryLimits.default.maximumLastErrorUTF8ByteCount
        )
        let statement = try connection.prepare(
            """
            UPDATE skill_operations
            SET outcome = 'needsRepair', attempt_count = attempt_count + 1,
                last_error = ?, updated_at_ms = ?
            WHERE operation_id = ? AND phase <> 'completed' AND outcome IS NULL
            """
        )
        try statement.bind(error, at: 1)
        try statement.bind(updatedAtMilliseconds, at: 2)
        try statement.bind(operationID.bytes, at: 3)
        try finishMutation(statement)
    }

    func markCorruptOperationNeedsRepair(
        operationID: SSOTOperationID,
        detail: String,
        updatedAtMilliseconds: Int64
    ) throws {
        let error = boundedJournalError(
            "\(SSOTRecoveryErrorCode.invalidJournalState.rawValue): \(detail)",
            maximumBytes: SSOTRecoveryLimits.default.maximumLastErrorUTF8ByteCount
        )
        let statement = try connection.prepare(
            """
            UPDATE skill_operations
            SET outcome = 'needsRepair', attempt_count = attempt_count + 1,
                last_error = ?, updated_at_ms = MAX(updated_at_ms, ?)
            WHERE operation_id = ? AND phase <> 'completed' AND outcome IS NULL
            """
        )
        try statement.bind(error, at: 1)
        try statement.bind(updatedAtMilliseconds, at: 2)
        try statement.bind(operationID.bytes, at: 3)
        guard try !statement.step() else {
            throw SSOTJournalStoreError.corruptRecord("mutation unexpectedly returned a row")
        }
        if try connection.querySingleInt("SELECT changes()") == 1 { return }

        let retainedBlocker = try connection.prepare(
            """
            SELECT count(*) FROM skill_operations
            WHERE operation_id = ? AND (phase = 'completed' OR outcome = 'needsRepair')
            """
        )
        try retainedBlocker.bind(operationID.bytes, at: 1)
        guard try retainedBlocker.step(), retainedBlocker.int64(at: 0) == 1 else {
            throw SSOTJournalStoreError.stateConflict
        }
    }

    func transaction<T>(_ body: () throws -> T) throws -> T {
        try connection.execute("BEGIN IMMEDIATE")
        do {
            let result = try body()
            try connection.execute("COMMIT")
            return result
        } catch {
            try? connection.execute("ROLLBACK")
            throw error
        }
    }

    func finishMutation(_ statement: SQLiteStatement) throws {
        guard try !statement.step() else {
            throw SSOTJournalStoreError.corruptRecord("mutation unexpectedly returned a row")
        }
        guard try connection.querySingleInt("SELECT changes()") == 1 else {
            throw SSOTJournalStoreError.stateConflict
        }
    }

    private func updateState(
        sql: String,
        operationID: SSOTOperationID,
        updatedAtMilliseconds: Int64
    ) throws {
        let statement = try connection.prepare(sql)
        try statement.bind(updatedAtMilliseconds, at: 1)
        try statement.bind(operationID.bytes, at: 2)
        try finishMutation(statement)
    }

    private func bindPrepared(
        _ record: SSOTJournalRecord,
        to statement: SQLiteStatement
    ) throws {
        try statement.bind(record.operationID.bytes, at: 1)
        try statement.bind(record.operationType.rawValue, at: 2)
        try statement.bind(record.skillID.bytes, at: 3)
        try statement.bind(record.state.phase.rawValue, at: 4)
        try statement.bind(record.stagingLocator, at: 5)
        try statement.bind(record.finalLocator, at: 6)
        try bind(record.recoveryLocator, to: statement, at: 7)
        try bind(record.oldFingerprint?.algorithmVersion, to: statement, at: 8)
        try bind(record.oldFingerprint?.digest, to: statement, at: 9)
        try statement.bind(Int64(record.newFingerprint.algorithmVersion), at: 10)
        try statement.bind(record.newFingerprint.digest, at: 11)
        try statement.bind(SSOTWritePayloadCodec.encode(record.payload), at: 12)
        try statement.bind(ManagedItemIdentityCodec.encode(record.expectedStagedIdentity), at: 13)
        try bind(record.expectedOldIdentity, to: statement, at: 14)
        try statement.bind(ManagedItemIdentityCodec.encode(record.expectedNewIdentity), at: 15)
        try statement.bind(record.expectedDatabaseRevision, at: 16)
        try statement.bind(ManagedItemIdentityCodec.encode(record.expectedRootIdentity), at: 17)
        try statement.bind(record.state.cleanupState.rawValue, at: 18)
        try statement.bind(record.attemptCount, at: 19)
        try bind(record.lastError, to: statement, at: 20)
        try statement.bind(record.createdAtMilliseconds, at: 21)
        try statement.bind(record.updatedAtMilliseconds, at: 22)
    }

    private func decodeOperation(_ statement: SQLiteStatement) throws -> SSOTJournalRecord {
        do {
            let outcome = try optionalEnum(
                statement.text(at: 4),
                as: SSOTOperationOutcome.self
            ) ?? .pending
            let oldDigest = statement.blob(at: 9)
            let oldFingerprint = try oldDigest.map {
                try SkillContentFingerprint(
                    algorithmVersion: Int(statement.int64(at: 8)),
                    digest: $0
                )
            }
            return try SSOTJournalRecord(
                operationID: SSOTOperationID(bytes: try journalRequiredBlob(statement, 0)),
                operationType: try journalRequiredEnum(statement, 1, as: SSOTOperationType.self),
                skillID: SkillID(bytes: try journalRequiredBlob(statement, 2)),
                state: SSOTJournalState(
                    phase: try journalRequiredEnum(statement, 3, as: SSOTJournalPhase.self),
                    outcome: outcome,
                    cleanupState: try journalRequiredEnum(statement, 18, as: SSOTCleanupState.self)
                ),
                stagingLocator: try journalRequiredText(statement, 5),
                finalLocator: try journalRequiredText(statement, 6),
                recoveryLocator: statement.text(at: 7),
                oldFingerprint: oldFingerprint,
                newFingerprint: try SkillContentFingerprint(
                    algorithmVersion: Int(statement.int64(at: 10)),
                    digest: try journalRequiredBlob(statement, 11)
                ),
                payload: try SSOTWritePayloadCodec.decode(try journalRequiredBlob(statement, 12)),
                expectedStagedIdentity: try ManagedItemIdentityCodec.decode(
                    try journalRequiredBlob(statement, 13)
                ),
                expectedOldIdentity: try statement.blob(at: 14).map(ManagedItemIdentityCodec.decode),
                expectedNewIdentity: try ManagedItemIdentityCodec.decode(
                    try journalRequiredBlob(statement, 15)
                ),
                expectedDatabaseRevision: statement.int64(at: 16),
                expectedRootIdentity: try ManagedItemIdentityCodec.decode(
                    try journalRequiredBlob(statement, 17)
                ),
                cleanupDebtID: try statement.blob(at: 19).map(SSOTCleanupDebtID.init(bytes:)),
                attemptCount: statement.int64(at: 20),
                lastError: statement.text(at: 21),
                createdAtMilliseconds: statement.int64(at: 22),
                updatedAtMilliseconds: statement.int64(at: 23)
            )
        } catch let error as SSOTJournalStoreError {
            throw error
        } catch {
            throw SSOTJournalStoreError.corruptRecord(error.localizedDescription)
        }
    }

    private static let operationSelect = """
    SELECT operation_id, operation_type, skill_id, phase, outcome,
           staging_locator, final_locator, recovery_locator,
           old_fingerprint_algorithm_version, old_content_fingerprint,
           new_fingerprint_algorithm_version, new_content_fingerprint, domain_payload,
           expected_staged_identity, expected_old_identity, expected_new_identity,
           expected_db_revision, expected_root_identity, cleanup_state, cleanup_debt_id,
           attempt_count, last_error, created_at_ms, updated_at_ms
    FROM skill_operations
    """
}

private nonisolated func bind(_ value: String?, to statement: SQLiteStatement, at index: Int32) throws {
    if let value { try statement.bind(value, at: index) } else { try statement.bindNull(at: index) }
}

private nonisolated func bind(_ value: Data?, to statement: SQLiteStatement, at index: Int32) throws {
    if let value { try statement.bind(value, at: index) } else { try statement.bindNull(at: index) }
}

private nonisolated func bind(_ value: Int?, to statement: SQLiteStatement, at index: Int32) throws {
    if let value { try statement.bind(Int64(value), at: index) } else { try statement.bindNull(at: index) }
}

private nonisolated func bind(
    _ value: ManagedItemIdentity?,
    to statement: SQLiteStatement,
    at index: Int32
) throws {
    try bind(value.map(ManagedItemIdentityCodec.encode), to: statement, at: index)
}

nonisolated func journalRequiredText(_ statement: SQLiteStatement, _ column: Int32) throws -> String {
    guard let value = statement.text(at: column) else {
        throw SSOTJournalStoreError.corruptRecord("column \(column) is NULL")
    }
    return value
}

nonisolated func journalRequiredBlob(_ statement: SQLiteStatement, _ column: Int32) throws -> Data {
    guard let value = statement.blob(at: column) else {
        throw SSOTJournalStoreError.corruptRecord("column \(column) is NULL")
    }
    return value
}

nonisolated func journalRequiredEnum<T: RawRepresentable>(
    _ statement: SQLiteStatement,
    _ column: Int32,
    as type: T.Type
) throws -> T where T.RawValue == String {
    guard let value = T(rawValue: try journalRequiredText(statement, column)) else {
        throw SSOTJournalStoreError.corruptRecord("column \(column) has an unknown enum value")
    }
    return value
}

private nonisolated func optionalEnum<T: RawRepresentable>(
    _ rawValue: String?,
    as type: T.Type
) throws -> T? where T.RawValue == String {
    guard let rawValue else { return nil }
    guard let value = T(rawValue: rawValue) else {
        throw SSOTJournalStoreError.corruptRecord("unknown enum value \(rawValue)")
    }
    return value
}

nonisolated func boundedJournalError(_ value: String, maximumBytes: Int) -> String {
    var result = ""
    var bytes = 0
    for character in value {
        let count = String(character).utf8.count
        guard bytes + count <= maximumBytes else { break }
        result.append(character)
        bytes += count
    }
    return result.isEmpty ? "SSOT recovery failed" : result
}
