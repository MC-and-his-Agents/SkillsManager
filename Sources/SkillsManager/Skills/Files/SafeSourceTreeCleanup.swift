import Darwin
import Foundation

@discardableResult
nonisolated func unlinkCreatedFileIfUnchanged(
    named name: String,
    in parentDescriptor: Int32,
    expectedIdentity: ManagedItemIdentity,
    beforeUnlink: () -> Void = {},
    beforeRestore: (String) -> Void = { _ in }
) -> Bool {
    let quarantine: String
    while true {
        let candidate = ".skillsmanager-cleanup-\(UUID().uuidString.lowercased())"
        if Darwin.renameatx_np(
            parentDescriptor,
            name,
            parentDescriptor,
            candidate,
            UInt32(RENAME_EXCL)
        ) == 0 {
            quarantine = candidate
            break
        }
        if errno != EEXIST { return false }
    }

    var movedMetadata = stat()
    guard Darwin.fstatat(
        parentDescriptor,
        quarantine,
        &movedMetadata,
        AT_SYMLINK_NOFOLLOW
    ) == 0 else {
        return false
    }
    let movedIdentity = ManagedItemIdentity(movedMetadata)
    guard movedIdentity == expectedIdentity else {
        beforeRestore(quarantine)
        var recoveryMetadata = stat()
        guard Darwin.fstatat(
            parentDescriptor,
            quarantine,
            &recoveryMetadata,
            AT_SYMLINK_NOFOLLOW
        ) == 0,
            ManagedItemIdentity(recoveryMetadata) == movedIdentity else {
            return false
        }
        _ = Darwin.renameatx_np(
            parentDescriptor,
            quarantine,
            parentDescriptor,
            name,
            UInt32(RENAME_EXCL)
        )
        return false
    }

    beforeUnlink()
    return Darwin.unlinkat(parentDescriptor, quarantine, 0) == 0
}
