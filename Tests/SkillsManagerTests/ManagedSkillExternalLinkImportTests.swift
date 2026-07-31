import Foundation
import Testing

@testable import SkillsManager

extension ManagedSkillImportTests {
    @Test("external Skill links import snapshots without mutating their source")
    func importsExternalSkillLinkAsSnapshot() async throws {
        let workspace = try WriterWorkspace()
        let root = try discoveryRoot(in: workspace)
        let target = try createSkill(
            named: "external",
            content: "# External",
            in: workspace.workspace
        )
        let link = root.appendingPathComponent("linked")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: target)
        let linkIdentity = try identity(of: link)
        let targetIdentity = try identity(of: target)
        let sourceBytes = try Data(contentsOf: target.appendingPathComponent("SKILL.md"))
        let writer = try await workspace.openWriter()
        let roots = [SkillDiscoveryRoot(scope: .global, url: root)]
        let observation = try await scanObservation(roots: roots, writer: writer)
        let service = ManagedSkillImportService(writer: writer)

        let preview = try await service.preview(
            observation: observation,
            action: .importNew
        )
        let result = try await service.execute(preview.token)
        let rescanned = try await scanObservation(roots: roots, writer: writer)

        #expect(result.disposition == .created)
        #expect(rescanned.status == .managed)
        #expect(rescanned.matchedSkillID == result.skill.skillID)
        #expect(try workspace.integer("SELECT count(*) FROM skills") == 1)
        #expect(try workspace.integer("SELECT count(*) FROM local_skill_origins") == 1)
        #expect(try workspace.integer("SELECT count(*) FROM distribution_bindings") == 0)
        #expect(try identity(of: link) == linkIdentity)
        #expect(try identity(of: target) == targetIdentity)
        #expect(try Data(contentsOf: target.appendingPathComponent("SKILL.md")) == sourceBytes)
        #expect(
            try Data(contentsOf: workspace.root
                .appendingPathComponent(result.skill.skillID.directoryName)
                .appendingPathComponent("SKILL.md")) == sourceBytes
        )
    }

    @Test("retargeting an external Skill link invalidates its import preview")
    func retargetedExternalSkillLinkFailsClosed() async throws {
        let workspace = try WriterWorkspace()
        let root = try discoveryRoot(in: workspace)
        let first = try createSkill(named: "first", content: "# First", in: workspace.workspace)
        let second = try createSkill(named: "second", content: "# Second", in: workspace.workspace)
        let link = root.appendingPathComponent("linked")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: first)
        let writer = try await workspace.openWriter()
        let observation = try await scanObservation(
            roots: [SkillDiscoveryRoot(scope: .global, url: root)],
            writer: writer
        )
        let service = ManagedSkillImportService(writer: writer)
        let preview = try await service.preview(
            observation: observation,
            action: .importNew
        )

        try FileManager.default.removeItem(at: link)
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: second)

        await #expect(throws: ManagedSkillImportError.sourceChanged) {
            _ = try await service.execute(preview.token)
        }
        #expect(try workspace.integer("SELECT count(*) FROM skills") == 0)
        #expect(try workspace.integer("SELECT count(*) FROM local_skill_origins") == 0)
        #expect(try workspace.integer("SELECT count(*) FROM distribution_bindings") == 0)
        #expect(
            try String(
                contentsOf: first.appendingPathComponent("SKILL.md"),
                encoding: .utf8
            ) == "# First"
        )
        #expect(
            try String(
                contentsOf: second.appendingPathComponent("SKILL.md"),
                encoding: .utf8
            ) == "# Second"
        )
    }

    @Test("changing an external Skill target invalidates its import preview")
    func changedExternalSkillLinkTargetFailsClosed() async throws {
        let workspace = try WriterWorkspace()
        let root = try discoveryRoot(in: workspace)
        let target = try createSkill(
            named: "external",
            content: "# Before",
            in: workspace.workspace
        )
        let link = root.appendingPathComponent("linked")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: target)
        let writer = try await workspace.openWriter()
        let observation = try await scanObservation(
            roots: [SkillDiscoveryRoot(scope: .global, url: root)],
            writer: writer
        )
        let service = ManagedSkillImportService(writer: writer)
        let preview = try await service.preview(
            observation: observation,
            action: .importNew
        )
        try "# After".write(
            to: target.appendingPathComponent("SKILL.md"),
            atomically: true,
            encoding: .utf8
        )

        await #expect(throws: ManagedSkillImportError.sourceChanged) {
            _ = try await service.execute(preview.token)
        }
        #expect(try workspace.integer("SELECT count(*) FROM skills") == 0)
        #expect(try workspace.integer("SELECT count(*) FROM local_skill_origins") == 0)
        #expect(try workspace.integer("SELECT count(*) FROM distribution_bindings") == 0)
        #expect(
            try String(
                contentsOf: target.appendingPathComponent("SKILL.md"),
                encoding: .utf8
            ) == "# After"
        )
    }
}
