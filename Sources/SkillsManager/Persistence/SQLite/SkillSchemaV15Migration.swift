import Foundation

nonisolated extension SkillSchemaMigrator {
    static func applyV15Migration(
        _ connection: SQLiteConnection,
        beforeCommit: () throws -> Void
    ) throws {
        try connection.execute(SkillSchemaV15.repositoryCatalogSQL)
        try connection.execute(
            "UPDATE schema_metadata SET schema_version = 15 WHERE singleton = 1"
        )
        try connection.execute("PRAGMA user_version = 15")
        try beforeCommit()
        try validateV15(connection)
    }
}
