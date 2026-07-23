import Foundation
import Synchronization
import Testing

@testable import SkillsManager

@Suite("Managed Skill import recovery")
struct ManagedSkillImportRecoveryTests {
    private enum Stop: Error { case requested }

    @Test("a second token recovers an interrupted import before mutating")
    func recoversInterruptedImportBeforeSecondToken() async throws {
        let workspace = try WriterWorkspace()
        let discoveryRoot = workspace.workspace.appendingPathComponent(
            "discovery",
            isDirectory: true
        )
        let source = discoveryRoot.appendingPathComponent("demo", isDirectory: true)
        try FileManager.default.createDirectory(
            at: source,
            withIntermediateDirectories: true
        )
        try "# Demo".write(
            to: source.appendingPathComponent("SKILL.md"),
            atomically: true,
            encoding: .utf8
        )
        let fired = Mutex(false)
        var hooks = JournaledSSOTWriterHooks()
        hooks.checkpoint = { point, _ in
            guard point == .afterFilesystemPhase else { return }
            if fired.withLock({ value in
                defer { value = true }
                return !value
            }) {
                throw Stop.requested
            }
        }
        let writer = try await workspace.openWriter(hooks: hooks)
        let observation = try #require(
            SkillDiscoveryScanner().scan(
                roots: [SkillDiscoveryRoot(scope: .global, url: discoveryRoot)]
            ).observations.first
        )
        let service = ManagedSkillImportService(writer: writer)
        let first = try await service.preview(observation: observation, action: .importNew)
        let second = try await service.preview(observation: observation, action: .importNew)

        await #expect(throws: SSOTWriterCheckpointInterruption.self) {
            _ = try await service.execute(first.token)
        }
        let recovered = try await service.execute(second.token)

        #expect(recovered.disposition == .alreadyManaged)
        #expect(try workspace.integer("SELECT count(*) FROM skills") == 1)
        #expect(try workspace.integer("SELECT count(*) FROM local_skill_origins") == 1)
        #expect(try workspace.integer("SELECT count(*) FROM skill_operations") == 1)
        #expect(try workspace.internalItemCount() == 0)
    }

    @Test(
        "create-time local origins recover at every persisted checkpoint",
        arguments: [
            SSOTWriterCheckpoint.afterPreparedInsert,
            .afterCreatePromotion,
            .afterFilesystemPhase,
            .afterDomainTransaction,
            .afterTerminalCompletion,
        ]
    )
    func recoversCreateTimeOrigins(point: SSOTWriterCheckpoint) async throws {
        let workspace = try WriterWorkspace()
        let fired = Mutex(false)
        var hooks = JournaledSSOTWriterHooks()
        hooks.checkpoint = { reached, _ in
            guard reached == point else { return }
            let shouldStop = fired.withLock { value in
                guard !value else { return false }
                value = true
                return true
            }
            if shouldStop { throw Stop.requested }
        }
        var writer: JournaledSSOTWriter? = try await workspace.openWriter(hooks: hooks)
        let snapshot = try workspace.snapshot(content: point.rawValue)
        let skillID = SkillID()
        let origin = try localOrigin(
            skillID: skillID,
            fingerprint: SkillContentFingerprint(currentDigest: snapshot.fingerprintDigest)
        )
        do {
            _ = try await writer!.create(
                payload: try workspace.payload(
                    skillID: skillID,
                    name: "Origin",
                    snapshot: snapshot,
                    localOrigins: [origin]
                ),
                sourceSnapshot: snapshot
            )
            Issue.record("Expected checkpoint interruption")
        } catch is SSOTWriterCheckpointInterruption {}
        writer = nil

        let recovered = try await workspace.openWriter()
        _ = recovered
        #expect(try workspace.integer("SELECT count(*) FROM skills") == 1)
        #expect(try workspace.integer("SELECT count(*) FROM local_skill_origins") == 1)
        #expect(try workspace.scalar("SELECT raw_locator FROM local_skill_origins") == "Origin")
    }

    @Test(
        "v1 create journals survive v4 to v5 upgrade",
        arguments: [
            SSOTWriterCheckpoint.afterPreparedInsert,
            .afterFilesystemPhase,
        ]
    )
    func recoversLegacyV1CreateAfterUpgrade(point: SSOTWriterCheckpoint) async throws {
        let workspace = try WriterWorkspace()
        var hooks = JournaledSSOTWriterHooks()
        hooks.checkpoint = { reached, _ in
            if reached == point { throw Stop.requested }
        }
        var writer: JournaledSSOTWriter? = try await workspace.openWriter(hooks: hooks)
        let snapshot = try workspace.snapshot(content: "legacy-\(point.rawValue)")
        do {
            _ = try await writer!.create(
                payload: try workspace.payload(name: "Legacy", snapshot: snapshot),
                sourceSnapshot: snapshot
            )
            Issue.record("Expected checkpoint interruption")
        } catch is SSOTWriterCheckpointInterruption {}
        writer = nil

        try rewriteJournalPayloadAsV1(workspace.database)
        try downgradeJournalDatabaseToV4(workspace.database)

        let recovered = try await workspace.openWriter()
        _ = recovered
        #expect(try workspace.integer("PRAGMA user_version") == 5)
        #expect(try workspace.integer("SELECT count(*) FROM skills") == 1)
        #expect(try workspace.integer("SELECT count(*) FROM local_skill_origins") == 0)
        #expect(try workspace.scalar("SELECT outcome FROM skill_operations") == "applied")
    }

    private func localOrigin(
        skillID: SkillID,
        fingerprint: SkillContentFingerprint
    ) throws -> LocalSkillOriginRecord {
        try LocalSkillOriginRecord(
            skillID: skillID,
            scope: .global,
            rawLocator: "Origin",
            normalizedLocator: "Origin",
            collisionKey: SkillContentPath.collisionKey(for: "Origin"),
            fingerprint: fingerprint,
            confirmedAtMilliseconds: 1
        )
    }

    private func rewriteJournalPayloadAsV1(_ database: URL) throws {
        let connection = try SQLiteConnection(url: database)
        let statement = try connection.prepare(
            "SELECT domain_payload FROM skill_operations ORDER BY created_at_ms LIMIT 1"
        )
        guard try statement.step(), let encoded = statement.blob(at: 0),
              var envelope = try JSONSerialization.jsonObject(with: encoded) as? [String: Any],
              let trigger = try connection.querySingleText(
                  "SELECT sql FROM sqlite_schema "
                      + "WHERE type = 'trigger' AND name = 'skill_operations_immutable_ownership'"
              ) else {
            throw SSOTJournalStoreError.invalidRecord
        }
        envelope["version"] = 1
        envelope.removeValue(forKey: "localOrigins")
        let legacy = try JSONSerialization.data(withJSONObject: envelope)

        try connection.execute("BEGIN IMMEDIATE")
        do {
            try connection.execute("DROP TRIGGER skill_operations_immutable_ownership")
            let update = try connection.prepare("UPDATE skill_operations SET domain_payload = ?")
            try update.bind(legacy, at: 1)
            guard try !update.step(),
                  try connection.querySingleInt("SELECT changes()") == 1 else {
                throw SSOTJournalStoreError.stateConflict
            }
            try connection.execute(trigger)
            try connection.execute("COMMIT")
        } catch {
            try? connection.execute("ROLLBACK")
            throw error
        }
    }

    private func downgradeJournalDatabaseToV4(_ database: URL) throws {
        let connection = try SQLiteConnection(url: database)
        try connection.execute("BEGIN IMMEDIATE")
        do {
            try connection.execute("DROP TABLE local_skill_origins")
            try connection.execute(
                "UPDATE schema_metadata SET schema_version = 4 WHERE singleton = 1"
            )
            try connection.execute("PRAGMA user_version = 4")
            try connection.execute("COMMIT")
        } catch {
            try? connection.execute("ROLLBACK")
            throw error
        }
    }
}
