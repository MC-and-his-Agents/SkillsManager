import Foundation
import Testing

@testable import SkillsManager

@Suite("Skill database schema v6")
struct SkillSchemaV6Tests {
    @Test("migrates every supported schema version to v6")
    func migratesEverySupportedVersion() throws {
        for version in 0...5 {
            let location = try v6DatabaseLocation("migrate-\(version)")
            defer { try? FileManager.default.removeItem(at: location.root) }
            try createV6MigrationFixture(version: version, at: location.database)

            let migrated = try SkillSchemaMigrator.open(at: location.database)
            #expect(try migrated.querySingleInt("PRAGMA user_version") == 6)
            #expect(try migrated.querySingleInt(
                "SELECT schema_version FROM schema_metadata WHERE singleton = 1"
            ) == 6)
            #expect(try migrated.userTableNames() == SkillSchemaV6.tableNames)
        }
    }

    @Test("v6 checkpoint failure rolls v0 and v5 back completely")
    func v6CheckpointRollsBack() throws {
        enum InjectedFailure: Error { case stop }

        for version in [0, 5] {
            let location = try v6DatabaseLocation("rollback-\(version)")
            defer { try? FileManager.default.removeItem(at: location.root) }
            try createV6MigrationFixture(version: version, at: location.database)
            if version == 5 {
                try SQLiteConnection(url: location.database).execute(v6SkillInsert(id: v6SkillA))
            }

            #expect(throws: InjectedFailure.self) {
                _ = try SkillSchemaMigrator.open(
                    at: location.database,
                    beforeV6Commit: { throw InjectedFailure.stop }
                )
            }

            let rolledBack = try SQLiteConnection(url: location.database)
            #expect(try rolledBack.querySingleInt("PRAGMA user_version") == Int64(version))
            #expect(
                try rolledBack.userTableNames()
                    == (version == 0 ? [] : SkillSchemaV5.tableNames)
            )
            if version == 5 {
                #expect(try rolledBack.querySingleInt("SELECT count(*) FROM skills") == 1)
            }
        }
    }

    @Test("v6 validates on read-only reopen")
    func readOnlyReopen() throws {
        let location = try v6DatabaseLocation("read-only")
        defer { try? FileManager.default.removeItem(at: location.root) }
        _ = try SkillSchemaMigrator.open(at: location.database)

        let reader = try SkillSchemaMigrator.open(
            at: location.database,
            accessMode: .readOnly
        )
        #expect(reader.accessMode == .readOnly)
        #expect(try reader.querySingleInt("PRAGMA user_version") == 6)
        #expect(try reader.userTableNames() == SkillSchemaV6.tableNames)
    }

    @Test("distribution binding constraints fail closed")
    func bindingConstraints() throws {
        let location = try v6DatabaseLocation("constraints")
        defer { try? FileManager.default.removeItem(at: location.root) }
        let connection = try SkillSchemaMigrator.open(at: location.database)
        try connection.execute(v6SkillInsert(id: v6SkillA))
        try connection.execute(v6SkillInsert(id: v6SkillB, slug: "other"))

        #expect(v6SQLIsRejected(connection, v6BindingInsert(skillID: v6UnknownSkill)))
        #expect(v6SQLIsRejected(connection, v6BindingInsert(scope: "unknown")))
        #expect(v6SQLIsRejected(connection, v6BindingInsert(adapter: "codex")))
        #expect(v6SQLIsRejected(connection, v6BindingInsert(
            scope: "agent",
            adapter: "unknown",
            targetKey: "agent:unknown"
        )))
        #expect(v6SQLIsRejected(connection, v6BindingInsert(
            scope: "agent",
            adapter: "codex",
            targetKey: "agent:claude"
        )))
        #expect(v6SQLIsRejected(connection, v6BindingInsert(syncMode: "copy")))
        #expect(v6SQLIsRejected(connection, v6BindingInsert(
            slug: String(repeating: "a", count: 201)
        )))
        #expect(v6SQLIsRejected(connection, v6BindingInsert(
            slugKey: String(repeating: "a", count: 801)
        )))
        #expect(v6SQLIsRejected(connection, v6BindingInsert(createdAt: -1, updatedAt: 0)))
        #expect(v6SQLIsRejected(connection, v6BindingInsert(createdAt: 2, updatedAt: 1)))

        try connection.execute(v6BindingInsert())
        #expect(v6SQLIsRejected(connection, v6BindingInsert(
            scope: "agent",
            adapter: "codex",
            targetKey: "agent:codex"
        )))
        #expect(v6SQLIsRejected(connection, v6BindingInsert(
            skillID: v6SkillB
        )))
        try connection.execute(v6BindingInsert(
            skillID: v6SkillB,
            scope: "agent",
            adapter: "codex",
            targetKey: "agent:codex"
        ))
        try connection.execute(v6BindingInsert(
            skillID: v6SkillB,
            scope: "agent",
            adapter: "claude",
            targetKey: "agent:claude"
        ))
        try connection.execute(v6BindingInsert(
            skillID: v6SkillB,
            scope: "agent",
            adapter: "opencode",
            targetKey: "agent:opencode",
            slug: String(repeating: "s", count: 200),
            slugKey: String(repeating: "k", count: 800)
        ))
        #expect(v6SQLIsRejected(
            connection,
            """
            UPDATE distribution_bindings
            SET scope_kind = 'global', adapter_code = NULL, target_scope_key = 'global',
                distribution_slug = 'other', slug_key = 'other'
            WHERE skill_id = X'\(v6SkillB)' AND target_scope_key = 'agent:codex'
            """
        ))

        #expect(v6SQLIsRejected(
            connection,
            "UPDATE distribution_bindings SET created_at_ms = 0 "
                + "WHERE skill_id = X'\(v6SkillA)'"
        ))
        try connection.execute(
            "UPDATE distribution_bindings SET updated_at_ms = 2 "
                + "WHERE skill_id = X'\(v6SkillA)'"
        )
        #expect(v6SQLIsRejected(
            connection,
            "UPDATE distribution_bindings SET updated_at_ms = 1 "
                + "WHERE skill_id = X'\(v6SkillA)'"
        ))
        try connection.execute(
            "UPDATE distribution_bindings SET updated_at_ms = 3 "
                + "WHERE skill_id = X'\(v6SkillA)'"
        )

        try connection.execute("DELETE FROM skills WHERE skill_id = X'\(v6SkillB)'")
        #expect(try connection.querySingleInt(
            "SELECT count(*) FROM distribution_bindings WHERE skill_id = X'\(v6SkillB)'"
        ) == 0)
    }
}

private let v6SkillA = "00112233445566778899aabbccddeeff"
private let v6SkillB = "11112222333344445555666677778888"
private let v6UnknownSkill = "9999aaaabbbb4ccc8dddeeeeffff0000"
private let v6Fingerprint = String(repeating: "ab", count: 32)

private func v6DatabaseLocation(_ suffix: String) throws -> (root: URL, database: URL) {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent(
            "skillsmanager-v6-\(suffix)-\(UUID().uuidString)",
            isDirectory: true
        )
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
    return (root, root.appendingPathComponent("manager.sqlite"))
}

private func createV6MigrationFixture(version: Int, at url: URL) throws {
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

private func v6SkillInsert(id: String, slug: String = "demo") -> String {
    """
    INSERT INTO skills(
      skill_id, display_name, default_distribution_slug, default_slug_key,
      fingerprint_algorithm_version, content_fingerprint, status,
      created_at_ms, updated_at_ms, db_revision
    ) VALUES (
      X'\(id)', 'Demo', '\(slug)', '\(slug)', 1, X'\(v6Fingerprint)',
      'managed', 0, 0, 0
    )
    """
}

private func v6BindingInsert(
    skillID: String = v6SkillA,
    scope: String = "global",
    adapter: String? = nil,
    targetKey: String = "global",
    slug: String = "demo",
    slugKey: String = "demo",
    syncMode: String = "symlink",
    createdAt: Int64 = 1,
    updatedAt: Int64 = 1
) -> String {
    let adapterSQL = adapter.map { "'\($0)'" } ?? "NULL"
    return """
    INSERT INTO distribution_bindings(
      skill_id, scope_kind, adapter_code, target_scope_key,
      distribution_slug, slug_key, sync_mode, created_at_ms, updated_at_ms
    ) VALUES (
      X'\(skillID)', '\(scope)', \(adapterSQL), '\(targetKey)',
      '\(slug)', '\(slugKey)', '\(syncMode)', \(createdAt), \(updatedAt)
    )
    """
}

private func v6SQLIsRejected(_ connection: SQLiteConnection, _ sql: String) -> Bool {
    do {
        try connection.execute(sql)
        return false
    } catch {
        return true
    }
}

func removeV6ObjectsForLegacyFixture(_ connection: SQLiteConnection) throws {
    try connection.execute("DROP TABLE distribution_bindings")
}
