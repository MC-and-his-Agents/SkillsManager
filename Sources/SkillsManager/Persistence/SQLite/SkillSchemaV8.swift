nonisolated enum SkillSchemaV8 {
    static let version = 8

    static let tableNames = (SkillSchemaV7.tableNames + [
        "distribution_configurations",
    ]).sorted()

    static let indexAndTriggerNames = SkillSchemaV7.indexAndTriggerNames

    static let fingerprintedObjectNames = (SkillSchemaV7.fingerprintedObjectNames + [
        "distribution_configurations",
    ]).sorted()

    static let statements = [
        """
        CREATE TABLE distribution_configurations (
          skill_id BLOB PRIMARY KEY NOT NULL
            REFERENCES skills(skill_id) ON DELETE CASCADE
            CHECK (typeof(skill_id) = 'blob' AND length(skill_id) = 16),
          configured_at_ms INTEGER NOT NULL
            CHECK (typeof(configured_at_ms) = 'integer' AND configured_at_ms >= 0)
        ) STRICT
        """,
        """
        INSERT INTO distribution_configurations(skill_id, configured_at_ms)
        SELECT skill_id, MIN(created_at_ms)
        FROM distribution_bindings
        GROUP BY skill_id
        """,
    ]
}

nonisolated extension SkillSchemaMigrator {
    static func applyV8Migration(
        _ connection: SQLiteConnection,
        beforeCommit: () throws -> Void
    ) throws {
        for statement in SkillSchemaV8.statements {
            try connection.execute(statement)
        }
        try connection.execute(
            "UPDATE schema_metadata SET schema_version = 8 WHERE singleton = 1"
        )
        try connection.execute("PRAGMA user_version = 8")
        try beforeCommit()
        try validateV8(connection)
    }

    static func validateV8(_ connection: SQLiteConnection) throws {
        guard try connection.userTableNames() == SkillSchemaV8.tableNames else {
            throw SQLiteStoreError.invalidState(
                "schema v8 table set is missing or contains unknown tables"
            )
        }
        guard try connection.querySingleInt("PRAGMA user_version")
                == Int64(SkillSchemaV8.version) else {
            throw SQLiteStoreError.invalidState("PRAGMA user_version does not match schema v8")
        }
        try validateMetadata(connection, version: SkillSchemaV8.version)
        try validateV3Columns(connection)
        let schemaObjects = try SkillSchemaInspection.textValues(
            connection,
            sql: "SELECT name FROM sqlite_schema "
                + "WHERE type IN ('index', 'trigger') AND name NOT LIKE 'sqlite_%' ORDER BY name"
        )
        guard schemaObjects == SkillSchemaV8.indexAndTriggerNames else {
            throw SQLiteStoreError.invalidState("schema v8 indexes or triggers do not match")
        }
        guard try SkillSchemaInspection.columnNames(
            connection,
            table: "distribution_configurations"
        ) == [
            "skill_id", "configured_at_ms",
        ], try connection.querySingleInt(
            "SELECT count(*) FROM pragma_table_list WHERE schema = 'main' AND strict = 1 "
                + "AND name NOT LIKE 'sqlite_%'"
        ) == Int64(SkillSchemaV8.tableNames.count), try SkillSchemaInspection.schemaFingerprint(
            connection,
            objectNames: SkillSchemaV8.fingerprintedObjectNames
        ) == SkillSchemaInspection.expectedV8SchemaFingerprint() else {
            throw SQLiteStoreError.invalidState("schema v8 structure does not match")
        }
        try validateV2CleanupRows(connection)
    }
}
