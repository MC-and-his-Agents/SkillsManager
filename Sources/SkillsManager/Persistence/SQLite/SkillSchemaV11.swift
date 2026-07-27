import Foundation

nonisolated enum SkillSchemaV11 {
    static let version = 11

    static let tableNames = (SkillSchemaV10.tableNames + [
        "managed_publish_states",
    ]).sorted()

    static let indexAndTriggerNames = (SkillSchemaV10.indexAndTriggerNames + [
        "managed_publish_states_immutable_identity",
    ]).sorted()

    static let fingerprintedObjectNames = (SkillSchemaV10.fingerprintedObjectNames + [
        "managed_publish_states",
        "managed_publish_states_immutable_identity",
    ]).sorted()

    static let statements = [
        """
        CREATE TABLE managed_publish_states (
          skill_id BLOB PRIMARY KEY
            REFERENCES skills(skill_id) ON DELETE CASCADE
            CHECK (typeof(skill_id) = 'blob' AND length(skill_id) = 16),
          source_runtime_locator TEXT UNIQUE
            REFERENCES publish_states(runtime_locator) ON DELETE RESTRICT,
          last_published_hash TEXT NOT NULL
            CHECK (length(CAST(last_published_hash AS BLOB)) BETWEEN 1 AND 512),
          last_published_at_ms INTEGER NOT NULL
            CHECK (typeof(last_published_at_ms) = 'integer'),
          hash_algorithm_version INTEGER
            CHECK (hash_algorithm_version IS NULL OR hash_algorithm_version = 1)
        ) STRICT
        """,
        """
        CREATE TRIGGER managed_publish_states_immutable_identity
        BEFORE UPDATE ON managed_publish_states
        WHEN NEW.skill_id IS NOT OLD.skill_id
          OR NEW.source_runtime_locator IS NOT OLD.source_runtime_locator
        BEGIN
          SELECT RAISE(ABORT, 'managed publish state identity is immutable');
        END
        """,
    ]
}

nonisolated extension SkillSchemaMigrator {
    static func applyV11Migration(
        _ connection: SQLiteConnection,
        beforeCommit: () throws -> Void
    ) throws {
        for statement in SkillSchemaV11.statements {
            try connection.execute(statement)
        }
        try migrateManagedPublishStates(connection)
        try connection.execute(
            "UPDATE schema_metadata SET schema_version = 11 WHERE singleton = 1"
        )
        try connection.execute("PRAGMA user_version = 11")
        try beforeCommit()
        try validateV11(connection)
    }

    static func validateV11(_ connection: SQLiteConnection) throws {
        guard try connection.userTableNames() == SkillSchemaV11.tableNames,
              try connection.querySingleInt("PRAGMA user_version")
                == Int64(SkillSchemaV11.version) else {
            throw SQLiteStoreError.invalidState("schema v11 version or table set does not match")
        }
        try validateMetadata(connection, version: SkillSchemaV11.version)
        try validateV3Columns(connection)
        let schemaObjects = try SkillSchemaInspection.textValues(
            connection,
            sql: "SELECT name FROM sqlite_schema "
                + "WHERE type IN ('index', 'trigger') AND name NOT LIKE 'sqlite_%' ORDER BY name"
        )
        guard schemaObjects == SkillSchemaV11.indexAndTriggerNames else {
            throw SQLiteStoreError.invalidState("schema v11 indexes or triggers do not match")
        }
        guard try SkillSchemaInspection.columnNames(
            connection,
            table: "managed_publish_states"
        ) == [
            "skill_id", "source_runtime_locator", "last_published_hash",
            "last_published_at_ms", "hash_algorithm_version",
        ], try connection.querySingleInt(
            "SELECT count(*) FROM pragma_table_list WHERE schema = 'main' AND strict = 1 "
                + "AND name NOT LIKE 'sqlite_%'"
        ) == Int64(SkillSchemaV11.tableNames.count) else {
            throw SQLiteStoreError.invalidState("schema v11 table structure does not match")
        }
        guard try SkillSchemaInspection.schemaFingerprint(
            connection,
            objectNames: SkillSchemaV11.fingerprintedObjectNames
        ) == SkillSchemaInspection.expectedV11SchemaFingerprint() else {
            throw SQLiteStoreError.invalidState("schema v11 SQL fingerprint does not match")
        }
        try validateV2CleanupRows(connection)
    }

    private struct PublishCandidate {
        let locator: String
        let sourceLegacyLocator: String?
        let state: SQLitePublishState
        let collisionKey: String?
    }

    private static func migrateManagedPublishStates(_ connection: SQLiteConnection) throws {
        let candidates = try publishCandidates(connection)
        let skillsByKey = try managedSkillIDsByKey(connection)
        let candidatesByKey = Dictionary(grouping: candidates.compactMap { candidate in
            candidate.collisionKey.map { ($0, candidate) }
        }, by: \.0)

        for candidate in candidates {
            guard let key = candidate.collisionKey else {
                try updateLegacyBinding(candidate, skillID: nil, ambiguous: false, connection)
                continue
            }
            let matchingCandidates = candidatesByKey[key]?.map(\.1) ?? []
            let matchingSkills = skillsByKey[key] ?? []
            let isUnique = matchingCandidates.count == 1 && matchingSkills.count == 1
            if isUnique, let skillID = matchingSkills.first {
                try insertManagedPublishState(candidate, skillID: skillID, connection)
                try updateLegacyBinding(candidate, skillID: skillID, ambiguous: false, connection)
            } else {
                try updateLegacyBinding(
                    candidate,
                    skillID: nil,
                    ambiguous: matchingCandidates.count > 1 || matchingSkills.count > 1,
                    connection
                )
            }
        }
    }

    private static func publishCandidates(
        _ connection: SQLiteConnection
    ) throws -> [PublishCandidate] {
        let statement = try connection.prepare(
            """
            SELECT runtime_locator, source_legacy_locator, last_published_hash,
                   last_published_at_ms, hash_algorithm_version
            FROM publish_states ORDER BY runtime_locator
            """
        )
        var candidates: [PublishCandidate] = []
        while try statement.step() {
            guard let locator = statement.text(at: 0),
                  let hash = statement.text(at: 2),
                  !statement.isNull(at: 3) else {
                throw SQLiteStoreError.invalidState("publish state row is invalid")
            }
            let collisionKey = try? collisionKey(fromRuntimeLocator: locator)
            candidates.append(PublishCandidate(
                locator: locator,
                sourceLegacyLocator: statement.text(at: 1),
                state: SQLitePublishState(
                    lastPublishedHash: hash,
                    lastPublishedAtMilliseconds: statement.int64(at: 3),
                    hashAlgorithmVersion: statement.isNull(at: 4)
                        ? nil
                        : Int(statement.int64(at: 4))
                ),
                collisionKey: collisionKey
            ))
        }
        return candidates
    }

    private static func managedSkillIDsByKey(
        _ connection: SQLiteConnection
    ) throws -> [String: [SkillID]] {
        let statement = try connection.prepare(
            """
            SELECT skill_id, default_distribution_slug, default_slug_key
            FROM skills ORDER BY skill_id
            """
        )
        var result: [String: [SkillID]] = [:]
        while try statement.step() {
            guard let bytes = statement.blob(at: 0),
                  let slugValue = statement.text(at: 1),
                  let key = statement.text(at: 2) else {
                throw SQLiteStoreError.invalidState("managed Skill identity row is invalid")
            }
            let slug: DefaultDistributionSlug
            do {
                slug = try DefaultDistributionSlug(validating: slugValue)
            } catch {
                throw SQLiteStoreError.invalidState("managed Skill distribution slug is invalid")
            }
            guard slug.collisionKey == key else {
                throw SQLiteStoreError.invalidState("managed Skill slug key does not match")
            }
            result[key, default: []].append(try SkillID(bytes: bytes))
        }
        return result
    }

    private static func collisionKey(fromRuntimeLocator locator: String) throws -> String {
        let canonical = try PublishStateLocator.validateLegacy(locator)
        guard canonical.utf8.elementsEqual(locator.utf8) else {
            throw SQLiteStoreError.invalidState("publish state locator is not NFC")
        }
        let prefix = "skill-state/"
        let start = canonical.index(canonical.startIndex, offsetBy: prefix.count)
        let end = canonical.index(canonical.endIndex, offsetBy: -5)
        return SkillContentPath.collisionKey(for: String(canonical[start..<end]))
    }

    private static func insertManagedPublishState(
        _ candidate: PublishCandidate,
        skillID: SkillID,
        _ connection: SQLiteConnection
    ) throws {
        let statement = try connection.prepare(
            """
            INSERT INTO managed_publish_states(
              skill_id, source_runtime_locator, last_published_hash,
              last_published_at_ms, hash_algorithm_version
            ) VALUES (?, ?, ?, ?, ?)
            """
        )
        try statement.bind(skillID.bytes, at: 1)
        try statement.bind(candidate.locator, at: 2)
        try statement.bind(candidate.state.lastPublishedHash, at: 3)
        try statement.bind(candidate.state.lastPublishedAtMilliseconds, at: 4)
        if let version = candidate.state.hashAlgorithmVersion {
            try statement.bind(Int64(version), at: 5)
        } else {
            try statement.bindNull(at: 5)
        }
        _ = try statement.step()
    }

    private static func updateLegacyBinding(
        _ candidate: PublishCandidate,
        skillID: SkillID?,
        ambiguous: Bool,
        _ connection: SQLiteConnection
    ) throws {
        guard let legacyLocator = candidate.sourceLegacyLocator else { return }
        let statement: SQLiteStatement
        if let skillID {
            statement = try connection.prepare(
                """
                UPDATE legacy_publish_states
                SET binding_status = 'bound', bound_skill_id = ?, bound_at_ms = migrated_at_ms
                WHERE legacy_locator = ?
                """
            )
            try statement.bind(skillID.bytes, at: 1)
            try statement.bind(legacyLocator, at: 2)
        } else {
            statement = try connection.prepare(
                """
                UPDATE legacy_publish_states
                SET binding_status = ?, bound_skill_id = NULL, bound_at_ms = NULL
                WHERE legacy_locator = ?
                """
            )
            try statement.bind(ambiguous ? "ambiguous" : "unresolved", at: 1)
            try statement.bind(legacyLocator, at: 2)
        }
        _ = try statement.step()
    }
}
