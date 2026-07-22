import Testing

@testable import SkillsManager

@Suite("SSOT recovery truth table")
struct SSOTRecoveryClassifierTests {
    @Test("create permits only the specified active-phase combinations")
    func createTruthTableFailsClosed() {
        var allowedCount = 0

        for phase in [
            SSOTJournalPhase.prepared,
            .filesystemApplied,
            .databaseCommitted,
        ] {
            for observations in allObservations {
                for cleanupDebt in SSOTCleanupDebtObservation.allCases {
                    let snapshot = makeSnapshot(
                        operationType: .create,
                        phase: phase,
                        cleanupState: .notApplicable,
                        observations: observations,
                        cleanupDebt: cleanupDebt
                    )
                    let decision = SSOTRecoveryClassifier.classify(snapshot)
                    let expected = expectedCreateDecision(
                        phase: phase,
                        observations: observations,
                        cleanupDebt: cleanupDebt
                    )

                    #expect(decision == expected)
                    if !isNeedsRepair(decision) { allowedCount += 1 }
                }
            }
        }

        #expect(allowedCount == 4)
    }

    @Test("replace permits only the specified active-phase combinations")
    func replaceTruthTableFailsClosed() {
        var allowedCount = 0

        for phase in [
            SSOTJournalPhase.prepared,
            .filesystemApplied,
            .databaseCommitted,
        ] {
            let cleanupStates: [SSOTCleanupState] = phase == .databaseCommitted
                ? [.notStarted, .pending, .completed]
                : [.notStarted]
            for cleanupState in cleanupStates {
                for observations in allObservations {
                    for cleanupDebt in SSOTCleanupDebtObservation.allCases {
                        let snapshot = makeSnapshot(
                            operationType: .replace,
                            phase: phase,
                            cleanupState: cleanupState,
                            observations: observations,
                            cleanupDebt: cleanupDebt
                        )
                        let decision = SSOTRecoveryClassifier.classify(snapshot)
                        let expected = expectedReplaceDecision(
                            phase: phase,
                            cleanupState: cleanupState,
                            observations: observations,
                            cleanupDebt: cleanupDebt
                        )

                        #expect(decision == expected)
                        if !isNeedsRepair(decision) { allowedCount += 1 }
                    }
                }
            }
        }

        #expect(allowedCount == 7)
    }

    @Test("completed phase permits only role-bound cleanup debt combinations")
    func completedTruthTableFailsClosed() {
        for operationType in SSOTOperationType.allCases {
            var allowedCount = 0
            for outcome in SSOTOperationOutcome.allCases {
                for cleanupState in SSOTCleanupState.allCases {
                    for observations in allObservations {
                        for cleanupDebt in SSOTCleanupDebtObservation.allCases {
                            let decision = SSOTRecoveryClassifier.classify(makeSnapshot(
                                operationType: operationType,
                                phase: .completed,
                                outcome: outcome,
                                cleanupState: cleanupState,
                                observations: observations,
                                cleanupDebt: cleanupDebt
                            ))
                            let expected = expectedCompletedDecision(
                                operationType: operationType,
                                outcome: outcome,
                                cleanupState: cleanupState,
                                observations: observations,
                                cleanupDebt: cleanupDebt
                            )

                            if let expected {
                                #expect(decision == expected)
                                allowedCount += 1
                            } else {
                                #expect(isNeedsRepair(decision))
                            }
                        }
                    }
                }
            }
            let repairCount = allObservations.count * (operationType == .create ? 1 : 2)
            #expect(allowedCount == (operationType == .create ? 4 : 6) + repairCount)
        }
    }

    @Test("terminal cleanup identity drift requires a role-bound debt")
    func cleanupIdentityDriftIsStableAndRoleBound() {
        let cases: [(SSOTOperationType, SSOTOperationOutcome, SSOTCleanupDebtObservation)] = [
            (.create, .rolledBack, .verifiedStaging),
            (.replace, .applied, .verifiedRecovery),
            (.replace, .rolledBack, .verifiedStaging),
        ]

        for (operationType, outcome, expectedDebt) in cases {
            for observations in allObservations {
                let decision = SSOTRecoveryClassifier.classify(makeSnapshot(
                    operationType: operationType,
                    phase: .completed,
                    outcome: outcome,
                    cleanupState: .needsRepair,
                    observations: observations,
                    cleanupDebt: expectedDebt
                ))
                #expect(decision == .needsRepair(.cleanupIdentityDrift))
            }
            for debt in SSOTCleanupDebtObservation.allCases where debt != expectedDebt {
                let decision = SSOTRecoveryClassifier.classify(makeSnapshot(
                    operationType: operationType,
                    phase: .completed,
                    outcome: outcome,
                    cleanupState: .needsRepair,
                    observations: allObservations[0],
                    cleanupDebt: debt
                ))
                #expect(decision == .needsRepair(.cleanupDebtMismatch))
            }
        }

        #expect(SSOTRecoveryClassifier.classify(makeSnapshot(
            operationType: .create,
            phase: .completed,
            outcome: .applied,
            cleanupState: .needsRepair,
            observations: allObservations[0],
            cleanupDebt: .verifiedStaging
        )) == .needsRepair(.invalidJournalState))
        #expect(SSOTRecoveryClassifier.classify(makeSnapshot(
            operationType: .replace,
            phase: .prepared,
            cleanupState: .needsRepair,
            observations: allObservations[0],
            cleanupDebt: .verifiedRecovery
        )) == .needsRepair(.invalidJournalState))
    }

    @Test("persisted needsRepair never advances at any phase")
    func needsRepairIsAlwaysTerminal() {
        for operationType in SSOTOperationType.allCases {
            for phase in SSOTJournalPhase.allCases {
                for observations in allObservations {
                    for cleanupDebt in SSOTCleanupDebtObservation.allCases {
                        let decision = SSOTRecoveryClassifier.classify(makeSnapshot(
                            operationType: operationType,
                            phase: phase,
                            outcome: .needsRepair,
                            cleanupState: operationType == .create ? .notApplicable : .notStarted,
                            observations: observations,
                            cleanupDebt: cleanupDebt
                        ))
                        #expect(isNeedsRepair(decision))
                    }
                }
            }
        }
    }

    @Test("database-committed repair retains its verified recovery debt")
    func databaseCommittedRepairDebtIsStable() {
        let snapshot = SSOTRecoverySnapshot(
            operationType: .replace,
            journal: .init(
                phase: .databaseCommitted,
                outcome: .needsRepair,
                cleanupState: .pending
            ),
            database: .expectedNew,
            final: .expectedNew,
            staging: .missing,
            recovery: .missing,
            cleanupDebt: .verifiedRecovery
        )
        #expect(
            SSOTRecoveryClassifier.classify(snapshot)
                == .needsRepair(.journalMarkedNeedsRepair)
        )
    }

    @Test("invalid journal state, persisted repair and resource limits use stable codes")
    func validationAndStableCodes() {
        let safeObservations = Observations(
            database: .absent,
            final: .absent,
            staging: .expectedNew,
            recovery: .missing
        )

        #expect(SSOTRecoveryClassifier.classify(makeSnapshot(
            operationType: .create,
            phase: .prepared,
            outcome: .applied,
            cleanupState: .notApplicable,
            observations: safeObservations
        )) == .needsRepair(.invalidJournalState))

        #expect(SSOTRecoveryClassifier.classify(makeSnapshot(
            operationType: .create,
            phase: .prepared,
            outcome: .needsRepair,
            cleanupState: .notApplicable,
            observations: safeObservations
        )) == .needsRepair(.journalMarkedNeedsRepair))

        #expect(SSOTRecoveryClassifier.classify(makeSnapshot(
            operationType: .create,
            phase: .prepared,
            cleanupState: .notApplicable,
            observations: safeObservations,
            attemptCount: -1
        )) == .needsRepair(.attemptLimitExceeded))

        #expect(SSOTRecoveryClassifier.classify(makeSnapshot(
            operationType: .create,
            phase: .prepared,
            cleanupState: .notApplicable,
            observations: safeObservations,
            attemptCount: 10_000
        )) == .advance(.promoteCreate))

        #expect(SSOTRecoveryClassifier.classify(makeSnapshot(
            operationType: .create,
            phase: .prepared,
            cleanupState: .notApplicable,
            observations: safeObservations,
            attemptCount: 10_001
        )) == .needsRepair(.attemptLimitExceeded))

        #expect(SSOTRecoveryClassifier.classify(makeSnapshot(
            operationType: .create,
            phase: .prepared,
            cleanupState: .notApplicable,
            observations: safeObservations,
            lastErrorUTF8ByteCount: -1
        )) == .needsRepair(.errorDetailLimitExceeded))

        #expect(SSOTRecoveryClassifier.classify(makeSnapshot(
            operationType: .create,
            phase: .prepared,
            cleanupState: .notApplicable,
            observations: safeObservations,
            lastErrorUTF8ByteCount: 4_096
        )) == .advance(.promoteCreate))

        #expect(SSOTRecoveryClassifier.classify(makeSnapshot(
            operationType: .create,
            phase: .prepared,
            cleanupState: .notApplicable,
            observations: safeObservations,
            lastErrorUTF8ByteCount: 4_097
        )) == .needsRepair(.errorDetailLimitExceeded))

        #expect(SSOTRecoveryErrorCode.journalMarkedNeedsRepair.rawValue == "SM-SSOT-RECOVERY-001")
        #expect(SSOTRecoveryErrorCode.invalidJournalState.rawValue == "SM-SSOT-RECOVERY-002")
        #expect(SSOTRecoveryErrorCode.attemptLimitExceeded.rawValue == "SM-SSOT-RECOVERY-003")
        #expect(SSOTRecoveryErrorCode.errorDetailLimitExceeded.rawValue == "SM-SSOT-RECOVERY-004")
        #expect(SSOTRecoveryErrorCode.cleanupDebtMismatch.rawValue == "SM-SSOT-RECOVERY-005")
        #expect(SSOTRecoveryErrorCode.cleanupIdentityDrift.rawValue == "SM-SSOT-RECOVERY-006")
        #expect(SSOTRecoveryErrorCode.createStateMismatch.rawValue == "SM-SSOT-RECOVERY-101")
        #expect(SSOTRecoveryErrorCode.replaceStateMismatch.rawValue == "SM-SSOT-RECOVERY-102")
    }
}

private struct Observations: Equatable {
    let database: SSOTDatabaseObservation
    let final: SSOTFinalObservation
    let staging: SSOTStagingObservation
    let recovery: SSOTRecoveryItemObservation
}

private let allObservations: [Observations] = SSOTDatabaseObservation.allCases.flatMap { database in
    SSOTFinalObservation.allCases.flatMap { final in
        SSOTStagingObservation.allCases.flatMap { staging in
            SSOTRecoveryItemObservation.allCases.map { recovery in
                Observations(
                    database: database,
                    final: final,
                    staging: staging,
                    recovery: recovery
                )
            }
        }
    }
}

private func makeSnapshot(
    operationType: SSOTOperationType,
    phase: SSOTJournalPhase,
    outcome: SSOTOperationOutcome = .pending,
    cleanupState: SSOTCleanupState,
    observations: Observations,
    cleanupDebt: SSOTCleanupDebtObservation = .none,
    attemptCount: Int64 = 0,
    lastErrorUTF8ByteCount: Int = 0
) -> SSOTRecoverySnapshot {
    SSOTRecoverySnapshot(
        operationType: operationType,
        journal: .init(phase: phase, outcome: outcome, cleanupState: cleanupState),
        database: observations.database,
        final: observations.final,
        staging: observations.staging,
        recovery: observations.recovery,
        cleanupDebt: cleanupDebt,
        attemptCount: attemptCount,
        lastErrorUTF8ByteCount: lastErrorUTF8ByteCount
    )
}

private func expectedCreateDecision(
    phase: SSOTJournalPhase,
    observations: Observations,
    cleanupDebt: SSOTCleanupDebtObservation
) -> SSOTRecoveryDecision {
    guard cleanupDebt == .none else {
        return .needsRepair(.cleanupDebtMismatch)
    }
    switch (phase, observations) {
    case (.prepared, .init(database: .absent, final: .absent, staging: .expectedNew, recovery: .missing)):
        return .advance(.promoteCreate)
    case (.prepared, .init(database: .absent, final: .expectedNew, staging: .missing, recovery: .missing)):
        return .advance(.recordFilesystemApplied)
    case (.filesystemApplied, .init(database: .absent, final: .expectedNew, staging: .missing, recovery: .missing)):
        return .advance(.commitCreate)
    case (.databaseCommitted, .init(database: .expectedNew, final: .expectedNew, staging: .missing, recovery: .missing)):
        return .complete(outcome: .applied, cleanupState: .notApplicable)
    default:
        return .needsRepair(.createStateMismatch)
    }
}

private func expectedReplaceDecision(
    phase: SSOTJournalPhase,
    cleanupState: SSOTCleanupState,
    observations: Observations,
    cleanupDebt: SSOTCleanupDebtObservation
) -> SSOTRecoveryDecision {
    let expectedDebt: SSOTCleanupDebtObservation = cleanupState == .pending
        ? .verifiedRecovery
        : .none
    guard cleanupDebt == expectedDebt else {
        return .needsRepair(.cleanupDebtMismatch)
    }
    switch (phase, cleanupState, observations) {
    case (.prepared, .notStarted, .init(database: .expectedOld, final: .expectedOld, staging: .expectedNew, recovery: .missing)):
        return .advance(.swapReplacement)
    case (.prepared, .notStarted, .init(database: .expectedOld, final: .expectedNew, staging: .missing, recovery: .expectedOld)):
        return .advance(.recordFilesystemApplied)
    case (.filesystemApplied, .notStarted, .init(database: .expectedOld, final: .expectedNew, staging: .missing, recovery: .expectedOld)):
        return .advance(.commitReplacement)
    case (.databaseCommitted, .notStarted, .init(database: .expectedNew, final: .expectedNew, staging: .missing, recovery: .expectedOld)):
        return .advance(.cleanupReplacement)
    case (.databaseCommitted, .pending, .init(database: .expectedNew, final: .expectedNew, staging: .missing, recovery: .expectedOld)),
         (.databaseCommitted, .pending, .init(database: .expectedNew, final: .expectedNew, staging: .missing, recovery: .missing)):
        return .complete(outcome: .applied, cleanupState: .pending)
    case (.databaseCommitted, .completed, .init(database: .expectedNew, final: .expectedNew, staging: .missing, recovery: .missing)):
        return .complete(outcome: .applied, cleanupState: .completed)
    default:
        return .needsRepair(.replaceStateMismatch)
    }
}

private func expectedCompletedDecision(
    operationType: SSOTOperationType,
    outcome: SSOTOperationOutcome,
    cleanupState: SSOTCleanupState,
    observations: Observations,
    cleanupDebt: SSOTCleanupDebtObservation
) -> SSOTRecoveryDecision? {
    switch (operationType, outcome, cleanupState, observations, cleanupDebt) {
    case (.create, .applied, .notApplicable,
          .init(database: .expectedNew, final: .expectedNew, staging: .missing, recovery: .missing),
          .none):
        return .complete(outcome: .applied, cleanupState: .notApplicable)
    case (.create, .rolledBack, .completed,
          .init(database: .absent, final: .absent, staging: .missing, recovery: .missing),
          .none):
        return .complete(outcome: .rolledBack, cleanupState: .completed)
    case (.create, .rolledBack, .pending,
          .init(database: .absent, final: .absent, staging: .expectedNew, recovery: .missing),
          .verifiedStaging),
         (.create, .rolledBack, .pending,
          .init(database: .absent, final: .absent, staging: .missing, recovery: .missing),
          .verifiedStaging):
        return .complete(outcome: .rolledBack, cleanupState: .pending)
    case (.create, .rolledBack, .needsRepair, _, .verifiedStaging):
        return .needsRepair(.cleanupIdentityDrift)
    case (.replace, .applied, .completed,
          .init(database: .expectedNew, final: .expectedNew, staging: .missing, recovery: .missing),
          .none):
        return .complete(outcome: .applied, cleanupState: .completed)
    case (.replace, .applied, .pending,
          .init(database: .expectedNew, final: .expectedNew, staging: .missing, recovery: .expectedOld),
          .verifiedRecovery),
         (.replace, .applied, .pending,
          .init(database: .expectedNew, final: .expectedNew, staging: .missing, recovery: .missing),
          .verifiedRecovery):
        return .complete(outcome: .applied, cleanupState: .pending)
    case (.replace, .rolledBack, .completed,
          .init(database: .expectedOld, final: .expectedOld, staging: .missing, recovery: .missing),
          .none):
        return .complete(outcome: .rolledBack, cleanupState: .completed)
    case (.replace, .rolledBack, .pending,
          .init(database: .expectedOld, final: .expectedOld, staging: .expectedNew, recovery: .missing),
          .verifiedStaging),
         (.replace, .rolledBack, .pending,
          .init(database: .expectedOld, final: .expectedOld, staging: .missing, recovery: .missing),
          .verifiedStaging):
        return .complete(outcome: .rolledBack, cleanupState: .pending)
    case (.replace, .applied, .needsRepair, _, .verifiedRecovery),
         (.replace, .rolledBack, .needsRepair, _, .verifiedStaging):
        return .needsRepair(.cleanupIdentityDrift)
    default:
        return nil
    }
}

private func isNeedsRepair(_ decision: SSOTRecoveryDecision) -> Bool {
    if case .needsRepair = decision { return true }
    return false
}
