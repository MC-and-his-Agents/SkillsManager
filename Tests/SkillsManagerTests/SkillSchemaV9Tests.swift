import Foundation
import Testing

@testable import SkillsManager

@Suite("Skill database schema v9", .serialized)
struct SkillSchemaV9Tests {
    @Test("adds durable backup and deletion journal constraints")
    func schemaAndConstraints() throws {
        try withSkillSchemaV9 { connection, _ in
            let tableNames = try connection.userTableNames()
            #expect(tableNames == SkillSchemaV9.tableNames)
            #expect(SkillSchemaV9.version == 9)
            let storedSkillsSQL = try connection.querySingleText(
                "SELECT sql FROM sqlite_schema WHERE type = 'table' AND name = 'skills'"
            )
            let skillsSQL = try #require(storedSkillsSQL)
            #expect(canonicalSchemaSQL(skillsSQL)
                == canonicalSchemaSQL(SkillSchemaV9.expectedSkillsTableSQL))
            #expect(sqlRejected(connection, """
                INSERT INTO skill_backups(
                  backup_id, format_version, original_skill_id, state, locator,
                  directory_identity, manifest_digest, fingerprint_algorithm_version,
                  content_fingerprint, pinned, created_at_ms, updated_at_ms
                ) VALUES (
                  X'00112233445566778899aabbccddeeff', 1,
                  X'11112222333344445555666677778888', 'available', 'safe/path',
                  zeroblob(32), zeroblob(32), 1, zeroblob(32), 0, 2, 1
                )
                """))
            #expect(sqlRejected(connection, """
                INSERT INTO skill_deletion_operations(
                  operation_id, format_version, skill_id, backup_id, phase, outcome,
                  cleanup_state, domain_payload, expectation_payload, distribution_plan,
                  ssot_identity, quarantine_locator, attempt_count, created_at_ms, updated_at_ms
                ) VALUES (
                  X'aaaaaaaa111142228333bbbbbbbbbbbb', 1,
                  X'00112233445566778899aabbccddeeff',
                  X'11112222333344445555666677778888',
                  'completed', 'pending', 'notApplicable',
                  X'7b7d', X'7b7d', X'7b7d', zeroblob(32), 'safe/quarantine', 0, 1, 1
                )
                """))
        }
    }
}

private func canonicalSchemaSQL(_ sql: String) -> String {
    sql.split(whereSeparator: \Character.isWhitespace).joined(separator: " ")
}

func withSkillSchemaV9(
    _ body: (SQLiteConnection, URL) throws -> Void
) throws {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("skill-schema-v9-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
    defer { try? FileManager.default.removeItem(at: root) }
    let connection = try SQLiteConnection(url: root.appendingPathComponent("manager.sqlite"))
    for statement in SkillSchemaV1.statements { try connection.execute(statement) }
    try connection.execute(
        "INSERT INTO schema_metadata(singleton, schema_version) VALUES (1, 1)"
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
        for statement in statements { try connection.execute(statement) }
    }
    try body(connection, root)
}

func sqlRejected(_ connection: SQLiteConnection, _ sql: String) -> Bool {
    do {
        try connection.execute(sql)
        return false
    } catch {
        return true
    }
}
