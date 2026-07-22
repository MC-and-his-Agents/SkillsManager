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

    private struct TopLocator {
        let name: String
        let identity: ManagedItemIdentity
    }

    private struct DirectoryLink {
        let name: String
        let identity: ManagedItemIdentity
    }

    private struct RegularFileSnapshot: Equatable {
        let identity: ManagedItemIdentity
        let size: off_t
        let byteCount: UInt64
        let modificationSeconds: time_t
        let modificationNanoseconds: Int
        let statusChangeSeconds: time_t
        let statusChangeNanoseconds: Int

        init?(_ metadata: stat) {
            guard metadata.st_size >= 0 else { return nil }
            identity = ManagedItemIdentity(metadata)
            size = metadata.st_size
            byteCount = UInt64(metadata.st_size)
            modificationSeconds = metadata.st_mtimespec.tv_sec
            modificationNanoseconds = metadata.st_mtimespec.tv_nsec
            statusChangeSeconds = metadata.st_ctimespec.tv_sec
            statusChangeNanoseconds = metadata.st_ctimespec.tv_nsec
        }
    }

    private let rootDescriptor: Int32
    private let maximumDepth: Int
    private let boundary: Boundary

    init(
        rootDescriptor: Int32,
        maximumDepth: Int,
        boundary: @escaping Boundary
    ) {
        self.rootDescriptor = rootDescriptor
        self.maximumDepth = maximumDepth
        self.boundary = boundary
    }

    func remove(named name: String, expectedIdentity: ManagedItemIdentity) throws {
        let top = TopLocator(name: name, identity: expectedIdentity)
        let descriptor = try openDirectory(
            named: name,
            in: rootDescriptor,
            expectedIdentity: expectedIdentity
        )
        defer { Darwin.close(descriptor) }
        let ancestry = [DirectoryLink(name: name, identity: expectedIdentity)]
        try removeContents(of: descriptor, depth: 0, top: top, ancestry: ancestry)
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

    private func removeContents(
        of descriptor: Int32,
        depth: Int,
        top: TopLocator,
        ancestry: [DirectoryLink]
    ) throws {
        guard depth <= maximumDepth else { throw ManagedPathError.itemChanged }
        let names = try SafeSourceTree.names(in: descriptor, displayPath: "journal-owned item")
            .sorted { $0.utf8.lexicographicallyPrecedes($1.utf8) }
        for name in names {
            let metadata = try status(named: name, in: descriptor)
            let identity = ManagedItemIdentity(metadata)
            switch metadata.st_mode & mode_t(S_IFMT) {
            case mode_t(S_IFREG):
                guard let snapshot = RegularFileSnapshot(metadata) else {
                    throw ManagedPathError.itemChanged
                }
                let file = try openRegularFile(
                    named: name,
                    in: descriptor,
                    expectedSnapshot: snapshot
                )
                do {
                    defer { Darwin.close(file) }
                    try removeEntry(
                        named: name,
                        in: descriptor,
                        descriptor: file,
                        expectedIdentity: identity,
                        top: top,
                        parentAncestry: ancestry,
                        flags: 0,
                        expectedFileSnapshot: snapshot
                    )
                }
            case mode_t(S_IFDIR):
                let child = try openDirectory(
                    named: name,
                    in: descriptor,
                    expectedIdentity: identity
                )
                do {
                    defer { Darwin.close(child) }
                    let childAncestry = ancestry + [DirectoryLink(name: name, identity: identity)]
                    try removeContents(
                        of: child,
                        depth: depth + 1,
                        top: top,
                        ancestry: childAncestry
                    )
                    try removeEntry(
                        named: name,
                        in: descriptor,
                        descriptor: child,
                        expectedIdentity: identity,
                        top: top,
                        parentAncestry: ancestry,
                        flags: AT_REMOVEDIR
                    )
                }
            default:
                throw ManagedPathError.unsupportedItemType
            }
        }
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
            guard Darwin.unlinkat(parentDescriptor, name, flags) == 0 else {
                throw posix("remove journal-owned operation entry")
            }
            try requireDescriptorIdentity(expectedIdentity, descriptor: descriptor)
            guard try identityIfPresent(named: name, in: parentDescriptor) == nil else {
                throw ManagedPathError.itemChanged
            }
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
        guard descriptor >= 0 else { throw posix("open journal-owned file") }
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
        guard descriptor >= 0 else { throw posix("open journal-owned directory") }
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
        var descriptor = Darwin.dup(rootDescriptor)
        guard descriptor >= 0 else { throw ManagedPathError.itemChanged }
        defer { Darwin.close(descriptor) }
        for link in ancestry {
            let child = try openDirectory(
                named: link.name,
                in: descriptor,
                expectedIdentity: link.identity
            )
            Darwin.close(descriptor)
            descriptor = child
        }
        guard try descriptorIdentity(descriptor) == descriptorIdentity(heldDescriptor) else {
            throw ManagedPathError.itemChanged
        }
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
        guard Darwin.fstatat(
            parentDescriptor,
            name,
            &metadata,
            AT_SYMLINK_NOFOLLOW
        ) == 0 else {
            throw posix("inspect journal-owned operation entry")
        }
        return metadata
    }

    private func posix(_ operation: String) -> ManagedPathError {
        .posix(operation: operation, code: errno)
    }
}
