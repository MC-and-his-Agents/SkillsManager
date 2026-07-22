import Darwin
import Foundation

/// Binds cleanup of a temporary item to the exact parent root and item identity
/// observed when the application took ownership of it.
nonisolated struct TemporaryItemLease: Sendable {
    let url: URL
    let parentRoot: ManagedRootReference
    let identity: ManagedItemIdentity

    static func createDirectory(
        in parentURL: URL,
        prefix: String
    ) throws -> (lease: TemporaryItemLease, handle: ManagedDirectoryHandle) {
        let parentRoot = try ManagedRootReference.capture(at: parentURL)
        let verifiedParent = try parentRoot.verifiedRoot()
        let guardrail = try ManagedPathGuard(rootURL: verifiedParent.url)
        try guardrail.verifyRootIdentity(expected: verifiedParent.identity)
        let url = verifiedParent.url.appendingPathComponent(
            "\(prefix)\(UUID().uuidString.lowercased())",
            isDirectory: true
        )
        let handle = try guardrail.createDirectory(at: url)
        return (
            TemporaryItemLease(
                url: url,
                parentRoot: parentRoot,
                identity: handle.identity
            ),
            handle
        )
    }

    static func captureFile(at fileURL: URL) throws -> TemporaryItemLease {
        let parentRoot = try ManagedRootReference.capture(
            at: fileURL.standardizedFileURL.deletingLastPathComponent()
        )
        let verifiedParent = try parentRoot.verifiedRoot()
        let guardrail = try ManagedPathGuard(rootURL: verifiedParent.url)
        try guardrail.verifyRootIdentity(expected: verifiedParent.identity)
        let verifiedURL = verifiedParent.url.appendingPathComponent(fileURL.lastPathComponent)
        guard let identity = try guardrail.itemIdentity(at: verifiedURL) else {
            throw ManagedPathError.itemNotFound
        }
        try guardrail.withItemDescriptor(at: verifiedURL, expectedIdentity: identity) { descriptor in
            var metadata = stat()
            guard Darwin.fstat(descriptor, &metadata) == 0 else {
                throw ManagedPathError.posix(operation: "inspect temporary file", code: errno)
            }
            guard ManagedPathGuard.fileType(of: metadata) == S_IFREG else {
                throw ManagedPathError.unsupportedItemType
            }
        }
        return TemporaryItemLease(
            url: verifiedURL,
            parentRoot: parentRoot,
            identity: identity
        )
    }

    func removeIfCurrent() throws {
        let verifiedParent = try parentRoot.verifiedRoot()
        let guardrail = try ManagedPathGuard(rootURL: verifiedParent.url)
        try guardrail.verifyRootIdentity(expected: verifiedParent.identity)
        do {
            try guardrail.removeItem(at: url, expectedIdentity: identity)
        } catch ManagedPathError.itemNotFound {
            return
        }
    }
}
