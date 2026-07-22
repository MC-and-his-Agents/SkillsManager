import Foundation

nonisolated extension SSOTJournalStore {
    func cleanupDebtObservation(
        for operation: SSOTJournalRecord
    ) throws -> SSOTCleanupDebtObservation {
        guard let debt = try loadCleanupDebt(for: operation) else { return .none }
        guard debt.operationID == operation.operationID,
              debt.expectedRootIdentity == operation.expectedRootIdentity else {
            return .unknown
        }
        switch debt.itemRole {
        case .staging:
            let validState = operation.state == .init(
                phase: .completed, outcome: .rolledBack, cleanupState: .pending
            ) || operation.state == .init(
                phase: .completed, outcome: .rolledBack, cleanupState: .needsRepair
            )
            guard validState,
               debt.recoveryLocator == operation.stagingLocator,
               debt.expectedItemIdentity == operation.expectedStagedIdentity,
               debt.expectedFingerprint == operation.newFingerprint else {
                return .unknown
            }
            return .verifiedStaging
        case .recovery:
            let validState = operation.state == .init(
                phase: .databaseCommitted,
                outcome: .pending,
                cleanupState: .pending
            ) || operation.state == .init(
                phase: .databaseCommitted,
                outcome: .needsRepair,
                cleanupState: .pending
            ) || operation.state == .init(
                phase: .completed,
                outcome: .applied,
                cleanupState: .pending
            ) || operation.state == .init(
                phase: .completed,
                outcome: .applied,
                cleanupState: .needsRepair
            )
            guard operation.operationType == .replace,
                  validState,
                  debt.recoveryLocator == operation.recoveryLocator,
                  debt.expectedItemIdentity == operation.expectedOldIdentity,
                  debt.expectedFingerprint == operation.oldFingerprint else {
                return .unknown
            }
            return .verifiedRecovery
        }
    }

    func loadCleanupDebt(
        for operation: SSOTJournalRecord
    ) throws -> SSOTCleanupDebtRecord? {
        guard let debtID = operation.cleanupDebtID else {
            let statement = try connection.prepare(
                "SELECT count(*) FROM cleanup_debts WHERE operation_id = ?"
            )
            try statement.bind(operation.operationID.bytes, at: 1)
            guard try statement.step(), statement.int64(at: 0) == 0 else {
                throw SSOTJournalStoreError.corruptRecord("operation has an unbound cleanup debt")
            }
            return nil
        }
        let statement = try connection.prepare(Self.cleanupDebtSelect + " WHERE cleanup_debt_id = ?")
        try statement.bind(debtID.bytes, at: 1)
        guard try statement.step() else {
            throw SSOTJournalStoreError.corruptRecord("bound cleanup debt is missing")
        }
        let debt = try decodeCleanupDebt(statement)
        guard try !statement.step(), debt.operationID == operation.operationID else {
            throw SSOTJournalStoreError.corruptRecord("cleanup debt ownership is invalid")
        }
        return debt
    }

    func completeAppliedWithCleanupDebt(
        operationID: SSOTOperationID,
        debt: SSOTCleanupDebtRecord,
        updatedAtMilliseconds: Int64
    ) throws {
        try transaction {
            let operation = try loadOperation(operationID)
            guard debt.itemRole == .recovery,
                  cleanupDebtMatchesRecovery(debt, operation: operation),
                  operation.state == .init(
                    phase: .databaseCommitted,
                    outcome: .pending,
                    cleanupState: .notStarted
                  ) else {
                throw SSOTJournalStoreError.invalidRecord
            }
            try bindCleanupDebt(
                operationID: operationID,
                debt: debt,
                outcome: .applied,
                updatedAtMilliseconds: updatedAtMilliseconds
            )
        }
    }

    func completeRolledBackWithCleanupDebt(
        operationID: SSOTOperationID,
        debt: SSOTCleanupDebtRecord,
        updatedAtMilliseconds: Int64
    ) throws {
        try transaction {
            let operation = try loadOperation(operationID)
            guard debt.itemRole == .staging,
                  cleanupDebtMatchesStaging(debt, operation: operation),
                  operation.state.phase == .prepared,
                  operation.state.outcome == .pending else {
                throw SSOTJournalStoreError.invalidRecord
            }
            try bindCleanupDebt(
                operationID: operationID,
                debt: debt,
                outcome: .rolledBack,
                updatedAtMilliseconds: updatedAtMilliseconds
            )
        }
    }

    func completeCleanupDebt(
        operationID: SSOTOperationID,
        debtID: SSOTCleanupDebtID,
        updatedAtMilliseconds: Int64
    ) throws {
        try transaction {
            let operation = try loadOperation(operationID)
            guard operation.state.cleanupState == .pending,
                  operation.state.outcome != .needsRepair,
                  operation.cleanupDebtID == debtID,
                  try cleanupDebtObservation(for: operation) != .unknown else {
                throw SSOTJournalStoreError.stateConflict
            }
            let update = try connection.prepare(
                """
                UPDATE skill_operations
                SET phase = 'completed',
                    outcome = CASE WHEN phase = 'databaseCommitted' THEN 'applied' ELSE outcome END,
                    cleanup_state = 'completed', cleanup_debt_id = NULL, updated_at_ms = ?
                WHERE operation_id = ?
                  AND ((phase = 'databaseCommitted' AND outcome IS NULL)
                    OR (phase = 'completed' AND outcome IN ('applied', 'rolledBack')))
                  AND cleanup_state = 'pending' AND cleanup_debt_id = ?
                """
            )
            try update.bind(updatedAtMilliseconds, at: 1)
            try update.bind(operationID.bytes, at: 2)
            try update.bind(debtID.bytes, at: 3)
            try finishMutation(update)

            let delete = try connection.prepare(
                "DELETE FROM cleanup_debts WHERE cleanup_debt_id = ? AND operation_id = ?"
            )
            try delete.bind(debtID.bytes, at: 1)
            try delete.bind(operationID.bytes, at: 2)
            try finishMutation(delete)
        }
    }

    func recordCleanupDebtFailure(
        operationID: SSOTOperationID,
        debtID: SSOTCleanupDebtID,
        errorCode: String,
        updatedAtMilliseconds: Int64
    ) throws {
        let boundedCode = boundedJournalError(errorCode, maximumBytes: 128)
        try transaction {
            let operation = try loadOperation(operationID)
            guard operation.state.cleanupState == .pending,
                  operation.state.outcome != .needsRepair,
                  operation.cleanupDebtID == debtID,
                  try cleanupDebtObservation(for: operation) != .unknown else {
                throw SSOTJournalStoreError.stateConflict
            }
            let debt = try connection.prepare(
                """
                UPDATE cleanup_debts
                SET attempt_count = attempt_count + 1, last_error_code = ?, updated_at_ms = ?
                WHERE cleanup_debt_id = ? AND operation_id = ?
                  AND EXISTS (
                    SELECT 1 FROM skill_operations
                    WHERE operation_id = ? AND cleanup_state = 'pending'
                      AND cleanup_debt_id = ?
                  )
                """
            )
            try debt.bind(boundedCode, at: 1)
            try debt.bind(updatedAtMilliseconds, at: 2)
            try debt.bind(debtID.bytes, at: 3)
            try debt.bind(operationID.bytes, at: 4)
            try debt.bind(operationID.bytes, at: 5)
            try debt.bind(debtID.bytes, at: 6)
            try finishMutation(debt)
        }
    }

    func markCleanupNeedsRepair(
        operationID: SSOTOperationID,
        debtID: SSOTCleanupDebtID,
        errorCode: SSOTRecoveryErrorCode,
        updatedAtMilliseconds: Int64
    ) throws {
        try transaction {
            let operation = try loadOperation(operationID)
            guard operation.state.phase == .completed,
                  operation.state.outcome == .applied || operation.state.outcome == .rolledBack,
                  operation.state.cleanupState == .pending,
                  operation.cleanupDebtID == debtID,
                  let debt = try loadCleanupDebt(for: operation),
                  updatedAtMilliseconds >= operation.updatedAtMilliseconds,
                  updatedAtMilliseconds >= debt.updatedAtMilliseconds else {
                throw SSOTJournalStoreError.stateConflict
            }
            let expectedObservation: SSOTCleanupDebtObservation =
                operation.state.outcome == .applied ? .verifiedRecovery : .verifiedStaging
            guard try cleanupDebtObservation(for: operation) == expectedObservation else {
                throw SSOTJournalStoreError.stateConflict
            }

            let debtUpdate = try connection.prepare(
                """
                UPDATE cleanup_debts
                SET attempt_count = attempt_count + 1, last_error_code = ?, updated_at_ms = ?
                WHERE cleanup_debt_id = ? AND operation_id = ?
                """
            )
            try debtUpdate.bind(errorCode.rawValue, at: 1)
            try debtUpdate.bind(updatedAtMilliseconds, at: 2)
            try debtUpdate.bind(debtID.bytes, at: 3)
            try debtUpdate.bind(operationID.bytes, at: 4)
            try finishMutation(debtUpdate)

            let operationUpdate = try connection.prepare(
                """
                UPDATE skill_operations
                SET cleanup_state = 'needsRepair', updated_at_ms = ?
                WHERE operation_id = ? AND phase = 'completed'
                  AND outcome IN ('applied', 'rolledBack')
                  AND cleanup_state = 'pending' AND cleanup_debt_id = ?
                """
            )
            try operationUpdate.bind(updatedAtMilliseconds, at: 1)
            try operationUpdate.bind(operationID.bytes, at: 2)
            try operationUpdate.bind(debtID.bytes, at: 3)
            try finishMutation(operationUpdate)
        }
    }

    private func bindCleanupDebt(
        operationID: SSOTOperationID,
        debt: SSOTCleanupDebtRecord,
        outcome: SSOTOperationOutcome,
        updatedAtMilliseconds: Int64
    ) throws {
        guard debt.operationID == operationID,
              outcome == .applied || outcome == .rolledBack else {
            throw SSOTJournalStoreError.invalidRecord
        }
        let operation = try connection.prepare(
            """
            UPDATE skill_operations
            SET phase = 'completed', outcome = ?, cleanup_state = 'pending',
                cleanup_debt_id = ?, attempt_count = attempt_count + 1,
                last_error = ?, updated_at_ms = ?
            WHERE operation_id = ? AND outcome IS NULL
              AND ((? = 'applied' AND phase = 'databaseCommitted')
                OR (? = 'rolledBack' AND phase = 'prepared'))
            """
        )
        try operation.bind(outcome.rawValue, at: 1)
        try operation.bind(debt.debtID.bytes, at: 2)
        try operation.bind(debt.lastErrorCode, at: 3)
        try operation.bind(updatedAtMilliseconds, at: 4)
        try operation.bind(operationID.bytes, at: 5)
        try operation.bind(outcome.rawValue, at: 6)
        try operation.bind(outcome.rawValue, at: 7)
        try finishMutation(operation)
        try insertCleanupDebt(debt)
    }

    private func insertCleanupDebt(_ debt: SSOTCleanupDebtRecord) throws {
        let statement = try connection.prepare(Self.cleanupDebtInsert)
        try statement.bind(debt.debtID.bytes, at: 1)
        try statement.bind(debt.operationID.bytes, at: 2)
        try statement.bind(debt.itemRole.rawValue, at: 3)
        try statement.bind(debt.recoveryLocator, at: 4)
        try statement.bind(ManagedItemIdentityCodec.encode(debt.expectedItemIdentity), at: 5)
        try statement.bind(Int64(debt.expectedFingerprint.algorithmVersion), at: 6)
        try statement.bind(debt.expectedFingerprint.digest, at: 7)
        try statement.bind(ManagedItemIdentityCodec.encode(debt.expectedRootIdentity), at: 8)
        try statement.bind(debt.attemptCount, at: 9)
        try statement.bind(debt.lastErrorCode, at: 10)
        try statement.bind(debt.createdAtMilliseconds, at: 11)
        try statement.bind(debt.updatedAtMilliseconds, at: 12)
        try finishMutation(statement)
    }

    private func decodeCleanupDebt(_ statement: SQLiteStatement) throws -> SSOTCleanupDebtRecord {
        do {
            return try SSOTCleanupDebtRecord(
                debtID: SSOTCleanupDebtID(bytes: journalRequiredBlob(statement, 0)),
                operationID: SSOTOperationID(bytes: journalRequiredBlob(statement, 1)),
                itemRole: try journalRequiredEnum(statement, 2, as: SSOTCleanupItemRole.self),
                recoveryLocator: journalRequiredText(statement, 3),
                expectedItemIdentity: try ManagedItemIdentityCodec.decode(
                    journalRequiredBlob(statement, 4)
                ),
                expectedFingerprint: SkillContentFingerprint(
                    algorithmVersion: Int(statement.int64(at: 5)),
                    digest: journalRequiredBlob(statement, 6)
                ),
                expectedRootIdentity: try ManagedItemIdentityCodec.decode(
                    journalRequiredBlob(statement, 7)
                ),
                attemptCount: statement.int64(at: 8),
                lastErrorCode: journalRequiredText(statement, 9),
                createdAtMilliseconds: statement.int64(at: 10),
                updatedAtMilliseconds: statement.int64(at: 11)
            )
        } catch let error as SSOTJournalStoreError {
            throw error
        } catch {
            throw SSOTJournalStoreError.corruptRecord(error.localizedDescription)
        }
    }

    private func cleanupDebtMatchesStaging(
        _ debt: SSOTCleanupDebtRecord,
        operation: SSOTJournalRecord
    ) -> Bool {
        debt.operationID == operation.operationID
            && debt.recoveryLocator == operation.stagingLocator
            && debt.expectedItemIdentity == operation.expectedStagedIdentity
            && debt.expectedFingerprint == operation.newFingerprint
            && debt.expectedRootIdentity == operation.expectedRootIdentity
    }

    private func cleanupDebtMatchesRecovery(
        _ debt: SSOTCleanupDebtRecord,
        operation: SSOTJournalRecord
    ) -> Bool {
        operation.operationType == .replace
            && debt.operationID == operation.operationID
            && debt.recoveryLocator == operation.recoveryLocator
            && debt.expectedItemIdentity == operation.expectedOldIdentity
            && debt.expectedFingerprint == operation.oldFingerprint
            && debt.expectedRootIdentity == operation.expectedRootIdentity
    }

    private static let cleanupDebtSelect = """
    SELECT cleanup_debt_id, operation_id, item_role, recovery_locator,
           expected_item_identity, expected_fingerprint_algorithm_version,
           expected_content_fingerprint, expected_root_identity,
           attempt_count, last_error_code, created_at_ms, updated_at_ms
    FROM cleanup_debts
    """

    private static let cleanupDebtInsert = """
    INSERT INTO cleanup_debts(
      cleanup_debt_id, operation_id, item_role, recovery_locator,
      expected_item_identity, expected_fingerprint_algorithm_version,
      expected_content_fingerprint, expected_root_identity,
      attempt_count, last_error_code, created_at_ms, updated_at_ms
    ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
    """
}
