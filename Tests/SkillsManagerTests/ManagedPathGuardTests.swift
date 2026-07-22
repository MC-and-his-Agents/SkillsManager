import Darwin
import Foundation
import Testing

@testable import SkillsManager

@Suite("Managed path guard")
@MainActor
struct ManagedPathGuardTests {
    let fileManager = FileManager.default

    @Test("root must be an existing real directory")
    func rootValidation() throws {
        try withTemporaryDirectory { temporary in
            let missing = temporary.appendingPathComponent("missing")
            #expect(throws: ManagedPathError.self) {
                try ManagedPathGuard(rootURL: missing)
            }

            let file = temporary.appendingPathComponent("file")
            try Data().write(to: file)
            #expect(throws: ManagedPathError.self) {
                try ManagedPathGuard(rootURL: file)
            }

            let directory = temporary.appendingPathComponent("directory")
            let link = temporary.appendingPathComponent("directory-link")
            try fileManager.createDirectory(at: directory, withIntermediateDirectories: false)
            try fileManager.createSymbolicLink(at: link, withDestinationURL: directory)
            #expect(throws: ManagedPathError.self) {
                try ManagedPathGuard(rootURL: link)
            }
        }
    }

    @Test("only direct children are accepted")
    func rejectsRootSiblingTraversalPrefixAndDescendants() throws {
        try withFixture { temporary, root, guardValue in
            let sibling = temporary.appendingPathComponent("sibling")
            let similarPrefix = temporary.appendingPathComponent("managed-other/item")
            let traversal = URL(fileURLWithPath: root.path + "/../sibling")
            let descendant = root.appendingPathComponent("skill/nested")

            #expect(throws: ManagedPathError.targetIsRoot) {
                try guardValue.removeItem(at: root)
            }
            for unsafeTarget in [sibling, similarPrefix, traversal, descendant] {
                #expect(throws: ManagedPathError.targetIsNotDirectChild) {
                    try guardValue.removeItem(at: unsafeTarget)
                }
            }
        }
    }

    @Test("missing direct child reports false and removal fails closed")
    func missingItem() throws {
        try withFixture { _, root, guardValue in
            let missing = root.appendingPathComponent("missing")
            let exists = try guardValue.itemExists(at: missing)
            #expect(exists == false)
            #expect(throws: ManagedPathError.itemNotFound) {
                try guardValue.removeItem(at: missing)
            }
        }
    }

    @Test("dangling final symlink exists and only the link is removed")
    func removesOnlyFinalSymlink() throws {
        try withFixture { temporary, root, guardValue in
            let external = temporary.appendingPathComponent("external")
            let externalFile = external.appendingPathComponent("keep.txt")
            try fileManager.createDirectory(at: external, withIntermediateDirectories: false)
            try "keep".write(to: externalFile, atomically: true, encoding: .utf8)

            let directoryLink = root.appendingPathComponent("linked-skill")
            try fileManager.createSymbolicLink(at: directoryLink, withDestinationURL: external)
            let directoryLinkExists = try guardValue.itemExists(at: directoryLink)
            #expect(directoryLinkExists)
            try guardValue.removeItem(at: directoryLink)
            #expect(!fileManager.fileExists(atPath: directoryLink.path))
            #expect(fileManager.fileExists(atPath: externalFile.path))

            let danglingLink = root.appendingPathComponent("dangling")
            try fileManager.createSymbolicLink(
                at: danglingLink,
                withDestinationURL: temporary.appendingPathComponent("does-not-exist")
            )
            let danglingLinkExists = try guardValue.itemExists(at: danglingLink)
            #expect(danglingLinkExists)
            try guardValue.removeItem(at: danglingLink)
            #expect(!fileManager.fileExists(atPath: danglingLink.path))
        }
    }

    @Test("recursive removal never follows links inside a managed directory")
    func recursiveRemovalDoesNotFollowLinks() throws {
        try withFixture { temporary, root, guardValue in
            let external = temporary.appendingPathComponent("external")
            let externalFile = external.appendingPathComponent("keep.txt")
            try fileManager.createDirectory(at: external, withIntermediateDirectories: false)
            try "keep".write(to: externalFile, atomically: true, encoding: .utf8)

            let skill = root.appendingPathComponent("skill")
            try fileManager.createDirectory(at: skill, withIntermediateDirectories: false)
            try "local".write(
                to: skill.appendingPathComponent("SKILL.md"),
                atomically: true,
                encoding: .utf8
            )
            try fileManager.createSymbolicLink(
                at: skill.appendingPathComponent("external-link"),
                withDestinationURL: external
            )

            try guardValue.removeItem(at: skill)

            #expect(!fileManager.fileExists(atPath: skill.path))
            #expect(fileManager.fileExists(atPath: externalFile.path))
        }
    }

    @Test("recursive removal failure restores the remaining skill at its original name")
    func recursiveRemovalFailureRestoresRemainingSkill() throws {
        try withTemporaryDirectory { temporary in
            let root = temporary.appendingPathComponent("managed")
            let skill = root.appendingPathComponent("skill")
            try fileManager.createDirectory(at: skill, withIntermediateDirectories: true)
            try "first".write(
                to: skill.appendingPathComponent("first.txt"),
                atomically: true,
                encoding: .utf8
            )
            try "second".write(
                to: skill.appendingPathComponent("second.txt"),
                atomically: true,
                encoding: .utf8
            )
            var moves = 0
            let hooks = ManagedPathGuardTestHooks(beforeQuarantineMove: { _ in
                moves += 1
                if moves == 3 {
                    throw ManagedPathError.posix(operation: "injected removal", code: EIO)
                }
            })

            do {
                try ManagedPathGuard(rootURL: root, hooks: hooks).removeItem(at: skill)
                Issue.record("Expected the injected removal failure")
            } catch let error as ManagedPathError {
                guard case let .removalFailed(partiallyDeleted, recoveryPath, restored, cause) = error else {
                    Issue.record("Unexpected error: \(error)")
                    return
                }
                #expect(partiallyDeleted)
                #expect(restored)
                let restoredPath = try #require(recoveryPath)
                #expect(
                    URL(fileURLWithPath: restoredPath).resolvingSymlinksInPath().path
                        == skill.resolvingSymlinksInPath().path
                )
                #expect(cause.contains("injected removal"))
            }

            #expect(fileManager.fileExists(atPath: skill.path))
            let remaining = try fileManager.contentsOfDirectory(atPath: skill.path)
            #expect(remaining.count == 1)
            let rootContents = try fileManager.contentsOfDirectory(atPath: root.path)
            #expect(rootContents == ["skill"])
        }
    }

    @Test("recursive removal reports the quarantine path when the original name is occupied")
    func recursiveRemovalFailureReportsQuarantinePath() throws {
        try withTemporaryDirectory { temporary in
            let root = temporary.appendingPathComponent("managed")
            let skill = root.appendingPathComponent("skill")
            try fileManager.createDirectory(at: skill, withIntermediateDirectories: true)
            try "first".write(
                to: skill.appendingPathComponent("first.txt"),
                atomically: true,
                encoding: .utf8
            )
            try "second".write(
                to: skill.appendingPathComponent("second.txt"),
                atomically: true,
                encoding: .utf8
            )
            var moves = 0
            let hooks = ManagedPathGuardTestHooks(beforeQuarantineMove: { _ in
                moves += 1
                if moves == 3 {
                    try fileManager.createDirectory(at: skill, withIntermediateDirectories: false)
                    throw ManagedPathError.posix(operation: "injected removal", code: EIO)
                }
            })

            var recoveryPath: String?
            do {
                try ManagedPathGuard(rootURL: root, hooks: hooks).removeItem(at: skill)
                Issue.record("Expected the injected removal failure")
            } catch let error as ManagedPathError {
                guard case let .removalFailed(partiallyDeleted, path, restored, _) = error else {
                    Issue.record("Unexpected error: \(error)")
                    return
                }
                #expect(partiallyDeleted)
                #expect(!restored)
                #expect(path?.contains(".skillsmanager-delete-") == true)
                recoveryPath = path
            }

            let resolvedRecoveryPath = try #require(recoveryPath)
            #expect(fileManager.fileExists(atPath: skill.path))
            #expect(fileManager.fileExists(atPath: resolvedRecoveryPath))
            let remaining = try fileManager.contentsOfDirectory(atPath: resolvedRecoveryPath)
            #expect(remaining.count == 1)
        }
    }

    @Test("removal never restores an item that replaced the quarantined identity")
    func removalDoesNotRestoreReplacedQuarantine() throws {
        try withTemporaryDirectory { temporary in
            let root = temporary.appendingPathComponent("managed")
            let skill = root.appendingPathComponent("skill")
            let displaced = root.appendingPathComponent("displaced")
            try fileManager.createDirectory(at: skill, withIntermediateDirectories: true)
            try "original".write(
                to: skill.appendingPathComponent("SKILL.md"),
                atomically: true,
                encoding: .utf8
            )
            var hooks = ManagedPathGuardTestHooks()
            hooks.afterQuarantineMove = { _, quarantine in
                let quarantineURL = root.appendingPathComponent(quarantine)
                try fileManager.moveItem(at: quarantineURL, to: displaced)
                try fileManager.createDirectory(at: quarantineURL, withIntermediateDirectories: false)
                try "replacement".write(
                    to: quarantineURL.appendingPathComponent("SKILL.md"),
                    atomically: true,
                    encoding: .utf8
                )
            }

            do {
                try ManagedPathGuard(rootURL: root, hooks: hooks).removeItem(at: skill)
                Issue.record("Expected the quarantine identity change to fail closed")
            } catch let error as ManagedPathError {
                guard case let .removalFailed(partiallyDeleted, recoveryPath, restored, cause) = error else {
                    Issue.record("Unexpected error: \(error)")
                    return
                }
                #expect(!partiallyDeleted)
                #expect(recoveryPath == nil)
                #expect(!restored)
                #expect(cause.contains("changed"))
            }

            #expect(!fileManager.fileExists(atPath: skill.path))
            #expect(try String(
                contentsOf: displaced.appendingPathComponent("SKILL.md"),
                encoding: .utf8
            ) == "original")
            let rootItems = try fileManager.contentsOfDirectory(atPath: root.path)
            #expect(rootItems.contains("skill") == false)
        }
    }

    @Test("a replaced root is rejected before lookup or mutation")
    func rejectsReplacedRoot() throws {
        try withFixture { temporary, root, guardValue in
            let originalTarget = root.appendingPathComponent("original")
            try "original".write(to: originalTarget, atomically: true, encoding: .utf8)

            let movedRoot = temporary.appendingPathComponent("moved-root")
            try fileManager.moveItem(at: root, to: movedRoot)
            try fileManager.createDirectory(at: root, withIntermediateDirectories: false)
            let replacementTarget = root.appendingPathComponent("replacement")
            try "replacement".write(to: replacementTarget, atomically: true, encoding: .utf8)

            #expect(throws: ManagedPathError.rootReplaced) {
                try guardValue.itemExists(at: replacementTarget)
            }
            #expect(throws: ManagedPathError.rootReplaced) {
                try guardValue.removeItem(at: replacementTarget)
            }
            #expect(fileManager.fileExists(atPath: movedRoot.appendingPathComponent("original").path))
            #expect(fileManager.fileExists(atPath: replacementTarget.path))
        }
    }

    @Test("staged child is atomically promoted when target is absent")
    func promotesNewItem() throws {
        try withFixture { _, root, guardValue in
            let staged = root.appendingPathComponent(".staged")
            let target = root.appendingPathComponent("skill")
            try fileManager.createDirectory(at: staged, withIntermediateDirectories: false)
            try "new".write(
                to: staged.appendingPathComponent("SKILL.md"),
                atomically: true,
                encoding: .utf8
            )

            let observedStaged = try guardValue.itemIdentity(at: staged)
            let expectedStaged = try #require(observedStaged)
            try guardValue.promoteStagedItemIfAbsent(
                at: staged,
                to: target,
                expectedStaged: expectedStaged,
                validateStaged: { _ in }
            )

            #expect(!fileManager.fileExists(atPath: staged.path))
            let content = try String(contentsOf: target.appendingPathComponent("SKILL.md"), encoding: .utf8)
            #expect(content == "new")
        }
    }

    @Test("existing target is atomically swapped and old item is cleaned")
    func replacesExistingItem() throws {
        try withFixture { _, root, guardValue in
            let staged = root.appendingPathComponent(".staged")
            let target = root.appendingPathComponent("skill")
            try fileManager.createDirectory(at: staged, withIntermediateDirectories: false)
            try fileManager.createDirectory(at: target, withIntermediateDirectories: false)
            try "new".write(
                to: staged.appendingPathComponent("SKILL.md"),
                atomically: true,
                encoding: .utf8
            )
            try "old".write(
                to: target.appendingPathComponent("SKILL.md"),
                atomically: true,
                encoding: .utf8
            )

            let observedStaged = try guardValue.itemIdentity(at: staged)
            let observedTarget = try guardValue.itemIdentity(at: target)
            let expectedStaged = try #require(observedStaged)
            let expected = try #require(observedTarget)
            let result = try guardValue.replaceStagedItem(
                at: staged,
                to: target,
                expectedStaged: expectedStaged,
                expectedTarget: expected,
                validateStaged: { _ in }
            )

            #expect(result == .committed)
            #expect(!fileManager.fileExists(atPath: staged.path))
            let content = try String(contentsOf: target.appendingPathComponent("SKILL.md"), encoding: .utf8)
            #expect(content == "new")
        }
    }

    @Test("no-replace promotion rejects a destination created concurrently")
    func noReplaceRejectsConcurrentCreate() throws {
        try withTemporaryDirectory { temporary in
            let root = temporary.appendingPathComponent("managed")
            let staged = root.appendingPathComponent(".staged")
            let target = root.appendingPathComponent("skill")
            try fileManager.createDirectory(at: staged, withIntermediateDirectories: true)
            let hooks = ManagedPathGuardTestHooks(beforeNoReplaceCommit: {
                try "contender".write(to: target, atomically: true, encoding: .utf8)
            })
            let guardValue = try ManagedPathGuard(rootURL: root, hooks: hooks)
            let observedStaged = try guardValue.itemIdentity(at: staged)
            let expectedStaged = try #require(observedStaged)

            #expect(throws: ManagedPathError.destinationAlreadyExists) {
                try guardValue.promoteStagedItemIfAbsent(
                    at: staged,
                    to: target,
                    expectedStaged: expectedStaged,
                    validateStaged: { _ in }
                )
            }
            #expect(fileManager.fileExists(atPath: staged.path))
            #expect(try String(contentsOf: target, encoding: .utf8) == "contender")
        }
    }

    @Test("only one staged item can win the same destination")
    func onlyOneNoReplacePromotionWins() throws {
        try withFixture { _, root, guardValue in
            let first = root.appendingPathComponent(".first")
            let second = root.appendingPathComponent(".second")
            let target = root.appendingPathComponent("skill")
            try "first".write(to: first, atomically: true, encoding: .utf8)
            try "second".write(to: second, atomically: true, encoding: .utf8)

            let observedFirst = try guardValue.itemIdentity(at: first)
            let observedSecond = try guardValue.itemIdentity(at: second)
            let expectedFirst = try #require(observedFirst)
            let expectedSecond = try #require(observedSecond)
            try guardValue.promoteStagedItemIfAbsent(
                at: first,
                to: target,
                expectedStaged: expectedFirst,
                validateStaged: { _ in }
            )
            #expect(throws: ManagedPathError.destinationAlreadyExists) {
                try guardValue.promoteStagedItemIfAbsent(
                    at: second,
                    to: target,
                    expectedStaged: expectedSecond,
                    validateStaged: { _ in }
                )
            }

            #expect(try String(contentsOf: target, encoding: .utf8) == "first")
            #expect(try String(contentsOf: second, encoding: .utf8) == "second")
        }
    }

    @Test("replace rejects a target whose identity changed after observation")
    func replaceRejectsChangedTarget() throws {
        try withTemporaryDirectory { temporary in
            let root = temporary.appendingPathComponent("managed")
            let staged = root.appendingPathComponent(".staged")
            let target = root.appendingPathComponent("skill")
            let displaced = root.appendingPathComponent("displaced")
            try fileManager.createDirectory(at: staged, withIntermediateDirectories: true)
            try "old".write(to: target, atomically: true, encoding: .utf8)
            let observer = try ManagedPathGuard(rootURL: root)
            let observed = try observer.itemIdentity(at: target)
            let expected = try #require(observed)
            let observedStaged = try observer.itemIdentity(at: staged)
            let expectedStaged = try #require(observedStaged)
            let hooks = ManagedPathGuardTestHooks(beforeReplaceCommit: {
                try fileManager.moveItem(at: target, to: displaced)
                try "replacement".write(to: target, atomically: true, encoding: .utf8)
            })
            let guardValue = try ManagedPathGuard(rootURL: root, hooks: hooks)

            #expect(throws: ManagedPathError.itemChanged) {
                _ = try guardValue.replaceStagedItem(
                    at: staged,
                    to: target,
                    expectedStaged: expectedStaged,
                    expectedTarget: expected,
                    validateStaged: { _ in }
                )
            }
            #expect(fileManager.fileExists(atPath: staged.path))
            #expect(try String(contentsOf: target, encoding: .utf8) == "replacement")
        }
    }

    @Test("removal restores but never deletes a name replaced before quarantine")
    func removalRejectsChangedName() throws {
        try withTemporaryDirectory { temporary in
            let root = temporary.appendingPathComponent("managed")
            let target = root.appendingPathComponent("skill")
            let displaced = root.appendingPathComponent("displaced")
            try fileManager.createDirectory(at: root, withIntermediateDirectories: false)
            try "old".write(to: target, atomically: true, encoding: .utf8)
            let hooks = ManagedPathGuardTestHooks(beforeQuarantineMove: { name in
                guard name == "skill" else { return }
                try fileManager.moveItem(at: target, to: displaced)
                try "replacement".write(to: target, atomically: true, encoding: .utf8)
            })
            let guardValue = try ManagedPathGuard(rootURL: root, hooks: hooks)

            #expect(throws: ManagedPathError.itemChanged) {
                try guardValue.removeItem(at: target)
            }
            #expect(try String(contentsOf: target, encoding: .utf8) == "replacement")
            #expect(try String(contentsOf: displaced, encoding: .utf8) == "old")
        }
    }

    func withFixture(
        _ body: (URL, URL, ManagedPathGuard) throws -> Void
    ) throws {
        try withTemporaryDirectory { temporary in
            let root = temporary.appendingPathComponent("managed")
            try fileManager.createDirectory(at: root, withIntermediateDirectories: false)
            try body(temporary, root, ManagedPathGuard(rootURL: root))
        }
    }

    func withTemporaryDirectory(_ body: (URL) throws -> Void) throws {
        let temporary = fileManager.temporaryDirectory
            .appendingPathComponent("ManagedPathGuardTests-\(UUID().uuidString)")
        try fileManager.createDirectory(at: temporary, withIntermediateDirectories: false)
        defer { try? fileManager.removeItem(at: temporary) }
        try body(temporary)
    }
}
