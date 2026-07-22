import CryptoKit
import Foundation

nonisolated enum SkillSchemaMigrator {
    static func open(
        at url: URL,
        accessMode: SQLiteAccessMode = .readWrite,
        afterInitialV0Read: () throws -> Void = {},
        beforeCommit: () throws -> Void = {},
        beforeV2Commit: () throws -> Void = {}
    ) throws -> SQLiteConnection {
        let connection = try SQLiteConnection(url: url, accessMode: accessMode)
        switch accessMode {
        case .readWrite:
            try admitSchemaVersion(connection)
            try connection.setJournalModeWAL()
            try migrateIfNeeded(
                connection,
                afterInitialV0Read: afterInitialV0Read,
                beforeCommit: beforeCommit,
                beforeV2Commit: beforeV2Commit
            )
        case .readOnly:
            try validateV2(connection)
        }
        return connection
    }

    static func migrateIfNeeded(
        _ connection: SQLiteConnection,
        afterInitialV0Read: () throws -> Void = {},
        beforeCommit: () throws -> Void = {},
        beforeV2Commit: () throws -> Void = {}
    ) throws {
        guard connection.accessMode == .readWrite else {
            throw SQLiteStoreError.invalidState("schema migration requires read-write access")
        }
        let rawVersion = try admittedSchemaVersion(connection)

        switch rawVersion {
        case 0:
            try afterInitialV0Read()
            try migrateV0ToV2(
                connection,
                beforeV1Commit: beforeCommit,
                beforeV2Commit: beforeV2Commit
            )
        case Int64(SkillSchemaV1.version):
            try validateV1(connection)
            try migrateV1ToV2(connection, beforeCommit: beforeV2Commit)
        case Int64(SkillSchemaV2.version):
            try validateV2(connection)
        default:
            throw SQLiteStoreError.invalidState("unsupported schema version \(rawVersion)")
        }
    }

    private static func migrateV0ToV2(
        _ connection: SQLiteConnection,
        beforeV1Commit: () throws -> Void,
        beforeV2Commit: () throws -> Void
    ) throws {
        try connection.execute("BEGIN IMMEDIATE")
        do {
            guard let lockedVersion = try connection.querySingleInt("PRAGMA user_version") else {
                throw SQLiteStoreError.invalidState("PRAGMA user_version returned no row")
            }
            if lockedVersion == Int64(SkillSchemaV2.version) {
                try validateV2(connection)
                try connection.execute("COMMIT")
                return
            }
            if lockedVersion == Int64(SkillSchemaV1.version) {
                try validateV1(connection)
                try applyV2Migration(connection, beforeCommit: beforeV2Commit)
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
            try beforeV1Commit()
            try validateV1(connection)
            try applyV2Migration(connection, beforeCommit: beforeV2Commit)
            try connection.execute("COMMIT")
        } catch {
            try? connection.execute("ROLLBACK")
            throw error
        }
    }

    private static func migrateV1ToV2(
        _ connection: SQLiteConnection,
        beforeCommit: () throws -> Void
    ) throws {
        try connection.execute("BEGIN IMMEDIATE")
        do {
            guard let lockedVersion = try connection.querySingleInt("PRAGMA user_version") else {
                throw SQLiteStoreError.invalidState("PRAGMA user_version returned no row")
            }
            if lockedVersion == Int64(SkillSchemaV2.version) {
                try validateV2(connection)
                try connection.execute("COMMIT")
                return
            }
            guard lockedVersion == Int64(SkillSchemaV1.version) else {
                throw SQLiteStoreError.invalidState(
                    "schema version changed to unsupported value \(lockedVersion)"
                )
            }
            try validateV1(connection)
            try applyV2Migration(connection, beforeCommit: beforeCommit)
            try connection.execute("COMMIT")
        } catch {
            try? connection.execute("ROLLBACK")
            throw error
        }
    }

    private static func applyV2Migration(
        _ connection: SQLiteConnection,
        beforeCommit: () throws -> Void
    ) throws {
        for statement in SkillSchemaV2.statements {
            try connection.execute(statement)
        }
        try connection.execute(
            "UPDATE schema_metadata SET schema_version = 2 WHERE singleton = 1"
        )
        try connection.execute("PRAGMA user_version = 2")
        try beforeCommit()
        try validateV2(connection)
    }

    private static func validateV1(_ connection: SQLiteConnection) throws {
        guard try connection.userTableNames() == SkillSchemaV1.tableNames else {
            throw SQLiteStoreError.invalidState("schema v1 table set is missing or contains unknown tables")
        }
        guard try connection.querySingleInt("PRAGMA user_version") == Int64(SkillSchemaV1.version) else {
            throw SQLiteStoreError.invalidState("PRAGMA user_version does not match schema v1")
        }
        try validateMetadata(connection, version: SkillSchemaV1.version)
    }

    private static func validateV2(_ connection: SQLiteConnection) throws {
        guard try connection.userTableNames() == SkillSchemaV2.tableNames else {
            throw SQLiteStoreError.invalidState("schema v2 table set is missing or contains unknown tables")
        }
        guard try connection.querySingleInt("PRAGMA user_version") == Int64(SkillSchemaV2.version) else {
            throw SQLiteStoreError.invalidState("PRAGMA user_version does not match schema v2")
        }
        try validateMetadata(connection, version: SkillSchemaV2.version)
        try validateV2Structure(connection)
        try validateV2CleanupRows(connection)
    }

    private static func validateV2Structure(_ connection: SQLiteConnection) throws {
        let schemaObjects = try textValues(
            connection,
            sql: "SELECT name FROM sqlite_schema "
                + "WHERE type IN ('index', 'trigger') AND name NOT LIKE 'sqlite_%' ORDER BY name"
        )
        guard schemaObjects == SkillSchemaV2.indexAndTriggerNames else {
            throw SQLiteStoreError.invalidState("schema v2 indexes or triggers do not match")
        }
        guard try columnNames(connection, table: "skills") == [
            "skill_id", "display_name", "default_distribution_slug", "default_slug_key",
            "fingerprint_algorithm_version", "content_fingerprint", "status",
            "created_at_ms", "updated_at_ms", "db_revision",
        ], try columnNames(connection, table: "skill_operations") == [
            "operation_id", "operation_type", "skill_id", "domain_payload",
            "phase", "outcome",
            "staging_locator", "final_locator", "recovery_locator",
            "old_fingerprint_algorithm_version", "old_content_fingerprint",
            "new_fingerprint_algorithm_version", "new_content_fingerprint",
            "expected_staged_identity", "expected_old_identity", "expected_new_identity",
            "expected_db_revision", "expected_root_identity", "cleanup_state",
            "cleanup_debt_id", "attempt_count", "last_error", "created_at_ms", "updated_at_ms",
        ], try columnNames(connection, table: "cleanup_debts") == [
            "cleanup_debt_id", "operation_id", "item_role", "recovery_locator",
            "expected_item_identity", "expected_fingerprint_algorithm_version",
            "expected_content_fingerprint", "expected_root_identity", "attempt_count",
            "last_error_code", "created_at_ms", "updated_at_ms",
        ] else {
            throw SQLiteStoreError.invalidState("schema v2 columns do not match")
        }
        guard try connection.querySingleInt(
            "SELECT count(*) FROM pragma_table_list WHERE schema = 'main' AND strict = 1 "
                + "AND name IN ('cleanup_debts','provider_aliases','schema_metadata',"
                + "'skill_operations','skills','sources')"
        ) == Int64(SkillSchemaV2.tableNames.count) else {
            throw SQLiteStoreError.invalidState("schema v2 tables must all be STRICT")
        }
        guard try schemaFingerprint(connection) == expectedSchemaFingerprint() else {
            throw SQLiteStoreError.invalidState("schema v2 SQL fingerprint does not match")
        }
    }

    private static func validateV2CleanupRows(_ connection: SQLiteConnection) throws {
        guard try connection.querySingleInt(
            """
            SELECT count(*) FROM skill_operations operation
            WHERE (operation.cleanup_state IN ('pending', 'needsRepair')
                AND NOT EXISTS (
                  SELECT 1 FROM cleanup_debts debt
                  WHERE debt.operation_id = operation.operation_id
                    AND debt.cleanup_debt_id = operation.cleanup_debt_id
                ))
              OR (operation.cleanup_state NOT IN ('pending', 'needsRepair') AND EXISTS (
                  SELECT 1 FROM cleanup_debts debt
                  WHERE debt.operation_id = operation.operation_id
                ))
            """
        ) == 0, try connection.querySingleInt(
            """
            SELECT count(*) FROM cleanup_debts debt
            JOIN skill_operations operation ON operation.operation_id = debt.operation_id
            WHERE operation.cleanup_state NOT IN ('pending', 'needsRepair')
              OR operation.cleanup_debt_id IS NOT debt.cleanup_debt_id
              OR operation.expected_root_identity IS NOT debt.expected_root_identity
              OR (debt.item_role = 'staging' AND (
                operation.phase <> 'completed'
                OR operation.outcome IS NOT 'rolledBack'
                OR operation.staging_locator IS NOT debt.recovery_locator
                OR operation.expected_staged_identity IS NOT debt.expected_item_identity
                OR operation.new_fingerprint_algorithm_version
                  IS NOT debt.expected_fingerprint_algorithm_version
                OR operation.new_content_fingerprint IS NOT debt.expected_content_fingerprint
              ))
              OR (debt.item_role = 'recovery' AND (
                operation.operation_type <> 'replace'
                OR NOT (
                  (operation.phase = 'databaseCommitted'
                    AND (operation.outcome IS NULL OR operation.outcome = 'needsRepair'))
                  OR (operation.phase = 'completed' AND operation.outcome = 'applied')
                )
                OR operation.recovery_locator IS NOT debt.recovery_locator
                OR operation.expected_old_identity IS NOT debt.expected_item_identity
                OR operation.old_fingerprint_algorithm_version
                  IS NOT debt.expected_fingerprint_algorithm_version
                OR operation.old_content_fingerprint IS NOT debt.expected_content_fingerprint
              ))
            """
        ) == 0 else {
            throw SQLiteStoreError.invalidState("schema v2 cleanup state is inconsistent")
        }
    }

    private static func validateMetadata(
        _ connection: SQLiteConnection,
        version: Int
    ) throws {
        let statement = try connection.prepare(
            "SELECT singleton, schema_version FROM schema_metadata ORDER BY singleton"
        )
        guard try statement.step(),
              statement.int64(at: 0) == 1,
              statement.int64(at: 1) == Int64(version),
              try !statement.step() else {
            throw SQLiteStoreError.invalidState(
                "schema_metadata must contain only singleton v\(version)"
            )
        }
        guard try !connection.foreignKeyViolationsExist() else {
            throw SQLiteStoreError.invalidState("foreign_key_check reported a violation")
        }
    }

    private static func admitSchemaVersion(_ connection: SQLiteConnection) throws {
        _ = try admittedSchemaVersion(connection)
    }

    private static func admittedSchemaVersion(_ connection: SQLiteConnection) throws -> Int64 {
        guard let version = try connection.querySingleInt("PRAGMA user_version") else {
            throw SQLiteStoreError.invalidState("PRAGMA user_version returned no row")
        }
        guard version >= 0 else {
            throw SQLiteStoreError.invalidState("negative schema version \(version)")
        }
        guard version <= Int64(SkillSchemaV2.version) else {
            throw SQLiteStoreError.invalidState("unsupported schema version \(version)")
        }
        return version
    }

    private static func schemaFingerprint(_ connection: SQLiteConnection) throws -> Data {
        let statement = try connection.prepare(
            "SELECT name, sql FROM sqlite_schema WHERE sql IS NOT NULL ORDER BY name"
        )
        let expectedNames = Set(SkillSchemaV2.fingerprintedObjectNames)
        var entries: [(name: String, sql: String)] = []
        while try statement.step() {
            guard let name = statement.text(at: 0), let sql = statement.text(at: 1) else {
                throw SQLiteStoreError.invalidState("sqlite_schema returned NULL SQL")
            }
            if expectedNames.contains(name) {
                entries.append((name, canonicalSchemaSQL(sql)))
            }
        }
        guard entries.map(\.name) == SkillSchemaV2.fingerprintedObjectNames else {
            throw SQLiteStoreError.invalidState("schema v2 fingerprint objects do not match")
        }
        return hashSchemaEntries(entries)
    }

    private static func expectedSchemaFingerprint() throws -> Data {
        let expectedNames = Set(SkillSchemaV2.fingerprintedObjectNames)
        let statements = SkillSchemaV1.statements
            + SkillSchemaV2.statements
            + [SkillSchemaV2.expectedSkillsTableSQL]
        var sqlByName: [String: String] = [:]
        for statement in statements {
            let canonical = canonicalSchemaSQL(statement)
            guard let name = createdSchemaObjectName(canonical), expectedNames.contains(name) else {
                continue
            }
            sqlByName[name] = canonical
        }
        let entries = sqlByName.map { (name: $0.key, sql: $0.value) }
            .sorted { $0.name < $1.name }
        guard entries.map(\.name) == SkillSchemaV2.fingerprintedObjectNames else {
            throw SQLiteStoreError.invalidState("expected schema v2 fingerprint is incomplete")
        }
        return hashSchemaEntries(entries)
    }

    private static func canonicalSchemaSQL(_ sql: String) -> String {
        sql.split(whereSeparator: \Character.isWhitespace).joined(separator: " ")
    }

    private static func createdSchemaObjectName(_ canonicalSQL: String) -> String? {
        let words = canonicalSQL.split(separator: " ")
        guard words.first == "CREATE", words.count >= 3 else { return nil }
        if words[1] == "UNIQUE" {
            guard words.count >= 4, words[2] == "INDEX" else { return nil }
            return String(words[3])
        }
        guard words[1] == "TABLE" || words[1] == "TRIGGER" else { return nil }
        return String(words[2])
    }

    private static func hashSchemaEntries(
        _ entries: [(name: String, sql: String)]
    ) -> Data {
        var bytes = Data()
        for entry in entries {
            bytes.append(contentsOf: entry.name.utf8)
            bytes.append(0)
            bytes.append(contentsOf: entry.sql.utf8)
            bytes.append(0)
        }
        return Data(SHA256.hash(data: bytes))
    }

    private static func columnNames(
        _ connection: SQLiteConnection,
        table: String
    ) throws -> [String] {
        try textValues(connection, sql: "SELECT name FROM pragma_table_info('\(table)') ORDER BY cid")
    }

    private static func textValues(
        _ connection: SQLiteConnection,
        sql: String
    ) throws -> [String] {
        let statement = try connection.prepare(sql)
        var values: [String] = []
        while try statement.step() {
            guard let value = statement.text(at: 0) else {
                throw SQLiteStoreError.invalidState("schema query returned NULL text")
            }
            values.append(value)
        }
        return values
    }
}
