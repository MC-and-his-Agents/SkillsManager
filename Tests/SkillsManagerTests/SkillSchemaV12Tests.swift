import Foundation
import Testing

@testable import SkillsManager

@Suite("Skill database schema v12", .serialized)
struct SkillSchemaV12Tests {
    enum InjectedFailure: Error {
        case stop
    }

    @Test("migrates v11 atomically and preserves Symlink bindings")
    func migratesAtomically() throws {
        try withV11SchemaDatabase { connection, databaseURL in
            let skillID = SkillID()
            try insertV12TestSkill(skillID, connection: connection)
            try insertV11SymlinkBinding(skillID, connection: connection)
            let operationStore = try DistributionOperationStore(connection: connection)
            let operation = try operationStore.insertPrepared(
                v11OperationDraft(skillID: skillID)
            )

            #expect(throws: InjectedFailure.stop) {
                try SkillSchemaMigrator.migrateIfNeeded(
                    connection,
                    beforeV12Commit: { throw InjectedFailure.stop }
                )
            }
            #expect(try connection.querySingleInt("PRAGMA user_version") == 11)
            #expect(try SkillSchemaInspection.columnNames(
                connection,
                table: "distribution_bindings"
            ).count == 9)
            #expect(try operationStore.load(operation.operationID) == operation)

            try SkillSchemaMigrator.migrateIfNeeded(connection)
            #expect(try connection.querySingleInt("PRAGMA user_version") == 16)
            let binding = try #require(
                DistributionBindingStore(connection: connection).load(skillID: skillID).first
            )
            #expect(binding.syncMode == .symlink)
            #expect(binding.copyBaseline == nil)
            #expect(try connection.querySingleInt(
                "SELECT count(*) FROM distribution_bindings "
                    + "WHERE copy_content_fingerprint IS NOT NULL"
            ) == 0)
            #expect(try operationStore.load(operation.operationID) == operation)

            try SkillSchemaMigrator.migrateIfNeeded(connection)
            let reader = try SkillSchemaMigrator.open(at: databaseURL, accessMode: .readOnly)
            #expect(reader.accessMode == .readOnly)
        }
    }

    @Test("database rejects incomplete Copy ownership and Symlink ownership")
    func rejectsInvalidCopyColumns() throws {
        try withV12SchemaDatabase { connection in
            let skillID = SkillID()
            try insertV12TestSkill(skillID, connection: connection)
            #expect(throws: SQLiteStoreError.self) {
                try connection.execute(
                    """
                    INSERT INTO distribution_bindings(
                      skill_id, scope_kind, adapter_code, target_scope_key,
                      distribution_slug, slug_key, sync_mode,
                      created_at_ms, updated_at_ms
                    ) VALUES (
                      x'\(skillID.bytes.hex)', 'global', NULL, 'global',
                      'copy', 'copy', 'copy', 1, 1
                    )
                    """
                )
            }
            #expect(throws: SQLiteStoreError.self) {
                try connection.execute(
                    """
                    INSERT INTO distribution_bindings(
                      skill_id, scope_kind, adapter_code, target_scope_key,
                      distribution_slug, slug_key, sync_mode,
                      copy_content_algorithm_version, copy_content_fingerprint,
                      copy_tree_algorithm_version, copy_tree_digest,
                      copy_root_identity, copy_entry_identity,
                      copy_applied_operation_id, copy_verified_at_ms,
                      created_at_ms, updated_at_ms
                    ) VALUES (
                      x'\(skillID.bytes.hex)', 'global', NULL, 'global',
                      'link', 'link', 'symlink',
                      1, zeroblob(32), 1, zeroblob(32),
                      zeroblob(32), zeroblob(32), zeroblob(16), 1,
                      1, 1
                    )
                    """
                )
            }
            try connection.execute(
                """
                INSERT INTO distribution_operations(
                  operation_id, format_version, skill_id, phase, outcome,
                  old_bindings, new_bindings, plan_payload, preflight_payload,
                  runtime_payload, forward_cursor, rollback_cursor, cleanup_cursor,
                  attempt_count, created_at_ms, updated_at_ms
                ) VALUES (
                  X'11112222333344445555666677778888', 2,
                  X'\(skillID.bytes.hex)', 'completed', 'applied',
                  X'00', X'00', X'00', X'00', X'00', 0, 0, 0, 0, 1, 1
                )
                """
            )
            try connection.execute(
                """
                INSERT INTO distribution_bindings(
                  skill_id, scope_kind, adapter_code, target_scope_key,
                  distribution_slug, slug_key, sync_mode,
                  created_at_ms, updated_at_ms
                ) VALUES (
                  X'\(skillID.bytes.hex)', 'agent', 'codex', 'agent:codex',
                  'copy', 'copy', 'symlink', 1, 1
                )
                """
            )
            try connection.execute(
                """
                INSERT INTO distribution_bindings(
                  skill_id, scope_kind, adapter_code, target_scope_key,
                  distribution_slug, slug_key, sync_mode,
                  copy_content_algorithm_version, copy_content_fingerprint,
                  copy_tree_algorithm_version, copy_tree_digest,
                  copy_root_identity, copy_entry_identity,
                  copy_provenance_kind, copy_applied_operation_id,
                  copy_verified_at_ms,
                  created_at_ms, updated_at_ms
                ) VALUES (
                  X'\(skillID.bytes.hex)', 'agent', 'claude', 'agent:claude',
                  'copy', 'copy', 'copy',
                  1, zeroblob(32), 1, zeroblob(32),
                  zeroblob(32), zeroblob(32), 'distribution',
                  X'11112222333344445555666677778888', 1, 1, 1
                )
                """
            )
            #expect(throws: DistributionBindingStoreError.corruptRecord) {
                _ = try DistributionBindingStore(connection: connection)
                    .load(skillID: skillID)
            }
        }
    }
}

private func withV11SchemaDatabase(
    _ body: (SQLiteConnection, URL) throws -> Void
) throws {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("skill-schema-v12-v11-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
    defer { try? FileManager.default.removeItem(at: root) }
    let databaseURL = root.appendingPathComponent("manager.sqlite")
    let connection = try SQLiteConnection(url: databaseURL)
    for statement in SkillSchemaV1.statements { try connection.execute(statement) }
    try connection.execute(
        "INSERT INTO schema_metadata(singleton, schema_version) VALUES (1, 11)"
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
        SkillSchemaV10.statements,
        SkillSchemaV11.statements,
    ] {
        for statement in statements { try connection.execute(statement) }
    }
    try connection.execute("PRAGMA user_version = 11")
    try body(connection, databaseURL)
}

private func withV12SchemaDatabase(
    _ body: (SQLiteConnection) throws -> Void
) throws {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("skill-schema-v12-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
    defer { try? FileManager.default.removeItem(at: root) }
    try body(try SkillSchemaMigrator.open(at: root.appendingPathComponent("manager.sqlite")))
}

private func insertV12TestSkill(
    _ skillID: SkillID,
    connection: SQLiteConnection
) throws {
    let statement = try connection.prepare(
        """
        INSERT INTO skills(
          skill_id, display_name, default_distribution_slug, default_slug_key,
          fingerprint_algorithm_version, content_fingerprint, status,
          created_at_ms, updated_at_ms, db_revision
        ) VALUES (?, 'Copy', 'copy', 'copy', 1, zeroblob(32), 'managed', 1, 1, 0)
        """
    )
    try statement.bind(skillID.bytes, at: 1)
    _ = try statement.step()
}

private func insertV11SymlinkBinding(
    _ skillID: SkillID,
    connection: SQLiteConnection
) throws {
    let statement = try connection.prepare(
        """
        INSERT INTO distribution_bindings(
          skill_id, scope_kind, adapter_code, target_scope_key,
          distribution_slug, slug_key, sync_mode, created_at_ms, updated_at_ms
        ) VALUES (?, 'global', NULL, 'global', 'copy', 'copy', 'symlink', 1, 1)
        """
    )
    try statement.bind(skillID.bytes, at: 1)
    _ = try statement.step()
}

private func v11OperationDraft(
    skillID: SkillID
) throws -> DistributionOperationDraft {
    struct Plan: Codable {
        let status: String
        let filesystemActions: [String]
        let bindingsChanged: Bool
        let bindingReplacement: [String]
        let configurationChanged: Bool
        let expectedOldConfigured: Bool
        let desiredConfigured: Bool
        let conflicts: [String]

        enum CodingKeys: String, CodingKey {
            case status
            case filesystemActions = "filesystem_actions"
            case bindingsChanged = "bindings_changed"
            case bindingReplacement = "binding_replacement"
            case configurationChanged = "configuration_changed"
            case expectedOldConfigured = "expected_old_configured"
            case desiredConfigured = "desired_configured"
            case conflicts
        }
    }
    struct Preflight: Codable {
        let actions: [String]
        let ssotIdentity: Data
        let absoluteLinkTarget: String
        let expectedOldConfigured: Bool
        let desiredConfigured: Bool
    }
    var metadata = stat()
    metadata.st_mode = mode_t(S_IFDIR)
    let preflight = Preflight(
        actions: [],
        ssotIdentity: try ManagedItemIdentityCodec.encode(
            ManagedItemIdentity(metadata)
        ),
        absoluteLinkTarget: "/tmp/.SkillsManager/skills/\(skillID.directoryName)",
        expectedOldConfigured: false,
        desiredConfigured: true
    )
    return try DistributionOperationDraft(
        skillID: skillID,
        oldBindings: Data("[]".utf8),
        newBindings: Data("[]".utf8),
        planPayload: try DistributionOperationPayloadCodec.encode(Plan(
            status: "executable",
            filesystemActions: [],
            bindingsChanged: false,
            bindingReplacement: [],
            configurationChanged: true,
            expectedOldConfigured: false,
            desiredConfigured: true,
            conflicts: []
        )),
        preflightPayload: try DistributionOperationPayloadCodec.encode(preflight),
        runtimePayload: Data(#"{"created":[],"removed":[]}"#.utf8),
        createdAtMilliseconds: 1
    )
}

private extension Data {
    var hex: String {
        map { String(format: "%02x", $0) }.joined()
    }
}
