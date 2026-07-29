import Foundation

nonisolated enum ManagedSkillUpdateCheckCodecError: Error, Equatable {
    case invalidPayload
}

nonisolated enum ManagedSkillUpdateCheckCodec {
    static let maximumByteCount = 65_536

    static func encode(_ snapshot: ManagedSkillUpdateCheckSnapshot) throws -> Data {
        let data = try encoder.encode(Wire(snapshot))
        guard 1...maximumByteCount ~= data.count else {
            throw ManagedSkillUpdateCheckCodecError.invalidPayload
        }
        return data
    }

    static func decode(_ data: Data) throws -> ManagedSkillUpdateCheckSnapshot {
        guard 1...maximumByteCount ~= data.count else {
            throw ManagedSkillUpdateCheckCodecError.invalidPayload
        }
        do {
            return try decoder.decode(Wire.self, from: data).snapshot()
        } catch {
            throw ManagedSkillUpdateCheckCodecError.invalidPayload
        }
    }

    private static var encoder: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return encoder
    }

    private static var decoder: JSONDecoder { JSONDecoder() }
}

private nonisolated struct Wire: Codable {
    let version: Int
    let skillID: Data
    let checkedAtMilliseconds: Int64
    let status: ManagedSkillUpdateCheckStatus
    let domainRevision: Int64
    let domainPayloadDigest: Data
    let storedFingerprint: FingerprintWire
    let liveSSOTIdentity: Data?
    let liveFingerprint: FingerprintWire?
    let candidate: CandidateWire?
    let copyStates: [CopyStateWire]
    let capabilityReason: String?

    init(_ snapshot: ManagedSkillUpdateCheckSnapshot) throws {
        version = 1
        skillID = snapshot.skillID.bytes
        checkedAtMilliseconds = snapshot.checkedAtMilliseconds
        status = snapshot.status
        domainRevision = snapshot.domainRevision
        domainPayloadDigest = snapshot.domainPayloadDigest
        storedFingerprint = FingerprintWire(snapshot.storedFingerprint)
        liveSSOTIdentity = try snapshot.liveSSOTIdentity.map(ManagedItemIdentityCodec.encode)
        liveFingerprint = snapshot.liveFingerprint.map(FingerprintWire.init)
        candidate = try snapshot.candidate.map(CandidateWire.init)
        copyStates = try snapshot.copyStates.map(CopyStateWire.init)
        capabilityReason = snapshot.capabilityReason
    }

    func snapshot() throws -> ManagedSkillUpdateCheckSnapshot {
        guard version == 1,
              checkedAtMilliseconds >= 0,
              domainRevision >= 0,
              domainPayloadDigest.count == 32,
              capabilityReason.map({ !$0.isEmpty && $0.utf8.count <= 512 }) ?? true else {
            throw ManagedSkillUpdateCheckCodecError.invalidPayload
        }
        let decodedCandidate = try candidate?.value()
        let decodedCopyStates = try copyStates.map { try $0.value() }
        guard Set(decodedCopyStates.map(\.scopeKey)).count == decodedCopyStates.count,
              (liveSSOTIdentity == nil) == (liveFingerprint == nil),
              (decodedCandidate == nil) == (capabilityReason != nil) else {
            throw ManagedSkillUpdateCheckCodecError.invalidPayload
        }
        switch status {
        case .upToDate, .remoteChanged:
            guard decodedCandidate != nil else {
                throw ManagedSkillUpdateCheckCodecError.invalidPayload
            }
        case .capabilityUnavailable:
            guard decodedCandidate == nil else {
                throw ManagedSkillUpdateCheckCodecError.invalidPayload
            }
        case .localModified, .copyDrift, .conflict:
            break
        }
        return ManagedSkillUpdateCheckSnapshot(
            skillID: try SkillID(bytes: skillID),
            checkedAtMilliseconds: checkedAtMilliseconds,
            status: status,
            domainRevision: domainRevision,
            domainPayloadDigest: domainPayloadDigest,
            storedFingerprint: try storedFingerprint.fingerprint(),
            liveSSOTIdentity: try liveSSOTIdentity.map(ManagedItemIdentityCodec.decode),
            liveFingerprint: try liveFingerprint?.fingerprint(),
            candidate: decodedCandidate,
            copyStates: decodedCopyStates,
            capabilityReason: capabilityReason
        )
    }
}

private nonisolated struct FingerprintWire: Codable {
    let algorithmVersion: Int
    let digest: Data

    init(_ fingerprint: SkillContentFingerprint) {
        algorithmVersion = fingerprint.algorithmVersion
        digest = fingerprint.digest
    }

    func fingerprint() throws -> SkillContentFingerprint {
        try SkillContentFingerprint(algorithmVersion: algorithmVersion, digest: digest)
    }
}

private nonisolated struct CandidateWire: Codable {
    enum Kind: String, Codable {
        case clawdhub
        case github
    }

    let kind: Kind
    let slug: String?
    let version: String?
    let repositoryURL: String?
    let subpath: String?
    let revision: String?
    let downloadURL: String?
    let fingerprint: FingerprintWire

    init(_ candidate: ManagedSkillUpdateCandidate) throws {
        fingerprint = FingerprintWire(candidate.contentFingerprint)
        switch candidate.locator {
        case .clawdhub(let slug, let version):
            kind = .clawdhub
            self.slug = slug
            self.version = version.value
            repositoryURL = nil
            subpath = nil
            revision = nil
            downloadURL = nil
        case .github(let repositoryURL, let subpath, let revision, let downloadURL):
            kind = .github
            slug = nil
            version = nil
            self.repositoryURL = repositoryURL.value
            self.subpath = subpath.value
            self.revision = revision.value
            self.downloadURL = downloadURL.value
        }
    }

    func value() throws -> ManagedSkillUpdateCandidate {
        let locator: ManagedSkillUpdateRemoteLocator
        switch kind {
        case .clawdhub:
            guard let slug, let version,
                  !slug.isEmpty, slug.utf8.count <= 512,
                  repositoryURL == nil, subpath == nil, revision == nil, downloadURL == nil else {
                throw ManagedSkillUpdateCheckCodecError.invalidPayload
            }
            locator = .clawdhub(slug: slug, version: try SourceVersion(version))
        case .github:
            guard slug == nil, version == nil,
                  let repositoryURL, let subpath, let revision, let downloadURL else {
                throw ManagedSkillUpdateCheckCodecError.invalidPayload
            }
            locator = .github(
                repositoryURL: try NormalizedRepositoryURL(repositoryURL),
                subpath: try RepositorySubpath(subpath),
                revision: try SourceRevision(revision),
                downloadURL: try PublicDownloadURL(downloadURL)
            )
        }
        return ManagedSkillUpdateCandidate(
            locator: locator,
            contentFingerprint: try fingerprint.fingerprint()
        )
    }
}

private nonisolated struct CopyStateWire: Codable {
    let scopeKey: String
    let state: String
    let baselineFingerprint: FingerprintWire?
    let observedFingerprint: FingerprintWire?
    let baselineTreeDigest: TreeDigestWire?
    let observedTreeDigest: TreeDigestWire?
    let baselineRootIdentity: Data?
    let observedRootIdentity: Data?
    let baselineEntryIdentity: Data?
    let observedEntryIdentity: Data?

    init(_ value: ManagedSkillUpdateCopyState) throws {
        scopeKey = value.scopeKey
        state = value.state.rawValue
        baselineFingerprint = value.baselineFingerprint.map(FingerprintWire.init)
        observedFingerprint = value.observedFingerprint.map(FingerprintWire.init)
        baselineTreeDigest = value.baselineTreeDigest.map(TreeDigestWire.init)
        observedTreeDigest = value.observedTreeDigest.map(TreeDigestWire.init)
        baselineRootIdentity = try value.baselineRootIdentity.map(ManagedItemIdentityCodec.encode)
        observedRootIdentity = try value.observedRootIdentity.map(ManagedItemIdentityCodec.encode)
        baselineEntryIdentity = try value.baselineEntryIdentity.map(ManagedItemIdentityCodec.encode)
        observedEntryIdentity = try value.observedEntryIdentity.map(ManagedItemIdentityCodec.encode)
    }

    func value() throws -> ManagedSkillUpdateCopyState {
        guard !scopeKey.isEmpty, scopeKey.utf8.count <= 512,
              let state = DistributionCopyObservationState(rawValue: state) else {
            throw ManagedSkillUpdateCheckCodecError.invalidPayload
        }
        return ManagedSkillUpdateCopyState(
            scopeKey: scopeKey,
            state: state,
            baselineFingerprint: try baselineFingerprint?.fingerprint(),
            observedFingerprint: try observedFingerprint?.fingerprint(),
            baselineTreeDigest: try baselineTreeDigest?.value(),
            observedTreeDigest: try observedTreeDigest?.value(),
            baselineRootIdentity: try baselineRootIdentity.map(ManagedItemIdentityCodec.decode),
            observedRootIdentity: try observedRootIdentity.map(ManagedItemIdentityCodec.decode),
            baselineEntryIdentity: try baselineEntryIdentity.map(ManagedItemIdentityCodec.decode),
            observedEntryIdentity: try observedEntryIdentity.map(ManagedItemIdentityCodec.decode)
        )
    }
}

private nonisolated struct TreeDigestWire: Codable {
    let algorithmVersion: Int
    let digest: Data

    init(_ value: CopyPhysicalTreeDigest) {
        algorithmVersion = value.algorithmVersion
        digest = value.digest
    }

    func value() throws -> CopyPhysicalTreeDigest {
        try CopyPhysicalTreeDigest(algorithmVersion: algorithmVersion, digest: digest)
    }
}
