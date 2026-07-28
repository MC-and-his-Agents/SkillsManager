import CryptoKit
import Darwin
import Foundation

nonisolated struct CopyPhysicalTreeSnapshot: Sendable {
    let digest: CopyPhysicalTreeDigest
    let rootPermissions: mode_t

    static func captureSource(
        _ snapshot: SkillContentSnapshot,
        limits: SkillContentLimits = .default,
        checkpoint: SkillCancellationCheckpoint = {}
    ) throws -> Self {
        _ = try SkillContentFileEnumerator(
            limits: limits,
            policy: .copyTarget
        ).files(in: snapshot.sourceTree, checkpoint: checkpoint)
        return try capture(
            sourceTree: snapshot.sourceTree,
            policy: .copySource,
            limits: limits,
            checkpoint: checkpoint
        )
    }

    static func captureTarget(
        directoryDescriptor: Int32,
        displayPath: String,
        limits: SkillContentLimits = .default,
        checkpoint: SkillCancellationCheckpoint = {}
    ) throws -> Self {
        try capture(
            sourceTree: SafeSourceTree(
                directoryDescriptor: directoryDescriptor,
                displayPath: displayPath
            ),
            policy: .copyTarget,
            limits: limits,
            checkpoint: checkpoint
        )
    }

    private static func capture(
        sourceTree: SafeSourceTree,
        policy: SkillContentFileEnumerator.TraversalPolicy,
        limits: SkillContentLimits,
        checkpoint: SkillCancellationCheckpoint
    ) throws -> Self {
        try checkpoint()
        let root = try sourceTree.duplicateRoot()
        defer { Darwin.close(root) }
        var rootMetadata = stat()
        guard Darwin.fstat(root, &rootMetadata) == 0 else {
            throw SkillContentSnapshotError.fileSystemFailure(path: ".", code: errno)
        }
        let rootPermissions = permissions(rootMetadata)
        let discovery = try SkillContentFileEnumerator(
            limits: limits,
            policy: policy
        ).files(in: sourceTree, checkpoint: checkpoint)

        var hasher = SHA256()
        hasher.update(data: Data("SkillsManager.CopyPhysicalTree".utf8))
        updateInteger(&hasher, UInt32(CopyPhysicalTreeDigest.algorithmVersion))
        update(&hasher, kind: 0, path: "", permissions: rootPermissions)
        for directory in discovery.directories.sorted(by: {
            $0.relativePath.utf8.lexicographicallyPrecedes($1.relativePath.utf8)
        }) {
            try checkpoint()
            update(
                &hasher,
                kind: 1,
                path: directory.relativePath,
                permissions: directory.safePermissions
            )
        }
        for file in discovery.files {
            try checkpoint()
            update(
                &hasher,
                kind: 2,
                path: file.relativePath,
                permissions: file.safePermissions
            )
        }
        try discovery.sourceTree.verifyDirectories(
            discovery.directories,
            checkpoint: checkpoint
        )
        return try Self(
            digest: CopyPhysicalTreeDigest(digest: Data(hasher.finalize())),
            rootPermissions: rootPermissions
        )
    }

    private static func update(
        _ hasher: inout SHA256,
        kind: UInt8,
        path: String,
        permissions: mode_t
    ) {
        let pathBytes = Data(path.utf8)
        hasher.update(data: Data([kind]))
        updateInteger(&hasher, UInt64(pathBytes.count))
        hasher.update(data: pathBytes)
        updateInteger(&hasher, UInt32(permissions))
    }

    private static func updateInteger<T: FixedWidthInteger>(
        _ hasher: inout SHA256,
        _ value: T
    ) {
        var bytes = value.bigEndian
        withUnsafeBytes(of: &bytes) { hasher.update(bufferPointer: $0) }
    }

    private static func permissions(_ metadata: stat) -> mode_t {
        metadata.st_mode & mode_t(S_IRWXU | S_IRWXG | S_IRWXO)
    }
}
