import Foundation

extension SkillDistributionViewModel {
    var globalReaders: [SkillPlatform] {
        DistributionTargetCatalog.current.globalReaders
    }

    var hasUnappliedDraft: Bool {
        selectedAgents != currentEnabledAgents || selectedSyncMode != currentSyncMode
    }

    var willConvertGlobalToDedicated: Bool {
        currentBindings.contains { $0.scope == .global }
            && !selectedAgents.isEmpty
            && selectedAgents != Set(globalReaders)
    }

    var draftUsesGlobalTarget: Bool {
        selectedAgents == Set(globalReaders)
    }

    var agentRows: [AgentRow] {
        guard let distributionSlug else { return [] }
        let usesGlobal = selectedAgents == Set(globalReaders)
        return SkillPlatform.allCases.compactMap { platform in
            let scope: DistributionBindingScope = usesGlobal
                && platform.readsGlobalDistributionTarget
                ? .global
                : .agent(platform)
            return DistributionTargetCatalog.current.entry(
                for: scope,
                slug: distributionSlug
            ).map {
                AgentRow(
                    platform: platform,
                    locator: $0.canonicalLocator,
                    readsGlobalTarget: platform.readsGlobalDistributionTarget,
                    isCurrentlyEnabled: currentEnabledAgents.contains(platform),
                    isSelected: selectedAgents.contains(platform)
                )
            }
        }
    }

    func desiredConfiguration() -> DistributionDesiredConfiguration? {
        guard let distributionSlug else { return nil }
        let scope: DistributionDesiredScope
        if selectedAgents.isEmpty {
            scope = .disabled
        } else if selectedAgents == Set(globalReaders) {
            scope = .global(distributionSlug)
        } else {
            scope = .agents(selectedAgents, distributionSlug)
        }
        return DistributionDesiredConfiguration(
            scope: scope,
            syncMode: selectedSyncMode
        )
    }

    func requiredCodes(_ agents: Set<SkillPlatform>) -> Set<String> {
        Set(agents.map(\.storageKey))
    }

    func previewRows(
        plan: DistributionPlan,
        slug: DefaultDistributionSlug
    ) -> [PreviewRow] {
        if plan.status == .noOp {
            return currentBindings.compactMap { binding in
                DistributionTargetCatalog.current.entry(
                    for: binding.scope,
                    slug: slug
                ).map {
                    PreviewRow(
                        kind: .noChange,
                        scopeKey: binding.scope.targetScopeKey,
                        locator: $0.canonicalLocator
                    )
                }
            }
        }

        var rows = plan.filesystemActions.map { action in
            PreviewRow(
                kind: previewKind(action.kind),
                scopeKey: action.entry.target.scope.targetScopeKey,
                locator: action.entry.canonicalLocator
            )
        }
        let actionScopeKeys = Set(
            plan.filesystemActions.map(\.entry.target.scope.targetScopeKey)
        )
        rows.append(contentsOf: plan.bindingReplacement.compactMap { intent in
            guard !actionScopeKeys.contains(intent.scope.targetScopeKey) else {
                return nil
            }
            return DistributionTargetCatalog.current.entry(
                for: intent.scope,
                slug: intent.distributionSlug
            ).map {
                PreviewRow(
                    kind: currentBindings.contains(where: { $0.intent == intent })
                        ? .noChange
                        : .binding,
                    scopeKey: intent.scope.targetScopeKey,
                    locator: $0.canonicalLocator
                )
            }
        })
        if rows.isEmpty, plan.configurationChanged {
            rows.append(PreviewRow(
                kind: .configuration,
                scopeKey: "configuration",
                locator: "Skills Manager database"
            ))
        }
        return rows
    }

    func previewIsCurrent(_ preview: PendingPreview) -> Bool {
        preview.generation == refreshGeneration
            && activeSkillID == preview.skillID
            && desiredConfigurationMatches(preview.desiredConfiguration)
            && requiredCodes(selectedAgents) == preview.requiredAdapterCodes
    }

    func eligibleDriftDecisions(
        plan: DistributionPlan,
        skillID: SkillID,
        dependencies: SkillDistributionDependencies
    ) async throws -> [DriftDecision] {
        guard plan.status == .blocked else { return [] }
        var decisions: [DriftDecision] = []
        for conflict in plan.conflicts where conflict.reason == .copyContentDrift {
            guard !Task.isCancelled,
                  let binding = currentBindings.first(where: {
                      $0.scope.targetScopeKey == conflict.targetScopeKey
                          && $0.distributionSlug.collisionKey == conflict.slugKey
                  }) else {
                continue
            }
            do {
                let preview = try await dependencies.copyDriftPreview(
                    skillID,
                    binding.scope
                )
                decisions.append(DriftDecision(
                    scopeKey: conflict.targetScopeKey,
                    locator: conflict.canonicalLocator,
                    preview: preview
                ))
            } catch CopyForkError.notContentOnlyDrift {
                continue
            }
        }
        return decisions
    }

    private func desiredConfigurationMatches(
        _ expected: DistributionDesiredConfiguration
    ) -> Bool {
        guard let current = desiredConfiguration(),
              current.syncMode == expected.syncMode else {
            return false
        }
        return switch (current.scope, expected.scope) {
        case (.disabled, .disabled):
            true
        case (.global(let lhs), .global(let rhs)):
            lhs == rhs
        case (.agents(let lhsAgents, let lhsSlug),
              .agents(let rhsAgents, let rhsSlug)):
            lhsAgents == rhsAgents && lhsSlug == rhsSlug
        default:
            false
        }
    }

    private func previewKind(
        _ kind: DistributionFilesystemActionKind
    ) -> PreviewRow.Kind {
        switch kind {
        case .removeSymlink, .removeCopy:
            .remove
        case .createSymlink, .createCopy:
            .create
        case .refreshCopy, .discardCopyDrift:
            .refresh
        case .replaceSymlinkWithCopy, .replaceCopyWithSymlink:
            .replace
        }
    }
}
