import Darwin
import Foundation

nonisolated extension DistributionSymlinkFileSystem {
    func requireCopy(
        named name: String,
        in rootDescriptor: Int32,
        expected: DistributionCopyEvidence,
        displayPath: String
    ) throws {
        let descriptor = try openCopyDirectory(
            named: name,
            in: rootDescriptor,
            expectedIdentity: expected.entryIdentity
        )
        defer { Darwin.close(descriptor) }
        let observed = try copyEvidence(
            descriptor: descriptor,
            displayPath: displayPath,
            rootIdentity: expected.rootIdentity,
            entryIdentity: expected.entryIdentity
        )
        guard observed == expected else {
            throw DistributionSymlinkFileSystemError.entryChanged
        }
    }

    func copyEvidence(
        descriptor: Int32,
        displayPath: String,
        rootIdentity: ManagedItemIdentity,
        entryIdentity: ManagedItemIdentity
    ) throws -> DistributionCopyEvidence {
        let content = try SkillContentSnapshot.capture(
            directoryDescriptor: descriptor,
            displayPath: displayPath
        )
        let physical = try CopyPhysicalTreeSnapshot.captureTarget(
            directoryDescriptor: descriptor,
            displayPath: displayPath
        )
        return DistributionCopyEvidence(
            rootIdentity: rootIdentity,
            entryIdentity: entryIdentity,
            contentFingerprint: try SkillContentFingerprint(
                currentDigest: content.fingerprintDigest
            ),
            physicalTreeDigest: physical.digest
        )
    }

    func openCopyDirectory(
        named name: String,
        in parent: Int32,
        expectedIdentity: ManagedItemIdentity? = nil
    ) throws -> Int32 {
        let descriptor = Darwin.openat(
            parent,
            name,
            O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC
        )
        guard descriptor >= 0 else {
            throw DistributionSymlinkFileSystemError.entryChanged
        }
        var held = stat()
        var named = stat()
        guard Darwin.fstat(descriptor, &held) == 0,
              Darwin.fstatat(parent, name, &named, AT_SYMLINK_NOFOLLOW) == 0,
              held.st_mode & mode_t(S_IFMT) == mode_t(S_IFDIR),
              ManagedItemIdentity(held) == ManagedItemIdentity(named),
              expectedIdentity == nil || ManagedItemIdentity(held) == expectedIdentity else {
            Darwin.close(descriptor)
            throw DistributionSymlinkFileSystemError.entryChanged
        }
        return descriptor
    }

    func synchronize(_ snapshot: SkillContentSnapshot) throws {
        for file in snapshot.discoveredFiles {
            let parent = try openSnapshotDirectory(
                steps: file.directorySteps,
                tree: snapshot.sourceTree
            )
            let descriptor = Darwin.openat(
                parent,
                file.fileName,
                O_RDONLY | O_NOFOLLOW | O_CLOEXEC
            )
            Darwin.close(parent)
            guard descriptor >= 0 else { throw posix("open Copy file for sync") }
            do {
                try SSOTDurability.syncFile(descriptor)
                Darwin.close(descriptor)
            } catch {
                Darwin.close(descriptor)
                throw error
            }
        }
        for directory in snapshot.sourceDirectories.reversed() {
            let descriptor = try openSnapshotDirectory(
                steps: directory.steps,
                tree: snapshot.sourceTree
            )
            do {
                try SSOTDurability.syncDirectory(descriptor)
                Darwin.close(descriptor)
            } catch {
                Darwin.close(descriptor)
                throw error
            }
        }
        let root = try snapshot.sourceTree.duplicateRoot()
        defer { Darwin.close(root) }
        try SSOTDurability.syncDirectory(root)
    }

    func openSnapshotDirectory(
        steps: [SafeSourceTree.DirectoryStep],
        tree: SafeSourceTree
    ) throws -> Int32 {
        var descriptor = try tree.duplicateRoot()
        for step in steps {
            do {
                let child = try SafeSourceTree.openDirectory(
                    named: step.name,
                    in: descriptor,
                    expectedIdentity: step.identity,
                    displayPath: step.name
                )
                Darwin.close(descriptor)
                descriptor = child
            } catch {
                Darwin.close(descriptor)
                throw error
            }
        }
        return descriptor
    }

    func removeOwnedCopy(
        named name: String,
        rootDescriptor: Int32,
        expectedIdentity: ManagedItemIdentity?,
        expectedContent: SkillContentFingerprint?,
        expectedDigest: CopyPhysicalTreeDigest?
    ) throws {
        guard let expectedIdentity else { return }
        guard let actualIdentity = try identityIfPresent(name, in: rootDescriptor) else {
            return
        }
        guard actualIdentity == expectedIdentity else {
            throw DistributionSymlinkFileSystemError.entryChanged
        }
        let descriptor = try openCopyDirectory(
            named: name,
            in: rootDescriptor,
            expectedIdentity: expectedIdentity
        )
        defer { Darwin.close(descriptor) }
        let physical = try CopyPhysicalTreeSnapshot.captureTarget(
            directoryDescriptor: descriptor,
            displayPath: name
        )
        if let expectedDigest, physical.digest != expectedDigest {
            throw DistributionSymlinkFileSystemError.entryChanged
        }
        let snapshot = try SkillContentSnapshot.capture(
            directoryDescriptor: descriptor,
            displayPath: name
        )
        if let expectedContent,
           snapshot.fingerprintDigest != expectedContent.digest {
            throw DistributionSymlinkFileSystemError.entryChanged
        }
        let manifest = try SSOTJournalDeletionManifest.freeze(
            snapshot: snapshot,
            topName: name,
            topIdentity: expectedIdentity,
            maximumDepth: SkillContentLimits.default.maximumPathDepth
        )
        try makeCopyWritable(snapshot)
        try SSOTJournalOwnedItemRemoval(
            rootDescriptor: rootDescriptor,
            boundary: { _ in }
        ).remove(
            named: name,
            expectedIdentity: expectedIdentity,
            manifest: manifest
        )
    }

    private func makeCopyWritable(
        _ snapshot: SkillContentSnapshot
    ) throws {
        for directory in snapshot.sourceDirectories {
            let descriptor = try openSnapshotDirectory(
                steps: directory.steps,
                tree: snapshot.sourceTree
            )
            guard Darwin.fchmod(descriptor, mode_t(0o700)) == 0 else {
                let error = posix("make Copy directory removable")
                Darwin.close(descriptor)
                throw error
            }
            Darwin.close(descriptor)
        }
        let root = try snapshot.sourceTree.duplicateRoot()
        defer { Darwin.close(root) }
        guard Darwin.fchmod(root, mode_t(0o700)) == 0 else {
            throw posix("make Copy root removable")
        }
    }
}
