import Darwin
import Foundation
import Testing

@testable import SkillsManager

@Suite("Managed path guard failures")
@MainActor
struct ManagedPathGuardFailureTests {
    private let fileManager = FileManager.default

    @Test("removal bound to an observed identity preserves a newer item")
    func removalRejectsStaleExpectedIdentity() throws {
        try withFixture { _, root, guardValue in
            let target = root.appendingPathComponent("skill")
            let old = root.appendingPathComponent("old")
            try "old".write(to: target, atomically: true, encoding: .utf8)
            let observed = try guardValue.itemIdentity(at: target)
            let expected = try #require(observed)
            try fileManager.moveItem(at: target, to: old)
            try "new".write(to: target, atomically: true, encoding: .utf8)

            #expect(throws: ManagedPathError.itemChanged) {
                try guardValue.removeItem(at: target, expectedIdentity: expected)
            }
            #expect(try String(contentsOf: target, encoding: .utf8) == "new")
        }
    }

    @Test("cleanup failure preserves the committed replacement and old contents")
    func cleanupFailurePreservesCommittedState() throws {
        try withTemporaryDirectory { temporary in
            let root = temporary.appendingPathComponent("managed")
            let staged = root.appendingPathComponent(".staged")
            let target = root.appendingPathComponent("skill")
            try fileManager.createDirectory(at: root, withIntermediateDirectories: false)
            try "new".write(to: staged, atomically: true, encoding: .utf8)
            try "old".write(to: target, atomically: true, encoding: .utf8)
            let cleanupError = ManagedPathError.posix(operation: "injected cleanup", code: EIO)
            let observer = try ManagedPathGuard(rootURL: root)
            let observed = try observer.itemIdentity(at: target)
            let expected = try #require(observed)
            let observedStaged = try observer.itemIdentity(at: staged)
            let expectedStaged = try #require(observedStaged)
            let hooks = ManagedPathGuardTestHooks(
                beforeCleanup: { throw cleanupError }
            )
            let guardValue = try ManagedPathGuard(rootURL: root, hooks: hooks)

            let result = try guardValue.replaceStagedItem(
                at: staged,
                to: target,
                expectedStaged: expectedStaged,
                expectedTarget: expected,
                validateStaged: { _ in }
            )

            #expect(result == .committedWithCleanupDebt(staged, cleanupError))
            #expect(try String(contentsOf: target, encoding: .utf8) == "new")
            #expect(try String(contentsOf: staged, encoding: .utf8) == "old")
        }
    }

    @Test("no-replace promotion never moves a concurrent target during post-check")
    func noReplacePreservesConcurrentTarget() throws {
        try withTemporaryDirectory { temporary in
            let root = temporary.appendingPathComponent("managed")
            let staged = root.appendingPathComponent(".staged")
            let target = root.appendingPathComponent("skill")
            let committed = root.appendingPathComponent("committed")
            try fileManager.createDirectory(at: root, withIntermediateDirectories: false)
            try "validated".write(to: staged, atomically: true, encoding: .utf8)
            let observer = try ManagedPathGuard(rootURL: root)
            let expectedStaged = try #require(try observer.itemIdentity(at: staged))
            let hooks = ManagedPathGuardTestHooks(afterNoReplaceCommit: {
                try self.fileManager.moveItem(at: target, to: committed)
                try "newer".write(to: target, atomically: true, encoding: .utf8)
            })
            let guardValue = try ManagedPathGuard(rootURL: root, hooks: hooks)

            #expect(throws: ManagedPromotionIndeterminate.self) {
                try guardValue.promoteStagedItemIfAbsent(
                    at: staged,
                    to: target,
                    expectedStaged: expectedStaged,
                    validateStaged: { _ in }
                )
            }
            #expect(try String(contentsOf: target, encoding: .utf8) == "newer")
            #expect(try String(contentsOf: committed, encoding: .utf8) == "validated")
            #expect(!fileManager.fileExists(atPath: staged.path))
        }
    }

    @Test("replacement never swaps a concurrent target during post-check")
    func replacementPreservesConcurrentTargetAndRecovery() throws {
        try withTemporaryDirectory { temporary in
            let root = temporary.appendingPathComponent("managed")
            let staged = root.appendingPathComponent(".staged")
            let target = root.appendingPathComponent("skill")
            let committed = root.appendingPathComponent("committed")
            try fileManager.createDirectory(at: root, withIntermediateDirectories: false)
            try "validated".write(to: staged, atomically: true, encoding: .utf8)
            try "old".write(to: target, atomically: true, encoding: .utf8)
            let observer = try ManagedPathGuard(rootURL: root)
            let expectedStaged = try #require(try observer.itemIdentity(at: staged))
            let expectedTarget = try #require(try observer.itemIdentity(at: target))
            let hooks = ManagedPathGuardTestHooks(afterReplaceCommit: {
                try self.fileManager.moveItem(at: target, to: committed)
                try "newer".write(to: target, atomically: true, encoding: .utf8)
            })
            let guardValue = try ManagedPathGuard(rootURL: root, hooks: hooks)

            do {
                _ = try guardValue.replaceStagedItem(
                    at: staged,
                    to: target,
                    expectedStaged: expectedStaged,
                    expectedTarget: expectedTarget,
                    validateStaged: { _ in }
                )
                Issue.record("Expected an indeterminate post-commit state")
            } catch let error as ManagedPromotionIndeterminate {
                #expect(error.recoveryURL == staged)
            }
            #expect(try String(contentsOf: target, encoding: .utf8) == "newer")
            #expect(try String(contentsOf: staged, encoding: .utf8) == "old")
            #expect(try String(contentsOf: committed, encoding: .utf8) == "validated")
        }
    }

    @Test("replacement rechecks the target after old-content cleanup")
    func replacementDetectsPostCleanupTargetChange() throws {
        try withTemporaryDirectory { temporary in
            let root = temporary.appendingPathComponent("managed")
            let staged = root.appendingPathComponent(".staged")
            let target = root.appendingPathComponent("skill")
            let committed = root.appendingPathComponent("committed")
            try fileManager.createDirectory(at: root, withIntermediateDirectories: false)
            try "validated".write(to: staged, atomically: true, encoding: .utf8)
            try "old".write(to: target, atomically: true, encoding: .utf8)
            let observer = try ManagedPathGuard(rootURL: root)
            let expectedStaged = try #require(try observer.itemIdentity(at: staged))
            let expectedTarget = try #require(try observer.itemIdentity(at: target))
            let hooks = ManagedPathGuardTestHooks(afterCleanup: {
                try self.fileManager.moveItem(at: target, to: committed)
                try "newer".write(to: target, atomically: true, encoding: .utf8)
            })
            let guardValue = try ManagedPathGuard(rootURL: root, hooks: hooks)

            #expect(throws: ManagedPromotionIndeterminate.self) {
                _ = try guardValue.replaceStagedItem(
                    at: staged,
                    to: target,
                    expectedStaged: expectedStaged,
                    expectedTarget: expectedTarget,
                    validateStaged: { _ in }
                )
            }
            #expect(try String(contentsOf: target, encoding: .utf8) == "newer")
            #expect(try String(contentsOf: committed, encoding: .utf8) == "validated")
            #expect(!fileManager.fileExists(atPath: staged.path))
        }
    }

    private func withFixture(
        _ body: (URL, URL, ManagedPathGuard) throws -> Void
    ) throws {
        try withTemporaryDirectory { temporary in
            let root = temporary.appendingPathComponent("managed")
            try fileManager.createDirectory(at: root, withIntermediateDirectories: false)
            try body(temporary, root, ManagedPathGuard(rootURL: root))
        }
    }

    private func withTemporaryDirectory(_ body: (URL) throws -> Void) throws {
        let temporary = fileManager.temporaryDirectory
            .appendingPathComponent("ManagedPathGuardFailureTests-\(UUID().uuidString)")
        try fileManager.createDirectory(at: temporary, withIntermediateDirectories: false)
        defer { try? fileManager.removeItem(at: temporary) }
        try body(temporary)
    }
}
