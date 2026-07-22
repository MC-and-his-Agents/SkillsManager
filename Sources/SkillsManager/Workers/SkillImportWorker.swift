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

    var errorDescription: String? {
        let completed = installedStorageKeys.joined(separator: ", ")
        return "Installed in \(completed), but failed in \(failedStorageKey): \(reason)"
    }
}

actor SkillImportWorker {
    struct ImportCandidatePayload: Sendable {
        let rootURL: URL
        let skillFileURL: URL
        let skillName: String
        let markdown: String
        let temporaryRoot: URL?
        let archiveURL: URL?
        let fingerprint: String
    }

    func validateFolder(_ folderURL: URL) throws -> ImportCandidatePayload {
        try Task.checkCancellation()
        let skillRoot = try SkillPackageLocator().locateSkillRoot(in: folderURL)
        return try makePayload(
            rootURL: skillRoot,
            temporaryRoot: nil,
            archiveURL: nil,
            checkpoint: { try Task.checkCancellation() }
        )
    }

    func validateZip(_ zipURL: URL) throws -> ImportCandidatePayload {
        let temporaryRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("skillsmanager-import-\(UUID().uuidString)", isDirectory: true)
        do {
            try FileManager.default.createDirectory(at: temporaryRoot, withIntermediateDirectories: true)
            do {
                try SafeSkillArchive().extract(
                    archiveAt: zipURL,
                    to: temporaryRoot,
                    checkpoint: { try Task.checkCancellation() }
                )
            } catch let error as SafeSkillArchiveError {
                throw SkillImportValidationError.archiveRejected(error.localizedDescription)
            }
            let skillRoot = try SkillPackageLocator().locateSkillRoot(in: temporaryRoot)
            return try makePayload(
                rootURL: skillRoot,
                temporaryRoot: temporaryRoot,
                archiveURL: zipURL,
                checkpoint: { try Task.checkCancellation() }
            )
        } catch {
            try? FileManager.default.removeItem(at: temporaryRoot)
            throw error
        }
    }

    func importCandidate(
        _ candidate: ImportCandidatePayload,
        destinations: [SkillFileWorker.InstallDestination]
    ) throws {
        let stager = SafeSkillStager()
        var installedStorageKeys: [String] = []
        for destination in destinations {
            do {
                if let archiveURL = candidate.archiveURL {
                    _ = try stager.installArchive(
                        archiveAt: archiveURL,
                        expectedFingerprint: candidate.fingerprint,
                        destinationRoot: destination.rootURL,
                        preferredName: candidate.skillName,
                        conflictPolicy: .chooseUniqueName,
                        managedRoot: destination.managedRoot,
                        checkpoint: { try Task.checkCancellation() }
                    )
                } else {
                    _ = try stager.install(
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
            } catch {
                guard !installedStorageKeys.isEmpty else { throw error }
                throw PartialSkillInstallError(
                    installedStorageKeys: installedStorageKeys,
                    failedStorageKey: destination.storageKey,
                    reason: error.localizedDescription
                )
            }
        }
    }

    func cleanupTemporaryRoot(_ url: URL) {
        try? FileManager.default.removeItem(at: url)
    }

    private func makePayload(
        rootURL: URL,
        temporaryRoot: URL?,
        archiveURL: URL?,
        checkpoint: SkillCancellationCheckpoint
    ) throws -> ImportCandidatePayload {
        let snapshot: SkillContentSnapshot
        do {
            snapshot = try SkillContentSnapshot.capture(at: rootURL, checkpoint: checkpoint)
        } catch let error as SkillContentSnapshotError {
            throw SkillImportValidationError.contentRejected(error.localizedDescription)
        }

        let skillFileURL = rootURL.appendingPathComponent("SKILL.md", isDirectory: false)
        return ImportCandidatePayload(
            rootURL: rootURL,
            skillFileURL: skillFileURL,
            skillName: rootURL.lastPathComponent,
            markdown: try String(contentsOf: skillFileURL, encoding: .utf8),
            temporaryRoot: temporaryRoot,
            archiveURL: archiveURL,
            fingerprint: snapshot.fingerprint
        )
    }
}
