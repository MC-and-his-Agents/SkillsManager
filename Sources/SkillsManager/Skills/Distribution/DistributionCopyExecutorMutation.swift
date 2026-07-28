import Foundation

nonisolated extension DistributionCopyExecutor {
    func quarantineLink(
        _ action: DistributionFilesystemAction,
        _ index: Int,
        _ preflight: DistributionOperationPreflightV2,
        _ operationID: SSOTOperationID,
        _ runtime: inout DistributionOperationRuntimeV2,
        _ timestamp: Int64
    ) throws {
        guard preflight.actions.indices.contains(index),
              let old = preflight.actions[index].oldLink else {
            throw DistributionSymlinkExecutorError.conflict
        }
        runtime.actions[index].pending = .quarantineSymlink
        try advance(
            operationID,
            phase: .applying,
            cursor: Int64(index),
            runtime: runtime,
            timestamp: timestamp
        )
        let quarantined = try fileSystem.quarantine(
            action.entry,
            expected: old.evidence(),
            operationID: operationID.uuid,
            actionIndex: index
        )
        guard quarantined.temporaryName
                == preflight.actions[index].quarantineName else {
            throw DistributionSymlinkExecutorError.needsRepair(
                "symlink quarantine locator changed"
            )
        }
        runtime.actions[index].quarantinedLink = try DistributionLinkEvidenceWireV2(
            quarantined.evidence
        )
    }

    func createLink(
        _ action: DistributionFilesystemAction,
        _ index: Int,
        _ preflight: DistributionOperationPreflightV2,
        _ source: DistributionCopySource,
        _ operationID: SSOTOperationID,
        _ runtime: inout DistributionOperationRuntimeV2,
        _ timestamp: Int64
    ) throws {
        let root = try fileSystem.ensureRoot(for: action.entry.target.scope)
        if let encodedRoot = preflight.actions[index].rootIdentity,
           try ManagedItemIdentityCodec.decode(encodedRoot) != root {
            throw DistributionSymlinkExecutorError.needsRepair(
                "distribution root changed"
            )
        }
        runtime.actions[index].pending = .createSymlink
        try advance(
            operationID,
            phase: .applying,
            cursor: Int64(index),
            runtime: runtime,
            timestamp: timestamp
        )
        let created = try fileSystem.create(
            action.entry,
            absoluteTarget: source.absoluteTarget,
            expectedRootIdentity: root
        )
        runtime.actions[index].createdLink = try DistributionLinkEvidenceWireV2(
            created
        )
    }

    func quarantineCopy(
        _ action: DistributionFilesystemAction,
        _ index: Int,
        _ preflight: DistributionOperationPreflightV2,
        _ operationID: SSOTOperationID,
        _ runtime: inout DistributionOperationRuntimeV2,
        _ timestamp: Int64
    ) throws {
        guard preflight.actions.indices.contains(index),
              let old = preflight.actions[index].oldCopy else {
            throw DistributionSymlinkExecutorError.conflict
        }
        runtime.actions[index].pending = .quarantineCopy
        try advance(
            operationID,
            phase: .applying,
            cursor: Int64(index),
            runtime: runtime,
            timestamp: timestamp
        )
        let quarantined = try fileSystem.quarantineCopy(
            action.entry,
            expected: old.evidence(),
            operationID: operationID.uuid,
            actionIndex: index
        )
        guard quarantined.temporaryName
                == preflight.actions[index].quarantineName else {
            throw DistributionSymlinkExecutorError.needsRepair(
                "Copy quarantine locator changed"
            )
        }
        runtime.actions[index].quarantinedCopy = try DistributionCopyEvidenceWireV2(
            quarantined.evidence
        )
    }

    func promoteCopy(
        _ action: DistributionFilesystemAction,
        _ index: Int,
        _ preflight: DistributionOperationPreflightV2,
        _ runtime: inout DistributionOperationRuntimeV2,
        _ operationID: SSOTOperationID,
        _ timestamp: Int64
    ) throws {
        guard runtime.actions.indices.contains(index),
              preflight.actions.indices.contains(index),
              let stagedWire = runtime.actions[index].stagedCopy,
              let stagingName = preflight.actions[index].stagingName else {
            throw DistributionSymlinkExecutorError.needsRepair(
                "Copy staging evidence is missing"
            )
        }
        let staged = DistributionStagedCopy(
            temporaryName: stagingName,
            evidence: try stagedWire.evidence()
        )
        runtime.actions[index].pending = .promoteCopy
        try advance(
            operationID,
            phase: .applying,
            cursor: Int64(index),
            runtime: runtime,
            timestamp: timestamp
        )
        let created = try fileSystem.promoteCopy(action.entry, staged: staged)
        runtime.actions[index].createdCopy = try DistributionCopyEvidenceWireV2(
            created
        )
    }
}
