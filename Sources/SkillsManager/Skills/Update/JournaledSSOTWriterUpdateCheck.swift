import CryptoKit
import Foundation

extension JournaledSSOTWriter {
    func beginUpdateCheck(
        skillID: SkillID,
        token: ManagedSkillUpdateCheckToken
    ) throws -> ManagedSkillUpdateCheckReadback {
        try requireAuthority()
        updateCheckTokens[skillID] = token
        return try updateCheckReadback(skillID: skillID)
    }

    func loadUpdateCheck(_ skillID: SkillID) throws -> ManagedSkillUpdateCheckSnapshot? {
        try requireAuthority()
        guard let record = try UpdateCheckStore(connection: connection).load(skillID: skillID) else {
            return nil
        }
        let snapshot = try ManagedSkillUpdateCheckCodec.decode(record.payload)
        guard snapshot.skillID == record.skillID,
              snapshot.status == record.status,
              snapshot.checkedAtMilliseconds == record.checkedAtMilliseconds else {
            throw UpdateCheckStoreError.corruptRecord
        }
        return snapshot
    }

    func updateCheckReadback(skillID: SkillID) throws -> ManagedSkillUpdateCheckReadback {
        try requireAuthority()
        guard let domain = try journal.storedDomain(skillID) else {
            throw ManagedLocalCatalogError.skillUnavailable
        }
        let live = try fileSystem.captureCurrentFinal(skillID: skillID)
        let selection = try loadDistributionSelection(skillID: skillID)
        let reconcile = try reconcileDistribution(skillID: skillID)
        let payload = try SSOTWritePayloadCodec.encode(domain.payload)
        let copyStates: [ManagedSkillUpdateCopyState] = reconcile.observations.compactMap {
            element in
            let (entry, observation) = element
            guard case .copy(let copy) = observation else { return nil }
            return ManagedSkillUpdateCopyState(
                scopeKey: entry.target.scope.targetScopeKey,
                state: copy.state,
                baselineFingerprint: copy.evidence.baselineContentFingerprint,
                observedFingerprint: copy.evidence.observedContentFingerprint,
                baselineTreeDigest: copy.evidence.baselinePhysicalTreeDigest,
                observedTreeDigest: copy.evidence.observedPhysicalTreeDigest,
                baselineRootIdentity: copy.evidence.baselineRootIdentity,
                observedRootIdentity: copy.evidence.observedRootIdentity,
                baselineEntryIdentity: copy.evidence.baselineEntryIdentity,
                observedEntryIdentity: copy.evidence.observedEntryIdentity
            )
        }.sorted { $0.scopeKey.utf8.lexicographicallyPrecedes($1.scopeKey.utf8) }
        return ManagedSkillUpdateCheckReadback(
            skillID: skillID,
            domain: domain,
            canonicalData: try ManagedSkillUpdateReadbackCodec.encode(
                skillID: skillID,
                domainRevision: domain.revision,
                payload: payload,
                liveIdentity: live?.identity,
                liveFingerprint: try live.map {
                    try SkillContentFingerprint(currentDigest: $0.snapshot.fingerprintDigest)
                },
                selection: DistributionRepairSelectionToken.encode(
                    selection,
                    skillID: skillID
                ),
                reconcile: reconcile
            ),
            liveSSOTIdentity: live?.identity,
            liveFingerprint: try live.map {
                try SkillContentFingerprint(currentDigest: $0.snapshot.fingerprintDigest)
            },
            distributionStatus: reconcile.status,
            copyStates: copyStates
        )
    }

    func commitUpdateCheck(
        skillID: SkillID,
        token: ManagedSkillUpdateCheckToken,
        expectedCanonicalReadback: Data,
        stableSnapshot: ManagedSkillUpdateCheckSnapshot
    ) throws {
        try Task.checkCancellation()
        try requireAuthority()
        guard updateCheckTokens[skillID] == token else {
            throw ManagedSkillUpdateCheckProblem.stale
        }
        let current = try updateCheckReadback(skillID: skillID)
        guard current.canonicalData == expectedCanonicalReadback,
              stableSnapshot.skillID == skillID,
              stableSnapshot.domainRevision == current.domain.revision,
              stableSnapshot.domainPayloadDigest
                == Data(SHA256.hash(data: try SSOTWritePayloadCodec.encode(
                    current.domain.payload
                ))),
              stableSnapshot.storedFingerprint == current.domain.payload.skill.contentFingerprint,
              stableSnapshot.liveSSOTIdentity == current.liveSSOTIdentity,
              stableSnapshot.liveFingerprint == current.liveFingerprint,
              stableSnapshot.copyStates == current.copyStates,
              candidateMatchesDomain(
                stableSnapshot.candidate,
                payload: current.domain.payload
              ),
              stableSnapshot.status == ManagedSkillUpdateCheckStatus.classify(
                readback: current,
                candidate: stableSnapshot.candidate
              ),
              (stableSnapshot.candidate == nil) == (stableSnapshot.capabilityReason != nil) else {
            throw ManagedSkillUpdateCheckProblem.stale
        }
        let payload = try ManagedSkillUpdateCheckCodec.encode(stableSnapshot)
        let record = try StoredSkillUpdateCheck(
            skillID: skillID,
            status: stableSnapshot.status,
            checkedAtMilliseconds: stableSnapshot.checkedAtMilliseconds,
            payload: payload
        )
        try UpdateCheckStore(connection: connection).upsert(record)
    }

    private func candidateMatchesDomain(
        _ candidate: ManagedSkillUpdateCandidate?,
        payload: SSOTSkillWritePayload
    ) -> Bool {
        guard let candidate else { return true }
        switch candidate.locator {
        case .github(let repositoryURL, let subpath, _, _):
            return payload.source?.repositoryURL == repositoryURL
                && payload.source?.subpath == subpath
        case .clawdhub(let slug, _):
            guard payload.source == nil else { return false }
            let matches = payload.providerProvenance.filter {
                $0.identity.provider == "clawdhub"
                    && $0.identity.identifier == slug
            }
            return matches.count == 1
        }
    }
}

private nonisolated enum ManagedSkillUpdateReadbackCodec {
    static func encode(
        skillID: SkillID,
        domainRevision: Int64,
        payload: Data,
        liveIdentity: ManagedItemIdentity?,
        liveFingerprint: SkillContentFingerprint?,
        selection: Data,
        reconcile: DistributionReconcileResult
    ) throws -> Data {
        let observations = try reconcile.observations.map { entry, observation in
            try Observation(entry: entry, observation: observation)
        }.sorted {
            $0.locator.utf8.lexicographicallyPrecedes($1.locator.utf8)
        }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return try encoder.encode(Wire(
            version: 1,
            skillID: skillID.bytes,
            domainRevision: domainRevision,
            payload: payload,
            liveIdentity: try liveIdentity.map(ManagedItemIdentityCodec.encode),
            liveFingerprint: liveFingerprint.map(Fingerprint.init),
            selection: selection,
            reconcileStatus: reconcile.status.rawValue,
            observations: observations
        ))
    }

    private struct Wire: Encodable {
        let version: Int
        let skillID: Data
        let domainRevision: Int64
        let payload: Data
        let liveIdentity: Data?
        let liveFingerprint: Fingerprint?
        let selection: Data
        let reconcileStatus: String
        let observations: [Observation]
    }

    private struct Fingerprint: Encodable {
        let algorithmVersion: Int
        let digest: Data

        init(_ value: SkillContentFingerprint) {
            algorithmVersion = value.algorithmVersion
            digest = value.digest
        }
    }

    private struct Observation: Encodable {
        let locator: String
        let kind: String
        let copyState: String?
        let copyEvidence: [Data?]?

        init(
            entry: DistributionTargetEntry,
            observation: DistributionTargetObservation
        ) throws {
            locator = entry.canonicalLocator
            switch observation {
            case .missing:
                kind = "missing"
                copyState = nil
                copyEvidence = nil
            case .managed(let skillID, let directory):
                kind = "managed:\(skillID.directoryName):\(directory)"
                copyState = nil
                copyEvidence = nil
            case .copy(let copy):
                kind = "copy"
                copyState = copy.state.rawValue
                copyEvidence = try [
                    copy.evidence.baselineContentFingerprint?.digest,
                    copy.evidence.observedContentFingerprint?.digest,
                    copy.evidence.baselinePhysicalTreeDigest?.digest,
                    copy.evidence.observedPhysicalTreeDigest?.digest,
                    copy.evidence.baselineRootIdentity.map(ManagedItemIdentityCodec.encode),
                    copy.evidence.observedRootIdentity.map(ManagedItemIdentityCodec.encode),
                    copy.evidence.baselineEntryIdentity.map(ManagedItemIdentityCodec.encode),
                    copy.evidence.observedEntryIdentity.map(ManagedItemIdentityCodec.encode),
                ]
            case .unknownObject:
                kind = "unknown"
                copyState = nil
                copyEvidence = nil
            case .unavailable:
                kind = "unavailable"
                copyState = nil
                copyEvidence = nil
            }
        }
    }
}
