import Darwin
import Foundation
import Testing

@testable import SkillsManager

@Suite("Anchored skill package locator")
struct AnchoredSkillPackageTests {
    @Test("repeated ambiguous scans release candidate descriptors")
    func repeatedAmbiguousScansReleaseDescriptors() throws {
        try withTemporaryDirectory { root in
            for name in ["one", "two"] {
                let candidate = root.appendingPathComponent(name, isDirectory: true)
                try FileManager.default.createDirectory(at: candidate, withIntermediateDirectories: true)
                try Data("# Skill".utf8).write(to: candidate.appendingPathComponent("SKILL.md"))
            }

            let rootDescriptor = Darwin.open(
                root.path,
                O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC
            )
            #expect(rootDescriptor >= 0)
            guard rootDescriptor >= 0 else { return }
            defer { Darwin.close(rootDescriptor) }

            for _ in 0..<128 {
                do {
                    _ = try AnchoredSkillPackageLocator.locate(
                        in: rootDescriptor,
                        displayPath: root.path
                    )
                    Issue.record("Expected ambiguousRoots")
                } catch SkillPackageError.ambiguousRoots {
                    continue
                } catch {
                    Issue.record("Unexpected locator error: \(error)")
                }
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
