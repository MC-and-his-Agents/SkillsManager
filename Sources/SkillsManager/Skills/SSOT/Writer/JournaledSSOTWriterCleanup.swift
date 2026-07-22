import Darwin
import Foundation

extension JournaledSSOTWriter {
    func cancelPrepared(_ operationID: SSOTOperationID) throws {
        let operation = try journal.loadOperation(operationID)
        let snapshot = try recoverySnapshot(for: operation)
        let decision = SSOTRecoveryClassifier.classify(snapshot)
        let rollbackStep: SSOTRecoveryStep = operation.operationType == .create
            ? .promoteCreate : .swapReplacement
        guard operation.state.phase == .prepared,
              decision == .advance(rollbackStep) else {
            throw JournaledSSOTWriterError.invalidInput
        }
        do {
            try removeStaging(operation)
            try requireAuthority()
            try journal.completeRolledBack(
                operationID: operationID,
                updatedAtMilliseconds: timestamp(for: operation)
            )
        } catch let error as SSOTWriterCheckpointInterruption {
            throw error
        } catch let error where isAuthorityFailure(error) {
            throw error
        } catch let error where isIdentityFailure(error) {
            try markCleanupNeedsRepair(operation, error: error)
            throw JournaledSSOTWriterError.operationNeedsRepair(
                operationID,
                mismatchCode(for: operation)
            )
        } catch {
            let debt = try cleanupDebt(
                operation: operation,
                role: .staging,
                identity: operation.expectedStagedIdentity,
                fingerprint: operation.newFingerprint,
                error: error
            )
            try requireAuthority()
            try journal.completeRolledBackWithCleanupDebt(
                operationID: operationID,
                debt: debt,
                updatedAtMilliseconds: timestamp(for: operation)
            )
        }
    }

    func cleanupAppliedReplacement(_ operation: SSOTJournalRecord) throws {
        guard let oldIdentity = operation.expectedOldIdentity,
              let oldFingerprint = operation.oldFingerprint else {
            throw JournaledSSOTWriterError.invalidInput
        }
        do {
            try checkpoint(.beforeCleanup, operation.operationID)
            if hooks.shouldFailCleanup(.recovery) {
                throw SSOTOperationFileSystemError.posix(
                    operation: "injected recovery cleanup",
                    code: EIO
                )
            }
            try fileSystem.removeExpectedOperationItem(
                .recovery(operationID: operation.operationID.uuid),
                identity: oldIdentity,
                fingerprint: oldFingerprint
            )
            try checkpoint(.afterCleanup, operation.operationID)
            try checkpoint(.beforeTerminalCompletion, operation.operationID)
            try requireAuthority()
            try journal.completeApplied(
                operationID: operation.operationID,
                cleanupState: .completed,
                updatedAtMilliseconds: timestamp(for: operation)
            )
            try checkpoint(.afterTerminalCompletion, operation.operationID)
        } catch let error as SSOTWriterCheckpointInterruption {
            throw error
        } catch let error where isAuthorityFailure(error) {
            throw error
        } catch let error where isIdentityFailure(error) {
            try markCleanupNeedsRepair(operation, error: error)
            throw JournaledSSOTWriterError.operationNeedsRepair(
                operation.operationID,
                .replaceStateMismatch
            )
        } catch {
            let debt = try cleanupDebt(
                operation: operation,
                role: .recovery,
                identity: oldIdentity,
                fingerprint: oldFingerprint,
                error: error
            )
            try requireAuthority()
            try journal.completeAppliedWithCleanupDebt(
                operationID: operation.operationID,
                debt: debt,
                updatedAtMilliseconds: timestamp(for: operation)
            )
        }
    }

    func retryCleanupDebt(_ operation: SSOTJournalRecord) throws {
        guard let debt = try journal.loadCleanupDebt(for: operation) else {
            return
        }
        let reference: SSOTOperationItemReference = switch debt.itemRole {
        case .staging: .staging(operationID: operation.operationID.uuid)
        case .recovery: .recovery(operationID: operation.operationID.uuid)
        }
        let observed = try fileSystem.observeOperationItem(
            reference,
            expectedIdentity: debt.expectedItemIdentity,
            expectedFingerprint: debt.expectedFingerprint
        )
        if observed == .absent {
            if operation.state.phase == .databaseCommitted {
                try markNeedsRepair(
                    operation,
                    code: .replaceStateMismatch,
                    detail: SSOTOperationFileSystemError.itemChanged
                )
                throw JournaledSSOTWriterError.operationNeedsRepair(
                    operation.operationID,
                    .replaceStateMismatch
                )
            }
            try requireAuthority()
            try journal.completeCleanupDebt(
                operationID: operation.operationID,
                debtID: debt.debtID,
                updatedAtMilliseconds: timestamp(for: operation)
            )
            return
        }
        guard observed == .expected else {
            try markCleanupNeedsRepair(operation, error: SSOTOperationFileSystemError.itemChanged)
            throw JournaledSSOTWriterError.operationNeedsRepair(
                operation.operationID,
                mismatchCode(for: operation)
            )
        }
        do {
            try fileSystem.removeExpectedOperationItem(
                reference,
                identity: debt.expectedItemIdentity,
                fingerprint: debt.expectedFingerprint
            )
            try requireAuthority()
            try journal.completeCleanupDebt(
                operationID: operation.operationID,
                debtID: debt.debtID,
                updatedAtMilliseconds: timestamp(for: operation)
            )
        } catch let error as SSOTWriterCheckpointInterruption {
            throw error
        } catch let error where isAuthorityFailure(error) {
            throw error
        } catch let error where isIdentityFailure(error) {
            try markCleanupNeedsRepair(operation, error: error)
            throw JournaledSSOTWriterError.operationNeedsRepair(
                operation.operationID,
                mismatchCode(for: operation)
            )
        } catch {
            try requireAuthority()
            try journal.recordCleanupDebtFailure(
                operationID: operation.operationID,
                debtID: debt.debtID,
                errorCode: cleanupErrorCode(error),
                updatedAtMilliseconds: timestamp(for: operation)
            )
        }
    }

    private func removeStaging(_ operation: SSOTJournalRecord) throws {
        try checkpoint(.beforeCleanup, operation.operationID)
        if hooks.shouldFailCleanup(.staging) {
            throw SSOTOperationFileSystemError.posix(
                operation: "injected staging cleanup",
                code: EIO
            )
        }
        try fileSystem.removeExpectedOperationItem(
            .staging(operationID: operation.operationID.uuid),
            identity: operation.expectedStagedIdentity,
            fingerprint: operation.newFingerprint
        )
        try checkpoint(.afterCleanup, operation.operationID)
    }

    private func cleanupDebt(
        operation: SSOTJournalRecord,
        role: SSOTCleanupItemRole,
        identity: ManagedItemIdentity,
        fingerprint: SkillContentFingerprint,
        error: Error
    ) throws -> SSOTCleanupDebtRecord {
        let now = timestamp(for: operation)
        return try SSOTCleanupDebtRecord(
            operationID: operation.operationID,
            itemRole: role,
            recoveryLocator: operationItemName(operation.operationID),
            expectedItemIdentity: identity,
            expectedFingerprint: fingerprint,
            expectedRootIdentity: operation.expectedRootIdentity,
            lastErrorCode: cleanupErrorCode(error),
            createdAtMilliseconds: now,
            updatedAtMilliseconds: now
        )
    }

    private func markCleanupNeedsRepair(
        _ operation: SSOTJournalRecord,
        error: Error
    ) throws {
        if operation.state.phase == .completed {
            guard operation.state.cleanupState == .pending,
                  let debt = try journal.loadCleanupDebt(for: operation) else {
                throw SSOTJournalStoreError.stateConflict
            }
            try requireAuthority()
            try journal.markCleanupNeedsRepair(
                operationID: operation.operationID,
                debtID: debt.debtID,
                errorCode: .cleanupIdentityDrift,
                updatedAtMilliseconds: max(
                    timestamp(for: operation),
                    debt.updatedAtMilliseconds
                )
            )
            return
        }
        try markNeedsRepair(operation, code: mismatchCode(for: operation), detail: error)
    }

    func markCleanupNeedsRepair(
        _ operation: SSOTJournalRecord,
        error: SSOTRecoveryErrorCode
    ) throws {
        try markCleanupNeedsRepair(
            operation,
            error: JournaledSSOTWriterError.operationNeedsRepair(
                operation.operationID,
                error
            )
        )
    }

    func mismatchCode(for operation: SSOTJournalRecord) -> SSOTRecoveryErrorCode {
        operation.operationType == .create ? .createStateMismatch : .replaceStateMismatch
    }

    private func isIdentityFailure(_ error: Error) -> Bool {
        if let value = error as? SSOTOperationFileSystemError, value == .itemChanged { return true }
        if let value = error as? SSOTWriterOwnershipError, value == .invalidLockFile { return true }
        if let value = error as? ManagedPathError {
            return value == .rootReplaced || value == .itemChanged
        }
        return false
    }

    private func isAuthorityFailure(_ error: Error) -> Bool {
        if let value = error as? SSOTWriterOwnershipError, value == .invalidLockFile {
            return true
        }
        if let value = error as? ManagedPathError, value == .rootReplaced {
            return true
        }
        return false
    }

    private func cleanupErrorCode(_ error: Error) -> String {
        if let value = error as? SSOTOperationFileSystemError {
            switch value {
            case .posix(_, let code): return "posix-\(code)"
            default: return "filesystem-error"
            }
        }
        return "cleanup-error"
    }
}
