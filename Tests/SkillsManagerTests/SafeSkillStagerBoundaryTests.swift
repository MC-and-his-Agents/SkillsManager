import Darwin
import Foundation
import Testing

@testable import SkillsManager

@Suite("Safe Skill Stager anchored boundaries")
struct SafeSkillStagerBoundaryTests {
    @Test("a managed root replaced before staging receives no writes")
    func rejectsRootReplacementBeforeStaging() throws {
        try withTemporaryDirectory { root in
            let source = root.appendingPathComponent("source", isDirectory: true)
            let destination = root.appendingPathComponent("destination", isDirectory: true)
            let displaced = root.appendingPathComponent("displaced", isDirectory: true)
            try makeSkill(at: source)
            try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
            let fingerprint = try SkillContentSnapshot.capture(at: source).fingerprint
            let stager = SafeSkillStager(guardFactory: { url in
                try FileManager.default.moveItem(at: url, to: displaced)
                try FileManager.default.createDirectory(at: url, withIntermediateDirectories: false)
                return try ManagedPathGuard(rootURL: url)
            })

            #expect(throws: ManagedPathError.rootReplaced) {
                _ = try stager.install(
                    sourceRoot: source,
                    expectedFingerprint: fingerprint,
                    destinationRoot: destination,
                    preferredName: "example",
                    conflictPolicy: .chooseUniqueName
                )
            }
            #expect(try FileManager.default.contentsOfDirectory(atPath: destination.path).isEmpty)
            #expect(try FileManager.default.contentsOfDirectory(atPath: displaced.path).isEmpty)
        }
    }

    @Test("Clawdhub metadata never follows a replaced metadata directory")
    func rejectsClawdhubMetadataLink() throws {
        try withTemporaryDirectory { root in
            let staged = root.appendingPathComponent("staged", isDirectory: true)
            let outside = root.appendingPathComponent("outside", isDirectory: true)
            try FileManager.default.createDirectory(at: staged, withIntermediateDirectories: true)
            try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
            try FileManager.default.createSymbolicLink(
                at: staged.appendingPathComponent(".clawdhub"),
                withDestinationURL: outside
            )
            let descriptor = Darwin.open(
                staged.path,
                O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC
            )
            guard descriptor >= 0 else { throw POSIXError(.EIO) }
            defer { Darwin.close(descriptor) }

            #expect(throws: POSIXError.self) {
                try SkillFileWorker.writeClawdhubOrigin(
                    in: descriptor,
                    slug: "example",
                    version: "1.0.0"
                )
            }
            #expect(!FileManager.default.fileExists(atPath: outside.appendingPathComponent("origin.json").path))
        }
    }

    @Test("cancellation after the final hook prevents commit")
    func cancellationBeforeCommit() throws {
        try withTemporaryDirectory { root in
            let source = root.appendingPathComponent("source", isDirectory: true)
            let destination = root.appendingPathComponent("destination", isDirectory: true)
            try makeSkill(at: source)
            let fingerprint = try SkillContentSnapshot.capture(at: source).fingerprint
            var cancelled = false
            var hooks = ManagedPathGuardTestHooks()
            hooks.beforeNoReplaceCommit = { cancelled = true }
            let stager = SafeSkillStager(
                guardFactory: { try ManagedPathGuard(rootURL: $0, hooks: hooks) }
            )

            #expect(throws: CancellationError.self) {
                _ = try stager.install(
                    sourceRoot: source,
                    expectedFingerprint: fingerprint,
                    destinationRoot: destination,
                    preferredName: "example",
                    conflictPolicy: .chooseUniqueName,
                    checkpoint: { if cancelled { throw CancellationError() } }
                )
            }
            #expect(try FileManager.default.contentsOfDirectory(atPath: destination.path).isEmpty)
        }
    }

    @Test("cancellation arriving after commit does not misreport rollback")
    func cancellationAfterCommitStillConverges() throws {
        try withTemporaryDirectory { root in
            let source = root.appendingPathComponent("source", isDirectory: true)
            let destination = root.appendingPathComponent("destination", isDirectory: true)
            try makeSkill(at: source)
            let fingerprint = try SkillContentSnapshot.capture(at: source).fingerprint
            var cancelled = false
            var hooks = ManagedPathGuardTestHooks()
            hooks.afterNoReplaceCommit = { cancelled = true }
            let stager = SafeSkillStager(
                guardFactory: { try ManagedPathGuard(rootURL: $0, hooks: hooks) }
            )

            let result = try stager.install(
                sourceRoot: source,
                expectedFingerprint: fingerprint,
                destinationRoot: destination,
                preferredName: "example",
                conflictPolicy: .chooseUniqueName,
                checkpoint: { if cancelled { throw CancellationError() } }
            )

            #expect(cancelled)
            #expect(FileManager.default.fileExists(
                atPath: result.installedURL.appendingPathComponent("SKILL.md").path
            ))
        }
    }

    @Test("post-commit verification failure rolls a new target back without deleting siblings")
    func noReplaceVerificationFailureRollsBack() throws {
        try withTemporaryDirectory { root in
            let source = root.appendingPathComponent("source", isDirectory: true)
            let destination = root.appendingPathComponent("destination", isDirectory: true)
            let keeper = destination.appendingPathComponent("keeper", isDirectory: true)
            try makeSkill(at: source)
            try makeSkill(at: keeper)
            let fingerprint = try SkillContentSnapshot.capture(at: source).fingerprint
            let injectedError = ManagedPathError.cleanupFailed(
                "injected equivalent-sibling verification failure"
            )
            var hooks = ManagedPathGuardTestHooks()
            hooks.beforeEquivalentSiblingCheck = { throw injectedError }
            let stager = SafeSkillStager(
                guardFactory: { try ManagedPathGuard(rootURL: $0, hooks: hooks) }
            )

            #expect(throws: injectedError) {
                _ = try stager.install(
                    sourceRoot: source,
                    expectedFingerprint: fingerprint,
                    destinationRoot: destination,
                    preferredName: "example",
                    conflictPolicy: .chooseUniqueName
                )
            }
            #expect(!FileManager.default.fileExists(
                atPath: destination.appendingPathComponent("example").path
            ))
            #expect(FileManager.default.fileExists(atPath: keeper.path))
        }
    }

    @Test("post-commit verification failure restores a replaced target and preserves siblings")
    func replaceVerificationFailureRollsBack() throws {
        try withTemporaryDirectory { root in
            let source = root.appendingPathComponent("source", isDirectory: true)
            let destination = root.appendingPathComponent("destination", isDirectory: true)
            let target = destination.appendingPathComponent("example", isDirectory: true)
            let keeper = destination.appendingPathComponent("keeper", isDirectory: true)
            try makeSkill(at: source, contents: "# New")
            try makeSkill(at: target, contents: "# Old")
            try makeSkill(at: keeper)
            let fingerprint = try SkillContentSnapshot.capture(at: source).fingerprint
            let injectedError = ManagedPathError.cleanupFailed(
                "injected equivalent-sibling verification failure"
            )
            var hooks = ManagedPathGuardTestHooks()
            hooks.beforeEquivalentSiblingCheck = { throw injectedError }
            let stager = SafeSkillStager(
                guardFactory: { try ManagedPathGuard(rootURL: $0, hooks: hooks) }
            )

            #expect(throws: injectedError) {
                _ = try stager.install(
                    sourceRoot: source,
                    expectedFingerprint: fingerprint,
                    destinationRoot: destination,
                    preferredName: "example",
                    conflictPolicy: .replaceExisting
                )
            }
            #expect(try String(
                contentsOf: target.appendingPathComponent("SKILL.md"),
                encoding: .utf8
            ) == "# Old")
            #expect(FileManager.default.fileExists(atPath: keeper.path))
        }
    }

    private func makeSkill(at root: URL, contents: String = "# Example") throws {
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try contents.write(
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
