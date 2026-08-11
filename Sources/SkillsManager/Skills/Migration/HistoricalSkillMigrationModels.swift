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
    let ssotAbsoluteTarget: String
    let ssotIdentity: ManagedItemIdentity?
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
    let localOriginCleanup: LocalSkillOriginRecord?

    init(
        source: DistributionCopyEvidence,
        backup: SkillBackupRecord,
        metadata: SkillBackupMigrationMetadata,
        localOriginCleanup: LocalSkillOriginRecord? = nil
    ) {
        self.source = source
        self.backup = backup
        self.metadata = metadata
        self.localOriginCleanup = localOriginCleanup
    }
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
    let ssotEvidence: DistributionCopySourceEvidence
    let backupID: SkillBackupID
    let operationID: SSOTOperationID
    let createdAtMilliseconds: Int64
}

nonisolated enum HistoricalSkillMigrationSSOTExpectation: Sendable {
    case absent(absoluteTarget: String)
    case existing(DistributionCopySourceEvidence)

    var absoluteTarget: String {
        switch self {
        case .absent(let value): value
        case .existing(let evidence): evidence.absoluteTarget
        }
    }

    var identity: ManagedItemIdentity? {
        if case .existing(let evidence) = self {
            return evidence.ssotIdentity
        }
        return nil
    }
}

nonisolated struct HistoricalSkillMigrationExistingBackup: Sendable {
    let backup: SkillBackupRecord
    let metadata: SkillBackupMigrationMetadata
    let operationID: SSOTOperationID
}
