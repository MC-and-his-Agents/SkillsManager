import Darwin
import SwiftUI

nonisolated enum SkillDistributionStateError: Error {
    case invalidPersistedBindings
}

extension SkillDistributionViewModel {
    enum LoadState: Equatable {
        case blocked(String)
        case empty
        case loading
        case ready(Status)
        case failed(Problem)
    }

    enum Status: Equatable {
        case notConfigured
        case inSync
        case drifted
        case needsRepair
        case operationInProgress
    }

    enum Problem: Equatable {
        case invalidPersistedBindings
        case previewExpired
        case permissionDenied
        case targetUnavailable
        case needsRepair
        case operationInProgress
        case operationDidNotComplete
        case forkCreatedButNotLocated
        case failed(String)

        var message: String {
            switch self {
            case .invalidPersistedBindings:
                String(localized: "The saved distribution state is invalid and cannot be edited safely.", bundle: .module)
            case .previewExpired:
                String(localized: "The preview expired because the distribution state changed. Review the refreshed state.", bundle: .module)
            case .permissionDenied:
                String(localized: "Skills Manager does not have permission to access a distribution target.", bundle: .module)
            case .targetUnavailable:
                String(localized: "A required distribution target is unavailable.", bundle: .module)
            case .needsRepair:
                String(localized: "This Skill has an incomplete distribution operation that needs repair.", bundle: .module)
            case .operationInProgress:
                String(localized: "A distribution operation is already in progress for this Skill.", bundle: .module)
            case .operationDidNotComplete:
                String(localized: "The distribution operation did not reach a successful terminal state.", bundle: .module)
            case .forkCreatedButNotLocated:
                String(localized: "The Fork was created, but it could not be selected in the refreshed library.", bundle: .module)
            case .failed(let message):
                message
            }
        }
    }

    struct TargetRow: Identifiable, Equatable, Sendable {
        let scopeKey: String
        let locator: String
        let syncMode: DistributionSyncMode

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

    struct ForkLineageRow: Equatable, Sendable {
        let parentSkillID: SkillID
        let parentDisplayName: String?
        let createdAtMilliseconds: Int64
        let forkedFromFingerprint: SkillContentFingerprint

        init(_ readback: SkillForkLineageReadback) {
            parentSkillID = readback.parentSkillID
            parentDisplayName = readback.parentDisplayName
            createdAtMilliseconds = readback.createdAtMilliseconds
            forkedFromFingerprint = readback.forkedFromFingerprint
        }

        var parentLabel: String {
            parentDisplayName ?? parentSkillID.directoryName
        }

        var fingerprintLabel: String {
            forkedFromFingerprint.shortDisplayName
        }
    }

    struct PreviewRow: Identifiable, Equatable, Sendable {
        enum Kind: String, Sendable {
            case remove
            case create
            case refresh
            case replace
            case binding
            case configuration
            case noChange
        }

        let kind: Kind
        let scopeKey: String
        let locator: String

        var id: String { "\(kind.rawValue)\u{0}\(scopeKey)\u{0}\(locator)" }
    }

    struct DriftDecision: Identifiable, Equatable, Sendable {
        let scopeKey: String
        let locator: String
        let preview: CopyDriftDecisionPreview

        var id: String {
            "\(scopeKey)\u{0}\(preview.binding.distributionSlug.collisionKey)"
        }
    }

    struct PendingPreview: Identifiable, Sendable {
        let id = UUID()
        let generation: UInt64
        let skillID: SkillID
        let desiredConfiguration: DistributionDesiredConfiguration
        let requiredAdapterCodes: Set<String>
        let plan: DistributionPlan
        let canonicalPlan: Data
        let rows: [PreviewRow]
        let driftDecisions: [DriftDecision]
    }
}

@MainActor extension SkillDistributionViewModel.Status {
    var displayName: String {
        switch self {
        case .notConfigured: String(localized: "Not configured", bundle: .module)
        case .inSync: String(localized: "In sync", bundle: .module)
        case .drifted: String(localized: "Needs update", bundle: .module)
        case .needsRepair: String(localized: "Needs repair", bundle: .module)
        case .operationInProgress: String(localized: "Operation in progress", bundle: .module)
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

@MainActor extension SkillDistributionViewModel.PreviewRow.Kind {
    var displayName: String {
        switch self {
        case .remove: String(localized: "Remove target", bundle: .module)
        case .create: String(localized: "Create target", bundle: .module)
        case .refresh: String(localized: "Refresh Copy", bundle: .module)
        case .replace: String(localized: "Change distribution mode", bundle: .module)
        case .binding: String(localized: "Update saved target", bundle: .module)
        case .configuration: String(localized: "Save Agent selection", bundle: .module)
        case .noChange: String(localized: "No change", bundle: .module)
        }
    }

    var systemImage: String {
        switch self {
        case .remove: "minus.circle"
        case .create: "plus.circle"
        case .refresh: "arrow.clockwise.circle"
        case .replace: "arrow.triangle.swap"
        case .binding: "link"
        case .configuration: "checklist"
        case .noChange: "checkmark.circle"
        }
    }
}

@MainActor extension DistributionSyncMode {
    var displayName: String {
        switch self {
        case .symlink: String(localized: "Symlink", bundle: .module)
        case .copy: String(localized: "Copy", bundle: .module)
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
                return .failed(String(localized: "The distribution plan is blocked by a target conflict.", bundle: .module))
            case .needsRepair:
                return .needsRepair
            case .operationInProgress:
                return .operationInProgress
            case .conflict:
                return .previewExpired
            }
        }
        if let error = error as? CopyForkError {
            switch error {
            case .previewExpired, .bindingConflict:
                return .previewExpired
            case .permissionDenied:
                return .permissionDenied
            case .targetUnavailable:
                return .targetUnavailable
            case .operationInProgress:
                return .operationInProgress
            case .needsRepair:
                return .needsRepair
            case .notCopy:
                return .failed(String(localized: "The selected target is not a managed Copy.", bundle: .module))
            case .notContentOnlyDrift:
                return .failed(String(localized: "Only content-only Copy changes can use this decision.", bundle: .module))
            case .unsafeContent:
                return .failed(String(localized: "The Copy contains unsupported or unsafe content.", bundle: .module))
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
