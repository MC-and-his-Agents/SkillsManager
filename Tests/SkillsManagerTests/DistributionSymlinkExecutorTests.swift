import Foundation
import Testing

@testable import SkillsManager

@Suite("DistributionSymlinkExecutor", .serialized)
struct DistributionSymlinkExecutorTests {
    @Test("applies a global plan and persists binding ownership")
    func appliesGlobalPlan() throws {
        let home = FileManager.default.temporaryDirectory
            .appendingPathComponent("distribution-executor-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: home) }
        let skillID = SkillID(UUID(uuidString: "00112233-4455-4677-8899-aabbccddeeff")!)
        let ssot = home
            .appendingPathComponent(".SkillsManager/skills", isDirectory: true)
            .appendingPathComponent(skillID.directoryName, isDirectory: true)
        try FileManager.default.createDirectory(at: ssot, withIntermediateDirectories: true)

        let database = home.appendingPathComponent("manager.sqlite")
        let connection = try SkillSchemaMigrator.open(at: database)
        try connection.execute(
            """
            INSERT INTO skills(
              skill_id, display_name, default_distribution_slug, default_slug_key,
              fingerprint_algorithm_version, content_fingerprint, status,
              created_at_ms, updated_at_ms, db_revision
            ) VALUES (
              X'00112233445546778899aabbccddeeff', 'Demo', 'demo', 'demo',
              1, X'\(String(repeating: "ab", count: 32))', 'managed', 0, 0, 0
            )
            """
        )

        let fileSystem = try DistributionSymlinkFileSystem(homeURL: home)
        let executor = try DistributionSymlinkExecutor(
            connection: connection,
            fileSystem: fileSystem,
            nowMilliseconds: { 10 }
        )
        let slug = try DefaultDistributionSlug(validating: "demo")
        let adapters = Set(DistributionTargetCatalog.current.globalReaders.map(\.storageKey))
        let plan = try executor.dryRun(
            skillID: skillID,
            currentBindings: [],
            desiredScope: .global(slug),
            requiredAdapterCodes: adapters
        )
        #expect(plan.status == .executable)

        let record = try executor.apply(
            skillID: skillID,
            plan: plan,
            expectedOldBindings: [],
            expectedOldOwnership: [],
            nowMilliseconds: 10
        )
        #expect(record.phase == .completed)
        #expect(record.outcome == .applied)

        let bindings = try DistributionBindingStore(connection: connection).load(skillID: skillID)
        #expect(bindings.map(\.scope) == [.global])
        let ownership = try DistributionLinkOwnershipStore(connection: connection).load(skillID: skillID)
        #expect(ownership.map(\.targetScopeKey) == ["global"])
        guard let entry = DistributionTargetCatalog.current.entry(
            for: .global,
            slug: slug
        ) else {
            Issue.record("global distribution entry is missing")
            return
        }
        #expect(try fileSystem.observe(entry) == .symlink(
            rootIdentity: ownership[0].rootIdentity,
            entryIdentity: ownership[0].entryIdentity,
            target: ownership[0].absoluteLinkTarget
        ))
    }
}
