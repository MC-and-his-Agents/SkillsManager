import Foundation

nonisolated struct LegacyMigrationResult: Equatable, Sendable {
    let diagnostics: [LegacyMigrationDiagnostic]

    var archiveChanged: Bool {
        diagnostics.contains { $0.code == .legacyArchiveChanged }
    }

    init(
        diagnostics: [LegacyMigrationDiagnostic],
        archiveChanged: Bool = false
    ) {
        self.diagnostics = diagnostics + (archiveChanged ? [LegacyMigrationDiagnostic(
            code: .legacyArchiveChanged,
            locator: nil
        )] : [])
    }
}

nonisolated enum LegacyMigrationLedgerAdmission {
    struct Record: Equatable, Sendable {
        let digest: Data
        let entryCount: Int64
        let customPathsFilePresent: Bool
        let customPathCount: Int64
        let publishStateCount: Int64
        let completedAtMilliseconds: Int64
    }

    static func read(_ connection: SQLiteConnection) throws -> Record? {
        do {
            let statement = try connection.prepare(
                """
                SELECT singleton, migration_version, status, inventory_digest,
                  inventory_entry_count, custom_paths_file_present, custom_path_count,
                  publish_state_count, completed_at_ms
                FROM legacy_migration_ledger ORDER BY singleton
                """
            )
            guard try statement.step() else { return nil }
            guard statement.int64(at: 0) == 1,
                  statement.int64(at: 1) == 1,
                  statement.text(at: 2) == "completed",
                  let digest = statement.blob(at: 3), digest.count == 32,
                  !statement.isNull(at: 4), !statement.isNull(at: 5),
                  !statement.isNull(at: 6), !statement.isNull(at: 7), !statement.isNull(at: 8) else {
                throw LegacyMigrationFailure(.ledgerInvalid)
            }
            let entryCount = statement.int64(at: 4)
            let present = statement.int64(at: 5)
            let customPathCount = statement.int64(at: 6)
            let publishStateCount = statement.int64(at: 7)
            let completedAt = statement.int64(at: 8)
            guard try !statement.step() else { throw LegacyMigrationFailure(.ledgerInvalid) }
            guard entryCount >= 0, present == 0 || present == 1,
                  customPathCount >= 0, publishStateCount >= 0, completedAt >= 0,
                  entryCount == present + publishStateCount else {
                throw LegacyMigrationFailure(.ledgerInvalid)
            }
            let provenanceCounts = try connection.prepare(
                """
                SELECT
                  (SELECT count(*) FROM legacy_publish_states),
                  (SELECT count(*) FROM publish_states WHERE source_legacy_locator IS NOT NULL)
                """
            )
            guard try provenanceCounts.step(),
                  provenanceCounts.int64(at: 0) == publishStateCount,
                  provenanceCounts.int64(at: 1) == publishStateCount,
                  try !provenanceCounts.step() else {
                throw LegacyMigrationFailure(.ledgerConflict)
            }
            return Record(
                digest: digest,
                entryCount: entryCount,
                customPathsFilePresent: present == 1,
                customPathCount: customPathCount,
                publishStateCount: publishStateCount,
                completedAtMilliseconds: completedAt
            )
        } catch let failure as LegacyMigrationFailure {
            throw failure
        } catch {
            throw mapLegacySQLiteError(error, invalidCode: .ledgerInvalid)
        }
    }

    static func requireCompleted(_ connection: SQLiteConnection) throws -> Record {
        guard let record = try read(connection) else {
            throw LegacyMigrationFailure(.componentNotAdmitted)
        }
        return record
    }
}

nonisolated enum LegacyStateMigrationExecutor {
    static func migrate(
        inventory: LegacyStateInventory,
        connection: SQLiteConnection,
        ownership: SSOTWriterOwnership,
        nowMilliseconds: () throws -> Int64 = { try LegacyDateCodec.milliseconds(from: Date()) },
        beforeCommit: () throws -> Void = {}
    ) throws -> LegacyMigrationResult {
        try LegacyStateInventory.validateOwnership(ownership)
        if let completed = try LegacyMigrationLedgerAdmission.read(connection) {
            return LegacyMigrationResult(
                diagnostics: inventory.diagnostics,
                archiveChanged: completed.digest != inventory.inventoryDigest
            )
        }
        let decoded = try inventory.decode()
        let timestamp = try nowMilliseconds()
        guard timestamp >= 0 else { throw LegacyMigrationFailure(.databaseFailure) }

        do {
            return try connection.withImmediateTransaction {
                if let completed = try LegacyMigrationLedgerAdmission.read(connection) {
                    return LegacyMigrationResult(
                        diagnostics: inventory.diagnostics,
                        archiveChanged: completed.digest != inventory.inventoryDigest
                    )
                }
                try insertCustomPaths(decoded.customPaths, connection: connection)
                try insertPublishStates(
                    decoded.publishStates,
                    migratedAtMilliseconds: timestamp,
                    connection: connection
                )
                try insertLedger(
                    inventory: inventory,
                    decoded: decoded,
                    completedAtMilliseconds: timestamp,
                    connection: connection
                )
                try inventory.validateUnchanged(ownership: ownership)
                _ = try LegacyMigrationLedgerAdmission.requireCompleted(connection)
                try beforeCommit()
                return LegacyMigrationResult(diagnostics: inventory.diagnostics)
            }
        } catch let failure as LegacyMigrationFailure {
            throw failure
        } catch {
            throw mapLegacySQLiteError(error, invalidCode: .databaseFailure)
        }
    }

    private static func insertCustomPaths(
        _ records: [LegacyCustomPathRecord],
        connection: SQLiteConnection
    ) throws {
        let statement = try connection.prepare(
            """
            INSERT INTO custom_paths(
              custom_path_id, absolute_url, normalized_url_key, display_name, added_at_ms
            ) VALUES (?, ?, ?, ?, ?)
            """
        )
        for record in records {
            try statement.bind(catalogUUIDBytes(record.id), at: 1)
            try statement.bind(record.absoluteURL, at: 2)
            try statement.bind(record.normalizedURLKey, at: 3)
            try statement.bind(record.displayName, at: 4)
            try statement.bind(record.addedAtMilliseconds, at: 5)
            guard try !statement.step() else { throw LegacyMigrationFailure(.databaseFailure) }
            try statement.reset()
        }
    }

    private static func insertPublishStates(
        _ records: [LegacyPublishStateRecord],
        migratedAtMilliseconds: Int64,
        connection: SQLiteConnection
    ) throws {
        let staging = try connection.prepare(
            """
            INSERT INTO legacy_publish_states(
              legacy_locator, legacy_format_version, file_digest, last_published_hash,
              last_published_at_ms, hash_algorithm_version, binding_status,
              bound_skill_id, bound_at_ms, migrated_at_ms
            ) VALUES (?, 0, ?, ?, ?, ?, 'unresolved', NULL, NULL, ?)
            """
        )
        let runtime = try connection.prepare(
            """
            INSERT INTO publish_states(
              runtime_locator, source_legacy_locator, last_published_hash,
              last_published_at_ms, hash_algorithm_version
            ) VALUES (?, ?, ?, ?, ?)
            """
        )
        for record in records {
            try staging.bind(record.locator, at: 1)
            try staging.bind(record.fileDigest, at: 2)
            try staging.bind(record.lastPublishedHash, at: 3)
            try staging.bind(record.lastPublishedAtMilliseconds, at: 4)
            try bindOptionalInt(record.hashAlgorithmVersion, to: staging, at: 5)
            try staging.bind(migratedAtMilliseconds, at: 6)
            guard try !staging.step() else { throw LegacyMigrationFailure(.databaseFailure) }
            try staging.reset()

            try runtime.bind(record.locator, at: 1)
            try runtime.bind(record.locator, at: 2)
            try runtime.bind(record.lastPublishedHash, at: 3)
            try runtime.bind(record.lastPublishedAtMilliseconds, at: 4)
            try bindOptionalInt(record.hashAlgorithmVersion, to: runtime, at: 5)
            guard try !runtime.step() else { throw LegacyMigrationFailure(.databaseFailure) }
            try runtime.reset()
        }
    }

    private static func insertLedger(
        inventory: LegacyStateInventory,
        decoded: DecodedLegacyState,
        completedAtMilliseconds: Int64,
        connection: SQLiteConnection
    ) throws {
        let statement = try connection.prepare(
            """
            INSERT INTO legacy_migration_ledger(
              singleton, migration_version, status, inventory_digest, inventory_entry_count,
              custom_paths_file_present, custom_path_count, publish_state_count, completed_at_ms
            ) VALUES (1, 1, 'completed', ?, ?, ?, ?, ?, ?)
            """
        )
        try statement.bind(inventory.inventoryDigest, at: 1)
        try statement.bind(Int64(inventory.entryCount), at: 2)
        try statement.bind(Int64(decoded.customPathsFilePresent ? 1 : 0), at: 3)
        try statement.bind(Int64(decoded.customPaths.count), at: 4)
        try statement.bind(Int64(decoded.publishStates.count), at: 5)
        try statement.bind(completedAtMilliseconds, at: 6)
        guard try !statement.step() else { throw LegacyMigrationFailure(.databaseFailure) }
    }
}

nonisolated enum LegacyStateMigrationGate {
    static func migrateIfNeeded(
        homeURL: URL = FileManager.default.homeDirectoryForCurrentUser,
        connection: SQLiteConnection,
        ownership: SSOTWriterOwnership,
        maximumTotalBytes: Int = 64 * 1_024 * 1_024,
        nowMilliseconds: () throws -> Int64 = { try LegacyDateCodec.milliseconds(from: Date()) }
    ) throws -> LegacyMigrationResult {
        try LegacyStateInventory.validateOwnership(ownership)
        if let completed = try LegacyMigrationLedgerAdmission.read(connection) {
            do {
                let inventory = try LegacyStateInventory.capture(
                    homeURL: homeURL,
                    ownership: ownership,
                    maximumTotalBytes: maximumTotalBytes
                )
                return LegacyMigrationResult(
                    diagnostics: inventory.diagnostics,
                    archiveChanged: completed.digest != inventory.inventoryDigest
                )
            } catch {
                return LegacyMigrationResult(diagnostics: [], archiveChanged: true)
            }
        }
        let inventory = try LegacyStateInventory.capture(
            homeURL: homeURL,
            ownership: ownership,
            maximumTotalBytes: maximumTotalBytes
        )
        return try LegacyStateMigrationExecutor.migrate(
            inventory: inventory,
            connection: connection,
            ownership: ownership,
            nowMilliseconds: nowMilliseconds
        )
    }
}

nonisolated func mapLegacySQLiteError(
    _ error: Error,
    invalidCode: LegacyMigrationErrorCode
) -> LegacyMigrationFailure {
    if let failure = error as? LegacyMigrationFailure { return failure }
    if case SQLiteStoreError.sqlite(_, let code, _) = error {
        let primaryCode = code & 0xff
        if primaryCode == 5 || primaryCode == 6 {
            return LegacyMigrationFailure(.databaseBusy)
        }
    }
    return LegacyMigrationFailure(invalidCode)
}

private nonisolated func bindOptionalInt(
    _ value: Int?,
    to statement: SQLiteStatement,
    at index: Int32
) throws {
    if let value { try statement.bind(Int64(value), at: index) }
    else { try statement.bindNull(at: index) }
}
