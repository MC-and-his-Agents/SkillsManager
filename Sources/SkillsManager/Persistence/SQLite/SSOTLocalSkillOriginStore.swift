import Foundation

nonisolated enum LocalSkillOriginStoreError: Error, Equatable {
    case conflict
    case invalidInput
    case corruptRecord
}

nonisolated extension SSOTJournalStore {
    func localOrigins() throws -> [LocalSkillOriginRecord] {
        let statement = try connection.prepare(
            """
            SELECT skill_id, scope_kind, adapter_code, path_variant, custom_path_id,
                   raw_locator, normalized_locator, collision_key,
                   fingerprint_algorithm_version, content_fingerprint, confirmed_at_ms
            FROM local_skill_origins
            ORDER BY scope_kind, custom_path_id, adapter_code, path_variant, collision_key
            """
        )
        var records: [LocalSkillOriginRecord] = []
        while try statement.step() {
            records.append(try decodeLocalOrigin(statement))
        }
        guard Set(records.map(\.position)).count == records.count else {
            throw LocalSkillOriginStoreError.corruptRecord
        }
        return records
    }

    func localOriginsMatch(_ expected: [LocalSkillOriginRecord]) throws -> Bool {
        guard !expected.isEmpty else { return true }
        let stored = try localOriginsByPosition()
        return expected.allSatisfy { stored[$0.position] == $0 }
    }

    func resolveExistingImport(
        origins: [LocalSkillOriginRecord]
    ) throws -> ManagedSkillRecord? {
        guard !origins.isEmpty else { throw LocalSkillOriginStoreError.invalidInput }
        let stored = try localOriginsByPosition()
        let matches = origins.compactMap { stored[$0.position] }
        guard !matches.isEmpty else { return nil }
        guard matches.count == origins.count,
              Set(matches.map(\.skillID)).count == 1,
              zip(matches, origins).allSatisfy({
                  sameLocalOriginPositionEvidence($0.0, $0.1)
              }) else {
            throw LocalSkillOriginStoreError.conflict
        }
        guard let skill = try managedSkillRecord(matches[0].skillID),
              skill.contentFingerprint == origins[0].fingerprint else {
            throw LocalSkillOriginStoreError.conflict
        }
        return skill
    }

    func claimLocalOrigins(
        skillID: SkillID,
        expectedFingerprint: SkillContentFingerprint,
        origins: [LocalSkillOriginRecord]
    ) throws -> ManagedSkillRecord {
        guard !origins.isEmpty,
              origins.allSatisfy({
                  $0.skillID == skillID && $0.fingerprint == expectedFingerprint
              }) else {
            throw LocalSkillOriginStoreError.invalidInput
        }
        return try transaction {
            guard let skill = try managedSkillRecord(skillID),
                  skill.contentFingerprint == expectedFingerprint else {
                throw LocalSkillOriginStoreError.conflict
            }
            let stored = try localOriginsByPosition()
            for origin in origins {
                if let existing = stored[origin.position] {
                    guard sameLocalOriginEvidence(existing, origin) else {
                        throw LocalSkillOriginStoreError.conflict
                    }
                } else {
                    try insertLocalOrigin(origin)
                }
            }
            return skill
        }
    }

    func insertLocalOrigins(_ origins: [LocalSkillOriginRecord]) throws {
        for origin in origins {
            try insertLocalOrigin(origin)
        }
    }

    private func localOriginsByPosition() throws
        -> [LocalSkillOriginPosition: LocalSkillOriginRecord] {
        let records = try localOrigins()
        return Dictionary(uniqueKeysWithValues: records.map { ($0.position, $0) })
    }

    private func insertLocalOrigin(_ origin: LocalSkillOriginRecord) throws {
        let statement = try connection.prepare(
            """
            INSERT INTO local_skill_origins(
              skill_id, scope_kind, adapter_code, path_variant, custom_path_id,
              raw_locator, normalized_locator, collision_key,
              fingerprint_algorithm_version, content_fingerprint, confirmed_at_ms
            ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
            """
        )
        try statement.bind(origin.skillID.bytes, at: 1)
        try statement.bind(origin.scope.kind.rawValue, at: 2)
        try bindOptional(origin.scope.adapterCode, to: statement, at: 3)
        try bindOptional(origin.scope.pathVariant, to: statement, at: 4)
        if let customPathID = origin.scope.customPathID {
            try statement.bind(SkillID(customPathID).bytes, at: 5)
        } else {
            try statement.bindNull(at: 5)
        }
        try statement.bind(origin.rawLocator, at: 6)
        try statement.bind(origin.normalizedLocator, at: 7)
        try statement.bind(origin.collisionKey, at: 8)
        try statement.bind(Int64(origin.fingerprint.algorithmVersion), at: 9)
        try statement.bind(origin.fingerprint.digest, at: 10)
        try statement.bind(origin.confirmedAtMilliseconds, at: 11)
        try finishMutation(statement)
    }

    private func decodeLocalOrigin(
        _ statement: SQLiteStatement
    ) throws -> LocalSkillOriginRecord {
        let skillID = try SkillID(bytes: journalRequiredBlob(statement, 0))
        let scope = try localOriginScope(
            kind: journalRequiredText(statement, 1),
            adapterCode: statement.text(at: 2),
            pathVariant: statement.text(at: 3),
            customPathData: statement.blob(at: 4)
        )
        do {
            return try LocalSkillOriginRecord(
                skillID: skillID,
                scope: scope,
                rawLocator: journalRequiredText(statement, 5),
                normalizedLocator: journalRequiredText(statement, 6),
                collisionKey: journalRequiredText(statement, 7),
                fingerprint: SkillContentFingerprint(
                    algorithmVersion: Int(statement.int64(at: 8)),
                    digest: journalRequiredBlob(statement, 9)
                ),
                confirmedAtMilliseconds: statement.int64(at: 10)
            )
        } catch {
            throw LocalSkillOriginStoreError.corruptRecord
        }
    }
}

private nonisolated func localOriginScope(
    kind: String,
    adapterCode: String?,
    pathVariant: String?,
    customPathData: Data?
) throws -> SkillDiscoveryScope {
    switch SkillDiscoveryScopeKind(rawValue: kind) {
    case .global:
        guard adapterCode == nil, pathVariant == nil, customPathData == nil else {
            throw LocalSkillOriginStoreError.corruptRecord
        }
        return .global
    case .agent:
        guard let adapterCode, let pathVariant, customPathData == nil else {
            throw LocalSkillOriginStoreError.corruptRecord
        }
        return .agent(adapterCode: adapterCode, pathVariant: pathVariant)
    case .custom:
        guard let adapterCode, let pathVariant, let customPathData else {
            throw LocalSkillOriginStoreError.corruptRecord
        }
        return .custom(
            pathID: try SkillID(bytes: customPathData).uuid,
            adapterCode: adapterCode,
            pathVariant: pathVariant
        )
    case nil:
        throw LocalSkillOriginStoreError.corruptRecord
    }
}

private nonisolated func bindOptional(
    _ value: String?,
    to statement: SQLiteStatement,
    at index: Int32
) throws {
    if let value {
        try statement.bind(value, at: index)
    } else {
        try statement.bindNull(at: index)
    }
}

private nonisolated func sameLocalOriginEvidence(
    _ lhs: LocalSkillOriginRecord,
    _ rhs: LocalSkillOriginRecord
) -> Bool {
    lhs.skillID == rhs.skillID
        && sameLocalOriginPositionEvidence(lhs, rhs)
}

private nonisolated func sameLocalOriginPositionEvidence(
    _ lhs: LocalSkillOriginRecord,
    _ rhs: LocalSkillOriginRecord
) -> Bool {
    lhs.scope == rhs.scope
        && lhs.rawLocator == rhs.rawLocator
        && lhs.normalizedLocator == rhs.normalizedLocator
        && lhs.collisionKey == rhs.collisionKey
        && lhs.fingerprint == rhs.fingerprint
}
