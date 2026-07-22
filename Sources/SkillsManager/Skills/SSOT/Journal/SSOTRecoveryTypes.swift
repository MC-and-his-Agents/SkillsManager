nonisolated enum SSOTOperationType: String, CaseIterable, Sendable {
    case create
    case replace
}

nonisolated enum SSOTJournalPhase: String, CaseIterable, Sendable {
    case prepared
    case filesystemApplied
    case databaseCommitted
    case completed
}

nonisolated enum SSOTOperationOutcome: String, CaseIterable, Sendable {
    case pending
    case applied
    case rolledBack
    case needsRepair
}

nonisolated enum SSOTCleanupState: String, CaseIterable, Sendable {
    case notApplicable
    case notStarted
    case pending
    case completed
    case needsRepair
}

nonisolated struct SSOTJournalState: Equatable, Sendable {
    let phase: SSOTJournalPhase
    let outcome: SSOTOperationOutcome
    let cleanupState: SSOTCleanupState
}

/// A database observation made after validating the expected revision and fingerprint.
nonisolated enum SSOTDatabaseObservation: String, CaseIterable, Sendable {
    case absent
    case expectedOld
    case expectedNew
    case unknown
}

/// A final-directory observation made after validating item identity and fingerprint.
nonisolated enum SSOTFinalObservation: String, CaseIterable, Sendable {
    case absent
    case expectedOld
    case expectedNew
    case unknown
}

/// A staging-directory observation made after validating operation ownership and identity.
nonisolated enum SSOTStagingObservation: String, CaseIterable, Sendable {
    case missing
    case expectedNew
    case unknown
}

/// A recovery-directory observation made after validating operation ownership and old identity.
nonisolated enum SSOTRecoveryItemObservation: String, CaseIterable, Sendable {
    case missing
    case expectedOld
    case unknown
}

/// A cleanup-debt observation made after validating its locator, role, and identities.
nonisolated enum SSOTCleanupDebtObservation: String, CaseIterable, Sendable {
    case none
    case verifiedStaging
    case verifiedRecovery
    case unknown
}

nonisolated struct SSOTRecoveryLimits: Equatable, Sendable {
    static let `default` = SSOTRecoveryLimits(
        maximumAttemptCount: 10_000,
        maximumLastErrorUTF8ByteCount: 4_096
    )

    let maximumAttemptCount: Int64
    let maximumLastErrorUTF8ByteCount: Int
}

nonisolated struct SSOTRecoverySnapshot: Equatable, Sendable {
    let operationType: SSOTOperationType
    let journal: SSOTJournalState
    let database: SSOTDatabaseObservation
    let final: SSOTFinalObservation
    let staging: SSOTStagingObservation
    let recovery: SSOTRecoveryItemObservation
    let cleanupDebt: SSOTCleanupDebtObservation
    let attemptCount: Int64
    let lastErrorUTF8ByteCount: Int

    init(
        operationType: SSOTOperationType,
        journal: SSOTJournalState,
        database: SSOTDatabaseObservation,
        final: SSOTFinalObservation,
        staging: SSOTStagingObservation,
        recovery: SSOTRecoveryItemObservation,
        cleanupDebt: SSOTCleanupDebtObservation = .none,
        attemptCount: Int64 = 0,
        lastErrorUTF8ByteCount: Int = 0
    ) {
        self.operationType = operationType
        self.journal = journal
        self.database = database
        self.final = final
        self.staging = staging
        self.recovery = recovery
        self.cleanupDebt = cleanupDebt
        self.attemptCount = attemptCount
        self.lastErrorUTF8ByteCount = lastErrorUTF8ByteCount
    }
}

nonisolated enum SSOTRecoveryStep: String, Equatable, Sendable {
    case promoteCreate
    case recordFilesystemApplied
    case commitCreate
    case swapReplacement
    case commitReplacement
    case cleanupReplacement
}

nonisolated enum SSOTRecoveryErrorCode: String, Equatable, Sendable {
    case journalMarkedNeedsRepair = "SM-SSOT-RECOVERY-001"
    case invalidJournalState = "SM-SSOT-RECOVERY-002"
    case attemptLimitExceeded = "SM-SSOT-RECOVERY-003"
    case errorDetailLimitExceeded = "SM-SSOT-RECOVERY-004"
    case cleanupDebtMismatch = "SM-SSOT-RECOVERY-005"
    case cleanupIdentityDrift = "SM-SSOT-RECOVERY-006"
    case createStateMismatch = "SM-SSOT-RECOVERY-101"
    case replaceStateMismatch = "SM-SSOT-RECOVERY-102"
}

nonisolated enum SSOTRecoveryDecision: Equatable, Sendable {
    case advance(SSOTRecoveryStep)
    case complete(outcome: SSOTOperationOutcome, cleanupState: SSOTCleanupState)
    case needsRepair(SSOTRecoveryErrorCode)
}
