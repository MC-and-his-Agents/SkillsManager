import Foundation

nonisolated extension SkillBackupManifestV1 {
    struct Wire: Codable {
        let schemaVersion: Int
        let backupID: String
        let originalSkillID: String
        let restoredFromSkillID: String?
        let createdAtMilliseconds: Int64
        let databaseRevision: Int64
        let skill: SkillWire
        let source: SourceWire?
        let aliases: [AliasWire]
        let localOrigins: [OriginWire]
        let distributionSelection: SelectionWire
        let content: ContentWire

        enum CodingKeys: String, CodingKey {
            case aliases
            case backupID = "backup_id"
            case content
            case createdAtMilliseconds = "created_at_ms"
            case databaseRevision = "database_revision"
            case distributionSelection = "distribution_selection"
            case localOrigins = "local_origins"
            case originalSkillID = "original_skill_id"
            case restoredFromSkillID = "restored_from_skill_id"
            case schemaVersion = "schema_version"
            case skill
            case source
        }

        init(_ manifest: SkillBackupManifestV1) {
            schemaVersion = SkillBackupManifestV1.schemaVersion
            backupID = manifest.backupID.uuid.uuidString.lowercased()
            originalSkillID = manifest.originalSkillID.uuid.uuidString.lowercased()
            restoredFromSkillID = manifest.payload.restoredFromSkillID?
                .uuid.uuidString.lowercased()
            createdAtMilliseconds = manifest.createdAtMilliseconds
            databaseRevision = manifest.databaseRevision
            skill = SkillWire(manifest.payload.skill)
            source = manifest.payload.source.map(SourceWire.init)
            aliases = manifest.payload.providerAliases.map(AliasWire.init).sorted {
                ($0.provider, $0.identifier) < ($1.provider, $1.identifier)
            }
            localOrigins = manifest.payload.localOrigins.map(OriginWire.init).sorted {
                $0.sortKey < $1.sortKey
            }
            distributionSelection = SelectionWire(manifest.distributionSelection)
            content = ContentWire(
                fingerprint: manifest.contentFingerprint,
                statistics: manifest.statistics
            )
        }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            guard container.contains(.source) else {
                throw SkillBackupManifestError.invalidManifest
            }
            schemaVersion = try container.decode(Int.self, forKey: .schemaVersion)
            backupID = try container.decode(String.self, forKey: .backupID)
            originalSkillID = try container.decode(String.self, forKey: .originalSkillID)
            restoredFromSkillID = try container.decodeIfPresent(
                String.self,
                forKey: .restoredFromSkillID
            )
            createdAtMilliseconds = try container.decode(Int64.self, forKey: .createdAtMilliseconds)
            databaseRevision = try container.decode(Int64.self, forKey: .databaseRevision)
            skill = try container.decode(SkillWire.self, forKey: .skill)
            source = try container.decodeIfPresent(SourceWire.self, forKey: .source)
            aliases = try container.decode([AliasWire].self, forKey: .aliases)
            localOrigins = try container.decode([OriginWire].self, forKey: .localOrigins)
            distributionSelection = try container.decode(
                SelectionWire.self,
                forKey: .distributionSelection
            )
            content = try container.decode(ContentWire.self, forKey: .content)
        }

        func encode(to encoder: Encoder) throws {
            var container = encoder.container(keyedBy: CodingKeys.self)
            try container.encode(schemaVersion, forKey: .schemaVersion)
            try container.encode(backupID, forKey: .backupID)
            try container.encode(originalSkillID, forKey: .originalSkillID)
            try container.encodeIfPresent(restoredFromSkillID, forKey: .restoredFromSkillID)
            try container.encode(createdAtMilliseconds, forKey: .createdAtMilliseconds)
            try container.encode(databaseRevision, forKey: .databaseRevision)
            try container.encode(skill, forKey: .skill)
            if let source {
                try container.encode(source, forKey: .source)
            } else {
                try container.encodeNil(forKey: .source)
            }
            try container.encode(aliases, forKey: .aliases)
            try container.encode(localOrigins, forKey: .localOrigins)
            try container.encode(distributionSelection, forKey: .distributionSelection)
            try container.encode(content, forKey: .content)
        }

        func manifest() throws -> SkillBackupManifestV1 {
            let backupUUID = try lowerUUID(backupID)
            let originalUUID = try lowerUUID(originalSkillID)
            let skill = try skill.record()
            guard skill.skillID.uuid == originalUUID,
                  try content.fingerprint == skill.contentFingerprint else {
                throw SkillBackupManifestError.invalidManifest
            }
            let source = try source?.record(skillID: skill.skillID)
            let aliasRecords = try aliases.map { try $0.record(source: source) }
            let originRecords = try localOrigins.map { try $0.record(skill: skill) }
            let payload = try SSOTSkillWritePayload(
                skill: skill,
                source: source,
                providerAliases: aliasRecords,
                localOrigins: originRecords,
                restoredFromSkillID: try restoredFromSkillID.map {
                    SkillID(try lowerUUID($0))
                }
            )
            let selection = try distributionSelection.selection(skillID: skill.skillID)
            guard Set(aliases.map(\.sortKey)).count == aliases.count,
                  Set(localOrigins.map(\.positionKey)).count == localOrigins.count else {
                throw SkillBackupManifestError.invalidManifest
            }
            return try SkillBackupManifestV1(
                backupID: SkillBackupID(backupUUID),
                payload: payload,
                databaseRevision: databaseRevision,
                distributionSelection: selection,
                statistics: content.statistics,
                createdAtMilliseconds: createdAtMilliseconds
            )
        }
    }

    struct SkillWire: Codable {
        let skillID: String
        let displayName: String
        let defaultDistributionSlug: String
        let fingerprintAlgorithmVersion: Int
        let contentFingerprint: String
        let status: String
        let createdAtMilliseconds: Int64
        let updatedAtMilliseconds: Int64

        enum CodingKeys: String, CodingKey {
            case contentFingerprint = "content_fingerprint"
            case createdAtMilliseconds = "created_at_ms"
            case defaultDistributionSlug = "default_distribution_slug"
            case displayName = "display_name"
            case fingerprintAlgorithmVersion = "fingerprint_algorithm_version"
            case skillID = "skill_id"
            case status
            case updatedAtMilliseconds = "updated_at_ms"
        }

        init(_ skill: ManagedSkillRecord) {
            skillID = skill.skillID.uuid.uuidString.lowercased()
            displayName = skill.displayName.value
            defaultDistributionSlug = skill.defaultDistributionSlug.value
            fingerprintAlgorithmVersion = skill.contentFingerprint.algorithmVersion
            contentFingerprint = lowerHex(skill.contentFingerprint.digest)
            status = skill.status.rawValue
            createdAtMilliseconds = skill.createdAtMilliseconds
            updatedAtMilliseconds = skill.updatedAtMilliseconds
        }

        func record() throws -> ManagedSkillRecord {
            guard let status = ManagedSkillStatus(rawValue: status) else {
                throw SkillBackupManifestError.invalidManifest
            }
            return try ManagedSkillRecord(
                skillID: SkillID(try lowerUUID(skillID)),
                displayName: SkillDisplayName(displayName),
                defaultDistributionSlug: DefaultDistributionSlug(
                    validating: defaultDistributionSlug
                ),
                contentFingerprint: SkillContentFingerprint(
                    algorithmVersion: fingerprintAlgorithmVersion,
                    digest: try lowerHexData(contentFingerprint)
                ),
                status: status,
                createdAtMilliseconds: createdAtMilliseconds,
                updatedAtMilliseconds: updatedAtMilliseconds
            )
        }
    }

    struct SourceWire: Codable {
        let sourceID: String
        let repositoryURL: String
        let subpath: String
        let revision: String?
        let version: String?
        let downloadURL: String?

        enum CodingKeys: String, CodingKey {
            case downloadURL = "download_url"
            case repositoryURL = "repository_url"
            case revision
            case sourceID = "source_id"
            case subpath
            case version
        }

        init(_ source: SkillSourceRecord) {
            sourceID = source.sourceID.uuid.uuidString.lowercased()
            repositoryURL = source.repositoryURL.value
            subpath = source.subpath.value
            revision = source.revision?.value
            version = source.version?.value
            downloadURL = source.downloadURL?.value
        }

        func record(skillID: SkillID) throws -> SkillSourceRecord {
            SkillSourceRecord(
                sourceID: SourceID(try lowerUUID(sourceID)),
                skillID: skillID,
                repositoryURL: try NormalizedRepositoryURL(repositoryURL),
                subpath: try RepositorySubpath(subpath),
                revision: try revision.map(SourceRevision.init),
                version: try version.map(SourceVersion.init),
                downloadURL: try downloadURL.map(PublicDownloadURL.init)
            )
        }
    }

    struct AliasWire: Codable {
        let sourceID: String
        let provider: String
        let identifier: String

        enum CodingKeys: String, CodingKey {
            case identifier
            case provider
            case sourceID = "source_id"
        }

        init(_ alias: ProviderAliasRecord) {
            sourceID = alias.sourceID.uuid.uuidString.lowercased()
            provider = alias.identity.provider
            identifier = alias.identity.identifier
        }

        var sortKey: String { provider + "\u{0}" + identifier }

        func record(source: SkillSourceRecord?) throws -> ProviderAliasRecord {
            guard let source,
                  try lowerUUID(sourceID) == source.sourceID.uuid else {
                throw SkillBackupManifestError.invalidManifest
            }
            return ProviderAliasRecord(
                sourceID: source.sourceID,
                identity: try ProviderAliasIdentity(provider: provider, identifier: identifier)
            )
        }
    }

    struct OriginWire: Codable {
        let skillID: String
        let scopeKind: String
        let adapterCode: String?
        let pathVariant: String?
        let customPathID: String?
        let rawLocator: String
        let normalizedLocator: String
        let collisionKey: String
        let fingerprintAlgorithmVersion: Int
        let contentFingerprint: String
        let confirmedAtMilliseconds: Int64

        enum CodingKeys: String, CodingKey {
            case adapterCode = "adapter_code"
            case collisionKey = "collision_key"
            case confirmedAtMilliseconds = "confirmed_at_ms"
            case contentFingerprint = "content_fingerprint"
            case customPathID = "custom_path_id"
            case fingerprintAlgorithmVersion = "fingerprint_algorithm_version"
            case normalizedLocator = "normalized_locator"
            case pathVariant = "path_variant"
            case rawLocator = "raw_locator"
            case scopeKind = "scope_kind"
            case skillID = "skill_id"
        }

        init(_ origin: LocalSkillOriginRecord) {
            skillID = origin.skillID.uuid.uuidString.lowercased()
            scopeKind = origin.scope.kind.rawValue
            adapterCode = origin.scope.adapterCode
            pathVariant = origin.scope.pathVariant
            customPathID = origin.scope.customPathID?.uuidString.lowercased()
            rawLocator = origin.rawLocator
            normalizedLocator = origin.normalizedLocator
            collisionKey = origin.collisionKey
            fingerprintAlgorithmVersion = origin.fingerprint.algorithmVersion
            contentFingerprint = lowerHex(origin.fingerprint.digest)
            confirmedAtMilliseconds = origin.confirmedAtMilliseconds
        }

        var positionKey: String {
            [scopeKind, customPathID ?? "", adapterCode ?? "", pathVariant ?? "", collisionKey]
                .joined(separator: "\u{0}")
        }

        var sortKey: String { positionKey + "\u{0}" + rawLocator }

        func record(skill: ManagedSkillRecord) throws -> LocalSkillOriginRecord {
            guard try lowerUUID(skillID) == skill.skillID.uuid,
                  let kind = SkillDiscoveryScopeKind(rawValue: scopeKind) else {
                throw SkillBackupManifestError.invalidManifest
            }
            let scope: SkillDiscoveryScope
            switch kind {
            case .global:
                guard adapterCode == nil, pathVariant == nil, customPathID == nil else {
                    throw SkillBackupManifestError.invalidManifest
                }
                scope = .global
            case .agent:
                guard let adapterCode, let pathVariant, customPathID == nil else {
                    throw SkillBackupManifestError.invalidManifest
                }
                scope = .agent(adapterCode: adapterCode, pathVariant: pathVariant)
            case .custom:
                guard let adapterCode, let pathVariant, let customPathID else {
                    throw SkillBackupManifestError.invalidManifest
                }
                scope = .custom(
                    pathID: try lowerUUID(customPathID),
                    adapterCode: adapterCode,
                    pathVariant: pathVariant
                )
            }
            return try LocalSkillOriginRecord(
                skillID: skill.skillID,
                scope: scope,
                rawLocator: rawLocator,
                normalizedLocator: normalizedLocator,
                collisionKey: collisionKey,
                fingerprint: SkillContentFingerprint(
                    algorithmVersion: fingerprintAlgorithmVersion,
                    digest: try lowerHexData(contentFingerprint)
                ),
                confirmedAtMilliseconds: confirmedAtMilliseconds
            )
        }
    }

    struct SelectionWire: Codable {
        let explicitlyConfigured: Bool
        let bindings: [BindingWire]

        enum CodingKeys: String, CodingKey {
            case bindings
            case explicitlyConfigured = "explicitly_configured"
        }

        init(_ selection: SkillBackupDistributionSelection) {
            explicitlyConfigured = selection.isExplicitlyConfigured
            bindings = selection.bindingIntents.map(BindingWire.init).sorted {
                $0.targetScopeKey < $1.targetScopeKey
            }
        }

        func selection(skillID: SkillID) throws -> SkillBackupDistributionSelection {
            guard Set(bindings.map(\.targetScopeKey)).count == bindings.count else {
                throw SkillBackupManifestError.invalidManifest
            }
            return try SkillBackupDistributionSelection(
                isExplicitlyConfigured: explicitlyConfigured,
                bindingIntents: bindings.map { try $0.intent(skillID: skillID) }
            )
        }
    }

    struct BindingWire: Codable {
        let targetScopeKey: String
        let scopeKind: String
        let adapterCode: String?
        let distributionSlug: String
        let syncMode: String

        enum CodingKeys: String, CodingKey {
            case adapterCode = "adapter_code"
            case distributionSlug = "distribution_slug"
            case scopeKind = "scope_kind"
            case syncMode = "sync_mode"
            case targetScopeKey = "target_scope_key"
        }

        init(_ intent: DistributionBindingIntent) {
            targetScopeKey = intent.scope.targetScopeKey
            scopeKind = intent.scope.kind
            adapterCode = intent.scope.adapter?.storageKey
            distributionSlug = intent.distributionSlug.value
            syncMode = intent.syncMode.rawValue
        }

        func intent(skillID: SkillID) throws -> DistributionBindingIntent {
            let scope: DistributionBindingScope
            switch scopeKind {
            case "global":
                guard adapterCode == nil, targetScopeKey == "global" else {
                    throw SkillBackupManifestError.invalidManifest
                }
                scope = .global
            case "agent":
                guard let adapterCode,
                      let adapter = SkillPlatform.allCases.first(where: {
                          $0.storageKey == adapterCode
                      }),
                      targetScopeKey == "agent:\(adapterCode)" else {
                    throw SkillBackupManifestError.invalidManifest
                }
                scope = .agent(adapter)
            default:
                throw SkillBackupManifestError.invalidManifest
            }
            guard let mode = DistributionSyncMode(rawValue: syncMode) else {
                throw SkillBackupManifestError.invalidManifest
            }
            return DistributionBindingIntent(
                skillID: skillID,
                scope: scope,
                distributionSlug: try DefaultDistributionSlug(validating: distributionSlug),
                syncMode: mode
            )
        }
    }

    struct ContentWire: Codable {
        let fingerprintAlgorithmVersion: Int
        let contentFingerprint: String
        let fileCount: Int
        let totalByteCount: UInt64

        enum CodingKeys: String, CodingKey {
            case contentFingerprint = "content_fingerprint"
            case fileCount = "file_count"
            case fingerprintAlgorithmVersion = "fingerprint_algorithm_version"
            case totalByteCount = "total_byte_count"
        }

        init(
            fingerprint: SkillContentFingerprint,
            statistics: SkillContentSnapshot.Statistics
        ) {
            fingerprintAlgorithmVersion = fingerprint.algorithmVersion
            contentFingerprint = lowerHex(fingerprint.digest)
            fileCount = statistics.fileCount
            totalByteCount = statistics.totalByteCount
        }

        var fingerprint: SkillContentFingerprint {
            get throws {
                try SkillContentFingerprint(
                    algorithmVersion: fingerprintAlgorithmVersion,
                    digest: try lowerHexData(contentFingerprint)
                )
            }
        }

        var statistics: SkillContentSnapshot.Statistics {
            .init(fileCount: fileCount, totalByteCount: totalByteCount)
        }
    }
}

private nonisolated func lowerUUID(_ raw: String) throws -> UUID {
    guard raw == raw.lowercased(),
          let value = UUID(uuidString: raw),
          value.uuidString.lowercased() == raw else {
        throw SkillBackupManifestError.invalidManifest
    }
    return value
}

private nonisolated func lowerHex(_ data: Data) -> String {
    data.map { String(format: "%02x", $0) }.joined()
}

private nonisolated func lowerHexData(_ raw: String) throws -> Data {
    guard raw == raw.lowercased(), raw.count.isMultiple(of: 2) else {
        throw SkillBackupManifestError.invalidManifest
    }
    var data = Data(capacity: raw.count / 2)
    var index = raw.startIndex
    while index < raw.endIndex {
        let next = raw.index(index, offsetBy: 2)
        guard let byte = UInt8(raw[index..<next], radix: 16) else {
            throw SkillBackupManifestError.invalidManifest
        }
        data.append(byte)
        index = next
    }
    return data
}
