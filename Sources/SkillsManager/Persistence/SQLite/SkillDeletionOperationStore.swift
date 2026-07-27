import Foundation

nonisolated enum SkillDeletionPhase: String, CaseIterable, Codable, Sendable {
    case prepared
    case backupPublished
    case distributionRemoved
    case ssotQuarantined
    case databaseCommitted
    case completed
}

nonisolated enum SkillDeletionOutcome: String, CaseIterable, Codable, Sendable {
    case pending
    case applied
    case rolledBack
    case needsRepair
}

nonisolated enum SkillDeletionCleanupState: String, CaseIterable, Codable, Sendable {
    case notApplicable
    case notStarted
    case pending
    case completed
    case needsRepair
}

nonisolated enum SkillDeletionOperationStoreError: Error, Equatable, LocalizedError {
    case invalidRecord
    case operationNotFound
    case conflict
    case corruptRecord

    var errorDescription: String? {
        switch self {
        case .invalidRecord: "The Skill deletion operation is invalid."
        case .operationNotFound: "The Skill deletion operation was not found."
        case .conflict: "The Skill deletion operation changed concurrently."
        case .corruptRecord: "The Skill deletion operation is corrupt."
        }
    }
}

nonisolated struct SkillDeletionOperationDraft: Sendable {
    let operationID: SSOTOperationID
    let skillID: SkillID
    let backupID: SkillBackupID
    let domainPayload: Data
    let expectationPayload: Data
    let distributionPlan: Data
    let ssotIdentity: ManagedItemIdentity
    let quarantineLocator: String
    let createdAtMilliseconds: Int64

    init(
        operationID: SSOTOperationID = SSOTOperationID(),
        skillID: SkillID,
        backupID: SkillBackupID,
        domainPayload: Data,
        expectationPayload: Data,
        distributionPlan: Data,
        ssotIdentity: ManagedItemIdentity,
        quarantineLocator: String,
        createdAtMilliseconds: Int64
    ) throws {
        try SkillBackupCanonicalJSON.validate(domainPayload)
        try SkillBackupCanonicalJSON.validate(expectationPayload)
        try SkillBackupCanonicalJSON.validate(distributionPlan)
        guard SkillBackupRecord.validLocator(quarantineLocator),
              createdAtMilliseconds >= 0 else {
            throw SkillDeletionOperationStoreError.invalidRecord
        }
        self.operationID = operationID
        self.skillID = skillID
        self.backupID = backupID
        self.domainPayload = domainPayload
        self.expectationPayload = expectationPayload
        self.distributionPlan = distributionPlan
        self.ssotIdentity = ssotIdentity
        self.quarantineLocator = quarantineLocator
        self.createdAtMilliseconds = createdAtMilliseconds
    }

    func record() throws -> SkillDeletionOperationRecord {
        try SkillDeletionOperationRecord(
            operationID: operationID,
            skillID: skillID,
            backupID: backupID,
            phase: .prepared,
            outcome: .pending,
            cleanupState: .notApplicable,
            domainPayload: domainPayload,
            expectationPayload: expectationPayload,
            distributionPlan: distributionPlan,
            ssotIdentity: ssotIdentity,
            quarantineLocator: quarantineLocator,
            quarantineIdentity: nil,
            attemptCount: 0,
            lastError: nil,
            createdAtMilliseconds: createdAtMilliseconds,
            updatedAtMilliseconds: createdAtMilliseconds
        )
    }
}

nonisolated struct SkillDeletionOperationRecord: Equatable, Sendable {
    let operationID: SSOTOperationID
    let skillID: SkillID
    let backupID: SkillBackupID
    let phase: SkillDeletionPhase
    let outcome: SkillDeletionOutcome
    let cleanupState: SkillDeletionCleanupState
    let domainPayload: Data
    let expectationPayload: Data
    let distributionPlan: Data
    let ssotIdentity: ManagedItemIdentity
    let quarantineLocator: String
    let quarantineIdentity: ManagedItemIdentity?
    let attemptCount: Int64
    let lastError: String?
    let createdAtMilliseconds: Int64
    let updatedAtMilliseconds: Int64

    init(
        operationID: SSOTOperationID,
        skillID: SkillID,
        backupID: SkillBackupID,
        phase: SkillDeletionPhase,
        outcome: SkillDeletionOutcome,
        cleanupState: SkillDeletionCleanupState,
        domainPayload: Data,
        expectationPayload: Data,
        distributionPlan: Data,
        ssotIdentity: ManagedItemIdentity,
        quarantineLocator: String,
        quarantineIdentity: ManagedItemIdentity?,
        attemptCount: Int64,
        lastError: String?,
        createdAtMilliseconds: Int64,
        updatedAtMilliseconds: Int64
    ) throws {
        self.operationID = operationID
        self.skillID = skillID
        self.backupID = backupID
        self.phase = phase
        self.outcome = outcome
        self.cleanupState = cleanupState
        self.domainPayload = domainPayload
        self.expectationPayload = expectationPayload
        self.distributionPlan = distributionPlan
        self.ssotIdentity = ssotIdentity
        self.quarantineLocator = quarantineLocator
        self.quarantineIdentity = quarantineIdentity
        self.attemptCount = attemptCount
        self.lastError = lastError
        self.createdAtMilliseconds = createdAtMilliseconds
        self.updatedAtMilliseconds = updatedAtMilliseconds
        try validate()
    }

    func validateTransition(from old: Self) throws {
        guard operationID == old.operationID,
              skillID == old.skillID,
              backupID == old.backupID,
              domainPayload == old.domainPayload,
              expectationPayload == old.expectationPayload,
              distributionPlan == old.distributionPlan,
              ssotIdentity == old.ssotIdentity,
              quarantineLocator == old.quarantineLocator,
              createdAtMilliseconds == old.createdAtMilliseconds,
              old.quarantineIdentity == nil || quarantineIdentity == old.quarantineIdentity,
              attemptCount >= old.attemptCount,
              updatedAtMilliseconds >= old.updatedAtMilliseconds,
              Self.transitionAllowed(from: old, to: self) else {
            throw SkillDeletionOperationStoreError.invalidRecord
        }
        try validate()
    }

    private func validate() throws {
        try SkillBackupCanonicalJSON.validate(domainPayload)
        try SkillBackupCanonicalJSON.validate(expectationPayload)
        try SkillBackupCanonicalJSON.validate(distributionPlan)
        guard SkillBackupRecord.validLocator(quarantineLocator),
              attemptCount >= 0,
              createdAtMilliseconds >= 0,
              updatedAtMilliseconds >= createdAtMilliseconds,
              (lastError?.utf8.count ?? 0) <= 4_096 else {
            throw SkillDeletionOperationStoreError.invalidRecord
        }
        let requiresError = outcome == .needsRepair || cleanupState == .needsRepair
        guard requiresError == !(lastError?.isEmpty ?? true) else {
            throw SkillDeletionOperationStoreError.invalidRecord
        }
        switch (phase, outcome, cleanupState) {
        case (.prepared, .pending, .notApplicable),
             (.prepared, .needsRepair, .notApplicable),
             (.backupPublished, .pending, .notApplicable),
             (.backupPublished, .needsRepair, .notApplicable),
             (.distributionRemoved, .pending, .notApplicable),
             (.distributionRemoved, .needsRepair, .notApplicable):
            guard quarantineIdentity == nil else {
                throw SkillDeletionOperationStoreError.invalidRecord
            }
        case (.ssotQuarantined, .pending, .notStarted),
             (.ssotQuarantined, .needsRepair, .notStarted),
             (.databaseCommitted, .pending, .notStarted),
             (.databaseCommitted, .pending, .pending),
             (.databaseCommitted, .needsRepair, .notStarted),
             (.databaseCommitted, .needsRepair, .needsRepair),
             (.completed, .applied, .pending),
             (.completed, .applied, .completed),
             (.completed, .applied, .needsRepair):
            guard quarantineIdentity != nil else {
                throw SkillDeletionOperationStoreError.invalidRecord
            }
        case (.completed, .rolledBack, .notApplicable):
            break
        default:
            throw SkillDeletionOperationStoreError.invalidRecord
        }
    }

    private static func transitionAllowed(
        from old: Self,
        to new: Self
    ) -> Bool {
        if old.phase == new.phase,
           old.outcome == new.outcome {
            if old.phase == .completed, old.outcome == .applied {
                return cleanupTransitionAllowed(from: old.cleanupState, to: new.cleanupState)
            }
            return old.cleanupState == new.cleanupState
        }
        if old.outcome == .needsRepair,
           new.outcome == .pending,
           old.phase == new.phase {
            return old.cleanupState == new.cleanupState
                || cleanupTransitionAllowed(from: old.cleanupState, to: new.cleanupState)
        }
        if old.outcome == .pending,
           new.outcome == .needsRepair,
           old.phase == new.phase {
            return old.cleanupState == new.cleanupState
                || cleanupTransitionAllowed(from: old.cleanupState, to: new.cleanupState)
        }
        guard old.outcome == .pending else { return false }
        if new.outcome == .rolledBack,
           new.phase == .completed,
           new.cleanupState == .notApplicable {
            return old.phase != .databaseCommitted && old.phase != .completed
        }
        switch (old.phase, new.phase, new.outcome) {
        case (.prepared, .backupPublished, .pending),
             (.backupPublished, .distributionRemoved, .pending),
             (.distributionRemoved, .ssotQuarantined, .pending),
             (.ssotQuarantined, .databaseCommitted, .pending),
             (.databaseCommitted, .completed, .applied):
            return true
        default:
            return false
        }
    }

    private static func cleanupTransitionAllowed(
        from old: SkillDeletionCleanupState,
        to new: SkillDeletionCleanupState
    ) -> Bool {
        if old == new { return true }
        return switch (old, new) {
        case (.notStarted, .pending), (.notStarted, .completed),
             (.notStarted, .needsRepair), (.pending, .completed),
             (.pending, .needsRepair), (.needsRepair, .pending),
             (.needsRepair, .completed):
            true
        default:
            false
        }
    }
}

nonisolated final class SkillDeletionOperationStore {
    private let connection: SQLiteConnection

    init(connection: SQLiteConnection) throws {
        guard connection.accessMode != .readOnly else {
            throw SQLiteStoreError.invalidState(
                "the Skill deletion operation store requires read-write access"
            )
        }
        self.connection = connection
    }

    func insertPrepared(
        _ draft: SkillDeletionOperationDraft
    ) throws -> SkillDeletionOperationRecord {
        let record = try draft.record()
        let statement = try connection.prepare(
            """
            INSERT INTO skill_deletion_operations(
              operation_id, format_version, skill_id, backup_id, phase, outcome,
              cleanup_state, domain_payload, expectation_payload, distribution_plan,
              ssot_identity, quarantine_locator, quarantine_identity, attempt_count,
              last_error, created_at_ms, updated_at_ms
            ) VALUES (?, 1, ?, ?, 'prepared', 'pending', 'notApplicable',
                      ?, ?, ?, ?, ?, NULL, 0, NULL, ?, ?)
            """
        )
        try statement.bind(record.operationID.bytes, at: 1)
        try statement.bind(record.skillID.bytes, at: 2)
        try statement.bind(record.backupID.bytes, at: 3)
        try statement.bind(record.domainPayload, at: 4)
        try statement.bind(record.expectationPayload, at: 5)
        try statement.bind(record.distributionPlan, at: 6)
        try statement.bind(ManagedItemIdentityCodec.encode(record.ssotIdentity), at: 7)
        try statement.bind(record.quarantineLocator, at: 8)
        try statement.bind(record.createdAtMilliseconds, at: 9)
        try statement.bind(record.updatedAtMilliseconds, at: 10)
        do {
            try finishExactlyOne(statement)
        } catch let error as SkillDeletionOperationStoreError {
            throw error
        } catch {
            throw SkillDeletionOperationStoreError.conflict
        }
        return record
    }

    func load(_ operationID: SSOTOperationID) throws -> SkillDeletionOperationRecord {
        let statement = try connection.prepare(Self.selectSQL + " AND operation_id = ?")
        try statement.bind(operationID.bytes, at: 1)
        guard try statement.step() else {
            throw SkillDeletionOperationStoreError.operationNotFound
        }
        let record = try decode(statement)
        guard try !statement.step() else {
            throw SkillDeletionOperationStoreError.corruptRecord
        }
        return record
    }

    func recoverable() throws -> [SkillDeletionOperationRecord] {
        let statement = try connection.prepare(
            Self.selectSQL
                + " AND (outcome IN ('pending', 'needsRepair') "
                + "OR cleanup_state IN ('pending', 'needsRepair')) "
                + "ORDER BY created_at_ms, operation_id"
        )
        var records: [SkillDeletionOperationRecord] = []
        while try statement.step() { records.append(try decode(statement)) }
        return records
    }

    func transition(
        expected old: SkillDeletionOperationRecord,
        to replacement: SkillDeletionOperationRecord
    ) throws {
        try connection.withImmediateTransaction {
            try transitionInCurrentTransaction(expected: old, to: replacement)
        }
    }

    func transitionInCurrentTransaction(
        expected old: SkillDeletionOperationRecord,
        to replacement: SkillDeletionOperationRecord
    ) throws {
        try replacement.validateTransition(from: old)
        guard old != replacement else { return }
        guard try load(old.operationID) == old else {
            throw SkillDeletionOperationStoreError.conflict
        }
        let statement = try connection.prepare(
                """
                UPDATE skill_deletion_operations
                SET phase = ?, outcome = ?, cleanup_state = ?, quarantine_identity = ?,
                    attempt_count = ?, last_error = ?, updated_at_ms = ?
                WHERE operation_id = ? AND phase = ? AND outcome = ?
                  AND cleanup_state = ? AND updated_at_ms = ?
                """
        )
        try statement.bind(replacement.phase.rawValue, at: 1)
        try statement.bind(replacement.outcome.rawValue, at: 2)
        try statement.bind(replacement.cleanupState.rawValue, at: 3)
        if let identity = replacement.quarantineIdentity {
            try statement.bind(ManagedItemIdentityCodec.encode(identity), at: 4)
        } else {
            try statement.bindNull(at: 4)
        }
        try statement.bind(replacement.attemptCount, at: 5)
        if let error = replacement.lastError {
            try statement.bind(error, at: 6)
        } else {
            try statement.bindNull(at: 6)
        }
        try statement.bind(replacement.updatedAtMilliseconds, at: 7)
        try statement.bind(old.operationID.bytes, at: 8)
        try statement.bind(old.phase.rawValue, at: 9)
        try statement.bind(old.outcome.rawValue, at: 10)
        try statement.bind(old.cleanupState.rawValue, at: 11)
        try statement.bind(old.updatedAtMilliseconds, at: 12)
        try finishExactlyOne(statement)
    }

    func transaction<T>(_ body: () throws -> T) throws -> T {
        try connection.withImmediateTransaction(body)
    }

    func commitDomainDeletion(
        journal: SSOTJournalStore,
        skillID: SkillID,
        expectedDomain: StoredSkillDomainSnapshot,
        expected operation: SkillDeletionOperationRecord,
        replacement: SkillDeletionOperationRecord
    ) throws {
        try connection.withImmediateTransaction {
            try journal.deleteDomainInCurrentTransaction(
                skillID: skillID,
                expected: expectedDomain
            )
            try transitionInCurrentTransaction(
                expected: operation,
                to: replacement
            )
        }
    }

    private func decode(_ statement: SQLiteStatement) throws -> SkillDeletionOperationRecord {
        do {
            return try SkillDeletionOperationRecord(
                operationID: SSOTOperationID(
                    bytes: try skillLifecycleRequiredBlob(statement, 0)
                ),
                skillID: SkillID(bytes: try skillLifecycleRequiredBlob(statement, 2)),
                backupID: SkillBackupID(
                    bytes: try skillLifecycleRequiredBlob(statement, 3)
                ),
                phase: try skillLifecycleRequiredEnum(
                    statement, 4, as: SkillDeletionPhase.self
                ),
                outcome: try skillLifecycleRequiredEnum(
                    statement, 5, as: SkillDeletionOutcome.self
                ),
                cleanupState: try skillLifecycleRequiredEnum(
                    statement, 6, as: SkillDeletionCleanupState.self
                ),
                domainPayload: try skillLifecycleRequiredBlob(statement, 7),
                expectationPayload: try skillLifecycleRequiredBlob(statement, 8),
                distributionPlan: try skillLifecycleRequiredBlob(statement, 9),
                ssotIdentity: try ManagedItemIdentityCodec.decode(
                    skillLifecycleRequiredBlob(statement, 10)
                ),
                quarantineLocator: try skillLifecycleRequiredText(statement, 11),
                quarantineIdentity: try statement.blob(at: 12)
                    .map(ManagedItemIdentityCodec.decode),
                attemptCount: statement.int64(at: 13),
                lastError: statement.text(at: 14),
                createdAtMilliseconds: statement.int64(at: 15),
                updatedAtMilliseconds: statement.int64(at: 16)
            )
        } catch let error as SkillDeletionOperationStoreError {
            throw error
        } catch {
            throw SkillDeletionOperationStoreError.corruptRecord
        }
    }

    private func finishExactlyOne(_ statement: SQLiteStatement) throws {
        guard try !statement.step(),
              try connection.querySingleInt("SELECT changes()") == 1 else {
            throw SkillDeletionOperationStoreError.conflict
        }
    }

    private static let selectSQL = """
    SELECT operation_id, format_version, skill_id, backup_id, phase, outcome,
           cleanup_state, domain_payload, expectation_payload, distribution_plan,
           ssot_identity, quarantine_locator, quarantine_identity, attempt_count,
           last_error, created_at_ms, updated_at_ms
    FROM skill_deletion_operations
    WHERE format_version = 1
    """
}
