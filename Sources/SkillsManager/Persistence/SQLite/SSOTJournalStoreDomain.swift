import Foundation

nonisolated extension SSOTJournalStore {
    func databaseObservation(for operation: SSOTJournalRecord) throws -> SSOTDatabaseObservation {
        let stored: StoredDomain
        do {
            guard let loaded = try loadStoredDomain(skillID: operation.skillID) else {
                return .absent
            }
            stored = loaded
        } catch let error as SQLiteStoreError {
            throw error
        } catch {
            return .unknown
        }
        if operation.operationType == .replace,
           stored.revision == operation.expectedDatabaseRevision,
           stored.payload.skill.contentFingerprint == operation.oldFingerprint {
            return .expectedOld
        }
        let expectedRevision: Int64
        switch operation.operationType {
        case .create:
            expectedRevision = 0
        case .replace:
            guard operation.expectedDatabaseRevision < Int64.max else { return .unknown }
            expectedRevision = operation.expectedDatabaseRevision + 1
        }
        guard stored.revision == expectedRevision,
              try canonicalDomainPayload(stored.payload)
                == canonicalDomainPayload(operation.payload),
              try localOriginsMatch(operation.payload.localOrigins) else {
            return .unknown
        }
        return .expectedNew
    }

    func commitCreate(
        operationID: SSOTOperationID,
        updatedAtMilliseconds: Int64
    ) throws {
        try transaction {
            let operation = try loadOperation(operationID)
            guard operation.operationType == .create,
                  operation.state == .init(
                    phase: .filesystemApplied,
                    outcome: .pending,
                    cleanupState: .notApplicable
                  ),
                  try databaseObservation(for: operation) == .absent else {
                throw SSOTJournalStoreError.databaseConflict
            }
            try insertSkill(operation.payload.skill, revision: 0)
            try replaceSourceAndAliases(operation.payload)
            try insertLocalOrigins(operation.payload.localOrigins)
            try recordDatabaseCommitted(
                operationID: operationID,
                updatedAtMilliseconds: updatedAtMilliseconds
            )
        }
    }

    func commitReplacement(
        operationID: SSOTOperationID,
        updatedAtMilliseconds: Int64
    ) throws {
        try transaction {
            let operation = try loadOperation(operationID)
            guard operation.operationType == .replace,
                  operation.expectedDatabaseRevision < Int64.max,
                  operation.state == .init(
                    phase: .filesystemApplied,
                    outcome: .pending,
                    cleanupState: .notStarted
                  ),
                  try databaseObservation(for: operation) == .expectedOld else {
                throw SSOTJournalStoreError.databaseConflict
            }
            try updateSkill(
                operation.payload.skill,
                expectedRevision: operation.expectedDatabaseRevision,
                expectedOldFingerprint: operation.oldFingerprint
            )
            try replaceSourceAndAliases(operation.payload)
            try recordDatabaseCommitted(
                operationID: operationID,
                updatedAtMilliseconds: updatedAtMilliseconds
            )
        }
    }

    private func loadStoredDomain(skillID: SkillID) throws -> StoredDomain? {
        let statement = try connection.prepare(
            """
            SELECT display_name, default_distribution_slug, default_slug_key,
                   fingerprint_algorithm_version, content_fingerprint, status,
                   created_at_ms, updated_at_ms, db_revision
            FROM skills WHERE skill_id = ?
            """
        )
        try statement.bind(skillID.bytes, at: 1)
        guard try statement.step() else { return nil }
        let slug = try DefaultDistributionSlug(validating: journalRequiredText(statement, 1))
        guard slug.collisionKey == (try journalRequiredText(statement, 2)) else {
            throw SSOTJournalStoreError.corruptRecord("stored distribution slug key is invalid")
        }
        let skill = try ManagedSkillRecord(
            skillID: skillID,
            displayName: SkillDisplayName(journalRequiredText(statement, 0)),
            defaultDistributionSlug: slug,
            contentFingerprint: SkillContentFingerprint(
                algorithmVersion: Int(statement.int64(at: 3)),
                digest: journalRequiredBlob(statement, 4)
            ),
            status: try journalRequiredEnum(statement, 5, as: ManagedSkillStatus.self),
            createdAtMilliseconds: statement.int64(at: 6),
            updatedAtMilliseconds: statement.int64(at: 7)
        )
        let revision = statement.int64(at: 8)
        guard try !statement.step() else {
            throw SSOTJournalStoreError.corruptRecord("duplicate managed Skill UUID")
        }
        let source = try loadSource(skillID: skillID)
        let aliases: [ProviderAliasRecord]
        if let source {
            aliases = try loadAliases(sourceID: source.sourceID)
        } else {
            aliases = []
        }
        return StoredDomain(
            payload: try SSOTSkillWritePayload(
                skill: skill,
                source: source,
                providerAliases: aliases
            ),
            revision: revision
        )
    }

    func managedSkillRecord(_ skillID: SkillID) throws -> ManagedSkillRecord? {
        try loadStoredDomain(skillID: skillID)?.payload.skill
    }

    func discoveryCatalog() throws -> SkillDiscoveryCatalog {
        let statement = try connection.prepare(
            "SELECT skill_id FROM skills ORDER BY skill_id"
        )
        var managedSkills: [SkillDiscoveryManagedSkill] = []
        while try statement.step() {
            let skillID = try SkillID(bytes: journalRequiredBlob(statement, 0))
            guard let stored = try loadStoredDomain(skillID: skillID) else {
                throw SSOTJournalStoreError.corruptRecord("stored Skill disappeared")
            }
            managedSkills.append(SkillDiscoveryManagedSkill(
                skillID: skillID,
                fingerprint: stored.payload.skill.contentFingerprint,
                sourceKey: stored.payload.source.map(SkillDiscoverySourceKey.init),
                providerAliases: Set(stored.payload.providerAliases.map(\.identity))
            ))
        }
        let associations = try localOrigins().map {
            SkillDiscoveryLocalAssociation(
                scope: $0.scope,
                relativeLocatorKey: $0.collisionKey,
                skillID: $0.skillID,
                fingerprint: $0.fingerprint
            )
        }
        return SkillDiscoveryCatalog(
            managedSkills: managedSkills,
            localAssociations: associations
        )
    }

    private func loadSource(skillID: SkillID) throws -> SkillSourceRecord? {
        let statement = try connection.prepare(
            """
            SELECT source_id, normalized_repository_url, normalized_subpath,
                   revision, version, download_url
            FROM sources WHERE skill_id = ?
            """
        )
        try statement.bind(skillID.bytes, at: 1)
        guard try statement.step() else { return nil }
        let source = try SkillSourceRecord(
            sourceID: SourceID(bytes: journalRequiredBlob(statement, 0)),
            skillID: skillID,
            repositoryURL: NormalizedRepositoryURL(journalRequiredText(statement, 1)),
            subpath: RepositorySubpath(journalRequiredText(statement, 2)),
            revision: try optionalSourceRevision(statement.text(at: 3)),
            version: try optionalSourceVersion(statement.text(at: 4)),
            downloadURL: try optionalDownloadURL(statement.text(at: 5))
        )
        guard try !statement.step() else {
            throw SSOTJournalStoreError.corruptRecord("a Skill has multiple sources")
        }
        return source
    }

    private func loadAliases(sourceID: SourceID) throws -> [ProviderAliasRecord] {
        let statement = try connection.prepare(
            """
            SELECT provider, provider_identifier FROM provider_aliases
            WHERE source_id = ? ORDER BY provider, provider_identifier
            """
        )
        try statement.bind(sourceID.bytes, at: 1)
        var aliases: [ProviderAliasRecord] = []
        while try statement.step() {
            aliases.append(ProviderAliasRecord(
                sourceID: sourceID,
                identity: try ProviderAliasIdentity(
                    provider: journalRequiredText(statement, 0),
                    identifier: journalRequiredText(statement, 1)
                )
            ))
        }
        return aliases
    }

    private func insertSkill(_ skill: ManagedSkillRecord, revision: Int64) throws {
        let statement = try connection.prepare(Self.skillInsertSQL)
        try statement.bind(skill.skillID.bytes, at: 1)
        try bindSkillValues(skill, revision: revision, to: statement, startingAt: 2)
        try finishMutation(statement)
    }

    private func updateSkill(
        _ skill: ManagedSkillRecord,
        expectedRevision: Int64,
        expectedOldFingerprint: SkillContentFingerprint?
    ) throws {
        guard let expectedOldFingerprint else { throw SSOTJournalStoreError.invalidRecord }
        let statement = try connection.prepare(Self.skillUpdateSQL)
        try bindSkillValues(skill, revision: expectedRevision + 1, to: statement, startingAt: 1)
        try statement.bind(skill.skillID.bytes, at: 10)
        try statement.bind(expectedRevision, at: 11)
        try statement.bind(Int64(expectedOldFingerprint.algorithmVersion), at: 12)
        try statement.bind(expectedOldFingerprint.digest, at: 13)
        do {
            try finishMutation(statement)
        } catch SSOTJournalStoreError.stateConflict {
            throw SSOTJournalStoreError.databaseConflict
        }
    }

    private func bindSkillValues(
        _ skill: ManagedSkillRecord,
        revision: Int64,
        to statement: SQLiteStatement,
        startingAt firstIndex: Int32
    ) throws {
        try statement.bind(skill.displayName.value, at: firstIndex)
        try statement.bind(skill.defaultDistributionSlug.value, at: firstIndex + 1)
        try statement.bind(skill.defaultDistributionSlug.collisionKey, at: firstIndex + 2)
        try statement.bind(Int64(skill.contentFingerprint.algorithmVersion), at: firstIndex + 3)
        try statement.bind(skill.contentFingerprint.digest, at: firstIndex + 4)
        try statement.bind(skill.status.rawValue, at: firstIndex + 5)
        try statement.bind(skill.createdAtMilliseconds, at: firstIndex + 6)
        try statement.bind(skill.updatedAtMilliseconds, at: firstIndex + 7)
        try statement.bind(revision, at: firstIndex + 8)
    }

    private func replaceSourceAndAliases(_ payload: SSOTSkillWritePayload) throws {
        let delete = try connection.prepare("DELETE FROM sources WHERE skill_id = ?")
        try delete.bind(payload.skill.skillID.bytes, at: 1)
        guard try !delete.step(),
              let deleted = try connection.querySingleInt("SELECT changes()"),
              0...1 ~= deleted else {
            throw SSOTJournalStoreError.corruptRecord("a Skill has multiple source rows")
        }
        guard let source = payload.source else { return }
        try insertSource(source)
        for alias in payload.providerAliases { try insertAlias(alias) }
    }

    private func insertSource(_ source: SkillSourceRecord) throws {
        let statement = try connection.prepare(Self.sourceInsertSQL)
        try statement.bind(source.sourceID.bytes, at: 1)
        try statement.bind(source.skillID.bytes, at: 2)
        try statement.bind(source.repositoryURL.value, at: 3)
        try statement.bind(source.subpath.value, at: 4)
        try bindOptionalText(source.revision?.value, to: statement, at: 5)
        try bindOptionalText(source.version?.value, to: statement, at: 6)
        try bindOptionalText(source.downloadURL?.value, to: statement, at: 7)
        try finishMutation(statement)
    }

    private func insertAlias(_ alias: ProviderAliasRecord) throws {
        let statement = try connection.prepare(
            "INSERT INTO provider_aliases(source_id, provider, provider_identifier) VALUES (?, ?, ?)"
        )
        try statement.bind(alias.sourceID.bytes, at: 1)
        try statement.bind(alias.identity.provider, at: 2)
        try statement.bind(alias.identity.identifier, at: 3)
        try finishMutation(statement)
    }

    private func recordDatabaseCommitted(
        operationID: SSOTOperationID,
        updatedAtMilliseconds: Int64
    ) throws {
        let statement = try connection.prepare(
            """
            UPDATE skill_operations SET phase = 'databaseCommitted', updated_at_ms = ?
            WHERE operation_id = ? AND phase = 'filesystemApplied' AND outcome IS NULL
            """
        )
        try statement.bind(updatedAtMilliseconds, at: 1)
        try statement.bind(operationID.bytes, at: 2)
        try finishMutation(statement)
    }

    private static let skillInsertSQL = """
    INSERT INTO skills(
      skill_id, display_name, default_distribution_slug, default_slug_key,
      fingerprint_algorithm_version, content_fingerprint, status,
      created_at_ms, updated_at_ms, db_revision
    ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
    """

    private static let skillUpdateSQL = """
    UPDATE skills SET display_name = ?, default_distribution_slug = ?,
      default_slug_key = ?, fingerprint_algorithm_version = ?, content_fingerprint = ?,
      status = ?, created_at_ms = ?, updated_at_ms = ?, db_revision = ?
    WHERE skill_id = ? AND db_revision = ?
      AND fingerprint_algorithm_version = ? AND content_fingerprint = ?
    """

    private static let sourceInsertSQL = """
    INSERT INTO sources(
      source_id, skill_id, normalized_repository_url, normalized_subpath,
      revision, version, download_url
    ) VALUES (?, ?, ?, ?, ?, ?, ?)
    """
}

private nonisolated struct StoredDomain {
    let payload: SSOTSkillWritePayload
    let revision: Int64
}

private nonisolated func canonicalDomainPayload(
    _ payload: SSOTSkillWritePayload
) throws -> Data {
    try SSOTWritePayloadCodec.encode(SSOTSkillWritePayload(
        skill: payload.skill,
        source: payload.source,
        providerAliases: payload.providerAliases
    ))
}

private nonisolated func bindOptionalText(
    _ value: String?,
    to statement: SQLiteStatement,
    at index: Int32
) throws {
    if let value { try statement.bind(value, at: index) } else { try statement.bindNull(at: index) }
}

private nonisolated func optionalSourceRevision(_ value: String?) throws -> SourceRevision? {
    if let value { return try SourceRevision(value) }
    return nil
}

private nonisolated func optionalSourceVersion(_ value: String?) throws -> SourceVersion? {
    if let value { return try SourceVersion(value) }
    return nil
}

private nonisolated func optionalDownloadURL(_ value: String?) throws -> PublicDownloadURL? {
    if let value { return try PublicDownloadURL(value) }
    return nil
}
