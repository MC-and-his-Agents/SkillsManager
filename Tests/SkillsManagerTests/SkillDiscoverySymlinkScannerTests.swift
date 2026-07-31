import Darwin
import Foundation
import Testing

@testable import SkillsManager

extension SkillDiscoveryScannerTests {
    @Test("external Skill links are safely fingerprinted for import")
    func externalSkillLinkIsDiscovered() throws {
        try withWorkspace { workspace in
            let root = workspace.appendingPathComponent("skills", isDirectory: true)
            let outside = workspace.appendingPathComponent("outside", isDirectory: true)
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
            try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: false)
            try "# Outside".write(
                to: outside.appendingPathComponent("SKILL.md"),
                atomically: true,
                encoding: .utf8
            )
            try FileManager.default.createSymbolicLink(
                at: root.appendingPathComponent("linked"),
                withDestinationURL: outside
            )

            let result = try SkillDiscoveryScanner().scan(roots: [
                SkillDiscoveryRoot(scope: .global, url: root),
            ])

            let observation = try #require(result.observations.first)
            #expect(observation.status == .unmanaged)
            #expect(observation.reason == nil)
            #expect(observation.fingerprint != nil)
            #expect(observation.candidateIdentity != nil)
            #expect(observation.symbolicLinkIdentity != nil)
        }
    }

    @Test("an external-volume root symlink is a valid registered root")
    func externalVolumeRootSymlinkIsSupported() throws {
        try withWorkspace { workspace in
            let physicalRoot = workspace.appendingPathComponent("volume-skills", isDirectory: true)
            let registeredRoot = workspace.appendingPathComponent("skills", isDirectory: true)
            try FileManager.default.createDirectory(
                at: physicalRoot,
                withIntermediateDirectories: false
            )
            _ = try createSkill(named: "demo", in: physicalRoot)
            try FileManager.default.createSymbolicLink(
                at: registeredRoot,
                withDestinationURL: physicalRoot
            )

            let result = try SkillDiscoveryScanner().scan(roots: [
                SkillDiscoveryRoot(scope: .global, url: registeredRoot),
            ])

            let observation = try #require(result.observations.first)
            #expect(result.rootDiagnostics.isEmpty)
            #expect(observation.status == .unmanaged)
            #expect(observation.symbolicLinkIdentity == nil)
        }
    }

    @Test("broken and non-directory Skill links have precise reasons")
    func invalidSkillLinksAreClassified() throws {
        try withWorkspace { workspace in
            let root = workspace.appendingPathComponent("skills", isDirectory: true)
            let file = workspace.appendingPathComponent("file")
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
            try Data("not a Skill".utf8).write(to: file)
            try FileManager.default.createSymbolicLink(
                at: root.appendingPathComponent("broken"),
                withDestinationURL: workspace.appendingPathComponent("missing")
            )
            try FileManager.default.createSymbolicLink(
                at: root.appendingPathComponent("file-link"),
                withDestinationURL: file
            )

            let result = try SkillDiscoveryScanner().scan(roots: [
                SkillDiscoveryRoot(scope: .global, url: root),
            ])

            #expect(result.observations.contains {
                $0.relativeLocator == "broken"
                    && $0.status == .damaged
                    && $0.reason == .symbolicLinkTargetUnavailable
            })
            #expect(result.observations.contains {
                $0.relativeLocator == "file-link"
                    && $0.status == .damaged
                    && $0.reason == .symbolicLinkTargetUnsupported
            })
        }
    }

    @Test("an unreadable external Skill link target reports permission denied")
    func unreadableExternalSkillLinkIsClassified() throws {
        try withWorkspace { workspace in
            let root = workspace.appendingPathComponent("skills", isDirectory: true)
            let outside = workspace.appendingPathComponent("outside", isDirectory: true)
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
            try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: false)
            try "# Outside".write(
                to: outside.appendingPathComponent("SKILL.md"),
                atomically: true,
                encoding: .utf8
            )
            try FileManager.default.createSymbolicLink(
                at: root.appendingPathComponent("linked"),
                withDestinationURL: outside
            )
            #expect(Darwin.chmod(outside.path, 0) == 0)
            defer { _ = Darwin.chmod(outside.path, S_IRWXU) }

            let result = try SkillDiscoveryScanner().scan(roots: [
                SkillDiscoveryRoot(scope: .global, url: root),
            ])

            let observation = try #require(result.observations.first)
            #expect(observation.status == .permissionDenied)
            #expect(observation.reason == .candidatePermissionDenied)
        }
    }

    @Test("ordinary Skill containers are distinguished from malformed Skills")
    func containerDirectoriesAreClassified() throws {
        try withWorkspace { workspace in
            let root = workspace.appendingPathComponent("skills", isDirectory: true)
            let container = root.appendingPathComponent("container", isDirectory: true)
            let malformed = root.appendingPathComponent("malformed", isDirectory: true)
            try FileManager.default.createDirectory(at: container, withIntermediateDirectories: true)
            _ = try createSkill(named: "nested", in: container)
            try FileManager.default.createDirectory(
                at: malformed,
                withIntermediateDirectories: false
            )

            let result = try SkillDiscoveryScanner().scan(roots: [
                SkillDiscoveryRoot(scope: .global, url: root),
            ])

            #expect(result.observations.contains {
                $0.relativeLocator == "container" && $0.reason == .containerDirectory
            })
            #expect(result.observations.contains {
                $0.relativeLocator == "malformed" && $0.reason == .missingSkillManifest
            })
        }
    }

    @Test("mixed containers with links remain blocked")
    func mixedContainerIsNotDowngraded() throws {
        try withWorkspace { workspace in
            let root = workspace.appendingPathComponent("skills", isDirectory: true)
            let container = root.appendingPathComponent("container", isDirectory: true)
            let outside = workspace.appendingPathComponent("outside", isDirectory: true)
            try FileManager.default.createDirectory(at: container, withIntermediateDirectories: true)
            _ = try createSkill(named: "nested", in: container)
            _ = try createSkill(named: "outside", in: workspace)
            try FileManager.default.createSymbolicLink(
                at: container.appendingPathComponent("linked"),
                withDestinationURL: outside
            )

            let result = try SkillDiscoveryScanner().scan(roots: [
                SkillDiscoveryRoot(scope: .global, url: root),
            ])

            let observation = try #require(result.observations.first)
            #expect(observation.reason == .unsupportedEntryType)
            #expect(observation.reason != .containerDirectory)
        }
    }

    @Test("mixed containers with unreadable children remain blocked")
    func unreadableMixedContainerIsNotDowngraded() throws {
        try withWorkspace { workspace in
            let root = workspace.appendingPathComponent("skills", isDirectory: true)
            let container = root.appendingPathComponent("container", isDirectory: true)
            let unreadable = container.appendingPathComponent("unreadable", isDirectory: true)
            try FileManager.default.createDirectory(at: container, withIntermediateDirectories: true)
            _ = try createSkill(named: "nested", in: container)
            try FileManager.default.createDirectory(
                at: unreadable,
                withIntermediateDirectories: false
            )
            #expect(Darwin.chmod(unreadable.path, 0) == 0)
            defer { _ = Darwin.chmod(unreadable.path, S_IRWXU) }

            let result = try SkillDiscoveryScanner().scan(roots: [
                SkillDiscoveryRoot(scope: .global, url: root),
            ])

            let observation = try #require(result.observations.first)
            #expect(observation.reason == .candidatePermissionDenied)
            #expect(observation.reason != .containerDirectory)
        }
    }

    @Test("container inspection rejects manifest additions and removals after snapshot")
    func containerManifestChangesFailClosed() throws {
        for removesManifest in [false, true] {
            try withWorkspace { workspace in
                let container = workspace.appendingPathComponent("container", isDirectory: true)
                let child = container.appendingPathComponent("nested", isDirectory: true)
                try FileManager.default.createDirectory(
                    at: child,
                    withIntermediateDirectories: true
                )
                let manifest = child.appendingPathComponent("SKILL.md")
                if removesManifest {
                    try "# Nested".write(to: manifest, atomically: true, encoding: .utf8)
                }
                let descriptor = Darwin.open(
                    container.path,
                    O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC
                )
                #expect(descriptor >= 0)
                defer { Darwin.close(descriptor) }
                let snapshot = try SkillContentSnapshot.capture(
                    directoryDescriptor: descriptor,
                    displayPath: "container"
                )
                let scanner = SkillDiscoveryScanner()
                let expected = scanner.directChildSkillManifestDirectories(in: snapshot)

                if removesManifest {
                    try FileManager.default.removeItem(at: manifest)
                } else {
                    try "# Nested".write(to: manifest, atomically: true, encoding: .utf8)
                }

                #expect(throws: SkillContentSnapshotError.fileChanged(path: "container")) {
                    _ = try scanner.isContainerDirectory(
                        descriptor: descriptor,
                        displayPath: "container",
                        expectedSkillDirectories: expected,
                        checkpoint: {}
                    )
                }
            }
        }
    }
}
