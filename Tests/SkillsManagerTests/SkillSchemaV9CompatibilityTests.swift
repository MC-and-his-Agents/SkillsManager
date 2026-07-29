import Foundation
import Testing

@testable import SkillsManager

@Suite("Historical schema v9 compatibility", .serialized)
struct SkillSchemaV9CompatibilityTests {
    enum InjectedFailure: Error {
        case stop
    }

    @Test("normalizes the known early trigger and preserves business rows")
    func migratesKnownEarlySchema() throws {
        try withEarlyV9Database { databaseURL in
            let before = try historicalFacts(at: databaseURL)
            let connection = try SkillSchemaMigrator.open(at: databaseURL)

            #expect(try connection.querySingleInt("PRAGMA user_version") == 14)
            #expect(try connection.querySingleInt(
                "SELECT schema_version FROM schema_metadata"
            ) == 14)
            #expect(try historicalFacts(connection) == before)
            try SkillSchemaMigrator.validateV14(connection)
        }
    }

    @Test(
        "rolls back every trigger normalization failure boundary",
        arguments: [
            SkillSchemaV9CompatibilityCheckpoint.beforeTriggerDrop,
            .afterTriggerDrop,
            .afterTriggerCreate,
        ]
    )
    func rollsBackNormalizationFailure(
        checkpoint target: SkillSchemaV9CompatibilityCheckpoint
    ) throws {
        try withEarlyV9Database { databaseURL in
            let before = try historicalSnapshot(at: databaseURL)

            #expect(throws: InjectedFailure.stop) {
                _ = try SkillSchemaMigrator.open(
                    at: databaseURL,
                    onV9CompatibilityCheckpoint: { checkpoint in
                        if checkpoint == target { throw InjectedFailure.stop }
                    }
                )
            }

            #expect(try historicalSnapshot(at: databaseURL) == before)
        }
    }

    @Test("rejects every unknown v9 fingerprint without writing")
    func rejectsUnknownFingerprint() throws {
        try withEarlyV9Database(unknownFingerprint: true) { databaseURL in
            let before = try historicalSnapshot(at: databaseURL)
            let storageBefore = try databaseStorageSnapshot(at: databaseURL)

            #expect(throws: SQLiteStoreError.self) {
                _ = try SkillSchemaMigrator.open(at: databaseURL)
            }

            #expect(try historicalSnapshot(at: databaseURL) == before)
            #expect(try databaseStorageSnapshot(at: databaseURL) == storageBefore)
        }
    }

    @Test("validates cleanup facts before trigger normalization")
    func rejectsDirtyCleanupBeforeMutation() throws {
        try withEarlyV9Database { databaseURL in
            let connection = try SQLiteConnection(url: databaseURL)
            try insertCleanupFixtureSkill(connection)
            try connection.execute(createOperationInsert())
            try connection.execute("BEGIN IMMEDIATE")
            do {
                try connection.execute(rolledBackPendingUpdate())
                try connection.execute(cleanupDebtInsert())
                try connection.execute("COMMIT")
            } catch {
                try? connection.execute("ROLLBACK")
                throw error
            }
            try connection.execute("PRAGMA foreign_keys = OFF")
            try connection.execute(
                "UPDATE skill_operations SET cleanup_state = 'completed', "
                    + "cleanup_debt_id = NULL, updated_at_ms = 2"
            )
            try connection.execute("PRAGMA foreign_keys = ON")
            var checkpoints: [SkillSchemaV9CompatibilityCheckpoint] = []

            #expect(throws: SQLiteStoreError.self) {
                _ = try SkillSchemaMigrator.open(
                    at: databaseURL,
                    onV9CompatibilityCheckpoint: { checkpoints.append($0) }
                )
            }

            #expect(checkpoints.isEmpty)
        }
    }

}

private struct HistoricalV9Snapshot: Equatable {
    let fingerprint: Data
    let userVersion: Int64?
    let metadataVersion: Int64?
    let facts: [String]
}

private struct DatabaseStorageSnapshot: Equatable {
    let databaseBytes: Data
    let journalMode: String?
    let walExists: Bool
    let sharedMemoryExists: Bool
}

private func databaseStorageSnapshot(at databaseURL: URL) throws -> DatabaseStorageSnapshot {
    let connection = try SQLiteConnection(url: databaseURL, accessMode: .readOnly)
    let fileManager = FileManager.default
    return DatabaseStorageSnapshot(
        databaseBytes: try Data(contentsOf: databaseURL),
        journalMode: try connection.querySingleText("PRAGMA journal_mode"),
        walExists: fileManager.fileExists(atPath: databaseURL.path + "-wal"),
        sharedMemoryExists: fileManager.fileExists(atPath: databaseURL.path + "-shm")
    )
}

private func historicalSnapshot(at databaseURL: URL) throws -> HistoricalV9Snapshot {
    let connection = try SQLiteConnection(url: databaseURL, accessMode: .readOnly)
    return HistoricalV9Snapshot(
        fingerprint: try SkillSchemaInspection.schemaFingerprint(
            connection,
            objectNames: SkillSchemaV9.fingerprintedObjectNames
        ),
        userVersion: try connection.querySingleInt("PRAGMA user_version"),
        metadataVersion: try connection.querySingleInt(
            "SELECT schema_version FROM schema_metadata"
        ),
        facts: try historicalFacts(connection)
    )
}

private func historicalFacts(at databaseURL: URL) throws -> [String] {
    try historicalFacts(SQLiteConnection(url: databaseURL, accessMode: .readOnly))
}

private func historicalFacts(_ connection: SQLiteConnection) throws -> [String] {
    try [
        SkillSchemaInspection.textValues(
            connection,
            sql: """
                SELECT hex(skill_id) || '|' || display_name || '|' ||
                  default_distribution_slug || '|' || default_slug_key || '|' ||
                  hex(content_fingerprint) || '|' || status || '|' || db_revision
                FROM skills ORDER BY skill_id
                """
        ),
        SkillSchemaInspection.textValues(
            connection,
            sql: """
                SELECT hex(source_id) || '|' || hex(skill_id) || '|' ||
                  normalized_repository_url || '|' || normalized_subpath || '|' ||
                  revision || '|' || version || '|' || download_url
                FROM sources ORDER BY source_id
                """
        ),
        SkillSchemaInspection.textValues(
            connection,
            sql: """
                SELECT hex(skill_id) || '|' || scope_kind || '|' ||
                  ifnull(adapter_code, '') || '|' || target_scope_key || '|' ||
                  distribution_slug || '|' || slug_key || '|' || sync_mode
                FROM distribution_bindings ORDER BY skill_id, target_scope_key
                """
        ),
        SkillSchemaInspection.textValues(
            connection,
            sql: """
                SELECT hex(backup_id) || '|' || hex(original_skill_id) || '|' ||
                  state || '|' || locator || '|' || hex(restored_skill_id) || '|' ||
                  hex(restore_result_json)
                FROM skill_backups ORDER BY backup_id
                """
        ),
        SkillSchemaInspection.textValues(
            connection,
            sql: """
                SELECT hex(operation_id) || '|' || hex(skill_id) || '|' ||
                  hex(backup_id) || '|' || phase || '|' || outcome || '|' ||
                  cleanup_state || '|' || quarantine_locator
                FROM skill_deletion_operations ORDER BY operation_id
                """
        ),
    ].flatMap { $0 }
}

private func withEarlyV9Database(
    unknownFingerprint: Bool = false,
    _ body: (URL) throws -> Void
) throws {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("early-schema-v9-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
    defer { try? FileManager.default.removeItem(at: root) }
    let databaseURL = root.appendingPathComponent("manager.sqlite")

    try createEarlyV9Database(
        at: databaseURL,
        unknownFingerprint: unknownFingerprint,
        includeHistoricalRows: true
    )

    try body(databaseURL)
}

func createEarlyV9Database(
    at databaseURL: URL,
    unknownFingerprint: Bool = false,
    includeHistoricalRows: Bool = false
) throws {
    let connection = try SQLiteConnection(url: databaseURL)
    for statement in SkillSchemaV1.statements { try connection.execute(statement) }
    try connection.execute(
        "INSERT INTO schema_metadata(singleton, schema_version) VALUES (1, 9)"
    )
    for statements in [
        SkillSchemaV2.statements,
        SkillSchemaV3.statements,
        SkillSchemaV4.statements,
        SkillSchemaV5.statements,
        SkillSchemaV6.statements,
        SkillSchemaV7.statements,
        SkillSchemaV8.statements,
        SkillSchemaV9.statements,
    ] {
        for statement in statements {
            if statement == SkillSchemaV9.backupImmutableSnapshotTriggerSQL {
                let trigger = unknownFingerprint
                    ? SkillSchemaV9.earlyBackupImmutableSnapshotTriggerSQL
                        .replacingOccurrences(of: "\nBEGIN", with: "\n  OR 0\nBEGIN")
                    : SkillSchemaV9.earlyBackupImmutableSnapshotTriggerSQL
                try connection.execute(trigger)
            } else {
                try connection.execute(statement)
            }
        }
    }
    try connection.execute("PRAGMA user_version = 9")
    if includeHistoricalRows {
        try insertHistoricalRows(connection)
    }
}

private func insertHistoricalRows(_ connection: SQLiteConnection) throws {
    try connection.execute(
        """
        INSERT INTO skills(
          skill_id, display_name, default_distribution_slug, default_slug_key,
          fingerprint_algorithm_version, content_fingerprint, status,
          created_at_ms, updated_at_ms, db_revision
        ) VALUES (
          X'00112233445566778899aabbccddeeff', 'Historical Skill', 'historical',
          'historical', 1, X'\(String(repeating: "11", count: 32))', 'managed', 1, 2, 3
        )
        """
    )
    try connection.execute(
        """
        INSERT INTO sources(
          source_id, skill_id, normalized_repository_url, normalized_subpath,
          revision, version, download_url
        ) VALUES (
          X'22222222222242228222222222222222',
          X'00112233445566778899aabbccddeeff',
          'https://github.com/example/skills', 'swift', 'abc123', '1.0.0',
          'https://github.com/example/skills/archive/abc123.zip'
        )
        """
    )
    try connection.execute(
        """
        INSERT INTO distribution_bindings(
          skill_id, scope_kind, adapter_code, target_scope_key,
          distribution_slug, slug_key, sync_mode, created_at_ms, updated_at_ms
        ) VALUES (
          X'00112233445566778899aabbccddeeff', 'global', NULL, 'global',
          'historical', 'historical', 'symlink', 1, 2
        )
        """
    )
    try connection.execute(
        """
        INSERT INTO skill_backups(
          backup_id, format_version, original_skill_id, state, locator,
          directory_identity, manifest_digest, fingerprint_algorithm_version,
          content_fingerprint, pinned, restored_skill_id, restore_result_json,
          created_at_ms, updated_at_ms
        ) VALUES (
          X'33333333333343338333333333333333', 1,
          X'00112233445566778899aabbccddeeff', 'available', 'backup/historical',
          X'\(String(repeating: "22", count: 32))',
          X'\(String(repeating: "33", count: 32))', 1,
          X'\(String(repeating: "44", count: 32))', 1,
          X'44444444444444448444444444444444', X'7b22726573746f726564223a747275657d',
          1, 2
        )
        """
    )
    try connection.execute(
        """
        INSERT INTO skill_deletion_operations(
          operation_id, format_version, skill_id, backup_id, phase, outcome,
          cleanup_state, domain_payload, expectation_payload, distribution_plan,
          ssot_identity, quarantine_locator, attempt_count, created_at_ms, updated_at_ms
        ) VALUES (
          X'55555555555545558555555555555555', 1,
          X'00112233445566778899aabbccddeeff',
          X'33333333333343338333333333333333',
          'prepared', 'pending', 'notApplicable', X'7b7d', X'7b7d', X'7b7d',
          X'\(String(repeating: "55", count: 32))', 'quarantine/historical', 0, 1, 2
        )
        """
    )
}

private func insertCleanupFixtureSkill(_ connection: SQLiteConnection) throws {
    try connection.execute(
        """
        INSERT INTO skills(
          skill_id, display_name, default_distribution_slug, default_slug_key,
          fingerprint_algorithm_version, content_fingerprint, status,
          created_at_ms, updated_at_ms, db_revision
        ) VALUES (
          \(v2Blob(v2SkillA)), 'Cleanup Fixture', 'cleanup-fixture',
          'cleanup-fixture', 1, \(v2Blob(v2Fingerprint)), 'managed', 1, 1, 0
        )
        """
    )
}
