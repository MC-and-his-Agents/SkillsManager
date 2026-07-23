import Foundation
import Testing

@testable import SkillsManager

@Suite("DistributionBindingStore")
struct DistributionBindingStoreTests {
    @Test("loads canonical sets and preserves no-op and update timestamps")
    func canonicalSetNoOpAndTimestamps() throws {
        try withDistributionBindingStore { connection, store in
            let skillID = distributionStoreSkillA
            #expect(try store.load(skillID: skillID).isEmpty)

            let global = try distributionIntent(skillID, scope: .global, slug: "Demo")
            let storedGlobal = try store.replace(
                skillID: skillID,
                expectedOld: [],
                desired: [global],
                nowMilliseconds: 10
            )
            #expect(storedGlobal.count == 1)
            #expect(storedGlobal[0].createdAtMilliseconds == 10)
            #expect(storedGlobal[0].updatedAtMilliseconds == 10)

            let changesBeforeNoOp = try connection.querySingleInt("SELECT total_changes()")
            let noOp = try store.replace(
                skillID: skillID,
                expectedOld: storedGlobal,
                desired: [global],
                nowMilliseconds: 20
            )
            #expect(noOp == storedGlobal)
            #expect(try connection.querySingleInt("SELECT total_changes()") == changesBeforeNoOp)

            let agents = try [
                distributionIntent(skillID, scope: .agent(.copilot), slug: "Demo"),
                distributionIntent(skillID, scope: .agent(.codex), slug: "Demo"),
                distributionIntent(skillID, scope: .agent(.claude), slug: "Demo"),
            ]
            let storedAgents = try store.replace(
                skillID: skillID,
                expectedOld: storedGlobal,
                desired: agents,
                nowMilliseconds: 30
            )
            #expect(storedAgents.map(\.scope) == [
                .agent(.codex), .agent(.claude), .agent(.copilot),
            ])
            #expect(storedAgents.allSatisfy {
                $0.createdAtMilliseconds == 30 && $0.updatedAtMilliseconds == 30
            })

            let changedCodex = try distributionIntent(
                skillID,
                scope: .agent(.codex),
                slug: "Renamed"
            )
            let updated = try store.replace(
                skillID: skillID,
                expectedOld: storedAgents,
                desired: [agents[0], changedCodex, agents[2]],
                nowMilliseconds: 20
            )
            let codex = try #require(updated.first { $0.scope == .agent(.codex) })
            #expect(codex.createdAtMilliseconds == 30)
            #expect(codex.updatedAtMilliseconds == 31)
            #expect(updated.filter { $0.scope != .agent(.codex) }.allSatisfy {
                $0.createdAtMilliseconds == 30 && $0.updatedAtMilliseconds == 30
            })
        }
    }

    @Test("expected-old compares the complete persisted snapshot")
    func expectedOldConflictsOnAnyDrift() throws {
        try withDistributionBindingStore { _, store in
            let skillID = distributionStoreSkillA
            let intent = try distributionIntent(skillID, scope: .global, slug: "demo")
            let actual = try store.replace(
                skillID: skillID,
                expectedOld: [],
                desired: [intent],
                nowMilliseconds: 1
            )

            #expect(throws: DistributionBindingStoreError.conflict) {
                _ = try store.replace(
                    skillID: skillID,
                    expectedOld: [],
                    desired: [intent],
                    nowMilliseconds: 2
                )
            }
            let driftedTime = try DistributionBinding(
                skillID: skillID,
                scope: .global,
                distributionSlug: intent.distributionSlug,
                createdAtMilliseconds: 1,
                updatedAtMilliseconds: 2
            )
            #expect(throws: DistributionBindingStoreError.conflict) {
                _ = try store.replace(
                    skillID: skillID,
                    expectedOld: [driftedTime],
                    desired: [intent],
                    nowMilliseconds: 2
                )
            }
            let driftedSlug = try DistributionBinding(
                skillID: skillID,
                scope: .global,
                distributionSlug: DefaultDistributionSlug(validating: "other"),
                createdAtMilliseconds: 1,
                updatedAtMilliseconds: 1
            )
            #expect(throws: DistributionBindingStoreError.conflict) {
                _ = try store.replace(
                    skillID: skillID,
                    expectedOld: [driftedSlug],
                    desired: [intent],
                    nowMilliseconds: 2
                )
            }

            _ = try store.replace(
                skillID: skillID,
                expectedOld: actual,
                desired: [],
                nowMilliseconds: 2
            )
            #expect(throws: DistributionBindingStoreError.conflict) {
                _ = try store.replace(
                    skillID: skillID,
                    expectedOld: actual,
                    desired: [],
                    nowMilliseconds: 3
                )
            }
        }
    }

    @Test("invalid sets, overflow, and constraint failures roll back")
    func invalidAndRollback() throws {
        try withDistributionBindingStore { connection, store in
            let skillID = distributionStoreSkillA
            let global = try distributionIntent(skillID, scope: .global, slug: "demo")
            let codex = try distributionIntent(skillID, scope: .agent(.codex), slug: "demo")
            #expect(throws: DistributionBindingStoreError.invalidInput) {
                _ = try store.replace(
                    skillID: skillID,
                    expectedOld: [],
                    desired: [global, codex],
                    nowMilliseconds: 1
                )
            }
            #expect(throws: DistributionBindingStoreError.invalidInput) {
                _ = try store.replace(
                    skillID: skillID,
                    expectedOld: [],
                    desired: [codex, codex],
                    nowMilliseconds: 1
                )
            }
            #expect(try store.load(skillID: skillID).isEmpty)

            let claude = try distributionIntent(
                skillID,
                scope: .agent(.claude),
                slug: "demo"
            )
            let original = try store.replace(
                skillID: skillID,
                expectedOld: [],
                desired: [codex, claude],
                nowMilliseconds: 10
            )
            let occupied = try distributionIntent(
                distributionStoreSkillB,
                scope: .agent(.codex),
                slug: "taken"
            )
            _ = try store.replace(
                skillID: distributionStoreSkillB,
                expectedOld: [],
                desired: [occupied],
                nowMilliseconds: 10
            )
            let conflicting = try distributionIntent(
                skillID,
                scope: .agent(.codex),
                slug: "taken"
            )
            #expect(throws: SQLiteStoreError.self) {
                _ = try store.replace(
                    skillID: skillID,
                    expectedOld: original,
                    desired: [conflicting],
                    nowMilliseconds: 20
                )
            }
            #expect(try store.load(skillID: skillID) == original)

            try connection.execute(
                "UPDATE distribution_bindings SET updated_at_ms = \(Int64.max) "
                    + "WHERE skill_id = \(distributionStoreBlob(skillID)) "
                    + "AND target_scope_key = 'agent:codex'"
            )
            let overflowSnapshot = try store.load(skillID: skillID)
            let renamed = try distributionIntent(
                skillID,
                scope: .agent(.codex),
                slug: "renamed"
            )
            #expect(throws: DistributionBindingStoreError.invalidInput) {
                _ = try store.replace(
                    skillID: skillID,
                    expectedOld: overflowSnapshot,
                    desired: [renamed, claude],
                    nowMilliseconds: 0
                )
            }
            #expect(try store.load(skillID: skillID) == overflowSnapshot)
        }
    }

    @Test("typed readback rejects semantically corrupt direct SQL")
    func corruptReadback() throws {
        try withDistributionBindingStore { connection, store in
            try connection.execute(
                """
                INSERT INTO distribution_bindings(
                  skill_id, scope_kind, adapter_code, target_scope_key,
                  distribution_slug, slug_key, sync_mode, created_at_ms, updated_at_ms
                ) VALUES (
                  \(distributionStoreBlob(distributionStoreSkillA)),
                  'global', NULL, 'global', 'Demo', 'wrong', 'symlink', 1, 1
                )
                """
            )
            #expect(throws: DistributionBindingStoreError.corruptRecord) {
                _ = try store.load(skillID: distributionStoreSkillA)
            }
        }
    }
}

private let distributionStoreSkillA = SkillID(
    UUID(uuidString: "00112233-4455-4677-8899-aabbccddeeff")!
)
private let distributionStoreSkillB = SkillID(
    UUID(uuidString: "11112222-3333-4444-8555-666677778888")!
)
private let distributionStoreFingerprint = String(repeating: "ab", count: 32)

private func withDistributionBindingStore(
    _ body: (SQLiteConnection, DistributionBindingStore) throws -> Void
) throws {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("distribution-store-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
    defer { try? FileManager.default.removeItem(at: root) }
    let connection = try SkillSchemaMigrator.open(
        at: root.appendingPathComponent("manager.sqlite")
    )
    try connection.execute(distributionStoreSkillInsert(distributionStoreSkillA, slug: "demo"))
    try connection.execute(distributionStoreSkillInsert(distributionStoreSkillB, slug: "other"))
    try body(connection, DistributionBindingStore(connection: connection))
}

private func distributionIntent(
    _ skillID: SkillID,
    scope: DistributionBindingScope,
    slug: String
) throws -> DistributionBindingIntent {
    DistributionBindingIntent(
        skillID: skillID,
        scope: scope,
        distributionSlug: try DefaultDistributionSlug(validating: slug)
    )
}

private func distributionStoreSkillInsert(_ skillID: SkillID, slug: String) -> String {
    """
    INSERT INTO skills(
      skill_id, display_name, default_distribution_slug, default_slug_key,
      fingerprint_algorithm_version, content_fingerprint, status,
      created_at_ms, updated_at_ms, db_revision
    ) VALUES (
      \(distributionStoreBlob(skillID)), 'Demo', '\(slug)', '\(slug)',
      1, X'\(distributionStoreFingerprint)', 'managed', 0, 0, 0
    )
    """
}

private func distributionStoreBlob(_ skillID: SkillID) -> String {
    "X'\(skillID.bytes.map { String(format: "%02x", $0) }.joined())'"
}
