import Darwin
import Foundation

extension SkillContentSnapshot {
    nonisolated static func copyBytes(
        from sourceDescriptor: Int32,
        file: SkillContentFileEnumerator.DiscoveredFile,
        toParent parentDescriptor: Int32,
        destinationRoot rootDescriptor: Int32,
        name: String,
        limits: SkillContentLimits,
        totalByteCount: inout UInt64,
        checkpoint: SkillCancellationCheckpoint,
        failureCleanupAdmission: SkillCancellationCheckpoint?
    ) throws {
        let destinationDescriptor = Darwin.openat(
            parentDescriptor,
            name,
            O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC,
            S_IRUSR | S_IWUSR
        )
        guard destinationDescriptor >= 0 else {
            throw SkillContentSnapshotError.fileSystemFailure(path: file.relativePath, code: errno)
        }
        let initial: SSOTDestinationFileSnapshot
        do {
            initial = try destinationSnapshot(destinationDescriptor)
        } catch {
            Darwin.close(destinationDescriptor)
            throw SkillContentSnapshotError.fileChanged(path: file.relativePath)
        }
        var trusted = initial

        do {
            try transferBytes(
                from: sourceDescriptor,
                to: destinationDescriptor,
                file: file,
                limits: limits,
                fileByteCount: 0,
                totalByteCount: &totalByteCount,
                trusted: &trusted,
                checkpoint: checkpoint
            )
            guard Darwin.fchmod(destinationDescriptor, file.safePermissions) == 0 else {
                throw SkillContentSnapshotError.fileSystemFailure(path: file.relativePath, code: errno)
            }
            trusted = try destinationSnapshot(destinationDescriptor)
            Darwin.close(destinationDescriptor)
        } catch let operationError {
            cleanupFailedCopy(
                named: name,
                parentDescriptor: parentDescriptor,
                destinationDescriptor: destinationDescriptor,
                rootDescriptor: rootDescriptor,
                parentComponents: file.relativePath.split(separator: "/").dropLast().map(String.init),
                initialIdentity: initial.identity,
                trusted: trusted,
                admission: failureCleanupAdmission
            )
            Darwin.close(destinationDescriptor)
            throw operationError
        }
    }

    private nonisolated static func transferBytes(
        from sourceDescriptor: Int32,
        to destinationDescriptor: Int32,
        file: SkillContentFileEnumerator.DiscoveredFile,
        limits: SkillContentLimits,
        fileByteCount: UInt64,
        totalByteCount: inout UInt64,
        trusted: inout SSOTDestinationFileSnapshot,
        checkpoint: SkillCancellationCheckpoint
    ) throws {
        var fileByteCount = fileByteCount
        var buffer = [UInt8](repeating: 0, count: 64 * 1_024)
        while true {
            try destinationCheckpoint(checkpoint, descriptor: destinationDescriptor, trusted: &trusted)
            let count = buffer.withUnsafeMutableBytes {
                Darwin.read(sourceDescriptor, $0.baseAddress, $0.count)
            }
            if count < 0, errno == EINTR { continue }
            guard count >= 0 else {
                throw SkillContentSnapshotError.fileSystemFailure(path: file.relativePath, code: errno)
            }
            if count == 0 { break }
            try addCopiedBytes(
                UInt64(count), file: file, fileByteCount: &fileByteCount,
                totalByteCount: &totalByteCount, limits: limits
            )
            try writeAll(
                buffer.prefix(count), to: destinationDescriptor,
                trusted: &trusted, checkpoint: checkpoint
            )
        }
        guard fileByteCount == file.byteCount else {
            throw SkillContentSnapshotError.fileChanged(path: file.relativePath)
        }
    }

    private nonisolated static func destinationCheckpoint(
        _ checkpoint: SkillCancellationCheckpoint,
        descriptor: Int32,
        trusted: inout SSOTDestinationFileSnapshot
    ) throws {
        trusted = try destinationSnapshot(descriptor)
        try checkpoint()
        guard try destinationSnapshot(descriptor) == trusted else {
            throw SkillContentSnapshotError.fileChanged(path: "destination")
        }
    }

    private nonisolated static func cleanupFailedCopy(
        named name: String,
        parentDescriptor: Int32,
        destinationDescriptor: Int32,
        rootDescriptor: Int32,
        parentComponents: [String],
        initialIdentity: ManagedItemIdentity,
        trusted: SSOTDestinationFileSnapshot,
        admission: SkillCancellationCheckpoint?
    ) {
        guard let admission else {
            unlinkCreatedFileIfUnchanged(
                named: name,
                in: parentDescriptor,
                expectedIdentity: initialIdentity
            )
            return
        }
        _ = unlinkSSOTCreatedFileIfUnchanged(
            named: name,
            in: parentDescriptor,
            fileDescriptor: destinationDescriptor,
            rootDescriptor: rootDescriptor,
            parentComponents: parentComponents,
            expectedSnapshot: trusted,
            admission: admission
        )
    }

    private nonisolated static func addCopiedBytes(
        _ count: UInt64,
        file: SkillContentFileEnumerator.DiscoveredFile,
        fileByteCount: inout UInt64,
        totalByteCount: inout UInt64,
        limits: SkillContentLimits
    ) throws {
        let (newFileCount, fileOverflow) = fileByteCount.addingReportingOverflow(count)
        guard !fileOverflow, newFileCount <= limits.maximumFileByteCount,
              newFileCount <= file.byteCount else {
            throw SkillContentSnapshotError.fileChanged(path: file.relativePath)
        }
        let (newTotal, totalOverflow) = totalByteCount.addingReportingOverflow(count)
        guard !totalOverflow, newTotal <= limits.maximumTotalByteCount else {
            throw SkillContentSnapshotError.totalByteLimitExceeded(
                limit: limits.maximumTotalByteCount,
                actual: totalOverflow ? UInt64.max : newTotal
            )
        }
        fileByteCount = newFileCount
        totalByteCount = newTotal
    }

    private nonisolated static func writeAll(
        _ bytes: ArraySlice<UInt8>,
        to descriptor: Int32,
        trusted: inout SSOTDestinationFileSnapshot,
        checkpoint: SkillCancellationCheckpoint
    ) throws {
        try bytes.withUnsafeBytes { rawBuffer in
            var offset = 0
            while offset < rawBuffer.count {
                try destinationCheckpoint(checkpoint, descriptor: descriptor, trusted: &trusted)
                let count = Darwin.write(
                    descriptor,
                    rawBuffer.baseAddress!.advanced(by: offset),
                    rawBuffer.count - offset
                )
                if count < 0, errno == EINTR { continue }
                guard count > 0 else {
                    throw SkillContentSnapshotError.fileSystemFailure(path: "destination", code: errno)
                }
                offset += count
                trusted = try destinationSnapshot(descriptor)
            }
        }
    }
}
