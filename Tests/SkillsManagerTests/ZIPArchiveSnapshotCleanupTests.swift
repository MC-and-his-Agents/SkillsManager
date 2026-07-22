import Darwin
import Foundation
import Testing

@testable import SkillsManager

@Suite("ZIP archive snapshot cleanup")
struct ZIPArchiveSnapshotCleanupTests {
    @Test("snapshot anonymity preserves a quarantine replacement")
    func snapshotCleanupPreservesReplacement() throws {
        let temporary = FileManager.default.temporaryDirectory.appendingPathComponent(
            "skillsmanager-snapshot-cleanup-\(UUID().uuidString)",
            isDirectory: true
        )
        try FileManager.default.createDirectory(at: temporary, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: temporary) }
        let source = temporary.appendingPathComponent("source.zip")
        let destination = temporary.appendingPathComponent("destination", isDirectory: true)
        let displaced = temporary.appendingPathComponent("displaced-snapshot")
        try Data("archive".utf8).write(to: source)
        try FileManager.default.createDirectory(
            at: destination,
            withIntermediateDirectories: false
        )
        let rootDescriptor = Darwin.open(
            destination.path,
            O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC
        )
        #expect(rootDescriptor >= 0)
        defer { Darwin.close(rootDescriptor) }
        var replacementURL: URL?

        #expect(throws: POSIXError.self) {
            _ = try ZIPArchiveSnapshot(
                copying: source,
                into: rootDescriptor,
                maximumByteCount: 1_024,
                checkpoint: {},
                beforeSnapshotUnlink: { quarantine in
                    let replacement = destination.appendingPathComponent(quarantine)
                    replacementURL = replacement
                    try? FileManager.default.moveItem(at: replacement, to: displaced)
                    try? Data("replacement".utf8).write(to: replacement)
                }
            )
        }

        let replacement = try #require(replacementURL)
        #expect(try String(contentsOf: replacement, encoding: .utf8) == "replacement")
        #expect(FileManager.default.fileExists(atPath: displaced.path))
    }
}
