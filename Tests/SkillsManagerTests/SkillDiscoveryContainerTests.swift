import Foundation
import Testing

@testable import SkillsManager

@Suite("Skill discovery containers")
struct SkillDiscoveryContainerTests {
    @Test("only direct child Skills are discovered")
    func directChildrenOnly() throws {
        try withWorkspace { workspace in
            let root = workspace.appendingPathComponent("skills", isDirectory: true)
            let container = root.appendingPathComponent("bundle", isDirectory: true)
            try FileManager.default.createDirectory(at: container, withIntermediateDirectories: true)
            _ = try createSkill(named: "direct", in: container)
            let deeper = container.appendingPathComponent("deeper", isDirectory: true)
            try FileManager.default.createDirectory(at: deeper, withIntermediateDirectories: false)
            _ = try createSkill(named: "ignored", in: deeper)
            try FileManager.default.createDirectory(
                at: container.appendingPathComponent("plain"),
                withIntermediateDirectories: false
            )

            let result = try scan(root)

            #expect(result.observations.map(\.relativeLocator) == ["bundle/direct"])
            let observation = try #require(result.observations.first)
            #expect(observation.displayName == "direct")
            #expect(observation.locationRevision?.root != nil)
            #expect(observation.locationRevision?.container != nil)
            #expect(observation.locationRevision?.candidate != nil)
        }
    }

    @Test("a container without direct Skills remains a missing-manifest finding")
    func emptyContainerFallsBack() throws {
        try withWorkspace { workspace in
            let root = workspace.appendingPathComponent("skills", isDirectory: true)
            let container = root.appendingPathComponent("bundle", isDirectory: true)
            let deeper = container.appendingPathComponent("deeper", isDirectory: true)
            try FileManager.default.createDirectory(at: deeper, withIntermediateDirectories: true)
            _ = try createSkill(named: "ignored", in: deeper)

            let observation = try #require(try scan(root).observations.first)

            #expect(observation.relativeLocator == "bundle")
            #expect(observation.reason == .missingSkillManifest)
        }
    }

    @Test("container enumeration limit fails closed")
    func containerLimitFailsClosed() throws {
        try withWorkspace { workspace in
            let root = workspace.appendingPathComponent("skills", isDirectory: true)
            let container = root.appendingPathComponent("bundle", isDirectory: true)
            try FileManager.default.createDirectory(at: container, withIntermediateDirectories: true)
            try FileManager.default.createDirectory(
                at: container.appendingPathComponent("one"),
                withIntermediateDirectories: false
            )
            try FileManager.default.createDirectory(
                at: container.appendingPathComponent("two"),
                withIntermediateDirectories: false
            )
            let limits = SkillContentLimits(
                maximumFileCount: 10,
                maximumTotalByteCount: 1_024,
                maximumFileByteCount: 1_024,
                maximumDirectoryCount: 1
            )

            let result = try SkillDiscoveryScanner().scan(
                roots: [SkillDiscoveryRoot(scope: .global, url: root)],
                limits: limits
            )

            let observation = try #require(result.observations.first)
            #expect(result.observations.count == 1)
            #expect(observation.relativeLocator == "bundle")
            #expect(observation.reason == .resourceLimitExceeded)
        }
    }

    private func scan(_ root: URL) throws -> SkillDiscoveryResult {
        try SkillDiscoveryScanner().scan(roots: [
            SkillDiscoveryRoot(scope: .global, url: root),
        ])
    }

    private func createSkill(named name: String, in root: URL) throws -> URL {
        let skill = root.appendingPathComponent(name, isDirectory: true)
        try FileManager.default.createDirectory(at: skill, withIntermediateDirectories: false)
        try "# \(name)".write(
            to: skill.appendingPathComponent("SKILL.md"),
            atomically: true,
            encoding: .utf8
        )
        return skill
    }

    private func withWorkspace(_ body: (URL) throws -> Void) throws {
        let workspace = FileManager.default.temporaryDirectory
            .appendingPathComponent("container-scan-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: workspace) }
        try body(workspace)
    }
}
