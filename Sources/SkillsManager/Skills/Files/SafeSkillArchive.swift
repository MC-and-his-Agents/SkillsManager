import Darwin
import Foundation
import ZIPFoundation
nonisolated struct SafeSkillArchive {
    struct Limits: Sendable {
        let maximumEntryCount: Int
        let maximumArchiveByteCount: UInt64
        let content: SkillContentLimits
        init(
            maximumEntryCount: Int = 50_000,
            maximumFileCount: Int = SkillContentLimits.default.maximumFileCount,
            maximumTotalSize: UInt64 = SkillContentLimits.default.maximumTotalByteCount,
            maximumFileSize: UInt64 = SkillContentLimits.default.maximumFileByteCount,
            maximumDirectoryCount: Int = SkillContentLimits.default.maximumDirectoryCount,
            maximumPathDepth: Int = SkillContentLimits.default.maximumPathDepth,
            maximumArchiveSize: UInt64? = nil
        ) {
            self.maximumEntryCount = maximumEntryCount
            let (derivedArchiveSize, overflow) = maximumTotalSize.addingReportingOverflow(64 * 1_024 * 1_024)
            maximumArchiveByteCount = maximumArchiveSize ?? (overflow ? .max : derivedArchiveSize)
            content = SkillContentLimits(
                maximumFileCount: maximumFileCount,
                maximumTotalByteCount: maximumTotalSize,
                maximumFileByteCount: maximumFileSize,
                maximumDirectoryCount: maximumDirectoryCount,
                maximumPathDepth: maximumPathDepth
            )
        }
    }
    private enum EntryKind { case file, directory }
    private struct ValidatedEntry {
        let entry: Entry
        let components: [String]
        let kind: EntryKind
    }
    let limits: Limits
    init(limits: Limits = Limits()) {
        self.limits = limits
    }
    @discardableResult
    func extract(
        archiveAt archiveURL: URL,
        to emptyDestinationURL: URL,
        checkpoint: SkillCancellationCheckpoint = {},
        afterPreflight: () throws -> Void = {},
        beforeEntry: ([String]) throws -> Void = { _ in }
    ) throws -> [String] {
        let rootDescriptor = try openEmptyDestination(emptyDestinationURL)
        defer { Darwin.close(rootDescriptor) }
        return try extract(
            archiveAt: archiveURL,
            toRootDescriptor: rootDescriptor,
            checkpoint: checkpoint,
            afterPreflight: afterPreflight,
            beforeEntry: beforeEntry
        )
    }

    @discardableResult
    func extract(
        archiveAt archiveURL: URL,
        toDirectoryDescriptor destinationDescriptor: Int32,
        checkpoint: SkillCancellationCheckpoint = {},
        afterPreflight: () throws -> Void = {},
        beforeEntry: ([String]) throws -> Void = { _ in }
    ) throws -> [String] {
        let rootDescriptor = try duplicateEmptyDestination(destinationDescriptor)
        defer { Darwin.close(rootDescriptor) }
        return try extract(
            archiveAt: archiveURL,
            toRootDescriptor: rootDescriptor,
            checkpoint: checkpoint,
            afterPreflight: afterPreflight,
            beforeEntry: beforeEntry
        )
    }

    private func extract(
        archiveAt archiveURL: URL,
        toRootDescriptor rootDescriptor: Int32,
        checkpoint: SkillCancellationCheckpoint,
        afterPreflight: () throws -> Void,
        beforeEntry: ([String]) throws -> Void
    ) throws -> [String] {
        do {
            let snapshot = try ZIPArchiveSnapshot(
                copying: archiveURL,
                into: rootDescriptor,
                maximumByteCount: limits.maximumArchiveByteCount,
                checkpoint: checkpoint
            )
            let rawKinds = try ZIPCentralDirectory.entryKinds(
                in: snapshot.handle,
                maximumEntryCount: limits.maximumEntryCount,
                checkpoint: checkpoint
            )
            try afterPreflight()
            let archive = try Archive(url: snapshot.descriptorURL, accessMode: .read)
            let entries = Array(archive)
            let validatedEntries = try validate(
                entries: entries,
                rawKinds: rawKinds,
                checkpoint: checkpoint
            )
            try extract(
                validatedEntries,
                from: archive,
                rootDescriptor: rootDescriptor,
                checkpoint: checkpoint,
                beforeEntry: beforeEntry
            )
            return validatedEntries.map { $0.components.joined(separator: "/") }
        } catch {
            try? removeContents(of: rootDescriptor)
            throw error
        }
    }

    private func duplicateEmptyDestination(_ descriptor: Int32) throws -> Int32 {
        var status = stat()
        guard Darwin.fstat(descriptor, &status) == 0,
              status.st_mode & S_IFMT == S_IFDIR else {
            throw SafeSkillArchiveError.invalidDestination
        }
        let duplicate = Darwin.dup(descriptor)
        guard duplicate >= 0 else { throw SafeSkillArchiveError.invalidDestination }
        do {
            guard try directoryNames(in: duplicate).isEmpty else {
                throw SafeSkillArchiveError.destinationNotEmpty
            }
            return duplicate
        } catch {
            Darwin.close(duplicate)
            throw error
        }
    }

    private func openEmptyDestination(_ url: URL) throws -> Int32 {
        var pathStatus = stat()
        guard Darwin.lstat(url.path, &pathStatus) == 0, pathStatus.st_mode & S_IFMT == S_IFDIR else {
            throw SafeSkillArchiveError.invalidDestination
        }
        let descriptor = Darwin.open(url.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard descriptor >= 0 else { throw SafeSkillArchiveError.invalidDestination }
        var descriptorStatus = stat()
        guard Darwin.fstat(descriptor, &descriptorStatus) == 0,
              descriptorStatus.st_mode & S_IFMT == S_IFDIR,
              descriptorStatus.st_dev == pathStatus.st_dev,
              descriptorStatus.st_ino == pathStatus.st_ino else {
            Darwin.close(descriptor)
            throw SafeSkillArchiveError.invalidDestination
        }
        guard try directoryNames(in: descriptor).isEmpty else {
            Darwin.close(descriptor)
            throw SafeSkillArchiveError.destinationNotEmpty
        }
        return descriptor
    }
    private func validate(
        entries: [Entry],
        rawKinds: [ZIPCentralDirectory.Kind],
        checkpoint: SkillCancellationCheckpoint
    ) throws -> [ValidatedEntry] {
        guard entries.count == rawKinds.count else { throw SafeSkillArchiveError.invalidArchive }
        guard entries.count <= limits.maximumEntryCount else { throw SafeSkillArchiveError.tooManyEntries }
        var fileCount = 0, totalSize: UInt64 = 0
        var directoryKeys: Set<String> = []
        var paths: [String: (path: String, kind: EntryKind)] = [:]
        var prefixSpellings: [String: (spelling: String, path: String)] = [:]
        var result: [ValidatedEntry] = []
        for (entry, rawKind) in zip(entries, rawKinds) {
            try checkpoint()
            let kind = try validatedKind(rawKind, entry: entry)
            let components = try validatedComponents(for: entry.path, kind: kind)
            let normalized = components.map(SkillContentPath.normalizedComponent)
            let keys = normalized.map(SkillContentPath.collisionKey(for:))
            let key = keys.joined(separator: "/")
            guard components.count <= limits.content.maximumPathDepth else {
                throw SafeSkillArchiveError.pathTooDeep(entry.path)
            }
            if let existing = paths[key] {
                throw SafeSkillArchiveError.pathCollision(existing.path, entry.path)
            }
            for end in normalized.indices {
                let prefixKey = keys[...end].joined(separator: "/")
                let spelling = normalized[...end].joined(separator: "/")
                if let existing = prefixSpellings[prefixKey], existing.spelling != spelling {
                    throw SafeSkillArchiveError.pathCollision(existing.path, entry.path)
                }
                prefixSpellings[prefixKey] = (spelling, entry.path)
            }
            paths[key] = (entry.path, kind)
            let directoryDepth = kind == .directory ? keys.count : keys.count - 1
            if directoryDepth > 0 {
                for end in 1...directoryDepth {
                    directoryKeys.insert(keys[..<end].joined(separator: "/"))
                }
            }
            guard directoryKeys.count <= limits.content.maximumDirectoryCount else {
                throw SafeSkillArchiveError.tooManyDirectories
            }
            try addSize(of: entry, kind: kind, fileCount: &fileCount, total: &totalSize)
            result.append(ValidatedEntry(entry: entry, components: components, kind: kind))
        }
        try validateParentKinds(in: paths)
        return result
    }
    private func validatedKind(_ rawKind: ZIPCentralDirectory.Kind, entry: Entry) throws -> EntryKind {
        switch rawKind {
        case .file where entry.type == .file, .dosFileOrDirectory where entry.type == .file:
            // ZIP has no portable hard-link marker; entries presented as regular files are indistinguishable.
            return .file
        case .directory where entry.type == .directory, .dosFileOrDirectory where entry.type == .directory:
            return .directory
        case .symbolicLink:
            throw SafeSkillArchiveError.unsupportedEntryType(entry.path)
        default:
            throw SafeSkillArchiveError.invalidArchive
        }
    }
    private func validatedComponents(for path: String, kind: EntryKind) throws -> [String] {
        guard !path.isEmpty, !path.contains("\\"), !path.contains("\0"), !(path as NSString).isAbsolutePath,
              !Self.isWindowsAbsolutePath(path) else { throw SafeSkillArchiveError.unsafePath(path) }
        let trimmed = kind == .directory && path.hasSuffix("/") ? String(path.dropLast()) : path
        let components = trimmed.split(separator: "/", omittingEmptySubsequences: false).map(String.init)
        guard !components.isEmpty, components.allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." }) else {
            throw SafeSkillArchiveError.unsafePath(path)
        }
        return components
    }
    private static func isWindowsAbsolutePath(_ path: String) -> Bool {
        guard path.count >= 3 else { return false }
        let characters = Array(path.prefix(3))
        return characters[0].isASCII && characters[0].isLetter && characters[1] == ":" && characters[2] == "/"
    }
    private func addSize(
        of entry: Entry,
        kind: EntryKind,
        fileCount: inout Int,
        total: inout UInt64
    ) throws {
        guard kind == .file else { return }
        fileCount += 1
        guard fileCount <= limits.content.maximumFileCount else { throw SafeSkillArchiveError.tooManyFiles }
        guard entry.uncompressedSize <= limits.content.maximumFileByteCount else {
            throw SafeSkillArchiveError.fileTooLarge(entry.path)
        }
        let (newTotal, overflow) = total.addingReportingOverflow(entry.uncompressedSize)
        guard !overflow, newTotal <= limits.content.maximumTotalByteCount else {
            throw SafeSkillArchiveError.archiveTooLarge
        }
        total = newTotal
    }
    private func validateParentKinds(in paths: [String: (path: String, kind: EntryKind)]) throws {
        for (key, value) in paths {
            let components = key.split(separator: "/")
            for end in 1..<components.count {
                if let parent = paths[components[..<end].joined(separator: "/")], parent.kind == .file {
                    throw SafeSkillArchiveError.pathCollision(parent.path, value.path)
                }
            }
        }
    }
    private func extract(
        _ entries: [ValidatedEntry],
        from archive: Archive,
        rootDescriptor: Int32,
        checkpoint: SkillCancellationCheckpoint,
        beforeEntry: ([String]) throws -> Void
    ) throws {
        var actualTotalSize: UInt64 = 0
        var directories: [ValidatedEntry] = []
        for item in entries {
            try checkpoint()
            try beforeEntry(item.components)
            switch item.kind {
            case .directory:
                let descriptor = try openDirectory(
                    item.components,
                    from: rootDescriptor,
                    create: true
                )
                Darwin.close(descriptor)
                directories.append(item)
            case .file:
                try extractFile(
                    item,
                    from: archive,
                    rootDescriptor: rootDescriptor,
                    actualTotalSize: &actualTotalSize,
                    checkpoint: checkpoint
                )
            }
        }
        for item in directories.reversed() {
            try checkpoint()
            let descriptor = try openDirectory(item.components, from: rootDescriptor, create: false)
            defer { Darwin.close(descriptor) }
            try applySafeAttributes(of: item.entry, to: descriptor, minimumPermissions: S_IRWXU)
        }
    }
    private func extractFile(
        _ item: ValidatedEntry,
        from archive: Archive,
        rootDescriptor: Int32,
        actualTotalSize: inout UInt64,
        checkpoint: SkillCancellationCheckpoint
    ) throws {
        var parentComponents = item.components
        let name = parentComponents.removeLast()
        let parent = try openDirectory(parentComponents, from: rootDescriptor, create: true)
        defer { Darwin.close(parent) }
        let descriptor = Darwin.openat(
            parent,
            name,
            O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC,
            S_IRUSR | S_IWUSR
        )
        guard descriptor >= 0 else { throw archivePOSIXError() }
        var destinationMetadata = stat()
        guard Darwin.fstat(descriptor, &destinationMetadata) == 0 else {
            let code = errno
            Darwin.close(descriptor)
            throw POSIXError(POSIXErrorCode(rawValue: code) ?? .EIO)
        }
        let destinationIdentity = ManagedItemIdentity(destinationMetadata)
        var completed = false
        defer {
            Darwin.close(descriptor)
            if !completed {
                unlinkCreatedFileIfUnchanged(
                    named: name,
                    in: parent,
                    expectedIdentity: destinationIdentity
                )
            }
        }
        var fileSize: UInt64 = 0
        let checksum = try archive.extract(item.entry) { data in
            try checkpoint()
            try addExtractedBytes(
                UInt64(data.count),
                path: item.entry.path,
                fileSize: &fileSize,
                totalSize: &actualTotalSize
            )
            try Self.writeAll(data, to: descriptor, checkpoint: checkpoint)
        }
        guard checksum == item.entry.checksum else {
            throw SafeSkillArchiveError.invalidChecksum(item.entry.path)
        }
        guard fileSize == item.entry.uncompressedSize else {
            throw SafeSkillArchiveError.invalidSize(item.entry.path)
        }
        try applySafeAttributes(of: item.entry, to: descriptor)
        completed = true
    }
    private func addExtractedBytes(
        _ count: UInt64,
        path: String,
        fileSize: inout UInt64,
        totalSize: inout UInt64
    ) throws {
        let (newFileSize, fileOverflow) = fileSize.addingReportingOverflow(count)
        guard !fileOverflow, newFileSize <= limits.content.maximumFileByteCount else {
            throw SafeSkillArchiveError.fileTooLarge(path)
        }
        let (newTotalSize, totalOverflow) = totalSize.addingReportingOverflow(count)
        guard !totalOverflow, newTotalSize <= limits.content.maximumTotalByteCount else {
            throw SafeSkillArchiveError.archiveTooLarge
        }
        fileSize = newFileSize
        totalSize = newTotalSize
    }
    private static func writeAll(
        _ data: Data,
        to descriptor: Int32,
        checkpoint: SkillCancellationCheckpoint
    ) throws {
        try data.withUnsafeBytes { bytes in
            var written = 0
            while written < bytes.count {
                try checkpoint()
                let count = Darwin.write(descriptor, bytes.baseAddress!.advanced(by: written), bytes.count - written)
                if count < 0, errno == EINTR { continue }
                guard count > 0 else { throw archivePOSIXError() }
                written += count
            }
        }
    }
    private func openDirectory(_ components: [String], from root: Int32, create: Bool) throws -> Int32 {
        var current = Darwin.dup(root)
        guard current >= 0 else { throw archivePOSIXError() }
        do {
            for component in components {
                if create, Darwin.mkdirat(current, component, S_IRWXU) != 0, errno != EEXIST {
                    throw archivePOSIXError()
                }
                let next = Darwin.openat(current, component, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
                guard next >= 0 else { throw archivePOSIXError() }
                Darwin.close(current)
                current = next
            }
            return current
        } catch {
            Darwin.close(current)
            throw error
        }
    }
    private func applySafeAttributes(
        of entry: Entry,
        to descriptor: Int32,
        minimumPermissions: mode_t = 0
    ) throws {
        if let rawMode = entry.fileAttributes[.posixPermissions] as? NSNumber {
            let permissions = (mode_t(rawMode.uint16Value) & 0o777) | minimumPermissions
            guard Darwin.fchmod(descriptor, permissions) == 0 else {
                throw archivePOSIXError()
            }
        }
        if let date = entry.fileAttributes[.modificationDate] as? Date {
            var times = [Darwin.timespec(tv_sec: 0, tv_nsec: Int(UTIME_OMIT)), Self.makeTimespec(for: date)]
            guard Darwin.futimens(descriptor, &times) == 0 else { throw archivePOSIXError() }
        }
    }
    private static func makeTimespec(for date: Date) -> Darwin.timespec {
        let seconds = floor(date.timeIntervalSince1970)
        return Darwin.timespec(
            tv_sec: Int(seconds),
            tv_nsec: Int((date.timeIntervalSince1970 - seconds) * 1_000_000_000)
        )
    }
    private func removeContents(of descriptor: Int32) throws {
        for name in try directoryNames(in: descriptor) {
            var status = stat()
            guard Darwin.fstatat(descriptor, name, &status, AT_SYMLINK_NOFOLLOW) == 0 else {
                if errno == ENOENT { continue }
                throw archivePOSIXError()
            }
            if status.st_mode & S_IFMT == S_IFDIR {
                let child = Darwin.openat(descriptor, name, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
                guard child >= 0 else { throw archivePOSIXError() }
                do {
                    try removeContents(of: child)
                    Darwin.close(child)
                } catch {
                    Darwin.close(child)
                    throw error
                }
                guard Darwin.unlinkat(descriptor, name, AT_REMOVEDIR) == 0 else { throw archivePOSIXError() }
            } else if Darwin.unlinkat(descriptor, name, 0) != 0, errno != ENOENT {
                throw archivePOSIXError()
            }
        }
    }
    private func directoryNames(in descriptor: Int32) throws -> [String] {
        let duplicate = Darwin.dup(descriptor)
        guard duplicate >= 0 else { throw archivePOSIXError() }
        guard let directory = Darwin.fdopendir(duplicate) else {
            Darwin.close(duplicate)
            throw archivePOSIXError()
        }
        defer { Darwin.closedir(directory) }
        var names: [String] = []
        Darwin.rewinddir(directory)
        errno = 0
        while let item = Darwin.readdir(directory) {
            let name = withUnsafePointer(to: &item.pointee.d_name) {
                $0.withMemoryRebound(to: CChar.self, capacity: Int(MAXNAMLEN) + 1) { String(cString: $0) }
            }
            if name != "." && name != ".." { names.append(name) }
            errno = 0
        }
        guard errno == 0 else { throw archivePOSIXError() }
        return names
    }
}

private nonisolated func archivePOSIXError() -> POSIXError {
    POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
}
