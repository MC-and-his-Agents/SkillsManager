import Foundation

nonisolated struct DistributionCopyProvenanceWireV3:
    Codable, Equatable, Sendable
{
    let kind: String
    let operationID: Data

    init(_ provenance: DistributionCopyBaseline.Provenance) {
        switch provenance {
        case .distribution(let operationID):
            kind = "distribution"
            self.operationID = operationID.bytes
        case .copyFork(let operationID):
            kind = "copyFork"
            self.operationID = operationID.bytes
        }
    }

    func provenance() throws -> DistributionCopyBaseline.Provenance {
        let operationID = try SSOTOperationID(bytes: operationID)
        return switch kind {
        case "distribution": .distribution(operationID)
        case "copyFork": .copyFork(operationID)
        default: throw DistributionOperationStoreError.invalidRecord
        }
    }
}

nonisolated struct DistributionCopyBaselineWireV3:
    Codable, Equatable, Sendable
{
    let content: DistributionFingerprintWireV2
    let physicalTree: DistributionTreeDigestWireV2
    let rootIdentity: Data
    let entryIdentity: Data
    let provenance: DistributionCopyProvenanceWireV3
    let verifiedAtMilliseconds: Int64

    init(_ baseline: DistributionCopyBaseline) throws {
        content = DistributionFingerprintWireV2(baseline.contentFingerprint)
        physicalTree = DistributionTreeDigestWireV2(baseline.physicalTreeDigest)
        rootIdentity = try ManagedItemIdentityCodec.encode(baseline.rootIdentity)
        entryIdentity = try ManagedItemIdentityCodec.encode(baseline.entryIdentity)
        provenance = DistributionCopyProvenanceWireV3(baseline.provenance)
        verifiedAtMilliseconds = baseline.verifiedAtMilliseconds
    }

    func baseline() throws -> DistributionCopyBaseline {
        try DistributionCopyBaseline(
            contentFingerprint: content.fingerprint(),
            physicalTreeDigest: physicalTree.treeDigest(),
            rootIdentity: ManagedItemIdentityCodec.decode(rootIdentity),
            entryIdentity: ManagedItemIdentityCodec.decode(entryIdentity),
            provenance: provenance.provenance(),
            verifiedAtMilliseconds: verifiedAtMilliseconds
        )
    }
}

nonisolated struct DistributionBindingWireV3:
    Codable, Equatable, Sendable
{
    let skillID: String
    let scope: String
    let adapter: String?
    let slug: String
    let syncMode: String
    let copyBaseline: DistributionCopyBaselineWireV3?
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
        copyBaseline = try binding.copyBaseline.map {
            try DistributionCopyBaselineWireV3($0)
        }
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

    func validationProjection(
        expectedSkillID: SkillID
    ) throws -> DistributionBindingWireV2 {
        if createdAtMilliseconds == nil, updatedAtMilliseconds == nil {
            return DistributionBindingWireV2(
                try intent(expectedSkillID: expectedSkillID)
            )
        }
        return try DistributionBindingWireV2.validationProjection(
            of: binding(expectedSkillID: expectedSkillID)
        )
    }
}

nonisolated enum DistributionOperationPayloadV3Validator {
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
        } else if phase == .rollingBack {
            try validateRollbackBindings(new, skillID: skillID)
        } else {
            try validateDesiredBindings(new, skillID: skillID)
        }
        try DistributionOperationPayloadV2Validator.validateActionPayloads(
            operationID: operationID,
            skillID: skillID,
            oldBindings: try old.map {
                try $0.validationProjection(expectedSkillID: skillID)
            },
            newBindings: try new.map {
                try $0.validationProjection(expectedSkillID: skillID)
            },
            planData: planData,
            preflightData: preflightData,
            runtimeData: runtimeData,
            phase: phase,
            outcome: outcome,
            forwardCursor: forwardCursor,
            rollbackCursor: rollbackCursor,
            cleanupCursor: cleanupCursor
        )
    }

    private static func decodeBindings(
        _ data: Data
    ) throws -> [DistributionBindingWireV3] {
        let value = try DistributionOperationPayloadCodec.decode(
            [DistributionBindingWireV3].self,
            from: data
        )
        guard try DistributionOperationPayloadCodec.encode(value) == data else {
            throw DistributionOperationStoreError.invalidRecord
        }
        return value
    }

    private static func validatePersistedBindings(
        _ wires: [DistributionBindingWireV3],
        skillID: SkillID
    ) throws {
        let bindings = try wires.map {
            try $0.binding(expectedSkillID: skillID)
        }
        try DistributionOperationPayloadV2Validator.validateBindingSet(
            bindings.map(\.intent)
        )
    }

    private static func validateDesiredBindings(
        _ wires: [DistributionBindingWireV3],
        skillID: SkillID
    ) throws {
        guard wires.allSatisfy({
            $0.createdAtMilliseconds == nil
                && $0.updatedAtMilliseconds == nil
                && $0.copyBaseline == nil
        }) else {
            throw DistributionOperationStoreError.invalidRecord
        }
        try DistributionOperationPayloadV2Validator.validateBindingSet(
            wires.map { try $0.intent(expectedSkillID: skillID) }
        )
    }

    private static func validateRollbackBindings(
        _ wires: [DistributionBindingWireV3],
        skillID: SkillID
    ) throws {
        if wires.allSatisfy({
            $0.createdAtMilliseconds == nil
                && $0.updatedAtMilliseconds == nil
                && $0.copyBaseline == nil
        }) {
            try validateDesiredBindings(wires, skillID: skillID)
        } else {
            try validatePersistedBindings(wires, skillID: skillID)
        }
    }
}
