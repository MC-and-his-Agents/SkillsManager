import Foundation

nonisolated enum SkillImportValidationError: LocalizedError {
    case archiveRejected(String)
    case contentRejected(String)

    var errorDescription: String? {
        switch self {
        case .archiveRejected(let reason):
            return "The zip archive is unsafe or invalid: \(reason)"
        case .contentRejected(let reason):
            return "The Skill contents are unsafe or invalid: \(reason)"
        }
    }
}

actor SkillImportWorker {
    struct ImportCandidatePayload: Sendable {
        enum SourceAnchor: Sendable {
            case registeredRoot(ManagedRootReference)
            case snapshot
        }

        let rootURL: URL
        let sourceAnchor: SourceAnchor
        let skillFileURL: URL
        let skillName: String
        let markdown: String
        let temporaryRoot: TemporaryItemLease?
        let snapshot: SkillContentSnapshot
        let fingerprint: String

        func requireSourceUnchanged() throws {
            switch sourceAnchor {
            case .registeredRoot(let rootReference):
                try snapshot.requireUnchanged(at: rootReference)
            case .snapshot:
                try snapshot.requireUnchanged()
            }
        }
    }

    func validateFolder(_ folderURL: URL) throws -> ImportCandidatePayload {
        try Task.checkCancellation()
        let skillRoot = try SkillPackageLocator().locateSkillRoot(in: folderURL)
        return try makePayload(
            rootURL: skillRoot,
            temporaryRoot: nil,
            checkpoint: { try Task.checkCancellation() }
        )
    }

    func validateZip(
        _ zipURL: URL,
        afterExtraction: @Sendable (TemporaryItemLease) throws -> Void = { _ in }
    ) throws -> ImportCandidatePayload {
        let archiveLease = try TemporaryItemLease.captureFile(at: zipURL)
        let temporary = try TemporaryItemLease.createDirectory(
            in: FileManager.default.temporaryDirectory,
            prefix: "skillsmanager-import-"
        )
        do {
            do {
                try SafeSkillArchive().extract(
                    archiveAt: archiveLease.url,
                    expectedArchiveIdentity: archiveLease.identity,
                    toDirectoryDescriptor: temporary.handle.descriptor,
                    checkpoint: { try Task.checkCancellation() }
                )
            } catch let error as SafeSkillArchiveError {
                throw SkillImportValidationError.archiveRejected(error.localizedDescription)
            }
            try afterExtraction(temporary.lease)
            let package = try AnchoredSkillPackageLocator.locate(
                in: temporary.handle.descriptor,
                displayPath: temporary.lease.url.path
            )
            return try makePayload(
                package: package,
                temporaryRoot: temporary.lease,
                checkpoint: { try Task.checkCancellation() }
            )
        } catch {
            removeTemporaryRoot(temporary.lease)
            throw error
        }
    }

    func validateZip(
        _ zipURL: URL,
        repositorySubpath: RepositorySubpath,
        expectedBlobs: [SafeSkillArchive.RepositoryBlobExpectation],
        afterExtraction: @Sendable (TemporaryItemLease) throws -> Void = { _ in }
    ) throws -> ImportCandidatePayload {
        let archiveLease = try TemporaryItemLease.captureFile(at: zipURL)
        let temporary = try TemporaryItemLease.createDirectory(
            in: FileManager.default.temporaryDirectory,
            prefix: "skillsmanager-import-"
        )
        do {
            do {
                try SafeSkillArchive().extractRepositorySubtree(
                    archiveAt: archiveLease.url,
                    expectedArchiveIdentity: archiveLease.identity,
                    repositorySubpath: repositorySubpath,
                    expectedBlobs: expectedBlobs,
                    toDirectoryDescriptor: temporary.handle.descriptor,
                    checkpoint: { try Task.checkCancellation() }
                )
            } catch let error as SafeSkillArchiveError {
                throw SkillImportValidationError.archiveRejected(error.localizedDescription)
            }
            try afterExtraction(temporary.lease)
            let package = try AnchoredSkillPackageLocator.locate(
                in: temporary.handle.descriptor,
                displayPath: temporary.lease.url.path
            )
            let skillName = repositorySubpath.value.split(separator: "/").last.map(String.init)
            return try makePayload(
                package: package,
                skillName: skillName,
                temporaryRoot: temporary.lease,
                checkpoint: { try Task.checkCancellation() }
            )
        } catch {
            removeTemporaryRoot(temporary.lease)
            throw error
        }
    }

    func cleanupTemporaryRoot(_ lease: TemporaryItemLease) {
        removeTemporaryRoot(lease)
    }

    func cleanupTemporaryRoot(
        _ lease: TemporaryItemLease?,
        afterCancelling consumer: Task<Void, Never>?
    ) async {
        consumer?.cancel()
        await consumer?.value
        if let lease {
            removeTemporaryRoot(lease)
        }
    }

    private func makePayload(
        rootURL: URL,
        temporaryRoot: TemporaryItemLease?,
        checkpoint: SkillCancellationCheckpoint
    ) throws -> ImportCandidatePayload {
        do {
            let snapshot = try SkillContentSnapshot.capture(at: rootURL, checkpoint: checkpoint)
            return try makePayload(
                rootURL: rootURL,
                skillName: rootURL.lastPathComponent,
                snapshot: snapshot,
                sourceAnchor: .registeredRoot(try ManagedRootReference.capture(at: rootURL)),
                temporaryRoot: temporaryRoot,
                checkpoint: checkpoint
            )
        } catch let error as SkillContentSnapshotError {
            throw SkillImportValidationError.contentRejected(error.localizedDescription)
        }
    }

    private func makePayload(
        package: AnchoredSkillPackage,
        skillName: String? = nil,
        temporaryRoot: TemporaryItemLease,
        checkpoint: SkillCancellationCheckpoint
    ) throws -> ImportCandidatePayload {
        do {
            let snapshot = try SkillContentSnapshot.capture(
                directoryDescriptor: package.descriptor,
                displayPath: package.displayPath,
                checkpoint: checkpoint
            )
            return try makePayload(
                rootURL: package.rootURL,
                skillName: skillName ?? package.skillName,
                snapshot: snapshot,
                sourceAnchor: .snapshot,
                temporaryRoot: temporaryRoot,
                checkpoint: checkpoint
            )
        } catch let error as SkillContentSnapshotError {
            throw SkillImportValidationError.contentRejected(error.localizedDescription)
        }
    }

    private func makePayload(
        rootURL: URL,
        skillName: String,
        snapshot: SkillContentSnapshot,
        sourceAnchor: ImportCandidatePayload.SourceAnchor,
        temporaryRoot: TemporaryItemLease?,
        checkpoint: SkillCancellationCheckpoint
    ) throws -> ImportCandidatePayload {
        let skillFileURL = rootURL.appendingPathComponent("SKILL.md", isDirectory: false)
        return ImportCandidatePayload(
            rootURL: rootURL,
            sourceAnchor: sourceAnchor,
            skillFileURL: skillFileURL,
            skillName: skillName,
            markdown: try snapshot.readUTF8File(
                relativePath: "SKILL.md",
                checkpoint: checkpoint
            ),
            temporaryRoot: temporaryRoot,
            snapshot: snapshot,
            fingerprint: snapshot.fingerprint
        )
    }

    private nonisolated func removeTemporaryRoot(_ lease: TemporaryItemLease) {
        do {
            try lease.removeIfCurrent()
        } catch {
            NSLog("Skills Manager preserved an unverified import directory at %@: %@", lease.url.path, error.localizedDescription)
        }
    }
}
