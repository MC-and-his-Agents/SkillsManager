import Foundation

nonisolated extension SkillSchemaMigrator {
    static func applyV14Migration(
        _ connection: SQLiteConnection,
        beforeCommit: () throws -> Void
    ) throws {
        try connection.execute(SkillSchemaV14.updateChecksSQL)
        try connection.execute(
            "UPDATE schema_metadata SET schema_version = 14 WHERE singleton = 1"
        )
        try connection.execute("PRAGMA user_version = 14")
        try beforeCommit()
        try validateV14(connection)
    }
}
