import Foundation

nonisolated enum DistributionDesiredScope: Sendable {
    case disabled
    case global(DefaultDistributionSlug)
    case agents(Set<SkillPlatform>, DefaultDistributionSlug)

    var distributionSlug: DefaultDistributionSlug? {
        switch self {
        case .disabled: nil
        case .global(let slug), .agents(_, let slug): slug
        }
    }

    var requiredAdapterCodes: Set<String> {
        switch self {
        case .disabled:
            []
        case .global:
            Set(DistributionTargetCatalog.current.globalReaders.map(\.storageKey))
        case .agents(let adapters, _):
            Set(adapters.map(\.storageKey))
        }
    }
}

nonisolated struct DistributionDesiredConfiguration: Sendable {
    let scope: DistributionDesiredScope
    let syncMode: DistributionSyncMode

    init(
        scope: DistributionDesiredScope,
        syncMode: DistributionSyncMode
    ) {
        self.scope = scope
        self.syncMode = syncMode
    }
}

nonisolated struct DistributionSelectionReadback: Sendable {
    let bindings: [DistributionBinding]
    let isExplicitlyConfigured: Bool

    func desiredConfiguration(
        for skillID: SkillID
    ) throws -> DistributionDesiredConfiguration {
        try distributionDesiredConfiguration(
            bindings.map(\.intent),
            skillID: skillID
        )
    }

    func desiredScope(for skillID: SkillID) throws -> DistributionDesiredScope {
        let configuration = try desiredConfiguration(for: skillID)
        guard configuration.syncMode == .symlink else {
            throw DistributionSelectionError.invalidBindings
        }
        return configuration.scope
    }
}

nonisolated func distributionDesiredConfiguration(
    _ bindings: [DistributionBindingIntent],
    skillID: SkillID
) throws -> DistributionDesiredConfiguration {
    guard bindings.allSatisfy({ $0.skillID == skillID }),
          Set(bindings.map(\.syncMode)).count <= 1 else {
        throw DistributionSelectionError.invalidBindings
    }
    let mode = bindings.first?.syncMode ?? .symlink
    guard let slug = bindings.first?.distributionSlug else {
        return DistributionDesiredConfiguration(scope: .disabled, syncMode: mode)
    }
    guard bindings.allSatisfy({ $0.distributionSlug == slug }) else {
        throw DistributionSelectionError.invalidBindings
    }
    let scope: DistributionDesiredScope
    if bindings.count == 1, bindings[0].scope == .global {
        scope = .global(slug)
    } else {
        let agents = Set(bindings.compactMap(\.scope.adapter))
        guard agents.count == bindings.count else {
            throw DistributionSelectionError.invalidBindings
        }
        scope = .agents(agents, slug)
    }
    return DistributionDesiredConfiguration(scope: scope, syncMode: mode)
}

nonisolated enum DistributionSelectionError: Error {
    case invalidBindings
}
nonisolated enum DistributionTargetObservation: Hashable, Sendable {
    case missing
    case managed(skillID: SkillID, ssotDirectoryName: String)
    case copy(DistributionCopyObservation)
    case unknownObject
    case unavailable
}

nonisolated enum DistributionCopyObservationState: String, Hashable, Sendable {
    case inSync = "in_sync"
    case sourceChanged = "source_changed"
    case contentDrift = "content_drift"
    case physicalDrift = "physical_drift"
    case rootReplaced = "root_replaced"
    case targetReplaced = "target_replaced"
    case targetMissing = "target_missing"
    case baselineInvalid = "baseline_invalid"
}

nonisolated struct DistributionCopyConflictEvidence: Hashable, Sendable {
    let skillID: SkillID
    let baselineContentFingerprint: SkillContentFingerprint?
    let observedContentFingerprint: SkillContentFingerprint?
    let baselinePhysicalTreeDigest: CopyPhysicalTreeDigest?
    let observedPhysicalTreeDigest: CopyPhysicalTreeDigest?
    let baselineRootIdentity: ManagedItemIdentity?
    let observedRootIdentity: ManagedItemIdentity?
    let baselineEntryIdentity: ManagedItemIdentity?
    let observedEntryIdentity: ManagedItemIdentity?
}

nonisolated struct DistributionCopyObservation: Hashable, Sendable {
    let state: DistributionCopyObservationState
    let evidence: DistributionCopyConflictEvidence
}

nonisolated enum DistributionConflictReason: String, CaseIterable, Sendable {
    case invalidDesiredScope = "invalid_desired_scope"
    case unsupportedAdapter = "unsupported_adapter"
    case globalCoverageMismatch = "global_coverage_mismatch"
    case dedicatedTargetUnavailable = "dedicated_target_unavailable"
    case targetUnavailable = "target_unavailable"
    case currentBindingMissing = "current_binding_missing"
    case managedTargetMismatch = "managed_target_mismatch"
    case unknownObject = "unknown_object"
    case slugOccupied = "slug_occupied"
    case copyContentDrift = "copy_content_drift"
    case copyPhysicalDrift = "copy_physical_drift"
    case copyRootReplaced = "copy_root_replaced"
    case copyTargetReplaced = "copy_target_replaced"
    case copyTargetMissing = "copy_target_missing"
    case copyBaselineInvalid = "copy_baseline_invalid"

    var canonicalRank: Int {
        Self.allCases.firstIndex(of: self) ?? Self.allCases.count
    }
}

@MainActor
extension DistributionConflictReason {
    var localizedDisplayName: String {
        switch self {
        case .invalidDesiredScope: String(localized: "The selected scope is invalid.", bundle: SkillsManagerLocalizationResources.bundle)
        case .unsupportedAdapter: String(localized: "The selected Agent is unsupported.", bundle: SkillsManagerLocalizationResources.bundle)
        case .globalCoverageMismatch: String(localized: "The global Agent coverage is inconsistent.", bundle: SkillsManagerLocalizationResources.bundle)
        case .dedicatedTargetUnavailable: String(localized: "An Agent-specific target is unavailable.", bundle: SkillsManagerLocalizationResources.bundle)
        case .targetUnavailable: String(localized: "The target folder is unavailable.", bundle: SkillsManagerLocalizationResources.bundle)
        case .currentBindingMissing: String(localized: "A saved link is missing.", bundle: SkillsManagerLocalizationResources.bundle)
        case .managedTargetMismatch: String(localized: "The saved link points to a different managed Skill.", bundle: SkillsManagerLocalizationResources.bundle)
        case .unknownObject: String(localized: "An unmanaged item already exists at this target.", bundle: SkillsManagerLocalizationResources.bundle)
        case .slugOccupied: String(localized: "Another managed Skill already uses this name.", bundle: SkillsManagerLocalizationResources.bundle)
        case .copyContentDrift: String(localized: "The managed copy contains local content changes.", bundle: SkillsManagerLocalizationResources.bundle)
        case .copyPhysicalDrift: String(localized: "The managed copy contains unexpected files or permissions.", bundle: SkillsManagerLocalizationResources.bundle)
        case .copyRootReplaced: String(localized: "The managed copy root was replaced.", bundle: SkillsManagerLocalizationResources.bundle)
        case .copyTargetReplaced: String(localized: "The managed copy directory was replaced.", bundle: SkillsManagerLocalizationResources.bundle)
        case .copyTargetMissing: String(localized: "The managed copy is missing.", bundle: SkillsManagerLocalizationResources.bundle)
        case .copyBaselineInvalid: String(localized: "The managed copy baseline is unavailable or invalid.", bundle: SkillsManagerLocalizationResources.bundle)
        }
    }
}

nonisolated enum DistributionFilesystemActionKind: String, Sendable {
    case removeSymlink = "remove_symlink"
    case createSymlink = "create_symlink"
    case createCopy = "create_copy"
    case refreshCopy = "refresh_copy"
    case discardCopyDrift = "discard_copy_drift"
    case removeCopy = "remove_copy"
    case replaceSymlinkWithCopy = "replace_symlink_with_copy"
    case replaceCopyWithSymlink = "replace_copy_with_symlink"

    var canonicalRank: Int {
        switch self {
        case .removeSymlink, .removeCopy: 0
        case .refreshCopy, .discardCopyDrift,
             .replaceSymlinkWithCopy, .replaceCopyWithSymlink: 1
        case .createSymlink, .createCopy: 2
        }
    }
}

nonisolated struct DistributionFilesystemAction: Hashable, Sendable {
    let kind: DistributionFilesystemActionKind
    let entry: DistributionTargetEntry
    let ssotLocator: String
}

nonisolated struct DistributionPlanConflict: Hashable, Sendable {
    let reason: DistributionConflictReason
    let targetScopeKey: String
    let targetRank: Int
    let slugKey: String
    let canonicalLocator: String
    let copyEvidence: DistributionCopyConflictEvidence?

    init(
        reason: DistributionConflictReason,
        targetScopeKey: String,
        targetRank: Int,
        slugKey: String,
        canonicalLocator: String,
        copyEvidence: DistributionCopyConflictEvidence? = nil
    ) {
        self.reason = reason
        self.targetScopeKey = targetScopeKey
        self.targetRank = targetRank
        self.slugKey = slugKey
        self.canonicalLocator = canonicalLocator
        self.copyEvidence = copyEvidence
    }
}

nonisolated enum DistributionPlanStatus: String, Sendable {
    case executable
    case noOp = "no_op"
    case blocked
}

nonisolated enum DistributionRepairIntent: String, Sendable {
    case rebuildMissingSymlink = "rebuild_missing_symlink"
    case disableMissingBinding = "disable_missing_binding"
}

nonisolated struct DistributionPlan: Sendable {
    let status: DistributionPlanStatus
    let filesystemActions: [DistributionFilesystemAction]
    let bindingsChanged: Bool
    let bindingReplacement: [DistributionBindingIntent]
    let configurationChanged: Bool
    let expectedOldConfigured: Bool
    let desiredConfigured: Bool
    let conflicts: [DistributionPlanConflict]
    let repairIntent: DistributionRepairIntent?
    let repairScopeKeys: [String]

    init(
        status: DistributionPlanStatus,
        filesystemActions: [DistributionFilesystemAction],
        bindingsChanged: Bool,
        bindingReplacement: [DistributionBindingIntent],
        configurationChanged: Bool,
        expectedOldConfigured: Bool,
        desiredConfigured: Bool,
        conflicts: [DistributionPlanConflict],
        repairIntent: DistributionRepairIntent? = nil,
        repairScopeKeys: [String] = []
    ) {
        self.status = status
        self.filesystemActions = filesystemActions
        self.bindingsChanged = bindingsChanged
        self.bindingReplacement = bindingReplacement
        self.configurationChanged = configurationChanged
        self.expectedOldConfigured = expectedOldConfigured
        self.desiredConfigured = desiredConfigured
        self.conflicts = conflicts
        self.repairIntent = repairIntent
        self.repairScopeKeys = repairScopeKeys
    }

    func canonicalJSONData() throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return try encoder.encode(CanonicalDistributionPlan(self))
    }

    func canonicalJSONString() throws -> String {
        String(decoding: try canonicalJSONData(), as: UTF8.self)
    }
}

nonisolated func distributionActionPrecedes(
    _ lhs: DistributionFilesystemAction,
    _ rhs: DistributionFilesystemAction
) -> Bool {
    if lhs.kind.canonicalRank != rhs.kind.canonicalRank {
        return lhs.kind.canonicalRank < rhs.kind.canonicalRank
    }
    if lhs.entry.target.rank != rhs.entry.target.rank {
        return lhs.entry.target.rank < rhs.entry.target.rank
    }
    if lhs.entry.slugKey != rhs.entry.slugKey {
        return utf8Precedes(lhs.entry.slugKey, rhs.entry.slugKey)
    }
    return utf8Precedes(lhs.entry.canonicalLocator, rhs.entry.canonicalLocator)
}

nonisolated func distributionConflictPrecedes(
    _ lhs: DistributionPlanConflict,
    _ rhs: DistributionPlanConflict
) -> Bool {
    if lhs.reason.canonicalRank != rhs.reason.canonicalRank {
        return lhs.reason.canonicalRank < rhs.reason.canonicalRank
    }
    if lhs.targetRank != rhs.targetRank {
        return lhs.targetRank < rhs.targetRank
    }
    if lhs.slugKey != rhs.slugKey {
        return utf8Precedes(lhs.slugKey, rhs.slugKey)
    }
    if lhs.canonicalLocator != rhs.canonicalLocator {
        return utf8Precedes(lhs.canonicalLocator, rhs.canonicalLocator)
    }
    return utf8Precedes(lhs.targetScopeKey, rhs.targetScopeKey)
}

private nonisolated struct CanonicalDistributionPlan: Encodable {
    let status: String
    let filesystemActions: [CanonicalDistributionAction]
    let bindingsChanged: Bool
    let bindingReplacement: [CanonicalDistributionBinding]
    let configurationChanged: Bool
    let expectedOldConfigured: Bool
    let desiredConfigured: Bool
    let conflicts: [CanonicalDistributionConflict]
    let repairIntent: String?
    let repairScopeKeys: [String]?

    enum CodingKeys: String, CodingKey {
        case status
        case filesystemActions = "filesystem_actions"
        case bindingsChanged = "bindings_changed"
        case bindingReplacement = "binding_replacement"
        case configurationChanged = "configuration_changed"
        case expectedOldConfigured = "expected_old_configured"
        case desiredConfigured = "desired_configured"
        case conflicts
        case repairIntent = "repair_intent"
        case repairScopeKeys = "repair_scope_keys"
    }

    init(_ plan: DistributionPlan) {
        status = plan.status.rawValue
        filesystemActions = plan.filesystemActions
            .sorted(by: distributionActionPrecedes)
            .map(CanonicalDistributionAction.init)
        bindingsChanged = plan.bindingsChanged
        bindingReplacement = plan.bindingReplacement
            .sorted(by: distributionBindingIntentPrecedes)
            .map(CanonicalDistributionBinding.init)
        configurationChanged = plan.configurationChanged
        expectedOldConfigured = plan.expectedOldConfigured
        desiredConfigured = plan.desiredConfigured
        conflicts = plan.conflicts
            .sorted(by: distributionConflictPrecedes)
            .map(CanonicalDistributionConflict.init)
        repairIntent = plan.repairIntent?.rawValue
        repairScopeKeys = plan.repairIntent == nil
            ? nil : plan.repairScopeKeys.sorted(by: utf8Precedes)
    }
}

private nonisolated struct CanonicalDistributionAction: Encodable {
    let action: String
    let targetScopeKey: String
    let targetLocator: String
    let ssotLocator: String

    enum CodingKeys: String, CodingKey {
        case action
        case targetScopeKey = "target_scope_key"
        case targetLocator = "target_locator"
        case ssotLocator = "ssot_locator"
    }

    init(_ action: DistributionFilesystemAction) {
        self.action = action.kind.rawValue
        targetScopeKey = action.entry.target.scope.targetScopeKey
        targetLocator = action.entry.canonicalLocator
        ssotLocator = action.ssotLocator
    }
}

private nonisolated struct CanonicalDistributionBinding: Encodable {
    let skillID: String
    let scopeKind: String
    let adapterCode: String?
    let targetScopeKey: String
    let distributionSlug: String
    let slugKey: String
    let syncMode: String

    enum CodingKeys: String, CodingKey {
        case skillID = "skill_id"
        case scopeKind = "scope_kind"
        case adapterCode = "adapter_code"
        case targetScopeKey = "target_scope_key"
        case distributionSlug = "distribution_slug"
        case slugKey = "slug_key"
        case syncMode = "sync_mode"
    }

    init(_ binding: DistributionBindingIntent) {
        skillID = binding.skillID.directoryName
        scopeKind = binding.scope.kind
        adapterCode = binding.scope.adapter?.storageKey
        targetScopeKey = binding.scope.targetScopeKey
        distributionSlug = binding.distributionSlug.value
        slugKey = binding.distributionSlug.collisionKey
        syncMode = binding.syncMode.rawValue
    }
}

private nonisolated struct CanonicalDistributionConflict: Encodable {
    let reason: String
    let targetScopeKey: String
    let slugKey: String
    let targetLocator: String
    let copyEvidence: CanonicalCopyConflictEvidence?

    enum CodingKeys: String, CodingKey {
        case reason
        case targetScopeKey = "target_scope_key"
        case slugKey = "slug_key"
        case targetLocator = "target_locator"
        case copyEvidence = "copy_evidence"
    }

    init(_ conflict: DistributionPlanConflict) {
        reason = conflict.reason.rawValue
        targetScopeKey = conflict.targetScopeKey
        slugKey = conflict.slugKey
        targetLocator = conflict.canonicalLocator
        copyEvidence = conflict.copyEvidence.map(CanonicalCopyConflictEvidence.init)
    }
}

private nonisolated struct CanonicalCopyConflictEvidence: Encodable {
    let skillID: String
    let baselineContentAlgorithm: Int?
    let baselineContentDigest: Data?
    let observedContentAlgorithm: Int?
    let observedContentDigest: Data?
    let baselineTreeAlgorithm: Int?
    let baselineTreeDigest: Data?
    let observedTreeAlgorithm: Int?
    let observedTreeDigest: Data?
    let baselineRootIdentity: Data?
    let observedRootIdentity: Data?
    let baselineEntryIdentity: Data?
    let observedEntryIdentity: Data?

    enum CodingKeys: String, CodingKey {
        case skillID = "skill_id"
        case baselineContentAlgorithm = "baseline_content_algorithm"
        case baselineContentDigest = "baseline_content_digest"
        case observedContentAlgorithm = "observed_content_algorithm"
        case observedContentDigest = "observed_content_digest"
        case baselineTreeAlgorithm = "baseline_tree_algorithm"
        case baselineTreeDigest = "baseline_tree_digest"
        case observedTreeAlgorithm = "observed_tree_algorithm"
        case observedTreeDigest = "observed_tree_digest"
        case baselineRootIdentity = "baseline_root_identity"
        case observedRootIdentity = "observed_root_identity"
        case baselineEntryIdentity = "baseline_entry_identity"
        case observedEntryIdentity = "observed_entry_identity"
    }

    init(_ evidence: DistributionCopyConflictEvidence) {
        skillID = evidence.skillID.directoryName
        baselineContentAlgorithm = evidence.baselineContentFingerprint?.algorithmVersion
        baselineContentDigest = evidence.baselineContentFingerprint?.digest
        observedContentAlgorithm = evidence.observedContentFingerprint?.algorithmVersion
        observedContentDigest = evidence.observedContentFingerprint?.digest
        baselineTreeAlgorithm = evidence.baselinePhysicalTreeDigest?.algorithmVersion
        baselineTreeDigest = evidence.baselinePhysicalTreeDigest?.digest
        observedTreeAlgorithm = evidence.observedPhysicalTreeDigest?.algorithmVersion
        observedTreeDigest = evidence.observedPhysicalTreeDigest?.digest
        baselineRootIdentity = evidence.baselineRootIdentity.flatMap {
            try? ManagedItemIdentityCodec.encode($0)
        }
        observedRootIdentity = evidence.observedRootIdentity.flatMap {
            try? ManagedItemIdentityCodec.encode($0)
        }
        baselineEntryIdentity = evidence.baselineEntryIdentity.flatMap {
            try? ManagedItemIdentityCodec.encode($0)
        }
        observedEntryIdentity = evidence.observedEntryIdentity.flatMap {
            try? ManagedItemIdentityCodec.encode($0)
        }
    }
}

nonisolated func utf8Precedes(_ lhs: String, _ rhs: String) -> Bool {
    lhs.utf8.lexicographicallyPrecedes(rhs.utf8)
}
