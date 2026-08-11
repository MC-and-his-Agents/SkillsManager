import Foundation

nonisolated extension DistributionCopyExecutor {
    func recoverAll() throws {
        for operation in try operationStore.recoverableOperations()
        where operation.formatVersion == 2 || operation.formatVersion == 3 {
            do {
                try recover(operation)
            } catch {
                do {
                    try operationStore.markNeedsRepair(
                        operationID: operation.operationID,
                        detail: error.localizedDescription,
                        updatedAtMilliseconds: max(
                            operation.updatedAtMilliseconds,
                            nowMilliseconds()
                        )
                    )
                } catch DistributionOperationStoreError.conflict {
                    // A committed cleanup may mark needsRepair before the
                    // recovery boundary reports its typed failure. Treat the
                    // second mark as idempotent only when the terminal repair
                    // outcome is already durable.
                    guard try operationStore.load(operation.operationID).outcome
                        == .needsRepair else {
                        throw error
                    }
                }
            }
        }
    }

    private func recover(_ operation: DistributionOperationRecord) throws {
        let preflight = try DistributionOperationPayloadCodec.decode(
            DistributionOperationPreflightV2.self,
            from: operation.preflightPayload
        )
        var runtime = try DistributionOperationPayloadCodec.decode(
            DistributionOperationRuntimeV2.self,
            from: operation.runtimePayload
        )
        let plan = try recoveryPlan(operation: operation, preflight: preflight)
        switch operation.phase {
        case .prepared, .applying, .rollingBack, .filesystemApplied:
            let oldBindings = try decodePersistedBindings(
                operation.oldBindings,
                skillID: operation.skillID,
                formatVersion: operation.formatVersion
            )
            let oldLinks = try linkOwnershipStore.load(skillID: operation.skillID)
            if operation.phase == .prepared {
                runtime = DistributionOperationRuntimeV2(
                    wireVersion: 2,
                    actions: plan.filesystemActions.indices.map {
                        DistributionOperationRuntimeActionV2(
                            actionIndex: $0,
                            pending: nil,
                            stagedCopy: nil,
                            createdCopy: nil,
                            createdLink: nil,
                            quarantinedCopy: nil,
                            quarantinedLink: nil
                        )
                    }
                )
            }
            try rollbackToOld(
                operationID: operation.operationID,
                plan: plan,
                preflight: preflight,
                runtime: runtime,
                expectedOldBindings: oldBindings,
                expectedOldLinks: oldLinks,
                detail: operation.lastError,
                timestamp: max(operation.updatedAtMilliseconds, nowMilliseconds())
            )
        case .databaseCommitted, .cleaning:
            let desiredBindings = try decodePersistedBindings(
                operation.newBindings,
                skillID: operation.skillID,
                formatVersion: operation.formatVersion
            )
            let desiredLinks = try linkOwnershipStore.load(skillID: operation.skillID)
            try finishCommitted(
                skillID: operation.skillID,
                operationID: operation.operationID,
                plan: plan,
                preflight: preflight,
                runtime: runtime,
                desiredBindings: desiredBindings,
                desiredLinks: desiredLinks,
                timestamp: max(operation.updatedAtMilliseconds, nowMilliseconds())
            )
        case .completed:
            throw DistributionSymlinkExecutorError.needsRepair(
                "Copy recovery reached an invalid phase"
            )
        }
    }

    private func recoveryPlan(
        operation: DistributionOperationRecord,
        preflight: DistributionOperationPreflightV2
    ) throws -> DistributionPlan {
        let bindings = try decodeBindingIntents(
            operation.newBindings,
            skillID: operation.skillID,
            formatVersion: operation.formatVersion
        )
        let planActions: [DistributionPlanActionWire]
        do {
            planActions = try DistributionOperationPayloadV2Validator.planActionsV2(
                operation.planPayload
            )
        } catch {
            throw DistributionSymlinkExecutorError.needsRepair(
                "persisted Copy plan is invalid"
            )
        }
        guard planActions.count == preflight.actions.count else {
            throw DistributionSymlinkExecutorError.needsRepair(
                "persisted Copy plan is invalid"
            )
        }
        let actions = try preflight.actions.enumerated().map { index, value in
            guard let kind = DistributionFilesystemActionKind(
                rawValue: value.kind
            ), value.targetScopeKey == planActions[index].targetScopeKey,
                value.kind == planActions[index].action else {
                throw DistributionSymlinkExecutorError.needsRepair(
                    "persisted Copy plan is invalid"
                )
            }
            let entry = try recoveryEntry(
                value,
                targetLocator: planActions[index].targetLocator
            )
            return DistributionFilesystemAction(
                kind: kind,
                entry: entry,
                ssotLocator: DistributionTargetCatalog.current.ssotLocator(
                    for: operation.skillID
                )
            )
        }
        return DistributionPlan(
            status: .executable,
            filesystemActions: actions,
            bindingsChanged: true,
            bindingReplacement: bindings,
            configurationChanged: preflight.expectedOldConfigured
                != preflight.desiredConfigured,
            expectedOldConfigured: preflight.expectedOldConfigured,
            desiredConfigured: preflight.desiredConfigured,
            conflicts: []
        )
    }

    private func recoveryEntry(
        _ action: DistributionOperationPreflightActionV2,
        targetLocator: String
    ) throws -> DistributionTargetEntry {
        let scope: DistributionBindingScope
        if action.targetScopeKey == DistributionBindingScope.global.targetScopeKey {
            scope = .global
        } else if action.targetScopeKey.hasPrefix("agent:"),
                  let platform = SkillPlatform.allCases.first(where: {
                      action.targetScopeKey == "agent:\($0.storageKey)"
                  }) {
            scope = .agent(platform)
        } else {
            throw DistributionSymlinkExecutorError.needsRepair(
                "persisted Copy target scope is invalid"
            )
        }
        let catalog = fileSystem.catalog
        guard let persisted = DistributionTargetCatalog.persistedTarget(
            from: targetLocator,
            for: scope
        ), persisted.slug.value == action.slug else {
            throw DistributionSymlinkExecutorError.needsRepair(
                "persisted Copy target locator is invalid"
            )
        }
        guard let current = catalog.target(for: scope) else {
            throw DistributionSymlinkExecutorError.needsRepair(
                "distribution target is unavailable"
            )
        }
        let defaultRoot = try fileSystem.defaultRootURL(for: scope)
        let currentMatchesPersisted = current.rootLocator == persisted.rootLocator
            || (persisted.rootLocator.hasPrefix("~/")
                && current.rootLocator == defaultRoot.path)
        guard currentMatchesPersisted else {
            throw DistributionSymlinkExecutorError.needsRepair(
                "distribution target changed since the operation was prepared"
            )
        }
        guard let slug = try? DefaultDistributionSlug(validating: action.slug),
              let entry = catalog.entry(
                  for: scope,
                  slug: slug
              ) else {
            throw DistributionSymlinkExecutorError.needsRepair(
                "persisted Copy target slug is invalid"
            )
        }
        return entry
    }

    private func decodeBindingIntents(
        _ payload: Data,
        skillID: SkillID,
        formatVersion: Int
    ) throws -> [DistributionBindingIntent] {
        switch formatVersion {
        case 2:
            return try DistributionOperationPayloadCodec.decode(
                [DistributionBindingWireV2].self,
                from: payload
            ).map {
                try $0.intent(expectedSkillID: skillID)
            }
        case 3:
            return try DistributionOperationPayloadCodec.decode(
                [DistributionBindingWireV3].self,
                from: payload
            ).map {
                try $0.intent(expectedSkillID: skillID)
            }
        default:
            throw DistributionSymlinkExecutorError.needsRepair(
                "unsupported Copy operation format"
            )
        }
    }

    private func decodePersistedBindings(
        _ payload: Data,
        skillID: SkillID,
        formatVersion: Int
    ) throws -> [DistributionBinding] {
        let bindings: [DistributionBinding]
        switch formatVersion {
        case 2:
            bindings = try DistributionOperationPayloadCodec.decode(
                [DistributionBindingWireV2].self,
                from: payload
            ).map {
                try $0.binding(expectedSkillID: skillID)
            }
        case 3:
            bindings = try DistributionOperationPayloadCodec.decode(
                [DistributionBindingWireV3].self,
                from: payload
            ).map {
                try $0.binding(expectedSkillID: skillID)
            }
        default:
            throw DistributionSymlinkExecutorError.needsRepair(
                "unsupported Copy operation format"
            )
        }
        return bindings.sorted {
            distributionBindingIntentPrecedes($0.intent, $1.intent)
        }
    }
}
