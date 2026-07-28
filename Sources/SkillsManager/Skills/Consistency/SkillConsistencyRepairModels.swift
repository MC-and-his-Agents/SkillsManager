import Foundation

nonisolated enum SkillConsistencyRepairAction: Sendable, Equatable {
    case rebuildMissingSymlink(scopeKeys: Set<String>)
    case disableMissingBinding(scopeKeys: Set<String>)
    case skip

    var intent: DistributionRepairIntent? {
        switch self {
        case .rebuildMissingSymlink: .rebuildMissingSymlink
        case .disableMissingBinding: .disableMissingBinding
        case .skip: nil
        }
    }

    var scopeKeys: Set<String> {
        switch self {
        case .rebuildMissingSymlink(let keys),
             .disableMissingBinding(let keys):
            keys
        case .skip:
            []
        }
    }
}

nonisolated struct SkillConsistencyRepairPreview: Sendable {
    let confirmationID: UUID
    let skillID: SkillID
    let action: SkillConsistencyRepairAction
    let auditCanonicalBytes: Data
    let selectionToken: Data
    let planCanonicalBytes: Data
}

nonisolated enum SkillConsistencyRepairResult: Sendable, Equatable {
    case skipped
    case noOp
    case applied(SSOTOperationID)
}

nonisolated enum SkillConsistencyRepairError: Error, Sendable, Equatable {
    case stalePreview
    case auditIncomplete
    case invalidSelection
    case unsupportedBindingState
    case copyRequiresForkDecision
    case targetOccupied
    case permissionDenied
    case operationInProgress
    case needsRepair
    case unavailable
}
