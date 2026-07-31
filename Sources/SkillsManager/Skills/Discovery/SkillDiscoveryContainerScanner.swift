import Darwin
import Foundation

nonisolated extension SkillDiscoveryScanner {
    func candidates(
        inDirectoryNamed rawName: String,
        normalizedName name: String,
        roots: [SkillDiscoveryRoot],
        rootIdentity: ManagedItemIdentity,
        rootRevision: SkillDiscoveryFileRevision,
        rootDescriptor: Int32,
        descriptor: Int32,
        revision: SkillDiscoveryFileRevision,
        limits: SkillContentLimits,
        checkpoint: SkillCancellationCheckpoint
    ) throws -> [SkillDiscoveryCandidate] {
        var manifest = stat()
        if Darwin.fstatat(descriptor, "SKILL.md", &manifest, AT_SYMLINK_NOFOLLOW) == 0 {
            guard manifest.st_mode & mode_t(S_IFMT) == S_IFREG else {
                return [failedCandidate(
                    named: name,
                    roots: roots,
                    rootIdentity: rootIdentity,
                    identity: revision.identity,
                    locationRevision: location(
                        root: rootRevision,
                        container: nil,
                        candidate: revision
                    ),
                    status: .damaged,
                    reason: .unsupportedEntryType
                )]
            }
            return [try snapshotCandidate(
                rawName: rawName,
                normalizedName: name,
                roots: roots,
                rootIdentity: rootIdentity,
                descriptor: descriptor,
                revision: revision,
                symbolicLinkIdentity: nil,
                locationRevision: location(
                    root: rootRevision,
                    container: nil,
                    candidate: revision
                ),
                limits: limits,
                checkpoint: checkpoint
            )]
        }
        let manifestError = errno
        guard manifestError == ENOENT else {
            return [failedCandidate(
                named: name,
                roots: roots,
                rootIdentity: rootIdentity,
                identity: revision.identity,
                locationRevision: location(
                    root: rootRevision,
                    container: nil,
                    candidate: revision
                ),
                status: permissionError(manifestError) ? .permissionDenied : .damaged,
                reason: permissionError(manifestError)
                    ? .candidatePermissionDenied
                    : .candidateReadFailed
            )]
        }
        return try containerCandidates(
            rawName: rawName,
            normalizedName: name,
            roots: roots,
            rootIdentity: rootIdentity,
            rootRevision: rootRevision,
            rootDescriptor: rootDescriptor,
            descriptor: descriptor,
            revision: revision,
            limits: limits,
            checkpoint: checkpoint
        )
    }

    private func containerCandidates(
        rawName: String,
        normalizedName name: String,
        roots: [SkillDiscoveryRoot],
        rootIdentity: ManagedItemIdentity,
        rootRevision: SkillDiscoveryFileRevision,
        rootDescriptor: Int32,
        descriptor: Int32,
        revision: SkillDiscoveryFileRevision,
        limits: SkillContentLimits,
        checkpoint: SkillCancellationCheckpoint
    ) throws -> [SkillDiscoveryCandidate] {
        let names: [String]
        do {
            names = try SafeSourceTree.names(in: descriptor, displayPath: name)
        } catch let error as SkillContentSnapshotError {
            return [containerFailure(
                rawName: rawName,
                name: name,
                roots: roots,
                rootIdentity: rootIdentity,
                rootRevision: rootRevision,
                revision: revision,
                error: error
            )]
        }
        guard names.count <= limits.maximumDirectoryCount else {
            return [failedCandidate(
                named: name,
                roots: roots,
                rootIdentity: rootIdentity,
                identity: revision.identity,
                locationRevision: location(
                    root: rootRevision,
                    container: revision,
                    candidate: nil
                ),
                status: .damaged,
                reason: .resourceLimitExceeded
            )]
        }

        var candidates: [SkillDiscoveryCandidate] = []
        var hasValidSkill = false
        for childName in names.sorted(by: skillDiscoveryPathComponentPrecedes) {
            try checkpoint()
            guard let child = try containerChildCandidate(
                containerRawName: rawName,
                childRawName: childName,
                roots: roots,
                rootIdentity: rootIdentity,
                rootRevision: rootRevision,
                containerDescriptor: descriptor,
                containerRevision: revision,
                limits: limits,
                checkpoint: checkpoint
            ) else {
                continue
            }
            candidates.append(child)
            hasValidSkill = hasValidSkill || child.terminalStatus == nil
        }
        return finalizeContainerCandidates(
            candidates,
            hasValidSkill: hasValidSkill,
            rawName: rawName,
            name: name,
            roots: roots,
            rootIdentity: rootIdentity,
            rootRevision: rootRevision,
            rootDescriptor: rootDescriptor,
            revision: revision
        )
    }

    private func finalizeContainerCandidates(
        _ candidates: [SkillDiscoveryCandidate],
        hasValidSkill: Bool,
        rawName: String,
        name: String,
        roots: [SkillDiscoveryRoot],
        rootIdentity: ManagedItemIdentity,
        rootRevision: SkillDiscoveryFileRevision,
        rootDescriptor: Int32,
        revision: SkillDiscoveryFileRevision
    ) -> [SkillDiscoveryCandidate] {
        guard SkillDiscoveryFileRevision(named: rawName, in: rootDescriptor) == revision else {
            return [failedCandidate(
                named: name,
                roots: roots,
                rootIdentity: rootIdentity,
                locationRevision: location(
                    root: rootRevision,
                    container: nil,
                    candidate: nil
                ),
                status: .damaged,
                reason: .sourceChanged
            )]
        }
        guard !hasValidSkill else { return candidates }
        let fallback = candidates.first
        return [failedCandidate(
            named: name,
            roots: roots,
            rootIdentity: rootIdentity,
            identity: revision.identity,
            locationRevision: location(
                root: rootRevision,
                container: revision,
                candidate: nil
            ),
            status: fallback?.terminalStatus ?? .damaged,
            reason: fallback?.terminalReason ?? .missingSkillManifest
        )] + candidates
    }

    private func containerChildCandidate(
        containerRawName: String,
        childRawName: String,
        roots: [SkillDiscoveryRoot],
        rootIdentity: ManagedItemIdentity,
        rootRevision: SkillDiscoveryFileRevision,
        containerDescriptor: Int32,
        containerRevision: SkillDiscoveryFileRevision,
        limits: SkillContentLimits,
        checkpoint: SkillCancellationCheckpoint
    ) throws -> SkillDiscoveryCandidate? {
        let rawLocator = "\(containerRawName)/\(childRawName)"
        var metadata = stat()
        guard Darwin.fstatat(
            containerDescriptor,
            childRawName,
            &metadata,
            AT_SYMLINK_NOFOLLOW
        ) == 0 else {
            return failedNestedCandidate(
                rawLocator, roots, rootIdentity, rootRevision, containerRevision,
                nil, permissionError(errno) ? .permissionDenied : .damaged,
                permissionError(errno) ? .candidatePermissionDenied : .sourceChanged
            )
        }
        let childRevision = SkillDiscoveryFileRevision(metadata)
        let type = metadata.st_mode & mode_t(S_IFMT)
        if type == S_IFREG { return nil }
        if type == S_IFLNK {
            return failedNestedCandidate(
                rawLocator, roots, rootIdentity, rootRevision, containerRevision,
                childRevision, .damaged, .unsupportedEntryType
            )
        }
        guard type == S_IFDIR else {
            return failedNestedCandidate(
                rawLocator, roots, rootIdentity, rootRevision, containerRevision,
                childRevision, .damaged, .unsupportedEntryType
            )
        }

        let childDescriptor = Darwin.openat(
            containerDescriptor,
            childRawName,
            O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC
        )
        guard childDescriptor >= 0 else {
            return failedNestedCandidate(
                rawLocator, roots, rootIdentity, rootRevision, containerRevision,
                childRevision,
                permissionError(errno) ? .permissionDenied : .damaged,
                permissionError(errno) ? .candidatePermissionDenied : .sourceChanged
            )
        }
        defer { Darwin.close(childDescriptor) }
        guard SkillDiscoveryFileRevision(descriptor: childDescriptor) == childRevision else {
            return failedNestedCandidate(
                rawLocator, roots, rootIdentity, rootRevision, containerRevision,
                nil, .damaged, .sourceChanged
            )
        }
        return try openedContainerChildCandidate(
            rawLocator: rawLocator,
            childRawName: childRawName,
            roots: roots,
            rootIdentity: rootIdentity,
            rootRevision: rootRevision,
            containerDescriptor: containerDescriptor,
            containerRevision: containerRevision,
            childDescriptor: childDescriptor,
            childRevision: childRevision,
            limits: limits,
            checkpoint: checkpoint
        )
    }

    private func openedContainerChildCandidate(
        rawLocator: String,
        childRawName: String,
        roots: [SkillDiscoveryRoot],
        rootIdentity: ManagedItemIdentity,
        rootRevision: SkillDiscoveryFileRevision,
        containerDescriptor: Int32,
        containerRevision: SkillDiscoveryFileRevision,
        childDescriptor: Int32,
        childRevision: SkillDiscoveryFileRevision,
        limits: SkillContentLimits,
        checkpoint: SkillCancellationCheckpoint
    ) throws -> SkillDiscoveryCandidate? {
        var manifest = stat()
        guard Darwin.fstatat(
            childDescriptor,
            "SKILL.md",
            &manifest,
            AT_SYMLINK_NOFOLLOW
        ) == 0 else {
            let code = errno
            if code == ENOENT { return nil }
            return failedNestedCandidate(
                rawLocator, roots, rootIdentity, rootRevision, containerRevision,
                childRevision,
                permissionError(code) ? .permissionDenied : .damaged,
                permissionError(code) ? .candidatePermissionDenied : .candidateReadFailed
            )
        }
        guard manifest.st_mode & mode_t(S_IFMT) == S_IFREG else {
            return failedNestedCandidate(
                rawLocator, roots, rootIdentity, rootRevision, containerRevision,
                childRevision, .damaged, .unsupportedEntryType
            )
        }
        guard let locator = SkillContentLocator(rawLocator) else {
            return failedNestedCandidate(
                rawLocator, roots, rootIdentity, rootRevision, containerRevision,
                childRevision, .damaged, .unsafeContent
            )
        }

        let candidate = try snapshotCandidate(
            rawName: locator.rawValue,
            normalizedName: locator.normalizedValue,
            roots: roots,
            rootIdentity: rootIdentity,
            descriptor: childDescriptor,
            revision: childRevision,
            symbolicLinkIdentity: nil,
            locationRevision: location(
                root: rootRevision,
                container: containerRevision,
                candidate: childRevision
            ),
            limits: limits,
            checkpoint: checkpoint
        )
        guard SkillDiscoveryFileRevision(
            named: childRawName,
            in: containerDescriptor
        ) == childRevision else {
            return failedNestedCandidate(
                rawLocator, roots, rootIdentity, rootRevision, containerRevision,
                nil, .damaged, .sourceChanged
            )
        }
        return candidate
    }

    private func failedNestedCandidate(
        _ rawLocator: String,
        _ roots: [SkillDiscoveryRoot],
        _ rootIdentity: ManagedItemIdentity,
        _ rootRevision: SkillDiscoveryFileRevision,
        _ containerRevision: SkillDiscoveryFileRevision,
        _ candidateRevision: SkillDiscoveryFileRevision?,
        _ status: SkillDiscoveryStatus,
        _ reason: SkillDiscoveryReason
    ) -> SkillDiscoveryCandidate {
        failedCandidate(
            named: rawLocator,
            roots: roots,
            rootIdentity: rootIdentity,
            identity: candidateRevision?.identity,
            locationRevision: location(
                root: rootRevision,
                container: containerRevision,
                candidate: candidateRevision
            ),
            status: status,
            reason: reason
        )
    }

    private func containerFailure(
        rawName _: String,
        name: String,
        roots: [SkillDiscoveryRoot],
        rootIdentity: ManagedItemIdentity,
        rootRevision: SkillDiscoveryFileRevision,
        revision: SkillDiscoveryFileRevision,
        error: SkillContentSnapshotError
    ) -> SkillDiscoveryCandidate {
        let code: Int32? = if case .fileSystemFailure(_, let value) = error {
            value
        } else {
            nil
        }
        return failedCandidate(
            named: name,
            roots: roots,
            rootIdentity: rootIdentity,
            identity: revision.identity,
            locationRevision: location(
                root: rootRevision,
                container: revision,
                candidate: nil
            ),
            status: code.map(permissionError) == true ? .permissionDenied : .damaged,
            reason: code.map(permissionError) == true
                ? .candidatePermissionDenied
                : .sourceChanged
        )
    }

    private func location(
        root: SkillDiscoveryFileRevision,
        container: SkillDiscoveryFileRevision?,
        candidate: SkillDiscoveryFileRevision?
    ) -> SkillDiscoveryLocationRevision {
        SkillDiscoveryLocationRevision(
            root: root,
            container: container,
            candidate: candidate
        )
    }
}
