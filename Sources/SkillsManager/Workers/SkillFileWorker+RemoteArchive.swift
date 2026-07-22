import Darwin
import Foundation

extension SkillFileWorker {
    func loadRawMarkdown(
        from archive: DownloadedSkillArchive,
        beforeManifestRead: @Sendable () throws -> Void = {}
    ) throws -> String {
        defer { Self.removeDownloadedArchive(archive) }
        return try loadRawMarkdown(
            from: archive.url,
            expectedArchiveIdentity: archive.expectedIdentity,
            beforeManifestRead: beforeManifestRead
        )
    }

    func loadRawMarkdown(from zipURL: URL) throws -> String {
        try loadRawMarkdown(
            from: zipURL,
            expectedArchiveIdentity: nil,
            beforeManifestRead: {}
        )
    }

    private func loadRawMarkdown(
        from zipURL: URL,
        expectedArchiveIdentity: ManagedItemIdentity?,
        beforeManifestRead: @Sendable () throws -> Void
    ) throws -> String {
        let temporary = try TemporaryItemLease.createDirectory(
            in: FileManager.default.temporaryDirectory,
            prefix: "skillsmanager-preview-"
        )
        defer { Self.removeTemporaryItem(temporary.lease) }

        do {
            try SafeSkillArchive().extract(
                archiveAt: zipURL,
                expectedArchiveIdentity: expectedArchiveIdentity,
                toDirectoryDescriptor: temporary.handle.descriptor,
                checkpoint: { try Task.checkCancellation() }
            )
        } catch let error as SafeSkillArchiveError {
            throw SkillImportValidationError.archiveRejected(error.localizedDescription)
        }
        let package = try AnchoredSkillPackageLocator.locate(
            in: temporary.handle.descriptor,
            displayPath: temporary.lease.url.path
        )
        do {
            let snapshot = try SkillContentSnapshot.capture(
                directoryDescriptor: package.descriptor,
                displayPath: package.displayPath,
                checkpoint: { try Task.checkCancellation() }
            )
            try beforeManifestRead()
            return try snapshot.readUTF8File(
                relativePath: "SKILL.md",
                checkpoint: { try Task.checkCancellation() }
            )
        } catch let error as SkillContentSnapshotError {
            throw SkillImportValidationError.contentRejected(error.localizedDescription)
        }
    }

    func installRemoteSkill(
        archive: DownloadedSkillArchive,
        slug: String,
        version: String?,
        destinations: [InstallDestination],
        beforeDestinationInstall: @Sendable (Int, InstallDestination) throws -> Void = { _, _ in }
    ) throws -> RemoteInstallResult {
        defer { Self.removeDownloadedArchive(archive) }
        return try installRemoteSkill(
            zipURL: archive.url,
            expectedArchiveIdentity: archive.expectedIdentity,
            slug: slug,
            version: version,
            destinations: destinations,
            beforeDestinationInstall: beforeDestinationInstall
        )
    }

    func installRemoteSkill(
        zipURL: URL,
        slug: String,
        version: String?,
        destinations: [InstallDestination]
    ) throws -> RemoteInstallResult {
        try installRemoteSkill(
            zipURL: zipURL,
            expectedArchiveIdentity: nil,
            slug: slug,
            version: version,
            destinations: destinations,
            beforeDestinationInstall: { _, _ in }
        )
    }

    private func installRemoteSkill(
        zipURL: URL,
        expectedArchiveIdentity: ManagedItemIdentity?,
        slug: String,
        version: String?,
        destinations: [InstallDestination],
        beforeDestinationInstall: @Sendable (Int, InstallDestination) throws -> Void
    ) throws -> RemoteInstallResult {
        let temporary = try TemporaryItemLease.createDirectory(
            in: FileManager.default.temporaryDirectory,
            prefix: "skillsmanager-remote-"
        )
        defer { Self.removeTemporaryItem(temporary.lease) }

        do {
            try SafeSkillArchive().extract(
                archiveAt: zipURL,
                expectedArchiveIdentity: expectedArchiveIdentity,
                toDirectoryDescriptor: temporary.handle.descriptor,
                checkpoint: { try Task.checkCancellation() }
            )
        } catch let error as SafeSkillArchiveError {
            throw SkillImportValidationError.archiveRejected(error.localizedDescription)
        }
        let package = try AnchoredSkillPackageLocator.locate(
            in: temporary.handle.descriptor,
            displayPath: temporary.lease.url.path
        )
        let snapshot: SkillContentSnapshot
        do {
            snapshot = try SkillContentSnapshot.capture(
                directoryDescriptor: package.descriptor,
                displayPath: package.displayPath,
                checkpoint: { try Task.checkCancellation() }
            )
        } catch let error as SkillContentSnapshotError {
            throw SkillImportValidationError.contentRejected(error.localizedDescription)
        }
        return try installRemoteSnapshot(
            snapshot,
            archiveURL: zipURL,
            expectedArchiveIdentity: expectedArchiveIdentity,
            slug: slug,
            version: version,
            destinations: destinations,
            beforeDestinationInstall: beforeDestinationInstall
        )
    }

    private func installRemoteSnapshot(
        _ snapshot: SkillContentSnapshot,
        archiveURL: URL,
        expectedArchiveIdentity: ManagedItemIdentity?,
        slug: String,
        version: String?,
        destinations: [InstallDestination],
        beforeDestinationInstall: @Sendable (Int, InstallDestination) throws -> Void
    ) throws -> RemoteInstallResult {
        let stager = SafeSkillStager()
        var installedStorageKeys: [String] = []
        var cleanupDebts: [SafeSkillCleanupDebt] = []
        var selectedID: String?
        for (index, destination) in destinations.enumerated() {
            do {
                try beforeDestinationInstall(index, destination)
                let result = try stager.installArchive(
                    archiveAt: archiveURL,
                    expectedArchiveIdentity: expectedArchiveIdentity,
                    expectedFingerprint: snapshot.fingerprint,
                    destinationRoot: destination.rootURL,
                    preferredName: slug,
                    conflictPolicy: .replaceExisting,
                    managedRoot: destination.managedRoot,
                    checkpoint: { try Task.checkCancellation() }
                ) { stagedDescriptor in
                    try Self.writeClawdhubOrigin(
                        in: stagedDescriptor,
                        slug: slug,
                        version: version
                    )
                }
                installedStorageKeys.append(destination.storageKey)
                cleanupDebts.append(contentsOf: result.cleanupDebts)
                if selectedID == nil {
                    selectedID = "\(destination.storageKey)-\(result.installedURL.lastPathComponent)"
                }
            } catch {
                guard !installedStorageKeys.isEmpty else { throw error }
                throw PartialSkillInstallError(
                    installedStorageKeys: installedStorageKeys,
                    failedStorageKey: destination.storageKey,
                    reason: error.localizedDescription,
                    cleanupDebts: cleanupDebts
                )
            }
        }

        return RemoteInstallResult(
            selectedID: selectedID,
            report: SkillInstallReport(
                installedStorageKeys: installedStorageKeys,
                cleanupDebts: cleanupDebts
            )
        )
    }

    nonisolated static func writeClawdhubOrigin(
        in skillRootDescriptor: Int32,
        slug: String,
        version: String?
    ) throws {
        if Darwin.mkdirat(skillRootDescriptor, ".clawdhub", S_IRWXU) != 0, errno != EEXIST {
            throw remoteWorkerPOSIXError()
        }
        let originDirectory = Darwin.openat(
            skillRootDescriptor,
            ".clawdhub",
            O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC
        )
        guard originDirectory >= 0 else { throw remoteWorkerPOSIXError() }
        defer { Darwin.close(originDirectory) }
        var originStatus = stat()
        guard Darwin.fstat(originDirectory, &originStatus) == 0 else {
            throw remoteWorkerPOSIXError()
        }
        let originIdentity = ManagedItemIdentity(originStatus)
        let payload: [String: Any] = [
            "slug": slug,
            "version": version ?? "latest",
            "source": "clawdhub",
            "installedAt": Int(Date().timeIntervalSince1970)
        ]
        let data = try JSONSerialization.data(withJSONObject: payload, options: [.prettyPrinted])
        let temporaryName = ".skillsmanager-tmp-origin-\(UUID().uuidString.lowercased())"
        let descriptor = Darwin.openat(
            originDirectory,
            temporaryName,
            O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC,
            S_IRUSR | S_IWUSR
        )
        guard descriptor >= 0 else { throw remoteWorkerPOSIXError() }
        var temporaryStatus = stat()
        guard Darwin.fstat(descriptor, &temporaryStatus) == 0 else {
            Darwin.close(descriptor)
            throw remoteWorkerPOSIXError()
        }
        let temporaryIdentity = ManagedItemIdentity(temporaryStatus)
        var published = false
        defer {
            Darwin.close(descriptor)
            if !published {
                unlinkCreatedFileIfUnchanged(
                    named: temporaryName,
                    in: originDirectory,
                    expectedIdentity: temporaryIdentity
                )
            }
        }
        try writeAll(data, to: descriptor)
        guard Darwin.renameatx_np(
            originDirectory,
            temporaryName,
            originDirectory,
            "origin.json",
            UInt32(RENAME_EXCL)
        ) == 0 else { throw remoteWorkerPOSIXError() }
        published = true
        var finalOriginStatus = stat()
        guard Darwin.fstatat(
            skillRootDescriptor,
            ".clawdhub",
            &finalOriginStatus,
            AT_SYMLINK_NOFOLLOW
        ) == 0,
            ManagedItemIdentity(finalOriginStatus) == originIdentity else {
            throw ManagedPathError.itemChanged
        }
    }

    private nonisolated static func removeTemporaryItem(_ lease: TemporaryItemLease) {
        do {
            try lease.removeIfCurrent()
        } catch {
            NSLog(
                "Skills Manager preserved an unverified temporary item at %@: %@",
                lease.url.path,
                error.localizedDescription
            )
        }
    }

    private nonisolated static func removeDownloadedArchive(_ archive: DownloadedSkillArchive) {
        do {
            try archive.removeIfOwned()
        } catch {
            NSLog(
                "Skills Manager preserved an unverified downloaded archive at %@: %@",
                archive.url.path,
                error.localizedDescription
            )
        }
    }

    private nonisolated static func writeAll(_ data: Data, to descriptor: Int32) throws {
        try data.withUnsafeBytes { bytes in
            var offset = 0
            while offset < bytes.count {
                let count = Darwin.write(
                    descriptor,
                    bytes.baseAddress!.advanced(by: offset),
                    bytes.count - offset
                )
                if count < 0, errno == EINTR { continue }
                guard count > 0 else { throw remoteWorkerPOSIXError() }
                offset += count
            }
        }
    }
}

private nonisolated func remoteWorkerPOSIXError() -> POSIXError {
    POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
}
