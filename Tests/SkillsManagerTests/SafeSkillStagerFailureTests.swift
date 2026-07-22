import Darwin
import Foundation
import Testing
import ZIPFoundation

@testable import SkillsManager

@Suite("Safe Skill Stager failure recovery")
struct SafeSkillStagerFailureTests {
    @Test("replacement rejects a staged identity changed before the swap")
    func replacementRejectsChangedStaging() throws {
        try withTemporaryDirectory { root in
            let managedRoot = root.appendingPathComponent("managed", isDirectory: true)
            let staged = managedRoot.appendingPathComponent(".staged", isDirectory: true)
            let displaced = managedRoot.appendingPathComponent("displaced", isDirectory: true)
            let target = managedRoot.appendingPathComponent("skill", isDirectory: true)
            try makeSkill(at: staged, markdown: "# Validated")
            try makeSkill(at: target, markdown: "# Existing")
            let observer = try ManagedPathGuard(rootURL: managedRoot)
            let observedStaged = try observer.itemIdentity(at: staged)
            let observedTarget = try observer.itemIdentity(at: target)
            let expectedStaged = try #require(observedStaged)
            let expectedTarget = try #require(observedTarget)

            var hooks = ManagedPathGuardTestHooks()
            hooks.beforeReplaceCommit = {
                try FileManager.default.moveItem(at: staged, to: displaced)
                try makeSkill(at: staged, markdown: "# Unverified")
            }
            let guardrail = try ManagedPathGuard(rootURL: managedRoot, hooks: hooks)

            #expect(throws: ManagedPathError.itemChanged) {
                _ = try guardrail.replaceStagedItem(
                    at: staged,
                    to: target,
                    expectedStaged: expectedStaged,
                    expectedTarget: expectedTarget,
                    validateStaged: { _ in }
                )
            }
            #expect(try String(
                contentsOf: target.appendingPathComponent("SKILL.md"),
                encoding: .utf8
            ) == "# Existing")
        }
    }

    @Test("a staging directory replaced after validation is never promoted")
    func rejectsReplacedValidatedStaging() throws {
        try withTemporaryDirectory { root in
            let source = root.appendingPathComponent("source", isDirectory: true)
            let destination = root.appendingPathComponent("destination", isDirectory: true)
            try makeSkill(at: source, markdown: "# Validated")
            let fingerprint = try SkillContentSnapshot.capture(at: source).fingerprint

            var hooks = ManagedPathGuardTestHooks()
            hooks.beforeNoReplaceCommit = {
                let children = try FileManager.default.contentsOfDirectory(
                    at: destination,
                    includingPropertiesForKeys: nil
                )
                let staged = try #require(children.first {
                    $0.lastPathComponent.hasPrefix(".skillsmanager-tmp-")
                })
                let displaced = destination.appendingPathComponent("displaced", isDirectory: true)
                try FileManager.default.moveItem(at: staged, to: displaced)
                try makeSkill(at: staged, markdown: "# Unverified")
            }
            let stager = SafeSkillStager(
                guardFactory: { try ManagedPathGuard(rootURL: $0, hooks: hooks) }
            )

            do {
                _ = try stager.install(
                    sourceRoot: source,
                    expectedFingerprint: fingerprint,
                    destinationRoot: destination,
                    preferredName: "example",
                    conflictPolicy: .chooseUniqueName
                )
                Issue.record("Expected the replaced staging identity to fail closed")
            } catch let failure as SafeSkillStagingFailure {
                #expect(failure.cleanupDebts.count == 1)
                #expect(failure.originalReason.contains("changed"))
            }

            let final = destination.appendingPathComponent("example", isDirectory: true)
            #expect(!FileManager.default.fileExists(atPath: final.path))
        }
    }

    @Test("staging content changed in place is revalidated immediately before commit")
    func rejectsInPlaceStagingMutation() throws {
        try withTemporaryDirectory { root in
            let source = root.appendingPathComponent("source", isDirectory: true)
            let destination = root.appendingPathComponent("destination", isDirectory: true)
            try makeSkill(at: source, markdown: "# Validated")
            let fingerprint = try SkillContentSnapshot.capture(at: source).fingerprint
            var hooks = ManagedPathGuardTestHooks()
            hooks.beforeNoReplaceCommit = {
                let staged = try #require(FileManager.default.contentsOfDirectory(
                    at: destination,
                    includingPropertiesForKeys: nil
                ).first { $0.lastPathComponent.hasPrefix(".skillsmanager-tmp-") })
                try "# Unverified".write(
                    to: staged.appendingPathComponent("SKILL.md"),
                    atomically: true,
                    encoding: .utf8
                )
            }
            let stager = SafeSkillStager(
                guardFactory: { try ManagedPathGuard(rootURL: $0, hooks: hooks) }
            )

            #expect(throws: SafeSkillStagingError.self) {
                _ = try stager.install(
                    sourceRoot: source,
                    expectedFingerprint: fingerprint,
                    destinationRoot: destination,
                    preferredName: "example",
                    conflictPolicy: .chooseUniqueName
                )
            }
            #expect(try FileManager.default.contentsOfDirectory(atPath: destination.path).isEmpty)
        }
    }

    @Test("indeterminate promotion preserves a concurrent target without pre-commit cleanup")
    func propagatesIndeterminatePromotion() throws {
        try withTemporaryDirectory { root in
            let source = root.appendingPathComponent("source", isDirectory: true)
            let destination = root.appendingPathComponent("destination", isDirectory: true)
            let target = destination.appendingPathComponent("example", isDirectory: true)
            let committed = destination.appendingPathComponent("committed", isDirectory: true)
            try makeSkill(at: source, markdown: "# Validated")
            let fingerprint = try SkillContentSnapshot.capture(at: source).fingerprint
            var hooks = ManagedPathGuardTestHooks()
            hooks.afterNoReplaceCommit = {
                try FileManager.default.moveItem(at: target, to: committed)
                try self.makeSkill(at: target, markdown: "# Newer")
            }
            let stager = SafeSkillStager(
                guardFactory: { try ManagedPathGuard(rootURL: $0, hooks: hooks) }
            )

            #expect(throws: ManagedPromotionIndeterminate.self) {
                _ = try stager.install(
                    sourceRoot: source,
                    expectedFingerprint: fingerprint,
                    destinationRoot: destination,
                    preferredName: "example",
                    conflictPolicy: .chooseUniqueName
                )
            }
            #expect(try String(
                contentsOf: target.appendingPathComponent("SKILL.md"),
                encoding: .utf8
            ) == "# Newer")
            #expect(try String(
                contentsOf: committed.appendingPathComponent("SKILL.md"),
                encoding: .utf8
            ) == "# Validated")
        }
    }

    @Test("target content changed in place after commit is indeterminate")
    func detectsPostCommitContentMutation() throws {
        try withTemporaryDirectory { root in
            let source = root.appendingPathComponent("source", isDirectory: true)
            let destination = root.appendingPathComponent("destination", isDirectory: true)
            let target = destination.appendingPathComponent("example", isDirectory: true)
            try makeSkill(at: source, markdown: "# Validated")
            let fingerprint = try SkillContentSnapshot.capture(at: source).fingerprint
            var hooks = ManagedPathGuardTestHooks()
            hooks.afterNoReplaceCommit = {
                try "# Changed".write(
                    to: target.appendingPathComponent("SKILL.md"),
                    atomically: true,
                    encoding: .utf8
                )
            }
            let stager = SafeSkillStager(
                guardFactory: { try ManagedPathGuard(rootURL: $0, hooks: hooks) }
            )

            #expect(throws: ManagedPromotionIndeterminate.self) {
                _ = try stager.install(
                    sourceRoot: source,
                    expectedFingerprint: fingerprint,
                    destinationRoot: destination,
                    preferredName: "example",
                    conflictPolicy: .chooseUniqueName
                )
            }
            #expect(try String(
                contentsOf: target.appendingPathComponent("SKILL.md"),
                encoding: .utf8
            ) == "# Changed")
        }
    }

    @Test("folder import reports cleanup debt together with its original failure")
    func reportsFolderPreCommitCleanupFailure() throws {
        try withTemporaryDirectory { root in
            let source = root.appendingPathComponent("source", isDirectory: true)
            let destination = root.appendingPathComponent("destination", isDirectory: true)
            try makeSkill(at: source, markdown: "# Folder")
            let fingerprint = try SkillContentSnapshot.capture(at: source).fingerprint
            let stager = failingStager()

            do {
                _ = try stager.install(
                    sourceRoot: source,
                    expectedFingerprint: fingerprint,
                    destinationRoot: destination,
                    preferredName: "folder",
                    conflictPolicy: .chooseUniqueName
                )
                Issue.record("Expected the injected commit and cleanup failures")
            } catch let failure as SafeSkillStagingFailure {
                #expect(failure.originalReason.contains("injected commit"))
                #expect(failure.cleanupDebts.count == 1)
                #expect(failure.localizedDescription.contains(failure.cleanupDebts[0].url.path))
            }
            #expect(!FileManager.default.fileExists(
                atPath: destination.appendingPathComponent("folder").path
            ))
        }
    }

    @Test("archive import reports both pre-commit cleanup debts")
    func reportsArchivePreCommitCleanupFailures() throws {
        try withTemporaryDirectory { root in
            let source = root.appendingPathComponent("source", isDirectory: true)
            let destination = root.appendingPathComponent("destination", isDirectory: true)
            let archiveURL = root.appendingPathComponent("skill.zip")
            try makeSkill(at: source, markdown: "# Archive")
            let fingerprint = try SkillContentSnapshot.capture(at: source).fingerprint
            let contents = try Data(contentsOf: source.appendingPathComponent("SKILL.md"))
            let archive = try Archive(url: archiveURL, accessMode: .create)
            try archive.addEntry(
                with: "SKILL.md",
                type: .file,
                uncompressedSize: Int64(contents.count)
            ) { position, size in
                let start = Int(position)
                return contents.subdata(in: start..<min(start + size, contents.count))
            }

            do {
                _ = try failingStager().installArchive(
                    archiveAt: archiveURL,
                    expectedFingerprint: fingerprint,
                    destinationRoot: destination,
                    preferredName: "archive",
                    conflictPolicy: .chooseUniqueName
                )
                Issue.record("Expected the injected archive commit and cleanup failures")
            } catch let failure as SafeSkillStagingFailure {
                #expect(failure.originalReason.contains("injected commit"))
                #expect(failure.cleanupDebts.count == 2)
                #expect(failure.cleanupDebts.contains {
                    $0.url.lastPathComponent.hasPrefix(".skillsmanager-tmp-archive-")
                })
            }
            #expect(!FileManager.default.fileExists(
                atPath: destination.appendingPathComponent("archive").path
            ))
        }
    }

    private func failingStager() -> SafeSkillStager {
        var hooks = ManagedPathGuardTestHooks()
        hooks.beforeNoReplaceCommit = {
            throw ManagedPathError.posix(operation: "injected commit", code: EIO)
        }
        hooks.beforeQuarantineMove = { name in
            guard name.hasPrefix(".skillsmanager-tmp-") else { return }
            throw ManagedPathError.posix(operation: "injected cleanup", code: EBUSY)
        }
        return SafeSkillStager(
            guardFactory: { try ManagedPathGuard(rootURL: $0, hooks: hooks) }
        )
    }

    private func makeSkill(at root: URL, markdown: String) throws {
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try markdown.write(
            to: root.appendingPathComponent("SKILL.md"),
            atomically: true,
            encoding: .utf8
        )
    }

    private func withTemporaryDirectory(_ body: (URL) throws -> Void) throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try body(root)
    }
}
