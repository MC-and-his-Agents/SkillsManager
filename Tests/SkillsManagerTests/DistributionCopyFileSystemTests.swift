import Darwin
import Foundation
import Testing

@testable import SkillsManager

@Suite("Distribution Copy file system", .serialized)
struct DistributionCopyFileSystemTests {
    @Test("stages, promotes, quarantines, restores, and safely cleans a Copy")
    func lifecycle() throws {
        let fixture = try CopyFileSystemFixture()
        defer { fixture.cleanup() }
        let source = try fixture.fileSystem.copySource(for: fixture.skillID)
        let root = try fixture.fileSystem.ensureRoot(for: .global)
        let staged = try fixture.fileSystem.stageCopy(
            fixture.entry,
            source: source,
            expectedRootIdentity: root,
            operationID: UUID(),
            actionIndex: 0
        )
        try fixture.fileSystem.requireUnchanged(source, skillID: fixture.skillID)
        let promoted = try fixture.fileSystem.promoteCopy(fixture.entry, staged: staged)
        #expect(try fixture.fileSystem.observeCopy(fixture.entry) == .directory(promoted))

        let quarantined = try fixture.fileSystem.quarantineCopy(
            fixture.entry,
            expected: promoted,
            operationID: UUID(),
            actionIndex: 1
        )
        try fixture.fileSystem.restoreCopy(fixture.entry, quarantined: quarantined)
        let second = try fixture.fileSystem.quarantineCopy(
            fixture.entry,
            expected: promoted,
            operationID: UUID(),
            actionIndex: 2
        )
        try fixture.fileSystem.cleanupCopy(fixture.entry, quarantined: second)
        #expect(try fixture.fileSystem.observeCopy(fixture.entry)
            == .missing(rootIdentity: root))
    }

    @Test("extra excluded entries and hardlinks are physical drift")
    func detectsPhysicalDrift() throws {
        let fixture = try CopyFileSystemFixture()
        defer { fixture.cleanup() }
        let evidence = try fixture.installCopy()
        let copyURL = fixture.copyURL
        try Data("finder".utf8).write(to: copyURL.appendingPathComponent(".DS_Store"))
        let changed = try #require(copyObservation(
            try fixture.fileSystem.observeCopy(fixture.entry)
        ))
        #expect(changed.contentFingerprint == evidence.contentFingerprint)
        #expect(changed.physicalTreeDigest != evidence.physicalTreeDigest)
        #expect(throws: DistributionSymlinkFileSystemError.self) {
            try fixture.fileSystem.removeCreatedCopy(fixture.entry, expected: evidence)
        }
        #expect(FileManager.default.fileExists(atPath: copyURL.path))

        try FileManager.default.removeItem(at: copyURL.appendingPathComponent(".DS_Store"))
        let outside = fixture.home.appendingPathComponent("outside")
        try Data("outside".utf8).write(to: outside)
        try FileManager.default.linkItem(
            at: outside,
            to: copyURL.appendingPathComponent("hardlink")
        )
        guard case .invalid = try fixture.fileSystem.observeCopy(fixture.entry) else {
            Issue.record("Expected a hardlink to be rejected")
            return
        }
    }

    @Test("source hardlinks and symlinks are rejected")
    func rejectsUnsafeSourceEntries() throws {
        let fixture = try CopyFileSystemFixture()
        defer { fixture.cleanup() }
        let outside = fixture.home.appendingPathComponent("outside")
        try Data("outside".utf8).write(to: outside)
        try FileManager.default.linkItem(
            at: outside,
            to: fixture.ssot.appendingPathComponent("hardlink")
        )
        #expect(throws: SkillContentSnapshotError.self) {
            _ = try fixture.fileSystem.copySource(for: fixture.skillID)
        }
        try FileManager.default.removeItem(at: fixture.ssot.appendingPathComponent("hardlink"))
        try FileManager.default.createSymbolicLink(
            at: fixture.ssot.appendingPathComponent("link"),
            withDestinationURL: outside
        )
        #expect(throws: SkillContentSnapshotError.self) {
            _ = try fixture.fileSystem.copySource(for: fixture.skillID)
        }
        try FileManager.default.removeItem(at: fixture.ssot.appendingPathComponent("link"))
        let excluded = fixture.ssot.appendingPathComponent(".git", isDirectory: true)
        try FileManager.default.createDirectory(
            at: excluded,
            withIntermediateDirectories: false
        )
        try FileManager.default.createSymbolicLink(
            at: excluded.appendingPathComponent("link"),
            withDestinationURL: outside
        )
        #expect(throws: SkillContentSnapshotError.self) {
            _ = try fixture.fileSystem.copySource(for: fixture.skillID)
        }
    }
}

private final class CopyFileSystemFixture {
    let home: URL
    let skillID = SkillID()
    let ssot: URL
    let fileSystem: DistributionSymlinkFileSystem
    let entry: DistributionTargetEntry

    init() throws {
        home = FileManager.default.temporaryDirectory
            .appendingPathComponent("distribution-copy-\(UUID().uuidString)", isDirectory: true)
        ssot = home
            .appendingPathComponent(".SkillsManager/skills", isDirectory: true)
            .appendingPathComponent(skillID.directoryName, isDirectory: true)
        try FileManager.default.createDirectory(
            at: ssot.appendingPathComponent("empty", isDirectory: true),
            withIntermediateDirectories: true
        )
        try Data([0, 1, 2, 255]).write(to: ssot.appendingPathComponent("SKILL.md"))
        let unicode = ssot.appendingPathComponent("目录", isDirectory: true)
        try FileManager.default.createDirectory(
            at: unicode,
            withIntermediateDirectories: false
        )
        try Data("内容".utf8).write(
            to: unicode.appendingPathComponent("文件.txt")
        )
        let readOnly = ssot.appendingPathComponent("read-only", isDirectory: true)
        try FileManager.default.createDirectory(
            at: readOnly,
            withIntermediateDirectories: false
        )
        try Data("nested".utf8).write(
            to: readOnly.appendingPathComponent("nested.txt")
        )
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o555],
            ofItemAtPath: readOnly.path
        )
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o750],
            ofItemAtPath: ssot.appendingPathComponent("empty").path
        )
        fileSystem = try DistributionSymlinkFileSystem(homeURL: home)
        let slug = try DefaultDistributionSlug(validating: "demo")
        entry = DistributionTargetEntry(
            target: DistributionTarget(scope: .global, rootLocator: "~/.agents/skills"),
            distributionSlug: slug,
            canonicalLocator: "~/.agents/skills/demo"
        )
    }

    var copyURL: URL {
        home.appendingPathComponent(".agents/skills/demo", isDirectory: true)
    }

    func installCopy() throws -> DistributionCopyEvidence {
        let source = try fileSystem.copySource(for: skillID)
        let root = try fileSystem.ensureRoot(for: .global)
        let staged = try fileSystem.stageCopy(
            entry,
            source: source,
            expectedRootIdentity: root,
            operationID: UUID(),
            actionIndex: 0
        )
        return try fileSystem.promoteCopy(entry, staged: staged)
    }

    func cleanup() {
        try? FileManager.default.removeItem(at: home)
    }
}

private func copyObservation(
    _ observation: DistributionCopyFilesystemObservation
) -> DistributionCopyEvidence? {
    if case .directory(let evidence) = observation { evidence } else { nil }
}
