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
        beforeV7Commit: () throws -> Void = {},
        beforeV8Commit: () throws -> Void = {},
        beforeV9Commit: () throws -> Void = {},
        beforeV10Commit: () throws -> Void = {},
        beforeV11Commit: () throws -> Void = {},
        beforeV12Commit: () throws -> Void = {},
        beforeV13Commit: () throws -> Void = {},
        beforeV14Commit: () throws -> Void = {},
        beforeV15Commit: () throws -> Void = {},
        beforeV16Commit: () throws -> Void = {},
        onV9CompatibilityCheckpoint: (
            SkillSchemaV9CompatibilityCheckpoint
        ) throws -> Void = { _ in },
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
            if try connection.querySingleInt("PRAGMA user_version")
                == Int64(SkillSchemaV9.version) {
                _ = try requiresV9TriggerNormalization(connection)
            }
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
                beforeV7Commit: beforeV7Commit,
                beforeV8Commit: beforeV8Commit,
                beforeV9Commit: beforeV9Commit,
                beforeV10Commit: beforeV10Commit,
                beforeV11Commit: beforeV11Commit,
                beforeV12Commit: beforeV12Commit,
                beforeV13Commit: beforeV13Commit,
                beforeV14Commit: beforeV14Commit,
                beforeV15Commit: beforeV15Commit,
                beforeV16Commit: beforeV16Commit,
                onV9CompatibilityCheckpoint: onV9CompatibilityCheckpoint,
                initializeV4: initializeV4
            )
        case .readOnly:
            try validateV16(connection)
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
        beforeV7Commit: () throws -> Void = {},
        beforeV8Commit: () throws -> Void = {},
        beforeV9Commit: () throws -> Void = {},
        beforeV10Commit: () throws -> Void = {},
        beforeV11Commit: () throws -> Void = {},
        beforeV12Commit: () throws -> Void = {},
        beforeV13Commit: () throws -> Void = {},
        beforeV14Commit: () throws -> Void = {},
        beforeV15Commit: () throws -> Void = {},
        beforeV16Commit: () throws -> Void = {},
        onV9CompatibilityCheckpoint: (
            SkillSchemaV9CompatibilityCheckpoint
        ) throws -> Void = { _ in },
        initializeV4: (SQLiteConnection) throws -> Void = { _ in }
    ) throws {
        guard connection.accessMode != .readOnly else {
            throw SQLiteStoreError.invalidState("schema migration requires read-write access")
        }
        let rawVersion = try admittedSchemaVersion(connection)

        if rawVersion == 0 {
            try afterInitialV0Read()
        }
        try migrateToV16(
            connection,
            beforeV1Commit: beforeCommit,
            beforeV2Commit: beforeV2Commit,
            beforeV3Commit: beforeV3Commit,
            beforeV4Commit: beforeV4Commit,
            beforeV5Commit: beforeV5Commit,
            beforeV6Commit: beforeV6Commit,
            beforeV7Commit: beforeV7Commit,
            beforeV8Commit: beforeV8Commit,
            beforeV9Commit: beforeV9Commit,
            beforeV10Commit: beforeV10Commit,
            beforeV11Commit: beforeV11Commit,
            beforeV12Commit: beforeV12Commit,
            beforeV13Commit: beforeV13Commit,
            beforeV14Commit: beforeV14Commit,
            beforeV15Commit: beforeV15Commit,
            beforeV16Commit: beforeV16Commit,
            onV9CompatibilityCheckpoint: onV9CompatibilityCheckpoint,
            initializeV4: initializeV4
        )
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

    private static func migrateToV16(
        _ connection: SQLiteConnection,
        beforeV1Commit: () throws -> Void,
        beforeV2Commit: () throws -> Void,
        beforeV3Commit: () throws -> Void,
        beforeV4Commit: () throws -> Void,
        beforeV5Commit: () throws -> Void,
        beforeV6Commit: () throws -> Void,
        beforeV7Commit: () throws -> Void,
        beforeV8Commit: () throws -> Void,
        beforeV9Commit: () throws -> Void,
        beforeV10Commit: () throws -> Void,
        beforeV11Commit: () throws -> Void,
        beforeV12Commit: () throws -> Void,
        beforeV13Commit: () throws -> Void,
        beforeV14Commit: () throws -> Void,
        beforeV15Commit: () throws -> Void,
        beforeV16Commit: () throws -> Void,
        onV9CompatibilityCheckpoint: (
            SkillSchemaV9CompatibilityCheckpoint
        ) throws -> Void,
        initializeV4: (SQLiteConnection) throws -> Void
    ) throws {
        try connection.execute("BEGIN IMMEDIATE")
        do {
            guard let lockedVersion = try connection.querySingleInt("PRAGMA user_version") else {
                throw SQLiteStoreError.invalidState("PRAGMA user_version returned no row")
            }
            guard (0...SkillSchemaV16.version).contains(Int(lockedVersion)) else {
                throw SQLiteStoreError.invalidState(
                    "schema version changed to unsupported value \(lockedVersion)"
                )
            }
            switch lockedVersion {
            case Int64(SkillSchemaV16.version):
                try validateV16(connection)
            case Int64(SkillSchemaV15.version):
                try validateV15(connection)
            case Int64(SkillSchemaV14.version):
                try validateV14(connection)
            case Int64(SkillSchemaV13.version):
                try validateV13(connection)
            case Int64(SkillSchemaV12.version):
                try validateV12(connection)
            case Int64(SkillSchemaV11.version):
                try validateV11(connection)
            case Int64(SkillSchemaV10.version):
                try validateV10(connection)
            case Int64(SkillSchemaV9.version):
                try normalizeKnownV9Schema(
                    connection,
                    checkpoint: onV9CompatibilityCheckpoint
                )
                try validateV9(connection)
                try applyV10Migration(connection, beforeCommit: beforeV10Commit)
            case Int64(SkillSchemaV8.version):
                try validateV8(connection)
                try applyV9Migration(connection, beforeCommit: beforeV9Commit)
                try applyV10Migration(connection, beforeCommit: beforeV10Commit)
            case Int64(SkillSchemaV7.version):
                try validateV7(connection)
                try applyV8Migration(connection, beforeCommit: beforeV8Commit)
                try applyV9Migration(connection, beforeCommit: beforeV9Commit)
                try applyV10Migration(connection, beforeCommit: beforeV10Commit)
            case Int64(SkillSchemaV6.version):
                try validateV6(connection)
                try applyV7Migration(connection, beforeCommit: beforeV7Commit)
                try applyV8Migration(connection, beforeCommit: beforeV8Commit)
                try applyV9Migration(connection, beforeCommit: beforeV9Commit)
                try applyV10Migration(connection, beforeCommit: beforeV10Commit)
            case Int64(SkillSchemaV5.version):
                try validateV5(connection)
                try applyV6Migration(connection, beforeCommit: beforeV6Commit)
                try applyV7Migration(connection, beforeCommit: beforeV7Commit)
                try applyV8Migration(connection, beforeCommit: beforeV8Commit)
                try applyV9Migration(connection, beforeCommit: beforeV9Commit)
                try applyV10Migration(connection, beforeCommit: beforeV10Commit)
            case Int64(SkillSchemaV4.version):
                try validateV4(connection)
                try applyV5Migration(connection, beforeCommit: beforeV5Commit)
                try applyV6Migration(connection, beforeCommit: beforeV6Commit)
                try applyV7Migration(connection, beforeCommit: beforeV7Commit)
                try applyV8Migration(connection, beforeCommit: beforeV8Commit)
                try applyV9Migration(connection, beforeCommit: beforeV9Commit)
                try applyV10Migration(connection, beforeCommit: beforeV10Commit)
            case Int64(SkillSchemaV3.version):
                try validateV3(connection)
                try applyV4Migration(connection, beforeCommit: beforeV4Commit)
                try applyV5Migration(connection, beforeCommit: beforeV5Commit)
                try applyV6Migration(connection, beforeCommit: beforeV6Commit)
                try applyV7Migration(connection, beforeCommit: beforeV7Commit)
                try applyV8Migration(connection, beforeCommit: beforeV8Commit)
                try applyV9Migration(connection, beforeCommit: beforeV9Commit)
                try applyV10Migration(connection, beforeCommit: beforeV10Commit)
            case Int64(SkillSchemaV2.version):
                try validateV2(connection)
                try applyV3Migration(connection, beforeCommit: beforeV3Commit)
                try applyV4Migration(connection, beforeCommit: beforeV4Commit)
                try applyV5Migration(connection, beforeCommit: beforeV5Commit)
                try applyV6Migration(connection, beforeCommit: beforeV6Commit)
                try applyV7Migration(connection, beforeCommit: beforeV7Commit)
                try applyV8Migration(connection, beforeCommit: beforeV8Commit)
                try applyV9Migration(connection, beforeCommit: beforeV9Commit)
                try applyV10Migration(connection, beforeCommit: beforeV10Commit)
            case Int64(SkillSchemaV1.version):
                try validateV1(connection)
                try applyV2Migration(connection, beforeCommit: beforeV2Commit)
                try applyV3Migration(connection, beforeCommit: beforeV3Commit)
                try applyV4Migration(connection, beforeCommit: beforeV4Commit)
                try applyV5Migration(connection, beforeCommit: beforeV5Commit)
                try applyV6Migration(connection, beforeCommit: beforeV6Commit)
                try applyV7Migration(connection, beforeCommit: beforeV7Commit)
                try applyV8Migration(connection, beforeCommit: beforeV8Commit)
                try applyV9Migration(connection, beforeCommit: beforeV9Commit)
                try applyV10Migration(connection, beforeCommit: beforeV10Commit)
            case 0:
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
                try applyV7Migration(connection, beforeCommit: beforeV7Commit)
                try applyV8Migration(connection, beforeCommit: beforeV8Commit)
                try applyV9Migration(connection, beforeCommit: beforeV9Commit)
                try applyV10Migration(connection, beforeCommit: beforeV10Commit)
            default:
                throw SQLiteStoreError.invalidState(
                    "schema version changed to unsupported value \(lockedVersion)"
                )
            }
            if try connection.querySingleInt("PRAGMA user_version")
                == Int64(SkillSchemaV10.version) {
                try applyV11Migration(connection, beforeCommit: beforeV11Commit)
            }
            if try connection.querySingleInt("PRAGMA user_version")
                == Int64(SkillSchemaV11.version) {
                try applyV12Migration(connection, beforeCommit: beforeV12Commit)
            }
            if try connection.querySingleInt("PRAGMA user_version")
                == Int64(SkillSchemaV12.version) {
                try applyV13Migration(connection, beforeCommit: beforeV13Commit)
            }
            if try connection.querySingleInt("PRAGMA user_version")
                == Int64(SkillSchemaV13.version) {
                try applyV14Migration(connection, beforeCommit: beforeV14Commit)
            }
            if try connection.querySingleInt("PRAGMA user_version")
                == Int64(SkillSchemaV14.version) {
                try applyV15Migration(connection, beforeCommit: beforeV15Commit)
            }
            if try connection.querySingleInt("PRAGMA user_version")
                == Int64(SkillSchemaV15.version) {
                try applyV16Migration(connection, beforeCommit: beforeV16Commit)
            }
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
        guard version <= Int64(SkillSchemaV16.version) else {
            throw SQLiteStoreError.invalidState("unsupported schema version \(version)")
        }
        return version
    }

}
