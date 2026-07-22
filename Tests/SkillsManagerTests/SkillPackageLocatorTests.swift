import Foundation
import Testing

@testable import SkillsManager

@Suite("Skill Package Locator")
struct SkillPackageLocatorTests {
    @Test("locates a direct Skill manifest")
    func locatesDirectManifest() throws {
        try withTemporaryDirectory { root in
            try "# Example".write(
                to: root.appendingPathComponent("SKILL.md"),
                atomically: true,
                encoding: .utf8
            )

            #expect(try SkillPackageLocator().locateSkillRoot(in: root) == root.standardizedFileURL)
        }
    }

    @Test("locates one wrapped Skill folder")
    func locatesWrappedSkill() throws {
        try withTemporaryDirectory { root in
            let skill = root.appendingPathComponent("example", isDirectory: true)
            try FileManager.default.createDirectory(at: skill, withIntermediateDirectories: true)
            try "# Example".write(
                to: skill.appendingPathComponent("SKILL.md"),
                atomically: true,
                encoding: .utf8
            )

            #expect(try SkillPackageLocator().locateSkillRoot(in: root) == skill.standardizedFileURL)
        }
    }

    @Test("rejects ambiguous wrapped Skills")
    func rejectsAmbiguousSkills() throws {
        try withTemporaryDirectory { root in
            for name in ["one", "two"] {
                let skill = root.appendingPathComponent(name, isDirectory: true)
                try FileManager.default.createDirectory(at: skill, withIntermediateDirectories: true)
                try "# \(name)".write(
                    to: skill.appendingPathComponent("SKILL.md"),
                    atomically: true,
                    encoding: .utf8
                )
            }

            #expect(throws: SkillPackageError.ambiguousRoots) {
                try SkillPackageLocator().locateSkillRoot(in: root)
            }
        }
    }

    @Test("rejects a symbolic-link manifest")
    func rejectsSymlinkManifest() throws {
        try withTemporaryDirectory { root in
            let outside = root.appendingPathComponent("outside.md")
            try "# Outside".write(to: outside, atomically: true, encoding: .utf8)
            try FileManager.default.createSymbolicLink(
                at: root.appendingPathComponent("SKILL.md"),
                withDestinationURL: outside
            )

            #expect(throws: SkillPackageError.self) {
                try SkillPackageLocator().locateSkillRoot(in: root)
            }
        }
    }

    private func withTemporaryDirectory(_ body: (URL) throws -> Void) throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try body(root)
    }
}
