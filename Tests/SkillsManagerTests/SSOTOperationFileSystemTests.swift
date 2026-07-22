import Darwin
import Foundation
import Synchronization
import Testing

@testable import SkillsManager

@Suite("SSOT operation filesystem")
struct SSOTOperationFileSystemTests {
    private enum Stop: Error { case requested }

    @Test("create promotion uses the UUID final name")
    func promotesCreate() throws {
        try withWorkspace { root, source in
            let fileSystem = try makeFileSystem(root: root)
            let snapshot = try sourceSnapshot(source, content: "first")
            let fingerprint = try currentFingerprint(snapshot)
            let operationID = UUID()
            let skillID = SkillID()

            let staged = try fileSystem.stage(
                sourceSnapshot: snapshot,
                expectedFingerprint: fingerprint,
                operationID: operationID
            )
            try fileSystem.promoteCreate(staged: staged, skillID: skillID)

            #expect(fileSystem.finalURL(skillID: skillID).lastPathComponent == skillID.directoryName)
            #expect(try fileSystem.observeFinal(
                skillID: skillID,
                expectedIdentity: staged.identity,
                expectedFingerprint: fingerprint
            ) == .expected)
            #expect(try fileSystem.observeOperationItem(
                staged.reference,
                expectedIdentity: staged.identity,
                expectedFingerprint: fingerprint
            ) == .absent)
        }
    }

    @Test("replacement returns a recovery role for the same operation locator")
    func swapsAndCleansRecovery() throws {
        try withWorkspace { root, source in
            let fileSystem = try makeFileSystem(root: root)
            let skillID = SkillID()
            let oldSnapshot = try sourceSnapshot(source, content: "old")
            let oldFingerprint = try currentFingerprint(oldSnapshot)
            let oldStaged = try fileSystem.stage(
                sourceSnapshot: oldSnapshot,
                expectedFingerprint: oldFingerprint,
                operationID: UUID()
            )
            try fileSystem.promoteCreate(staged: oldStaged, skillID: skillID)

            let newSnapshot = try sourceSnapshot(source, content: "new")
            let newFingerprint = try currentFingerprint(newSnapshot)
            let newStaged = try fileSystem.stage(
                sourceSnapshot: newSnapshot,
                expectedFingerprint: newFingerprint,
                operationID: UUID()
            )
            let recovery = try fileSystem.swapReplacement(
                staged: newStaged,
                skillID: skillID,
                expectedOldIdentity: oldStaged.identity,
                expectedOldFingerprint: oldFingerprint
            )

            #expect(recovery.role == .recovery)
            #expect(fileSystem.operationItemURL(for: recovery)
                == fileSystem.operationItemURL(for: newStaged.reference))
            #expect(try fileSystem.observeFinal(
                skillID: skillID,
                expectedIdentity: newStaged.identity,
                expectedFingerprint: newFingerprint
            ) == .expected)
            try fileSystem.removeExpectedOperationItem(
                recovery,
                identity: oldStaged.identity,
                fingerprint: oldFingerprint
            )
            #expect(try fileSystem.observeOperationItem(
                recovery,
                expectedIdentity: oldStaged.identity,
                expectedFingerprint: oldFingerprint
            ) == .absent)
        }
    }

    @Test("read-only files can reach the durability checkpoint")
    func syncsReadOnlyFiles() throws {
        try withWorkspace { root, source in
            let fileSystem = try makeFileSystem(root: root)
            let sourceFile = source.appendingPathComponent("SKILL.md")
            try Data("read only".utf8).write(to: sourceFile)
            #expect(Darwin.chmod(sourceFile.path, 0o444) == 0)
            let snapshot = try SkillContentSnapshot.capture(at: source)

            try fileSystem.synchronize(snapshot: snapshot)
            let fingerprint = try currentFingerprint(snapshot)
            _ = try fileSystem.stage(
                sourceSnapshot: snapshot,
                expectedFingerprint: fingerprint,
                operationID: UUID()
            )
        }
    }

    @Test("durability traversal observes cancellation before each item")
    func durabilityCanBeCancelled() throws {
        try withWorkspace { root, source in
            let fileSystem = try makeFileSystem(root: root)
            let snapshot = try sourceSnapshot(source, content: "cancel")
            var checkpointCount = 0

            #expect(throws: Stop.requested) {
                try fileSystem.synchronize(snapshot: snapshot) {
                    checkpointCount += 1
                    throw Stop.requested
                }
            }
            #expect(checkpointCount == 1)
        }
    }

    @Test("wrong lifecycle role cannot be promoted")
    func rejectsWrongRole() throws {
        try withWorkspace { root, source in
            let fileSystem = try makeFileSystem(root: root)
            let snapshot = try sourceSnapshot(source, content: "role")
            let fingerprint = try currentFingerprint(snapshot)
            let staged = try fileSystem.stage(
                sourceSnapshot: snapshot,
                expectedFingerprint: fingerprint,
                operationID: UUID()
            )
            let wrongRole = SSOTStagedItem(
                reference: .recovery(operationID: staged.reference.operationID),
                identity: staged.identity,
                fingerprint: staged.fingerprint
            )

            #expect(throws: SSOTOperationFileSystemError.invalidOperationItemRole) {
                try fileSystem.promoteCreate(staged: wrongRole, skillID: SkillID())
            }
        }
    }

    @Test("root replacement fails before mutation")
    func rejectsReplacedRoot() throws {
        try withWorkspace { root, source in
            let fileSystem = try makeFileSystem(root: root)
            let snapshot = try sourceSnapshot(source, content: "root")
            let fingerprint = try currentFingerprint(snapshot)
            let moved = root.deletingLastPathComponent().appendingPathComponent("old-root")
            try FileManager.default.moveItem(at: root, to: moved)
            defer { try? FileManager.default.removeItem(at: moved) }
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
            #expect(Darwin.chmod(root.path, 0o700) == 0)

            #expect(throws: ManagedPathError.rootReplaced) {
                try fileSystem.stage(
                    sourceSnapshot: snapshot,
                    expectedFingerprint: fingerprint,
                    operationID: UUID()
                )
            }
        }
    }

    @Test("before staging create lock drift does not create a directory")
    func rejectsLockDriftBeforeStagingCreate() throws {
        try withWorkspace { root, source in
            let hooks = SSOTOperationFileSystemTestHooks { checkpoint in
                guard checkpoint == .beforeStagingDirectoryCreate else { return }
                let lock = root.appendingPathComponent(SSOTWriterOwnership.lockFileName)
                try FileManager.default.removeItem(at: lock)
                try Data("replacement\n".utf8).write(to: lock)
                guard Darwin.chmod(lock.path, 0o600) == 0 else {
                    throw CocoaError(.fileWriteUnknown)
                }
            }
            let fileSystem = try makeFileSystem(root: root, hooks: hooks)
            let snapshot = try sourceSnapshot(source, content: "lock")
            let fingerprint = try currentFingerprint(snapshot)
            let operationID = UUID()
            #expect(throws: SSOTWriterOwnershipError.invalidLockFile) {
                try fileSystem.stage(
                    sourceSnapshot: snapshot,
                    expectedFingerprint: fingerprint,
                    operationID: operationID
                )
            }
            #expect(!FileManager.default.fileExists(
                atPath: fileSystem.operationItemURL(for: .staging(operationID: operationID)).path
            ))
            let names = try FileManager.default.contentsOfDirectory(atPath: root.path)
            #expect(names.allSatisfy { !$0.hasPrefix(".skillsmanager-tmp-create-") })
        }
    }

    @Test("before create promotion item drift does not rename")
    func rejectsItemDriftBeforeCreatePromotion() throws {
        try withWorkspace { root, source in
            let operationURL = Mutex<URL?>(nil)
            let hooks = SSOTOperationFileSystemTestHooks { checkpoint in
                guard checkpoint == .beforeCreateRename,
                      let operationURL = operationURL.withLock({ $0 }) else { return }
                try Data("drift".utf8).write(to: operationURL.appendingPathComponent("SKILL.md"))
            }
            let fileSystem = try makeFileSystem(root: root, hooks: hooks)
            let snapshot = try sourceSnapshot(source, content: "promotion")
            let fingerprint = try currentFingerprint(snapshot)
            let staged = try fileSystem.stage(
                sourceSnapshot: snapshot,
                expectedFingerprint: fingerprint,
                operationID: UUID()
            )
            operationURL.withLock { $0 = fileSystem.operationItemURL(for: staged.reference) }
            let skillID = SkillID()
            #expect(throws: SSOTOperationFileSystemError.itemChanged) {
                try fileSystem.promoteCreate(staged: staged, skillID: skillID)
            }
            #expect(!FileManager.default.fileExists(atPath: fileSystem.finalURL(skillID: skillID).path))
            #expect(FileManager.default.fileExists(atPath: operationURL.withLock { $0!.path }))
        }
    }

    @Test("before replacement drift does not swap final and staging")
    func rejectsDriftBeforeReplacementSwap() throws {
        try withWorkspace { root, source in
            let finalURL = Mutex<URL?>(nil)
            let hooks = SSOTOperationFileSystemTestHooks { checkpoint in
                guard checkpoint == .beforeReplacementSwap,
                      let finalURL = finalURL.withLock({ $0 }) else { return }
                try Data("drift".utf8).write(to: finalURL.appendingPathComponent("SKILL.md"))
            }
            let fileSystem = try makeFileSystem(root: root, hooks: hooks)
            let skillID = SkillID()
            let oldSnapshot = try sourceSnapshot(source, content: "old")
            let oldFingerprint = try currentFingerprint(oldSnapshot)
            let oldStaged = try fileSystem.stage(
                sourceSnapshot: oldSnapshot, expectedFingerprint: oldFingerprint, operationID: UUID()
            )
            try fileSystem.promoteCreate(staged: oldStaged, skillID: skillID)
            finalURL.withLock { $0 = fileSystem.finalURL(skillID: skillID) }
            let newSnapshot = try sourceSnapshot(source, content: "new")
            let newFingerprint = try currentFingerprint(newSnapshot)
            let newStaged = try fileSystem.stage(
                sourceSnapshot: newSnapshot, expectedFingerprint: newFingerprint, operationID: UUID()
            )
            #expect(throws: SSOTOperationFileSystemError.itemChanged) {
                try fileSystem.swapReplacement(
                    staged: newStaged,
                    skillID: skillID,
                    expectedOldIdentity: oldStaged.identity,
                    expectedOldFingerprint: oldFingerprint
                )
            }
            let actualFinal = try fileSystem.managedRootGuard.itemIdentity(
                at: fileSystem.finalURL(skillID: skillID)
            )
            #expect(actualFinal == oldStaged.identity)
            #expect(try fileSystem.observeOperationItem(
                newStaged.reference, expectedIdentity: newStaged.identity,
                expectedFingerprint: newFingerprint
            ) == .expected)
        }
    }

    @Test("filesystem checkpoints follow mutation and durability order")
    func emitsCheckpointsInOrder() throws {
        try withWorkspace { root, source in
            let reached = Mutex<[SSOTOperationFileSystemCheckpoint]>([])
            let hooks = SSOTOperationFileSystemTestHooks { checkpoint in
                reached.withLock { $0.append(checkpoint) }
            }
            let fileSystem = try makeFileSystem(root: root, hooks: hooks)
            let skillID = SkillID()
            let oldSnapshot = try sourceSnapshot(source, content: "old")
            let oldFingerprint = try currentFingerprint(oldSnapshot)
            let oldStaged = try fileSystem.stage(
                sourceSnapshot: oldSnapshot,
                expectedFingerprint: oldFingerprint,
                operationID: UUID()
            )
            try fileSystem.promoteCreate(staged: oldStaged, skillID: skillID)
            let newSnapshot = try sourceSnapshot(source, content: "new")
            let newFingerprint = try currentFingerprint(newSnapshot)
            let newStaged = try fileSystem.stage(
                sourceSnapshot: newSnapshot,
                expectedFingerprint: newFingerprint,
                operationID: UUID()
            )
            let recovery = try fileSystem.swapReplacement(
                staged: newStaged,
                skillID: skillID,
                expectedOldIdentity: oldStaged.identity,
                expectedOldFingerprint: oldFingerprint
            )
            try fileSystem.removeExpectedOperationItem(
                recovery,
                identity: oldStaged.identity,
                fingerprint: oldFingerprint
            )

            #expect(reached.withLock { $0 } == [
                .beforeStagingDirectoryCreate,
                .afterStagingDirectoryCreateBeforeCopy,
                .beforeStagingDurability,
                .afterStagingDurabilityBeforeParentSync,
                .afterStagingParentSyncBeforeValidation,
                .beforeCreateRename,
                .afterCreateRenameBeforeParentSync,
                .afterCreateParentSyncBeforeValidation,
                .beforeStagingDirectoryCreate,
                .afterStagingDirectoryCreateBeforeCopy,
                .beforeStagingDurability,
                .afterStagingDurabilityBeforeParentSync,
                .afterStagingParentSyncBeforeValidation,
                .beforeReplacementSwap,
                .afterReplacementSwapBeforeParentSync,
                .afterReplacementParentSyncBeforeValidation,
                .beforeCleanupRemoval,
                .beforeInPlaceEntryRemoval,
                .afterInPlaceEntryRemoval,
                .beforeInPlaceRootRemoval,
                .afterInPlaceRootRemoval,
                .afterCleanupRemovalBeforeParentSync,
                .afterCleanupParentSyncBeforeValidation,
            ])
        }
    }

    @Test("interrupted cleanup keeps every residual under the operation locator")
    func interruptedCleanupKeepsOperationLocator() throws {
        try withWorkspace { root, source in
            let hooks = SSOTOperationFileSystemTestHooks { checkpoint in
                if checkpoint == .afterInPlaceEntryRemoval { throw Stop.requested }
            }
            let fileSystem = try makeFileSystem(root: root, hooks: hooks)
            let nested = source.appendingPathComponent("nested", isDirectory: true)
            try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: false)
            try Data("manifest".utf8).write(to: source.appendingPathComponent("SKILL.md"))
            try Data("payload".utf8).write(to: nested.appendingPathComponent("payload.txt"))
            let snapshot = try SkillContentSnapshot.capture(at: source)
            let fingerprint = try currentFingerprint(snapshot)
            let staged = try fileSystem.stage(
                sourceSnapshot: snapshot,
                expectedFingerprint: fingerprint,
                operationID: UUID()
            )
            let operationURL = fileSystem.operationItemURL(for: staged.reference)
            #expect(throws: Stop.requested) {
                try fileSystem.removeExpectedOperationItem(
                    staged.reference,
                    identity: staged.identity,
                    fingerprint: fingerprint
                )
            }
            #expect(FileManager.default.fileExists(atPath: operationURL.path))
            let rootNames = try FileManager.default.contentsOfDirectory(atPath: root.path)
            #expect(!rootNames.contains { $0.hasPrefix(".skillsmanager-delete-") })
            let residual = try FileManager.default.subpathsOfDirectory(atPath: operationURL.path)
            #expect(!residual.contains { $0.contains(".skillsmanager-delete-") })
        }
    }

    @Test("lock replacement during recursive removal stops at the operation locator")
    func lockReplacementStopsRecursiveRemoval() throws {
        try withWorkspace { root, source in
            let hooks = SSOTOperationFileSystemTestHooks { checkpoint in
                guard checkpoint == .afterInPlaceEntryRemoval else { return }
                let lock = root.appendingPathComponent(SSOTWriterOwnership.lockFileName)
                try FileManager.default.removeItem(at: lock)
                try Data("replacement\n".utf8).write(to: lock)
                guard Darwin.chmod(lock.path, 0o600) == 0 else {
                    throw CocoaError(.fileWriteUnknown)
                }
            }
            let fileSystem = try makeFileSystem(root: root, hooks: hooks)
            let snapshot = try sourceSnapshot(source, content: "keep locator")
            let fingerprint = try currentFingerprint(snapshot)
            let staged = try fileSystem.stage(
                sourceSnapshot: snapshot,
                expectedFingerprint: fingerprint,
                operationID: UUID()
            )
            let operationURL = fileSystem.operationItemURL(for: staged.reference)
            #expect(throws: SSOTWriterOwnershipError.invalidLockFile) {
                try fileSystem.removeExpectedOperationItem(
                    staged.reference,
                    identity: staged.identity,
                    fingerprint: fingerprint
                )
            }
            #expect(FileManager.default.fileExists(atPath: operationURL.path))
            #expect(!FileManager.default.fileExists(
                atPath: root.appendingPathComponent(".skillsmanager-delete-").path
            ))
        }
    }

    @Test("before cleanup content drift preserves the journal-owned locator")
    func cleanupContentDriftFailsClosed() throws {
        try withWorkspace { root, source in
            let operationURL = Mutex<URL?>(nil)
            let replacement = Data("replacement".utf8)
            let hooks = SSOTOperationFileSystemTestHooks { checkpoint in
                guard checkpoint == .beforeCleanupRemoval,
                      let operationURL = operationURL.withLock({ $0 }) else { return }
                let file = operationURL.appendingPathComponent("SKILL.md")
                try FileManager.default.removeItem(at: file)
                try replacement.write(to: file)
            }
            let fileSystem = try makeFileSystem(root: root, hooks: hooks)
            let snapshot = try sourceSnapshot(source, content: "original")
            let fingerprint = try currentFingerprint(snapshot)
            let staged = try fileSystem.stage(
                sourceSnapshot: snapshot,
                expectedFingerprint: fingerprint,
                operationID: UUID()
            )
            let stagedURL = fileSystem.operationItemURL(for: staged.reference)
            operationURL.withLock { $0 = stagedURL }
            #expect(throws: SSOTOperationFileSystemError.itemChanged) {
                try fileSystem.removeExpectedOperationItem(
                    staged.reference,
                    identity: staged.identity,
                    fingerprint: fingerprint
                )
            }
            #expect(FileManager.default.fileExists(atPath: stagedURL.path))
            #expect(try Data(contentsOf: stagedURL.appendingPathComponent("SKILL.md")) == replacement)
        }
    }

    @Test("observation propagates cancellation")
    func observationPropagatesCancellation() throws {
        try withWorkspace { root, source in
            let fileSystem = try makeFileSystem(root: root)
            let snapshot = try sourceSnapshot(source, content: "cancel observation")
            let fingerprint = try currentFingerprint(snapshot)
            let staged = try fileSystem.stage(
                sourceSnapshot: snapshot,
                expectedFingerprint: fingerprint,
                operationID: UUID()
            )

            #expect(throws: CancellationError.self) {
                try fileSystem.observeOperationItem(
                    staged.reference,
                    expectedIdentity: staged.identity,
                    expectedFingerprint: fingerprint,
                    checkpoint: { throw CancellationError() }
                )
            }
        }
    }

    private func makeFileSystem(
        root: URL,
        hooks: SSOTOperationFileSystemTestHooks = .init()
    ) throws -> SSOTOperationFileSystem {
        #expect(Darwin.chmod(root.path, 0o700) == 0)
        let descriptor = Darwin.open(root.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard descriptor >= 0 else { throw CocoaError(.fileReadUnknown) }
        defer { Darwin.close(descriptor) }
        let verifiedRoot = try VerifiedSSOTRoot(existingRootURL: root, descriptor: descriptor)
        let ownershipGuard = try ManagedPathGuard(verifiedRoot: verifiedRoot)
        let ownership = try SSOTWriterOwnership.acquire(using: ownershipGuard)
        return try SSOTOperationFileSystem(
            verifiedRoot: verifiedRoot,
            ownership: ownership,
            hooks: hooks
        )
    }

    private func sourceSnapshot(_ source: URL, content: String) throws -> SkillContentSnapshot {
        let file = source.appendingPathComponent("SKILL.md")
        try Data(content.utf8).write(to: file, options: .atomic)
        return try SkillContentSnapshot.capture(at: source)
    }

    private func currentFingerprint(_ snapshot: SkillContentSnapshot) throws -> SkillContentFingerprint {
        try SkillContentFingerprint(currentDigest: snapshot.fingerprintDigest)
    }

    private func withWorkspace(_ body: (URL, URL) throws -> Void) throws {
        let workspace = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let root = workspace.appendingPathComponent("skills", isDirectory: true)
        let source = workspace.appendingPathComponent("source", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: workspace) }
        try body(root, source)
    }
}
