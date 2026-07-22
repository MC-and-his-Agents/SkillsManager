import Darwin
import Foundation

nonisolated extension ManagedPathGuard {
    func removeItem(at targetURL: URL) throws {
        guard let expected = try itemIdentity(at: targetURL) else {
            throw ManagedPathError.itemNotFound
        }
        try removeItem(at: targetURL, expectedIdentity: expected)
    }

    func removeItem(at targetURL: URL, expectedIdentity: ManagedItemIdentity) throws {
        try verifyRootIdentity()
        let name = try managedName(for: targetURL)
        try verifyRootIdentity()
        try removeNamedItem(name.value, from: rootDescriptor, expectedIdentity: expectedIdentity)
        try verifyRootIdentity()
    }

    private func removeNamedItem(
        _ name: String,
        from parentDescriptor: Int32,
        expectedIdentity: FileIdentity? = nil
    ) throws {
        try verifyRootIdentity()
        let initialStatus = try status(of: name, in: parentDescriptor)
        let initialIdentity = FileIdentity(initialStatus)
        guard expectedIdentity == nil || expectedIdentity == initialIdentity else {
            throw ManagedPathError.itemChanged
        }
        try hooks.beforeQuarantineMove(name)
        try verifyRootIdentity()
        let quarantine = try moveToQuarantine(name, in: parentDescriptor)
        let movedStatus: stat
        do {
            movedStatus = try status(of: quarantine, in: parentDescriptor)
        } catch {
            let recovery = restoreQuarantined(
                quarantine,
                to: name,
                in: parentDescriptor,
                expectedIdentity: initialIdentity
            )
            throw ManagedPathError.removalFailed(
                partiallyDeleted: false,
                recoveryPath: recovery.path,
                restored: recovery.restored,
                cause: error.localizedDescription
            )
        }
        guard FileIdentity(movedStatus) == initialIdentity else {
            let recovery = restoreQuarantined(
                quarantine,
                to: name,
                in: parentDescriptor,
                expectedIdentity: FileIdentity(movedStatus)
            )
            guard recovery.restored else {
                throw ManagedPathError.removalFailed(
                    partiallyDeleted: false,
                    recoveryPath: recovery.path,
                    restored: false,
                    cause: ManagedPathError.itemChanged.localizedDescription
                )
            }
            throw ManagedPathError.itemChanged
        }
        try hooks.afterQuarantineMove(name, quarantine)
        do {
            try removeQuarantinedItem(quarantine, status: movedStatus, in: parentDescriptor)
        } catch {
            let context = Self.removalFailureContext(error)
            let recovery = restoreQuarantined(
                quarantine,
                to: name,
                in: parentDescriptor,
                expectedIdentity: initialIdentity
            )
            throw ManagedPathError.removalFailed(
                partiallyDeleted: context.partiallyDeleted,
                recoveryPath: recovery.path,
                restored: recovery.restored,
                cause: context.cause
            )
        }
    }

    func removeQuarantinedItem(
        _ name: String,
        status: stat,
        in parentDescriptor: Int32
    ) throws {
        let expectedIdentity = FileIdentity(status)
        if Self.fileType(of: status) == S_IFDIR {
            let childDescriptor = Darwin.openat(
                parentDescriptor,
                name,
                O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC
            )
            guard childDescriptor >= 0 else {
                throw ManagedPathError.posix(operation: "open directory for removal", code: errno)
            }
            defer { Darwin.close(childDescriptor) }

            var openedStatus = stat()
            guard Darwin.fstat(childDescriptor, &openedStatus) == 0,
                  FileIdentity(openedStatus) == expectedIdentity else {
                throw ManagedPathError.itemChanged
            }
            let removedContents = try removeDirectoryContents(descriptor: childDescriptor)
            do {
                guard try identity(of: name, in: parentDescriptor) == expectedIdentity else {
                    throw ManagedPathError.itemChanged
                }
                guard Darwin.unlinkat(parentDescriptor, name, AT_REMOVEDIR) == 0 else {
                    throw ManagedPathError.posix(operation: "remove managed directory", code: errno)
                }
                do {
                    try verifyRootIdentity()
                } catch {
                    throw Self.removalFailure(error, additionallyPartiallyDeleted: true)
                }
            } catch {
                throw Self.removalFailure(error, additionallyPartiallyDeleted: removedContents)
            }
        } else {
            do {
                guard try identity(of: name, in: parentDescriptor) == expectedIdentity else {
                    throw ManagedPathError.itemChanged
                }
                guard Darwin.unlinkat(parentDescriptor, name, 0) == 0 else {
                    throw ManagedPathError.posix(operation: "remove managed item", code: errno)
                }
                do {
                    try verifyRootIdentity()
                } catch {
                    throw Self.removalFailure(error, additionallyPartiallyDeleted: true)
                }
            } catch {
                throw Self.removalFailure(error, additionallyPartiallyDeleted: false)
            }
        }
    }

    private func moveToQuarantine(_ name: String, in parentDescriptor: Int32) throws -> String {
        while true {
            let quarantine = ".skillsmanager-delete-\(UUID().uuidString.lowercased())"
            if Darwin.renameatx_np(
                parentDescriptor,
                name,
                parentDescriptor,
                quarantine,
                UInt32(RENAME_EXCL)
            ) == 0 {
                return quarantine
            }
            if errno == EEXIST { continue }
            if errno == ENOENT { throw ManagedPathError.itemChanged }
            throw ManagedPathError.posix(operation: "quarantine managed item", code: errno)
        }
    }

    private func restoreQuarantined(
        _ quarantine: String,
        to original: String,
        in parentDescriptor: Int32,
        expectedIdentity: FileIdentity
    ) -> (restored: Bool, path: String?) {
        let parentPath = Self.path(of: parentDescriptor)
        let quarantinePath = parentPath.map {
            URL(fileURLWithPath: $0).appendingPathComponent(quarantine).path
        }
        guard (try? identity(of: quarantine, in: parentDescriptor)) == expectedIdentity else {
            return (false, nil)
        }
        guard Darwin.renameatx_np(
            parentDescriptor,
            quarantine,
            parentDescriptor,
            original,
            UInt32(RENAME_EXCL)
        ) == 0 else {
            return (false, quarantinePath)
        }
        guard (try? identity(of: original, in: parentDescriptor)) == expectedIdentity else {
            return (false, nil)
        }
        let restoredPath = parentPath.map {
            URL(fileURLWithPath: $0).appendingPathComponent(original).path
        }
        return (true, restoredPath)
    }

    func status(of name: String, in parentDescriptor: Int32) throws -> stat {
        var itemStatus = stat()
        guard Darwin.fstatat(parentDescriptor, name, &itemStatus, AT_SYMLINK_NOFOLLOW) == 0 else {
            if errno == ENOENT { throw ManagedPathError.itemNotFound }
            throw ManagedPathError.posix(operation: "lstat managed item", code: errno)
        }
        return itemStatus
    }

    private func removeDirectoryContents(descriptor: Int32) throws -> Bool {
        let streamDescriptor = Darwin.dup(descriptor)
        guard streamDescriptor >= 0 else {
            throw ManagedPathError.posix(operation: "duplicate directory descriptor", code: errno)
        }
        guard let directory = Darwin.fdopendir(streamDescriptor) else {
            let code = errno
            Darwin.close(streamDescriptor)
            throw ManagedPathError.posix(operation: "enumerate directory", code: code)
        }
        defer { Darwin.closedir(directory) }

        var removedAny = false
        errno = 0
        while let entry = Darwin.readdir(directory) {
            let name = Self.name(of: entry)
            if name == "." || name == ".." { continue }
            do {
                try removeNamedItem(name, from: descriptor)
                removedAny = true
            } catch {
                throw Self.removalFailure(error, additionallyPartiallyDeleted: removedAny)
            }
            errno = 0
        }
        if errno != 0 {
            throw Self.removalFailure(
                ManagedPathError.posix(operation: "enumerate directory", code: errno),
                additionallyPartiallyDeleted: removedAny
            )
        }
        return removedAny
    }

    private static func removalFailure(
        _ error: Error,
        additionallyPartiallyDeleted: Bool
    ) -> ManagedPathError {
        let context = removalFailureContext(error)
        return .removalFailed(
            partiallyDeleted: context.partiallyDeleted || additionallyPartiallyDeleted,
            recoveryPath: nil,
            restored: false,
            cause: context.cause
        )
    }

    private static func removalFailureContext(
        _ error: Error
    ) -> (partiallyDeleted: Bool, cause: String) {
        if case let ManagedPathError.removalFailed(partiallyDeleted, _, _, cause) = error {
            return (partiallyDeleted, cause)
        }
        return (false, error.localizedDescription)
    }

    private static func name(of entry: UnsafeMutablePointer<dirent>) -> String {
        withUnsafePointer(to: &entry.pointee.d_name) { pointer in
            pointer.withMemoryRebound(to: CChar.self, capacity: Int(MAXNAMLEN) + 1) {
                String(cString: $0)
            }
        }
    }

    private static func path(of descriptor: Int32) -> String? {
        var buffer = [CChar](repeating: 0, count: Int(PATH_MAX))
        guard Darwin.fcntl(descriptor, F_GETPATH, &buffer) == 0 else { return nil }
        let end = buffer.firstIndex(of: 0) ?? buffer.endIndex
        return String(decoding: buffer[..<end].map { UInt8(bitPattern: $0) }, as: UTF8.self)
    }
}
