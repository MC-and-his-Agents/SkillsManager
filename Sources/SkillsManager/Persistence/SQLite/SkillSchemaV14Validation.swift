import Foundation

nonisolated extension SkillSchemaMigrator {
    static func validateV14(_ connection: SQLiteConnection) throws {
        guard try connection.userTableNames() == SkillSchemaV14.tableNames,
              try connection.querySingleInt("PRAGMA user_version")
                == Int64(SkillSchemaV14.version) else {
            throw SQLiteStoreError.invalidState("schema v14 version or table set does not match")
        }
        try validateMetadata(connection, version: SkillSchemaV14.version)
        try validateV13Columns(connection)
        let schemaObjects = try SkillSchemaInspection.textValues(
            connection,
            sql: "SELECT name FROM sqlite_schema "
                + "WHERE type IN ('index', 'trigger') AND name NOT LIKE 'sqlite_%' ORDER BY name"
        )
        guard schemaObjects == SkillSchemaV14.indexAndTriggerNames else {
            throw SQLiteStoreError.invalidState("schema v14 indexes or triggers do not match")
        }
        guard try SkillSchemaInspection.columnNames(
            connection,
            table: "skill_update_checks"
        ) == [
            "skill_id", "format_version", "status", "checked_at_ms", "snapshot_payload",
        ] else {
            throw SQLiteStoreError.invalidState("schema v14 columns do not match")
        }
        guard try connection.querySingleInt(
            "SELECT count(*) FROM pragma_table_list WHERE schema = 'main' AND strict = 1 "
                + "AND name NOT LIKE 'sqlite_%'"
        ) == Int64(SkillSchemaV14.tableNames.count) else {
            throw SQLiteStoreError.invalidState("schema v14 strict table count does not match")
        }
        guard try SkillSchemaInspection.schemaFingerprint(
            connection,
            objectNames: SkillSchemaV14.fingerprintedObjectNames
        ) == SkillSchemaInspection.expectedV14SchemaFingerprint() else {
            throw SQLiteStoreError.invalidState("schema v14 SQL fingerprint does not match")
        }
        guard try !connection.foreignKeyViolationsExist() else {
            throw SQLiteStoreError.invalidState("schema v14 foreign keys do not match")
        }
        try validateV13CopyProvenanceRows(connection)
        try validateV2CleanupRows(connection)
    }
}
