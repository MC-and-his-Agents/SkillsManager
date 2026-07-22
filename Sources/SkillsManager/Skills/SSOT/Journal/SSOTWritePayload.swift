import Foundation

nonisolated struct SSOTOperationID: Hashable, Sendable {
    let uuid: UUID

    init(_ uuid: UUID = UUID()) {
        self.uuid = uuid
    }

    init(bytes: Data) throws {
        uuid = try SkillID(bytes: bytes).uuid
    }

    var bytes: Data { SkillID(uuid).bytes }
}

nonisolated struct SSOTCleanupDebtID: Hashable, Sendable {
    let uuid: UUID

    init(_ uuid: UUID = UUID()) {
        self.uuid = uuid
    }

    init(bytes: Data) throws {
        uuid = try SkillID(bytes: bytes).uuid
    }

    var bytes: Data { SkillID(uuid).bytes }
}

nonisolated struct SSOTSkillWritePayload: Sendable {
    static let maximumProviderAliasCount = 64

    let skill: ManagedSkillRecord
    let source: SkillSourceRecord?
    let providerAliases: [ProviderAliasRecord]

    init(
        skill: ManagedSkillRecord,
        source: SkillSourceRecord? = nil,
        providerAliases: [ProviderAliasRecord] = []
    ) throws {
        guard source?.skillID == nil || source?.skillID == skill.skillID else {
            throw SSOTWritePayloadError.sourceSkillMismatch
        }
        guard providerAliases.count <= Self.maximumProviderAliasCount else {
            throw SSOTWritePayloadError.tooManyProviderAliases
        }
        guard providerAliases.isEmpty || source != nil,
              providerAliases.allSatisfy({ $0.sourceID == source?.sourceID }) else {
            throw SSOTWritePayloadError.aliasSourceMismatch
        }
        let identities = providerAliases.map(\.identity)
        guard Set(identities).count == identities.count else {
            throw SSOTWritePayloadError.duplicateProviderAlias
        }
        self.skill = skill
        self.source = source
        self.providerAliases = providerAliases.sorted {
            ($0.identity.provider, $0.identity.identifier)
                < ($1.identity.provider, $1.identity.identifier)
        }
    }
}

nonisolated enum SSOTWritePayloadError: LocalizedError, Equatable {
    case payloadTooLarge
    case invalidPayload
    case unsupportedVersion(Int)
    case sourceSkillMismatch
    case aliasSourceMismatch
    case duplicateProviderAlias
    case tooManyProviderAliases

    var errorDescription: String? {
        switch self {
        case .payloadTooLarge: "The persisted Skill write payload is too large."
        case .invalidPayload: "The persisted Skill write payload is invalid."
        case .unsupportedVersion(let version):
            "The persisted Skill write payload version \(version) is unsupported."
        case .sourceSkillMismatch: "The source belongs to another Skill."
        case .aliasSourceMismatch: "A provider alias belongs to another source."
        case .duplicateProviderAlias: "The Skill write payload contains a duplicate provider alias."
        case .tooManyProviderAliases: "The Skill write payload contains too many provider aliases."
        }
    }
}

nonisolated enum SSOTWritePayloadCodec {
    static let maximumEncodedByteCount = 128 * 1_024
    private static let currentVersion = 1

    static func encode(_ payload: SSOTSkillWritePayload) throws -> Data {
        let data = try JSONEncoder.skillsManager.encode(Envelope(payload))
        guard 1...maximumEncodedByteCount ~= data.count else {
            throw SSOTWritePayloadError.payloadTooLarge
        }
        return data
    }

    static func decode(_ data: Data) throws -> SSOTSkillWritePayload {
        guard 1...maximumEncodedByteCount ~= data.count else {
            throw SSOTWritePayloadError.payloadTooLarge
        }
        let envelope: Envelope
        do {
            envelope = try JSONDecoder().decode(Envelope.self, from: data)
        } catch {
            throw SSOTWritePayloadError.invalidPayload
        }
        guard envelope.version == currentVersion else {
            throw SSOTWritePayloadError.unsupportedVersion(envelope.version)
        }
        do {
            return try envelope.payload()
        } catch let error as SSOTWritePayloadError {
            throw error
        } catch {
            throw SSOTWritePayloadError.invalidPayload
        }
    }

    private struct Envelope: Codable {
        struct Source: Codable {
            let id: UUID
            let repositoryURL: String
            let subpath: String
            let revision: String?
            let sourceVersion: String?
            let downloadURL: String?
        }

        struct Alias: Codable {
            let sourceID: UUID
            let provider: String
            let identifier: String
        }

        let version: Int
        let skillID: UUID
        let displayName: String
        let distributionSlug: String
        let fingerprintAlgorithmVersion: Int
        let fingerprintDigest: Data
        let status: String
        let createdAtMilliseconds: Int64
        let updatedAtMilliseconds: Int64
        let source: Source?
        let aliases: [Alias]

        init(_ payload: SSOTSkillWritePayload) {
            version = currentVersion
            skillID = payload.skill.skillID.uuid
            displayName = payload.skill.displayName.value
            distributionSlug = payload.skill.defaultDistributionSlug.value
            fingerprintAlgorithmVersion = payload.skill.contentFingerprint.algorithmVersion
            fingerprintDigest = payload.skill.contentFingerprint.digest
            status = payload.skill.status.rawValue
            createdAtMilliseconds = payload.skill.createdAtMilliseconds
            updatedAtMilliseconds = payload.skill.updatedAtMilliseconds
            source = payload.source.map {
                Source(
                    id: $0.sourceID.uuid,
                    repositoryURL: $0.repositoryURL.value,
                    subpath: $0.subpath.value,
                    revision: $0.revision?.value,
                    sourceVersion: $0.version?.value,
                    downloadURL: $0.downloadURL?.value
                )
            }
            aliases = payload.providerAliases.map {
                Alias(
                    sourceID: $0.sourceID.uuid,
                    provider: $0.identity.provider,
                    identifier: $0.identity.identifier
                )
            }
        }

        func payload() throws -> SSOTSkillWritePayload {
            guard let status = ManagedSkillStatus(rawValue: status) else {
                throw SSOTWritePayloadError.invalidPayload
            }
            let skillID = SkillID(skillID)
            let skill = try ManagedSkillRecord(
                skillID: skillID,
                displayName: SkillDisplayName(displayName),
                defaultDistributionSlug: DefaultDistributionSlug(validating: distributionSlug),
                contentFingerprint: SkillContentFingerprint(
                    algorithmVersion: fingerprintAlgorithmVersion,
                    digest: fingerprintDigest
                ),
                status: status,
                createdAtMilliseconds: createdAtMilliseconds,
                updatedAtMilliseconds: updatedAtMilliseconds
            )
            let sourceRecord = try source.map { source in
                SkillSourceRecord(
                    sourceID: SourceID(source.id),
                    skillID: skillID,
                    repositoryURL: try NormalizedRepositoryURL(source.repositoryURL),
                    subpath: try RepositorySubpath(source.subpath),
                    revision: try source.revision.map(SourceRevision.init),
                    version: try source.sourceVersion.map(SourceVersion.init),
                    downloadURL: try source.downloadURL.map(PublicDownloadURL.init)
                )
            }
            let aliasRecords = try aliases.map { alias in
                ProviderAliasRecord(
                    sourceID: SourceID(alias.sourceID),
                    identity: try ProviderAliasIdentity(
                        provider: alias.provider,
                        identifier: alias.identifier
                    )
                )
            }
            return try SSOTSkillWritePayload(
                skill: skill,
                source: sourceRecord,
                providerAliases: aliasRecords
            )
        }
    }
}

private extension JSONEncoder {
    nonisolated static var skillsManager: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return encoder
    }
}
