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
    private struct ArchiveCandidatePath {
        let rawComponents: [String]
        let canonicalComponents: [String]
        let collisionKey: String
    }

    struct ArchiveCandidateID: Hashable, Sendable {
        let archiveSessionID: UUID
        let canonicalSubpathCollisionKey: String
    }

    struct ArchiveCandidate: Sendable, Identifiable {
        let id: ArchiveCandidateID
        let canonicalSubpath: String
        let displayName: String
        let slug: DefaultDistributionSlug?
        let payload: ImportCandidatePayload?
        let blockedReason: String?

        var isImportable: Bool {
            payload != nil && blockedReason == nil
        }

        func blocked(reason: String) -> Self {
            Self(
                id: id,
                canonicalSubpath: canonicalSubpath,
                displayName: displayName,
                slug: slug,
                payload: nil,
                blockedReason: reason
            )
        }
    }

    struct ArchiveSession: Sendable {
        let id: UUID
        let temporaryRoot: TemporaryItemLease
        let candidates: [ArchiveCandidate]

        var importableCandidates: [ArchiveCandidate] {
            candidates.filter(\.isImportable)
        }

        func requireCurrent() throws {
            try temporaryRoot.verifyCurrent()
        }
    }

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

    /// Captures and validates one immutable ZIP snapshot, then evaluates every
    /// directly-contained SKILL.md as an independent candidate on one shared
    /// temporary lease. The lease is owned by the returned session, not by an
    /// individual payload.
    func validateZipSession(_ zipURL: URL) throws -> ArchiveSession {
        let archiveLease = try TemporaryItemLease.captureFile(at: zipURL)
        let temporary = try TemporaryItemLease.createDirectory(
            in: FileManager.default.temporaryDirectory,
            prefix: "skillsmanager-import-"
        )
        let sessionID = UUID()
        do {
            var candidatePaths: [ArchiveCandidatePath] = []
            do {
                try SafeSkillArchive().extract(
                    archiveAt: archiveLease.url,
                    expectedArchiveIdentity: archiveLease.identity,
                    toDirectoryDescriptor: temporary.handle.descriptor,
                    checkpoint: { try Task.checkCancellation() },
                    afterValidation: { entries in
                        candidatePaths = Self.archiveCandidatePaths(from: entries)
                        guard !candidatePaths.isEmpty else {
                            throw SafeSkillArchiveError.invalidArchive
                        }
                    }
                )
            } catch let error as SafeSkillArchiveError {
                throw SkillImportValidationError.archiveRejected(error.localizedDescription)
            }

            guard !candidatePaths.isEmpty else {
                throw SkillImportValidationError.archiveRejected(
                    "The archive does not contain a Skill manifest."
                )
            }
            var candidates = candidatePaths.map { path in
                makeArchiveCandidateMetadata(
                    path: path,
                    sessionID: sessionID,
                    archiveURL: archiveLease.url
                )
            }
            markArchiveCandidateConflicts(&candidates)
            let rawComponentsByKey = Dictionary(
                uniqueKeysWithValues: candidatePaths.map { ($0.collisionKey, $0.rawComponents) }
            )

            for index in candidates.indices where candidates[index].blockedReason == nil {
                do {
                    guard let components = rawComponentsByKey[
                        candidates[index].id.canonicalSubpathCollisionKey
                    ] else {
                        throw SkillImportValidationError.contentRejected(
                            "The Skill candidate path is no longer available."
                        )
                    }
                    let package = try AnchoredSkillPackageLocator.locate(
                        in: temporary.handle.descriptor,
                        components: components,
                        displayPath: temporary.lease.url.path
                    )
                    let payload = try makePayload(
                        package: package,
                        skillName: candidates[index].displayName,
                        temporaryRoot: nil,
                        checkpoint: { try Task.checkCancellation() }
                    )
                    candidates[index] = ArchiveCandidate(
                        id: candidates[index].id,
                        canonicalSubpath: candidates[index].canonicalSubpath,
                        displayName: candidates[index].displayName,
                        slug: candidates[index].slug,
                        payload: payload,
                        blockedReason: nil
                    )
                } catch {
                    candidates[index] = candidates[index].blocked(
                        reason: Self.candidateReason(for: error)
                    )
                }
            }

            guard candidates.contains(where: \.isImportable) else {
                throw SkillImportValidationError.archiveRejected(
                    "The archive contains no importable Skill candidates."
                )
            }
            return ArchiveSession(
                id: sessionID,
                temporaryRoot: temporary.lease,
                candidates: candidates
            )
        } catch {
            removeTemporaryRoot(temporary.lease)
            throw error
        }
    }

    func cleanupArchiveSession(
        _ session: ArchiveSession?,
        afterCancelling consumer: Task<Void, Never>? = nil
    ) async {
        consumer?.cancel()
        await consumer?.value
        if let session {
            removeTemporaryRoot(session.temporaryRoot)
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
        temporaryRoot: TemporaryItemLease?,
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

    private nonisolated static func archiveCandidatePaths(
        from entries: [SafeSkillArchive.PreflightEntry]
    ) -> [ArchiveCandidatePath] {
        var paths: [String: ArchiveCandidatePath] = [:]
        for entry in entries where !entry.isDirectory && entry.components.last == "SKILL.md" {
            let raw = Array(entry.components.dropLast())
            let canonical = raw.map(SkillContentPath.normalizedComponent)
            let key = canonical.map(SkillContentPath.collisionKey).joined(separator: "/")
            paths[key] = ArchiveCandidatePath(
                rawComponents: raw,
                canonicalComponents: canonical,
                collisionKey: key
            )
        }
        return paths.values.sorted {
            $0.canonicalComponents.joined(separator: "/")
                < $1.canonicalComponents.joined(separator: "/")
        }
    }

    private func makeArchiveCandidateMetadata(
        path: ArchiveCandidatePath,
        sessionID: UUID,
        archiveURL: URL
    ) -> ArchiveCandidate {
        let canonical = path.canonicalComponents.joined(separator: "/")
        let rawDisplayName = path.canonicalComponents.last
            ?? archiveURL.deletingPathExtension().lastPathComponent
        var displayName: String
        let slug: DefaultDistributionSlug?
        var reason: String?
        do {
            displayName = try SkillDisplayName(rawDisplayName).value
            slug = try DefaultDistributionSlug(
                candidateFrom: SkillDisplayName(rawDisplayName)
            )
        } catch {
            displayName = rawDisplayName
            slug = nil
            reason = "The Skill name cannot produce a safe distribution slug."
        }
        return ArchiveCandidate(
            id: ArchiveCandidateID(
                archiveSessionID: sessionID,
                canonicalSubpathCollisionKey: path.collisionKey
            ),
            canonicalSubpath: canonical,
            displayName: displayName,
            slug: slug,
            payload: nil,
            blockedReason: reason
        )
    }

    private func markArchiveCandidateConflicts(
        _ candidates: inout [ArchiveCandidate]
    ) {
        for lhs in candidates.indices {
            guard candidates[lhs].blockedReason == nil else { continue }
            let left = candidates[lhs].id.canonicalSubpathCollisionKey
            for rhs in candidates.indices where lhs != rhs {
                guard candidates[rhs].blockedReason == nil else { continue }
                let right = candidates[rhs].id.canonicalSubpathCollisionKey
                guard !left.isEmpty && !right.isEmpty else {
                    if left.isEmpty != right.isEmpty {
                        candidates[lhs] = candidates[lhs].blocked(
                            reason: "This Skill's content range overlaps another candidate."
                        )
                        candidates[rhs] = candidates[rhs].blocked(
                            reason: "This Skill's content range overlaps another candidate."
                        )
                    }
                    continue
                }
                let leftParts = left.split(separator: "/")
                let rightParts = right.split(separator: "/")
                if Self.isPrefix(leftParts, of: rightParts)
                    || Self.isPrefix(rightParts, of: leftParts) {
                    candidates[lhs] = candidates[lhs].blocked(
                        reason: "This Skill's content range overlaps another candidate."
                    )
                    candidates[rhs] = candidates[rhs].blocked(
                        reason: "This Skill's content range overlaps another candidate."
                    )
                }
            }
        }

        var slugOwners: [String: [Int]] = [:]
        for index in candidates.indices {
            guard let slug = candidates[index].slug,
                  candidates[index].blockedReason == nil else { continue }
            slugOwners[slug.collisionKey, default: []].append(index)
        }
        for owners in slugOwners.values where owners.count > 1 {
            for index in owners {
                candidates[index] = candidates[index].blocked(
                    reason: "This Skill has the same distribution slug as another candidate."
                )
            }
        }
    }

    private nonisolated static func isPrefix(
        _ prefix: [Substring],
        of value: [Substring]
    ) -> Bool {
        prefix.count < value.count && value.starts(with: prefix)
    }

    private nonisolated static func candidateReason(for error: Error) -> String {
        if let error = error as? SkillImportValidationError {
            return error.localizedDescription
        }
        if let error = error as? SkillPackageError {
            return error.localizedDescription
        }
        if let error = error as? SkillContentSnapshotError {
            return error.localizedDescription
        }
        return "The Skill candidate could not be validated safely."
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
