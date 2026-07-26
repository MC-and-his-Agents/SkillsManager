import Foundation

nonisolated enum DistributionOperationPhase: String, CaseIterable, Codable, Sendable {
    case prepared
    case applying
    case filesystemApplied
    case databaseCommitted
    case rollingBack
    case cleaning
    case completed
}

nonisolated enum DistributionOperationOutcome: String, CaseIterable, Codable, Sendable {
    case applied
    case rolledBack
    case needsRepair
}

nonisolated enum DistributionOperationPayloadError: Error, Equatable {
    case empty
    case tooLarge
    case notCanonical
    case invalid
}

/// Canonical JSON for journal payloads. The store keeps payloads opaque so the
/// executor can evolve its versioned plan without widening the SQLite schema.
nonisolated enum DistributionOperationPayloadCodec {
    static let maximumByteCount = 65_536

    static func encode<T: Encodable>(_ value: T) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        let data = try encoder.encode(value)
        try validate(data)
        return data
    }

    static func decode<T: Decodable & Encodable>(_ type: T.Type, from data: Data) throws -> T {
        try validate(data)
        let value = try JSONDecoder().decode(type, from: data)
        guard try encode(value) == data else {
            throw DistributionOperationPayloadError.notCanonical
        }
        return value
    }

    static func validate(_ data: Data) throws {
        guard !data.isEmpty else { throw DistributionOperationPayloadError.empty }
        guard data.count <= maximumByteCount else {
            throw DistributionOperationPayloadError.tooLarge
        }
        let object: Any
        do {
            object = try JSONSerialization.jsonObject(with: data)
        } catch {
            throw DistributionOperationPayloadError.invalid
        }
        guard JSONSerialization.isValidJSONObject(object) else {
            throw DistributionOperationPayloadError.invalid
        }
    }
}

nonisolated struct DistributionOperationDraft: Sendable, Equatable {
    let operationID: SSOTOperationID
    let skillID: SkillID
    let oldBindings: Data
    let newBindings: Data
    let planPayload: Data
    let preflightPayload: Data
    let runtimePayload: Data
    let createdAtMilliseconds: Int64
    let updatedAtMilliseconds: Int64

    init(
        operationID: SSOTOperationID = SSOTOperationID(),
        skillID: SkillID,
        oldBindings: Data,
        newBindings: Data,
        planPayload: Data,
        preflightPayload: Data,
        runtimePayload: Data,
        createdAtMilliseconds: Int64,
        updatedAtMilliseconds: Int64? = nil
    ) throws {
        let updated = updatedAtMilliseconds ?? createdAtMilliseconds
        try DistributionOperationRecord.validate(
            oldBindings: oldBindings,
            newBindings: newBindings,
            planPayload: planPayload,
            preflightPayload: preflightPayload,
            runtimePayload: runtimePayload,
            forwardCursor: 0,
            rollbackCursor: 0,
            cleanupCursor: 0,
            attemptCount: 0,
            lastError: nil,
            createdAtMilliseconds: createdAtMilliseconds,
            updatedAtMilliseconds: updated,
            phase: .prepared,
            outcome: nil
        )
        self.operationID = operationID
        self.skillID = skillID
        self.oldBindings = oldBindings
        self.newBindings = newBindings
        self.planPayload = planPayload
        self.preflightPayload = preflightPayload
        self.runtimePayload = runtimePayload
        self.createdAtMilliseconds = createdAtMilliseconds
        self.updatedAtMilliseconds = updated
    }

    var record: DistributionOperationRecord {
        // Validation is performed by the initializer above.
        DistributionOperationRecord(
            operationID: operationID,
            skillID: skillID,
            phase: .prepared,
            outcome: nil,
            oldBindings: oldBindings,
            newBindings: newBindings,
            planPayload: planPayload,
            preflightPayload: preflightPayload,
            runtimePayload: runtimePayload,
            forwardCursor: 0,
            rollbackCursor: 0,
            cleanupCursor: 0,
            attemptCount: 0,
            lastError: nil,
            createdAtMilliseconds: createdAtMilliseconds,
            updatedAtMilliseconds: updatedAtMilliseconds
        )
    }
}

nonisolated struct DistributionOperationRecord: Sendable, Equatable {
    let operationID: SSOTOperationID
    let skillID: SkillID
    let phase: DistributionOperationPhase
    let outcome: DistributionOperationOutcome?
    let oldBindings: Data
    let newBindings: Data
    let planPayload: Data
    let preflightPayload: Data
    let runtimePayload: Data
    let forwardCursor: Int64
    let rollbackCursor: Int64
    let cleanupCursor: Int64
    let attemptCount: Int64
    let lastError: String?
    let createdAtMilliseconds: Int64
    let updatedAtMilliseconds: Int64

    init(
        operationID: SSOTOperationID,
        skillID: SkillID,
        phase: DistributionOperationPhase,
        outcome: DistributionOperationOutcome?,
        oldBindings: Data,
        newBindings: Data,
        planPayload: Data,
        preflightPayload: Data,
        runtimePayload: Data,
        forwardCursor: Int64,
        rollbackCursor: Int64,
        cleanupCursor: Int64,
        attemptCount: Int64,
        lastError: String?,
        createdAtMilliseconds: Int64,
        updatedAtMilliseconds: Int64
    ) {
        self.operationID = operationID
        self.skillID = skillID
        self.phase = phase
        self.outcome = outcome
        self.oldBindings = oldBindings
        self.newBindings = newBindings
        self.planPayload = planPayload
        self.preflightPayload = preflightPayload
        self.runtimePayload = runtimePayload
        self.forwardCursor = forwardCursor
        self.rollbackCursor = rollbackCursor
        self.cleanupCursor = cleanupCursor
        self.attemptCount = attemptCount
        self.lastError = lastError
        self.createdAtMilliseconds = createdAtMilliseconds
        self.updatedAtMilliseconds = updatedAtMilliseconds
    }

    fileprivate static func validate(
        oldBindings: Data,
        newBindings: Data,
        planPayload: Data,
        preflightPayload: Data,
        runtimePayload: Data,
        forwardCursor: Int64,
        rollbackCursor: Int64,
        cleanupCursor: Int64,
        attemptCount: Int64,
        lastError: String?,
        createdAtMilliseconds: Int64,
        updatedAtMilliseconds: Int64,
        phase: DistributionOperationPhase,
        outcome: DistributionOperationOutcome?
    ) throws {
        for payload in [oldBindings, newBindings, planPayload, preflightPayload, runtimePayload] {
            guard !payload.isEmpty, payload.count <= DistributionOperationPayloadCodec.maximumByteCount else {
                throw DistributionOperationStoreError.invalidRecord
            }
        }
        guard forwardCursor >= 0, rollbackCursor >= 0, cleanupCursor >= 0,
              attemptCount >= 0, createdAtMilliseconds >= 0,
              updatedAtMilliseconds >= createdAtMilliseconds,
              (lastError?.utf8.count ?? 0) <= 4_096 else {
            throw DistributionOperationStoreError.invalidRecord
        }
        if phase == .completed {
            guard outcome == .applied || outcome == .rolledBack || outcome == .needsRepair else {
                throw DistributionOperationStoreError.invalidRecord
            }
        } else if outcome == .applied || outcome == .rolledBack {
            throw DistributionOperationStoreError.invalidRecord
        }
    }
}

nonisolated enum DistributionOperationStoreError: Error, Equatable, LocalizedError {
    case invalidRecord
    case operationNotFound
    case conflict
    case corruptRecord

    var errorDescription: String? {
        switch self {
        case .invalidRecord: "The distribution operation record is invalid."
        case .operationNotFound: "The distribution operation was not found."
        case .conflict: "The distribution operation changed concurrently."
        case .corruptRecord: "The distribution operation record is corrupt."
        }
    }
}

nonisolated final class DistributionOperationStore {
    let connection: SQLiteConnection

    init(connection: SQLiteConnection) throws {
        guard connection.accessMode != .readOnly else {
            throw SQLiteStoreError.invalidState("the distribution operation store requires read-write access")
        }
        self.connection = connection
    }

    func insertPrepared(_ draft: DistributionOperationDraft) throws -> DistributionOperationRecord {
        let record = draft.record
        let statement = try connection.prepare(
            """
            INSERT INTO distribution_operations(
              operation_id, format_version, skill_id, phase, outcome,
              old_bindings, new_bindings, plan_payload, preflight_payload, runtime_payload,
              forward_cursor, rollback_cursor, cleanup_cursor, attempt_count, last_error,
              created_at_ms, updated_at_ms
            ) VALUES (?, 1, ?, 'prepared', NULL, ?, ?, ?, ?, ?, 0, 0, 0, 0, NULL, ?, ?)
            """
        )
        try statement.bind(record.operationID.bytes, at: 1)
        try statement.bind(record.skillID.bytes, at: 2)
        try statement.bind(record.oldBindings, at: 3)
        try statement.bind(record.newBindings, at: 4)
        try statement.bind(record.planPayload, at: 5)
        try statement.bind(record.preflightPayload, at: 6)
        try statement.bind(record.runtimePayload, at: 7)
        try statement.bind(record.createdAtMilliseconds, at: 8)
        try statement.bind(record.updatedAtMilliseconds, at: 9)
        do {
            guard try !statement.step() else { throw DistributionOperationStoreError.corruptRecord }
        } catch let error as DistributionOperationStoreError {
            throw error
        } catch {
            throw DistributionOperationStoreError.conflict
        }
        return record
    }

    func load(_ operationID: SSOTOperationID) throws -> DistributionOperationRecord {
        try loadOperation(operationID)
    }

    func loadOperation(_ operationID: SSOTOperationID) throws -> DistributionOperationRecord {
        let statement = try connection.prepare(Self.selectSQL + " AND operation_id = ?")
        try statement.bind(operationID.bytes, at: 1)
        guard try statement.step() else { throw DistributionOperationStoreError.operationNotFound }
        let record = try decode(statement)
        guard try !statement.step() else { throw DistributionOperationStoreError.corruptRecord }
        return record
    }

    func recoverableOperations() throws -> [DistributionOperationRecord] {
        try loadMany(
            "outcome IS NULL AND phase <> 'completed' ORDER BY created_at_ms, operation_id"
        )
    }

    func recoverableOperationIDs() throws -> [SSOTOperationID] {
        try recoverableOperations().map(\.operationID)
    }

    func repairRequiredOperations() throws -> [DistributionOperationRecord] {
        try loadMany("outcome = 'needsRepair' ORDER BY created_at_ms, operation_id")
    }

    func updateProgress(
        operationID: SSOTOperationID,
        phase: DistributionOperationPhase,
        forwardCursor: Int64,
        rollbackCursor: Int64,
        cleanupCursor: Int64,
        runtimePayload: Data,
        attemptCount: Int64,
        lastError: String?,
        updatedAtMilliseconds: Int64
    ) throws {
        try DistributionOperationRecord.validate(
            oldBindings: Data([1]), newBindings: Data([1]), planPayload: Data([1]),
            preflightPayload: Data([1]), runtimePayload: runtimePayload,
            forwardCursor: forwardCursor, rollbackCursor: rollbackCursor,
            cleanupCursor: cleanupCursor, attemptCount: attemptCount, lastError: lastError,
            createdAtMilliseconds: 0, updatedAtMilliseconds: updatedAtMilliseconds,
            phase: phase, outcome: nil
        )
        let statement = try connection.prepare(
            """
            UPDATE distribution_operations
            SET phase = ?, runtime_payload = ?, forward_cursor = ?,
                rollback_cursor = ?, cleanup_cursor = ?, attempt_count = ?,
                last_error = ?, updated_at_ms = ?
            WHERE operation_id = ? AND outcome IS NULL AND phase <> 'completed'
            """
        )
        try statement.bind(phase.rawValue, at: 1)
        try statement.bind(runtimePayload, at: 2)
        try statement.bind(forwardCursor, at: 3)
        try statement.bind(rollbackCursor, at: 4)
        try statement.bind(cleanupCursor, at: 5)
        try statement.bind(attemptCount, at: 6)
        if let lastError { try statement.bind(lastError, at: 7) } else { try statement.bindNull(at: 7) }
        try statement.bind(updatedAtMilliseconds, at: 8)
        try statement.bind(operationID.bytes, at: 9)
        try finishMutation(statement)
    }

    func markNeedsRepair(
        operationID: SSOTOperationID,
        detail: String,
        updatedAtMilliseconds: Int64
    ) throws {
        guard detail.utf8.count <= 4_096, updatedAtMilliseconds >= 0 else {
            throw DistributionOperationStoreError.invalidRecord
        }
        let statement = try connection.prepare(
            """
            UPDATE distribution_operations
            SET outcome = 'needsRepair', attempt_count = attempt_count + 1,
                last_error = ?, updated_at_ms = MAX(updated_at_ms, ?)
            WHERE operation_id = ? AND outcome IS NULL AND phase <> 'completed'
            """
        )
        try statement.bind(detail, at: 1)
        try statement.bind(updatedAtMilliseconds, at: 2)
        try statement.bind(operationID.bytes, at: 3)
        try finishMutation(statement)
    }

    func complete(
        operationID: SSOTOperationID,
        outcome: DistributionOperationOutcome,
        updatedAtMilliseconds: Int64
    ) throws {
        guard outcome == .applied || outcome == .rolledBack,
              updatedAtMilliseconds >= 0 else {
            throw DistributionOperationStoreError.invalidRecord
        }
        let statement = try connection.prepare(
            """
            UPDATE distribution_operations
            SET phase = 'completed', outcome = ?, updated_at_ms = MAX(updated_at_ms, ?)
            WHERE operation_id = ? AND outcome IS NULL
            """
        )
        try statement.bind(outcome.rawValue, at: 1)
        try statement.bind(updatedAtMilliseconds, at: 2)
        try statement.bind(operationID.bytes, at: 3)
        try finishMutation(statement)
    }

    func transaction<T>(_ body: () throws -> T) throws -> T {
        try connection.withImmediateTransaction(body)
    }

    private func loadMany(_ suffix: String) throws -> [DistributionOperationRecord] {
        let statement = try connection.prepare(Self.selectSQL + " AND " + suffix)
        var records: [DistributionOperationRecord] = []
        while try statement.step() { records.append(try decode(statement)) }
        return records
    }

    private func decode(_ statement: SQLiteStatement) throws -> DistributionOperationRecord {
        do {
            let phase = try distributionRequiredEnum(statement, 3, as: DistributionOperationPhase.self)
            let outcome = try distributionOptionalEnum(
                statement.text(at: 4), as: DistributionOperationOutcome.self
            )
            let record = DistributionOperationRecord(
                operationID: try SSOTOperationID(bytes: distributionRequiredBlob(statement, 0)),
                skillID: try SkillID(bytes: distributionRequiredBlob(statement, 2)),
                phase: phase,
                outcome: outcome,
                oldBindings: try distributionRequiredBlob(statement, 5),
                newBindings: try distributionRequiredBlob(statement, 6),
                planPayload: try distributionRequiredBlob(statement, 7),
                preflightPayload: try distributionRequiredBlob(statement, 8),
                runtimePayload: try distributionRequiredBlob(statement, 9),
                forwardCursor: statement.int64(at: 10),
                rollbackCursor: statement.int64(at: 11),
                cleanupCursor: statement.int64(at: 12),
                attemptCount: statement.int64(at: 13),
                lastError: statement.text(at: 14),
                createdAtMilliseconds: statement.int64(at: 15),
                updatedAtMilliseconds: statement.int64(at: 16)
            )
            try DistributionOperationRecord.validate(
                oldBindings: record.oldBindings, newBindings: record.newBindings,
                planPayload: record.planPayload, preflightPayload: record.preflightPayload,
                runtimePayload: record.runtimePayload, forwardCursor: record.forwardCursor,
                rollbackCursor: record.rollbackCursor, cleanupCursor: record.cleanupCursor,
                attemptCount: record.attemptCount, lastError: record.lastError,
                createdAtMilliseconds: record.createdAtMilliseconds,
                updatedAtMilliseconds: record.updatedAtMilliseconds,
                phase: record.phase, outcome: record.outcome
            )
            return record
        } catch let error as DistributionOperationStoreError {
            throw error
        } catch {
            throw DistributionOperationStoreError.corruptRecord
        }
    }

    private func finishMutation(_ statement: SQLiteStatement) throws {
        guard try !statement.step(),
              try connection.querySingleInt("SELECT changes()") == 1 else {
            throw DistributionOperationStoreError.conflict
        }
    }

    private static let selectSQL = """
    SELECT operation_id, format_version, skill_id, phase, outcome,
           old_bindings, new_bindings, plan_payload, preflight_payload, runtime_payload,
           forward_cursor, rollback_cursor, cleanup_cursor, attempt_count, last_error,
           created_at_ms, updated_at_ms
    FROM distribution_operations
    WHERE format_version = 1
    """
}

nonisolated func distributionRequiredBlob(
    _ statement: SQLiteStatement,
    _ column: Int32
) throws -> Data {
    guard let data = statement.blob(at: column) else {
        throw DistributionOperationStoreError.corruptRecord
    }
    return data
}

private nonisolated func distributionRequiredEnum<T: RawRepresentable>(
    _ statement: SQLiteStatement,
    _ column: Int32,
    as type: T.Type
) throws -> T where T.RawValue == String {
    guard let value = statement.text(at: column), let result = T(rawValue: value) else {
        throw DistributionOperationStoreError.corruptRecord
    }
    return result
}

private nonisolated func distributionOptionalEnum<T: RawRepresentable>(
    _ rawValue: String?,
    as type: T.Type
) throws -> T? where T.RawValue == String {
    guard let rawValue else { return nil }
    guard let result = T(rawValue: rawValue) else {
        throw DistributionOperationStoreError.corruptRecord
    }
    return result
}
