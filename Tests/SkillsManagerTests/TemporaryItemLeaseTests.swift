import Foundation
import Testing

@testable import SkillsManager

@Suite("Temporary item leases")
struct TemporaryItemLeaseTests {
    @Test("directory cleanup preserves a replacement and the displaced owned directory")
    func directoryCleanupPreservesReplacement() throws {
        try withTemporaryDirectory { parent in
            let temporary = try TemporaryItemLease.createDirectory(
                in: parent,
                prefix: "skillsmanager-test-"
            )
            let displaced = parent.appendingPathComponent("displaced", isDirectory: true)
            let sentinel = temporary.lease.url.appendingPathComponent("sentinel.txt")
            try FileManager.default.moveItem(at: temporary.lease.url, to: displaced)
            try FileManager.default.createDirectory(
                at: temporary.lease.url,
                withIntermediateDirectories: false
            )
            try Data("replacement".utf8).write(to: sentinel)

            #expect(throws: ManagedPathError.self) {
                try temporary.lease.removeIfCurrent()
            }

            #expect(try String(contentsOf: sentinel, encoding: .utf8) == "replacement")
            #expect(FileManager.default.fileExists(atPath: displaced.path))
        }
    }

    @Test("repeated cleanup is idempotent after the owned directory is gone")
    func repeatedCleanupIsIdempotent() throws {
        try withTemporaryDirectory { parent in
            let temporary = try TemporaryItemLease.createDirectory(
                in: parent,
                prefix: "skillsmanager-test-"
            )

            try temporary.lease.removeIfCurrent()
            try temporary.lease.removeIfCurrent()

            #expect(!FileManager.default.fileExists(atPath: temporary.lease.url.path))
        }
    }

    @Test("cleanup rejects a replaced temporary parent")
    func cleanupRejectsReplacedParent() throws {
        try withTemporaryDirectory { outer in
            let parent = outer.appendingPathComponent("temporary", isDirectory: true)
            let displaced = outer.appendingPathComponent("displaced", isDirectory: true)
            try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: false)
            let temporary = try TemporaryItemLease.createDirectory(
                in: parent,
                prefix: "skillsmanager-test-"
            )
            try FileManager.default.moveItem(at: parent, to: displaced)
            try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: false)
            let sentinel = parent.appendingPathComponent(temporary.lease.url.lastPathComponent)
            try Data("replacement".utf8).write(to: sentinel)

            #expect(throws: ManagedRootReferenceError.rootChanged) {
                try temporary.lease.removeIfCurrent()
            }
            #expect(try String(contentsOf: sentinel, encoding: .utf8) == "replacement")
            #expect(FileManager.default.fileExists(
                atPath: displaced.appendingPathComponent(temporary.lease.url.lastPathComponent).path
            ))
        }
    }

    private func withTemporaryDirectory(_ body: (URL) throws -> Void) throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(
            "temporary-item-lease-tests-\(UUID().uuidString.lowercased())",
            isDirectory: true
        )
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: root) }
        try body(root)
    }
}
