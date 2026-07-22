import Darwin
import Foundation

@discardableResult
nonisolated func unlinkCreatedFileIfUnchanged(
    named name: String,
    in parentDescriptor: Int32,
    expectedIdentity: ManagedItemIdentity,
    beforeUnlink: () -> Void = {},
    beforeRestore: (String) -> Void = { _ in },
    beforeQuarantineUnlink: (String) -> Void = { _ in }
) -> Bool {
    guard let quarantine = quarantineItem(named: name, in: parentDescriptor) else { return false }

    guard let movedIdentity = cleanupIdentity(of: quarantine, in: parentDescriptor) else { return false }
    guard movedIdentity == expectedIdentity else {
        beforeRestore(quarantine)
        restoreCleanupItem(
            quarantine,
            to: name,
            expectedIdentity: movedIdentity,
            in: parentDescriptor
        )
        return false
    }

    beforeUnlink()
    beforeQuarantineUnlink(quarantine)
    guard cleanupIdentity(of: quarantine, in: parentDescriptor) == expectedIdentity else {
        return false
    }
    guard Darwin.unlinkat(parentDescriptor, quarantine, 0) == 0 else {
        beforeRestore(quarantine)
        restoreCleanupItem(
            quarantine,
            to: name,
            expectedIdentity: expectedIdentity,
            in: parentDescriptor
        )
        return false
    }
    return true
}

private nonisolated func quarantineItem(named name: String, in parentDescriptor: Int32) -> String? {
    while true {
        let candidate = ".skillsmanager-cleanup-\(UUID().uuidString.lowercased())"
        if Darwin.renameatx_np(
            parentDescriptor,
            name,
            parentDescriptor,
            candidate,
            UInt32(RENAME_EXCL)
        ) == 0 {
            return candidate
        }
        if errno != EEXIST { return nil }
    }
}

private nonisolated func cleanupIdentity(
    of name: String,
    in parentDescriptor: Int32
) -> ManagedItemIdentity? {
    var metadata = stat()
    guard Darwin.fstatat(parentDescriptor, name, &metadata, AT_SYMLINK_NOFOLLOW) == 0 else {
        return nil
    }
    return ManagedItemIdentity(metadata)
}

private nonisolated func restoreCleanupItem(
    _ quarantine: String,
    to name: String,
    expectedIdentity: ManagedItemIdentity,
    in parentDescriptor: Int32
) {
    guard cleanupIdentity(of: quarantine, in: parentDescriptor) == expectedIdentity else { return }
    _ = Darwin.renameatx_np(
        parentDescriptor,
        quarantine,
        parentDescriptor,
        name,
        UInt32(RENAME_EXCL)
    )
}
