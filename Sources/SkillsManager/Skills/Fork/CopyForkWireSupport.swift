import Foundation

extension JournaledSSOTWriter {
    func copyForkWire(
        operationID: SSOTOperationID,
        childWriteOperationID: SSOTOperationID,
        parentSkillID: SkillID,
        childSkillID: SkillID,
        parentRevision: Int64,
        binding: DistributionBinding,
        evidence: DistributionCopyEvidence,
        parent: ManagedSkillRecord,
        createdAt: Int64
    ) throws -> CopyForkPreviewWire {
        let baseline = try requiredCopyBaseline(binding)
        let provenance: (String, UUID) = switch baseline.provenance {
        case .distribution(let identifier): ("distribution", identifier.uuid)
        case .copyFork(let identifier): ("copyFork", identifier.uuid)
        }
        return CopyForkPreviewWire(
            version: 1,
            operationID: operationID.uuid,
            childWriteOperationID: childWriteOperationID.uuid,
            parentSkillID: parentSkillID.uuid,
            childSkillID: childSkillID.uuid,
            parentRevision: parentRevision,
            scopeKind: binding.scope.kind,
            adapterCode: binding.scope.adapter?.storageKey,
            distributionSlug: binding.distributionSlug.value,
            childDisplayName: parent.displayName.value,
            childDefaultDistributionSlug: parent.defaultDistributionSlug.value,
            parentBaseline: CopyForkPreviewWire.Baseline(
                contentAlgorithmVersion: baseline.contentFingerprint.algorithmVersion,
                contentFingerprint: baseline.contentFingerprint.digest,
                treeAlgorithmVersion: baseline.physicalTreeDigest.algorithmVersion,
                treeDigest: baseline.physicalTreeDigest.digest,
                rootIdentity: try ManagedItemIdentityCodec.encode(baseline.rootIdentity),
                entryIdentity: try ManagedItemIdentityCodec.encode(baseline.entryIdentity),
                provenanceKind: provenance.0,
                provenanceOperationID: provenance.1,
                verifiedAtMilliseconds: baseline.verifiedAtMilliseconds,
                bindingCreatedAtMilliseconds: binding.createdAtMilliseconds,
                bindingUpdatedAtMilliseconds: binding.updatedAtMilliseconds
            ),
            observed: CopyForkPreviewWire.Evidence(
                contentAlgorithmVersion: evidence.contentFingerprint.algorithmVersion,
                contentFingerprint: evidence.contentFingerprint.digest,
                treeAlgorithmVersion: evidence.physicalTreeDigest.algorithmVersion,
                treeDigest: evidence.physicalTreeDigest.digest,
                rootIdentity: try ManagedItemIdentityCodec.encode(evidence.rootIdentity),
                entryIdentity: try ManagedItemIdentityCodec.encode(evidence.entryIdentity)
            ),
            createdAtMilliseconds: createdAt
        )
    }

    func requirePreview(
        _ preview: CopyForkPreview,
        matches wire: CopyForkPreviewWire
    ) throws {
        let scope = try copyForkScope(kind: wire.scopeKind, adapterCode: wire.adapterCode)
        guard wire.operationID == preview.operationID.uuid,
              wire.parentSkillID == preview.parentSkillID.uuid,
              wire.childSkillID == preview.childSkillID.uuid,
              scope == preview.scope,
              wire.distributionSlug == preview.distributionSlug.value,
              wire.observed.contentAlgorithmVersion
                == preview.contentFingerprint.algorithmVersion,
              wire.observed.contentFingerprint == preview.contentFingerprint.digest else {
            throw CopyForkError.previewExpired
        }
    }

    func requireOperation(
        _ operation: CopyForkOperationRecord,
        matches wire: CopyForkPreviewWire
    ) throws {
        let scope = try copyForkScope(kind: wire.scopeKind, adapterCode: wire.adapterCode)
        guard wire.operationID == operation.operationID.uuid,
              wire.parentSkillID == operation.parentSkillID.uuid,
              wire.childSkillID == operation.childSkillID.uuid,
              wire.parentRevision == operation.parentRevision,
              scope == operation.parentBinding.scope,
              wire.distributionSlug == operation.parentBinding.distributionSlug.value,
              try copyForkWire(
                operationID: operation.operationID,
                childWriteOperationID: SSOTOperationID(wire.childWriteOperationID),
                parentSkillID: operation.parentSkillID,
                childSkillID: operation.childSkillID,
                parentRevision: operation.parentRevision,
                binding: operation.parentBinding,
                evidence: operation.observedEvidence,
                parent: try copyForkExpectedChildRecord(
                    operation: operation,
                    wire: wire
                ),
                createdAt: operation.createdAtMilliseconds
            ).canonicalData() == operation.previewPayload else {
            throw CopyForkError.needsRepair
        }
    }

    func copyForkExpectedChildRecord(
        operation: CopyForkOperationRecord,
        wire: CopyForkPreviewWire
    ) throws -> ManagedSkillRecord {
        try ManagedSkillRecord(
            skillID: operation.childSkillID,
            displayName: SkillDisplayName(wire.childDisplayName),
            defaultDistributionSlug: DefaultDistributionSlug(
                validating: wire.childDefaultDistributionSlug
            ),
            contentFingerprint: operation.observedEvidence.contentFingerprint,
            status: .managed,
            createdAtMilliseconds: operation.createdAtMilliseconds,
            updatedAtMilliseconds: operation.createdAtMilliseconds
        )
    }
}

nonisolated func copyForkScope(
    kind: String,
    adapterCode: String?
) throws -> DistributionBindingScope {
    switch kind {
    case "global" where adapterCode == nil:
        return .global
    case "agent":
        guard let adapterCode,
              let adapter = SkillPlatform.allCases.first(where: {
                  $0.storageKey == adapterCode
              }) else {
            throw CopyForkError.previewExpired
        }
        return .agent(adapter)
    default:
        throw CopyForkError.previewExpired
    }
}

nonisolated func withStableCopyForkErrors<T>(_ body: () throws -> T) throws -> T {
    do {
        return try body()
    } catch is CancellationError {
        throw CancellationError()
    } catch let interruption as SSOTWriterCheckpointInterruption {
        throw interruption
    } catch let stable as CopyForkError {
        throw stable
    } catch let error as DistributionSymlinkFileSystemError {
        switch error {
        case .unavailable: throw CopyForkError.targetUnavailable
        case .posix(_, let code) where code == EACCES || code == EPERM:
            throw CopyForkError.permissionDenied
        case .entryChanged, .equivalentSibling, .temporaryEntryExists:
            throw CopyForkError.previewExpired
        case .invalidTarget:
            throw CopyForkError.targetUnavailable
        default:
            throw CopyForkError.unsafeContent
        }
    } catch is SkillContentSnapshotError {
        throw CopyForkError.unsafeContent
    } catch is DistributionBindingStoreError {
        throw CopyForkError.bindingConflict
    } catch let error as CopyForkOperationStoreError {
        switch error {
        case .conflict: throw CopyForkError.operationInProgress
        case .corruptRecord: throw CopyForkError.needsRepair
        case .operationNotFound: throw CopyForkError.previewExpired
        }
    } catch let error as NSError
        where error.domain == NSPOSIXErrorDomain
            && (error.code == Int(EACCES) || error.code == Int(EPERM)) {
        throw CopyForkError.permissionDenied
    } catch {
        throw CopyForkError.needsRepair
    }
}
