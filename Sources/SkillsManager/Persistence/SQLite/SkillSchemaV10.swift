nonisolated enum SkillSchemaV10 {
    static let version = 10

    static let tableNames = (SkillSchemaV9.tableNames + [
        "provider_provenance",
    ]).sorted()

    static let indexAndTriggerNames = SkillSchemaV9.indexAndTriggerNames

    static let fingerprintedObjectNames = (SkillSchemaV9.fingerprintedObjectNames + [
        "provider_provenance",
    ]).sorted()

    static let statements = [
        """
        CREATE TABLE provider_provenance (
          skill_id BLOB NOT NULL
            REFERENCES skills(skill_id) ON DELETE CASCADE
            CHECK (typeof(skill_id) = 'blob' AND length(skill_id) = 16),
          provider TEXT NOT NULL
            CHECK (typeof(provider) = 'text'
              AND length(CAST(provider AS BLOB)) BETWEEN 1 AND 64
              AND provider NOT GLOB '*[^a-z0-9._-]*'
              AND substr(provider, 1, 1) GLOB '[a-z0-9]'),
          provider_identifier TEXT NOT NULL
            CHECK (typeof(provider_identifier) = 'text'
              AND length(CAST(provider_identifier AS BLOB)) BETWEEN 1 AND 200
              AND provider_identifier NOT IN ('.', '..')
              AND substr(provider_identifier, 1, 1) <> '.'
              AND instr(provider_identifier, '/') = 0
              AND instr(provider_identifier, char(92)) = 0
              AND instr(provider_identifier, char(0)) = 0),
          provider_identifier_key TEXT NOT NULL
            CHECK (typeof(provider_identifier_key) = 'text'
              AND length(CAST(provider_identifier_key AS BLOB)) BETWEEN 1 AND 800),
          provider_version TEXT
            CHECK (provider_version IS NULL
              OR (typeof(provider_version) = 'text'
                AND length(CAST(provider_version AS BLOB)) BETWEEN 1 AND 512)),
          PRIMARY KEY (provider, provider_identifier_key),
          UNIQUE (skill_id, provider)
        ) STRICT
        """,
    ]
}

nonisolated extension SkillSchemaMigrator {
    static func applyV10Migration(
        _ connection: SQLiteConnection,
        beforeCommit: () throws -> Void
    ) throws {
        for statement in SkillSchemaV10.statements {
            try connection.execute(statement)
        }
        try connection.execute(
            "UPDATE schema_metadata SET schema_version = 10 WHERE singleton = 1"
        )
        try connection.execute("PRAGMA user_version = 10")
        try beforeCommit()
        try validateV10(connection)
    }

    static func validateV10(_ connection: SQLiteConnection) throws {
        guard try connection.userTableNames() == SkillSchemaV10.tableNames,
              try connection.querySingleInt("PRAGMA user_version")
                == Int64(SkillSchemaV10.version) else {
            throw SQLiteStoreError.invalidState("schema v10 version or table set does not match")
        }
        try validateMetadata(connection, version: SkillSchemaV10.version)
        try validateV3Columns(connection)
        let schemaObjects = try SkillSchemaInspection.textValues(
            connection,
            sql: "SELECT name FROM sqlite_schema "
                + "WHERE type IN ('index', 'trigger') AND name NOT LIKE 'sqlite_%' ORDER BY name"
        )
        guard schemaObjects == SkillSchemaV10.indexAndTriggerNames else {
            throw SQLiteStoreError.invalidState("schema v10 indexes or triggers do not match")
        }
        guard try SkillSchemaInspection.columnNames(
                connection,
                table: "provider_provenance"
              ) == [
                "skill_id", "provider", "provider_identifier", "provider_identifier_key",
                "provider_version",
              ],
              try connection.querySingleInt(
                "SELECT count(*) FROM pragma_table_list WHERE schema = 'main' AND strict = 1 "
                    + "AND name NOT LIKE 'sqlite_%'"
              ) == Int64(SkillSchemaV10.tableNames.count) else {
            throw SQLiteStoreError.invalidState("schema v10 table structure does not match")
        }
        guard try SkillSchemaInspection.schemaFingerprint(
                connection,
                objectNames: SkillSchemaV10.fingerprintedObjectNames
              ) == SkillSchemaInspection.expectedV10SchemaFingerprint() else {
            throw SQLiteStoreError.invalidState("schema v10 SQL fingerprint does not match")
        }
        try validateV2CleanupRows(connection)
    }
}
