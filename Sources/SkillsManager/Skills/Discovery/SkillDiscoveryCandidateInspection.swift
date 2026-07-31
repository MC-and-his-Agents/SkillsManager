import Darwin
import Foundation

nonisolated extension SkillDiscoveryScanner {
    func symbolicLinkCandidate(
        rawName: String,
        roots: [SkillDiscoveryRoot],
        rootIdentity: ManagedItemIdentity,
        rootRevision: SkillDiscoveryFileRevision,
        metadata: stat,
        limits: SkillContentLimits,
        checkpoint: SkillCancellationCheckpoint
    ) throws -> SkillDiscoveryCandidate {
        guard let name = SkillContentPath.visibleDirectoryName(rawName),
              let firstRoot = roots.first else {
            return failedCandidate(
                named: rawName,
                roots: roots,
                rootIdentity: rootIdentity,
                identity: ManagedItemIdentity(metadata),
                locationRevision: .init(
                    root: rootRevision,
                    container: nil,
                    candidate: nil
                ),
                status: .damaged,
                reason: .unsafeContent
            )
        }
        let linkIdentity = ManagedItemIdentity(metadata)
        let candidateURL = firstRoot.url.appendingPathComponent(rawName, isDirectory: true)
        var targetMetadata = stat()
        guard Darwin.fstatat(AT_FDCWD, candidateURL.path, &targetMetadata, 0) == 0 else {
            return failedCandidate(
                named: name,
                roots: roots,
                rootIdentity: rootIdentity,
                symbolicLinkIdentity: linkIdentity,
                locationRevision: .init(
                    root: rootRevision,
                    container: nil,
                    candidate: nil
                ),
                status: permissionError(errno) ? .permissionDenied : .damaged,
                reason: permissionError(errno)
                    ? .candidatePermissionDenied
                    : .symbolicLinkTargetUnavailable
            )
        }
        guard targetMetadata.st_mode & mode_t(S_IFMT) == S_IFDIR else {
            return failedCandidate(
                named: name,
                roots: roots,
                rootIdentity: rootIdentity,
                symbolicLinkIdentity: linkIdentity,
                locationRevision: .init(
                    root: rootRevision,
                    container: nil,
                    candidate: SkillDiscoveryFileRevision(targetMetadata)
                ),
                status: .damaged,
                reason: .symbolicLinkTargetUnsupported
            )
        }

        do {
            return try verifiedSymbolicLinkCandidate(
                rawName: rawName,
                normalizedName: name,
                roots: roots,
                rootIdentity: rootIdentity,
                rootRevision: rootRevision,
                symbolicLinkIdentity: linkIdentity,
                limits: limits,
                checkpoint: checkpoint
            )
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            return failedCandidate(
                named: name,
                roots: roots,
                rootIdentity: rootIdentity,
                symbolicLinkIdentity: linkIdentity,
                locationRevision: .init(
                    root: rootRevision,
                    container: nil,
                    candidate: nil
                ),
                status: .damaged,
                reason: .sourceChanged
            )
        }
    }

    private func verifiedSymbolicLinkCandidate(
        rawName: String,
        normalizedName name: String,
        roots: [SkillDiscoveryRoot],
        rootIdentity: ManagedItemIdentity,
        rootRevision: SkillDiscoveryFileRevision,
        symbolicLinkIdentity: ManagedItemIdentity,
        limits: SkillContentLimits,
        checkpoint: SkillCancellationCheckpoint
    ) throws -> SkillDiscoveryCandidate {
        let references = try roots.map {
            try ManagedRootReference.capture(
                at: $0.url.appendingPathComponent(rawName, isDirectory: true)
            )
        }
        let verified = try references.map { try $0.verifiedRoot() }
        guard let target = verified.first,
              verified.allSatisfy({ $0.identity == target.identity }) else {
            throw ManagedRootReferenceError.rootChanged
        }
        let descriptor = Darwin.open(
            target.url.path,
            O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC
        )
        guard descriptor >= 0 else {
            return failedCandidate(
                named: name,
                roots: roots,
                rootIdentity: rootIdentity,
                symbolicLinkIdentity: symbolicLinkIdentity,
                locationRevision: .init(
                    root: rootRevision,
                    container: nil,
                    candidate: nil
                ),
                status: permissionError(errno) ? .permissionDenied : .damaged,
                reason: permissionError(errno)
                    ? .candidatePermissionDenied
                    : .symbolicLinkTargetUnavailable
            )
        }
        defer { Darwin.close(descriptor) }
        guard let revision = SkillDiscoveryFileRevision(descriptor: descriptor),
              revision.identity == target.identity else {
            throw ManagedRootReferenceError.rootChanged
        }
        let candidate = try snapshotCandidate(
            rawName: rawName,
            normalizedName: name,
            roots: roots,
            rootIdentity: rootIdentity,
            descriptor: descriptor,
            revision: revision,
            symbolicLinkIdentity: symbolicLinkIdentity,
            locationRevision: .init(
                root: rootRevision,
                container: nil,
                candidate: revision
            ),
            limits: limits,
            checkpoint: checkpoint
        )
        guard SkillDiscoveryFileRevision(descriptor: descriptor) == revision,
              try references.allSatisfy({
                  try $0.verifiedRoot().identity == target.identity
              }) else {
            return failedCandidate(
                named: name,
                roots: roots,
                rootIdentity: rootIdentity,
                symbolicLinkIdentity: symbolicLinkIdentity,
                locationRevision: .init(
                    root: rootRevision,
                    container: nil,
                    candidate: nil
                ),
                status: .damaged,
                reason: .sourceChanged
            )
        }
        return candidate
    }

    func snapshotCandidate(
        rawName: String,
        normalizedName name: String,
        roots: [SkillDiscoveryRoot],
        rootIdentity: ManagedItemIdentity,
        descriptor: Int32,
        revision: SkillDiscoveryFileRevision,
        symbolicLinkIdentity: ManagedItemIdentity?,
        locationRevision: SkillDiscoveryLocationRevision,
        limits: SkillContentLimits,
        checkpoint: SkillCancellationCheckpoint
    ) throws -> SkillDiscoveryCandidate {
        do {
            let snapshot = try SkillContentSnapshot.capture(
                directoryDescriptor: descriptor,
                displayPath: name,
                limits: limits,
                checkpoint: checkpoint
            )
            _ = try snapshot.readUTF8File(
                relativePath: "SKILL.md",
                checkpoint: checkpoint
            )
            return SkillDiscoveryCandidate(
                roots: roots,
                rootIdentity: rootIdentity,
                rawRelativeLocator: rawName,
                relativeLocator: name,
                relativeLocatorKey: SkillContentPath.collisionKey(for: name),
                candidateIdentity: revision.identity,
                symbolicLinkIdentity: symbolicLinkIdentity,
                locationRevision: locationRevision,
                fingerprint: try SkillContentFingerprint(currentDigest: snapshot.fingerprintDigest),
                providerAliases: try SkillDiscoveryProviderMetadataReader().aliases(
                    in: descriptor,
                    expectedCandidate: revision,
                    checkpoint: checkpoint
                ),
                terminalStatus: nil,
                terminalReason: nil
            )
        } catch is CancellationError {
            throw CancellationError()
        } catch let error as SkillContentSnapshotError {
            return failedCandidate(
                named: name,
                roots: roots,
                rootIdentity: rootIdentity,
                identity: revision.identity,
                symbolicLinkIdentity: symbolicLinkIdentity,
                locationRevision: locationRevision,
                status: status(for: error),
                reason: reason(for: error)
            )
        } catch {
            return failedCandidate(
                named: name,
                roots: roots,
                rootIdentity: rootIdentity,
                identity: revision.identity,
                symbolicLinkIdentity: symbolicLinkIdentity,
                locationRevision: locationRevision,
                status: .damaged,
                reason: .candidateReadFailed
            )
        }
    }

    func failedCandidate(
        named name: String,
        roots: [SkillDiscoveryRoot],
        rootIdentity: ManagedItemIdentity,
        identity: ManagedItemIdentity? = nil,
        symbolicLinkIdentity: ManagedItemIdentity? = nil,
        locationRevision: SkillDiscoveryLocationRevision? = nil,
        status: SkillDiscoveryStatus,
        reason: SkillDiscoveryReason
    ) -> SkillDiscoveryCandidate {
        let normalized = SkillContentPath.normalizedComponent(name)
        return SkillDiscoveryCandidate(
            roots: roots,
            rootIdentity: rootIdentity,
            rawRelativeLocator: name,
            relativeLocator: normalized,
            relativeLocatorKey: SkillContentPath.collisionKey(for: normalized),
            candidateIdentity: identity,
            symbolicLinkIdentity: symbolicLinkIdentity,
            locationRevision: locationRevision,
            fingerprint: nil,
            providerAliases: [],
            terminalStatus: status,
            terminalReason: reason
        )
    }

    func permissionError(_ code: Int32) -> Bool {
        code == EACCES || code == EPERM
    }

    private func status(for error: SkillContentSnapshotError) -> SkillDiscoveryStatus {
        if case .fileSystemFailure(_, let code) = error, permissionError(code) {
            return .permissionDenied
        }
        return .damaged
    }

    private func reason(for error: SkillContentSnapshotError) -> SkillDiscoveryReason {
        switch error {
        case .fileNotFound(let path) where path == "SKILL.md":
            return .missingSkillManifest
        case .invalidUTF8(let path) where path == "SKILL.md":
            return .invalidSkillManifest
        case .fileChanged, .rootIsNotDirectory:
            return .sourceChanged
        case .unsupportedEntry:
            return .unsupportedEntryType
        case .pathCollision:
            return .unsafeContent
        case .fileCountLimitExceeded, .directoryCountLimitExceeded,
             .pathDepthLimitExceeded, .fileByteLimitExceeded, .totalByteLimitExceeded:
            return .resourceLimitExceeded
        case .fileSystemFailure(_, let code) where permissionError(code):
            return .candidatePermissionDenied
        case .fileSystemFailure:
            return .candidateReadFailed
        case .fileNotFound, .invalidUTF8:
            return .unsafeContent
        }
    }

}
