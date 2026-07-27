import Darwin
import SwiftUI

nonisolated enum SkillDistributionStateError: Error {
    case invalidPersistedBindings
}

extension SkillDistributionViewModel {
    enum Problem: Equatable {
        case invalidPersistedBindings
        case previewExpired
        case permissionDenied
        case targetUnavailable
        case needsRepair
        case operationInProgress
        case operationDidNotComplete
        case failed(String)

        var message: String {
            switch self {
            case .invalidPersistedBindings:
                "The saved distribution state is invalid and cannot be edited safely."
            case .previewExpired:
                "The preview expired because the distribution state changed. Review the refreshed state."
            case .permissionDenied:
                "Skills Manager does not have permission to access a distribution target."
            case .targetUnavailable:
                "A required distribution target is unavailable."
            case .needsRepair:
                "This Skill has an incomplete distribution operation that needs repair."
            case .operationInProgress:
                "A distribution operation is already in progress for this Skill."
            case .operationDidNotComplete:
                "The distribution operation did not reach a successful terminal state."
            case .failed(let message):
                message
            }
        }
    }

    struct TargetRow: Identifiable, Equatable, Sendable {
        let scopeKey: String
        let locator: String

        var id: String { "\(scopeKey)\u{0}\(locator)" }
    }

    struct AgentRow: Identifiable, Equatable, Sendable {
        let platform: SkillPlatform
        let locator: String
        let readsGlobalTarget: Bool
        let isCurrentlyEnabled: Bool
        let isSelected: Bool

        var id: SkillPlatform { platform }
    }

    struct PreviewRow: Identifiable, Equatable, Sendable {
        enum Kind: String, Sendable {
            case remove
            case create
            case binding
            case configuration
            case noChange
        }

        let kind: Kind
        let scopeKey: String
        let locator: String

        var id: String { "\(kind.rawValue)\u{0}\(scopeKey)\u{0}\(locator)" }
    }

    struct PendingPreview: Identifiable, Sendable {
        let id = UUID()
        let generation: UInt64
        let skillID: SkillID
        let desiredScope: DistributionDesiredScope
        let requiredAdapterCodes: Set<String>
        let plan: DistributionPlan
        let canonicalPlan: Data
        let rows: [PreviewRow]
    }
}

nonisolated extension DistributionConflictReason {
    var displayName: String {
        switch self {
        case .invalidDesiredScope: "The selected scope is invalid."
        case .unsupportedAdapter: "The selected Agent is unsupported."
        case .globalCoverageMismatch: "The global Agent coverage is inconsistent."
        case .dedicatedTargetUnavailable: "An Agent-specific target is unavailable."
        case .targetUnavailable: "The target folder is unavailable."
        case .currentBindingMissing: "A saved link is missing."
        case .managedTargetMismatch: "The saved link points to a different managed Skill."
        case .unknownObject: "An unmanaged item already exists at this target."
        case .slugOccupied: "Another managed Skill already uses this name."
        }
    }
}

extension SkillDistributionViewModel.Status {
    var displayName: String {
        switch self {
        case .notConfigured: "Not configured"
        case .inSync: "In sync"
        case .drifted: "Needs update"
        case .needsRepair: "Needs repair"
        case .operationInProgress: "Operation in progress"
        }
    }

    var systemImage: String {
        switch self {
        case .notConfigured: "circle.dashed"
        case .inSync: "checkmark.circle"
        case .drifted: "arrow.trianglehead.2.clockwise.rotate.90"
        case .needsRepair: "wrench.and.screwdriver"
        case .operationInProgress: "clock.arrow.circlepath"
        }
    }
}

extension SkillDistributionViewModel.PreviewRow.Kind {
    var displayName: String {
        switch self {
        case .remove: "Remove link"
        case .create: "Create link"
        case .binding: "Update saved target"
        case .configuration: "Save Agent selection"
        case .noChange: "No change"
        }
    }

    var systemImage: String {
        switch self {
        case .remove: "minus.circle"
        case .create: "plus.circle"
        case .binding: "link"
        case .configuration: "checklist"
        case .noChange: "checkmark.circle"
        }
    }
}

extension SkillDistributionViewModel {
    static func problem(for error: Error) -> Problem {
        if error is SkillDistributionStateError {
            return .invalidPersistedBindings
        }
        if let error = error as? DistributionSymlinkExecutorError {
            switch error {
            case .blocked(let conflicts):
                if conflicts.contains(where: { $0.reason == .targetUnavailable }) {
                    return .targetUnavailable
                }
                return .failed("The distribution plan is blocked by a target conflict.")
            case .needsRepair:
                return .needsRepair
            case .operationInProgress:
                return .operationInProgress
            case .conflict:
                return .previewExpired
            }
        }
        if let error = error as? DistributionSymlinkFileSystemError {
            switch error {
            case .unavailable:
                return .targetUnavailable
            case .posix(_, let code) where code == EACCES || code == EPERM:
                return .permissionDenied
            default:
                return .failed(error.localizedDescription)
            }
        }
        if let error = error as? ManagedPathError,
           case .posix(_, let code) = error,
           code == EACCES || code == EPERM {
            return .permissionDenied
        }
        let nsError = error as NSError
        if nsError.domain == NSPOSIXErrorDomain,
           nsError.code == Int(EACCES) || nsError.code == Int(EPERM) {
            return .permissionDenied
        }
        return .failed(error.localizedDescription)
    }
}
