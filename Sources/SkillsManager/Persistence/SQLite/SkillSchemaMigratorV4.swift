nonisolated extension SkillSchemaMigrator {
    static func migrateV3ToV4(
        _ connection: SQLiteConnection,
        beforeCommit: () throws -> Void
    ) throws {
        try connection.execute("BEGIN IMMEDIATE")
        do {
            guard let lockedVersion = try connection.querySingleInt("PRAGMA user_version") else {
                throw SQLiteStoreError.invalidState("PRAGMA user_version returned no row")
            }
            if lockedVersion == Int64(SkillSchemaV4.version) {
                try validateV4(connection)
                try connection.execute("COMMIT")
                return
            }
            guard lockedVersion == Int64(SkillSchemaV3.version) else {
                throw SQLiteStoreError.invalidState(
                    "schema version changed to unsupported value \(lockedVersion)"
                )
            }
            try validateV3(connection)
            try applyV4Migration(connection, beforeCommit: beforeCommit)
            try connection.execute("COMMIT")
        } catch {
            try? connection.execute("ROLLBACK")
            throw error
        }
    }

    static func applyV4Migration(
        _ connection: SQLiteConnection,
        beforeCommit: () throws -> Void
    ) throws {
        for statement in SkillSchemaV4.statements {
            try connection.execute(statement)
        }
        try connection.execute(
            "UPDATE schema_metadata SET schema_version = 4 WHERE singleton = 1"
        )
        try connection.execute("PRAGMA user_version = 4")
        try beforeCommit()
        try validateV4(connection)
    }

    static func validateV4(_ connection: SQLiteConnection) throws {
        guard try connection.userTableNames() == SkillSchemaV4.tableNames else {
            throw SQLiteStoreError.invalidState(
                "schema v4 table set is missing or contains unknown tables"
            )
        }
        guard try connection.querySingleInt("PRAGMA user_version")
                == Int64(SkillSchemaV4.version) else {
            throw SQLiteStoreError.invalidState("PRAGMA user_version does not match schema v4")
        }
        try validateMetadata(connection, version: SkillSchemaV4.version)
        try validateV3Columns(connection)
        let schemaObjects = try SkillSchemaInspection.textValues(
            connection,
            sql: "SELECT name FROM sqlite_schema "
                + "WHERE type IN ('index', 'trigger') AND name NOT LIKE 'sqlite_%' ORDER BY name"
        )
        guard schemaObjects == SkillSchemaV4.indexAndTriggerNames else {
            throw SQLiteStoreError.invalidState("schema v4 indexes or triggers do not match")
        }
        guard try SkillSchemaInspection.columnNames(connection, table: "library_bootstrap") == [
            "singleton", "format_version", "bootstrap_kind", "bootstrap_id",
            "expected_marker_identity", "state",
        ], try connection.querySingleInt(
            "SELECT count(*) FROM pragma_table_list WHERE schema = 'main' AND strict = 1 "
                + "AND name NOT LIKE 'sqlite_%'"
        ) == Int64(SkillSchemaV4.tableNames.count), try SkillSchemaInspection.schemaFingerprint(
            connection,
            objectNames: SkillSchemaV4.fingerprintedObjectNames
        ) == SkillSchemaInspection.expectedV4SchemaFingerprint() else {
            throw SQLiteStoreError.invalidState("schema v4 structure does not match")
        }
        try validateV2CleanupRows(connection)
    }
}
