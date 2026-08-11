import Darwin
import Foundation

actor HistoricalSkillMigrationService {
    private struct Pending: Sendable {
        let auditBytes: Data
        let observation: SkillDiscoveryObservation
        let importPreview: ManagedSkillImportPreview?
        let source: HistoricalSkillMigrationSource
        let sourceEvidence: DistributionCopyEvidence
        let plan: DistributionPlan
        let canonicalPlan: Data
        let ssotExpectation: HistoricalSkillMigrationSSOTExpectation
        let skillID: SkillID
        let backupID: SkillBackupID
        let operationID: SSOTOperationID
        let createdAtMilliseconds: Int64
    }

    private enum State {
        case pending(Pending)
        case running(Task<HistoricalSkillMigrationResult, Error>)
        case completed(HistoricalSkillMigrationResult)
        case failed(HistoricalSkillMigrationError)
    }

    private let writer: JournaledSSOTWriter
    private let auditService: SkillConsistencyAuditService
    private let importService: ManagedSkillImportService
    private let homeURL: URL
    private let nowMilliseconds: @Sendable () -> Int64
    private var states: [HistoricalSkillMigrationToken: State] = [:]

    init(
        writer: JournaledSSOTWriter,
        homeURL: URL = FileManager.default.homeDirectoryForCurrentUser,
        nowMilliseconds: @escaping @Sendable () -> Int64 = {
            max(0, Int64(Date().timeIntervalSince1970 * 1_000))
        },
        betweenAuditCaptures: @escaping @Sendable () async throws -> Void = {}
    ) {
        self.writer = writer
        self.homeURL = homeURL.standardizedFileURL
        self.nowMilliseconds = nowMilliseconds
        auditService = SkillConsistencyAuditService(
            writer: writer,
            homeURL: homeURL,
            betweenCaptures: betweenAuditCaptures
        )
        importService = ManagedSkillImportService(
            writer: writer,
            nowMilliseconds: nowMilliseconds
        )
    }

    func prepare(
        audit: SkillConsistencyAuditPrepared,
        observation: SkillDiscoveryObservation,
        importAction: ManagedSkillImportAction?
    ) async throws -> HistoricalSkillMigrationPreview {
        do {
            guard audit.manifest.coverage == .complete,
                  audit.manifest.health.allSatisfy({ !$0.blocking }),
                  try SkillConsistencyAuditManifestCodec.encode(audit.manifest)
                    == audit.canonicalBytes else {
                throw HistoricalSkillMigrationError.unavailable
            }
            let auditObservation = try SkillConsistencyAuditWire.discoveryObservation(
                observation
            )
            guard auditObservation.managedDistributionTarget == nil,
                  audit.manifest.discovery.observations.contains(auditObservation),
                  observation.roots.count == 1,
                  let root = observation.roots.first,
                  let candidateIdentity = observation.candidateIdentity,
                  observation.symbolicLinkIdentity == nil,
                  let fingerprint = observation.fingerprint,
                  observation.rawRelativeLocator == observation.relativeLocator else {
                throw HistoricalSkillMigrationError.unsupportedCandidate
            }
            if importAction != .importNew,
               !audit.manifest.discovery.occupancies.isEmpty {
                guard audit.manifest.discovery.occupancies.contains(where: {
                    $0.relativeLocatorKey == observation.relativeLocatorKey
                        && $0.relation == .sameFingerprint
                }) else {
                    throw HistoricalSkillMigrationError.unsupportedCandidate
                }
            }
            let scope = try distributionScope(for: root)
            let slug = try DefaultDistributionSlug(
                validating: observation.relativeLocator
            )
            try await requireCanonicalRoot(root, scope: scope)
            let occupiedByOtherSkill = audit.manifest.managedSkills.flatMap(\.bindings).contains {
                $0.scopeKey == scope.targetScopeKey
                    && $0.slugKey == slug.collisionKey
                    && $0.skillID != observation.matchedSkillID?.directoryName
            }
            guard !occupiedByOtherSkill else {
                throw HistoricalSkillMigrationError.targetOccupied
            }
            let importPreview = try await prepareImport(
                observation: observation,
                action: importAction
            )
            guard let skillID = importPreview?.newSkillID
                    ?? importPreview?.matchedSkillID
                    ?? observation.matchedSkillID else {
                throw HistoricalSkillMigrationError.invalidSelection
            }
            let ssotExpectation = try await writer.historicalMigrationSSOTExpectation(
                skillID: skillID,
                requiresExisting: importPreview?.action != .importNew
            )
            let source = HistoricalSkillMigrationSource(
                discoveryScope: root.scope,
                scope: scope,
                rawLocator: observation.rawRelativeLocator,
                normalizedLocator: observation.relativeLocator,
                rootIdentity: observation.rootIdentity,
                candidateIdentity: candidateIdentity,
                fingerprint: fingerprint
            )
            let sourceCapture = try await writer.captureHistoricalMigrationSource(
                source
            )
            let plan = try await writer.historicalMigrationPlan(
                skillID: skillID,
                scope: scope,
                slug: slug,
                source: source
            )
            let canonicalPlan = try plan.canonicalJSONData()
            let existing = observation.matchedSkillID == nil ? nil
                : try await writer.existingHistoricalMigrationBackup(
                    skillID: skillID,
                    source: source
                )
            let createdAt = existing?.metadata.createdAtMilliseconds
                ?? max(0, nowMilliseconds())
            let token = HistoricalSkillMigrationToken()
            let pending = Pending(
                auditBytes: audit.canonicalBytes,
                observation: observation,
                importPreview: importPreview,
                source: source,
                sourceEvidence: sourceCapture.evidence,
                plan: plan,
                canonicalPlan: canonicalPlan,
                ssotExpectation: ssotExpectation,
                skillID: skillID,
                backupID: existing?.backup.backupID ?? SkillBackupID(),
                operationID: existing?.operationID ?? SSOTOperationID(),
                createdAtMilliseconds: createdAt
            )
            states[token] = .pending(pending)
            guard let sourceEntry = try await writer.historicalMigrationSourceEntry(source),
                  let targetIntent = plan.bindingReplacement.first,
                  let targetEntry = (await writer.currentDistributionCatalog()).entry(
                      for: targetIntent.scope,
                      slug: targetIntent.distributionSlug
                  ) else {
                throw HistoricalSkillMigrationError.invalidSelection
            }
            return HistoricalSkillMigrationPreview(
                token: token,
                skillID: skillID,
                sourceScope: scope,
                sourceLocator: sourceEntry.canonicalLocator,
                targetLocator: targetEntry.canonicalLocator,
                backupID: pending.backupID,
                operationID: pending.operationID,
                ssotAbsoluteTarget: ssotExpectation.absoluteTarget,
                ssotIdentity: ssotExpectation.identity,
                canonicalAudit: pending.auditBytes,
                canonicalPlan: canonicalPlan
            )
        } catch {
            throw Self.stable(error)
        }
    }

    func confirm(
        _ token: HistoricalSkillMigrationToken
    ) async throws -> HistoricalSkillMigrationResult {
        switch states[token] {
        case .completed(let result):
            return result
        case .failed(let problem):
            throw problem
        case .running(let task):
            return try await task.value
        case .pending(let pending):
            let task = Task { try await self.execute(pending) }
            states[token] = .running(task)
            do {
                let result = try await task.value
                states[token] = .completed(result)
                return result
            } catch {
                let problem = Self.stable(error)
                states[token] = .failed(problem)
                throw problem
            }
        case nil:
            throw HistoricalSkillMigrationError.stalePreview
        }
    }

    private func execute(
        _ pending: Pending
    ) async throws -> HistoricalSkillMigrationResult {
        let currentAudit = try await auditService.prepare()
        guard currentAudit.canonicalBytes == pending.auditBytes,
              currentAudit.manifest.discovery.observations.contains(
                try SkillConsistencyAuditWire.discoveryObservation(
                    pending.observation
                )
              ) else {
            throw HistoricalSkillMigrationError.stalePreview
        }
        let currentSource = try await writer.captureHistoricalMigrationSource(
            pending.source
        )
        guard currentSource.evidence == pending.sourceEvidence else {
            throw HistoricalSkillMigrationError.sourceChanged
        }
        let existingSSOT = try await writer.requireHistoricalMigrationSSOTExpectation(
            pending.ssotExpectation,
            skillID: pending.skillID
        )
        let skill: ManagedSkillRecord
        if let importPreview = pending.importPreview {
            let imported = try await importService.execute(importPreview.token)
            guard imported.skill.skillID == pending.skillID else {
                throw HistoricalSkillMigrationError.stalePreview
            }
            skill = imported.skill
        } else {
            guard let managed = try await writer.managedSkillReadback(
                pending.skillID
            ) else {
                throw HistoricalSkillMigrationError.sourceChanged
            }
            skill = managed
        }
        let ssotEvidence: DistributionCopySourceEvidence
        if let existingSSOT {
            ssotEvidence = existingSSOT
        } else {
            ssotEvidence = try await writer.historicalMigrationSSOTEvidence(
                skillID: pending.skillID,
                expectedAbsoluteTarget: pending.ssotExpectation.absoluteTarget
            )
        }
        guard ssotEvidence.contentFingerprint == skill.contentFingerprint else {
            throw HistoricalSkillMigrationError.sourceChanged
        }
        return try await writer.performHistoricalMigration(
            skill: skill,
            request: HistoricalSkillMigrationRequest(
                skillID: pending.skillID,
                source: pending.source,
                plan: pending.plan,
                canonicalPlan: pending.canonicalPlan,
                ssotEvidence: ssotEvidence,
                backupID: pending.backupID,
                operationID: pending.operationID,
                createdAtMilliseconds: pending.createdAtMilliseconds
            )
        )
    }

    private func prepareImport(
        observation: SkillDiscoveryObservation,
        action: ManagedSkillImportAction?
    ) async throws -> ManagedSkillImportPreview? {
        switch observation.status {
        case .managed:
            guard action == nil, observation.matchedSkillID != nil else {
                throw HistoricalSkillMigrationError.invalidSelection
            }
            return nil
        case .unmanaged:
            guard action == .importNew else {
                throw HistoricalSkillMigrationError.invalidSelection
            }
        case .claimable:
            guard action == .claimExisting else {
                throw HistoricalSkillMigrationError.invalidSelection
            }
        case .conflict:
            guard action == .importNew,
                  observation.reason == .ambiguousSource
                    || observation.reason == .ambiguousFingerprint
                    || observation.reason == .evidenceConflict else {
                throw HistoricalSkillMigrationError.unsupportedCandidate
            }
        case .permissionDenied, .damaged:
            throw HistoricalSkillMigrationError.unsupportedCandidate
        }
        guard let action else {
            throw HistoricalSkillMigrationError.invalidSelection
        }
        return try await importService.preview(
            observation: observation,
            action: action
        )
    }

    private func distributionScope(
        for root: SkillDiscoveryRoot
    ) throws -> DistributionBindingScope {
        switch root.scope.kind {
        case .global:
            guard root.scope.adapterCode == nil,
                  root.scope.pathVariant == nil,
                  root.scope.customPathID == nil else {
                throw HistoricalSkillMigrationError.unsupportedCandidate
            }
            return .global
        case .agent:
            guard let code = root.scope.adapterCode,
                  root.scope.customPathID == nil,
                  let platform = SkillPlatform.allCases.first(where: {
                      $0.storageKey == code
                  }) else {
                throw HistoricalSkillMigrationError.unsupportedCandidate
            }
            return .agent(platform)
        case .custom:
            throw HistoricalSkillMigrationError.unsupportedCandidate
        }
    }

    private func requireCanonicalRoot(
        _ root: SkillDiscoveryRoot,
        scope: DistributionBindingScope
    ) async throws {
        let targetCatalog = await writer.currentDistributionCatalog()
        guard let target = targetCatalog.target(for: scope), target.isAvailable else {
            throw HistoricalSkillMigrationError.unsupportedCandidate
        }
        let expectedURL: URL
        if let resolved = target.resolvedRootURL {
            expectedURL = resolved.standardizedFileURL
        } else if target.rootLocator.hasPrefix("~/") {
            expectedURL = homeURL.appendingPathComponent(
                String(target.rootLocator.dropFirst(2)),
                isDirectory: true
            ).standardizedFileURL
        } else {
            expectedURL = URL(fileURLWithPath: target.rootLocator, isDirectory: true)
                .standardizedFileURL
        }
        guard root.url.standardizedFileURL == expectedURL else {
            guard case .agent(let platform) = scope,
                  let pathVariant = root.scope.pathVariant else {
                throw HistoricalSkillMigrationError.unsupportedCandidate
            }
            let pathVariantURL = URL(fileURLWithPath: pathVariant, isDirectory: true)
                .standardizedFileURL
            let nestedPrefix = platform.dedicatedDistributionRelativePath + "/"
            let compatibilityURL = platform.discoveryCompatibilityRelativePaths
                .compactMap { relativePath -> URL? in
                    let candidate: URL
                    if relativePath.hasPrefix(nestedPrefix) {
                        candidate = expectedURL.appendingPathComponent(
                            String(relativePath.dropFirst(nestedPrefix.count)),
                            isDirectory: true
                        )
                    } else {
                        candidate = homeURL.appendingPathComponent(relativePath, isDirectory: true)
                    }
                    let variantMatches = pathVariant == relativePath
                        || pathVariantURL == candidate.standardizedFileURL
                    return variantMatches ? candidate.standardizedFileURL : nil
                }
                .first
            guard compatibilityURL == root.url.standardizedFileURL else {
                throw HistoricalSkillMigrationError.unsupportedCandidate
            }
            return
        }
    }

    nonisolated static func stable(
        _ error: Error
    ) -> HistoricalSkillMigrationError {
        if let problem = error as? HistoricalSkillMigrationError { return problem }
        if let audit = error as? SkillConsistencyAuditError {
            return audit == .permissionDenied ? .permissionDenied : .stalePreview
        }
        if let importError = error as? ManagedSkillImportError {
            return switch importError {
            case .sourceChanged: .sourceChanged
            case .conflict: .targetOccupied
            case .tokenExpired: .stalePreview
            case .invalidObservation, .actionNotAllowed: .invalidSelection
            }
        }
        if let executor = error as? DistributionSymlinkExecutorError {
            return switch executor {
            case .operationInProgress: .operationInProgress
            case .needsRepair: .needsRepair
            case .blocked, .conflict: .targetOccupied
            }
        }
        if let backup = error as? SkillBackupFileSystemError {
            if case .posix(_, let code) = backup,
               code == EACCES || code == EPERM {
                return .permissionDenied
            }
            return .backupUnavailable
        }
        if error is SkillBackupManifestError || error is SkillBackupStoreError {
            return .backupUnavailable
        }
        if let fileSystem = error as? DistributionSymlinkFileSystemError {
            if case .posix(_, let code) = fileSystem,
               code == EACCES || code == EPERM {
                return .permissionDenied
            }
            if case .entryChanged = fileSystem { return .sourceChanged }
            return .unavailable
        }
        let value = error as NSError
        if value.domain == NSPOSIXErrorDomain,
           (value.code == Int(EACCES) || value.code == Int(EPERM)) {
            return .permissionDenied
        }
        return .unavailable
    }
}
