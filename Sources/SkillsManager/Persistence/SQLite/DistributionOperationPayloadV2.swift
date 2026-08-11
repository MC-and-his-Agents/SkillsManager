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
        guard case .distribution(let operationID) = baseline.provenance else {
            throw DistributionOperationStoreError.invalidRecord
        }
        content = DistributionFingerprintWireV2(baseline.contentFingerprint)
        physicalTree = DistributionTreeDigestWireV2(baseline.physicalTreeDigest)
        rootIdentity = try ManagedItemIdentityCodec.encode(baseline.rootIdentity)
        entryIdentity = try ManagedItemIdentityCodec.encode(baseline.entryIdentity)
        appliedOperationID = operationID.bytes
        verifiedAtMilliseconds = baseline.verifiedAtMilliseconds
    }

    static func validationProjection(
        of baseline: DistributionCopyBaseline
    ) throws -> Self {
        try Self(validationProjectionOf: baseline)
    }

    private init(
        validationProjectionOf baseline: DistributionCopyBaseline
    ) throws {
        content = DistributionFingerprintWireV2(baseline.contentFingerprint)
        physicalTree = DistributionTreeDigestWireV2(baseline.physicalTreeDigest)
        rootIdentity = try ManagedItemIdentityCodec.encode(baseline.rootIdentity)
        entryIdentity = try ManagedItemIdentityCodec.encode(baseline.entryIdentity)
        appliedOperationID = baseline.provenance.operationID.bytes
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
        try self.init(
            binding,
            copyBaseline: binding.copyBaseline.map {
                try DistributionCopyBaselineWireV2($0)
            }
        )
    }

    static func validationProjection(
        of binding: DistributionBinding
    ) throws -> Self {
        try Self(validationProjectionOf: binding)
    }

    private init(
        validationProjectionOf binding: DistributionBinding
    ) throws {
        try self.init(
            binding,
            copyBaseline: binding.copyBaseline.map {
                try DistributionCopyBaselineWireV2.validationProjection(of: $0)
            }
        )
    }

    private init(
        _ binding: DistributionBinding,
        copyBaseline: DistributionCopyBaselineWireV2?
    ) throws {
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
        self.copyBaseline = copyBaseline
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

nonisolated struct DistributionHistoricalMigrationBackupWireV2:
    Codable, Equatable, Sendable
{
    let backupID: String
    let locator: String
    let directoryIdentity: Data
    let manifestDigest: Data
    // These optional fields were added after the first V2 journal format. An
    // absent value keeps old journals decodable; new historical approvals bind
    // the backup to the exact source evidence and operation plan.
    let skillID: String?
    let sourceScopeKey: String?
    let sourceLocator: String?
    let approvalOperationID: Data?
    let sourceRootIdentity: Data?
    let sourceEntryIdentity: Data?
    let sourceContent: DistributionFingerprintWireV2?
    let sourcePhysicalTree: DistributionTreeDigestWireV2?
    let targetLocator: String?
    let sourceRootLocator: String?

    private enum CodingKeys: String, CodingKey {
        case backupID
        case directoryIdentity
        case locator
        case manifestDigest
        case skillID
        case sourceScopeKey
        case sourceLocator
        case approvalOperationID
        case sourceRootIdentity
        case sourceEntryIdentity
        case sourceContent
        case sourcePhysicalTree
        case targetLocator
        case sourceRootLocator
    }

    init(_ backup: SkillBackupRecord) throws {
        backupID = backup.backupID.uuid.uuidString.lowercased()
        locator = backup.locator
        directoryIdentity = try ManagedItemIdentityCodec.encode(backup.directoryIdentity)
        manifestDigest = backup.manifestDigest
        skillID = nil
        sourceScopeKey = nil
        sourceLocator = nil
        approvalOperationID = nil
        sourceRootIdentity = nil
        sourceEntryIdentity = nil
        sourceContent = nil
        sourcePhysicalTree = nil
        targetLocator = nil
        sourceRootLocator = nil
    }

    init(
        _ backup: SkillBackupRecord,
        source: DistributionCopyEvidence,
        sourceScopeKey: String,
        sourceLocator: String,
        operationID: SSOTOperationID,
        targetLocator: String,
        sourceRootLocator: String
    ) throws {
        backupID = backup.backupID.uuid.uuidString.lowercased()
        locator = backup.locator
        directoryIdentity = try ManagedItemIdentityCodec.encode(backup.directoryIdentity)
        manifestDigest = backup.manifestDigest
        skillID = backup.originalSkillID.directoryName
        self.sourceScopeKey = sourceScopeKey
        self.sourceLocator = sourceLocator
        approvalOperationID = operationID.bytes
        sourceRootIdentity = try ManagedItemIdentityCodec.encode(source.rootIdentity)
        sourceEntryIdentity = try ManagedItemIdentityCodec.encode(source.entryIdentity)
        sourceContent = DistributionFingerprintWireV2(source.contentFingerprint)
        sourcePhysicalTree = DistributionTreeDigestWireV2(source.physicalTreeDigest)
        self.targetLocator = targetLocator
        self.sourceRootLocator = sourceRootLocator
    }
}

nonisolated struct DistributionLocalSkillOriginCleanupWireV2:
    Codable, Equatable, Sendable
{
    let skillID: String
    let scopeKind: String
    let adapterCode: String?
    let pathVariant: String?
    let customPathID: String?
    let rawLocator: String
    let normalizedLocator: String
    let collisionKey: String
    let fingerprintAlgorithmVersion: Int
    let contentFingerprint: Data
    let confirmedAtMilliseconds: Int64

    private enum CodingKeys: String, CodingKey {
        case skillID
        case scopeKind
        case adapterCode
        case pathVariant
        case customPathID
        case rawLocator
        case normalizedLocator
        case collisionKey
        case fingerprintAlgorithmVersion
        case contentFingerprint
        case confirmedAtMilliseconds
    }

    init(_ origin: LocalSkillOriginRecord) {
        skillID = origin.skillID.directoryName
        scopeKind = origin.scope.kind.rawValue
        adapterCode = origin.scope.adapterCode
        pathVariant = origin.scope.pathVariant
        customPathID = origin.scope.customPathID?.uuidString.lowercased()
        rawLocator = origin.rawLocator
        normalizedLocator = origin.normalizedLocator
        collisionKey = origin.collisionKey
        fingerprintAlgorithmVersion = origin.fingerprint.algorithmVersion
        contentFingerprint = origin.fingerprint.digest
        confirmedAtMilliseconds = origin.confirmedAtMilliseconds
    }

    func origin() throws -> LocalSkillOriginRecord {
        guard let skillUUID = UUID(uuidString: skillID),
              skillUUID.uuidString.lowercased() == skillID,
              let kind = SkillDiscoveryScopeKind(rawValue: scopeKind) else {
            throw DistributionOperationStoreError.invalidRecord
        }
        let scope: SkillDiscoveryScope
        switch kind {
        case .global:
            guard adapterCode == nil, pathVariant == nil, customPathID == nil else {
                throw DistributionOperationStoreError.invalidRecord
            }
            scope = .global
        case .agent:
            guard let adapterCode, let pathVariant, customPathID == nil else {
                throw DistributionOperationStoreError.invalidRecord
            }
            scope = .agent(adapterCode: adapterCode, pathVariant: pathVariant)
        case .custom:
            guard let adapterCode, let pathVariant,
                  let customPathID,
                  let pathID = UUID(uuidString: customPathID),
                  pathID.uuidString.lowercased() == customPathID else {
                throw DistributionOperationStoreError.invalidRecord
            }
            scope = .custom(
                pathID: pathID,
                adapterCode: adapterCode,
                pathVariant: pathVariant
            )
        }
        do {
            return try LocalSkillOriginRecord(
                skillID: SkillID(skillUUID),
                scope: scope,
                rawLocator: rawLocator,
                normalizedLocator: normalizedLocator,
                collisionKey: collisionKey,
                fingerprint: SkillContentFingerprint(
                    algorithmVersion: fingerprintAlgorithmVersion,
                    digest: contentFingerprint
                ),
                confirmedAtMilliseconds: confirmedAtMilliseconds
            )
        } catch {
            throw DistributionOperationStoreError.invalidRecord
        }
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
    let historicalMigrationBackup: DistributionHistoricalMigrationBackupWireV2?
    let localOriginCleanup: DistributionLocalSkillOriginCleanupWireV2?

    enum CodingKeys: String, CodingKey {
        case actionIndex
        case historicalMigrationBackup
        case localOriginCleanup
        case kind
        case oldCopy
        case oldLink
        case quarantineName
        case rootIdentity
        case slug
        case stagingName
        case targetScopeKey
    }

    init(
        actionIndex: Int,
        kind: String,
        targetScopeKey: String,
        slug: String,
        rootIdentity: Data?,
        oldCopy: DistributionCopyEvidenceWireV2?,
        oldLink: DistributionLinkEvidenceWireV2?,
        stagingName: String?,
        quarantineName: String?,
        historicalMigrationBackup: DistributionHistoricalMigrationBackupWireV2? = nil,
        localOriginCleanup: DistributionLocalSkillOriginCleanupWireV2? = nil
    ) {
        self.actionIndex = actionIndex
        self.kind = kind
        self.targetScopeKey = targetScopeKey
        self.slug = slug
        self.rootIdentity = rootIdentity
        self.oldCopy = oldCopy
        self.oldLink = oldLink
        self.stagingName = stagingName
        self.quarantineName = quarantineName
        self.historicalMigrationBackup = historicalMigrationBackup
        self.localOriginCleanup = localOriginCleanup
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        actionIndex = try container.decode(Int.self, forKey: .actionIndex)
        kind = try container.decode(String.self, forKey: .kind)
        targetScopeKey = try container.decode(String.self, forKey: .targetScopeKey)
        slug = try container.decode(String.self, forKey: .slug)
        rootIdentity = try container.decodeIfPresent(Data.self, forKey: .rootIdentity)
        oldCopy = try container.decodeIfPresent(
            DistributionCopyEvidenceWireV2.self,
            forKey: .oldCopy
        )
        oldLink = try container.decodeIfPresent(
            DistributionLinkEvidenceWireV2.self,
            forKey: .oldLink
        )
        stagingName = try container.decodeIfPresent(String.self, forKey: .stagingName)
        quarantineName = try container.decodeIfPresent(String.self, forKey: .quarantineName)
        historicalMigrationBackup = try container.decodeIfPresent(
            DistributionHistoricalMigrationBackupWireV2.self,
            forKey: .historicalMigrationBackup
        )
        localOriginCleanup = try container.decodeIfPresent(
            DistributionLocalSkillOriginCleanupWireV2.self,
            forKey: .localOriginCleanup
        )
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(actionIndex, forKey: .actionIndex)
        try container.encode(kind, forKey: .kind)
        try container.encode(targetScopeKey, forKey: .targetScopeKey)
        try container.encode(slug, forKey: .slug)
        try container.encodeIfPresent(rootIdentity, forKey: .rootIdentity)
        try container.encodeIfPresent(oldCopy, forKey: .oldCopy)
        try container.encodeIfPresent(oldLink, forKey: .oldLink)
        try container.encodeIfPresent(stagingName, forKey: .stagingName)
        try container.encodeIfPresent(quarantineName, forKey: .quarantineName)
        try container.encodeIfPresent(
            historicalMigrationBackup,
            forKey: .historicalMigrationBackup
        )
        try container.encodeIfPresent(localOriginCleanup, forKey: .localOriginCleanup)
    }
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
        } else if phase == .rollingBack {
            try validateRollbackBindings(new, skillID: skillID)
        } else {
            try validateDesiredBindings(new, skillID: skillID)
        }
        try validateActionPayloads(
            operationID: operationID,
            skillID: skillID,
            oldBindings: old,
            newBindings: new,
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

    static func validateActionPayloads(
        operationID: SSOTOperationID,
        skillID: SkillID,
        oldBindings: [DistributionBindingWireV2],
        newBindings: [DistributionBindingWireV2],
        planData: Data,
        preflightData: Data,
        runtimeData: Data,
        phase: DistributionOperationPhase,
        outcome: DistributionOperationOutcome?,
        forwardCursor: Int64,
        rollbackCursor: Int64,
        cleanupCursor: Int64
    ) throws {
        let preflight = try DistributionOperationPayloadCodec.decode(
            DistributionOperationPreflightV2.self,
            from: preflightData
        )
        let allowsHistoricalUnboundCleanup = preflight.actions.contains {
            ($0.kind == DistributionFilesystemActionKind.removeCopy.rawValue
                || $0.kind == DistributionFilesystemActionKind.replaceCopyWithSymlink.rawValue)
                && completeHistoricalApproval($0.historicalMigrationBackup)
                && $0.localOriginCleanup != nil
        }
        let plan = try validatePlanV2(
            planData,
            skillID: skillID,
            oldBindings: oldBindings,
            newBindings: newBindings,
            allowsHistoricalUnboundCleanup: allowsHistoricalUnboundCleanup
        )
        let actionKinds = plan.filesystemActions.map(\.action)
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
        if allowsHistoricalUnboundCleanup {
            guard plan.filesystemActions.count == 1,
                  preflight.actions.count == 1,
                  let planAction = plan.filesystemActions.first,
                  let preflightAction = preflight.actions.first,
                  preflightAction.actionIndex == 0,
                  preflightAction.kind == planAction.action,
                  preflightAction.targetScopeKey == planAction.targetScopeKey,
                  let actionScope = scopeV2(planAction.targetScopeKey),
                  preflightAction.slug
                      == slugV2(planAction.targetLocator, scope: actionScope)?.value else {
                throw DistributionOperationStoreError.invalidRecord
            }
        }
        for (index, action) in preflight.actions.enumerated() {
            try validatePreflightAction(
                action,
                planAction: plan.filesystemActions[index],
                skillID: skillID,
                oldBindings: oldBindings,
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

    private static func validateRollbackBindings(
        _ wires: [DistributionBindingWireV2],
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

    static func validateBindingSet(
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
