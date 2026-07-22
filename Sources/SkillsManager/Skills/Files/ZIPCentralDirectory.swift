import Darwin
import Foundation

nonisolated final class ZIPArchiveSnapshot {
    let handle: FileHandle
    let descriptorURL: URL

    init(
        copying archiveURL: URL,
        into rootDescriptor: Int32,
        maximumByteCount: UInt64,
        checkpoint: SkillCancellationCheckpoint,
        beforeSnapshotUnlink: (String) -> Void = { _ in }
    ) throws {
        let source = Darwin.open(archiveURL.path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
        guard source >= 0 else { throw SafeSkillArchiveError.invalidArchive }
        defer { Darwin.close(source) }
        var status = stat()
        guard Darwin.fstat(source, &status) == 0,
              status.st_mode & S_IFMT == S_IFREG,
              status.st_size >= 0 else { throw SafeSkillArchiveError.invalidArchive }
        guard UInt64(status.st_size) <= maximumByteCount else {
            throw SafeSkillArchiveError.archiveTooLarge
        }
        let descriptor = try Self.makeAnonymousFile(
            in: rootDescriptor,
            beforeUnlink: beforeSnapshotUnlink
        )
        do {
            try Self.copy(
                source: source,
                destination: descriptor,
                maximumByteCount: maximumByteCount,
                checkpoint: checkpoint
            )
            guard Darwin.lseek(descriptor, 0, SEEK_SET) == 0 else {
                throw zipSnapshotPOSIXError()
            }
        } catch {
            Darwin.close(descriptor)
            throw error
        }
        handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
        descriptorURL = URL(fileURLWithPath: "/dev/fd/\(descriptor)")
    }

    private static func makeAnonymousFile(
        in rootDescriptor: Int32,
        beforeUnlink: (String) -> Void
    ) throws -> Int32 {
        while true {
            let name = ".skillsmanager-tmp-archive-snapshot-\(UUID().uuidString.lowercased())"
            let descriptor = Darwin.openat(
                rootDescriptor, name,
                O_RDWR | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC,
                S_IRUSR | S_IWUSR
            )
            if descriptor < 0, errno == EEXIST { continue }
            guard descriptor >= 0 else { throw zipSnapshotPOSIXError() }
            var metadata = stat()
            guard Darwin.fstat(descriptor, &metadata) == 0 else {
                let code = errno
                Darwin.close(descriptor)
                throw POSIXError(POSIXErrorCode(rawValue: code) ?? .EIO)
            }
            let identity = ManagedItemIdentity(metadata)
            guard unlinkCreatedFileIfUnchanged(
                named: name,
                in: rootDescriptor,
                expectedIdentity: identity,
                beforeQuarantineUnlink: beforeUnlink
            ) else {
                Darwin.close(descriptor)
                throw POSIXError(.EIO)
            }
            return descriptor
        }
    }

    private static func copy(
        source: Int32,
        destination: Int32,
        maximumByteCount: UInt64,
        checkpoint: SkillCancellationCheckpoint
    ) throws {
        var copied: UInt64 = 0
        var buffer = [UInt8](repeating: 0, count: 64 * 1_024)
        while true {
            try checkpoint()
            let count = buffer.withUnsafeMutableBytes { Darwin.read(source, $0.baseAddress, $0.count) }
            if count < 0, errno == EINTR { continue }
            guard count >= 0 else { throw zipSnapshotPOSIXError() }
            if count == 0 { return }
            let (newCount, overflow) = copied.addingReportingOverflow(UInt64(count))
            guard !overflow, newCount <= maximumByteCount else {
                throw SafeSkillArchiveError.archiveTooLarge
            }
            try writeAll(buffer.prefix(count), to: destination, checkpoint: checkpoint)
            copied = newCount
        }
    }

    private static func writeAll(
        _ bytes: ArraySlice<UInt8>,
        to descriptor: Int32,
        checkpoint: SkillCancellationCheckpoint
    ) throws {
        try bytes.withUnsafeBytes { buffer in
            var offset = 0
            while offset < buffer.count {
                try checkpoint()
                let count = Darwin.write(
                    descriptor,
                    buffer.baseAddress!.advanced(by: offset),
                    buffer.count - offset
                )
                if count < 0, errno == EINTR { continue }
                guard count > 0 else { throw zipSnapshotPOSIXError() }
                offset += count
            }
        }
    }
}

private nonisolated func zipSnapshotPOSIXError() -> POSIXError {
    POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
}

nonisolated enum ZIPCentralDirectory {
    enum Kind { case file, directory, dosFileOrDirectory, symbolicLink }

    private struct EndRecord {
        let entryCount: UInt64
        let centralDirectorySize: UInt64
        let centralDirectoryOffset: UInt64
        let centralDirectoryEndLimit: UInt64
    }

    static func entryKinds(
        in handle: FileHandle,
        maximumEntryCount: Int,
        checkpoint: SkillCancellationCheckpoint
    ) throws -> [Kind] {
        let fileSize = try handle.seekToEnd()
        let record = try endRecord(in: handle, fileSize: fileSize)
        guard record.entryCount <= UInt64(max(0, maximumEntryCount)) else {
            throw SafeSkillArchiveError.tooManyEntries
        }
        let (directoryEnd, overflow) = record.centralDirectoryOffset.addingReportingOverflow(
            record.centralDirectorySize
        )
        guard !overflow, directoryEnd <= record.centralDirectoryEndLimit else {
            throw SafeSkillArchiveError.invalidArchive
        }

        try handle.seek(toOffset: record.centralDirectoryOffset)
        var result: [Kind] = []
        result.reserveCapacity(Int(record.entryCount))
        var consumed: UInt64 = 0
        for _ in 0..<record.entryCount {
            try checkpoint()
            let header = try readExactly(46, from: handle)
            guard header.uint32(at: 0) == 0x0201_4b50 else {
                throw SafeSkillArchiveError.invalidArchive
            }
            let variableSize = UInt64(header.uint16(at: 28))
                + UInt64(header.uint16(at: 30))
                + UInt64(header.uint16(at: 32))
            let entrySize = UInt64(header.count) + variableSize
            guard consumed + entrySize <= record.centralDirectorySize else {
                throw SafeSkillArchiveError.invalidArchive
            }
            result.append(try kind(
                versionMadeBy: header.uint16(at: 4),
                attributes: header.uint32(at: 38)
            ))
            consumed += entrySize
            try handle.seek(toOffset: record.centralDirectoryOffset + consumed)
        }
        guard consumed == record.centralDirectorySize else {
            throw SafeSkillArchiveError.invalidArchive
        }
        return result
    }

    private static func endRecord(in handle: FileHandle, fileSize: UInt64) throws -> EndRecord {
        let tailSize = min(fileSize, 65_557)
        try handle.seek(toOffset: fileSize - tailSize)
        let tail = try readExactly(Int(tailSize), from: handle)
        guard tail.count >= 22 else { throw SafeSkillArchiveError.invalidArchive }

        for offset in stride(from: tail.count - 22, through: 0, by: -1) {
            guard tail.uint32(at: offset) == 0x0605_4b50 else { continue }
            guard offset + 22 + Int(tail.uint16(at: offset + 20)) == tail.count else {
                throw SafeSkillArchiveError.invalidArchive
            }
            let absoluteOffset = fileSize - tailSize + UInt64(offset)
            return try endRecord(
                in: handle,
                classicRecord: tail.subdata(in: offset..<(offset + 22)),
                classicOffset: absoluteOffset,
                fileSize: fileSize
            )
        }
        throw SafeSkillArchiveError.invalidArchive
    }

    private static func endRecord(
        in handle: FileHandle,
        classicRecord: Data,
        classicOffset: UInt64,
        fileSize: UInt64
    ) throws -> EndRecord {
        let entriesOnDisk = classicRecord.uint16(at: 8)
        let entryCount = classicRecord.uint16(at: 10)
        let directorySize = classicRecord.uint32(at: 12)
        let directoryOffset = classicRecord.uint32(at: 16)
        guard classicRecord.uint16(at: 4) == 0,
              classicRecord.uint16(at: 6) == 0,
              entriesOnDisk == entryCount else {
            throw SafeSkillArchiveError.invalidArchive
        }
        guard entryCount == .max || directorySize == .max || directoryOffset == .max else {
            return EndRecord(
                entryCount: UInt64(entryCount),
                centralDirectorySize: UInt64(directorySize),
                centralDirectoryOffset: UInt64(directoryOffset),
                centralDirectoryEndLimit: classicOffset
            )
        }
        return try zip64EndRecord(
            in: handle,
            classicOffset: classicOffset,
            fileSize: fileSize
        )
    }

    private static func zip64EndRecord(
        in handle: FileHandle,
        classicOffset: UInt64,
        fileSize: UInt64
    ) throws -> EndRecord {
        let zip64TrailerSize = UInt64(20 + 56)
        guard classicOffset >= zip64TrailerSize else {
            throw SafeSkillArchiveError.invalidArchive
        }
        try handle.seek(toOffset: classicOffset - 20)
        let locator = try readExactly(20, from: handle)
        guard locator.uint32(at: 0) == 0x0706_4b50,
              locator.uint32(at: 4) == 0,
              locator.uint32(at: 16) == 1 else {
            throw SafeSkillArchiveError.invalidArchive
        }

        let zip64Offset = locator.uint64(at: 8)
        guard zip64Offset == classicOffset - zip64TrailerSize,
              zip64Offset <= fileSize,
              fileSize - zip64Offset >= 56 else {
            throw SafeSkillArchiveError.invalidArchive
        }
        try handle.seek(toOffset: zip64Offset)
        let record = try readExactly(56, from: handle)
        let recordSize = record.uint64(at: 4)
        let (recordBodyEnd, bodyOverflow) = zip64Offset.addingReportingOverflow(12)
        let (recordEnd, recordOverflow) = recordBodyEnd.addingReportingOverflow(recordSize)
        guard !bodyOverflow, !recordOverflow,
              recordEnd == classicOffset - 20,
              record.uint32(at: 0) == 0x0606_4b50,
              recordSize == 44,
              record.uint32(at: 16) == 0,
              record.uint32(at: 20) == 0,
              record.uint64(at: 24) == record.uint64(at: 32) else {
            throw SafeSkillArchiveError.invalidArchive
        }
        return EndRecord(
            entryCount: record.uint64(at: 32),
            centralDirectorySize: record.uint64(at: 40),
            centralDirectoryOffset: record.uint64(at: 48),
            centralDirectoryEndLimit: zip64Offset
        )
    }

    private static func kind(versionMadeBy: UInt16, attributes: UInt32) throws -> Kind {
        switch versionMadeBy >> 8 {
        case 0:
            guard attributes & 0x08 == 0 else { throw SafeSkillArchiveError.invalidArchive }
            return .dosFileOrDirectory
        case 3, 19:
            switch mode_t(attributes >> 16) & mode_t(S_IFMT) {
            case mode_t(S_IFREG): return .file
            case mode_t(S_IFDIR): return .directory
            case mode_t(S_IFLNK): return .symbolicLink
            default: throw SafeSkillArchiveError.invalidArchive
            }
        default:
            throw SafeSkillArchiveError.invalidArchive
        }
    }

    private static func readExactly(_ count: Int, from handle: FileHandle) throws -> Data {
        guard let data = try handle.read(upToCount: count), data.count == count else {
            throw SafeSkillArchiveError.invalidArchive
        }
        return data
    }
}

private extension Data {
    nonisolated func uint16(at offset: Int) -> UInt16 {
        withUnsafeBytes {
            UInt16(littleEndian: $0.loadUnaligned(fromByteOffset: offset, as: UInt16.self))
        }
    }

    nonisolated func uint32(at offset: Int) -> UInt32 {
        withUnsafeBytes {
            UInt32(littleEndian: $0.loadUnaligned(fromByteOffset: offset, as: UInt32.self))
        }
    }

    nonisolated func uint64(at offset: Int) -> UInt64 {
        withUnsafeBytes {
            UInt64(littleEndian: $0.loadUnaligned(fromByteOffset: offset, as: UInt64.self))
        }
    }
}
