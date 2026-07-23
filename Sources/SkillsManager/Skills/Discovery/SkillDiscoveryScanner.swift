import Darwin
import Foundation

nonisolated struct SkillDiscoveryScanner {
    private struct RootEntry {
        let root: SkillDiscoveryRoot
        let reference: ManagedRootReference
        let identity: ManagedItemIdentity
    }

    private struct RootGroup {
        var entries: [RootEntry]
    }

    private enum RootInspection {
        case missing
        case verified(RootEntry)
        case diagnostic(SkillDiscoveryRootDiagnostic)
    }

    func scan(
        roots: [SkillDiscoveryRoot],
        catalog: SkillDiscoveryCatalog = .empty,
        limits: SkillContentLimits = .default,
        checkpoint: SkillCancellationCheckpoint = {}
    ) throws -> SkillDiscoveryResult {
        var groups: [ManagedItemIdentity: RootGroup] = [:]
        var diagnostics: [SkillDiscoveryRootDiagnostic] = []

        for root in sortedRoots(roots) {
            try checkpoint()
            switch inspect(root) {
            case .missing:
                continue
            case .verified(let entry):
                groups[entry.identity, default: RootGroup(entries: [])].entries.append(entry)
            case .diagnostic(let diagnostic):
                diagnostics.append(diagnostic)
            }
        }

        var candidates: [SkillDiscoveryCandidate] = []
        for group in sortedGroups(groups.values) {
            try checkpoint()
            let scanned = try scan(group, limits: limits, checkpoint: checkpoint)
            candidates.append(contentsOf: scanned.candidates)
            diagnostics.append(contentsOf: scanned.diagnostics)
        }

        let observations = SkillDiscoveryClassifier()
            .classify(candidates, catalog: catalog)
            .sorted(by: observationPrecedes)
        let uniqueDiagnostics = Array(Set(diagnostics))
        return SkillDiscoveryResult(
            observations: observations,
            rootDiagnostics: uniqueDiagnostics.sorted(by: diagnosticPrecedes)
        )
    }

    private func inspect(_ root: SkillDiscoveryRoot) -> RootInspection {
        var metadata = stat()
        guard Darwin.lstat(root.url.path, &metadata) == 0 else {
            if errno == ENOENT || errno == ENOTDIR { return .missing }
            return .diagnostic(rootDiagnostic(root, errno: errno))
        }
        let type = metadata.st_mode & mode_t(S_IFMT)
        guard type == S_IFDIR || type == S_IFLNK else {
            return .diagnostic(SkillDiscoveryRootDiagnostic(
                root: root,
                reason: .rootUnsupportedType
            ))
        }
        do {
            let reference = try ManagedRootReference.capture(at: root.url)
            let verified = try reference.verifiedRoot()
            return .verified(RootEntry(
                root: root,
                reference: reference,
                identity: verified.identity
            ))
        } catch ManagedRootReferenceError.rootChanged {
            return .diagnostic(SkillDiscoveryRootDiagnostic(root: root, reason: .rootChanged))
        } catch {
            return .diagnostic(SkillDiscoveryRootDiagnostic(root: root, reason: .rootReadFailed))
        }
    }

    private func scan(
        _ group: RootGroup,
        limits: SkillContentLimits,
        checkpoint: SkillCancellationCheckpoint
    ) throws -> (
        candidates: [SkillDiscoveryCandidate],
        diagnostics: [SkillDiscoveryRootDiagnostic]
    ) {
        let revalidated = revalidate(group.entries)
        guard !revalidated.entries.isEmpty else { return ([], revalidated.diagnostics) }
        let representative = revalidated.entries[0]
        let descriptor = Darwin.open(
            representative.reference.canonicalURL.path,
            O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC
        )
        guard descriptor >= 0 else {
            return ([], revalidated.diagnostics + revalidated.entries.map {
                rootDiagnostic($0.root, errno: errno)
            })
        }
        defer { Darwin.close(descriptor) }

        guard let before = revision(of: descriptor), before.identity == representative.identity else {
            return ([], revalidated.diagnostics + revalidated.entries.map {
                SkillDiscoveryRootDiagnostic(root: $0.root, reason: .rootChanged)
            })
        }

        let names: [String]
        do {
            names = try SafeSourceTree.names(
                in: descriptor,
                displayPath: representative.reference.canonicalURL.path
            )
        } catch let error as SkillContentSnapshotError {
            return ([], revalidated.diagnostics + revalidated.entries.map {
                rootDiagnostic($0.root, snapshotError: error)
            })
        } catch {
            return ([], revalidated.diagnostics + revalidated.entries.map {
                SkillDiscoveryRootDiagnostic(root: $0.root, reason: .rootReadFailed)
            })
        }

        let roots = sortedRoots(revalidated.entries.map(\.root))
        var candidates: [SkillDiscoveryCandidate] = []
        for name in names.sorted(by: pathComponentPrecedes) {
            try checkpoint()
            if let candidate = try candidate(
                named: name,
                roots: roots,
                rootIdentity: representative.identity,
                in: descriptor,
                limits: limits,
                checkpoint: checkpoint
            ) {
                candidates.append(candidate)
            }
        }

        guard let after = revision(of: descriptor), before == after else {
            return ([], revalidated.diagnostics + revalidated.entries.map {
                    SkillDiscoveryRootDiagnostic(root: $0.root, reason: .rootChanged)
                })
        }
        let finalValidation = revalidate(revalidated.entries)
        guard !finalValidation.entries.isEmpty else {
            return ([], revalidated.diagnostics + finalValidation.diagnostics)
        }
        let finalRoots = sortedRoots(finalValidation.entries.map(\.root))
        return (
            candidates.map { replacingRoots(of: $0, with: finalRoots) },
            revalidated.diagnostics + finalValidation.diagnostics
        )
    }

    private func candidate(
        named rawName: String,
        roots: [SkillDiscoveryRoot],
        rootIdentity: ManagedItemIdentity,
        in rootDescriptor: Int32,
        limits: SkillContentLimits,
        checkpoint: SkillCancellationCheckpoint
    ) throws -> SkillDiscoveryCandidate? {
        var metadata = stat()
        guard Darwin.fstatat(rootDescriptor, rawName, &metadata, AT_SYMLINK_NOFOLLOW) == 0 else {
            if errno == ENOENT { return nil }
            return failedCandidate(
                named: rawName,
                roots: roots,
                rootIdentity: rootIdentity,
                status: permissionError(errno) ? .permissionDenied : .damaged,
                reason: permissionError(errno) ? .candidatePermissionDenied : .sourceChanged
            )
        }
        let type = metadata.st_mode & mode_t(S_IFMT)
        if type == S_IFREG { return nil }
        if type == S_IFLNK {
            return failedCandidate(
                named: rawName,
                roots: roots,
                rootIdentity: rootIdentity,
                identity: ManagedItemIdentity(metadata),
                status: .conflict,
                reason: .unknownSymlink
            )
        }
        guard type == S_IFDIR else {
            return failedCandidate(
                named: rawName,
                roots: roots,
                rootIdentity: rootIdentity,
                identity: ManagedItemIdentity(metadata),
                status: .damaged,
                reason: .unsupportedEntryType
            )
        }
        guard let name = SkillContentPath.visibleDirectoryName(rawName) else {
            return failedCandidate(
                named: rawName,
                roots: roots,
                rootIdentity: rootIdentity,
                identity: ManagedItemIdentity(metadata),
                status: .damaged,
                reason: .unsafeContent
            )
        }
        return try directoryCandidate(
            rawName: rawName,
            normalizedName: name,
            roots: roots,
            rootIdentity: rootIdentity,
            metadata: metadata,
            rootDescriptor: rootDescriptor,
            limits: limits,
            checkpoint: checkpoint
        )
    }

    private func directoryCandidate(
        rawName: String,
        normalizedName name: String,
        roots: [SkillDiscoveryRoot],
        rootIdentity: ManagedItemIdentity,
        metadata: stat,
        rootDescriptor: Int32,
        limits: SkillContentLimits,
        checkpoint: SkillCancellationCheckpoint
    ) throws -> SkillDiscoveryCandidate {
        let descriptor = Darwin.openat(
            rootDescriptor,
            rawName,
            O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC
        )
        guard descriptor >= 0 else {
            return failedCandidate(
                named: name,
                roots: roots,
                rootIdentity: rootIdentity,
                identity: ManagedItemIdentity(metadata),
                status: permissionError(errno) ? .permissionDenied : .damaged,
                reason: permissionError(errno) ? .candidatePermissionDenied : .sourceChanged
            )
        }
        defer { Darwin.close(descriptor) }
        guard let opened = revision(of: descriptor),
              opened.identity == ManagedItemIdentity(metadata) else {
            return failedCandidate(
                named: name,
                roots: roots,
                rootIdentity: rootIdentity,
                status: .damaged,
                reason: .sourceChanged
            )
        }
        let candidate = try snapshotCandidate(
            rawName: rawName,
            normalizedName: name,
            roots: roots,
            rootIdentity: rootIdentity,
            descriptor: descriptor,
            revision: opened,
            limits: limits,
            checkpoint: checkpoint
        )
        guard SkillDiscoveryFileRevision(named: rawName, in: rootDescriptor) == opened else {
            return failedCandidate(
                named: name,
                roots: roots,
                rootIdentity: rootIdentity,
                status: .damaged,
                reason: .sourceChanged
            )
        }
        return candidate
    }

    private func snapshotCandidate(
        rawName: String,
        normalizedName name: String,
        roots: [SkillDiscoveryRoot],
        rootIdentity: ManagedItemIdentity,
        descriptor: Int32,
        revision: SkillDiscoveryFileRevision,
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
            _ = try snapshot.readUTF8File(relativePath: "SKILL.md", checkpoint: checkpoint)
            return SkillDiscoveryCandidate(
                roots: roots,
                rootIdentity: rootIdentity,
                rawRelativeLocator: rawName,
                relativeLocator: name,
                relativeLocatorKey: SkillContentPath.collisionKey(for: name),
                candidateIdentity: revision.identity,
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
                status: status(for: error),
                reason: reason(for: error)
            )
        } catch {
            return failedCandidate(
                named: name,
                roots: roots,
                rootIdentity: rootIdentity,
                identity: revision.identity,
                status: .damaged,
                reason: .candidateReadFailed
            )
        }
    }

    private func failedCandidate(
        named name: String,
        roots: [SkillDiscoveryRoot],
        rootIdentity: ManagedItemIdentity,
        identity: ManagedItemIdentity? = nil,
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
            fingerprint: nil,
            providerAliases: [],
            terminalStatus: status,
            terminalReason: reason
        )
    }

    private func revalidate(_ entries: [RootEntry]) -> (
        entries: [RootEntry],
        diagnostics: [SkillDiscoveryRootDiagnostic]
    ) {
        var valid: [RootEntry] = []
        var diagnostics: [SkillDiscoveryRootDiagnostic] = []
        for entry in entries {
            do {
                let verified = try entry.reference.verifiedRoot()
                guard verified.identity == entry.identity else {
                    diagnostics.append(SkillDiscoveryRootDiagnostic(
                        root: entry.root,
                        reason: .rootChanged
                    ))
                    continue
                }
                valid.append(entry)
            } catch {
                diagnostics.append(SkillDiscoveryRootDiagnostic(
                    root: entry.root,
                    reason: .rootChanged
                ))
            }
        }
        return (valid, diagnostics)
    }

    private func revision(of descriptor: Int32) -> SkillDiscoveryFileRevision? {
        SkillDiscoveryFileRevision(descriptor: descriptor)
    }

    private func replacingRoots(
        of candidate: SkillDiscoveryCandidate,
        with roots: [SkillDiscoveryRoot]
    ) -> SkillDiscoveryCandidate {
        SkillDiscoveryCandidate(
            roots: roots,
            rootIdentity: candidate.rootIdentity,
            rawRelativeLocator: candidate.rawRelativeLocator,
            relativeLocator: candidate.relativeLocator,
            relativeLocatorKey: candidate.relativeLocatorKey,
            candidateIdentity: candidate.candidateIdentity,
            fingerprint: candidate.fingerprint,
            providerAliases: candidate.providerAliases,
            terminalStatus: candidate.terminalStatus,
            terminalReason: candidate.terminalReason
        )
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

    private func rootDiagnostic(
        _ root: SkillDiscoveryRoot,
        errno code: Int32
    ) -> SkillDiscoveryRootDiagnostic {
        SkillDiscoveryRootDiagnostic(
            root: root,
            reason: permissionError(code) ? .rootPermissionDenied : .rootReadFailed
        )
    }

    private func rootDiagnostic(
        _ root: SkillDiscoveryRoot,
        snapshotError error: SkillContentSnapshotError
    ) -> SkillDiscoveryRootDiagnostic {
        if case .fileSystemFailure(_, let code) = error {
            return rootDiagnostic(root, errno: code)
        }
        return SkillDiscoveryRootDiagnostic(root: root, reason: .rootChanged)
    }

    private func permissionError(_ code: Int32) -> Bool {
        code == EACCES || code == EPERM
    }

    private func sortedRoots(_ roots: [SkillDiscoveryRoot]) -> [SkillDiscoveryRoot] {
        roots.sorted {
            ($0.scope.sortKey, $0.url.path) < ($1.scope.sortKey, $1.url.path)
        }
    }

    private func sortedGroups(_ groups: Dictionary<ManagedItemIdentity, RootGroup>.Values)
    -> [RootGroup] {
        groups.sorted {
            let left = sortedRoots($0.entries.map(\.root)).first
            let right = sortedRoots($1.entries.map(\.root)).first
            return (left?.scope.sortKey ?? "", left?.url.path ?? "")
                < (right?.scope.sortKey ?? "", right?.url.path ?? "")
        }
    }

    private func pathComponentPrecedes(_ lhs: String, _ rhs: String) -> Bool {
        let left = SkillContentPath.normalizedComponent(lhs)
        let right = SkillContentPath.normalizedComponent(rhs)
        return left.utf8.lexicographicallyPrecedes(right.utf8)
    }

    private func observationPrecedes(
        _ lhs: SkillDiscoveryObservation,
        _ rhs: SkillDiscoveryObservation
    ) -> Bool {
        let leftScope = lhs.scopes.map(\.sortKey).joined(separator: "\u{0}")
        let rightScope = rhs.scopes.map(\.sortKey).joined(separator: "\u{0}")
        if leftScope != rightScope { return leftScope < rightScope }
        return lhs.relativeLocator.utf8.lexicographicallyPrecedes(rhs.relativeLocator.utf8)
    }

    private func diagnosticPrecedes(
        _ lhs: SkillDiscoveryRootDiagnostic,
        _ rhs: SkillDiscoveryRootDiagnostic
    ) -> Bool {
        (lhs.root.scope.sortKey, lhs.root.url.path, lhs.reason.rawValue)
            < (rhs.root.scope.sortKey, rhs.root.url.path, rhs.reason.rawValue)
    }
}
