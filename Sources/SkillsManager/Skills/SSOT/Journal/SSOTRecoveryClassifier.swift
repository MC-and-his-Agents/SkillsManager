nonisolated enum SSOTRecoveryClassifier {
    static func classify(
        _ snapshot: SSOTRecoverySnapshot,
        limits: SSOTRecoveryLimits = .default
    ) -> SSOTRecoveryDecision {
        guard snapshot.attemptCount >= 0,
              snapshot.attemptCount <= limits.maximumAttemptCount else {
            return .needsRepair(.attemptLimitExceeded)
        }
        guard snapshot.lastErrorUTF8ByteCount >= 0,
              snapshot.lastErrorUTF8ByteCount <= limits.maximumLastErrorUTF8ByteCount else {
            return .needsRepair(.errorDetailLimitExceeded)
        }
        guard isValidJournalState(snapshot.journal, operationType: snapshot.operationType) else {
            return .needsRepair(.invalidJournalState)
        }
        guard hasValidCleanupDebt(snapshot) else {
            return .needsRepair(.cleanupDebtMismatch)
        }
        if snapshot.journal.cleanupState == .needsRepair {
            return .needsRepair(.cleanupIdentityDrift)
        }
        if snapshot.journal.outcome == .needsRepair {
            return .needsRepair(.journalMarkedNeedsRepair)
        }

        switch snapshot.operationType {
        case .create:
            return classifyCreate(snapshot)
        case .replace:
            return classifyReplace(snapshot)
        }
    }

    private static func classifyCreate(
        _ snapshot: SSOTRecoverySnapshot
    ) -> SSOTRecoveryDecision {
        let observations = (
            snapshot.database,
            snapshot.final,
            snapshot.staging,
            snapshot.recovery
        )

        switch snapshot.journal.phase {
        case .prepared:
            if observations == (.absent, .absent, .expectedNew, .missing) {
                return .advance(.promoteCreate)
            }
            if observations == (.absent, .expectedNew, .missing, .missing) {
                return .advance(.recordFilesystemApplied)
            }
        case .filesystemApplied:
            if observations == (.absent, .expectedNew, .missing, .missing) {
                return .advance(.commitCreate)
            }
        case .databaseCommitted:
            if observations == (.expectedNew, .expectedNew, .missing, .missing) {
                return .complete(outcome: .applied, cleanupState: .notApplicable)
            }
        case .completed:
            return classifyCompletedCreate(snapshot, observations: observations)
        }
        return .needsRepair(.createStateMismatch)
    }

    private static func classifyCompletedCreate(
        _ snapshot: SSOTRecoverySnapshot,
        observations: (
            SSOTDatabaseObservation,
            SSOTFinalObservation,
            SSOTStagingObservation,
            SSOTRecoveryItemObservation
        )
    ) -> SSOTRecoveryDecision {
        switch snapshot.journal.outcome {
        case .applied where observations == (.expectedNew, .expectedNew, .missing, .missing):
            return .complete(outcome: .applied, cleanupState: snapshot.journal.cleanupState)
        case .rolledBack:
            if snapshot.journal.cleanupState == .completed,
               observations == (.absent, .absent, .missing, .missing) {
                return .complete(outcome: .rolledBack, cleanupState: .completed)
            }
            if snapshot.journal.cleanupState == .pending,
               (observations == (.absent, .absent, .expectedNew, .missing)
                || observations == (.absent, .absent, .missing, .missing)) {
                return .complete(outcome: .rolledBack, cleanupState: .pending)
            }
            return .needsRepair(.createStateMismatch)
        default:
            return .needsRepair(.createStateMismatch)
        }
    }

    private static func classifyReplace(
        _ snapshot: SSOTRecoverySnapshot
    ) -> SSOTRecoveryDecision {
        let observations = (
            snapshot.database,
            snapshot.final,
            snapshot.staging,
            snapshot.recovery
        )

        switch snapshot.journal.phase {
        case .prepared:
            if observations == (.expectedOld, .expectedOld, .expectedNew, .missing) {
                return .advance(.swapReplacement)
            }
            if observations == (.expectedOld, .expectedNew, .missing, .expectedOld) {
                return .advance(.recordFilesystemApplied)
            }
        case .filesystemApplied:
            if observations == (.expectedOld, .expectedNew, .missing, .expectedOld) {
                return .advance(.commitReplacement)
            }
        case .databaseCommitted:
            if snapshot.journal.cleanupState == .notStarted,
               observations == (.expectedNew, .expectedNew, .missing, .expectedOld) {
                return .advance(.cleanupReplacement)
            }
            if snapshot.journal.cleanupState == .pending,
               (observations == (.expectedNew, .expectedNew, .missing, .expectedOld)
                || observations == (.expectedNew, .expectedNew, .missing, .missing)) {
                return .complete(outcome: .applied, cleanupState: .pending)
            }
            if snapshot.journal.cleanupState == .completed,
               observations == (.expectedNew, .expectedNew, .missing, .missing) {
                return .complete(
                    outcome: .applied,
                    cleanupState: .completed
                )
            }
        case .completed:
            return classifyCompletedReplace(snapshot, observations: observations)
        }
        return .needsRepair(.replaceStateMismatch)
    }

    private static func classifyCompletedReplace(
        _ snapshot: SSOTRecoverySnapshot,
        observations: (
            SSOTDatabaseObservation,
            SSOTFinalObservation,
            SSOTStagingObservation,
            SSOTRecoveryItemObservation
        )
    ) -> SSOTRecoveryDecision {
        switch snapshot.journal.outcome {
        case .applied:
            if snapshot.journal.cleanupState == .completed,
               observations == (.expectedNew, .expectedNew, .missing, .missing) {
                return .complete(outcome: .applied, cleanupState: .completed)
            }
            if snapshot.journal.cleanupState == .pending,
               (observations == (.expectedNew, .expectedNew, .missing, .expectedOld)
                || observations == (.expectedNew, .expectedNew, .missing, .missing)) {
                return .complete(outcome: .applied, cleanupState: .pending)
            }
        case .rolledBack:
            if snapshot.journal.cleanupState == .completed,
               observations == (.expectedOld, .expectedOld, .missing, .missing) {
                return .complete(outcome: .rolledBack, cleanupState: .completed)
            }
            if snapshot.journal.cleanupState == .pending,
               (observations == (.expectedOld, .expectedOld, .expectedNew, .missing)
                || observations == (.expectedOld, .expectedOld, .missing, .missing)) {
                return .complete(
                    outcome: .rolledBack,
                    cleanupState: .pending
                )
            }
        default:
            break
        }
        return .needsRepair(.replaceStateMismatch)
    }

    private static func isValidJournalState(
        _ state: SSOTJournalState,
        operationType: SSOTOperationType
    ) -> Bool {
        if state.phase == .completed {
            guard state.outcome == .applied || state.outcome == .rolledBack else {
                return false
            }
        } else if state.outcome != .pending && state.outcome != .needsRepair {
            return false
        }

        switch (operationType, state.phase, state.outcome, state.cleanupState) {
        case (.create, .completed, .rolledBack, .pending),
             (.create, .completed, .rolledBack, .completed):
            return true
        case (.create, .completed, .rolledBack, .needsRepair):
            return true
        case (.create, _, _, .notApplicable):
            return true
        case (.replace, .prepared, .pending, .notStarted),
             (.replace, .filesystemApplied, .pending, .notStarted),
             (.replace, .databaseCommitted, .pending, .notStarted),
             (.replace, .databaseCommitted, .pending, .pending),
             (.replace, .databaseCommitted, .pending, .completed),
             (.replace, .completed, .applied, .pending),
             (.replace, .completed, .applied, .completed),
             (.replace, .completed, .applied, .needsRepair),
             (.replace, .completed, .rolledBack, .pending),
             (.replace, .completed, .rolledBack, .completed),
             (.replace, .completed, .rolledBack, .needsRepair):
            return true
        case (_, _, .needsRepair, .needsRepair):
            return false
        case (_, _, .needsRepair, _):
            return true
        default:
            return false
        }
    }

    private static func hasValidCleanupDebt(_ snapshot: SSOTRecoverySnapshot) -> Bool {
        let expected: SSOTCleanupDebtObservation?
        if snapshot.journal.cleanupState != .pending,
           snapshot.journal.cleanupState != .needsRepair {
            expected = SSOTCleanupDebtObservation.none
        } else {
            switch (
                snapshot.operationType,
                snapshot.journal.phase,
                snapshot.journal.outcome
            ) {
            case (.create, .completed, .rolledBack),
                 (.replace, .completed, .rolledBack):
                expected = .verifiedStaging
            case (.replace, .databaseCommitted, .pending),
                 (.replace, .databaseCommitted, .needsRepair),
                 (.replace, .completed, .applied):
                expected = .verifiedRecovery
            default:
                expected = nil
            }
        }
        guard let expected else { return false }
        return snapshot.cleanupDebt == expected
    }
}
