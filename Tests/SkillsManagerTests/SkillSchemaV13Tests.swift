import Foundation
import Testing

@testable import SkillsManager

@Suite("Skill database schema v13", .serialized)
struct SkillSchemaV13Tests {
    enum InjectedFailure: Error { case stop }

    @Test("migrates v12 Copy provenance atomically and reopens read-only")
    func migratesV12CopyProvenance() throws {
        try withRawV12Database { connection, databaseURL in
            let skillID = SkillID()
            try insertV13Skill(skillID, connection: connection)
            try insertV12CopyOperationAndBinding(skillID, connection: connection)

            #expect(throws: InjectedFailure.stop) {
                try SkillSchemaMigrator.migrateIfNeeded(
                    connection,
                    beforeV13Commit: { throw InjectedFailure.stop }
                )
            }
            #expect(try connection.querySingleInt("PRAGMA user_version") == 12)
            #expect(try SkillSchemaInspection.columnNames(
                connection,
                table: "distribution_bindings"
            ).contains("copy_provenance_kind") == false)

            try SkillSchemaMigrator.migrateIfNeeded(connection)
            #expect(try connection.querySingleInt("PRAGMA user_version") == 15)
            #expect(try connection.querySingleText(
                "SELECT copy_provenance_kind FROM distribution_bindings"
            ) == "distribution")
            #expect(try connection.querySingleInt(
                "SELECT count(*) FROM distribution_bindings "
                    + "WHERE copy_applied_operation_id = "
                    + "X'11112222333344445555666677778888' "
                    + "AND copy_fork_operation_id IS NULL"
            ) == 1)

            try SkillSchemaMigrator.migrateIfNeeded(connection)
            let reader = try SkillSchemaMigrator.open(
                at: databaseURL,
                accessMode: .readOnly
            )
            #expect(reader.accessMode == .readOnly)
        }
    }

    @Test("enforces exact Copy Fork provenance and lineage relationships")
    func enforcesForkProvenance() throws {
        try withV13Database { connection in
            let parent = SkillID()
            let child = SkillID()
            try insertV13Skill(parent, connection: connection)
            try insertV13Skill(child, connection: connection)
            try insertCompletedCopyFork(
                parent: parent,
                child: child,
                connection: connection
            )
            try connection.execute(
                v13CopyForkBindingSQL(child: child, slug: "fork")
            )
            #expect(try connection.querySingleInt(
                "SELECT count(*) FROM distribution_bindings "
                    + "WHERE copy_provenance_kind = 'copyFork'"
            ) == 1)
            #expect(throws: SQLiteStoreError.self) {
                try connection.execute(
                    v13CopyForkBindingSQL(
                        child: child,
                        slug: "Fork",
                        scope: "agent:codex"
                    )
                )
            }
            #expect(throws: SQLiteStoreError.self) {
                try connection.execute(
                    """
                    INSERT INTO skill_fork_lineage(
                      fork_skill_id, parent_skill_id,
                      forked_from_algorithm_version, forked_from_hash,
                      created_at_ms, origin_type
                    ) VALUES (
                      X'\(child.bytes.hex)', X'\(child.bytes.hex)',
                      1, zeroblob(32), 1, 'local-fork'
                    )
                    """
                )
            }
            try connection.execute(
                """
                INSERT INTO skill_fork_lineage(
                  fork_skill_id, parent_skill_id,
                  forked_from_algorithm_version, forked_from_hash,
                  created_at_ms, origin_type
                ) VALUES (
                  X'\(child.bytes.hex)', X'\(parent.bytes.hex)',
                  1, zeroblob(32), 1, 'local-fork'
                )
                """
            )
            try connection.execute(
                "DELETE FROM distribution_bindings WHERE skill_id = X'\(child.bytes.hex)'"
            )
            try connection.execute(
                "DELETE FROM skills WHERE skill_id = X'\(parent.bytes.hex)'"
            )
            #expect(try connection.querySingleInt(
                "SELECT count(*) FROM skill_fork_lineage "
                    + "WHERE fork_skill_id = X'\(child.bytes.hex)'"
            ) == 1)
            try connection.execute(
                "DELETE FROM skills WHERE skill_id = X'\(child.bytes.hex)'"
            )
            #expect(try connection.querySingleInt(
                "SELECT count(*) FROM skill_fork_lineage"
            ) == 0)
        }
    }
}

private func withRawV12Database(
    _ body: (SQLiteConnection, URL) throws -> Void
) throws {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("skill-schema-v13-v12-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
    defer { try? FileManager.default.removeItem(at: root) }
    let databaseURL = root.appendingPathComponent("manager.sqlite")
    let connection = try SQLiteConnection(url: databaseURL)
    for statement in SkillSchemaV1.statements { try connection.execute(statement) }
    try connection.execute(
        "INSERT INTO schema_metadata(singleton, schema_version) VALUES (1, 11)"
    )
    for statements in [
        SkillSchemaV2.statements, SkillSchemaV3.statements, SkillSchemaV4.statements,
        SkillSchemaV5.statements, SkillSchemaV6.statements, SkillSchemaV7.statements,
        SkillSchemaV8.statements, SkillSchemaV9.statements, SkillSchemaV10.statements,
        SkillSchemaV11.statements,
    ] {
        for statement in statements { try connection.execute(statement) }
    }
    try connection.execute("PRAGMA user_version = 11")
    try connection.withImmediateTransaction {
        try SkillSchemaMigrator.applyV12Migration(connection, beforeCommit: {})
    }
    try body(connection, databaseURL)
}

private func withV13Database(_ body: (SQLiteConnection) throws -> Void) throws {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("skill-schema-v13-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
    defer { try? FileManager.default.removeItem(at: root) }
    try body(try SkillSchemaMigrator.open(at: root.appendingPathComponent("manager.sqlite")))
}

private func insertV13Skill(
    _ skillID: SkillID,
    connection: SQLiteConnection
) throws {
    try connection.execute(
        """
        INSERT INTO skills(
          skill_id, display_name, default_distribution_slug, default_slug_key,
          fingerprint_algorithm_version, content_fingerprint, status,
          created_at_ms, updated_at_ms, db_revision
        ) VALUES (
          X'\(skillID.bytes.hex)', 'Fork', 'fork', 'fork',
          1, zeroblob(32), 'managed', 1, 1, 0
        )
        """
    )
}

private func insertV12CopyOperationAndBinding(
    _ skillID: SkillID,
    connection: SQLiteConnection
) throws {
    try connection.execute(
        """
        INSERT INTO distribution_operations(
          operation_id, format_version, skill_id, phase, outcome,
          old_bindings, new_bindings, plan_payload, preflight_payload,
          runtime_payload, forward_cursor, rollback_cursor, cleanup_cursor,
          attempt_count, created_at_ms, updated_at_ms
        ) VALUES (
          X'11112222333344445555666677778888', 2, X'\(skillID.bytes.hex)',
          'completed', 'applied', X'00', X'00', X'00', X'00', X'00',
          0, 0, 0, 0, 1, 1
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
          copy_applied_operation_id, copy_verified_at_ms,
          created_at_ms, updated_at_ms
        ) VALUES (
          X'\(skillID.bytes.hex)', 'global', NULL, 'global', 'fork', 'fork', 'copy',
          1, zeroblob(32), 1, zeroblob(32), zeroblob(32), zeroblob(32),
          X'11112222333344445555666677778888', 1, 1, 1
        )
        """
    )
}

private func insertCompletedCopyFork(
    parent: SkillID,
    child: SkillID,
    connection: SQLiteConnection
) throws {
    try connection.execute(
        """
        INSERT INTO copy_fork_operations(
          operation_id, parent_skill_id, child_skill_id, parent_revision,
          scope_kind, adapter_code, target_scope_key, distribution_slug, slug_key,
          parent_copy_provenance_kind, parent_provenance_operation_id,
          parent_content_algorithm_version, parent_content_fingerprint,
          parent_tree_algorithm_version, parent_tree_digest,
          parent_root_identity, parent_entry_identity, parent_verified_at_ms,
          parent_binding_created_at_ms, parent_binding_updated_at_ms,
          observed_content_algorithm_version, observed_content_fingerprint,
          observed_tree_algorithm_version, observed_tree_digest,
          observed_root_identity, observed_entry_identity, preview_payload,
          phase, outcome, verified_at_ms, attempt_count,
          created_at_ms, updated_at_ms
        ) VALUES (
          X'99992222333344445555666677778888',
          X'\(parent.bytes.hex)', X'\(child.bytes.hex)', 0,
          'global', NULL, 'global', 'fork', 'fork',
          'distribution', X'11112222333344445555666677778888',
          1, zeroblob(32), 1, zeroblob(32), zeroblob(32), zeroblob(32), 1, 1, 1,
          1, zeroblob(32), 1, zeroblob(32), zeroblob(32), zeroblob(32), X'7b7d',
          'completed', 'applied', 2, 0, 1, 2
        )
        """
    )
}

private func v13CopyForkBindingSQL(
    child: SkillID,
    slug: String,
    scope: String = "global"
) -> String {
    let scopeColumns = scope == "global"
        ? "'global', NULL, 'global'"
        : "'agent', 'codex', 'agent:codex'"
    return """
    INSERT INTO distribution_bindings(
      skill_id, scope_kind, adapter_code, target_scope_key,
      distribution_slug, slug_key, sync_mode,
      copy_content_algorithm_version, copy_content_fingerprint,
      copy_tree_algorithm_version, copy_tree_digest,
      copy_root_identity, copy_entry_identity,
      copy_provenance_kind, copy_fork_operation_id, copy_verified_at_ms,
      created_at_ms, updated_at_ms
    ) VALUES (
      X'\(child.bytes.hex)', \(scopeColumns), '\(slug)', 'fork', 'copy',
      1, zeroblob(32), 1, zeroblob(32), zeroblob(32), zeroblob(32),
      'copyFork', X'99992222333344445555666677778888', 2, 2, 2
    )
    """
}

private extension Data {
    var hex: String { map { String(format: "%02x", $0) }.joined() }
}
