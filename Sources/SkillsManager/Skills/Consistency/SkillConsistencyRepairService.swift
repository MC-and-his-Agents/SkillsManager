import Foundation

actor SkillConsistencyRepairService {
    private let writer: JournaledSSOTWriter
    private let audit: SkillConsistencyAuditService
    private var consumedConfirmations = Set<UUID>()

    init(
        writer: JournaledSSOTWriter,
        homeURL: URL = FileManager.default.homeDirectoryForCurrentUser,
        betweenAuditCaptures: @escaping @Sendable () async throws -> Void = {}
    ) {
        self.writer = writer
        audit = SkillConsistencyAuditService(
            writer: writer,
            homeURL: homeURL,
            betweenCaptures: betweenAuditCaptures
        )
    }

    func prepare(
        skillID: SkillID,
        action: SkillConsistencyRepairAction
    ) async throws -> SkillConsistencyRepairPreview {
        if action == .skip {
            return SkillConsistencyRepairPreview(
                confirmationID: UUID(),
                skillID: skillID,
                action: action,
                auditCanonicalBytes: Data(),
                selectionToken: Data(),
                planCanonicalBytes: Data()
            )
        }
        do {
            let prepared = try await audit.prepare()
            let selection = try await writer.loadDistributionSelection(skillID: skillID)
            let observations = try observations(
                manifest: prepared.manifest,
                skillID: skillID
            )
            guard let intent = action.intent else {
                throw SkillConsistencyRepairError.invalidSelection
            }
            let plan = try DistributionPlanner().repairPlan(
                skillID: skillID,
                selection: selection,
                intent: intent,
                scopeKeys: action.scopeKeys,
                observations: observations
            )
            return SkillConsistencyRepairPreview(
                confirmationID: UUID(),
                skillID: skillID,
                action: action,
                auditCanonicalBytes: prepared.canonicalBytes,
                selectionToken: try DistributionRepairSelectionToken.encode(
                    selection,
                    skillID: skillID
                ),
                planCanonicalBytes: try plan.canonicalJSONData()
            )
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            throw stableSkillConsistencyRepairError(error)
        }
    }

    func confirm(
        _ preview: SkillConsistencyRepairPreview
    ) async throws -> SkillConsistencyRepairResult {
        guard consumedConfirmations.insert(preview.confirmationID).inserted else {
            throw SkillConsistencyRepairError.stalePreview
        }
        if preview.action == .skip { return .skipped }
        do {
            let prepared = try await audit.prepare()
            guard prepared.canonicalBytes == preview.auditCanonicalBytes,
                  let intent = preview.action.intent else {
                throw SkillConsistencyRepairError.stalePreview
            }
            let selection = try await writer.loadDistributionSelection(
                skillID: preview.skillID
            )
            guard try DistributionRepairSelectionToken.encode(
                selection,
                skillID: preview.skillID
            ) == preview.selectionToken else {
                throw SkillConsistencyRepairError.stalePreview
            }
            let expected = try repairReadbackExpectation(
                manifest: prepared.manifest,
                skillID: preview.skillID,
                action: preview.action,
                selection: selection
            )
            let operation = try await writer.applyDistributionRepair(
                skillID: preview.skillID,
                intent: intent,
                scopeKeys: preview.action.scopeKeys,
                expectedSelectionToken: preview.selectionToken,
                expectedPlan: preview.planCanonicalBytes
            )
            guard operation.phase == .completed,
                  operation.outcome == .applied else {
                throw SkillConsistencyRepairError.needsRepair
            }
            let reconcile = try await writer.reconcileDistribution(skillID: preview.skillID)
            guard stableSkillConsistencyRepairReadback(
                reconcile,
                skillID: preview.skillID,
                expectedBindingScopeKeys: expected.bindingScopeKeys,
                expectedMissingScopeKeys: expected.missingScopeKeys
            ) else {
                throw SkillConsistencyRepairError.needsRepair
            }
            return .applied(operation.operationID)
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            throw stableSkillConsistencyRepairError(error)
        }
    }

    private func repairReadbackExpectation(
        manifest: SkillConsistencyAuditManifest,
        skillID: SkillID,
        action: SkillConsistencyRepairAction,
        selection: DistributionSelectionReadback
    ) throws -> (bindingScopeKeys: Set<String>, missingScopeKeys: Set<String>) {
        let current = try observations(manifest: manifest, skillID: skillID)
        let missing = Set(current.compactMap { entry, observation in
            observation == .missing ? entry.target.scope.targetScopeKey : nil
        })
        let bindingScopes = Set(selection.bindings.map(\.scope.targetScopeKey))
        switch action {
        case .rebuildMissingSymlink:
            return (bindingScopes, [])
        case .disableMissingBinding(let selected):
            return (
                bindingScopes.subtracting(selected),
                missing.subtracting(selected)
            )
        case .skip:
            throw SkillConsistencyRepairError.invalidSelection
        }
    }

    private func observations(
        manifest: SkillConsistencyAuditManifest,
        skillID: SkillID
    ) throws -> [DistributionTargetEntry: DistributionTargetObservation] {
        guard manifest.coverage == .complete else {
            throw SkillConsistencyRepairError.auditIncomplete
        }
        guard manifest.managedSkills.contains(where: {
            $0.skillID == skillID.directoryName
        }), let distribution = manifest.distributions.first(where: {
            $0.skillID == skillID.directoryName
        }) else {
            throw SkillConsistencyRepairError.invalidSelection
        }
        switch distribution.status {
        case DistributionReconcileStatus.operationInProgress.rawValue:
            throw SkillConsistencyRepairError.operationInProgress
        case DistributionReconcileStatus.needsRepair.rawValue:
            throw SkillConsistencyRepairError.needsRepair
        default:
            break
        }
        return try Dictionary(uniqueKeysWithValues: distribution.targets.map {
            guard let scope = distributionRepairScope(for: $0.scopeKey),
                  let slug = try? DefaultDistributionSlug(validating: $0.slug),
                  let entry = DistributionTargetCatalog.current.entry(
                      for: scope,
                      slug: slug
                  ) else {
                throw SkillConsistencyRepairError.unavailable
            }
            let observation: DistributionTargetObservation = switch $0.observation.kind {
            case "missing":
                .missing
            case "managed" where $0.observation.skillID == skillID.directoryName
                && $0.observation.ssotDirectoryName == skillID.directoryName:
                .managed(skillID: skillID, ssotDirectoryName: skillID.directoryName)
            case "unavailable":
                .unavailable
            default:
                .unknownObject
            }
            return (entry, observation)
        })
    }

}

nonisolated func stableSkillConsistencyRepairReadback(
    _ result: DistributionReconcileResult,
    skillID: SkillID,
    expectedBindingScopeKeys: Set<String>,
    expectedMissingScopeKeys: Set<String>
) -> Bool {
    let scopeKeys = Set(result.observations.keys.map(\.target.scope.targetScopeKey))
    guard scopeKeys == expectedBindingScopeKeys else { return false }
    let expectedStatus: DistributionReconcileStatus = expectedMissingScopeKeys.isEmpty
        ? .inSync
        : .drifted
    guard result.status == expectedStatus else { return false }

    var missing = Set<String>()
    for (entry, observation) in result.observations {
        let scopeKey = entry.target.scope.targetScopeKey
        switch observation {
        case .missing:
            missing.insert(scopeKey)
        case .managed(let owner, let directoryName):
            guard owner == skillID, directoryName == skillID.directoryName else {
                return false
            }
        default:
            return false
        }
    }
    return missing == expectedMissingScopeKeys
}

nonisolated func stableSkillConsistencyRepairError(
    _ error: Error
) -> SkillConsistencyRepairError {
    if let error = error as? SkillConsistencyRepairError { return error }
    if let error = error as? DistributionRepairPlanningError {
        return switch error {
        case .invalidSelection: .invalidSelection
        case .unsupportedBindingState: .unsupportedBindingState
        case .copyRequiresForkDecision: .copyRequiresForkDecision
        case .targetOccupied: .targetOccupied
        case .unavailable: .unavailable
        }
    }
    if let error = error as? DistributionSymlinkExecutorError {
        return switch error {
        case .conflict: .stalePreview
        case .operationInProgress: .operationInProgress
        case .needsRepair: .needsRepair
        case .blocked: .targetOccupied
        }
    }
    if let error = error as? SkillConsistencyAuditError {
        return switch error {
        case .sourceChanged: .stalePreview
        case .permissionDenied: .permissionDenied
        case .rootUnavailable, .databaseUnavailable, .writerUnavailable: .unavailable
        case .inconsistentCatalog: .needsRepair
        }
    }
    if let error = error as? DistributionSymlinkFileSystemError,
       case .posix(_, let code) = error,
       code == EACCES || code == EPERM {
        return .permissionDenied
    }
    let value = error as NSError
    if value.domain == NSPOSIXErrorDomain,
       (value.code == Int(EACCES) || value.code == Int(EPERM)) {
        return .permissionDenied
    }
    return .unavailable
}
