import Darwin
import Foundation

nonisolated enum DistributionFilesystemCheckpoint: Equatable, Sendable {
    case beforeRootCreate
    case afterRootCreateBeforeSync
    case afterRootSync
    case beforeRemoveRename
    case afterRemoveRenameBeforeSync
    case afterRemoveSync
    case beforeCreate
    case afterCreateBeforeIdentity
    case afterCreateIdentityBeforeSync
    case afterCreateSync
    case beforeRollback
    case afterRollbackBeforeSync
    case afterRollbackSync
    case beforeCleanup
    case afterCleanupBeforeSync
    case afterCleanupSync
}

nonisolated struct DistributionFilesystemTestHooks: Sendable {
    private let onCheckpoint: @Sendable (DistributionFilesystemCheckpoint) throws -> Void

    init(
        onCheckpoint: @escaping @Sendable (DistributionFilesystemCheckpoint) throws -> Void = { _ in }
    ) {
        self.onCheckpoint = onCheckpoint
    }

    func reach(_ checkpoint: DistributionFilesystemCheckpoint) throws {
        try onCheckpoint(checkpoint)
    }
}

nonisolated enum DistributionSymlinkObservation: Equatable, Sendable {
    case missing(rootIdentity: ManagedItemIdentity?)
    case unavailable
    case symlink(
        rootIdentity: ManagedItemIdentity,
        entryIdentity: ManagedItemIdentity,
        target: String
    )
    case unknown(rootIdentity: ManagedItemIdentity, entryIdentity: ManagedItemIdentity)
}

nonisolated struct DistributionSymlinkEvidence: Equatable, Sendable {
    let rootIdentity: ManagedItemIdentity
    let entryIdentity: ManagedItemIdentity
    let absoluteTarget: String
}

nonisolated struct DistributionQuarantinedSymlink: Equatable, Sendable {
    let temporaryName: String
    let evidence: DistributionSymlinkEvidence
}

nonisolated enum DistributionSymlinkFileSystemError: LocalizedError, Equatable {
    case invalidTarget
    case unavailable
    case entryChanged
    case equivalentSibling
    case temporaryEntryExists
    case posix(operation: String, code: Int32)

    var errorDescription: String? {
        switch self {
        case .invalidTarget:
            "The distribution target is not an approved user Skill directory."
        case .unavailable:
            "The distribution target directory is unavailable."
        case .entryChanged:
            "The distribution entry changed while it was being verified."
        case .equivalentSibling:
            "An equivalent Skill name already exists in the target directory."
        case .temporaryEntryExists:
            "The operation temporary entry already exists."
        case .posix(let operation, let code):
            "\(operation) failed: \(String(cString: strerror(code)))"
        }
    }
}

/// Descriptor-backed file operations. Journal decisions belong to the executor.
nonisolated final class DistributionSymlinkFileSystem {
    private let homeURL: URL
    private let hooks: DistributionFilesystemTestHooks

    init(homeURL: URL, hooks: DistributionFilesystemTestHooks = .init()) throws {
        guard homeURL.isFileURL, homeURL.path.hasPrefix("/"), homeURL.path != "/" else {
            throw DistributionSymlinkFileSystemError.invalidTarget
        }
        self.homeURL = homeURL.standardizedFileURL
        self.hooks = hooks
        let home = try openHome()
        Darwin.close(home)
    }

    func ssotEvidence(for skillID: SkillID) throws -> (
        absoluteTarget: String,
        identity: ManagedItemIdentity
    ) {
        let components = [
            LibraryRootLayout.managementDirectoryName,
            LibraryRootLayout.ssotDirectoryName,
            skillID.directoryName,
        ]
        let handle = try openDirectory(components: components, createMissing: false)
        defer { Darwin.close(handle.descriptor) }
        return (
            components.reduce(homeURL) { $0.appendingPathComponent($1, isDirectory: true) }
                .standardizedFileURL.path,
            handle.identity
        )
    }

    func ensureRoot(for scope: DistributionBindingScope) throws -> ManagedItemIdentity {
        let handle = try openDirectory(components: try components(for: scope), createMissing: true)
        defer { Darwin.close(handle.descriptor) }
        return handle.identity
    }

    func existingRoot(for scope: DistributionBindingScope) throws -> ManagedItemIdentity? {
        do {
            let handle = try openDirectory(components: try components(for: scope), createMissing: false)
            defer { Darwin.close(handle.descriptor) }
            return handle.identity
        } catch DistributionSymlinkFileSystemError.unavailable {
            return nil
        }
    }

    func observe(_ entry: DistributionTargetEntry) throws -> DistributionSymlinkObservation {
        let components = try components(for: entry.target.scope)
        let handle: DirectoryHandle
        do {
            handle = try openDirectory(components: components, createMissing: false)
        } catch DistributionSymlinkFileSystemError.unavailable {
            if try classifyUnavailableRoot(components) == .missing {
                return .missing(rootIdentity: nil)
            }
            return .unavailable
        }
        defer { Darwin.close(handle.descriptor) }
        try requireUniqueName(entry.distributionSlug.value, in: handle.descriptor)

        var metadata = stat()
        guard Darwin.fstatat(
            handle.descriptor,
            entry.distributionSlug.value,
            &metadata,
            AT_SYMLINK_NOFOLLOW
        ) == 0 else {
            if errno == ENOENT {
                try verifyRoot(handle, components: components)
                return .missing(rootIdentity: handle.identity)
            }
            throw posix("inspect distribution entry")
        }
        let identity = ManagedItemIdentity(metadata)
        if metadata.st_mode & mode_t(S_IFMT) != mode_t(S_IFLNK) {
            return .unknown(rootIdentity: handle.identity, entryIdentity: identity)
        }
        let target = try readLink(entry.distributionSlug.value, in: handle.descriptor)
        try verifyRoot(handle, components: components)
        return .symlink(
            rootIdentity: handle.identity,
            entryIdentity: identity,
            target: target
        )
    }

    func quarantine(
        _ entry: DistributionTargetEntry,
        expected: DistributionSymlinkEvidence,
        operationID: UUID,
        actionIndex: Int
    ) throws -> DistributionQuarantinedSymlink {
        let components = try components(for: entry.target.scope)
        let handle = try openDirectory(components: components, createMissing: false)
        defer { Darwin.close(handle.descriptor) }
        guard handle.identity == expected.rootIdentity else {
            throw DistributionSymlinkFileSystemError.entryChanged
        }
        let name = entry.distributionSlug.value
        try verify(
            name: name,
            expectedIdentity: expected.entryIdentity,
            expectedTarget: expected.absoluteTarget,
            in: handle.descriptor
        )
        let temporaryName = temporaryName(operationID: operationID, actionIndex: actionIndex)
        guard try identityIfPresent(temporaryName, in: handle.descriptor) == nil else {
            throw DistributionSymlinkFileSystemError.temporaryEntryExists
        }
        try hooks.reach(.beforeRemoveRename)
        guard Darwin.renameatx_np(
            handle.descriptor,
            name,
            handle.descriptor,
            temporaryName,
            UInt32(RENAME_EXCL)
        ) == 0 else {
            throw posix("quarantine distribution symlink")
        }
        try hooks.reach(.afterRemoveRenameBeforeSync)
        try SSOTDurability.syncDirectory(handle.descriptor)
        try hooks.reach(.afterRemoveSync)
        try verify(
            name: temporaryName,
            expectedIdentity: expected.entryIdentity,
            expectedTarget: expected.absoluteTarget,
            in: handle.descriptor
        )
        guard try identityIfPresent(name, in: handle.descriptor) == nil else {
            throw DistributionSymlinkFileSystemError.entryChanged
        }
        try verifyRoot(handle, components: components)
        return DistributionQuarantinedSymlink(
            temporaryName: temporaryName,
            evidence: expected
        )
    }

    func create(
        _ entry: DistributionTargetEntry,
        absoluteTarget: String,
        expectedRootIdentity: ManagedItemIdentity
    ) throws -> DistributionSymlinkEvidence {
        let components = try components(for: entry.target.scope)
        let handle = try openDirectory(components: components, createMissing: false)
        defer { Darwin.close(handle.descriptor) }
        guard handle.identity == expectedRootIdentity else {
            throw DistributionSymlinkFileSystemError.entryChanged
        }
        let name = entry.distributionSlug.value
        try requireUniqueName(name, in: handle.descriptor)
        guard try identityIfPresent(name, in: handle.descriptor) == nil else {
            throw DistributionSymlinkFileSystemError.entryChanged
        }
        try hooks.reach(.beforeCreate)
        guard Darwin.symlinkat(absoluteTarget, handle.descriptor, name) == 0 else {
            throw posix("create distribution symlink")
        }
        try hooks.reach(.afterCreateBeforeIdentity)
        let identity = try requiredIdentity(name, in: handle.descriptor)
        try verify(
            name: name,
            expectedIdentity: identity,
            expectedTarget: absoluteTarget,
            in: handle.descriptor
        )
        try hooks.reach(.afterCreateIdentityBeforeSync)
        try SSOTDurability.syncDirectory(handle.descriptor)
        try hooks.reach(.afterCreateSync)
        try verifyRoot(handle, components: components)
        return DistributionSymlinkEvidence(
            rootIdentity: handle.identity,
            entryIdentity: identity,
            absoluteTarget: absoluteTarget
        )
    }

    func restore(
        _ entry: DistributionTargetEntry,
        quarantined: DistributionQuarantinedSymlink
    ) throws {
        let components = try components(for: entry.target.scope)
        let handle = try openDirectory(components: components, createMissing: false)
        defer { Darwin.close(handle.descriptor) }
        guard handle.identity == quarantined.evidence.rootIdentity else {
            throw DistributionSymlinkFileSystemError.entryChanged
        }
        let finalName = entry.distributionSlug.value
        guard try identityIfPresent(finalName, in: handle.descriptor) == nil else {
            throw DistributionSymlinkFileSystemError.entryChanged
        }
        try verify(
            name: quarantined.temporaryName,
            expectedIdentity: quarantined.evidence.entryIdentity,
            expectedTarget: quarantined.evidence.absoluteTarget,
            in: handle.descriptor
        )
        try hooks.reach(.beforeRollback)
        guard Darwin.renameatx_np(
            handle.descriptor,
            quarantined.temporaryName,
            handle.descriptor,
            finalName,
            UInt32(RENAME_EXCL)
        ) == 0 else {
            throw posix("restore distribution symlink")
        }
        try hooks.reach(.afterRollbackBeforeSync)
        try SSOTDurability.syncDirectory(handle.descriptor)
        try hooks.reach(.afterRollbackSync)
        try verify(
            name: finalName,
            expectedIdentity: quarantined.evidence.entryIdentity,
            expectedTarget: quarantined.evidence.absoluteTarget,
            in: handle.descriptor
        )
        try verifyRoot(handle, components: components)
    }

    func removeCreated(
        _ entry: DistributionTargetEntry,
        expected: DistributionSymlinkEvidence
    ) throws {
        try unlink(
            name: entry.distributionSlug.value,
            scope: entry.target.scope,
            expected: expected
        )
    }

    func cleanup(
        _ entry: DistributionTargetEntry,
        quarantined: DistributionQuarantinedSymlink
    ) throws {
        try unlink(
            name: quarantined.temporaryName,
            scope: entry.target.scope,
            expected: quarantined.evidence
        )
    }

    private func unlink(
        name: String,
        scope: DistributionBindingScope,
        expected: DistributionSymlinkEvidence
    ) throws {
        let components = try components(for: scope)
        let handle = try openDirectory(components: components, createMissing: false)
        defer { Darwin.close(handle.descriptor) }
        guard handle.identity == expected.rootIdentity else {
            throw DistributionSymlinkFileSystemError.entryChanged
        }
        try verify(
            name: name,
            expectedIdentity: expected.entryIdentity,
            expectedTarget: expected.absoluteTarget,
            in: handle.descriptor
        )
        try hooks.reach(.beforeCleanup)
        guard Darwin.unlinkat(handle.descriptor, name, 0) == 0 else {
            throw posix("remove distribution symlink")
        }
        try hooks.reach(.afterCleanupBeforeSync)
        try SSOTDurability.syncDirectory(handle.descriptor)
        try hooks.reach(.afterCleanupSync)
        guard try identityIfPresent(name, in: handle.descriptor) == nil else {
            throw DistributionSymlinkFileSystemError.entryChanged
        }
        try verifyRoot(handle, components: components)
    }

    private struct DirectoryHandle {
        let descriptor: Int32
        let identity: ManagedItemIdentity
    }

    private enum RootAvailability {
        case missing
        case unavailable
    }

    private func classifyUnavailableRoot(
        _ components: [String]
    ) throws -> RootAvailability {
        var current = try openHome()
        defer { Darwin.close(current) }
        for component in components {
            var metadata = stat()
            guard Darwin.fstatat(current, component, &metadata, AT_SYMLINK_NOFOLLOW) == 0 else {
                return errno == ENOENT ? .missing : .unavailable
            }
            guard metadata.st_mode & mode_t(S_IFMT) == mode_t(S_IFDIR),
                  metadata.st_uid == Darwin.geteuid() else {
                return .unavailable
            }
            let next = Darwin.openat(
                current,
                component,
                O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC
            )
            guard next >= 0 else { return .unavailable }
            Darwin.close(current)
            current = next
        }
        return .unavailable
    }

    private func openDirectory(
        components: [String],
        createMissing: Bool
    ) throws -> DirectoryHandle {
        var current = try openHome()
        do {
            for component in components {
                var metadata = stat()
                if Darwin.fstatat(current, component, &metadata, AT_SYMLINK_NOFOLLOW) != 0 {
                    guard errno == ENOENT, createMissing else {
                        throw DistributionSymlinkFileSystemError.unavailable
                    }
                    try hooks.reach(.beforeRootCreate)
                    if Darwin.mkdirat(current, component, mode_t(0o700)) != 0,
                       errno != EEXIST {
                        throw posix("create distribution directory")
                    }
                    try hooks.reach(.afterRootCreateBeforeSync)
                    try SSOTDurability.syncDirectory(current)
                    try hooks.reach(.afterRootSync)
                }

                let next = Darwin.openat(
                    current,
                    component,
                    O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC
                )
                guard next >= 0 else {
                    throw DistributionSymlinkFileSystemError.unavailable
                }
                var held = stat()
                var named = stat()
                guard Darwin.fstat(next, &held) == 0,
                      Darwin.fstatat(current, component, &named, AT_SYMLINK_NOFOLLOW) == 0,
                      held.st_mode & mode_t(S_IFMT) == mode_t(S_IFDIR),
                      held.st_uid == Darwin.geteuid(),
                      ManagedItemIdentity(held) == ManagedItemIdentity(named) else {
                    Darwin.close(next)
                    throw DistributionSymlinkFileSystemError.unavailable
                }
                Darwin.close(current)
                current = next
            }
            var metadata = stat()
            guard Darwin.fstat(current, &metadata) == 0 else {
                throw posix("inspect distribution root")
            }
            return DirectoryHandle(
                descriptor: current,
                identity: ManagedItemIdentity(metadata)
            )
        } catch {
            Darwin.close(current)
            throw error
        }
    }

    private func verifyRoot(_ handle: DirectoryHandle, components: [String]) throws {
        let reopened = try openDirectory(components: components, createMissing: false)
        defer { Darwin.close(reopened.descriptor) }
        guard reopened.identity == handle.identity else {
            throw DistributionSymlinkFileSystemError.entryChanged
        }
    }

    private func openHome() throws -> Int32 {
        let parent = Darwin.open(
            homeURL.deletingLastPathComponent().path,
            O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC
        )
        guard parent >= 0 else { throw posix("open home parent") }
        defer { Darwin.close(parent) }
        let descriptor = Darwin.openat(
            parent,
            homeURL.lastPathComponent,
            O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC
        )
        guard descriptor >= 0 else { throw posix("open home") }
        var held = stat()
        var named = stat()
        guard Darwin.fstat(descriptor, &held) == 0,
              Darwin.fstatat(
                parent,
                homeURL.lastPathComponent,
                &named,
                AT_SYMLINK_NOFOLLOW
              ) == 0,
              held.st_mode & mode_t(S_IFMT) == mode_t(S_IFDIR),
              held.st_uid == Darwin.geteuid(),
              ManagedItemIdentity(held) == ManagedItemIdentity(named) else {
            Darwin.close(descriptor)
            throw DistributionSymlinkFileSystemError.invalidTarget
        }
        return descriptor
    }

    private func components(for scope: DistributionBindingScope) throws -> [String] {
        let relativePath: String = switch scope {
        case .global:
            ".agents/skills"
        case .agent(let adapter):
            adapter.dedicatedDistributionRelativePath
        }
        let components = relativePath.split(separator: "/", omittingEmptySubsequences: false)
            .map(String.init)
        guard !components.isEmpty,
              components.allSatisfy({
                  !$0.isEmpty && $0 != "." && $0 != ".." && !$0.contains("\0")
              }) else {
            throw DistributionSymlinkFileSystemError.invalidTarget
        }
        return components
    }

    private func requireUniqueName(_ name: String, in descriptor: Int32) throws {
        let key = SkillContentPath.collisionKey(for: name)
        let matches = try directoryNames(descriptor).filter {
            !$0.hasPrefix(".skillsmanager-distribution-")
                && SkillContentPath.collisionKey(for: $0) == key
        }
        guard matches.isEmpty || matches == [name] else {
            throw DistributionSymlinkFileSystemError.equivalentSibling
        }
    }

    private func directoryNames(_ descriptor: Int32) throws -> [String] {
        let duplicate = Darwin.fcntl(descriptor, F_DUPFD_CLOEXEC, 0)
        guard duplicate >= 0 else { throw posix("duplicate distribution root") }
        guard let directory = Darwin.fdopendir(duplicate) else {
            let code = errno
            Darwin.close(duplicate)
            throw DistributionSymlinkFileSystemError.posix(
                operation: "enumerate distribution root",
                code: code
            )
        }
        defer { Darwin.closedir(directory) }
        var names: [String] = []
        errno = 0
        while let entry = Darwin.readdir(directory) {
            let name = withUnsafePointer(to: &entry.pointee.d_name) { pointer in
                pointer.withMemoryRebound(to: CChar.self, capacity: Int(MAXNAMLEN) + 1) {
                    String(cString: $0)
                }
            }
            if name != "." && name != ".." { names.append(name) }
            errno = 0
        }
        guard errno == 0 else { throw posix("enumerate distribution root") }
        return names
    }

    private func verify(
        name: String,
        expectedIdentity: ManagedItemIdentity,
        expectedTarget: String,
        in descriptor: Int32
    ) throws {
        var metadata = stat()
        guard Darwin.fstatat(descriptor, name, &metadata, AT_SYMLINK_NOFOLLOW) == 0,
              metadata.st_mode & mode_t(S_IFMT) == mode_t(S_IFLNK),
              ManagedItemIdentity(metadata) == expectedIdentity,
              try readLink(name, in: descriptor) == expectedTarget else {
            throw DistributionSymlinkFileSystemError.entryChanged
        }
    }

    private func requiredIdentity(
        _ name: String,
        in descriptor: Int32
    ) throws -> ManagedItemIdentity {
        guard let identity = try identityIfPresent(name, in: descriptor) else {
            throw DistributionSymlinkFileSystemError.entryChanged
        }
        return identity
    }

    private func identityIfPresent(
        _ name: String,
        in descriptor: Int32
    ) throws -> ManagedItemIdentity? {
        var metadata = stat()
        guard Darwin.fstatat(descriptor, name, &metadata, AT_SYMLINK_NOFOLLOW) == 0 else {
            if errno == ENOENT { return nil }
            throw posix("inspect distribution entry")
        }
        return ManagedItemIdentity(metadata)
    }

    private func readLink(_ name: String, in descriptor: Int32) throws -> String {
        var bytes = [UInt8](repeating: 0, count: Int(PATH_MAX) + 1)
        let count = Darwin.readlinkat(descriptor, name, &bytes, bytes.count - 1)
        guard count >= 0 else { throw posix("read distribution symlink") }
        guard count < bytes.count - 1 else {
            throw DistributionSymlinkFileSystemError.entryChanged
        }
        return String(decoding: bytes.prefix(Int(count)), as: UTF8.self)
    }

    private func temporaryName(operationID: UUID, actionIndex: Int) -> String {
        ".skillsmanager-distribution-\(operationID.uuidString.lowercased())-\(actionIndex)"
    }

    private func posix(_ operation: String) -> DistributionSymlinkFileSystemError {
        .posix(operation: operation, code: errno)
    }
}
