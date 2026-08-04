import Foundation

nonisolated extension SkillSchemaMigrator {
    static func validateV15(_ connection: SQLiteConnection) throws {
        guard try connection.userTableNames() == SkillSchemaV15.tableNames,
              try connection.querySingleInt("PRAGMA user_version")
                == Int64(SkillSchemaV15.version) else {
            throw SQLiteStoreError.invalidState("schema v15 version or table set does not match")
        }
        try validateMetadata(connection, version: SkillSchemaV15.version)
        try validateV13Columns(connection)
        let schemaObjects = try SkillSchemaInspection.textValues(
            connection,
            sql: "SELECT name FROM sqlite_schema "
                + "WHERE type IN ('index', 'trigger') AND name NOT LIKE 'sqlite_%' ORDER BY name"
        )
        guard schemaObjects == SkillSchemaV15.indexAndTriggerNames,
              try SkillSchemaInspection.columnNames(connection, table: "skill_update_checks") == [
                "skill_id", "format_version", "status", "checked_at_ms", "snapshot_payload",
              ],
              try SkillSchemaInspection.columnNames(connection, table: "repository_catalog") == [
                "repository_id", "normalized_repository_url", "ref_kind", "requested_ref",
                "display_name", "enabled", "created_at_ms", "updated_at_ms", "db_revision",
              ] else {
            throw SQLiteStoreError.invalidState("schema v15 objects or columns do not match")
        }
        guard try connection.querySingleInt(
            "SELECT count(*) FROM pragma_table_list WHERE schema = 'main' AND strict = 1 "
                + "AND name NOT LIKE 'sqlite_%'"
        ) == Int64(SkillSchemaV15.tableNames.count),
              try SkillSchemaInspection.schemaFingerprint(
                connection,
                objectNames: SkillSchemaV15.fingerprintedObjectNames
              ) == SkillSchemaInspection.expectedV15SchemaFingerprint(),
              try !connection.foreignKeyViolationsExist() else {
            throw SQLiteStoreError.invalidState("schema v15 structure does not match")
        }
        try validateV13CopyProvenanceRows(connection)
        try validateV2CleanupRows(connection)
    }
}
