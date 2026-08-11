import Foundation

extension JournaledSSOTWriter {
    func historicalMigrationSSOTExpectation(
        skillID: SkillID,
        requiresExisting: Bool
    ) throws -> HistoricalSkillMigrationSSOTExpectation {
        try requireAuthority()
        let target = fileSystem.finalURL(skillID: skillID).standardizedFileURL.path
        if requiresExisting {
            return .existing(
                try historicalMigrationSSOTEvidence(
                    skillID: skillID,
                    expectedAbsoluteTarget: target
                )
            )
        }
        guard try fileSystem.managedRootGuard.itemIdentity(
            at: fileSystem.finalURL(skillID: skillID)
        ) == nil else {
            throw HistoricalSkillMigrationError.stalePreview
        }
        return .absent(absoluteTarget: target)
    }

    func requireHistoricalMigrationSSOTExpectation(
        _ expectation: HistoricalSkillMigrationSSOTExpectation,
        skillID: SkillID
    ) throws -> DistributionCopySourceEvidence? {
        try requireAuthority()
        switch expectation {
        case .absent(let absoluteTarget):
            guard fileSystem.finalURL(skillID: skillID).standardizedFileURL.path
                    == absoluteTarget,
                  try fileSystem.managedRootGuard.itemIdentity(
                    at: fileSystem.finalURL(skillID: skillID)
                  ) == nil else {
                throw HistoricalSkillMigrationError.stalePreview
            }
            return nil
        case .existing(let expected):
            let current = try historicalMigrationSSOTEvidence(
                skillID: skillID,
                expectedAbsoluteTarget: expected.absoluteTarget
            )
            guard current == expected else {
                throw HistoricalSkillMigrationError.stalePreview
            }
            return current
        }
    }

    func historicalMigrationSSOTEvidence(
        skillID: SkillID,
        expectedAbsoluteTarget: String
    ) throws -> DistributionCopySourceEvidence {
        try requireAuthority()
        let evidence = try copyDistribution.fileSystem.copySource(
            for: skillID
        ).decisionEvidence()
        guard evidence.absoluteTarget == expectedAbsoluteTarget else {
            throw HistoricalSkillMigrationError.stalePreview
        }
        return evidence
    }

    func historicalMigrationPlan(
        skillID: SkillID,
        scope: DistributionBindingScope,
        slug: DefaultDistributionSlug,
        source: HistoricalSkillMigrationSource? = nil
    ) throws -> DistributionPlan {
        try requireAuthority()
        let selection = try loadDistributionSelection(skillID: skillID)
        let ownership = try DistributionLinkOwnershipStore(connection: connection)
            .load(skillID: skillID)
        let entry: DistributionTargetEntry
        if let source {
            guard let sourceEntry = try historicalMigrationEntry(source) else {
                throw HistoricalSkillMigrationError.invalidSelection
            }
            entry = sourceEntry
        } else {
            guard let primaryEntry = distributionCatalog.entry(
                for: scope,
                slug: slug
            ) else {
                throw HistoricalSkillMigrationError.invalidSelection
            }
            entry = primaryEntry
        }

        // A historical source may be a duplicate in another harness root.
        // Keep an already valid selection and journal only the source cleanup;
        // the planner remains the sole owner of binding transitions.
        if let source, !selection.bindings.isEmpty {
            let current = selection.bindings.map(\.intent)
                .sorted(by: distributionBindingIntentPrecedes)
            let sourceScope: DistributionBindingScope
            switch source.discoveryScope.kind {
            case .global:
                sourceScope = .global
            case .agent:
                guard let adapter = source.discoveryScope.adapterCode,
                      let platform = SkillPlatform.allCases.first(where: {
                          $0.storageKey == adapter
                      }) else {
                    throw HistoricalSkillMigrationError.invalidSelection
                }
                sourceScope = .agent(platform)
            case .custom:
                throw HistoricalSkillMigrationError.unsupportedCandidate
            }
            let sourceEntry = try DefaultDistributionSlug(validating: source.normalizedLocator)
            guard sourceEntry == slug else {
                throw HistoricalSkillMigrationError.invalidSelection
            }
            let sameTargetBinding = sourceIsPrimary(source)
                && selection.bindings.contains {
                    $0.scope == sourceScope && $0.distributionSlug == sourceEntry
                }
            if sameTargetBinding,
               selection.bindings.contains(where: {
                   $0.scope == sourceScope
                       && $0.distributionSlug == sourceEntry
                       && $0.syncMode != .symlink
               }) {
                throw HistoricalSkillMigrationError.unsupportedCandidate
            }
            let action: DistributionFilesystemAction
            if sameTargetBinding {
                // A stale/ordinary directory occupies an existing binding.
                // Replacing it with the SSOT link preserves the binding.
                action = DistributionFilesystemAction(
                    kind: .replaceCopyWithSymlink,
                    entry: entry,
                    ssotLocator: DistributionTargetCatalog.current.ssotLocator(for: skillID)
                )
            } else {
                // The source is an extra unmanaged directory. Quarantine and
                // remove it through the copy executor's existing V2 journal.
                action = DistributionFilesystemAction(
                    kind: .removeCopy,
                    entry: entry,
                    ssotLocator: DistributionTargetCatalog.current.ssotLocator(for: skillID)
                )
            }
            return DistributionPlan(
                status: .executable,
                filesystemActions: [action],
                bindingsChanged: false,
                bindingReplacement: current,
                configurationChanged: false,
                expectedOldConfigured: selection.isExplicitlyConfigured,
                desiredConfigured: selection.isExplicitlyConfigured,
                conflicts: []
            )
        }

        guard selection.bindings.isEmpty, ownership.isEmpty else {
            throw HistoricalSkillMigrationError.invalidSelection
        }
        let desired = DistributionBindingIntent(
            skillID: skillID,
            scope: scope,
            distributionSlug: slug,
            syncMode: .symlink
        )
        return DistributionPlan(
            status: .executable,
            filesystemActions: [
                DistributionFilesystemAction(
                    kind: .replaceCopyWithSymlink,
                    entry: entry,
                    ssotLocator: DistributionTargetCatalog.current.ssotLocator(for: skillID)
                ),
            ],
            bindingsChanged: true,
            bindingReplacement: [desired],
            configurationChanged: !selection.isExplicitlyConfigured,
            expectedOldConfigured: selection.isExplicitlyConfigured,
            desiredConfigured: true,
            conflicts: []
        )
    }

    func captureHistoricalMigrationSource(
        _ source: HistoricalSkillMigrationSource
    ) throws -> DistributionCopyCapture {
        try requireAuthority()
        guard let entry = try historicalMigrationEntry(source) else {
            throw HistoricalSkillMigrationError.invalidSelection
        }
        let capture = try copyDistribution.fileSystem.captureCopy(
            entry,
            expectedRootIdentity: source.rootIdentity,
            expectedEntryIdentity: source.candidateIdentity
        )
        guard capture.evidence.contentFingerprint == source.fingerprint else {
            throw HistoricalSkillMigrationError.sourceChanged
        }
        return capture
    }

    func existingHistoricalMigrationBackup(
        skillID: SkillID,
        source: HistoricalSkillMigrationSource
    ) throws -> HistoricalSkillMigrationExistingBackup? {
        try requireAuthority()
        try recoverIndependentUpdateBackups()
        let matches = try SkillBackupStore(connection: connection)
            .list(originalSkillID: skillID)
            .compactMap { backup -> (SkillBackupRecord, SkillBackupMigrationMetadata)? in
                guard backup.state == .available else { return nil }
                let manifest = try validatedBackupManifest(backup)
                guard let metadata = manifest.migrationMetadata,
                      metadata.sourceScope == source.scope,
                      metadata.rawLocator == source.rawLocator,
                      metadata.normalizedLocator == source.normalizedLocator,
                      metadata.rootIdentity == source.rootIdentity,
                      metadata.candidateIdentity == source.candidateIdentity,
                      metadata.fingerprint == source.fingerprint else {
                    return nil
                }
                return (backup, metadata)
            }
        guard matches.count <= 1 else {
            throw HistoricalSkillMigrationError.needsRepair
        }
        guard let (backup, metadata) = matches.first else { return nil }
        let operationID: SSOTOperationID
        do {
            let operation = try copyDistribution.operationStore.load(metadata.operationID)
            if operation.phase == .completed, operation.outcome == .rolledBack {
                operationID = SSOTOperationID()
            } else if operation.outcome == .needsRepair {
                throw HistoricalSkillMigrationError.needsRepair
            } else {
                operationID = metadata.operationID
            }
        } catch DistributionOperationStoreError.operationNotFound {
            operationID = metadata.operationID
        }
        return HistoricalSkillMigrationExistingBackup(
            backup: backup,
            metadata: metadata,
            operationID: operationID
        )
    }

    func performHistoricalMigration(
        skill: ManagedSkillRecord,
        request: HistoricalSkillMigrationRequest
    ) throws -> HistoricalSkillMigrationResult {
        try requireAuthority()
        try recoverAll()
        try recoverIndependentUpdateBackups()
        try copyDistribution.recoverAll()
        let currentSSOT = try historicalMigrationSSOTEvidence(
            skillID: request.skillID,
            expectedAbsoluteTarget: request.ssotEvidence.absoluteTarget
        )
        let existingOperation = try? copyDistribution.operationStore.load(
            request.operationID
        )
        guard skill.skillID == request.skillID,
              currentSSOT == request.ssotEvidence,
              let domain = try journal.storedDomain(request.skillID),
              domain.payload.skill == skill,
              domain.payload.skill.contentFingerprint == request.source.fingerprint,
              (try hasExactHistoricalOrigin(domain.payload, source: request.source)
                  || (existingOperation?.phase == .completed
                      && existingOperation?.outcome == .applied)) else {
            throw HistoricalSkillMigrationError.sourceChanged
        }
        let plan = try historicalMigrationPlan(
            skillID: request.skillID,
            scope: request.source.scope,
            slug: DefaultDistributionSlug(validating: request.source.normalizedLocator),
            source: request.source
        )
        guard try plan.canonicalJSONData() == request.canonicalPlan,
              try request.plan.canonicalJSONData() == request.canonicalPlan else {
            throw HistoricalSkillMigrationError.stalePreview
        }
        let selection = try loadDistributionSelection(skillID: request.skillID)
        let shouldRemoveOrigin = !selection.bindings.isEmpty

        // A completed operation may be observed again after an interrupted UI
        // confirmation. Reuse its published backup and finish the idempotent
        // origin cleanup without attempting to recapture a source that has
        // already been replaced or removed.
        if let existingOperation, existingOperation.phase == .completed,
           existingOperation.outcome == .applied,
           existingOperation.planPayload == request.canonicalPlan,
           let existing = try existingHistoricalMigrationBackup(
               skillID: request.skillID,
               source: request.source
           ) {
            if shouldRemoveOrigin {
                do {
                    try removeHistoricalOrigin(
                        skillID: request.skillID,
                        source: request.source
                    )
                } catch {
                    throw HistoricalSkillMigrationError.needsRepair
                }
            }
            return HistoricalSkillMigrationResult(
                skill: skill,
                backup: existing.backup,
                distribution: existingOperation
            )
        }
        let capture = try captureHistoricalMigrationSource(request.source)
        let metadata = try SkillBackupMigrationMetadata(
            operationID: request.operationID,
            sourceScope: request.source.scope,
            rawLocator: request.source.rawLocator,
            normalizedLocator: request.source.normalizedLocator,
            rootIdentity: request.source.rootIdentity,
            candidateIdentity: request.source.candidateIdentity,
            fingerprint: request.source.fingerprint,
            createdAtMilliseconds: request.createdAtMilliseconds
        )
        let backup: SkillBackupRecord
        do {
            backup = try ensureHistoricalMigrationBackup(
                domain: domain,
                selection: selection,
                capture: capture,
                request: request,
                metadata: metadata
            )
        } catch let problem as HistoricalSkillMigrationError {
            throw problem
        } catch let backup as SkillBackupFileSystemError {
            throw backup
        } catch let manifest as SkillBackupManifestError {
            throw manifest
        } catch let store as SkillBackupStoreError {
            throw store
        } catch {
            throw HistoricalSkillMigrationError.backupUnavailable
        }
        try hooks.historicalMigrationBackupPublished(request.skillID)
        let currentSSOTAfterBackup = try historicalMigrationSSOTEvidence(
            skillID: request.skillID,
            expectedAbsoluteTarget: request.ssotEvidence.absoluteTarget
        )
        guard currentSSOTAfterBackup == request.ssotEvidence else {
            throw HistoricalSkillMigrationError.stalePreview
        }
        let current = try captureHistoricalMigrationSource(request.source)
        guard current.evidence == capture.evidence else {
            throw HistoricalSkillMigrationError.sourceChanged
        }
        let approval = DistributionHistoricalMigrationApproval(
            source: current.evidence,
            backup: backup,
            metadata: try validatedBackupManifest(backup).migrationMetadata
                ?? metadata,
            localOriginCleanup: shouldRemoveOrigin
                ? domain.payload.localOrigins.first(where: {
                    $0.scope == request.source.discoveryScope
                        && $0.rawLocator == request.source.rawLocator
                        && $0.normalizedLocator == request.source.normalizedLocator
                        && $0.collisionKey == SkillContentPath.collisionKey(
                            for: request.source.normalizedLocator
                        )
                        && $0.fingerprint == request.source.fingerprint
                })
                : nil
        )
        let operation = try applyOrReadHistoricalMigration(
            request: request,
            plan: plan,
            approval: approval
        )
        guard operation.phase == .completed, operation.outcome == .applied,
              try copyDistribution.reconcile(skillID: request.skillID).status == .inSync else {
            throw HistoricalSkillMigrationError.needsRepair
        }
        if shouldRemoveOrigin {
            do {
                try removeHistoricalOrigin(
                    skillID: request.skillID,
                    source: request.source
                )
            } catch LocalSkillOriginStoreError.conflict {
                throw HistoricalSkillMigrationError.needsRepair
            } catch {
                throw HistoricalSkillMigrationError.needsRepair
            }
        }
        return HistoricalSkillMigrationResult(
            skill: skill,
            backup: backup,
            distribution: operation
        )
    }

    private func ensureHistoricalMigrationBackup(
        domain: StoredSkillDomainSnapshot,
        selection: DistributionSelectionReadback,
        capture: DistributionCopyCapture,
        request: HistoricalSkillMigrationRequest,
        metadata: SkillBackupMigrationMetadata
    ) throws -> SkillBackupRecord {
        if let existing = try existingHistoricalMigrationBackup(
            skillID: request.skillID,
            source: request.source
        ) {
            return existing.backup
        }
        return try publishIndependentBackup(
            domain: domain,
            selection: selection,
            snapshot: capture.snapshot,
            backupID: request.backupID,
            createdAtMilliseconds: request.createdAtMilliseconds,
            migrationMetadata: metadata
        )
    }

    private func applyOrReadHistoricalMigration(
        request: HistoricalSkillMigrationRequest,
        plan: DistributionPlan,
        approval: DistributionHistoricalMigrationApproval
    ) throws -> DistributionOperationRecord {
        do {
            let existing = try copyDistribution.operationStore.load(request.operationID)
            guard existing.skillID == request.skillID,
                  existing.planPayload == request.canonicalPlan else {
                throw HistoricalSkillMigrationError.needsRepair
            }
            if existing.phase == .completed, existing.outcome == .applied {
                return existing
            }
            if existing.phase == .completed || existing.outcome == .needsRepair {
                throw HistoricalSkillMigrationError.needsRepair
            }
            try copyDistribution.recoverAll()
            return try copyDistribution.operationStore.load(request.operationID)
        } catch DistributionOperationStoreError.operationNotFound {
            let selection = try loadDistributionSelection(skillID: request.skillID)
            return try copyDistribution.apply(
                skillID: request.skillID,
                plan: plan,
                expectedOldBindings: selection.bindings,
                approvedCopySource: request.ssotEvidence,
                approvedHistoricalMigration: approval,
                operationID: request.operationID,
                nowMilliseconds: request.createdAtMilliseconds
            )
        }
    }

    private func hasExactHistoricalOrigin(
        _ payload: SSOTSkillWritePayload,
        source: HistoricalSkillMigrationSource
    ) throws -> Bool {
        payload.localOrigins.contains {
            $0.scope == source.discoveryScope
                && $0.rawLocator == source.rawLocator
                && $0.normalizedLocator == source.normalizedLocator
                && $0.collisionKey == SkillContentPath.collisionKey(
                    for: source.normalizedLocator
                )
                && $0.fingerprint == source.fingerprint
        }
    }

    private func removeHistoricalOrigin(
        skillID: SkillID,
        source: HistoricalSkillMigrationSource
    ) throws {
        guard let origin = try journal.localOrigins().first(where: {
            $0.skillID == skillID
                && $0.scope == source.discoveryScope
                && $0.rawLocator == source.rawLocator
                && $0.normalizedLocator == source.normalizedLocator
                && $0.collisionKey == SkillContentPath.collisionKey(
                    for: source.normalizedLocator
                )
                && $0.fingerprint == source.fingerprint
        }) else { return }
        try journal.removeLocalOrigin(origin)
    }

    func historicalMigrationSourceEntry(
        _ source: HistoricalSkillMigrationSource
    ) throws -> DistributionTargetEntry? {
        try requireAuthority()
        return try historicalMigrationEntry(source)
    }

    private func historicalMigrationEntry(
        _ source: HistoricalSkillMigrationSource
    ) throws -> DistributionTargetEntry? {
        let slug = try DefaultDistributionSlug(validating: source.normalizedLocator)
        let homeURL = copyDistribution.fileSystem.distributionHomeURL
        let catalog = distributionCatalog
        guard let target = catalog.target(for: source.scope) else { return nil }
        guard let root = sourceRootURL(source, target: target, homeURL: homeURL) else {
            return nil
        }
        let sourceTarget = DistributionTarget(
            scope: source.scope,
            rootLocator: try sourceRootLocator(
                source,
                target: target,
                homeURL: homeURL
            ),
            resolvedRootURL: root
        )
        return DistributionTargetEntry(
            target: sourceTarget,
            distributionSlug: slug,
            canonicalLocator: "\(sourceTarget.rootLocator)/\(slug.value)"
                .precomposedStringWithCanonicalMapping
        )
    }

    private func sourceRootLocator(
        _ source: HistoricalSkillMigrationSource,
        target: DistributionTarget,
        homeURL: URL
    ) throws -> String {
        switch source.discoveryScope.kind {
        case .global:
            guard source.discoveryScope.pathVariant == nil,
                  source.discoveryScope.adapterCode == nil,
                  source.discoveryScope.customPathID == nil else {
                throw HistoricalSkillMigrationError.invalidSelection
            }
            return target.rootLocator
        case .custom:
            throw HistoricalSkillMigrationError.unsupportedCandidate
        case .agent:
            guard let adapter = source.discoveryScope.adapterCode,
                  let platform = SkillPlatform.allCases.first(where: {
                      $0.storageKey == adapter
                  }),
                  let pathVariant = source.discoveryScope.pathVariant,
                  source.discoveryScope.customPathID == nil else {
                throw HistoricalSkillMigrationError.invalidSelection
            }
            if pathVariant == target.rootLocator
                || pathVariant == platform.dedicatedDistributionRelativePath {
                return target.rootLocator
            }
            let nestedPrefix = platform.dedicatedDistributionRelativePath + "/"
            for compatibility in platform.discoveryCompatibilityRelativePaths {
                guard pathVariant == compatibility else { continue }
                if target.rootLocator.hasPrefix("~/") {
                    return "~/\(compatibility)"
                }
                return homeURL.appendingPathComponent(
                    compatibility,
                    isDirectory: true
                ).standardizedFileURL.path
            }
            if pathVariant.hasPrefix("/"),
               pathVariant.hasPrefix(target.rootLocator + "/"),
               platform.discoveryCompatibilityRelativePaths.contains(where: {
                   $0.hasPrefix(nestedPrefix)
                       && pathVariant == target.rootLocator + String(
                           $0.dropFirst(platform.dedicatedDistributionRelativePath.count)
                       )
               }) {
                return pathVariant
            }
            throw HistoricalSkillMigrationError.invalidSelection
        }
    }

    private func sourceRootURL(
        _ source: HistoricalSkillMigrationSource,
        target: DistributionTarget,
        homeURL: URL
    ) -> URL? {
        switch source.discoveryScope.kind {
        case .global:
            guard source.discoveryScope.pathVariant == nil else { return nil }
            return target.resolvedRootURL
                ?? homeURL.appendingPathComponent(".agents/skills", isDirectory: true)
        case .custom:
            return nil
        case .agent:
            guard let adapter = source.discoveryScope.adapterCode,
                  let platform = SkillPlatform.allCases.first(where: {
                      $0.storageKey == adapter
                  }),
                  let pathVariant = source.discoveryScope.pathVariant else {
                return nil
            }
            let primary = target.resolvedRootURL
                ?? homeURL.appendingPathComponent(
                    platform.dedicatedDistributionRelativePath,
                    isDirectory: true
                )
            if pathVariant == platform.dedicatedDistributionRelativePath
                || pathVariant == target.rootLocator {
                return primary.standardizedFileURL
            }
            let nestedPrefix = platform.dedicatedDistributionRelativePath + "/"
            let pathVariantURL = URL(fileURLWithPath: pathVariant, isDirectory: true)
                .standardizedFileURL
            for relativePath in platform.discoveryCompatibilityRelativePaths {
                let candidate: URL
                if relativePath.hasPrefix(nestedPrefix) {
                    candidate = primary.appendingPathComponent(
                        String(relativePath.dropFirst(nestedPrefix.count)),
                        isDirectory: true
                    )
                } else {
                    candidate = homeURL.appendingPathComponent(relativePath, isDirectory: true)
                }
                if pathVariant == relativePath || pathVariantURL == candidate.standardizedFileURL {
                    return candidate.standardizedFileURL
                }
            }
            return nil
        }
    }

    private func sourceIsPrimary(_ source: HistoricalSkillMigrationSource) -> Bool {
        switch source.discoveryScope.kind {
        case .global:
            return source.discoveryScope.pathVariant == nil
        case .custom:
            return false
        case .agent:
            guard let adapter = source.discoveryScope.adapterCode,
                  let platform = SkillPlatform.allCases.first(where: {
                      $0.storageKey == adapter
                  }),
                  let pathVariant = source.discoveryScope.pathVariant else {
                return false
            }
            if platform.discoveryCompatibilityRelativePaths.contains(pathVariant)
                || platform.discoveryCompatibilityRelativePaths.contains(where: {
                    pathVariant.hasSuffix("/\($0)")
                }) {
                return false
            }
            let nestedPrefix = platform.dedicatedDistributionRelativePath + "/"
            return !pathVariant.hasPrefix(nestedPrefix)
        }
    }
}
