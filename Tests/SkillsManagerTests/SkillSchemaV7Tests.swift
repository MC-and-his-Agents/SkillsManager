import Foundation
import Testing

@testable import SkillsManager

@Suite("Skill database schema v7", .serialized)
struct SkillSchemaV7Tests {
    @Test("migrates every supported schema version to v7")
    func migratesEverySupportedVersion() throws {
        for version in 0...6 {
            let location = try v7DatabaseLocation("migrate-\(version)")
            defer { try? FileManager.default.removeItem(at: location.root) }
            try createV7MigrationFixture(version: version, at: location.database)

            let migrated = try SkillSchemaMigrator.open(at: location.database)
            #expect(try migrated.querySingleInt("PRAGMA user_version") == 7)
            #expect(try migrated.querySingleInt(
                "SELECT schema_version FROM schema_metadata WHERE singleton = 1"
            ) == 7)
            #expect(try migrated.userTableNames() == SkillSchemaV7.tableNames)
        }
    }

    @Test("v7 checkpoint failure rolls back the full migration")
    func v7CheckpointRollsBack() throws {
        enum InjectedFailure: Error { case stop }

        for version in 0...6 {
            let location = try v7DatabaseLocation("rollback-\(version)")
            defer { try? FileManager.default.removeItem(at: location.root) }
            try createV7MigrationFixture(version: version, at: location.database)

            #expect(throws: InjectedFailure.self) {
                _ = try SkillSchemaMigrator.open(
                    at: location.database,
                    beforeV7Commit: { throw InjectedFailure.stop }
                )
            }

            let rolledBack = try SQLiteConnection(url: location.database)
            #expect(try rolledBack.querySingleInt("PRAGMA user_version") == Int64(version))
            #expect(
                try rolledBack.userTableNames()
                    == (version == 0
                        ? []
                        : version == 1 ? SkillSchemaV1.tableNames
                        : version == 2 ? SkillSchemaV2.tableNames
                        : version == 3 ? SkillSchemaV3.tableNames
                        : version == 4 ? SkillSchemaV4.tableNames
                        : version == 5 ? SkillSchemaV5.tableNames
                        : SkillSchemaV6.tableNames)
            )
        }
    }

    @Test("v7 validates on read-only reopen")
    func readOnlyReopen() throws {
        let location = try v7DatabaseLocation("read-only")
        defer { try? FileManager.default.removeItem(at: location.root) }
        _ = try SkillSchemaMigrator.open(at: location.database)

        let reader = try SkillSchemaMigrator.open(
            at: location.database,
            accessMode: .readOnly
        )
        #expect(reader.accessMode == .readOnly)
        #expect(try reader.querySingleInt("PRAGMA user_version") == 7)
        #expect(try reader.userTableNames() == SkillSchemaV7.tableNames)
    }

    @Test("v7 operation and ownership constraints fail closed")
    func operationAndOwnershipConstraints() throws {
        let location = try v7DatabaseLocation("constraints")
        defer { try? FileManager.default.removeItem(at: location.root) }
        let connection = try SkillSchemaMigrator.open(at: location.database)
        #expect(try connection.querySingleInt("PRAGMA foreign_keys") == 1)
        try connection.execute(v7SkillInsert())
        try connection.execute(v7SkillInsert(id: v7SkillB, slug: "other"))
        try connection.execute(v7BindingInsert())

        #expect(v7SQLIsRejected(connection, v7OperationInsert(skillID: v7UnknownSkill)))
        #expect(v7SQLIsRejected(connection, v7OperationInsert(formatVersion: 2)))
        #expect(v7SQLIsRejected(connection, v7OperationInsert(phase: "unknown")))
        #expect(v7SQLIsRejected(connection, v7OperationInsert(outcome: "unknown")))
        #expect(v7SQLIsRejected(connection, v7OperationInsert(forwardCursor: -1)))
        #expect(v7SQLIsRejected(connection, v7OperationInsert(lastError: String(repeating: "x", count: 4097))))
        #expect(v7SQLIsRejected(connection, v7OperationInsert(payloadSize: 65537)))
        #expect(v7SQLIsRejected(connection, v7OperationInsert(
            phase: "completed", outcome: nil
        )))

        try connection.execute(v7OperationInsert())
        #expect(v7SQLIsRejected(connection, v7OperationInsert()))
        try connection.execute(v7OperationInsert(
            operationID: v7OperationB,
            skillID: v7SkillB,
            phase: "completed",
            outcome: "applied"
        ))
        try connection.execute(v7OperationInsert(
            operationID: v7OperationC,
            skillID: v7SkillB
        ))

        #expect(v7SQLIsRejected(connection, v7OwnershipInsert(
            skillID: v7UnknownSkill
        )))
        #expect(v7SQLIsRejected(connection, v7OwnershipInsert(
            targetKey: "agent:codex"
        )))
        #expect(v7SQLIsRejected(connection, v7OwnershipInsert(
            appliedOperationID: v7OperationD
        )))
        try connection.execute(v7OwnershipInsert())
        #expect(v7SQLIsRejected(connection, v7OwnershipInsert()))
        #expect(try connection.querySingleInt(
            "SELECT count(*) FROM distribution_link_ownership"
        ) == 1)
    }
}

private let v7SkillA = "00112233445566778899aabbccddeeff"
private let v7SkillB = "11112222333344445555666677778888"
private let v7UnknownSkill = "9999aaaabbbb4ccc8dddeeeeffff0000"
private let v7OperationA = "aaaaaaaa111142228333bbbbbbbbbbbb"
private let v7OperationB = "bbbbbbbb222243338444cccccccccccc"
private let v7OperationC = "cccccccc333354449555dddddddddddd"
private let v7OperationD = "dddddddd44446555a666eeeeeeeeeeee"
private let v7Fingerprint = String(repeating: "ab", count: 32)
private let v7Identity = String(repeating: "cd", count: 32)
private let v7Payload = "7b7d"

private func v7DatabaseLocation(_ suffix: String) throws -> (root: URL, database: URL) {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent(
            "skillsmanager-v7-\(suffix)-\(UUID().uuidString)",
            isDirectory: true
        )
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
    return (root, root.appendingPathComponent("manager.sqlite"))
}

private func createV7MigrationFixture(version: Int, at url: URL) throws {
    guard version > 0 else { return }
    let connection = try SQLiteConnection(url: url)
    try connection.setJournalModeWAL()
    try connection.execute("BEGIN IMMEDIATE")
    do {
        for statement in SkillSchemaV1.statements {
            try connection.execute(statement)
        }
        try connection.execute(
            "INSERT INTO schema_metadata(singleton, schema_version) VALUES (1, 1)"
        )
        if version >= 2 {
            for statement in SkillSchemaV2.statements {
                try connection.execute(statement)
            }
        }
        if version >= 3 {
            for statement in SkillSchemaV3.statements {
                try connection.execute(statement)
            }
        }
        if version >= 4 {
            for statement in SkillSchemaV4.statements {
                try connection.execute(statement)
            }
        }
        if version >= 5 {
            for statement in SkillSchemaV5.statements {
                try connection.execute(statement)
            }
        }
        if version >= 6 {
            for statement in SkillSchemaV6.statements {
                try connection.execute(statement)
            }
        }
        try connection.execute(
            "UPDATE schema_metadata SET schema_version = \(version) WHERE singleton = 1"
        )
        try connection.execute("PRAGMA user_version = \(version)")
        try connection.execute("COMMIT")
    } catch {
        try? connection.execute("ROLLBACK")
        throw error
    }
}

private func v7SkillInsert(
    id: String = v7SkillA,
    slug: String = "demo"
) -> String {
    """
    INSERT INTO skills(
      skill_id, display_name, default_distribution_slug, default_slug_key,
      fingerprint_algorithm_version, content_fingerprint, status,
      created_at_ms, updated_at_ms, db_revision
    ) VALUES (
      X'\(id)', 'Demo', '\(slug)', '\(slug)', 1, X'\(v7Fingerprint)',
      'managed', 0, 0, 0
    )
    """
}

private func v7BindingInsert() -> String {
    """
    INSERT INTO distribution_bindings(
      skill_id, scope_kind, adapter_code, target_scope_key,
      distribution_slug, slug_key, sync_mode, created_at_ms, updated_at_ms
    ) VALUES (
      X'\(v7SkillA)', 'global', NULL, 'global',
      'demo', 'demo', 'symlink', 1, 1
    )
    """
}

private func v7OperationInsert(
    operationID: String = v7OperationA,
    formatVersion: Int = 1,
    skillID: String = v7SkillA,
    phase: String = "prepared",
    outcome: String? = nil,
    payloadSize: Int = 2,
    forwardCursor: Int = 0,
    lastError: String? = nil
) -> String {
    let outcomeSQL = outcome.map { "'\($0)'" } ?? "NULL"
    let payload = String(repeating: "ab", count: payloadSize)
    let errorSQL = lastError.map { "'\($0)'" } ?? "NULL"
    return """
    INSERT INTO distribution_operations(
      operation_id, format_version, skill_id, phase, outcome,
      old_bindings, new_bindings, plan_payload, preflight_payload, runtime_payload,
      forward_cursor, rollback_cursor, cleanup_cursor, attempt_count, last_error,
      created_at_ms, updated_at_ms
    ) VALUES (
      X'\(operationID)', \(formatVersion), X'\(skillID)', '\(phase)', \(outcomeSQL),
      X'\(payload)', X'\(payload)', X'\(payload)', X'\(payload)', X'\(payload)',
      \(forwardCursor), 0, 0, 0, \(errorSQL), 1, 1
    )
    """
}

private func v7OwnershipInsert(
    skillID: String = v7SkillA,
    targetKey: String = "global",
    appliedOperationID: String = v7OperationA
) -> String {
    """
    INSERT INTO distribution_link_ownership(
      skill_id, target_scope_key, applied_operation_id,
      root_identity, entry_identity, absolute_link_target, verified_at_ms
    ) VALUES (
      X'\(skillID)', '\(targetKey)', X'\(appliedOperationID)',
      X'\(v7Identity)', X'\(v7Identity)', '/Users/test/.SkillsManager/skills/demo', 1
    )
    """
}

private func v7SQLIsRejected(_ connection: SQLiteConnection, _ sql: String) -> Bool {
    do {
        try connection.execute(sql)
        return false
    } catch {
        return true
    }
}
