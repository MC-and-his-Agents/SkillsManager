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
                String(localized: "The saved distribution state is invalid and cannot be edited safely.", bundle: SkillsManagerLocalizationResources.bundle)
            case .previewExpired:
                String(localized: "The preview expired because the distribution state changed. Review the refreshed state.", bundle: SkillsManagerLocalizationResources.bundle)
            case .permissionDenied:
                String(localized: "Skills Manager does not have permission to access a distribution target.", bundle: SkillsManagerLocalizationResources.bundle)
            case .targetUnavailable:
                String(localized: "A required distribution target is unavailable.", bundle: SkillsManagerLocalizationResources.bundle)
            case .needsRepair:
                String(localized: "This Skill has an incomplete distribution operation that needs repair.", bundle: SkillsManagerLocalizationResources.bundle)
            case .operationInProgress:
                String(localized: "A distribution operation is already in progress for this Skill.", bundle: SkillsManagerLocalizationResources.bundle)
            case .operationDidNotComplete:
                String(localized: "The distribution operation did not reach a successful terminal state.", bundle: SkillsManagerLocalizationResources.bundle)
            case .forkCreatedButNotLocated:
                String(localized: "The Fork was created, but it could not be selected in the refreshed library.", bundle: SkillsManagerLocalizationResources.bundle)
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
        case .notConfigured: String(localized: "Not configured", bundle: SkillsManagerLocalizationResources.bundle)
        case .inSync: String(localized: "In sync", bundle: SkillsManagerLocalizationResources.bundle)
        case .drifted: String(localized: "Needs update", bundle: SkillsManagerLocalizationResources.bundle)
        case .needsRepair: String(localized: "Needs repair", bundle: SkillsManagerLocalizationResources.bundle)
        case .operationInProgress: String(localized: "Operation in progress", bundle: SkillsManagerLocalizationResources.bundle)
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
        case .remove: String(localized: "Remove target", bundle: SkillsManagerLocalizationResources.bundle)
        case .create: String(localized: "Create target", bundle: SkillsManagerLocalizationResources.bundle)
        case .refresh: String(localized: "Refresh Copy", bundle: SkillsManagerLocalizationResources.bundle)
        case .replace: String(localized: "Change distribution mode", bundle: SkillsManagerLocalizationResources.bundle)
        case .binding: String(localized: "Update saved target", bundle: SkillsManagerLocalizationResources.bundle)
        case .configuration: String(localized: "Save Agent selection", bundle: SkillsManagerLocalizationResources.bundle)
        case .noChange: String(localized: "No change", bundle: SkillsManagerLocalizationResources.bundle)
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
        case .symlink: String(localized: "Symlink", bundle: SkillsManagerLocalizationResources.bundle)
        case .copy: String(localized: "Copy", bundle: SkillsManagerLocalizationResources.bundle)
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
                return .failed(String(localized: "The distribution plan is blocked by a target conflict.", bundle: SkillsManagerLocalizationResources.bundle))
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
                return .failed(String(localized: "The selected target is not a managed Copy.", bundle: SkillsManagerLocalizationResources.bundle))
            case .notContentOnlyDrift:
                return .failed(String(localized: "Only content-only Copy changes can use this decision.", bundle: SkillsManagerLocalizationResources.bundle))
            case .unsafeContent:
                return .failed(String(localized: "The Copy contains unsupported or unsafe content.", bundle: SkillsManagerLocalizationResources.bundle))
            }
        }
        if let error = error as? DistributionSymlinkFileSystemError {
            switch error {
            case .invalidTarget:
                return .failed(String(localized: "The distribution target is not an approved user Skill directory.", bundle: SkillsManagerLocalizationResources.bundle))
            case .unavailable:
                return .targetUnavailable
            case .entryChanged:
                return .failed(String(localized: "The distribution entry changed while it was being verified.", bundle: SkillsManagerLocalizationResources.bundle))
            case .equivalentSibling:
                return .failed(String(localized: "An equivalent Skill name already exists in the target directory.", bundle: SkillsManagerLocalizationResources.bundle))
            case .temporaryEntryExists:
                return .failed(String(localized: "The operation temporary entry already exists.", bundle: SkillsManagerLocalizationResources.bundle))
            case .posix(_, let code) where code == EACCES || code == EPERM:
                return .permissionDenied
            case .posix:
                return .failed(error.localizedDescription)
            }
        }
        if let error = error as? ManagedPathError {
            switch error {
            case .rootReplaced:
                return .failed(String(localized: "The managed root was replaced after it was registered.", bundle: SkillsManagerLocalizationResources.bundle))
            case .targetIsRoot:
                return .failed(String(localized: "The managed root itself cannot be used as an item target.", bundle: SkillsManagerLocalizationResources.bundle))
            case .targetIsNotDirectChild:
                return .failed(String(localized: "The target must be a direct child of the managed root.", bundle: SkillsManagerLocalizationResources.bundle))
            case .itemNotFound:
                return .failed(String(localized: "The managed item does not exist.", bundle: SkillsManagerLocalizationResources.bundle))
            case .itemChanged:
                return .failed(String(localized: "The managed item changed during the operation.", bundle: SkillsManagerLocalizationResources.bundle))
            case .destinationAlreadyExists:
                return .failed(String(localized: "The destination already exists.", bundle: SkillsManagerLocalizationResources.bundle))
            case .unsupportedItemType:
                return .failed(String(localized: "The managed item has an unsupported file type.", bundle: SkillsManagerLocalizationResources.bundle))
            case .invalidRoot, .cleanupFailed, .removalFailed:
                return .failed(error.localizedDescription)
            case .posix(_, let code) where code == EACCES || code == EPERM:
                return .permissionDenied
            case .posix:
                return .failed(error.localizedDescription)
            }
        }
        let nsError = error as NSError
        if nsError.domain == NSPOSIXErrorDomain,
           nsError.code == Int(EACCES) || nsError.code == Int(EPERM) {
            return .permissionDenied
        }
        return .failed(error.localizedDescription)
    }
}
