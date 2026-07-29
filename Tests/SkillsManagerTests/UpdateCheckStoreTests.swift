import Foundation
import Testing

@testable import SkillsManager

@Suite("Skill update check store", .serialized)
struct UpdateCheckStoreTests {
    enum InjectedFailure: Error { case stop }

    @Test("upserts and loads every stable status")
    func upsertsStableStatuses() throws {
        try withUpdateCheckDatabase { connection in
            let skillID = try insertUpdateCheckSkill(connection)
            let store = UpdateCheckStore(connection: connection)

            let statuses: [SkillUpdateCheckStatus] = [
                .upToDate, .remoteChanged, .localModified,
                .copyDrift, .capabilityUnavailable, .conflict,
            ]
            for (index, status) in statuses.enumerated() {
                let expected = try StoredSkillUpdateCheck(
                    skillID: skillID,
                    status: status,
                    checkedAtMilliseconds: Int64(index),
                    payload: Data([UInt8(index + 1)])
                )
                try store.upsert(expected)
                #expect(try store.load(skillID: skillID) == expected)
                #expect(try connection.querySingleInt(
                    "SELECT count(*) FROM skill_update_checks"
                ) == 1)
            }
        }
    }

    @Test("transaction rollback preserves the previous snapshot")
    func rollbackPreservesPreviousSnapshot() throws {
        try withUpdateCheckDatabase { connection in
            let skillID = try insertUpdateCheckSkill(connection)
            let store = UpdateCheckStore(connection: connection)
            let original = try StoredSkillUpdateCheck(
                skillID: skillID,
                status: .upToDate,
                checkedAtMilliseconds: 1,
                payload: Data([1])
            )
            let replacement = try StoredSkillUpdateCheck(
                skillID: skillID,
                status: .remoteChanged,
                checkedAtMilliseconds: 2,
                payload: Data([2])
            )
            try store.upsert(original)

            #expect(throws: InjectedFailure.stop) {
                try store.transaction {
                    try store.upsertInCurrentTransaction(replacement)
                    throw InjectedFailure.stop
                }
            }
            #expect(try store.load(skillID: skillID) == original)
        }
    }

    @Test("rejects invalid payloads and corrupt stored rows")
    func rejectsInvalidAndCorruptRecords() throws {
        try withUpdateCheckDatabase { connection in
            let skillID = try insertUpdateCheckSkill(connection)
            #expect(throws: UpdateCheckStoreError.invalidRecord) {
                try StoredSkillUpdateCheck(
                    skillID: skillID,
                    status: .conflict,
                    checkedAtMilliseconds: -1,
                    payload: Data()
                )
            }
            #expect(throws: UpdateCheckStoreError.invalidRecord) {
                try StoredSkillUpdateCheck(
                    skillID: skillID,
                    status: .conflict,
                    checkedAtMilliseconds: 0,
                    payload: Data(repeating: 0, count: 65_537)
                )
            }

            try connection.execute("PRAGMA ignore_check_constraints = ON")
            let statement = try connection.prepare(
                """
                INSERT INTO skill_update_checks(
                  skill_id, format_version, status, checked_at_ms, snapshot_payload
                ) VALUES (?, 1, 'unknown', 0, X'01')
                """
            )
            try statement.bind(skillID.bytes, at: 1)
            #expect(try statement.step() == false)
            try connection.execute("PRAGMA ignore_check_constraints = OFF")
            #expect(throws: UpdateCheckStoreError.corruptRecord) {
                try UpdateCheckStore(connection: connection).load(skillID: skillID)
            }
        }
    }

    @Test("deleting a Skill cascades its update check")
    func cascadeDelete() throws {
        try withUpdateCheckDatabase { connection in
            let skillID = try insertUpdateCheckSkill(connection)
            let store = UpdateCheckStore(connection: connection)
            try store.upsert(try StoredSkillUpdateCheck(
                skillID: skillID,
                status: .capabilityUnavailable,
                checkedAtMilliseconds: 3,
                payload: Data([3])
            ))

            let statement = try connection.prepare("DELETE FROM skills WHERE skill_id = ?")
            try statement.bind(skillID.bytes, at: 1)
            #expect(try statement.step() == false)
            #expect(try store.load(skillID: skillID) == nil)
        }
    }
}

private func withUpdateCheckDatabase(
    _ body: (SQLiteConnection) throws -> Void
) throws {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("update-check-store-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
    defer { try? FileManager.default.removeItem(at: root) }
    try body(try SkillSchemaMigrator.open(at: root.appendingPathComponent("manager.sqlite")))
}

private func insertUpdateCheckSkill(_ connection: SQLiteConnection) throws -> SkillID {
    let skillID = SkillID()
    let statement = try connection.prepare(
        """
        INSERT INTO skills(
          skill_id, display_name, default_distribution_slug, default_slug_key,
          fingerprint_algorithm_version, content_fingerprint, status,
          created_at_ms, updated_at_ms, db_revision
        ) VALUES (?, 'Update', 'update', 'update', 1, zeroblob(32), 'managed', 1, 1, 0)
        """
    )
    try statement.bind(skillID.bytes, at: 1)
    guard try !statement.step() else {
        throw SQLiteStoreError.invalidState("Skill insert returned a row")
    }
    return skillID
}
