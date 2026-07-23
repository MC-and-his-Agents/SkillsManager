import Foundation

nonisolated enum SkillSchemaMigrator {
    static func open(
        at url: URL,
        accessMode: SQLiteAccessMode = .readWrite,
        expectedParentIdentity: ManagedItemIdentity? = nil,
        afterInitialV0Read: () throws -> Void = {},
        beforeCommit: () throws -> Void = {},
        beforeV2Commit: () throws -> Void = {},
        beforeV3Commit: () throws -> Void = {},
        beforeV4Commit: () throws -> Void = {},
        beforeV5Commit: () throws -> Void = {},
        beforeV6Commit: () throws -> Void = {},
        initializeV4: (SQLiteConnection) throws -> Void = { _ in }
    ) throws -> SQLiteConnection {
        let connection = try SQLiteConnection(
            url: url,
            accessMode: accessMode,
            expectedParentIdentity: expectedParentIdentity
        )
        switch accessMode {
        case .readWrite, .readWriteExisting:
            try admitSchemaVersion(connection)
            try connection.setJournalModeWAL()
            try migrateIfNeeded(
                connection,
                afterInitialV0Read: afterInitialV0Read,
                beforeCommit: beforeCommit,
                beforeV2Commit: beforeV2Commit,
                beforeV3Commit: beforeV3Commit,
                beforeV4Commit: beforeV4Commit,
                beforeV5Commit: beforeV5Commit,
                beforeV6Commit: beforeV6Commit,
                initializeV4: initializeV4
            )
        case .readOnly:
            try validateV6(connection)
        }
        return connection
    }

    static func migrateIfNeeded(
        _ connection: SQLiteConnection,
        afterInitialV0Read: () throws -> Void = {},
        beforeCommit: () throws -> Void = {},
        beforeV2Commit: () throws -> Void = {},
        beforeV3Commit: () throws -> Void = {},
        beforeV4Commit: () throws -> Void = {},
        beforeV5Commit: () throws -> Void = {},
        beforeV6Commit: () throws -> Void = {},
        initializeV4: (SQLiteConnection) throws -> Void = { _ in }
    ) throws {
        guard connection.accessMode != .readOnly else {
            throw SQLiteStoreError.invalidState("schema migration requires read-write access")
        }
        let rawVersion = try admittedSchemaVersion(connection)

        switch rawVersion {
        case 0:
            try afterInitialV0Read()
            try migrateV0ToV6(
                connection,
                beforeV1Commit: beforeCommit,
                beforeV2Commit: beforeV2Commit,
                beforeV3Commit: beforeV3Commit,
                beforeV4Commit: beforeV4Commit,
                beforeV5Commit: beforeV5Commit,
                beforeV6Commit: beforeV6Commit,
                initializeV4: initializeV4
            )
        case Int64(SkillSchemaV1.version):
            try validateV1(connection)
            try migrateV1ToV6(
                connection,
                beforeV2Commit: beforeV2Commit,
                beforeV3Commit: beforeV3Commit,
                beforeV4Commit: beforeV4Commit,
                beforeV5Commit: beforeV5Commit,
                beforeV6Commit: beforeV6Commit
            )
        case Int64(SkillSchemaV2.version):
            try validateV2(connection)
            try migrateV2ToV6(
                connection,
                beforeV3Commit: beforeV3Commit,
                beforeV4Commit: beforeV4Commit,
                beforeV5Commit: beforeV5Commit,
                beforeV6Commit: beforeV6Commit
            )
        case Int64(SkillSchemaV3.version):
            try validateV3(connection)
            try migrateV3ToV6(
                connection,
                beforeV4Commit: beforeV4Commit,
                beforeV5Commit: beforeV5Commit,
                beforeV6Commit: beforeV6Commit
            )
        case Int64(SkillSchemaV4.version):
            try validateV4(connection)
            try migrateV4ToV6(
                connection,
                beforeV5Commit: beforeV5Commit,
                beforeV6Commit: beforeV6Commit
            )
        case Int64(SkillSchemaV5.version):
            try validateV5(connection)
            try migrateV5ToV6(connection, beforeCommit: beforeV6Commit)
        case Int64(SkillSchemaV6.version):
            try validateV6(connection)
        default:
            throw SQLiteStoreError.invalidState("unsupported schema version \(rawVersion)")
        }
    }

    private static func migrateV0ToV6(
        _ connection: SQLiteConnection,
        beforeV1Commit: () throws -> Void,
        beforeV2Commit: () throws -> Void,
        beforeV3Commit: () throws -> Void,
        beforeV4Commit: () throws -> Void,
        beforeV5Commit: () throws -> Void,
        beforeV6Commit: () throws -> Void,
        initializeV4: (SQLiteConnection) throws -> Void
    ) throws {
        try connection.execute("BEGIN IMMEDIATE")
        do {
            guard let lockedVersion = try connection.querySingleInt("PRAGMA user_version") else {
                throw SQLiteStoreError.invalidState("PRAGMA user_version returned no row")
            }
            if lockedVersion == Int64(SkillSchemaV6.version) {
                try validateV6(connection)
                try connection.execute("COMMIT")
                return
            }
            if lockedVersion == Int64(SkillSchemaV5.version) {
                try validateV5(connection)
                try applyV6Migration(connection, beforeCommit: beforeV6Commit)
                try connection.execute("COMMIT")
                return
            }
            if lockedVersion == Int64(SkillSchemaV4.version) {
                try validateV4(connection)
                try applyV5Migration(connection, beforeCommit: beforeV5Commit)
                try applyV6Migration(connection, beforeCommit: beforeV6Commit)
                try connection.execute("COMMIT")
                return
            }
            if lockedVersion == Int64(SkillSchemaV3.version) {
                try validateV3(connection)
                try applyV4Migration(connection, beforeCommit: beforeV4Commit)
                try applyV5Migration(connection, beforeCommit: beforeV5Commit)
                try applyV6Migration(connection, beforeCommit: beforeV6Commit)
                try connection.execute("COMMIT")
                return
            }
            if lockedVersion == Int64(SkillSchemaV2.version) {
                try validateV2(connection)
                try applyV3Migration(connection, beforeCommit: beforeV3Commit)
                try applyV4Migration(connection, beforeCommit: beforeV4Commit)
                try applyV5Migration(connection, beforeCommit: beforeV5Commit)
                try applyV6Migration(connection, beforeCommit: beforeV6Commit)
                try connection.execute("COMMIT")
                return
            }
            if lockedVersion == Int64(SkillSchemaV1.version) {
                try validateV1(connection)
                try applyV2Migration(connection, beforeCommit: beforeV2Commit)
                try applyV3Migration(connection, beforeCommit: beforeV3Commit)
                try applyV4Migration(connection, beforeCommit: beforeV4Commit)
                try applyV5Migration(connection, beforeCommit: beforeV5Commit)
                try applyV6Migration(connection, beforeCommit: beforeV6Commit)
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
            try applyV3Migration(connection, beforeCommit: beforeV3Commit)
            try applyV4Migration(connection, beforeCommit: beforeV4Commit)
            try initializeV4(connection)
            try applyV5Migration(connection, beforeCommit: beforeV5Commit)
            try applyV6Migration(connection, beforeCommit: beforeV6Commit)
            try connection.execute("COMMIT")
        } catch {
            try? connection.execute("ROLLBACK")
            throw error
        }
    }

    private static func migrateV1ToV6(
        _ connection: SQLiteConnection,
        beforeV2Commit: () throws -> Void,
        beforeV3Commit: () throws -> Void,
        beforeV4Commit: () throws -> Void,
        beforeV5Commit: () throws -> Void,
        beforeV6Commit: () throws -> Void
    ) throws {
        try connection.execute("BEGIN IMMEDIATE")
        do {
            guard let lockedVersion = try connection.querySingleInt("PRAGMA user_version") else {
                throw SQLiteStoreError.invalidState("PRAGMA user_version returned no row")
            }
            if lockedVersion == Int64(SkillSchemaV6.version) {
                try validateV6(connection)
                try connection.execute("COMMIT")
                return
            }
            if lockedVersion == Int64(SkillSchemaV5.version) {
                try validateV5(connection)
                try applyV6Migration(connection, beforeCommit: beforeV6Commit)
                try connection.execute("COMMIT")
                return
            }
            if lockedVersion == Int64(SkillSchemaV4.version) {
                try validateV4(connection)
                try applyV5Migration(connection, beforeCommit: beforeV5Commit)
                try applyV6Migration(connection, beforeCommit: beforeV6Commit)
                try connection.execute("COMMIT")
                return
            }
            if lockedVersion == Int64(SkillSchemaV3.version) {
                try validateV3(connection)
                try applyV4Migration(connection, beforeCommit: beforeV4Commit)
                try applyV5Migration(connection, beforeCommit: beforeV5Commit)
                try applyV6Migration(connection, beforeCommit: beforeV6Commit)
                try connection.execute("COMMIT")
                return
            }
            if lockedVersion == Int64(SkillSchemaV2.version) {
                try validateV2(connection)
                try applyV3Migration(connection, beforeCommit: beforeV3Commit)
                try applyV4Migration(connection, beforeCommit: beforeV4Commit)
                try applyV5Migration(connection, beforeCommit: beforeV5Commit)
                try applyV6Migration(connection, beforeCommit: beforeV6Commit)
                try connection.execute("COMMIT")
                return
            }
            guard lockedVersion == Int64(SkillSchemaV1.version) else {
                throw SQLiteStoreError.invalidState(
                    "schema version changed to unsupported value \(lockedVersion)"
                )
            }
            try validateV1(connection)
            try applyV2Migration(connection, beforeCommit: beforeV2Commit)
            try applyV3Migration(connection, beforeCommit: beforeV3Commit)
            try applyV4Migration(connection, beforeCommit: beforeV4Commit)
            try applyV5Migration(connection, beforeCommit: beforeV5Commit)
            try applyV6Migration(connection, beforeCommit: beforeV6Commit)
            try connection.execute("COMMIT")
        } catch {
            try? connection.execute("ROLLBACK")
            throw error
        }
    }

    private static func migrateV2ToV6(
        _ connection: SQLiteConnection,
        beforeV3Commit: () throws -> Void,
        beforeV4Commit: () throws -> Void,
        beforeV5Commit: () throws -> Void,
        beforeV6Commit: () throws -> Void
    ) throws {
        try connection.execute("BEGIN IMMEDIATE")
        do {
            guard let lockedVersion = try connection.querySingleInt("PRAGMA user_version") else {
                throw SQLiteStoreError.invalidState("PRAGMA user_version returned no row")
            }
            if lockedVersion == Int64(SkillSchemaV6.version) {
                try validateV6(connection)
                try connection.execute("COMMIT")
                return
            }
            if lockedVersion == Int64(SkillSchemaV5.version) {
                try validateV5(connection)
                try applyV6Migration(connection, beforeCommit: beforeV6Commit)
                try connection.execute("COMMIT")
                return
            }
            if lockedVersion == Int64(SkillSchemaV4.version) {
                try validateV4(connection)
                try applyV5Migration(connection, beforeCommit: beforeV5Commit)
                try applyV6Migration(connection, beforeCommit: beforeV6Commit)
                try connection.execute("COMMIT")
                return
            }
            if lockedVersion == Int64(SkillSchemaV3.version) {
                try validateV3(connection)
                try applyV4Migration(connection, beforeCommit: beforeV4Commit)
                try applyV5Migration(connection, beforeCommit: beforeV5Commit)
                try applyV6Migration(connection, beforeCommit: beforeV6Commit)
                try connection.execute("COMMIT")
                return
            }
            guard lockedVersion == Int64(SkillSchemaV2.version) else {
                throw SQLiteStoreError.invalidState(
                    "schema version changed to unsupported value \(lockedVersion)"
                )
            }
            try validateV2(connection)
            try applyV3Migration(connection, beforeCommit: beforeV3Commit)
            try applyV4Migration(connection, beforeCommit: beforeV4Commit)
            try applyV5Migration(connection, beforeCommit: beforeV5Commit)
            try applyV6Migration(connection, beforeCommit: beforeV6Commit)
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

    private static func applyV3Migration(
        _ connection: SQLiteConnection,
        beforeCommit: () throws -> Void
    ) throws {
        for statement in SkillSchemaV3.statements {
            try connection.execute(statement)
        }
        try connection.execute(
            "UPDATE schema_metadata SET schema_version = 3 WHERE singleton = 1"
        )
        try connection.execute("PRAGMA user_version = 3")
        try beforeCommit()
        try validateV3(connection)
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

    static func validateV3(_ connection: SQLiteConnection) throws {
        guard try connection.userTableNames() == SkillSchemaV3.tableNames else {
            throw SQLiteStoreError.invalidState("schema v3 table set is missing or contains unknown tables")
        }
        guard try connection.querySingleInt("PRAGMA user_version") == Int64(SkillSchemaV3.version) else {
            throw SQLiteStoreError.invalidState("PRAGMA user_version does not match schema v3")
        }
        try validateMetadata(connection, version: SkillSchemaV3.version)
        try validateV3Structure(connection)
        try validateV2CleanupRows(connection)
    }

    private static func validateV2Structure(_ connection: SQLiteConnection) throws {
        let schemaObjects = try SkillSchemaInspection.textValues(
            connection,
            sql: "SELECT name FROM sqlite_schema "
                + "WHERE type IN ('index', 'trigger') AND name NOT LIKE 'sqlite_%' ORDER BY name"
        )
        guard schemaObjects == SkillSchemaV2.indexAndTriggerNames else {
            throw SQLiteStoreError.invalidState("schema v2 indexes or triggers do not match")
        }
        guard try SkillSchemaInspection.columnNames(connection, table: "skills") == [
            "skill_id", "display_name", "default_distribution_slug", "default_slug_key",
            "fingerprint_algorithm_version", "content_fingerprint", "status",
            "created_at_ms", "updated_at_ms", "db_revision",
        ], try SkillSchemaInspection.columnNames(connection, table: "skill_operations") == [
            "operation_id", "operation_type", "skill_id", "domain_payload",
            "phase", "outcome",
            "staging_locator", "final_locator", "recovery_locator",
            "old_fingerprint_algorithm_version", "old_content_fingerprint",
            "new_fingerprint_algorithm_version", "new_content_fingerprint",
            "expected_staged_identity", "expected_old_identity", "expected_new_identity",
            "expected_db_revision", "expected_root_identity", "cleanup_state",
            "cleanup_debt_id", "attempt_count", "last_error", "created_at_ms", "updated_at_ms",
        ], try SkillSchemaInspection.columnNames(connection, table: "cleanup_debts") == [
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
        guard try SkillSchemaInspection.schemaFingerprint(
            connection,
            objectNames: SkillSchemaV2.fingerprintedObjectNames
        ) == SkillSchemaInspection.expectedV2SchemaFingerprint() else {
            throw SQLiteStoreError.invalidState("schema v2 SQL fingerprint does not match")
        }
    }

    private static func validateV3Structure(_ connection: SQLiteConnection) throws {
        try validateV3Columns(connection)
        let schemaObjects = try SkillSchemaInspection.textValues(
            connection,
            sql: "SELECT name FROM sqlite_schema "
                + "WHERE type IN ('index', 'trigger') AND name NOT LIKE 'sqlite_%' ORDER BY name"
        )
        guard schemaObjects == SkillSchemaV3.indexAndTriggerNames else {
            throw SQLiteStoreError.invalidState("schema v3 indexes or triggers do not match")
        }
        guard try connection.querySingleInt(
            "SELECT count(*) FROM pragma_table_list WHERE schema = 'main' AND strict = 1 "
                + "AND name NOT LIKE 'sqlite_%'"
        ) == Int64(SkillSchemaV3.tableNames.count) else {
            throw SQLiteStoreError.invalidState("schema v3 tables must all be STRICT")
        }
        guard try SkillSchemaInspection.schemaFingerprint(
            connection,
            objectNames: SkillSchemaV3.fingerprintedObjectNames
        ) == SkillSchemaInspection.expectedV3SchemaFingerprint() else {
            throw SQLiteStoreError.invalidState("schema v3 SQL fingerprint does not match")
        }
    }

    static func validateV3Columns(_ connection: SQLiteConnection) throws {
        guard try SkillSchemaInspection.columnNames(connection, table: "custom_paths") == [
            "custom_path_id", "absolute_url", "normalized_url_key", "display_name", "added_at_ms",
        ], try SkillSchemaInspection.columnNames(connection, table: "legacy_publish_states") == [
            "legacy_locator", "legacy_format_version", "file_digest", "last_published_hash",
            "last_published_at_ms", "hash_algorithm_version", "binding_status", "bound_skill_id",
            "bound_at_ms", "migrated_at_ms",
        ], try SkillSchemaInspection.columnNames(connection, table: "publish_states") == [
            "runtime_locator", "source_legacy_locator", "last_published_hash",
            "last_published_at_ms", "hash_algorithm_version",
        ], try SkillSchemaInspection.columnNames(connection, table: "legacy_migration_ledger") == [
            "singleton", "migration_version", "status", "inventory_digest",
            "inventory_entry_count", "custom_paths_file_present", "custom_path_count",
            "publish_state_count", "completed_at_ms",
        ] else {
            throw SQLiteStoreError.invalidState("schema v3 columns do not match")
        }
    }

    static func validateV2CleanupRows(_ connection: SQLiteConnection) throws {
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

    static func validateMetadata(
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
        guard version <= Int64(SkillSchemaV6.version) else {
            throw SQLiteStoreError.invalidState("unsupported schema version \(version)")
        }
        return version
    }

}
