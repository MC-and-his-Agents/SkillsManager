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

nonisolated struct PartialSkillInstallError: LocalizedError, Sendable {
    let installedStorageKeys: [String]
    let failedStorageKey: String
    let reason: String
    let cleanupDebts: [SafeSkillCleanupDebt]

    var errorDescription: String? {
        let completed = installedStorageKeys.joined(separator: ", ")
        let cleanup = cleanupDebts.isEmpty
            ? ""
            : " Cleanup is still needed at \(cleanupDebts.map(\.url.path).joined(separator: ", "))."
        return "Installed in \(completed), but failed in \(failedStorageKey): \(reason).\(cleanup)"
    }
}

nonisolated struct SkillInstallReport: Sendable {
    let installedStorageKeys: [String]
    let cleanupDebts: [SafeSkillCleanupDebt]

    var warningMessage: String? {
        guard !cleanupDebts.isEmpty else { return nil }
        let paths = cleanupDebts.map(\.url.path).joined(separator: ", ")
        return "The Skill was installed, but old temporary content still needs cleanup: \(paths)"
    }
}

actor SkillImportWorker {
    struct ImportCandidatePayload: Sendable {
        let rootURL: URL
        let skillFileURL: URL
        let skillName: String
        let markdown: String
        let temporaryRoot: TemporaryItemLease?
        let archiveURL: URL?
        let archiveIdentity: ManagedItemIdentity?
        let fingerprint: String
    }

    func validateFolder(_ folderURL: URL) throws -> ImportCandidatePayload {
        try Task.checkCancellation()
        let skillRoot = try SkillPackageLocator().locateSkillRoot(in: folderURL)
        return try makePayload(
            rootURL: skillRoot,
            temporaryRoot: nil,
            archiveURL: nil,
            archiveIdentity: nil,
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
                archiveURL: archiveLease.url,
                archiveIdentity: archiveLease.identity,
                checkpoint: { try Task.checkCancellation() }
            )
        } catch {
            removeTemporaryRoot(temporary.lease)
            throw error
        }
    }

    func importCandidate(
        _ candidate: ImportCandidatePayload,
        destinations: [SkillFileWorker.InstallDestination]
    ) throws -> SkillInstallReport {
        let stager = SafeSkillStager()
        var installedStorageKeys: [String] = []
        var cleanupDebts: [SafeSkillCleanupDebt] = []
        for destination in destinations {
            do {
                let result: SafeSkillInstallResult
                if let archiveURL = candidate.archiveURL {
                    guard let archiveIdentity = candidate.archiveIdentity else {
                        throw SkillImportValidationError.archiveRejected(
                            "The validated archive identity is unavailable."
                        )
                    }
                    result = try stager.installArchive(
                        archiveAt: archiveURL,
                        expectedArchiveIdentity: archiveIdentity,
                        expectedFingerprint: candidate.fingerprint,
                        destinationRoot: destination.rootURL,
                        preferredName: candidate.skillName,
                        conflictPolicy: .chooseUniqueName,
                        managedRoot: destination.managedRoot,
                        checkpoint: { try Task.checkCancellation() }
                    )
                } else {
                    result = try stager.install(
                        sourceRoot: candidate.rootURL,
                        expectedFingerprint: candidate.fingerprint,
                        destinationRoot: destination.rootURL,
                        preferredName: candidate.skillName,
                        conflictPolicy: .chooseUniqueName,
                        managedRoot: destination.managedRoot,
                        checkpoint: { try Task.checkCancellation() }
                    )
                }
                installedStorageKeys.append(destination.storageKey)
                cleanupDebts.append(contentsOf: result.cleanupDebts)
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
        return SkillInstallReport(
            installedStorageKeys: installedStorageKeys,
            cleanupDebts: cleanupDebts
        )
    }

    func cleanupTemporaryRoot(_ lease: TemporaryItemLease) {
        removeTemporaryRoot(lease)
    }

    private func makePayload(
        rootURL: URL,
        temporaryRoot: TemporaryItemLease?,
        archiveURL: URL?,
        archiveIdentity: ManagedItemIdentity?,
        checkpoint: SkillCancellationCheckpoint
    ) throws -> ImportCandidatePayload {
        do {
            let snapshot = try SkillContentSnapshot.capture(at: rootURL, checkpoint: checkpoint)
            return try makePayload(
                rootURL: rootURL,
                skillName: rootURL.lastPathComponent,
                snapshot: snapshot,
                temporaryRoot: temporaryRoot,
                archiveURL: archiveURL,
                archiveIdentity: archiveIdentity,
                checkpoint: checkpoint
            )
        } catch let error as SkillContentSnapshotError {
            throw SkillImportValidationError.contentRejected(error.localizedDescription)
        }
    }

    private func makePayload(
        package: AnchoredSkillPackage,
        temporaryRoot: TemporaryItemLease,
        archiveURL: URL,
        archiveIdentity: ManagedItemIdentity,
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
                skillName: package.skillName,
                snapshot: snapshot,
                temporaryRoot: temporaryRoot,
                archiveURL: archiveURL,
                archiveIdentity: archiveIdentity,
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
        temporaryRoot: TemporaryItemLease?,
        archiveURL: URL?,
        archiveIdentity: ManagedItemIdentity?,
        checkpoint: SkillCancellationCheckpoint
    ) throws -> ImportCandidatePayload {
        let skillFileURL = rootURL.appendingPathComponent("SKILL.md", isDirectory: false)
        return ImportCandidatePayload(
            rootURL: rootURL,
            skillFileURL: skillFileURL,
            skillName: skillName,
            markdown: try snapshot.readUTF8File(
                relativePath: "SKILL.md",
                checkpoint: checkpoint
            ),
            temporaryRoot: temporaryRoot,
            archiveURL: archiveURL,
            archiveIdentity: archiveIdentity,
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
