import Foundation

nonisolated enum SSOTWriterCheckpoint: String, CaseIterable, Sendable {
    case beforeStaging
    case afterStaging
    case beforePreparedInsert
    case afterPreparedInsert
    case beforeCreatePromotion
    case afterCreatePromotion
    case beforeReplacementSwap
    case afterReplacementSwap
    case beforeFilesystemPhase
    case afterFilesystemPhase
    case beforeDomainTransaction
    case afterDomainTransaction
    case beforeCleanup
    case afterCleanup
    case beforeTerminalCompletion
    case afterTerminalCompletion
}

nonisolated struct JournaledSSOTWriterHooks: Sendable {
    var checkpoint: @Sendable (SSOTWriterCheckpoint, SSOTOperationID) throws -> Void = { _, _ in }
    var fileSystemCheckpoint: @Sendable (SSOTOperationFileSystemCheckpoint) throws -> Void = { _ in }
    var shouldFailCleanup: @Sendable (SSOTCleanupItemRole) -> Bool = { _ in false }
    var nowMilliseconds: @Sendable () -> Int64 = {
        max(0, Int64(Date().timeIntervalSince1970 * 1_000))
    }
}

nonisolated enum JournaledSSOTWriterError: LocalizedError, Equatable {
    case invalidInput
    case operationNeedsRepair(SSOTOperationID, SSOTRecoveryErrorCode)
    case operationRolledBack(SSOTOperationID)
    case recoveryDidNotConverge(SSOTOperationID)

    var errorDescription: String? {
        switch self {
        case .invalidInput:
            "The SSOT write input does not match the journal contract."
        case .operationNeedsRepair(let operationID, let code):
            "SSOT operation \(operationID.uuid) requires repair (\(code.rawValue))."
        case .operationRolledBack(let operationID):
            "SSOT operation \(operationID.uuid) was rolled back."
        case .recoveryDidNotConverge(let operationID):
            "SSOT operation \(operationID.uuid) did not converge within the recovery limit."
        }
    }
}

nonisolated struct SSOTWriterCheckpointInterruption: Error, Sendable {
    let detail: String
}

nonisolated struct SSOTReplacementExpectation: Sendable {
    let identity: ManagedItemIdentity
    let fingerprint: SkillContentFingerprint
    let databaseRevision: Int64

    init(
        identity: ManagedItemIdentity,
        fingerprint: SkillContentFingerprint,
        databaseRevision: Int64
    ) throws {
        guard databaseRevision >= 0 else { throw JournaledSSOTWriterError.invalidInput }
        self.identity = identity
        self.fingerprint = fingerprint
        self.databaseRevision = databaseRevision
    }
}
