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
}
