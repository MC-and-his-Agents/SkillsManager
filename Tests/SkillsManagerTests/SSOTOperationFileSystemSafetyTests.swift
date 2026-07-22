import Darwin
import Foundation
import Synchronization
import Testing

@testable import SkillsManager

@Suite("SSOT operation filesystem destructive boundaries")
struct SSOTOperationFileSystemSafetyTests {
    private enum Stop: Error { case requested }

    @Test("in-place file rewrites stop cleanup before unlink")
    func inPlaceRewriteStopsCleanup() throws {
        let workspace = try WriterWorkspace()
        let operationURL = Mutex<URL?>(nil)
        let mutated = Mutex(false)
        let hooks = SSOTOperationFileSystemTestHooks { checkpoint in
            guard checkpoint == .beforeInPlaceEntryRemoval,
                  !mutated.withLock({ $0 }),
                  let operationURL = operationURL.withLock({ $0 }) else { return }
            try overwriteInPlace(
                operationURL.appendingPathComponent("SKILL.md"),
                with: Data("other".utf8)
            )
            mutated.withLock { $0 = true }
        }
        let fileSystem = try makeFileSystem(workspace, hooks: hooks)
        let snapshot = try workspace.snapshot(content: "first")
        let fingerprint = try currentFingerprint(snapshot)
        let staged = try fileSystem.stage(
            sourceSnapshot: snapshot,
            expectedFingerprint: fingerprint,
            operationID: UUID()
        )
        let stagedURL = fileSystem.operationItemURL(for: staged.reference)
        operationURL.withLock { $0 = stagedURL }

        #expect(throws: ManagedPathError.itemChanged) {
            try fileSystem.removeExpectedOperationItem(
                staged.reference,
                identity: staged.identity,
                fingerprint: fingerprint
            )
        }
        #expect(mutated.withLock { $0 })
        #expect(try Data(contentsOf: stagedURL.appendingPathComponent("SKILL.md"))
            == Data("other".utf8))
    }

    @Test("relocated operation locator stops cleanup through its old descriptor")
    func relocatedLocatorStopsCleanup() throws {
        let workspace = try WriterWorkspace()
        let operationURL = Mutex<URL?>(nil)
        let displaced = workspace.workspace.appendingPathComponent("displaced", isDirectory: true)
        let hooks = SSOTOperationFileSystemTestHooks { checkpoint in
            guard checkpoint == .afterInPlaceEntryRemoval,
                  let operationURL = operationURL.withLock({ $0 }),
                  !FileManager.default.fileExists(atPath: displaced.path) else { return }
            try FileManager.default.moveItem(at: operationURL, to: displaced)
        }
        let fileSystem = try makeFileSystem(workspace, hooks: hooks)
        try Data("manifest".utf8).write(
            to: workspace.source.appendingPathComponent("SKILL.md")
        )
        let nested = workspace.source.appendingPathComponent("nested", isDirectory: true)
        try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: false)
        try Data("payload".utf8).write(to: nested.appendingPathComponent("payload.txt"))
        let snapshot = try SkillContentSnapshot.capture(at: workspace.source)
        let fingerprint = try currentFingerprint(snapshot)
        let staged = try fileSystem.stage(
            sourceSnapshot: snapshot,
            expectedFingerprint: fingerprint,
            operationID: UUID()
        )
        let stagedURL = fileSystem.operationItemURL(for: staged.reference)
        operationURL.withLock { $0 = stagedURL }

        #expect(throws: ManagedPathError.itemChanged) {
            try fileSystem.removeExpectedOperationItem(
                staged.reference,
                identity: staged.identity,
                fingerprint: fingerprint
            )
        }
        #expect(!FileManager.default.fileExists(atPath: stagedURL.path))
        #expect(FileManager.default.fileExists(
            atPath: displaced.appendingPathComponent("nested/payload.txt").path
        ))
    }

    @Test("relocated nested parent stops cleanup through its old descriptor")
    func relocatedNestedParentStopsCleanup() throws {
        let workspace = try WriterWorkspace()
        let operationURL = Mutex<URL?>(nil)
        let displaced = workspace.workspace.appendingPathComponent("displaced-nested")
        let hooks = SSOTOperationFileSystemTestHooks { checkpoint in
            guard checkpoint == .beforeInPlaceEntryRemoval,
                  let operationURL = operationURL.withLock({ $0 }),
                  !FileManager.default.fileExists(atPath: displaced.path) else { return }
            try FileManager.default.moveItem(
                at: operationURL.appendingPathComponent("nested"),
                to: displaced
            )
        }
        let fileSystem = try makeFileSystem(workspace, hooks: hooks)
        let nested = workspace.source.appendingPathComponent("nested", isDirectory: true)
        try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: false)
        try Data("keep".utf8).write(to: nested.appendingPathComponent("payload.txt"))
        let snapshot = try SkillContentSnapshot.capture(at: workspace.source)
        let fingerprint = try currentFingerprint(snapshot)
        let staged = try fileSystem.stage(
            sourceSnapshot: snapshot,
            expectedFingerprint: fingerprint,
            operationID: UUID()
        )
        let stagedURL = fileSystem.operationItemURL(for: staged.reference)
        operationURL.withLock { $0 = stagedURL }

        #expect(throws: ManagedPathError.self) {
            try fileSystem.removeExpectedOperationItem(
                staged.reference,
                identity: staged.identity,
                fingerprint: fingerprint
            )
        }
        #expect(FileManager.default.fileExists(atPath: stagedURL.path))
        #expect(try Data(contentsOf: displaced.appendingPathComponent("payload.txt"))
            == Data("keep".utf8))
    }

    @Test("lock drift during copy preserves the partial staging tree")
    func copyLockDriftPreservesStaging() throws {
        let workspace = try WriterWorkspace()
        let fileSystem = try makeFileSystem(workspace)
        let snapshot = try workspace.snapshot(
            content: String(repeating: "a", count: 128 * 1_024)
        )
        let fingerprint = try currentFingerprint(snapshot)
        let operationID = UUID()
        let stagedURL = fileSystem.operationItemURL(for: .staging(operationID: operationID))
        var replacedLock = false

        do {
            _ = try fileSystem.stage(
                sourceSnapshot: snapshot,
                expectedFingerprint: fingerprint,
                operationID: operationID,
                checkpoint: {
                    let file = stagedURL.appendingPathComponent("SKILL.md")
                    guard !replacedLock, fileSize(file) > 0 else { return }
                    try replaceSSOTLock(in: workspace.root)
                    replacedLock = true
                }
            )
            Issue.record("Expected ownership loss during copy")
        } catch let error as SSOTOperationFileSystemError {
            guard case .stagingCleanupFailed = error else {
                Issue.record("Unexpected error: \(error)")
                return
            }
        }

        #expect(replacedLock)
        #expect(fileSize(stagedURL.appendingPathComponent("SKILL.md")) > 0)
    }

    @Test("pre-copy hook failure preserves foreign staging content")
    func preCopyHookFailurePreservesStaging() throws {
        let workspace = try WriterWorkspace()
        let operationID = UUID()
        let stagedURL = workspace.root.appendingPathComponent(
            ".skillsmanager-tmp-\(operationID.uuidString.lowercased())"
        )
        let hooks = SSOTOperationFileSystemTestHooks { checkpoint in
            guard checkpoint == .afterStagingDirectoryCreateBeforeCopy else { return }
            try Data("foreign".utf8).write(
                to: stagedURL.appendingPathComponent("foreign.txt")
            )
            throw Stop.requested
        }
        let fileSystem = try makeFileSystem(workspace, hooks: hooks)
        let snapshot = try workspace.snapshot(content: "source")

        #expect(throws: SSOTOperationFileSystemError.self) {
            _ = try fileSystem.stage(
                sourceSnapshot: snapshot,
                expectedFingerprint: try currentFingerprint(snapshot),
                operationID: operationID
            )
        }
        #expect(try Data(contentsOf: stagedURL.appendingPathComponent("foreign.txt"))
            == Data("foreign".utf8))
    }

    @Test("post-copy hook failure preserves in-place staging drift")
    func postCopyHookFailurePreservesStaging() throws {
        let workspace = try WriterWorkspace()
        let operationID = UUID()
        let stagedURL = workspace.root.appendingPathComponent(
            ".skillsmanager-tmp-\(operationID.uuidString.lowercased())"
        )
        let hooks = SSOTOperationFileSystemTestHooks { checkpoint in
            guard checkpoint == .beforeStagingDurability else { return }
            try overwriteInPlace(
                stagedURL.appendingPathComponent("SKILL.md"),
                with: Data("drift".utf8)
            )
            throw Stop.requested
        }
        let fileSystem = try makeFileSystem(workspace, hooks: hooks)
        let snapshot = try workspace.snapshot(content: "source")

        #expect(throws: SSOTOperationFileSystemError.self) {
            _ = try fileSystem.stage(
                sourceSnapshot: snapshot,
                expectedFingerprint: try currentFingerprint(snapshot),
                operationID: operationID
            )
        }
        #expect(try Data(contentsOf: stagedURL.appendingPathComponent("SKILL.md"))
            == Data("drift".utf8))
    }

    @Test("copy failure preserves earlier drift and skips outer cleanup")
    func copyFailurePreservesEarlierDrift() throws {
        let workspace = try WriterWorkspace()
        let outerCleanupReached = Mutex(false)
        let hooks = SSOTOperationFileSystemTestHooks { checkpoint in
            guard checkpoint == .beforeInPlaceEntryRemoval else { return }
            outerCleanupReached.withLock { $0 = true }
        }
        let fileSystem = try makeFileSystem(workspace, hooks: hooks)
        try Data("complete".utf8).write(to: workspace.source.appendingPathComponent("a.txt"))
        try Data(repeating: 0x7a, count: 128 * 1_024)
            .write(to: workspace.source.appendingPathComponent("z.txt"))
        let snapshot = try SkillContentSnapshot.capture(at: workspace.source)
        let fingerprint = try currentFingerprint(snapshot)
        let operationID = UUID()
        let stagedURL = fileSystem.operationItemURL(for: .staging(operationID: operationID))
        var copyFailed = false

        do {
            _ = try fileSystem.stage(
                sourceSnapshot: snapshot,
                expectedFingerprint: fingerprint,
                operationID: operationID,
                checkpoint: {
                    let partial = stagedURL.appendingPathComponent("z.txt")
                    guard !copyFailed, fileSize(partial) > 0 else { return }
                    try overwriteInPlace(
                        stagedURL.appendingPathComponent("a.txt"),
                        with: Data("foreign".utf8)
                    )
                    copyFailed = true
                    throw Stop.requested
                }
            )
            Issue.record("Expected the injected copy failure")
        } catch let error as SSOTOperationFileSystemError {
            guard case .stagingCleanupFailed = error else {
                Issue.record("Unexpected error: \(error)")
                return
            }
        }

        #expect(copyFailed)
        #expect(!outerCleanupReached.withLock { $0 })
        #expect(FileManager.default.fileExists(atPath: stagedURL.path))
        #expect(try Data(contentsOf: stagedURL.appendingPathComponent("a.txt"))
            == Data("foreign".utf8))
    }

    @Test("relocated partial-copy parent is not unlinked through its old descriptor")
    func relocatedPartialCopyParentIsPreserved() throws {
        let workspace = try WriterWorkspace()
        let fileSystem = try makeFileSystem(workspace)
        let sourceParent = workspace.source.appendingPathComponent("nested", isDirectory: true)
        try FileManager.default.createDirectory(at: sourceParent, withIntermediateDirectories: false)
        try Data(repeating: 0x62, count: 128 * 1_024)
            .write(to: sourceParent.appendingPathComponent("payload.txt"))
        let snapshot = try SkillContentSnapshot.capture(at: workspace.source)
        let fingerprint = try currentFingerprint(snapshot)
        let operationID = UUID()
        let stagedURL = fileSystem.operationItemURL(for: .staging(operationID: operationID))
        let displaced = workspace.workspace.appendingPathComponent("displaced-copy-parent")
        var relocated = false

        #expect(throws: SSOTOperationFileSystemError.self) {
            _ = try fileSystem.stage(
                sourceSnapshot: snapshot,
                expectedFingerprint: fingerprint,
                operationID: operationID,
                checkpoint: {
                    let partial = stagedURL.appendingPathComponent("nested/payload.txt")
                    guard !relocated, fileSize(partial) > 0 else { return }
                    try FileManager.default.moveItem(
                        at: stagedURL.appendingPathComponent("nested"),
                        to: displaced
                    )
                    relocated = true
                    throw Stop.requested
                }
            )
        }

        #expect(relocated)
        #expect(fileSize(displaced.appendingPathComponent("payload.txt")) > 0)
        #expect(FileManager.default.fileExists(atPath: stagedURL.path))
    }

    @Test("in-place partial-copy rewrite is preserved for repair")
    func inPlacePartialCopyRewriteIsPreserved() throws {
        let workspace = try WriterWorkspace()
        let fileSystem = try makeFileSystem(workspace)
        let snapshot = try workspace.snapshot(
            content: String(repeating: "a", count: 128 * 1_024)
        )
        let fingerprint = try currentFingerprint(snapshot)
        let operationID = UUID()
        let stagedURL = fileSystem.operationItemURL(for: .staging(operationID: operationID))
        let partial = stagedURL.appendingPathComponent("SKILL.md")
        var rewritten = false

        #expect(throws: SSOTOperationFileSystemError.self) {
            _ = try fileSystem.stage(
                sourceSnapshot: snapshot,
                expectedFingerprint: fingerprint,
                operationID: operationID,
                checkpoint: {
                    guard !rewritten, fileSize(partial) > 0 else { return }
                    try overwriteInPlace(partial, with: Data("foreign".utf8))
                    rewritten = true
                    throw Stop.requested
                }
            )
        }

        #expect(rewritten)
        #expect(try Data(contentsOf: partial) == Data("foreign".utf8))
    }

    private func makeFileSystem(
        _ workspace: WriterWorkspace,
        hooks: SSOTOperationFileSystemTestHooks = .init()
    ) throws -> SSOTOperationFileSystem {
        let guardValue = try ManagedPathGuard(verifiedRoot: workspace.verifiedRoot)
        let ownership = try SSOTWriterOwnership.acquire(using: guardValue)
        return try SSOTOperationFileSystem(
            verifiedRoot: workspace.verifiedRoot,
            ownership: ownership,
            hooks: hooks
        )
    }

    private func currentFingerprint(
        _ snapshot: SkillContentSnapshot
    ) throws -> SkillContentFingerprint {
        try SkillContentFingerprint(currentDigest: snapshot.fingerprintDigest)
    }
}

private func overwriteInPlace(_ url: URL, with content: Data) throws {
    let descriptor = Darwin.open(url.path, O_WRONLY | O_TRUNC | O_NOFOLLOW | O_CLOEXEC)
    guard descriptor >= 0 else { throw CocoaError(.fileWriteUnknown) }
    defer { Darwin.close(descriptor) }
    try content.withUnsafeBytes { bytes in
        guard Darwin.write(descriptor, bytes.baseAddress, bytes.count) == bytes.count else {
            throw CocoaError(.fileWriteUnknown)
        }
    }
}

private func replaceSSOTLock(in root: URL) throws {
    let lock = root.appendingPathComponent(SSOTWriterOwnership.lockFileName)
    try FileManager.default.removeItem(at: lock)
    try Data("replacement\n".utf8).write(to: lock)
    guard Darwin.chmod(lock.path, 0o600) == 0 else { throw CocoaError(.fileWriteUnknown) }
}

private func fileSize(_ url: URL) -> Int {
    (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int) ?? -1
}
