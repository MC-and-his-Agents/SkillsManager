import Foundation

nonisolated struct ManagedSkillUpdateExecutionToken: Hashable, Sendable {
    let uuid: UUID

    init(_ uuid: UUID = UUID()) {
        self.uuid = uuid
    }
}

nonisolated enum ManagedSkillUpdateCopyDecision: String, CaseIterable, Sendable {
    case discard
    case fork
    case cancel
}

nonisolated struct ManagedSkillUpdateCopyChoice: Identifiable, Sendable {
    let scopeKey: String
    let targetDescription: String

    var id: String { scopeKey }
}

nonisolated struct ManagedSkillUpdateExecutionPreview: Identifiable, Sendable {
    let token: ManagedSkillUpdateExecutionToken
    let skillID: SkillID
    let displayName: String
    let currentSourceDescription: String
    let candidateSourceDescription: String
    let distributionDescription: String
    let currentFingerprint: SkillContentFingerprint
    let candidate: ManagedSkillUpdateCandidate
    let copyChoices: [ManagedSkillUpdateCopyChoice]

    var id: ManagedSkillUpdateExecutionToken { token }
}

nonisolated struct ManagedSkillUpdateDecisionSelection: Sendable {
    let scopeKey: String
    let decision: ManagedSkillUpdateCopyDecision
}

nonisolated enum ManagedSkillUpdateExecutionStatus: Equatable, Sendable {
    case cancelled
    case noChange
    case backupReadyUpdateNotStarted
    case copyDecisionsAppliedUpdateNotCompleted
    case updated
    case updatedNeedsAttention
    case updateRolledBack
    case updateIndeterminate
    case needsRepair
}

nonisolated struct ManagedSkillUpdateExecutionResult: Equatable, Sendable {
    let skillID: SkillID
    let status: ManagedSkillUpdateExecutionStatus
    let backupID: SkillBackupID?
}

nonisolated enum ManagedSkillUpdateExecutionProblem: LocalizedError, Equatable, Sendable {
    case unavailable
    case noUpdate
    case stale
    case invalidDecisions
    case unsafeCopyState
    case operationInProgress
    case permissionDenied
    case providerUnavailable
    case needsRepair
    case failed

    var errorDescription: String? {
        switch self {
        case .unavailable:
            "Updating is unavailable for this Skill."
        case .noUpdate:
            "The remote Skill no longer contains an update."
        case .stale:
            "The Skill or remote source changed. Check for updates again."
        case .invalidDecisions:
            "Choose how to handle every modified Copy before updating."
        case .unsafeCopyState:
            "A Copy target changed in a way that cannot be updated safely."
        case .operationInProgress:
            "This Skill is already being prepared or updated."
        case .permissionDenied:
            "Skills Manager does not have permission to complete this update."
        case .providerUnavailable:
            "The remote source is temporarily unavailable."
        case .needsRepair:
            "The managed Skill requires repair before it can be updated."
        case .failed:
            "The Skill could not be updated."
        }
    }
}

@MainActor
func localizedManagedSkillUpdateExecutionProblem(
    _ problem: ManagedSkillUpdateExecutionProblem
) -> String {
    switch problem {
    case .unavailable: String(localized: "Updating is unavailable for this Skill.", bundle: SkillsManagerLocalizationResources.bundle)
    case .noUpdate: String(localized: "The remote Skill no longer contains an update.", bundle: SkillsManagerLocalizationResources.bundle)
    case .stale: String(localized: "The Skill or remote source changed. Check for updates again.", bundle: SkillsManagerLocalizationResources.bundle)
    case .invalidDecisions: String(localized: "Choose how to handle every modified Copy before updating.", bundle: SkillsManagerLocalizationResources.bundle)
    case .unsafeCopyState: String(localized: "A Copy target changed in a way that cannot be updated safely.", bundle: SkillsManagerLocalizationResources.bundle)
    case .operationInProgress: String(localized: "This Skill is already being prepared or updated.", bundle: SkillsManagerLocalizationResources.bundle)
    case .permissionDenied: String(localized: "Skills Manager does not have permission to complete this update.", bundle: SkillsManagerLocalizationResources.bundle)
    case .providerUnavailable: String(localized: "The remote source is temporarily unavailable.", bundle: SkillsManagerLocalizationResources.bundle)
    case .needsRepair: String(localized: "The managed Skill requires repair before it can be updated.", bundle: SkillsManagerLocalizationResources.bundle)
    case .failed: String(localized: "The Skill could not be updated.", bundle: SkillsManagerLocalizationResources.bundle)
    }
}

nonisolated extension ManagedSkillUpdateRemoteLocator {
    var updateDisplayName: String {
        switch self {
        case .clawdhub(let slug, let version):
            "ClawHub \(slug) \(version.value)"
        case .github(let repositoryURL, let subpath, let revision, _):
            "\(repositoryURL.value)/\(subpath.value) @ \(revision.value.prefix(12))"
        }
    }
}

nonisolated extension ManagedSkillUpdateExecutionStatus {
    var displayName: String {
        switch self {
        case .cancelled: "Update cancelled"
        case .noChange: "Already up to date"
        case .backupReadyUpdateNotStarted:
            "Backup completed; recheck before trying the update again"
        case .copyDecisionsAppliedUpdateNotCompleted:
            "Copy decisions were saved; recheck before updating the parent Skill"
        case .updated: "Skill updated"
        case .updatedNeedsAttention: "Skill updated; distribution needs attention"
        case .updateRolledBack: "Update rolled back"
        case .updateIndeterminate: "Update state could not be confirmed"
        case .needsRepair: "Managed Skill needs repair"
        }
    }

    var requiresAttention: Bool {
        switch self {
        case .updated, .noChange, .cancelled: false
        default: true
        }
    }

    var systemImage: String {
        requiresAttention ? "exclamationmark.triangle" : "checkmark.circle"
    }
}
