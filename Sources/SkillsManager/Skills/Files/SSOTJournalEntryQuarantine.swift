import Darwin
import Foundation

/// Moves one journal-owned entry to a unique operation-scoped sibling before deletion so
/// a same-name replacement can be identified and preserved.
nonisolated struct SSOTJournalEntryQuarantine {
    typealias FileSnapshot = SSOTJournalDeletionManifest.RegularFileSnapshot

    private let originalName: String
    private let quarantineName: String
    private let parentDescriptor: Int32

    static func move(
        named name: String,
        in parentDescriptor: Int32,
        operationScope: String
    ) throws -> Self {
        while true {
            let quarantine = ".skillsmanager-cleanup-\(operationScope)-"
                + UUID().uuidString.lowercased()
            if Darwin.renameatx_np(
                parentDescriptor,
                name,
                parentDescriptor,
                quarantine,
                UInt32(RENAME_EXCL)
            ) == 0 {
                return Self(
                    originalName: name,
                    quarantineName: quarantine,
                    parentDescriptor: parentDescriptor
                )
            }
            let code = errno
            guard code == EEXIST else {
                throw failure("quarantine journal-owned operation entry", code: code)
            }
        }
    }

    func requireExpected(
        heldDescriptor: Int32,
        identity: ManagedItemIdentity,
        fileSnapshot: FileSnapshot?
    ) throws {
        let held = try metadata(descriptor: heldDescriptor)
        let moved = try metadata(named: quarantineName)
        guard ManagedItemIdentity(held) == identity,
              ManagedItemIdentity(moved) == identity else {
            throw ManagedPathError.itemChanged
        }
        if let fileSnapshot {
            guard matchesStableFileMetadata(held, expected: fileSnapshot),
                  matchesStableFileMetadata(moved, expected: fileSnapshot) else {
                throw ManagedPathError.itemChanged
            }
        }
    }

    func remove(flags: Int32) throws {
        guard Darwin.unlinkat(parentDescriptor, quarantineName, flags) == 0 else {
            throw Self.failure(
                "remove quarantined journal-owned operation entry",
                code: errno
            )
        }
        var metadata = stat()
        if Darwin.fstatat(
            parentDescriptor,
            quarantineName,
            &metadata,
            AT_SYMLINK_NOFOLLOW
        ) == 0 || errno != ENOENT {
            throw ManagedPathError.itemChanged
        }
    }

    func restore() {
        _ = Darwin.renameatx_np(
            parentDescriptor,
            quarantineName,
            parentDescriptor,
            originalName,
            UInt32(RENAME_EXCL)
        )
    }

    private func metadata(descriptor: Int32) throws -> stat {
        var value = stat()
        guard Darwin.fstat(descriptor, &value) == 0 else {
            throw ManagedPathError.itemChanged
        }
        return value
    }

    private func metadata(named name: String) throws -> stat {
        var value = stat()
        guard Darwin.fstatat(parentDescriptor, name, &value, AT_SYMLINK_NOFOLLOW) == 0 else {
            throw ManagedPathError.itemChanged
        }
        return value
    }

    private func matchesStableFileMetadata(_ value: stat, expected: FileSnapshot) -> Bool {
        value.st_mode & mode_t(S_IFMT) == mode_t(S_IFREG)
            && value.st_size == expected.size
            && value.st_mtimespec.tv_sec == expected.modificationSeconds
            && value.st_mtimespec.tv_nsec == expected.modificationNanoseconds
    }

    private static func failure(_ operation: String, code: Int32) -> ManagedPathError {
        switch code {
        case ENOENT, ENOTDIR, EISDIR, ELOOP, ENOTEMPTY, EEXIST:
            .itemChanged
        default:
            .posix(operation: operation, code: code)
        }
    }
}
