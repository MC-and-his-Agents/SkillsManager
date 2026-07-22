import Darwin
import Foundation
import Testing

@testable import SkillsManager

@Suite("SSOT durability")
struct SSOTDurabilityTests {
    @Test("file and directory checkpoints accept anchored descriptors")
    func checkpointsAnchoredDescriptors() throws {
        try withTemporaryDirectory { root in
            let staging = root.appendingPathComponent("staging", isDirectory: true)
            let file = staging.appendingPathComponent("SKILL.md")
            try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: false)
            try Data("content".utf8).write(to: file)

            let rootDescriptor = Darwin.open(root.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
            let stagingDescriptor = Darwin.open(
                staging.path,
                O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC
            )
            let fileDescriptor = Darwin.open(file.path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
            #expect(rootDescriptor >= 0)
            #expect(stagingDescriptor >= 0)
            #expect(fileDescriptor >= 0)
            defer {
                if rootDescriptor >= 0 { Darwin.close(rootDescriptor) }
                if stagingDescriptor >= 0 { Darwin.close(stagingDescriptor) }
                if fileDescriptor >= 0 { Darwin.close(fileDescriptor) }
            }

            try SSOTDurability.syncFile(fileDescriptor)
            try SSOTDurability.syncDirectory(stagingDescriptor)
            try SSOTDurability.syncDirectory(rootDescriptor)
        }
    }

    @Test("invalid descriptors report a structured sync failure")
    func rejectsInvalidDescriptor() throws {
        do {
            try SSOTDurability.syncDirectory(-1)
            Issue.record("Expected an invalid descriptor to fail")
        } catch let error as SSOTDurabilityError {
            guard case .posix(let operation, let code) = error else {
                Issue.record("Unexpected error: \(error)")
                return
            }
            #expect(operation == "sync managed directory")
            #expect(code == EBADF)
        }
    }

    @Test("item revalidation rejects a replaced direct child")
    func rejectsReplacedItem() throws {
        try withTemporaryDirectory { root in
            let item = root.appendingPathComponent("item")
            try Data("original".utf8).write(to: item)
            let guardValue = try ManagedPathGuard(rootURL: root)
            let expectedRoot = try ManagedItemIdentityCodec.capture(
                descriptor: guardValue.rootDescriptor
            )
            let expectedItem = try #require(try guardValue.itemIdentity(at: item))

            try SSOTIdentityRevalidator.requireRoot(
                guardValue,
                expectedIdentity: expectedRoot
            )
            try FileManager.default.removeItem(at: item)
            try Data("replacement".utf8).write(to: item)

            #expect(throws: ManagedPathError.itemChanged) {
                try SSOTIdentityRevalidator.requireItem(
                    at: item,
                    in: guardValue,
                    expectedIdentity: expectedItem
                )
            }
        }
    }

    private func withTemporaryDirectory(_ body: (URL) throws -> Void) throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: url) }
        try body(url)
    }
}
