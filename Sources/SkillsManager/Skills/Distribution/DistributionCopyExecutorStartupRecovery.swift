import Foundation

nonisolated extension DistributionCopyExecutor {
    func recoverAll() throws {
        for operation in try operationStore.recoverableOperations()
        where operation.formatVersion == 2 {
            do {
                try recover(operation)
            } catch {
                try operationStore.markNeedsRepair(
                    operationID: operation.operationID,
                    detail: error.localizedDescription,
                    updatedAtMilliseconds: max(
                        operation.updatedAtMilliseconds,
                        nowMilliseconds()
                    )
                )
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
                skillID: operation.skillID
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
                skillID: operation.skillID
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
                "v2 recovery reached an invalid phase"
            )
        }
    }

    private func recoveryPlan(
        operation: DistributionOperationRecord,
        preflight: DistributionOperationPreflightV2
    ) throws -> DistributionPlan {
        let bindings = try decodeBindingIntents(
            operation.newBindings,
            skillID: operation.skillID
        )
        let actions = try preflight.actions.map { value in
            guard let kind = DistributionFilesystemActionKind(
                rawValue: value.kind
            ), let entry = recoveryEntry(value) else {
                throw DistributionSymlinkExecutorError.needsRepair(
                    "persisted Copy plan is invalid"
                )
            }
            return DistributionFilesystemAction(
                kind: kind,
                entry: entry,
                ssotLocator: preflight.absoluteSSOTTarget
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
        _ action: DistributionOperationPreflightActionV2
    ) -> DistributionTargetEntry? {
        let scope: DistributionBindingScope
        if action.targetScopeKey == DistributionBindingScope.global.targetScopeKey {
            scope = .global
        } else if action.targetScopeKey.hasPrefix("agent:"),
                  let platform = SkillPlatform.allCases.first(where: {
                      action.targetScopeKey == "agent:\($0.storageKey)"
                  }) {
            scope = .agent(platform)
        } else {
            return nil
        }
        guard let slug = try? DefaultDistributionSlug(validating: action.slug) else {
            return nil
        }
        return DistributionTargetCatalog.current.entry(for: scope, slug: slug)
    }

    private func decodeBindingIntents(
        _ payload: Data,
        skillID: SkillID
    ) throws -> [DistributionBindingIntent] {
        try DistributionOperationPayloadCodec.decode(
            [DistributionBindingWireV2].self,
            from: payload
        ).map {
            try $0.intent(expectedSkillID: skillID)
        }
    }

    private func decodePersistedBindings(
        _ payload: Data,
        skillID: SkillID
    ) throws -> [DistributionBinding] {
        try DistributionOperationPayloadCodec.decode(
            [DistributionBindingWireV2].self,
            from: payload
        ).map {
            try $0.binding(expectedSkillID: skillID)
        }.sorted {
            distributionBindingIntentPrecedes($0.intent, $1.intent)
        }
    }
}
