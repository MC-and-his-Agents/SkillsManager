import Foundation

nonisolated enum HistoricalSkillMigrationError: Error, Equatable, Sendable {
    case stalePreview
    case invalidSelection
    case permissionDenied
    case sourceChanged
    case targetOccupied
    case operationInProgress
    case needsRepair
    case backupUnavailable
    case unsupportedCandidate
    case unavailable
}

nonisolated struct HistoricalSkillMigrationToken: Hashable, Sendable {
    let uuid: UUID

    init(_ uuid: UUID = UUID()) {
        self.uuid = uuid
    }
}

nonisolated struct HistoricalSkillMigrationPreview: Sendable {
    let token: HistoricalSkillMigrationToken
    let skillID: SkillID
    let sourceScope: DistributionBindingScope
    let sourceLocator: String
    let targetLocator: String
    let backupID: SkillBackupID
    let operationID: SSOTOperationID
    let canonicalAudit: Data
    let canonicalPlan: Data
}

nonisolated struct HistoricalSkillMigrationResult: Sendable {
    let skill: ManagedSkillRecord
    let backup: SkillBackupRecord
    let distribution: DistributionOperationRecord
}

nonisolated struct DistributionHistoricalMigrationApproval: Sendable {
    let source: DistributionCopyEvidence
    let backup: SkillBackupRecord
    let metadata: SkillBackupMigrationMetadata
}

nonisolated struct HistoricalSkillMigrationSource: Sendable {
    let discoveryScope: SkillDiscoveryScope
    let scope: DistributionBindingScope
    let rawLocator: String
    let normalizedLocator: String
    let rootIdentity: ManagedItemIdentity
    let candidateIdentity: ManagedItemIdentity
    let fingerprint: SkillContentFingerprint
}

nonisolated struct HistoricalSkillMigrationRequest: Sendable {
    let skillID: SkillID
    let source: HistoricalSkillMigrationSource
    let plan: DistributionPlan
    let canonicalPlan: Data
    let backupID: SkillBackupID
    let operationID: SSOTOperationID
    let createdAtMilliseconds: Int64
}

nonisolated struct HistoricalSkillMigrationExistingBackup: Sendable {
    let backup: SkillBackupRecord
    let metadata: SkillBackupMigrationMetadata
    let operationID: SSOTOperationID
}
