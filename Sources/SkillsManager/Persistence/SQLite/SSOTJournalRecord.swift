import Foundation

nonisolated enum SSOTCleanupItemRole: String, Sendable {
    case staging
    case recovery
}

nonisolated struct SSOTJournalRecord: Sendable {
    let operationID: SSOTOperationID
    let operationType: SSOTOperationType
    let skillID: SkillID
    let state: SSOTJournalState
    let stagingLocator: String
    let finalLocator: String
    let recoveryLocator: String?
    let oldFingerprint: SkillContentFingerprint?
    let newFingerprint: SkillContentFingerprint
    let payload: SSOTSkillWritePayload
    let expectedStagedIdentity: ManagedItemIdentity
    let expectedOldIdentity: ManagedItemIdentity?
    let expectedNewIdentity: ManagedItemIdentity
    let expectedDatabaseRevision: Int64
    let expectedRootIdentity: ManagedItemIdentity
    let cleanupDebtID: SSOTCleanupDebtID?
    let attemptCount: Int64
    let lastError: String?
    let createdAtMilliseconds: Int64
    let updatedAtMilliseconds: Int64

    init(
        operationID: SSOTOperationID,
        operationType: SSOTOperationType,
        skillID: SkillID,
        state: SSOTJournalState,
        stagingLocator: String,
        finalLocator: String,
        recoveryLocator: String?,
        oldFingerprint: SkillContentFingerprint?,
        newFingerprint: SkillContentFingerprint,
        payload: SSOTSkillWritePayload,
        expectedStagedIdentity: ManagedItemIdentity,
        expectedOldIdentity: ManagedItemIdentity?,
        expectedNewIdentity: ManagedItemIdentity,
        expectedDatabaseRevision: Int64,
        expectedRootIdentity: ManagedItemIdentity,
        cleanupDebtID: SSOTCleanupDebtID? = nil,
        attemptCount: Int64 = 0,
        lastError: String? = nil,
        createdAtMilliseconds: Int64,
        updatedAtMilliseconds: Int64
    ) throws {
        guard payload.skill.skillID == skillID,
              payload.skill.contentFingerprint == newFingerprint else {
            throw SSOTJournalStoreError.payloadMismatch
        }
        guard finalLocator == skillID.directoryName else {
            throw SSOTJournalStoreError.invalidRecord
        }
        switch operationType {
        case .create:
            guard recoveryLocator == nil,
                  oldFingerprint == nil,
                  expectedOldIdentity == nil,
                  expectedDatabaseRevision == 0 else {
                throw SSOTJournalStoreError.invalidRecord
            }
        case .replace:
            guard recoveryLocator != nil,
                  oldFingerprint != nil,
                  expectedOldIdentity != nil else {
                throw SSOTJournalStoreError.invalidRecord
            }
        }
        guard attemptCount >= 0,
              expectedDatabaseRevision >= 0,
              createdAtMilliseconds >= 0,
              updatedAtMilliseconds >= createdAtMilliseconds,
              (lastError?.utf8.count ?? 0) <= SSOTRecoveryLimits.default.maximumLastErrorUTF8ByteCount else {
            throw SSOTJournalStoreError.invalidRecord
        }
        self.operationID = operationID
        self.operationType = operationType
        self.skillID = skillID
        self.state = state
        self.stagingLocator = stagingLocator
        self.finalLocator = finalLocator
        self.recoveryLocator = recoveryLocator
        self.oldFingerprint = oldFingerprint
        self.newFingerprint = newFingerprint
        self.payload = payload
        self.expectedStagedIdentity = expectedStagedIdentity
        self.expectedOldIdentity = expectedOldIdentity
        self.expectedNewIdentity = expectedNewIdentity
        self.expectedDatabaseRevision = expectedDatabaseRevision
        self.expectedRootIdentity = expectedRootIdentity
        self.cleanupDebtID = cleanupDebtID
        self.attemptCount = attemptCount
        self.lastError = lastError
        self.createdAtMilliseconds = createdAtMilliseconds
        self.updatedAtMilliseconds = updatedAtMilliseconds
    }
}

nonisolated struct SSOTCleanupDebtRecord: Sendable {
    let debtID: SSOTCleanupDebtID
    let operationID: SSOTOperationID
    let itemRole: SSOTCleanupItemRole
    let recoveryLocator: String
    let expectedItemIdentity: ManagedItemIdentity
    let expectedFingerprint: SkillContentFingerprint
    let expectedRootIdentity: ManagedItemIdentity
    let attemptCount: Int64
    let lastErrorCode: String
    let createdAtMilliseconds: Int64
    let updatedAtMilliseconds: Int64

    init(
        debtID: SSOTCleanupDebtID = SSOTCleanupDebtID(),
        operationID: SSOTOperationID,
        itemRole: SSOTCleanupItemRole,
        recoveryLocator: String,
        expectedItemIdentity: ManagedItemIdentity,
        expectedFingerprint: SkillContentFingerprint,
        expectedRootIdentity: ManagedItemIdentity,
        attemptCount: Int64 = 0,
        lastErrorCode: String,
        createdAtMilliseconds: Int64,
        updatedAtMilliseconds: Int64
    ) throws {
        guard !recoveryLocator.isEmpty,
              recoveryLocator.utf8.count <= 255,
              !recoveryLocator.contains("/"),
              1...128 ~= lastErrorCode.utf8.count,
              attemptCount >= 0,
              createdAtMilliseconds >= 0,
              updatedAtMilliseconds >= createdAtMilliseconds else {
            throw SSOTJournalStoreError.invalidRecord
        }
        self.debtID = debtID
        self.operationID = operationID
        self.itemRole = itemRole
        self.recoveryLocator = recoveryLocator
        self.expectedItemIdentity = expectedItemIdentity
        self.expectedFingerprint = expectedFingerprint
        self.expectedRootIdentity = expectedRootIdentity
        self.attemptCount = attemptCount
        self.lastErrorCode = lastErrorCode
        self.createdAtMilliseconds = createdAtMilliseconds
        self.updatedAtMilliseconds = updatedAtMilliseconds
    }
}

nonisolated enum SSOTJournalStoreError: LocalizedError, Equatable {
    case invalidRecord
    case payloadMismatch
    case operationNotFound
    case stateConflict
    case databaseConflict
    case corruptRecord(String)

    var errorDescription: String? {
        switch self {
        case .invalidRecord: "The SSOT journal record is invalid."
        case .payloadMismatch: "The SSOT journal payload does not match its immutable operation fields."
        case .operationNotFound: "The SSOT journal operation no longer exists."
        case .stateConflict: "The SSOT journal operation changed concurrently."
        case .databaseConflict: "The managed Skill database revision or source changed concurrently."
        case .corruptRecord(let reason): "The SSOT journal contains an invalid record: \(reason)"
        }
    }
}
