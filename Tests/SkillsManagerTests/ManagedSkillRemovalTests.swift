import Foundation
import Testing

@testable import SkillsManager

@Suite("Managed skill removal")
struct ManagedSkillRemovalTests {
    private let fileManager = FileManager.default

    @Test("removes a direct child of a registered root")
    func removesRegisteredChild() throws {
        try withFixture { temporary, root in
            let skill = try makeSkill(named: "skill", in: root)
            let managedRoot = try ManagedRootReference.capture(at: root)

            try ManagedSkillRemoval.remove(targetURL: skill, managedRoot: managedRoot)

            #expect(!fileManager.fileExists(atPath: skill.path))
            #expect(fileManager.fileExists(atPath: temporary.path))
        }
    }

    @Test("rejects siblings, similar prefixes, the root itself, and traversal")
    func rejectsTargetsOutsideRegisteredRoot() throws {
        try withFixture { temporary, root in
            let managedRoot = try ManagedRootReference.capture(at: root)
            let sibling = try makeSkill(named: "sibling", in: temporary)
            let similarRoot = temporary.appendingPathComponent("managed-other")
            try fileManager.createDirectory(at: similarRoot, withIntermediateDirectories: false)
            let similar = try makeSkill(named: "skill", in: similarRoot)
            let traversal = URL(fileURLWithPath: root.path + "/../sibling")

            for target in [sibling, similar, root, traversal] {
                #expect(throws: ManagedSkillRemovalError.targetOutsideManagedRoots) {
                    try ManagedSkillRemoval.remove(targetURL: target, managedRoot: managedRoot)
                }
            }

            #expect(fileManager.fileExists(atPath: sibling.path))
            #expect(fileManager.fileExists(atPath: similar.path))
            #expect(fileManager.fileExists(atPath: root.path))
        }
    }

    @Test("a symlinked registered root uses the same resolved root as scanning")
    func removesFromResolvedCustomRoot() throws {
        try withFixture { temporary, _ in
            let resolvedRoot = temporary.appendingPathComponent("custom-real")
            let linkedRoot = temporary.appendingPathComponent("custom-link")
            try fileManager.createDirectory(at: resolvedRoot, withIntermediateDirectories: false)
            try fileManager.createSymbolicLink(at: linkedRoot, withDestinationURL: resolvedRoot)
            let scannedSkill = try makeSkill(named: "skill", in: resolvedRoot)
            let managedRoot = try ManagedRootReference.capture(at: linkedRoot)

            try ManagedSkillRemoval.remove(targetURL: scannedSkill, managedRoot: managedRoot)

            #expect(!fileManager.fileExists(atPath: scannedSkill.path))
            #expect(fileManager.fileExists(atPath: linkedRoot.path))
        }
    }

    @Test("removing a linked skill removes only the link")
    func removesOnlySkillLink() throws {
        try withFixture { temporary, root in
            let external = try makeSkill(named: "external", in: temporary)
            let linkedSkill = root.appendingPathComponent("linked-skill")
            let managedRoot = try ManagedRootReference.capture(at: root)
            try fileManager.createSymbolicLink(at: linkedSkill, withDestinationURL: external)

            try ManagedSkillRemoval.remove(targetURL: linkedSkill, managedRoot: managedRoot)

            #expect(!fileManager.fileExists(atPath: linkedSkill.path))
            #expect(fileManager.fileExists(atPath: external.appendingPathComponent("SKILL.md").path))
        }
    }

    @Test("a replaced registered root cannot redirect deletion")
    func rejectsRetargetedRoot() throws {
        try withFixture { temporary, root in
            let scannedSkill = try makeSkill(named: "skill", in: root)
            let managedRoot = try ManagedRootReference.capture(at: root)
            let movedRoot = temporary.appendingPathComponent("moved-root")
            let externalRoot = temporary.appendingPathComponent("external-root")
            try fileManager.moveItem(at: root, to: movedRoot)
            try fileManager.createDirectory(at: externalRoot, withIntermediateDirectories: false)
            let externalSkill = try makeSkill(named: "skill", in: externalRoot)
            try fileManager.createSymbolicLink(at: root, withDestinationURL: externalRoot)

            #expect(throws: ManagedRootReferenceError.self) {
                try ManagedSkillRemoval.remove(targetURL: scannedSkill, managedRoot: managedRoot)
            }
            #expect(fileManager.fileExists(atPath: externalSkill.appendingPathComponent("SKILL.md").path))
            #expect(fileManager.fileExists(atPath: movedRoot.appendingPathComponent("skill/SKILL.md").path))
        }
    }

    @Test("a root replaced after verification cannot redirect deletion")
    func rejectsRootReplacedAfterVerification() throws {
        try withFixture { temporary, root in
            let scannedSkill = try makeSkill(named: "skill", in: root)
            let managedRoot = try ManagedRootReference.capture(at: root)
            let movedRoot = temporary.appendingPathComponent("moved-root")
            let replacementRoot = temporary.appendingPathComponent("replacement-root")
            try fileManager.createDirectory(at: replacementRoot, withIntermediateDirectories: false)
            _ = try makeSkill(named: "skill", in: replacementRoot)

            #expect(throws: ManagedPathError.rootReplaced) {
                try ManagedSkillRemoval.remove(
                    targetURL: scannedSkill,
                    managedRoot: managedRoot,
                    beforeGuard: {
                        try fileManager.moveItem(at: root, to: movedRoot)
                        try fileManager.moveItem(at: replacementRoot, to: root)
                    }
                )
            }
            #expect(fileManager.fileExists(
                atPath: root.appendingPathComponent("skill/SKILL.md").path
            ))
            #expect(fileManager.fileExists(atPath: movedRoot.appendingPathComponent("skill/SKILL.md").path))
        }
    }

    private func withFixture(_ body: (URL, URL) throws -> Void) throws {
        let temporary = fileManager.temporaryDirectory
            .appendingPathComponent("ManagedSkillRemovalTests-\(UUID().uuidString)")
        let root = temporary.appendingPathComponent("managed")
        try fileManager.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? fileManager.removeItem(at: temporary) }
        try body(temporary, root)
    }

    private func makeSkill(named name: String, in root: URL) throws -> URL {
        let skill = root.appendingPathComponent(name)
        try fileManager.createDirectory(at: skill, withIntermediateDirectories: false)
        try "# Skill".write(
            to: skill.appendingPathComponent("SKILL.md"),
            atomically: true,
            encoding: .utf8
        )
        return skill
    }
}
