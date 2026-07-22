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
}
