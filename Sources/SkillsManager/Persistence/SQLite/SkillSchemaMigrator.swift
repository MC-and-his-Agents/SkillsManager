import Foundation

nonisolated enum SkillSchemaMigrator {
    static func open(
        at url: URL,
        afterInitialV0Read: () throws -> Void = {},
        beforeCommit: () throws -> Void = {}
    ) throws -> SQLiteConnection {
        let connection = try SQLiteConnection(url: url)
        try connection.setJournalModeWAL()
        try migrateIfNeeded(
            connection,
            afterInitialV0Read: afterInitialV0Read,
            beforeCommit: beforeCommit
        )
        return connection
    }

    static func migrateIfNeeded(
        _ connection: SQLiteConnection,
        afterInitialV0Read: () throws -> Void = {},
        beforeCommit: () throws -> Void = {}
    ) throws {
        guard let rawVersion = try connection.querySingleInt("PRAGMA user_version") else {
            throw SQLiteStoreError.invalidState("PRAGMA user_version returned no row")
        }
        guard rawVersion >= 0 else {
            throw SQLiteStoreError.invalidState("negative schema version \(rawVersion)")
        }

        switch rawVersion {
        case 0:
            try afterInitialV0Read()
            try migrateV0ToV1(connection, beforeCommit: beforeCommit)
        case Int64(SkillSchemaV1.version):
            try validateV1(connection)
        default:
            throw SQLiteStoreError.invalidState("unsupported schema version \(rawVersion)")
        }
    }

    private static func migrateV0ToV1(
        _ connection: SQLiteConnection,
        beforeCommit: () throws -> Void
    ) throws {
        try connection.execute("BEGIN IMMEDIATE")
        do {
            guard let lockedVersion = try connection.querySingleInt("PRAGMA user_version") else {
                throw SQLiteStoreError.invalidState("PRAGMA user_version returned no row")
            }
            if lockedVersion == Int64(SkillSchemaV1.version) {
                try validateV1(connection)
                try connection.execute("COMMIT")
                return
            }
            guard lockedVersion == 0 else {
                throw SQLiteStoreError.invalidState(
                    "schema version changed to unsupported value \(lockedVersion)"
                )
            }
            guard try connection.userTableNames().isEmpty else {
                throw SQLiteStoreError.invalidState("schema v0 contains unknown user tables")
            }

            for statement in SkillSchemaV1.statements {
                try connection.execute(statement)
            }
            try connection.execute(
                "INSERT INTO schema_metadata(singleton, schema_version) VALUES (1, 1)"
            )
            try connection.execute("PRAGMA user_version = 1")
            try beforeCommit()
            try validateV1(connection)
            try connection.execute("COMMIT")
        } catch {
            try? connection.execute("ROLLBACK")
            throw error
        }
    }

    private static func validateV1(_ connection: SQLiteConnection) throws {
        guard try connection.userTableNames() == SkillSchemaV1.tableNames else {
            throw SQLiteStoreError.invalidState("schema v1 table set is missing or contains unknown tables")
        }
        guard try connection.querySingleInt("PRAGMA user_version") == Int64(SkillSchemaV1.version) else {
            throw SQLiteStoreError.invalidState("PRAGMA user_version does not match schema v1")
        }

        let statement = try connection.prepare(
            "SELECT singleton, schema_version FROM schema_metadata ORDER BY singleton"
        )
        guard try statement.step(),
              statement.int64(at: 0) == 1,
              statement.int64(at: 1) == Int64(SkillSchemaV1.version),
              try !statement.step() else {
            throw SQLiteStoreError.invalidState("schema_metadata must contain only singleton v1")
        }
        guard try !connection.foreignKeyViolationsExist() else {
            throw SQLiteStoreError.invalidState("foreign_key_check reported a violation")
        }
    }
}
