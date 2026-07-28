import Foundation

nonisolated struct DistributionFingerprintWireV2: Codable, Equatable, Sendable {
    let algorithmVersion: Int
    let digest: Data

    init(_ fingerprint: SkillContentFingerprint) {
        algorithmVersion = fingerprint.algorithmVersion
        digest = fingerprint.digest
    }

    func fingerprint() throws -> SkillContentFingerprint {
        try SkillContentFingerprint(algorithmVersion: algorithmVersion, digest: digest)
    }
}

nonisolated struct DistributionTreeDigestWireV2: Codable, Equatable, Sendable {
    let algorithmVersion: Int
    let digest: Data

    init(_ value: CopyPhysicalTreeDigest) {
        algorithmVersion = value.algorithmVersion
        digest = value.digest
    }

    func treeDigest() throws -> CopyPhysicalTreeDigest {
        try CopyPhysicalTreeDigest(algorithmVersion: algorithmVersion, digest: digest)
    }
}

nonisolated struct DistributionCopyBaselineWireV2: Codable, Equatable, Sendable {
    let content: DistributionFingerprintWireV2
    let physicalTree: DistributionTreeDigestWireV2
    let rootIdentity: Data
    let entryIdentity: Data
    let appliedOperationID: Data
    let verifiedAtMilliseconds: Int64

    init(_ baseline: DistributionCopyBaseline) throws {
        content = DistributionFingerprintWireV2(baseline.contentFingerprint)
        physicalTree = DistributionTreeDigestWireV2(baseline.physicalTreeDigest)
        rootIdentity = try ManagedItemIdentityCodec.encode(baseline.rootIdentity)
        entryIdentity = try ManagedItemIdentityCodec.encode(baseline.entryIdentity)
        appliedOperationID = baseline.appliedOperationID.bytes
        verifiedAtMilliseconds = baseline.verifiedAtMilliseconds
    }

    func baseline() throws -> DistributionCopyBaseline {
        try DistributionCopyBaseline(
            contentFingerprint: content.fingerprint(),
            physicalTreeDigest: physicalTree.treeDigest(),
            rootIdentity: ManagedItemIdentityCodec.decode(rootIdentity),
            entryIdentity: ManagedItemIdentityCodec.decode(entryIdentity),
            appliedOperationID: SSOTOperationID(bytes: appliedOperationID),
            verifiedAtMilliseconds: verifiedAtMilliseconds
        )
    }
}

nonisolated struct DistributionBindingWireV2: Codable, Equatable, Sendable {
    let skillID: String
    let scope: String
    let adapter: String?
    let slug: String
    let syncMode: String
    let copyBaseline: DistributionCopyBaselineWireV2?
    let createdAtMilliseconds: Int64?
    let updatedAtMilliseconds: Int64?

    init(_ intent: DistributionBindingIntent) {
        skillID = intent.skillID.directoryName
        switch intent.scope {
        case .global:
            scope = "global"
            adapter = nil
        case .agent(let platform):
            scope = "agent"
            adapter = platform.storageKey
        }
        slug = intent.distributionSlug.value
        syncMode = intent.syncMode.rawValue
        copyBaseline = nil
        createdAtMilliseconds = nil
        updatedAtMilliseconds = nil
    }

    init(_ binding: DistributionBinding) throws {
        skillID = binding.skillID.directoryName
        switch binding.scope {
        case .global:
            scope = "global"
            adapter = nil
        case .agent(let platform):
            scope = "agent"
            adapter = platform.storageKey
        }
        slug = binding.distributionSlug.value
        syncMode = binding.syncMode.rawValue
        copyBaseline = try binding.copyBaseline.map(DistributionCopyBaselineWireV2.init)
        createdAtMilliseconds = binding.createdAtMilliseconds
        updatedAtMilliseconds = binding.updatedAtMilliseconds
    }

    func intent(expectedSkillID: SkillID) throws -> DistributionBindingIntent {
        guard skillID == expectedSkillID.directoryName,
              let mode = DistributionSyncMode(rawValue: syncMode) else {
            throw DistributionOperationStoreError.invalidRecord
        }
        let bindingScope: DistributionBindingScope
        switch scope {
        case "global" where adapter == nil:
            bindingScope = .global
        case "agent":
            guard let adapter,
                  let platform = SkillPlatform.allCases.first(where: {
                      $0.storageKey == adapter
                  }) else {
                throw DistributionOperationStoreError.invalidRecord
            }
            bindingScope = .agent(platform)
        default:
            throw DistributionOperationStoreError.invalidRecord
        }
        return DistributionBindingIntent(
            skillID: expectedSkillID,
            scope: bindingScope,
            distributionSlug: try DefaultDistributionSlug(validating: slug),
            syncMode: mode
        )
    }

    func binding(expectedSkillID: SkillID) throws -> DistributionBinding {
        guard let createdAtMilliseconds, let updatedAtMilliseconds else {
            throw DistributionOperationStoreError.invalidRecord
        }
        let intent = try intent(expectedSkillID: expectedSkillID)
        return try DistributionBinding(
            skillID: expectedSkillID,
            scope: intent.scope,
            distributionSlug: intent.distributionSlug,
            syncMode: intent.syncMode,
            copyBaseline: try copyBaseline?.baseline(),
            createdAtMilliseconds: createdAtMilliseconds,
            updatedAtMilliseconds: updatedAtMilliseconds
        )
    }
}

nonisolated struct DistributionCopyEvidenceWireV2: Codable, Equatable, Sendable {
    let rootIdentity: Data
    let entryIdentity: Data
    let content: DistributionFingerprintWireV2
    let physicalTree: DistributionTreeDigestWireV2

    init(_ evidence: DistributionCopyEvidence) throws {
        rootIdentity = try ManagedItemIdentityCodec.encode(evidence.rootIdentity)
        entryIdentity = try ManagedItemIdentityCodec.encode(evidence.entryIdentity)
        content = DistributionFingerprintWireV2(evidence.contentFingerprint)
        physicalTree = DistributionTreeDigestWireV2(evidence.physicalTreeDigest)
    }

    func evidence() throws -> DistributionCopyEvidence {
        try DistributionCopyEvidence(
            rootIdentity: ManagedItemIdentityCodec.decode(rootIdentity),
            entryIdentity: ManagedItemIdentityCodec.decode(entryIdentity),
            contentFingerprint: content.fingerprint(),
            physicalTreeDigest: physicalTree.treeDigest()
        )
    }
}

nonisolated struct DistributionLinkEvidenceWireV2: Codable, Equatable, Sendable {
    let rootIdentity: Data
    let entryIdentity: Data
    let absoluteTarget: String

    init(_ evidence: DistributionSymlinkEvidence) throws {
        rootIdentity = try ManagedItemIdentityCodec.encode(evidence.rootIdentity)
        entryIdentity = try ManagedItemIdentityCodec.encode(evidence.entryIdentity)
        absoluteTarget = evidence.absoluteTarget
    }

    func evidence() throws -> DistributionSymlinkEvidence {
        DistributionSymlinkEvidence(
            rootIdentity: try ManagedItemIdentityCodec.decode(rootIdentity),
            entryIdentity: try ManagedItemIdentityCodec.decode(entryIdentity),
            absoluteTarget: absoluteTarget
        )
    }
}

nonisolated struct DistributionOperationPreflightActionV2:
    Codable, Equatable, Sendable
{
    let actionIndex: Int
    let kind: String
    let targetScopeKey: String
    let slug: String
    let rootIdentity: Data?
    let oldCopy: DistributionCopyEvidenceWireV2?
    let oldLink: DistributionLinkEvidenceWireV2?
    let stagingName: String?
    let quarantineName: String?
}

nonisolated struct DistributionOperationPreflightV2: Codable, Equatable, Sendable {
    let wireVersion: Int
    let skillID: String
    let ssotIdentity: Data
    let absoluteSSOTTarget: String
    let sourceContent: DistributionFingerprintWireV2
    let sourcePhysicalTree: DistributionTreeDigestWireV2
    let expectedOldConfigured: Bool
    let desiredConfigured: Bool
    let actions: [DistributionOperationPreflightActionV2]
}

nonisolated enum DistributionOperationPendingKindV2: String, Codable, Sendable {
    case stageCopy
    case quarantineCopy
    case quarantineSymlink
    case promoteCopy
    case createSymlink
}

nonisolated struct DistributionOperationRuntimeActionV2:
    Codable, Equatable, Sendable
{
    let actionIndex: Int
    var pending: DistributionOperationPendingKindV2?
    var stagedCopy: DistributionCopyEvidenceWireV2?
    var createdCopy: DistributionCopyEvidenceWireV2?
    var createdLink: DistributionLinkEvidenceWireV2?
    var quarantinedCopy: DistributionCopyEvidenceWireV2?
    var quarantinedLink: DistributionLinkEvidenceWireV2?
}

nonisolated struct DistributionOperationRuntimeV2: Codable, Equatable, Sendable {
    let wireVersion: Int
    var actions: [DistributionOperationRuntimeActionV2]
}

nonisolated enum DistributionOperationPayloadV2Validator {
    static func validate(
        operationID: SSOTOperationID,
        skillID: SkillID,
        oldBindingsData: Data,
        newBindingsData: Data,
        planData: Data,
        preflightData: Data,
        runtimeData: Data,
        phase: DistributionOperationPhase,
        outcome: DistributionOperationOutcome?,
        forwardCursor: Int64,
        rollbackCursor: Int64,
        cleanupCursor: Int64
    ) throws {
        let old = try decodeBindings(oldBindingsData)
        let new = try decodeBindings(newBindingsData)
        try validatePersistedBindings(old, skillID: skillID)
        if phase == .filesystemApplied || phase == .databaseCommitted
            || phase == .cleaning
            || (phase == .completed && outcome == .applied) {
            try validatePersistedBindings(new, skillID: skillID)
        } else {
            try validateDesiredBindings(new, skillID: skillID)
        }
        let plan = try validatePlanV2(
            planData,
            skillID: skillID,
            oldBindings: old,
            newBindings: new
        )
        let actionKinds = plan.filesystemActions.map(\.action)
        let preflight = try DistributionOperationPayloadCodec.decode(
            DistributionOperationPreflightV2.self,
            from: preflightData
        )
        guard try DistributionOperationPayloadCodec.encode(preflight) == preflightData,
              preflight.wireVersion == 2,
              preflight.skillID == skillID.directoryName,
              URL(fileURLWithPath: preflight.absoluteSSOTTarget)
                .standardizedFileURL.path == preflight.absoluteSSOTTarget,
              preflight.absoluteSSOTTarget.hasSuffix(
                "/.SkillsManager/skills/\(skillID.directoryName)"
              ),
              (try? ManagedItemIdentityCodec.decode(preflight.ssotIdentity)) != nil,
              (try? preflight.sourceContent.fingerprint()) != nil,
              (try? preflight.sourcePhysicalTree.treeDigest()) != nil,
              preflight.actions.count == actionKinds.count,
              preflight.actions.enumerated().allSatisfy({
                  $0.offset == $0.element.actionIndex
                      && $0.element.kind == actionKinds[$0.offset]
              }) else {
            throw DistributionOperationStoreError.invalidRecord
        }
        for (index, action) in preflight.actions.enumerated() {
            try validatePreflightAction(
                action,
                planAction: plan.filesystemActions[index],
                skillID: skillID,
                oldBindings: old,
                operationID: operationID
            )
        }
        try validateRuntime(
            runtimeData,
            planData: planData,
            preflightData: preflightData,
            forwardCursor: forwardCursor,
            rollbackCursor: rollbackCursor,
            cleanupCursor: cleanupCursor,
            phase: phase,
            outcome: outcome
        )
    }

    static func validateRuntime(
        _ runtimeData: Data,
        planData: Data,
        preflightData: Data,
        forwardCursor: Int64,
        rollbackCursor: Int64,
        cleanupCursor: Int64,
        phase: DistributionOperationPhase,
        outcome: DistributionOperationOutcome? = nil
    ) throws {
        let actionKinds = try planActionsV2(planData).map(\.action)
        let preflight = try DistributionOperationPayloadCodec.decode(
            DistributionOperationPreflightV2.self,
            from: preflightData
        )
        let runtime = try DistributionOperationPayloadCodec.decode(
            DistributionOperationRuntimeV2.self,
            from: runtimeData
        )
        guard try DistributionOperationPayloadCodec.encode(runtime) == runtimeData,
              runtime.wireVersion == 2,
              runtime.actions.count == actionKinds.count,
              preflight.actions.count == actionKinds.count,
              runtime.actions.enumerated().allSatisfy({
                  $0.offset == $0.element.actionIndex
              }),
              forwardCursor >= 0, forwardCursor <= Int64(actionKinds.count),
              rollbackCursor >= 0, rollbackCursor <= Int64(actionKinds.count),
              cleanupCursor >= 0, cleanupCursor <= Int64(actionKinds.count) else {
            throw DistributionOperationStoreError.invalidRecord
        }
        guard runtime.actions.filter({ $0.pending != nil }).count <= 1 else {
            throw DistributionOperationStoreError.invalidRecord
        }
        for (index, action) in runtime.actions.enumerated() {
            try validateRuntimeAction(
                action,
                kind: actionKinds[index],
                preflight: preflight.actions[index],
                source: preflight
            )
        }
        if phase == .prepared {
            guard forwardCursor == 0, rollbackCursor == 0, cleanupCursor == 0,
                  runtime.actions.allSatisfy({
                      $0.pending == nil
                          && $0.stagedCopy == nil
                          && $0.createdCopy == nil
                          && $0.createdLink == nil
                          && $0.quarantinedCopy == nil
                          && $0.quarantinedLink == nil
                  }) else {
                throw DistributionOperationStoreError.invalidRecord
            }
        } else if phase == .filesystemApplied || phase == .databaseCommitted
                    || phase == .cleaning
                    || (phase == .completed && outcome == .applied) {
            guard runtime.actions.enumerated().allSatisfy({
                hasAppliedEvidence($0.element, kind: actionKinds[$0.offset])
            }) else {
                throw DistributionOperationStoreError.invalidRecord
            }
        } else if phase == .completed && outcome == .rolledBack {
            guard runtime.actions.allSatisfy(isEmptyRuntimeAction) else {
                throw DistributionOperationStoreError.invalidRecord
            }
        }
    }

    private static func decodeBindings(_ data: Data) throws -> [DistributionBindingWireV2] {
        let value = try DistributionOperationPayloadCodec.decode(
            [DistributionBindingWireV2].self,
            from: data
        )
        guard try DistributionOperationPayloadCodec.encode(value) == data else {
            throw DistributionOperationStoreError.invalidRecord
        }
        return value
    }

    private static func validatePersistedBindings(
        _ wires: [DistributionBindingWireV2],
        skillID: SkillID
    ) throws {
        let bindings = try wires.map { try $0.binding(expectedSkillID: skillID) }
        try validateBindingSet(bindings.map(\.intent))
    }

    private static func validateDesiredBindings(
        _ wires: [DistributionBindingWireV2],
        skillID: SkillID
    ) throws {
        guard wires.allSatisfy({
            $0.createdAtMilliseconds == nil
                && $0.updatedAtMilliseconds == nil
                && $0.copyBaseline == nil
        }) else {
            throw DistributionOperationStoreError.invalidRecord
        }
        try validateBindingSet(wires.map { try $0.intent(expectedSkillID: skillID) })
    }

    private static func validateBindingSet(
        _ intents: [DistributionBindingIntent]
    ) throws {
        guard Set(intents.map(\.scope.targetScopeKey)).count == intents.count,
              Set(intents.map(\.distributionSlug)).count <= 1,
              Set(intents.map(\.syncMode)).count <= 1 else {
            throw DistributionOperationStoreError.invalidRecord
        }
        let globalCount = intents.count { $0.scope == .global }
        guard globalCount == 0 || (globalCount == 1 && intents.count == 1) else {
            throw DistributionOperationStoreError.invalidRecord
        }
    }

}
