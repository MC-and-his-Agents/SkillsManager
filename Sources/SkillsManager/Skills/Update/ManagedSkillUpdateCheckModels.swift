import Foundation

nonisolated enum ManagedSkillUpdateCheckStatus: String, Codable, Sendable {
    case upToDate
    case remoteChanged
    case localModified
    case copyDrift
    case capabilityUnavailable
    case conflict
}

nonisolated extension ManagedSkillUpdateCheckStatus {
    static func classify(
        readback: ManagedSkillUpdateCheckReadback,
        candidate: ManagedSkillUpdateCandidate?
    ) -> Self {
        guard readback.domain.payload.skill.status == .managed,
              readback.liveSSOTIdentity != nil,
              readback.liveFingerprint != nil,
              readback.distributionStatus != .needsRepair,
              readback.distributionStatus != .operationInProgress else {
            return .conflict
        }
        if readback.liveFingerprint != readback.domain.payload.skill.contentFingerprint {
            return .localModified
        }
        if readback.copyStates.contains(where: \.isTargetDrift) {
            return .copyDrift
        }
        if readback.distributionStatus == .drifted,
           !readback.distributionHasOnlyCopySourceDrift {
            return .conflict
        }
        guard let candidate else { return .capabilityUnavailable }
        return candidate.contentFingerprint == readback.liveFingerprint
            ? .upToDate
            : .remoteChanged
    }
}

nonisolated enum ManagedSkillUpdateRemoteLocator: Equatable, Sendable {
    case clawdhub(slug: String, version: SourceVersion)
    case github(
        repositoryURL: NormalizedRepositoryURL,
        subpath: RepositorySubpath,
        revision: SourceRevision,
        downloadURL: PublicDownloadURL
    )
}

nonisolated struct ManagedSkillUpdateCandidate: Equatable, Sendable {
    let locator: ManagedSkillUpdateRemoteLocator
    let contentFingerprint: SkillContentFingerprint
}

nonisolated struct ManagedSkillPreparedCandidate: Sendable {
    let candidate: ManagedSkillUpdateCandidate
    let payload: SkillImportWorker.ImportCandidatePayload
}

nonisolated struct ManagedSkillUpdateCopyState: Equatable, Sendable {
    let scopeKey: String
    let state: DistributionCopyObservationState
    let baselineFingerprint: SkillContentFingerprint?
    let observedFingerprint: SkillContentFingerprint?
    let baselineTreeDigest: CopyPhysicalTreeDigest?
    let observedTreeDigest: CopyPhysicalTreeDigest?
    let baselineRootIdentity: ManagedItemIdentity?
    let observedRootIdentity: ManagedItemIdentity?
    let baselineEntryIdentity: ManagedItemIdentity?
    let observedEntryIdentity: ManagedItemIdentity?

    var isTargetDrift: Bool {
        switch state {
        case .inSync, .sourceChanged:
            false
        case .contentDrift, .physicalDrift, .rootReplaced, .targetReplaced,
             .targetMissing, .baselineInvalid:
            true
        }
    }

    var sourceChanged: Bool { state == .sourceChanged }
}

nonisolated struct ManagedSkillUpdateCheckReadback: Sendable {
    let skillID: SkillID
    let domain: StoredSkillDomainSnapshot
    let canonicalData: Data
    let liveSSOTIdentity: ManagedItemIdentity?
    let liveFingerprint: SkillContentFingerprint?
    let distributionStatus: DistributionReconcileStatus
    let distributionHasOnlyCopySourceDrift: Bool
    let copyStates: [ManagedSkillUpdateCopyState]
}

nonisolated struct ManagedSkillUpdateCheckSnapshot: Equatable, Sendable {
    let skillID: SkillID
    let checkedAtMilliseconds: Int64
    let status: ManagedSkillUpdateCheckStatus
    let domainRevision: Int64
    let domainPayloadDigest: Data
    let storedFingerprint: SkillContentFingerprint
    let liveSSOTIdentity: ManagedItemIdentity?
    let liveFingerprint: SkillContentFingerprint?
    let candidate: ManagedSkillUpdateCandidate?
    let copyStates: [ManagedSkillUpdateCopyState]
    let capabilityReason: String?

    var sourceChangedScopeKeys: [String] {
        copyStates.filter(\.sourceChanged).map(\.scopeKey)
    }

    var hasExecutableRemoteUpdate: Bool {
        guard let candidate else { return false }
        return candidate.contentFingerprint != storedFingerprint
            && (status == .remoteChanged || status == .copyDrift)
    }
}

nonisolated enum ManagedSkillUpdateCheckProblem: LocalizedError, Equatable, Sendable {
    case unavailable
    case stale
    case cancelled
    case timeout
    case offline
    case rateLimited
    case providerUnavailable
    case unsafeContent
    case databaseUnavailable
    case failed

    var errorDescription: String? {
        switch self {
        case .unavailable:
            "Update checking is unavailable for this Skill."
        case .stale:
            "The Skill changed while it was being checked. Try again."
        case .cancelled:
            "The update check was cancelled."
        case .timeout:
            "The remote source timed out."
        case .offline:
            "The network is offline."
        case .rateLimited:
            "The remote source is rate limited. Try again later."
        case .providerUnavailable:
            "The remote source is temporarily unavailable."
        case .unsafeContent:
            "The remote Skill contents were rejected as unsafe or invalid."
        case .databaseUnavailable:
            "The last update check could not be saved."
        case .failed:
            "The update check failed."
        }
    }
}

nonisolated struct ManagedSkillUpdateCheckToken: Hashable, Sendable {
    let uuid: UUID

    init(_ uuid: UUID = UUID()) {
        self.uuid = uuid
    }
}
