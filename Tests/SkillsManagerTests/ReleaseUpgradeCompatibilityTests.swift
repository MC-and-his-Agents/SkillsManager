import Foundation
import Testing

@testable import SkillsManager

@Suite("v0.1.0 release upgrade compatibility", .serialized)
struct ReleaseUpgradeCompatibilityTests {
    enum InjectedFailure: Error {
        case beforeV12Commit
    }

    @Test("upgrades the v0.1.0 schema v11 fixture through the production writer")
    func upgradesV010Fixture() async throws {
        let fixture = try ReleaseV010Fixture()
        let databaseBefore = try fixture.databaseSnapshot()
        let filesBefore = try fixture.fileTreeSnapshot()

        #expect(throws: InjectedFailure.beforeV12Commit) {
            _ = try SkillSchemaMigrator.open(
                at: fixture.workspace.database,
                beforeV12Commit: { throw InjectedFailure.beforeV12Commit }
            )
        }
        #expect(try fixture.databaseSnapshot() == databaseBefore)
        #expect(try fixture.fileTreeSnapshot() == filesBefore)

        let writer = try await fixture.workspace.openWriter()
        #expect(try fixture.workspace.integer("PRAGMA user_version") == 14)
        _ = try SkillSchemaMigrator.open(
            at: fixture.workspace.database,
            accessMode: .readOnly
        )
        #expect(try fixture.fileTreeSnapshot() == filesBefore)

        try await fixture.assertCatalogAndDomain(writer)
        try await fixture.assertBackupIsRestorable(writer)
        try fixture.assertOperationIsDecodable()
        #expect(
            try fixture.workspace.integer(
                "SELECT count(*) FROM distribution_link_ownership WHERE skill_id = "
                    + "X'\(fixture.skillIDHex)'"
            ) == 1
        )

        let reconcile = try await writer.reconcileDistribution(skillID: fixture.skillID)
        #expect(reconcile.status == .inSync)
        _ = try await writer.healthDiagnostics()
        #expect(try await writer.loadCustomPaths().isEmpty)
        let audit = try await SkillConsistencyAuditService(
            writer: writer,
            homeURL: fixture.workspace.distributionHomeURL
        ).prepare()
        #expect(audit.manifest.coverage == .complete)
        #expect(audit.manifest.managedSkills.count == 1)
        #expect(audit.manifest.distributions.first?.status == "inSync")
        #expect(audit.manifest.health.isEmpty)
    }
}
