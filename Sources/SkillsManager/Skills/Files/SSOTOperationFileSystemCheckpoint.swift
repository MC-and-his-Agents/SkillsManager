import Darwin
import Foundation

nonisolated enum SSOTManagedItemObservation: Equatable, Sendable {
    case absent
    case expected
    case unknown
}

nonisolated enum SSOTOperationItemRole: Equatable, Sendable {
    case staging
    case recovery
}

/// A journal-owned direct child. Staging and recovery intentionally resolve to
/// the same operation UUID name before and after `RENAME_SWAP`.
nonisolated struct SSOTOperationItemReference: Equatable, Sendable {
    let operationID: UUID
    let role: SSOTOperationItemRole

    static func staging(operationID: UUID) -> Self {
        Self(operationID: operationID, role: .staging)
    }

    static func recovery(operationID: UUID) -> Self {
        Self(operationID: operationID, role: .recovery)
    }
}

nonisolated struct SSOTStagedItem: Sendable {
    let reference: SSOTOperationItemReference
    let identity: ManagedItemIdentity
    let fingerprint: SkillContentFingerprint
}

nonisolated enum SSOTOperationFileSystemError: LocalizedError, Equatable {
    case invalidOperationItemRole
    case stagingAlreadyExists
    case stagedContentMismatch
    case destinationAlreadyExists
    case itemChanged
    case stagingCleanupFailed(String)
    case posix(operation: String, code: Int32)

    var errorDescription: String? {
        switch self {
        case .invalidOperationItemRole:
            "The operation-owned item has the wrong lifecycle role."
        case .stagingAlreadyExists:
            "The operation-owned staging directory already exists."
        case .stagedContentMismatch:
            "The staged Skill no longer matches the expected content."
        case .destinationAlreadyExists:
            "The final Skill directory already exists."
        case .itemChanged:
            "An operation-owned Skill directory changed during the operation."
        case .stagingCleanupFailed(let reason):
            "Staging failed after its operation locator was published; "
                + "the locator was preserved for health scan: \(reason)"
        case .posix(let operation, let code):
            "\(operation) failed: \(String(cString: strerror(code)))"
        }
    }
}

nonisolated enum SSOTOperationFileSystemCheckpoint: CaseIterable, Equatable, Sendable {
    case beforeStagingDirectoryCreate
    case afterStagingDirectoryCreateBeforeCopy
    case beforeStagingDurability
    case afterStagingDurabilityBeforeParentSync
    case afterStagingParentSyncBeforeValidation
    case beforeCreateRename
    case afterCreateRenameBeforeParentSync
    case afterCreateParentSyncBeforeValidation
    case beforeReplacementSwap
    case afterReplacementSwapBeforeParentSync
    case afterReplacementParentSyncBeforeValidation
    case beforeCleanupRemoval
    case afterCleanupRemovalBeforeParentSync
    case afterCleanupParentSyncBeforeValidation
    case beforeInPlaceEntryRemoval
    case afterInPlaceEntryRemoval
    case beforeInPlaceRootRemoval
    case afterInPlaceRootRemoval
}

nonisolated struct SSOTOperationFileSystemTestHooks: Sendable {
    private let onCheckpoint: @Sendable (SSOTOperationFileSystemCheckpoint) throws -> Void

    init(
        onCheckpoint: @escaping @Sendable (SSOTOperationFileSystemCheckpoint) throws -> Void = { _ in }
    ) {
        self.onCheckpoint = onCheckpoint
    }

    func reach(_ checkpoint: SSOTOperationFileSystemCheckpoint) throws {
        try onCheckpoint(checkpoint)
    }
}
