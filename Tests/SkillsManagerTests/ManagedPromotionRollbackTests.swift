import Foundation
import Testing

@testable import SkillsManager

@Suite("Managed promotion rollback")
struct ManagedPromotionRollbackTests {
    @Test("no-replace rollback restores the staged identity")
    func restoresNoReplacePromotion() throws {
        try withTemporaryDirectory { temporary in
            let root = temporary.appendingPathComponent("managed", isDirectory: true)
            let staged = root.appendingPathComponent(".staged", isDirectory: true)
            let target = root.appendingPathComponent("skill", isDirectory: true)
            try makeItem(at: target, contents: "new")
            let guardrail = try ManagedPathGuard(rootURL: root)
            let observed = try guardrail.itemIdentity(at: target)
            let expected = try #require(observed)

            #expect(guardrail.rollbackNoReplace(
                names: .init(staged: staged.lastPathComponent, target: target.lastPathComponent),
                expectedStaged: expected
            ))
            #expect(!FileManager.default.fileExists(atPath: target.path))
            #expect(try contents(at: staged) == "new")
        }
    }

    @Test("replace rollback swaps both exact identities back")
    func restoresReplacePromotion() throws {
        try withTemporaryDirectory { temporary in
            let root = temporary.appendingPathComponent("managed", isDirectory: true)
            let staged = root.appendingPathComponent(".staged", isDirectory: true)
            let target = root.appendingPathComponent("skill", isDirectory: true)
            try makeItem(at: staged, contents: "old")
            try makeItem(at: target, contents: "new")
            let guardrail = try ManagedPathGuard(rootURL: root)
            let observedStaged = try guardrail.itemIdentity(at: target)
            let observedTarget = try guardrail.itemIdentity(at: staged)
            let expectedStaged = try #require(observedStaged)
            let expectedTarget = try #require(observedTarget)

            #expect(guardrail.rollbackReplace(
                names: .init(staged: staged.lastPathComponent, target: target.lastPathComponent),
                expectedStaged: expectedStaged,
                expectedTarget: expectedTarget
            ))
            #expect(try contents(at: target) == "old")
            #expect(try contents(at: staged) == "new")
        }
    }

    private func makeItem(at url: URL, contents: String) throws {
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        try contents.write(
            to: url.appendingPathComponent("SKILL.md"),
            atomically: true,
            encoding: .utf8
        )
    }

    private func contents(at url: URL) throws -> String {
        try String(contentsOf: url.appendingPathComponent("SKILL.md"), encoding: .utf8)
    }

    private func withTemporaryDirectory(_ body: (URL) throws -> Void) throws {
        let temporary = FileManager.default.temporaryDirectory
            .appendingPathComponent("managed-promotion-rollback-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: temporary, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: temporary) }
        try body(temporary)
    }
}
