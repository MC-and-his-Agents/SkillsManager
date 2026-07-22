import Darwin
import Foundation
import Synchronization
import Testing

@testable import SkillsManager

@Suite("SSOT journal deletion manifest safety")
struct SSOTJournalDeletionManifestTests {
    @Test("later sibling rewrites preserve the foreign bytes")
    func laterSiblingRewriteRequiresRepair() throws {
        try assertLaterSiblingDrift(.rewrite)
    }

    @Test("later sibling replacements preserve the foreign inode")
    func laterSiblingReplacementRequiresRepair() throws {
        try assertLaterSiblingDrift(.replace)
    }

    @Test("missing later siblings are classified as identity drift")
    func missingLaterSiblingRequiresRepair() throws {
        try assertLaterSiblingDrift(.remove)
    }

    @Test("new later siblings are preserved and classified as identity drift")
    func addedLaterSiblingRequiresRepair() throws {
        try assertLaterSiblingDrift(.add)
    }

    @Test("fingerprint-excluded physical entries are never adopted for cleanup")
    func excludedPhysicalEntryRequiresRepair() throws {
        let workspace = try WriterWorkspace()
        let fileSystem = try makeFileSystem(workspace)
        let snapshot = try workspace.snapshot(content: "managed")
        let fingerprint = try currentFingerprint(snapshot)
        let staged = try fileSystem.stage(
            sourceSnapshot: snapshot,
            expectedFingerprint: fingerprint,
            operationID: UUID()
        )
        let stagedURL = fileSystem.operationItemURL(for: staged.reference)
        let excluded = stagedURL.appendingPathComponent(".git", isDirectory: true)
        try FileManager.default.createDirectory(at: excluded, withIntermediateDirectories: false)
        let foreign = excluded.appendingPathComponent("keep")
        try Data("foreign".utf8).write(to: foreign)

        #expect(throws: ManagedPathError.itemChanged) {
            try fileSystem.removeExpectedOperationItem(
                staged.reference,
                identity: staged.identity,
                fingerprint: fingerprint
            )
        }
        #expect(try Data(contentsOf: foreign) == Data("foreign".utf8))
        #expect(FileManager.default.fileExists(
            atPath: stagedURL.appendingPathComponent("SKILL.md").path
        ))
    }

    @Test("a same-name replacement after final validation is quarantined and preserved")
    func replacementAfterFinalValidationIsPreserved() throws {
        let workspace = try WriterWorkspace()
        let fileSystem = try makeFileSystem(workspace)
        try Data("manifest".utf8).write(
            to: workspace.source.appendingPathComponent("SKILL.md")
        )
        try Data("owned".utf8).write(to: workspace.source.appendingPathComponent("z.txt"))
        let sourceSnapshot = try SkillContentSnapshot.capture(at: workspace.source)
        let fingerprint = try currentFingerprint(sourceSnapshot)
        let staged = try fileSystem.stage(
            sourceSnapshot: sourceSnapshot,
            expectedFingerprint: fingerprint,
            operationID: UUID()
        )
        let stagedURL = fileSystem.operationItemURL(for: staged.reference)
        let snapshot = try SkillContentSnapshot.capture(at: stagedURL)
        let guardValue = try ManagedPathGuard(verifiedRoot: workspace.verifiedRoot)
        let displaced = stagedURL.appendingPathComponent("z-owned-displaced.txt")
        let foreign = Data("foreign-replacement".utf8)
        var replaced = false
        let removal = SSOTJournalOwnedItemRemoval(
            rootDescriptor: guardValue.rootDescriptor,
            boundary: { _ in },
            beforeQuarantineMove: { name, parentDescriptor in
                guard name == "z.txt", !replaced else { return }
                guard Darwin.renameatx_np(
                    parentDescriptor,
                    name,
                    parentDescriptor,
                    displaced.lastPathComponent,
                    UInt32(RENAME_EXCL)
                ) == 0 else { throw CocoaError(.fileWriteUnknown) }
                try foreign.write(to: stagedURL.appendingPathComponent(name))
                replaced = true
            }
        )
        let manifest = try SSOTJournalDeletionManifest.freeze(
            snapshot: snapshot,
            topName: stagedURL.lastPathComponent,
            topIdentity: staged.identity,
            maximumDepth: SkillContentLimits.default.maximumPathDepth
        )

        #expect(throws: ManagedPathError.itemChanged) {
            try removal.remove(
                named: stagedURL.lastPathComponent,
                expectedIdentity: staged.identity,
                manifest: manifest
            )
        }
        #expect(replaced)
        #expect(try Data(contentsOf: stagedURL.appendingPathComponent("z.txt")) == foreign)
        #expect(try Data(contentsOf: displaced) == Data("owned".utf8))
    }

    private enum LaterSiblingDrift {
        case rewrite
        case replace
        case remove
        case add
    }

    private func assertLaterSiblingDrift(_ drift: LaterSiblingDrift) throws {
        let workspace = try WriterWorkspace()
        let operationURL = Mutex<URL?>(nil)
        let mutated = Mutex(false)
        let foreign = Data("foreign-later-sibling".utf8)
        let hooks = SSOTOperationFileSystemTestHooks { checkpoint in
            guard checkpoint == .afterInPlaceEntryRemoval,
                  !mutated.withLock({ $0 }),
                  let operationURL = operationURL.withLock({ $0 }) else { return }
            try apply(
                drift,
                operationURL: operationURL,
                foreign: foreign
            )
            mutated.withLock { $0 = true }
        }
        let fileSystem = try makeFileSystem(workspace, hooks: hooks)
        try Data("manifest".utf8).write(
            to: workspace.source.appendingPathComponent("SKILL.md")
        )
        try Data("managed-later".utf8).write(
            to: workspace.source.appendingPathComponent("z.txt")
        )
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
        #expect(mutated.withLock { $0 })
        #expect(!FileManager.default.fileExists(
            atPath: stagedURL.appendingPathComponent("SKILL.md").path
        ))
        try assertPreservedResult(drift, stagedURL: stagedURL, foreign: foreign)
    }

    private func apply(
        _ drift: LaterSiblingDrift,
        operationURL: URL,
        foreign: Data
    ) throws {
        let later = operationURL.appendingPathComponent("z.txt")
        switch drift {
        case .rewrite:
            try overwriteInPlace(later, with: foreign)
        case .replace:
            try FileManager.default.removeItem(at: later)
            try foreign.write(to: later)
        case .remove:
            try FileManager.default.removeItem(at: later)
        case .add:
            try foreign.write(to: operationURL.appendingPathComponent("zz-foreign.txt"))
        }
    }

    private func assertPreservedResult(
        _ drift: LaterSiblingDrift,
        stagedURL: URL,
        foreign: Data
    ) throws {
        let later = stagedURL.appendingPathComponent("z.txt")
        switch drift {
        case .rewrite, .replace:
            #expect(try Data(contentsOf: later) == foreign)
        case .remove:
            #expect(!FileManager.default.fileExists(atPath: later.path))
        case .add:
            #expect(!FileManager.default.fileExists(atPath: later.path))
            #expect(try Data(contentsOf: stagedURL.appendingPathComponent("zz-foreign.txt"))
                == foreign)
        }
        #expect(FileManager.default.fileExists(atPath: stagedURL.path))
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
