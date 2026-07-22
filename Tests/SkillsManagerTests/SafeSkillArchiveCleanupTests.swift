import Darwin
import Foundation
import Testing

@testable import SkillsManager

extension SafeSkillArchiveTests {
    @Test("Atomic cleanup preserves a replacement created before unlink")
    func atomicCleanupPreservesReplacementInUnlinkWindow() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let original = fixture.destinationURL.appendingPathComponent("entry")
        try Data("original".utf8).write(to: original)
        let descriptor = Darwin.open(original.path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
        #expect(descriptor >= 0)
        defer { Darwin.close(descriptor) }
        var metadata = stat()
        #expect(Darwin.fstat(descriptor, &metadata) == 0)
        let expectedIdentity = ManagedItemIdentity(metadata)
        let parent = Darwin.open(
            fixture.destinationURL.path,
            O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC
        )
        #expect(parent >= 0)
        defer { Darwin.close(parent) }

        #expect(unlinkCreatedFileIfUnchanged(
            named: original.lastPathComponent,
            in: parent,
            expectedIdentity: expectedIdentity,
            beforeUnlink: {
                try? Data("concurrent".utf8).write(to: original)
            }
        ))
        #expect(try String(contentsOf: original, encoding: .utf8) == "concurrent")
    }

    @Test("Cleanup does not restore a replaced quarantine object")
    func cleanupDoesNotRestoreUnknownQuarantineIdentity() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let original = fixture.destinationURL.appendingPathComponent("entry")
        let expectedDisplaced = fixture.destinationURL.appendingPathComponent("expected-displaced")
        let displaced = fixture.destinationURL.appendingPathComponent("displaced")
        try Data("original".utf8).write(to: original)
        let descriptor = Darwin.open(original.path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
        #expect(descriptor >= 0)
        defer { Darwin.close(descriptor) }
        var metadata = stat()
        #expect(Darwin.fstat(descriptor, &metadata) == 0)
        let expectedIdentity = ManagedItemIdentity(metadata)
        try FileManager.default.moveItem(at: original, to: expectedDisplaced)
        try Data("concurrent".utf8).write(to: original)
        let parent = Darwin.open(
            fixture.destinationURL.path,
            O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC
        )
        #expect(parent >= 0)
        defer { Darwin.close(parent) }
        var quarantinePath: URL?

        #expect(!unlinkCreatedFileIfUnchanged(
            named: original.lastPathComponent,
            in: parent,
            expectedIdentity: expectedIdentity,
            beforeRestore: { quarantine in
                let path = fixture.destinationURL.appendingPathComponent(quarantine)
                quarantinePath = path
                try? FileManager.default.moveItem(at: path, to: displaced)
                try? Data("unknown".utf8).write(to: path)
            }
        ))
        #expect(!FileManager.default.fileExists(atPath: original.path))
        #expect(try String(contentsOf: expectedDisplaced, encoding: .utf8) == "original")
        #expect(try String(contentsOf: displaced, encoding: .utf8) == "concurrent")
        let retained = try #require(quarantinePath)
        #expect(try String(contentsOf: retained, encoding: .utf8) == "unknown")
    }
}
