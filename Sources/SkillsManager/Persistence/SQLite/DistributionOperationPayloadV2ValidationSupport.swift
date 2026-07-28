import Foundation

nonisolated extension DistributionOperationPayloadV2Validator {
    static func validatePlanV2(
        _ data: Data,
        skillID: SkillID,
        oldBindings: [DistributionBindingWireV2],
        newBindings: [DistributionBindingWireV2]
    ) throws -> DistributionPlanWire {
        let plan = try decodePlanV2(data)
        guard let expectedConfigured = plan.expectedOldConfigured,
              let desiredConfigured = plan.desiredConfigured,
              plan.configurationChanged
                == (expectedConfigured != desiredConfigured) else {
            throw DistributionOperationStoreError.invalidRecord
        }
        let old = try oldBindings.map {
            try $0.intent(expectedSkillID: skillID)
        }
        let new = try newBindings.map {
            try $0.intent(expectedSkillID: skillID)
        }
        let replacement = try plan.bindingReplacement.map {
            try planIntentV2($0, skillID: skillID)
        }
        guard plan.bindingReplacement.count == new.count,
              Set(replacement) == Set(new),
              plan.bindingsChanged == (Set(old) != Set(new)),
              !plan.filesystemActions.isEmpty
                || plan.bindingsChanged
                || plan.configurationChanged == true else {
            throw DistributionOperationStoreError.invalidRecord
        }
        try validatePlanActionsV2(
            plan.filesystemActions,
            skillID: skillID,
            old: old,
            new: new
        )
        return plan
    }

    static func planActionsV2(
        _ data: Data
    ) throws -> [DistributionPlanActionWire] {
        try decodePlanV2(data).filesystemActions
    }

    private static func decodePlanV2(_ data: Data) throws -> DistributionPlanWire {
        let plan = try DistributionOperationPayloadCodec.decode(
            DistributionPlanWire.self,
            from: data
        )
        guard try DistributionOperationPayloadCodec.encode(plan) == data,
              plan.status == DistributionPlanStatus.executable.rawValue,
              plan.conflicts.isEmpty,
              plan.filesystemActions.count <= 8 else {
            throw DistributionOperationStoreError.invalidRecord
        }
        return plan
    }

    private static func planIntentV2(
        _ wire: DistributionPlanBindingWire,
        skillID: SkillID
    ) throws -> DistributionBindingIntent {
        guard wire.skillID == skillID.directoryName,
              let mode = DistributionSyncMode(rawValue: wire.syncMode),
              let slug = try? DefaultDistributionSlug(
                  validating: wire.distributionSlug
              ),
              slug.collisionKey == wire.slugKey else {
            throw DistributionOperationStoreError.invalidRecord
        }
        let scope: DistributionBindingScope
        switch wire.scopeKind {
        case "global":
            guard wire.adapterCode == nil, wire.targetScopeKey == "global" else {
                throw DistributionOperationStoreError.invalidRecord
            }
            scope = .global
        case "agent":
            guard let adapter = wire.adapterCode,
                  let platform = SkillPlatform.allCases.first(where: {
                      $0.storageKey == adapter
                  }),
                  wire.targetScopeKey == "agent:\(adapter)" else {
                throw DistributionOperationStoreError.invalidRecord
            }
            scope = .agent(platform)
        default:
            throw DistributionOperationStoreError.invalidRecord
        }
        return DistributionBindingIntent(
            skillID: skillID,
            scope: scope,
            distributionSlug: slug,
            syncMode: mode
        )
    }

    private static func validatePlanActionsV2(
        _ actions: [DistributionPlanActionWire],
        skillID: SkillID,
        old: [DistributionBindingIntent],
        new: [DistributionBindingIntent]
    ) throws {
        var actionKinds: [String: DistributionFilesystemActionKind] = [:]
        for action in actions {
            guard let kind = DistributionFilesystemActionKind(
                rawValue: action.action
            ), let scope = scopeV2(action.targetScopeKey),
                  let slug = slugV2(action.targetLocator, scope: scope),
                  action.ssotLocator
                    == DistributionTargetCatalog.current.ssotLocator(for: skillID),
                  actionKinds.updateValue(
                      kind,
                      forKey: bindingKeyV2(scope: scope, slug: slug)
                  ) == nil else {
                throw DistributionOperationStoreError.invalidRecord
            }
        }
        guard Set(actions.map(\.targetScopeKey)).count <= 5 else {
            throw DistributionOperationStoreError.invalidRecord
        }
        let oldByKey = Dictionary(uniqueKeysWithValues: old.map {
            (bindingKeyV2(scope: $0.scope, slug: $0.distributionSlug), $0)
        })
        let newByKey = Dictionary(uniqueKeysWithValues: new.map {
            (bindingKeyV2(scope: $0.scope, slug: $0.distributionSlug), $0)
        })
        let bindingKeys = Set(oldByKey.keys).union(newByKey.keys)
        guard Set(actionKinds.keys).isSubset(of: bindingKeys) else {
            throw DistributionOperationStoreError.invalidRecord
        }
        for key in bindingKeys {
            let oldIntent = oldByKey[key]
            let newIntent = newByKey[key]
            let expected: DistributionFilesystemActionKind? = switch (
                oldIntent?.syncMode,
                newIntent?.syncMode
            ) {
            case (nil, .symlink): .createSymlink
            case (nil, .copy): .createCopy
            case (.symlink, nil): .removeSymlink
            case (.copy, nil): .removeCopy
            case (.symlink, .copy): .replaceSymlinkWithCopy
            case (.copy, .symlink): .replaceCopyWithSymlink
            case (.copy, .copy): actionKinds[key] == .refreshCopy
                ? .refreshCopy : nil
            case (.symlink, .symlink): nil
            case (nil, nil): nil
            }
            guard actionKinds[key] == expected else {
                throw DistributionOperationStoreError.invalidRecord
            }
        }
    }

    private static func scopeV2(
        _ key: String
    ) -> DistributionBindingScope? {
        if key == "global" { return .global }
        return SkillPlatform.allCases.first {
            key == "agent:\($0.storageKey)"
        }.map(DistributionBindingScope.agent)
    }

    private static func slugV2(
        _ locator: String,
        scope: DistributionBindingScope
    ) -> DefaultDistributionSlug? {
        guard let target = DistributionTargetCatalog.current.target(for: scope),
              locator.hasPrefix(target.rootLocator + "/"),
              let slug = try? DefaultDistributionSlug(
                  validating: String(
                      locator.dropFirst(target.rootLocator.count + 1)
                  )
              ),
              locator == target.rootLocator + "/" + slug.value else {
            return nil
        }
        return slug
    }

    private static func bindingKeyV2(
        scope: DistributionBindingScope,
        slug: DefaultDistributionSlug
    ) -> String {
        "\(scope.targetScopeKey)\u{0}\(slug.collisionKey)"
    }

    static func validatePreflightAction(
        _ action: DistributionOperationPreflightActionV2,
        planAction: DistributionPlanActionWire,
        skillID: SkillID,
        oldBindings: [DistributionBindingWireV2],
        operationID: SSOTOperationID
    ) throws {
        guard let scope = scopeV2(planAction.targetScopeKey),
              let planSlug = slugV2(planAction.targetLocator, scope: scope),
              action.kind == planAction.action,
              action.targetScopeKey == planAction.targetScopeKey,
              action.slug == planSlug.value,
              planAction.ssotLocator
                == DistributionTargetCatalog.current.ssotLocator(for: skillID)
        else {
            throw DistributionOperationStoreError.invalidRecord
        }
        guard validScopeKey(action.targetScopeKey),
              (try? DefaultDistributionSlug(validating: action.slug)) != nil,
              action.rootIdentity == nil
                || (try? ManagedItemIdentityCodec.decode(action.rootIdentity!)) != nil else {
            throw DistributionOperationStoreError.invalidRecord
        }
        _ = try action.oldCopy?.evidence()
        _ = try action.oldLink?.evidence()
        let oldBinding = try oldBindings.first {
            let intent = try $0.intent(expectedSkillID: skillID)
            return intent.scope == scope
                && intent.distributionSlug == planSlug
        }
        let oldCopyMatches = if let evidence = action.oldCopy,
                                let baseline = oldBinding?.copyBaseline {
            evidence.content == baseline.content
                && evidence.physicalTree == baseline.physicalTree
                && evidence.rootIdentity == baseline.rootIdentity
                && evidence.entryIdentity == baseline.entryIdentity
        } else {
            action.oldCopy == nil
        }
        guard oldCopyMatches,
              action.oldLink == nil
                || oldBinding?.syncMode == DistributionSyncMode.symlink.rawValue,
              action.oldCopy != nil || action.oldLink != nil
                || oldBinding == nil else {
            throw DistributionOperationStoreError.invalidRecord
        }
        guard action.oldCopy == nil
                || action.rootIdentity == action.oldCopy?.rootIdentity,
              action.oldLink == nil
                || action.rootIdentity == action.oldLink?.rootIdentity else {
            throw DistributionOperationStoreError.invalidRecord
        }
        let copyStage = DistributionSymlinkFileSystem.copyTemporaryName(
            operationID: operationID.uuid,
            actionIndex: action.actionIndex,
            suffix: "staging"
        )
        let copyQuarantine = DistributionSymlinkFileSystem.copyTemporaryName(
            operationID: operationID.uuid,
            actionIndex: action.actionIndex,
            suffix: "quarantine"
        )
        let linkQuarantine = DistributionSymlinkFileSystem.temporaryName(
            operationID: operationID.uuid,
            actionIndex: action.actionIndex
        )
        let valid = switch DistributionFilesystemActionKind(rawValue: action.kind) {
        case .createSymlink:
            action.oldCopy == nil && action.oldLink == nil
                && action.stagingName == nil && action.quarantineName == nil
        case .removeSymlink:
            action.oldCopy == nil && action.oldLink != nil
                && action.stagingName == nil && action.quarantineName == linkQuarantine
        case .createCopy:
            action.oldCopy == nil && action.oldLink == nil
                && action.stagingName == copyStage && action.quarantineName == nil
        case .refreshCopy:
            action.oldCopy != nil && action.oldLink == nil
                && action.stagingName == copyStage
                && action.quarantineName == copyQuarantine
        case .removeCopy:
            action.oldCopy != nil && action.oldLink == nil
                && action.stagingName == nil
                && action.quarantineName == copyQuarantine
        case .replaceSymlinkWithCopy:
            action.oldCopy == nil && action.oldLink != nil
                && action.stagingName == copyStage
                && action.quarantineName == linkQuarantine
        case .replaceCopyWithSymlink:
            action.oldCopy != nil && action.oldLink == nil
                && action.stagingName == nil
                && action.quarantineName == copyQuarantine
        case nil:
            false
        }
        guard valid else { throw DistributionOperationStoreError.invalidRecord }
    }

    static func validateRuntimeAction(
        _ action: DistributionOperationRuntimeActionV2,
        kind: String,
        preflight: DistributionOperationPreflightActionV2,
        source: DistributionOperationPreflightV2
    ) throws {
        _ = try action.stagedCopy?.evidence()
        _ = try action.createdCopy?.evidence()
        _ = try action.createdLink?.evidence()
        _ = try action.quarantinedCopy?.evidence()
        _ = try action.quarantinedLink?.evidence()
        if let staged = action.stagedCopy {
            guard staged.content == source.sourceContent,
                  staged.physicalTree == source.sourcePhysicalTree,
                  preflight.rootIdentity == nil
                    || staged.rootIdentity == preflight.rootIdentity else {
                throw DistributionOperationStoreError.invalidRecord
            }
        }
        guard action.createdCopy == nil
                || action.createdCopy == action.stagedCopy,
              action.quarantinedCopy == nil
                || action.quarantinedCopy == preflight.oldCopy,
              action.quarantinedLink == nil
                || action.quarantinedLink == preflight.oldLink else {
            throw DistributionOperationStoreError.invalidRecord
        }
        if let created = action.createdLink {
            guard created.absoluteTarget == source.absoluteSSOTTarget,
                  preflight.rootIdentity == nil
                    || created.rootIdentity == preflight.rootIdentity else {
                throw DistributionOperationStoreError.invalidRecord
            }
        }
        let actionKind = DistributionFilesystemActionKind(rawValue: kind)
        let copyCreator = actionKind == .createCopy || actionKind == .refreshCopy
            || actionKind == .replaceSymlinkWithCopy
        let linkCreator = actionKind == .createSymlink
            || actionKind == .replaceCopyWithSymlink
        let copyRemoval = actionKind == .refreshCopy || actionKind == .removeCopy
            || actionKind == .replaceCopyWithSymlink
        let linkRemoval = actionKind == .removeSymlink
            || actionKind == .replaceSymlinkWithCopy
        guard (!copyCreator
                ? action.stagedCopy == nil && action.createdCopy == nil : true),
              !linkCreator ? action.createdLink == nil : true,
              !copyRemoval ? action.quarantinedCopy == nil : true,
              !linkRemoval ? action.quarantinedLink == nil : true,
              pending(action.pending, isValidFor: actionKind) else {
            throw DistributionOperationStoreError.invalidRecord
        }
    }

    static func hasAppliedEvidence(
        _ action: DistributionOperationRuntimeActionV2,
        kind: String
    ) -> Bool {
        guard action.pending == nil else { return false }
        return switch DistributionFilesystemActionKind(rawValue: kind) {
        case .createSymlink: action.createdLink != nil
        case .removeSymlink: action.quarantinedLink != nil
        case .createCopy: action.createdCopy != nil
        case .refreshCopy:
            action.createdCopy != nil && action.quarantinedCopy != nil
        case .removeCopy: action.quarantinedCopy != nil
        case .replaceSymlinkWithCopy:
            action.createdCopy != nil && action.quarantinedLink != nil
        case .replaceCopyWithSymlink:
            action.createdLink != nil && action.quarantinedCopy != nil
        case nil: false
        }
    }

    static func pending(
        _ pending: DistributionOperationPendingKindV2?,
        isValidFor kind: DistributionFilesystemActionKind?
    ) -> Bool {
        guard let pending else { return true }
        return switch pending {
        case .stageCopy, .promoteCopy:
            kind == .createCopy || kind == .refreshCopy
                || kind == .replaceSymlinkWithCopy
        case .quarantineCopy:
            kind == .refreshCopy || kind == .removeCopy
                || kind == .replaceCopyWithSymlink
        case .quarantineSymlink:
            kind == .removeSymlink || kind == .replaceSymlinkWithCopy
        case .createSymlink:
            kind == .createSymlink || kind == .replaceCopyWithSymlink
        }
    }

    static func validScopeKey(_ value: String) -> Bool {
        value == "global" || SkillPlatform.allCases.contains {
            value == "agent:\($0.storageKey)"
        }
    }

    static func isEmptyRuntimeAction(
        _ action: DistributionOperationRuntimeActionV2
    ) -> Bool {
        action.pending == nil && action.stagedCopy == nil
            && action.createdCopy == nil && action.createdLink == nil
            && action.quarantinedCopy == nil && action.quarantinedLink == nil
    }
}
