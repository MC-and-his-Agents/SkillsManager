import Foundation
import Testing

@testable import SkillsManager

@Suite("Publish state hash migration")
struct PublishStateMigrationTests {
    @Test("legacy fixture decodes without an algorithm version")
    func decodesLegacyFixture() throws {
        let data = Data(#"{"lastPublishedHash":"legacy","lastPublishedAt":0}"#.utf8)

        let state = try JSONDecoder().decode(SkillStore.PublishState.self, from: data)

        #expect(state.lastPublishedHash == "legacy")
        #expect(state.lastPublishedAt == Date(timeIntervalSinceReferenceDate: 0))
        #expect(state.hashAlgorithmVersion == nil)
    }

    @Test("new state persists the current algorithm version")
    func encodesCurrentVersion() throws {
        let state = SkillStore.PublishState(
            lastPublishedHash: "v1",
            lastPublishedAt: Date(timeIntervalSinceReferenceDate: 0)
        )

        let data = try JSONEncoder().encode(state)
        let decoded = try JSONDecoder().decode(SkillStore.PublishState.self, from: data)

        #expect(decoded == state)
        #expect(decoded.hashAlgorithmVersion == 1)
    }

    @Test("matching legacy state migrates without reporting changes")
    func migratesMatchingLegacyState() {
        let publishedAt = Date(timeIntervalSinceReferenceDate: 123)
        let state = SkillStore.PublishState(
            lastPublishedHash: "legacy",
            lastPublishedAt: publishedAt,
            hashAlgorithmVersion: nil
        )

        #expect(state.resolve(currentHash: "v1", legacyHash: "legacy") == .migrate(
            SkillStore.PublishState(lastPublishedHash: "v1", lastPublishedAt: publishedAt)
        ))
        #expect(state.resolve(currentHash: "v1", legacyHash: "changed") == .changed)
    }

    @Test("current and unknown hash versions never use a legacy match")
    func handlesVersionedState() {
        let date = Date(timeIntervalSinceReferenceDate: 0)
        let current = SkillStore.PublishState(lastPublishedHash: "v1", lastPublishedAt: date)
        let unknown = SkillStore.PublishState(
            lastPublishedHash: "v1",
            lastPublishedAt: date,
            hashAlgorithmVersion: 99
        )

        #expect(current.resolve(currentHash: "v1", legacyHash: "other") == .unchanged)
        #expect(current.resolve(currentHash: "other", legacyHash: "v1") == .changed)
        #expect(unknown.resolve(currentHash: "v1", legacyHash: "v1") == .changed)
    }

    @Test("legacy hash remains compatible with the previous implementation")
    func computesLegacyHashVector() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try Data("# Demo\n".utf8).write(to: root.appendingPathComponent("SKILL.md"))
        try FileManager.default.createDirectory(
            at: root.appendingPathComponent("assets"),
            withIntermediateDirectories: true
        )
        try Data([0x00, 0xff]).write(to: root.appendingPathComponent("assets/icon.bin"))

        let hash = try await SkillFileWorker().computeLegacyPublishHash(for: root)

        #expect(hash == "d1393358c9e133cf174741e2dea34eb6f5d839047cc622c3ede6f4eab2532111")
    }
}
