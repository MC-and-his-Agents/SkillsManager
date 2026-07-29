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

nonisolated extension ManagedSkillUpdateRemoteLocator {
    var updateDisplayName: String {
        switch self {
        case .clawdhub(let slug, let version):
            "Clawdhub \(slug) \(version.value)"
        case .github(let repositoryURL, let subpath, let revision, _):
            "\(repositoryURL.value)/\(subpath.value) @ \(revision.value.prefix(12))"
        }
    }
}
