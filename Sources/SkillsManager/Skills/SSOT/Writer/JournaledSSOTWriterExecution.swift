import Foundation

extension JournaledSSOTWriter {
    func execute(_ operationID: SSOTOperationID) throws -> SSOTJournalRecord {
        for _ in 0..<Self.maximumRecoverySteps {
            let operation = try journal.loadOperation(operationID)
            try handleCancellation(operation)
            let snapshot = try recoverySnapshot(for: operation)
            switch SSOTRecoveryClassifier.classify(snapshot) {
            case .advance(let step):
                try advance(step, operation: operation)
                if step == .cleanupReplacement {
                    let updated = try journal.loadOperation(operationID)
                    if updated.state == .init(
                        phase: .completed,
                        outcome: .applied,
                        cleanupState: .pending
                    ) {
                        return updated
                    }
                }
            case .complete(let outcome, let cleanupState):
                return try complete(
                    operation,
                    outcome: outcome,
                    cleanupState: cleanupState
                )
            case .needsRepair(let code):
                if hasTerminalCleanupIdentityDrift(operation, snapshot: snapshot) {
                    try markCleanupNeedsRepair(operation, error: code)
                    throw JournaledSSOTWriterError.operationNeedsRepair(
                        operationID,
                        .cleanupIdentityDrift
                    )
                }
                if operation.state.outcome != .needsRepair,
                   operation.state.phase != .completed {
                    try markNeedsRepair(operation, code: code, detail: nil)
                }
                throw JournaledSSOTWriterError.operationNeedsRepair(operationID, code)
            }
        }
        throw JournaledSSOTWriterError.recoveryDidNotConverge(operationID)
    }

    private func hasTerminalCleanupIdentityDrift(
        _ operation: SSOTJournalRecord,
        snapshot: SSOTRecoverySnapshot
    ) -> Bool {
        guard operation.state.phase == .completed,
              operation.state.cleanupState == .pending else {
            return false
        }
        switch snapshot.cleanupDebt {
        case .verifiedStaging:
            return snapshot.staging == .unknown
        case .verifiedRecovery:
            return snapshot.recovery == .unknown
        case .none, .unknown:
            return false
        }
    }

    private func advance(
        _ step: SSOTRecoveryStep,
        operation: SSOTJournalRecord
    ) throws {
        switch step {
        case .promoteCreate:
            try checkpoint(.beforeCreatePromotion, operation.operationID)
            try fileSystem.promoteCreate(
                staged: stagedItem(for: operation),
                skillID: operation.skillID
            )
            try checkpoint(.afterCreatePromotion, operation.operationID)
        case .recordFilesystemApplied:
            try checkpoint(.beforeFilesystemPhase, operation.operationID)
            try restoreParentDurability(for: operation)
            try requireAuthority()
            try journal.recordFilesystemApplied(
                operationID: operation.operationID,
                updatedAtMilliseconds: timestamp(for: operation)
            )
            try checkpoint(.afterFilesystemPhase, operation.operationID)
        case .commitCreate:
            try checkpoint(.beforeDomainTransaction, operation.operationID)
            try commitDomain(operation) {
                try journal.commitCreate(
                    operationID: operation.operationID,
                    updatedAtMilliseconds: timestamp(for: operation)
                )
            }
            try checkpoint(.afterDomainTransaction, operation.operationID)
        case .swapReplacement:
            try checkpoint(.beforeReplacementSwap, operation.operationID)
            try swapReplacement(operation)
            try checkpoint(.afterReplacementSwap, operation.operationID)
        case .commitReplacement:
            try checkpoint(.beforeDomainTransaction, operation.operationID)
            try commitDomain(operation) {
                try journal.commitReplacement(
                    operationID: operation.operationID,
                    updatedAtMilliseconds: timestamp(for: operation)
                )
            }
            try checkpoint(.afterDomainTransaction, operation.operationID)
        case .cleanupReplacement:
            try cleanupAppliedReplacement(operation)
        }
    }

    private func swapReplacement(_ operation: SSOTJournalRecord) throws {
        guard let oldIdentity = operation.expectedOldIdentity,
              let oldFingerprint = operation.oldFingerprint else {
            throw JournaledSSOTWriterError.invalidInput
        }
        _ = try fileSystem.swapReplacement(
            staged: stagedItem(for: operation),
            skillID: operation.skillID,
            expectedOldIdentity: oldIdentity,
            expectedOldFingerprint: oldFingerprint
        )
    }

    private func complete(
        _ operation: SSOTJournalRecord,
        outcome: SSOTOperationOutcome,
        cleanupState: SSOTCleanupState
    ) throws -> SSOTJournalRecord {
        if cleanupState == .pending {
            try retryCleanupDebt(operation)
            return try journal.loadOperation(operation.operationID)
        }
        guard operation.state.phase != .completed else { return operation }
        guard outcome == .applied else {
            throw JournaledSSOTWriterError.operationRolledBack(operation.operationID)
        }
        try checkpoint(.beforeTerminalCompletion, operation.operationID)
        try requireAuthority()
        try journal.completeApplied(
            operationID: operation.operationID,
            cleanupState: cleanupState,
            updatedAtMilliseconds: timestamp(for: operation)
        )
        try checkpoint(.afterTerminalCompletion, operation.operationID)
        return try journal.loadOperation(operation.operationID)
    }

    private func stagedItem(for operation: SSOTJournalRecord) -> SSOTStagedItem {
        SSOTStagedItem(
            reference: .staging(operationID: operation.operationID.uuid),
            identity: operation.expectedStagedIdentity,
            fingerprint: operation.newFingerprint
        )
    }

    private func restoreParentDurability(for operation: SSOTJournalRecord) throws {
        try fileSystem.validateAuthority()
        try SSOTDurability.syncDirectory(fileSystem.managedRootGuard.rootDescriptor)
        try fileSystem.validateAuthority()
        let snapshot = try recoverySnapshot(for: operation)
        guard SSOTRecoveryClassifier.classify(snapshot) == .advance(.recordFilesystemApplied) else {
            let code: SSOTRecoveryErrorCode = operation.operationType == .create
                ? .createStateMismatch : .replaceStateMismatch
            try markNeedsRepair(operation, code: code, detail: nil)
            throw JournaledSSOTWriterError.operationNeedsRepair(operation.operationID, code)
        }
    }

    private func commitDomain(
        _ operation: SSOTJournalRecord,
        body: () throws -> Void
    ) throws {
        do {
            try requireAuthority()
            try body()
        } catch let error as SSOTJournalStoreError where error == .databaseConflict {
            try markNeedsRepair(operation, code: mismatchCode(for: operation), detail: error)
            throw JournaledSSOTWriterError.operationNeedsRepair(
                operation.operationID,
                mismatchCode(for: operation)
            )
        } catch let error as SQLiteStoreError where error.isConstraintViolation {
            try markNeedsRepair(operation, code: mismatchCode(for: operation), detail: error)
            throw JournaledSSOTWriterError.operationNeedsRepair(
                operation.operationID,
                mismatchCode(for: operation)
            )
        }
    }

    func markNeedsRepair(
        _ operation: SSOTJournalRecord,
        code: SSOTRecoveryErrorCode,
        detail: Error?
    ) throws {
        try requireAuthority()
        try journal.markNeedsRepair(
            operationID: operation.operationID,
            errorCode: code,
            detail: detail?.localizedDescription ?? code.rawValue,
            updatedAtMilliseconds: timestamp(for: operation)
        )
    }

    private func handleCancellation(_ operation: SSOTJournalRecord) throws {
        guard Task.isCancelled else { return }
        if operation.state.phase == .prepared {
            do {
                try cancelPrepared(operation.operationID)
            } catch JournaledSSOTWriterError.invalidInput {
                // A rename/swap may already have happened; leave the journal for recovery.
            }
        }
        throw CancellationError()
    }
}

private extension SQLiteStoreError {
    var isConstraintViolation: Bool {
        guard case .sqlite(_, let code, _) = self else { return false }
        return code & 0xff == 19
    }
}
