import Darwin
import Foundation

nonisolated struct SSOTDestinationFileSnapshot: Equatable {
    let identity: ManagedItemIdentity
    let size: off_t
    let modificationSeconds: time_t
    let modificationNanoseconds: Int
    let statusChangeSeconds: time_t
    let statusChangeNanoseconds: Int

    init?(_ metadata: stat) {
        guard metadata.st_mode & mode_t(S_IFMT) == mode_t(S_IFREG),
              metadata.st_size >= 0 else { return nil }
        identity = ManagedItemIdentity(metadata)
        size = metadata.st_size
        modificationSeconds = metadata.st_mtimespec.tv_sec
        modificationNanoseconds = metadata.st_mtimespec.tv_nsec
        statusChangeSeconds = metadata.st_ctimespec.tv_sec
        statusChangeNanoseconds = metadata.st_ctimespec.tv_nsec
    }
}

nonisolated struct SSOTPartialCopyCleanupRequired: LocalizedError {
    let operationReason: String

    var errorDescription: String? {
        "Partial staging content changed or left its named parent; cleanup was skipped. "
            + "Original failure: \(operationReason)"
    }
}

nonisolated func unlinkSSOTCreatedFileIfUnchanged(
    named name: String,
    in parentDescriptor: Int32,
    fileDescriptor: Int32,
    rootDescriptor: Int32,
    parentComponents: [String],
    expectedSnapshot: SSOTDestinationFileSnapshot,
    admission: () throws -> Void
) -> Bool {
    do {
        try admission()
        let heldParent = try descriptorIdentity(parentDescriptor)
        let reopenedParent = try reopenDirectory(
            rootDescriptor: rootDescriptor,
            components: parentComponents
        )
        defer { Darwin.close(reopenedParent) }
        guard try descriptorIdentity(reopenedParent) == heldParent else { return false }
        var metadata = stat()
        guard Darwin.fstatat(reopenedParent, name, &metadata, AT_SYMLINK_NOFOLLOW) == 0,
              SSOTDestinationFileSnapshot(metadata) == expectedSnapshot,
              try destinationSnapshot(fileDescriptor) == expectedSnapshot else {
            return false
        }
        return Darwin.unlinkat(reopenedParent, name, 0) == 0
    } catch {
        return false
    }
}

nonisolated func destinationSnapshot(_ descriptor: Int32) throws -> SSOTDestinationFileSnapshot {
    var metadata = stat()
    guard Darwin.fstat(descriptor, &metadata) == 0,
          let snapshot = SSOTDestinationFileSnapshot(metadata) else {
        throw ManagedPathError.itemChanged
    }
    return snapshot
}

private nonisolated func reopenDirectory(
    rootDescriptor: Int32,
    components: [String]
) throws -> Int32 {
    var descriptor = Darwin.dup(rootDescriptor)
    guard descriptor >= 0 else { throw ManagedPathError.itemChanged }
    for component in components {
        let child = Darwin.openat(
            descriptor,
            component,
            O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC
        )
        guard child >= 0 else {
            Darwin.close(descriptor)
            throw ManagedPathError.itemChanged
        }
        Darwin.close(descriptor)
        descriptor = child
    }
    return descriptor
}

private nonisolated func descriptorIdentity(_ descriptor: Int32) throws -> ManagedItemIdentity {
    var metadata = stat()
    guard Darwin.fstat(descriptor, &metadata) == 0 else {
        throw ManagedPathError.itemChanged
    }
    return ManagedItemIdentity(metadata)
}

/// Removes a journal-owned staging/recovery tree in place. A failure never
/// renames the remaining tree away from its operation locator.
nonisolated final class SSOTJournalOwnedItemRemoval {
    typealias Boundary = (SSOTOperationFileSystemCheckpoint) throws -> Void
    typealias BeforeQuarantineMove = (_ name: String, _ parentDescriptor: Int32) throws -> Void
    private typealias DirectoryLink = SSOTJournalDeletionManifest.DirectoryLink
    private typealias FrozenEntry = SSOTJournalDeletionManifest.Entry
    private typealias FrozenDirectory = SSOTJournalDeletionManifest.Directory
    private typealias RegularFileSnapshot = SSOTJournalDeletionManifest.RegularFileSnapshot

    private struct TopLocator {
        let name: String
        let identity: ManagedItemIdentity
    }

    private let rootDescriptor: Int32
    private let boundary: Boundary
    private let beforeQuarantineMove: BeforeQuarantineMove

    init(
        rootDescriptor: Int32,
        boundary: @escaping Boundary,
        beforeQuarantineMove: @escaping BeforeQuarantineMove = { _, _ in }
    ) {
        self.rootDescriptor = rootDescriptor
        self.boundary = boundary
        self.beforeQuarantineMove = beforeQuarantineMove
    }

    func remove(
        named name: String,
        expectedIdentity: ManagedItemIdentity,
        manifest: SSOTJournalDeletionManifest
    ) throws {
        guard manifest.topIdentity == expectedIdentity else { throw ManagedPathError.itemChanged }
        let top = TopLocator(name: name, identity: expectedIdentity)
        let descriptor = try openDirectory(
            named: name,
            in: rootDescriptor,
            expectedIdentity: expectedIdentity
        )
        defer { Darwin.close(descriptor) }
        try validateManifest(manifest)
        for entry in manifest.removalOrder {
            guard let parent = manifest.directories[entry.parentKey] else {
                throw ManagedPathError.itemChanged
            }
            try removeFrozenEntry(
                entry,
                parent: parent,
                top: top
            )
        }
        try removeEntry(
            named: name,
            in: rootDescriptor,
            descriptor: descriptor,
            expectedIdentity: expectedIdentity,
            top: top,
            parentAncestry: [],
            flags: AT_REMOVEDIR,
            before: .beforeInPlaceRootRemoval,
            after: .afterInPlaceRootRemoval,
            topExistsAfterRemoval: false
        )
    }

    private func validateManifest(_ manifest: SSOTJournalDeletionManifest) throws {
        for directory in manifest.directories.values {
            let descriptor = try openAncestry(directory.ancestry)
            defer { Darwin.close(descriptor) }
            try SSOTJournalDeletionManifest.requireChildren(
                of: directory,
                remaining: Set(directory.entries.keys),
                descriptor: descriptor
            )
        }
    }

    private func removeFrozenEntry(
        _ entry: FrozenEntry,
        parent: FrozenDirectory,
        top: TopLocator
    ) throws {
        let parentDescriptor = try openAncestry(parent.ancestry)
        defer { Darwin.close(parentDescriptor) }
        let descriptor: Int32
        let fileSnapshot: RegularFileSnapshot?
        switch entry.item {
        case .file(let snapshot):
            descriptor = try openRegularFile(
                named: entry.name, in: parentDescriptor, expectedSnapshot: snapshot
            )
            fileSnapshot = snapshot
        case .directory(let identity):
            descriptor = try openDirectory(
                named: entry.name, in: parentDescriptor, expectedIdentity: identity
            )
            fileSnapshot = nil
        }
        defer { Darwin.close(descriptor) }
        try removeEntry(
            named: entry.name,
            in: parentDescriptor,
            descriptor: descriptor,
            expectedIdentity: entry.item.identity,
            top: top,
            parentAncestry: parent.ancestry,
            flags: fileSnapshot == nil ? AT_REMOVEDIR : 0,
            expectedFileSnapshot: fileSnapshot
        )
    }

    private func removeEntry(
        named name: String,
        in parentDescriptor: Int32,
        descriptor: Int32,
        expectedIdentity: ManagedItemIdentity,
        top: TopLocator,
        parentAncestry: [DirectoryLink],
        flags: Int32,
        before: SSOTOperationFileSystemCheckpoint = .beforeInPlaceEntryRemoval,
        after: SSOTOperationFileSystemCheckpoint = .afterInPlaceEntryRemoval,
        topExistsAfterRemoval: Bool = true,
        expectedFileSnapshot: RegularFileSnapshot? = nil
    ) throws {
        try mutate(
            before: before,
            after: after,
            top: top,
            parentDescriptor: parentDescriptor,
            parentAncestry: parentAncestry,
            topExistsAfterRemoval: topExistsAfterRemoval
        ) {
            if let expectedFileSnapshot {
                try requireFileSnapshot(expectedFileSnapshot, descriptor: descriptor)
                try requireFileSnapshot(
                    expectedFileSnapshot,
                    named: name,
                    in: parentDescriptor
                )
            } else {
                try requireDescriptorIdentity(expectedIdentity, descriptor: descriptor)
                try requireIdentity(expectedIdentity, named: name, in: parentDescriptor)
            }
            try beforeQuarantineMove(name, parentDescriptor)
            try quarantineAndRemove(
                named: name,
                in: parentDescriptor,
                descriptor: descriptor,
                expectedIdentity: expectedIdentity,
                operationScope: top.name,
                flags: flags,
                expectedFileSnapshot: expectedFileSnapshot
            )
            try requireDescriptorIdentity(expectedIdentity, descriptor: descriptor)
            guard try identityIfPresent(named: name, in: parentDescriptor) == nil else {
                throw ManagedPathError.itemChanged
            }
        }
    }

    private func quarantineAndRemove(
        named name: String,
        in parentDescriptor: Int32,
        descriptor: Int32,
        expectedIdentity: ManagedItemIdentity,
        operationScope: String,
        flags: Int32,
        expectedFileSnapshot: RegularFileSnapshot?
    ) throws {
        let quarantine = try SSOTJournalEntryQuarantine.move(
            named: name,
            in: parentDescriptor,
            operationScope: operationScope
        )
        do {
            try quarantine.requireExpected(
                heldDescriptor: descriptor,
                identity: expectedIdentity,
                fileSnapshot: expectedFileSnapshot
            )
            try quarantine.remove(flags: flags)
        } catch {
            quarantine.restore()
            throw error
        }
    }

    private func openRegularFile(
        named name: String,
        in parentDescriptor: Int32,
        expectedSnapshot: RegularFileSnapshot
    ) throws -> Int32 {
        let descriptor = Darwin.openat(
            parentDescriptor,
            name,
            O_RDONLY | O_NOFOLLOW | O_CLOEXEC
        )
        guard descriptor >= 0 else {
            throw openFailure("open journal-owned file", code: errno)
        }
        do {
            try requireFileSnapshot(expectedSnapshot, descriptor: descriptor)
            try requireFileSnapshot(expectedSnapshot, named: name, in: parentDescriptor)
            return descriptor
        } catch {
            Darwin.close(descriptor)
            throw error
        }
    }

    private func openDirectory(
        named name: String,
        in parentDescriptor: Int32,
        expectedIdentity: ManagedItemIdentity
    ) throws -> Int32 {
        let descriptor = Darwin.openat(
            parentDescriptor,
            name,
            O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC
        )
        guard descriptor >= 0 else {
            throw openFailure("open journal-owned directory", code: errno)
        }
        do {
            try requireDescriptorIdentity(expectedIdentity, descriptor: descriptor)
            try requireIdentity(expectedIdentity, named: name, in: parentDescriptor)
            return descriptor
        } catch {
            Darwin.close(descriptor)
            throw error
        }
    }

    private func requireDescriptorIdentity(
        _ expected: ManagedItemIdentity,
        descriptor: Int32
    ) throws {
        var metadata = stat()
        guard Darwin.fstat(descriptor, &metadata) == 0,
              ManagedItemIdentity(metadata) == expected else {
            throw ManagedPathError.itemChanged
        }
    }

    private func mutate(
        before: SSOTOperationFileSystemCheckpoint,
        after: SSOTOperationFileSystemCheckpoint,
        top: TopLocator,
        parentDescriptor: Int32,
        parentAncestry: [DirectoryLink],
        topExistsAfterRemoval: Bool,
        operation: () throws -> Void
    ) throws {
        try boundary(before)
        try requireTopLocator(top, exists: true)
        try requireParentAncestry(parentAncestry, heldDescriptor: parentDescriptor)
        try operation()
        try boundary(after)
        try requireTopLocator(top, exists: topExistsAfterRemoval)
        try requireParentAncestry(parentAncestry, heldDescriptor: parentDescriptor)
    }

    private func requireParentAncestry(
        _ ancestry: [DirectoryLink],
        heldDescriptor: Int32
    ) throws {
        let descriptor = try openAncestry(ancestry)
        defer { Darwin.close(descriptor) }
        guard try descriptorIdentity(descriptor) == descriptorIdentity(heldDescriptor) else {
            throw ManagedPathError.itemChanged
        }
    }

    private func openAncestry(_ ancestry: [DirectoryLink]) throws -> Int32 {
        var descriptor = Darwin.dup(rootDescriptor)
        guard descriptor >= 0 else { throw ManagedPathError.itemChanged }
        for link in ancestry {
            do {
                let child = try openDirectory(
                    named: link.name, in: descriptor, expectedIdentity: link.identity
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

    private func requireTopLocator(_ top: TopLocator, exists: Bool) throws {
        let actual = try identityIfPresent(named: top.name, in: rootDescriptor)
        guard exists ? actual == top.identity : actual == nil else {
            throw ManagedPathError.itemChanged
        }
    }

    private func requireFileSnapshot(
        _ expected: RegularFileSnapshot,
        descriptor: Int32
    ) throws {
        var metadata = stat()
        guard Darwin.fstat(descriptor, &metadata) == 0,
              RegularFileSnapshot(metadata) == expected else {
            throw ManagedPathError.itemChanged
        }
    }

    private func requireFileSnapshot(
        _ expected: RegularFileSnapshot,
        named name: String,
        in parentDescriptor: Int32
    ) throws {
        let metadata = try status(named: name, in: parentDescriptor)
        guard RegularFileSnapshot(metadata) == expected else {
            throw ManagedPathError.itemChanged
        }
    }

    private func requireIdentity(
        _ expected: ManagedItemIdentity,
        named name: String,
        in parentDescriptor: Int32
    ) throws {
        guard try identityIfPresent(named: name, in: parentDescriptor) == expected else {
            throw ManagedPathError.itemChanged
        }
    }

    private func identityIfPresent(
        named name: String,
        in parentDescriptor: Int32
    ) throws -> ManagedItemIdentity? {
        var metadata = stat()
        if Darwin.fstatat(parentDescriptor, name, &metadata, AT_SYMLINK_NOFOLLOW) == 0 {
            return ManagedItemIdentity(metadata)
        }
        if errno == ENOENT { return nil }
        throw posix("inspect journal-owned operation entry")
    }

    private func status(named name: String, in parentDescriptor: Int32) throws -> stat {
        var metadata = stat()
        let result = Darwin.fstatat(
            parentDescriptor,
            name,
            &metadata,
            AT_SYMLINK_NOFOLLOW
        )
        guard result == 0 else {
            throw openFailure("inspect journal-owned operation entry", code: errno)
        }
        return metadata
    }

    private func openFailure(_ operation: String, code: Int32) -> ManagedPathError {
        switch code {
        case ENOENT, ENOTDIR, ELOOP:
            .itemChanged
        default:
            .posix(operation: operation, code: code)
        }
    }

    private func removalFailure(_ operation: String, code: Int32) -> ManagedPathError {
        switch code {
        case ENOENT, ENOTDIR, EISDIR, ELOOP, ENOTEMPTY, EEXIST:
            .itemChanged
        default:
            .posix(operation: operation, code: code)
        }
    }

    private func posix(_ operation: String) -> ManagedPathError {
        .posix(operation: operation, code: errno)
    }
}
