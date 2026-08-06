import Darwin
import Foundation
import Testing

@testable import SkillsManager

@Suite("DistributionSymlinkFileSystem", .serialized)
struct DistributionSymlinkFileSystemTests {
    @Test("captures distribution destinations under the supplied home")
    func capturesDestinationUnderExplicitHome() throws {
        let home = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: home) }
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: false)
        let fileSystem = try DistributionSymlinkFileSystem(homeURL: home)
        let entry = DistributionTargetEntry(
            target: DistributionTarget(scope: .global, rootLocator: "~/.agents/skills"),
            distributionSlug: try DefaultDistributionSlug(validating: "captured"),
            canonicalLocator: "~/.agents/skills/captured"
        )

        let expected = home
            .appendingPathComponent(".agents/skills/captured", isDirectory: true)
            .standardizedFileURL
        #expect(try fileSystem.absoluteTargetURL(for: entry) == expected)
        #expect(try fileSystem.captureAbsoluteTarget(for: entry) == expected.path)
    }

    @Test("capture resolves from the held home and ignores locator strings")
    func captureIgnoresLocatorStrings() throws {
        let home = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: home) }
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: false)
        let fileSystem = try DistributionSymlinkFileSystem(homeURL: home)
        let entry = DistributionTargetEntry(
            target: DistributionTarget(scope: .global, rootLocator: "~/../../etc"),
            distributionSlug: try DefaultDistributionSlug(validating: "escape"),
            canonicalLocator: "~/../../etc/escape"
        )

        let resolved = try fileSystem.absoluteTargetURL(for: entry).path
        #expect(resolved.hasPrefix(home.standardizedFileURL.path + "/"))
        #expect(!resolved.contains(".."))
    }

    @Test("creates, observes, quarantines, restores, and cleans a managed link")
    func lifecycle() throws {
        let home = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: home) }
        let skillID = SkillID()
        let ssot = home
            .appendingPathComponent(".SkillsManager/skills", isDirectory: true)
            .appendingPathComponent(skillID.directoryName, isDirectory: true)
        try FileManager.default.createDirectory(at: ssot, withIntermediateDirectories: true)

        let fileSystem = try DistributionSymlinkFileSystem(homeURL: home)
        let scope: DistributionBindingScope = .global
        let slug = try DefaultDistributionSlug(validating: "demo")
        let entry = DistributionTargetEntry(
            target: DistributionTarget(scope: scope, rootLocator: "~/.agents/skills"),
            distributionSlug: slug,
            canonicalLocator: "~/.agents/skills/demo"
        )
        #expect(try fileSystem.observe(entry) == .missing(rootIdentity: nil))
        let rootIdentity = try fileSystem.ensureRoot(for: scope)
        let target = try fileSystem.ssotEvidence(for: skillID).absoluteTarget
        let evidence = try fileSystem.create(
            entry,
            absoluteTarget: target,
            expectedRootIdentity: rootIdentity
        )
        #expect(try fileSystem.observe(entry) == .symlink(
            rootIdentity: evidence.rootIdentity,
            entryIdentity: evidence.entryIdentity,
            target: target
        ))
        let operationID = UUID()
        let quarantined = try fileSystem.quarantine(
            entry,
            expected: evidence,
            operationID: operationID,
            actionIndex: 0
        )
        try fileSystem.restore(entry, quarantined: quarantined)
        try fileSystem.restore(entry, quarantined: quarantined)
        let secondQuarantine = try fileSystem.quarantine(
            entry,
            expected: evidence,
            operationID: operationID,
            actionIndex: 1
        )
        try fileSystem.cleanup(entry, quarantined: secondQuarantine)
        try fileSystem.cleanup(entry, quarantined: secondQuarantine)
        #expect(try fileSystem.observe(entry) == .missing(rootIdentity: evidence.rootIdentity))

        let recreated = try fileSystem.create(
            entry,
            absoluteTarget: target,
            expectedRootIdentity: evidence.rootIdentity
        )
        try fileSystem.removeCreated(entry, expected: recreated)
        try fileSystem.removeCreated(entry, expected: recreated)
    }

    @Test("classifies a dangling intermediate symlink as unavailable")
    func danglingIntermediateRootIsUnavailable() throws {
        let home = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: home) }
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(
            at: home.appendingPathComponent(".agents"),
            withDestinationURL: home.appendingPathComponent("missing-agents")
        )

        let fileSystem = try DistributionSymlinkFileSystem(homeURL: home)
        let entry = DistributionTargetEntry(
            target: DistributionTarget(
                scope: .global,
                rootLocator: "~/.agents/skills"
            ),
            distributionSlug: try DefaultDistributionSlug(validating: "demo"),
            canonicalLocator: "~/.agents/skills/demo"
        )
        #expect(try fileSystem.observe(entry) == .unavailable)
    }
}
