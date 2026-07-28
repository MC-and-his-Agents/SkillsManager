import Darwin
import Foundation

extension JournaledSSOTWriter {
    func copyForkPreview(
        parentSkillID: SkillID,
        scope: DistributionBindingScope
    ) throws -> CopyForkPreview {
        try copyDriftDecisionPreview(
            parentSkillID: parentSkillID,
            scope: scope
        ).forkPreview
    }

    func createCopyFork(_ preview: CopyForkPreview) throws -> CopyForkResult {
        try withStableCopyForkErrors {
            try requireAuthority()
            let wire = try CopyForkPreviewWire.decode(preview.token)
            try requirePreview(preview, matches: wire)
            let store = CopyForkOperationStore(connection: connection)
            let operation: CopyForkOperationRecord
            do {
                operation = try store.load(preview.operationID)
            } catch CopyForkOperationStoreError.operationNotFound {
                operation = try reserveCopyFork(wire: wire, preview: preview)
            }
            return try resumeCopyFork(operation)
        }
    }

    func recoverCopyForks() throws {
        let store = CopyForkOperationStore(connection: connection)
        for operation in try store.active() where operation.outcome == nil {
            do {
                _ = try resumeCopyFork(operation)
            } catch is CancellationError {
                throw CancellationError()
            } catch let error as SSOTWriterOwnershipError {
                throw error
            } catch {
                let current = try store.load(operation.operationID)
                guard current.outcome == nil else { continue }
                try store.markNeedsRepair(
                    current,
                    error: error.localizedDescription,
                    at: nextCopyForkTimestamp(current)
                )
            }
        }
    }

    private func reserveCopyFork(
        wire: CopyForkPreviewWire,
        preview: CopyForkPreview
    ) throws -> CopyForkOperationRecord {
        let scope = try copyForkScope(kind: wire.scopeKind, adapterCode: wire.adapterCode)
        let context = try copyForkContext(parentSkillID: preview.parentSkillID, scope: scope)
        let capture = try captureContentOnlyDrift(
            entry: context.entry,
            baseline: context.baseline
        )
        let refreshed = try copyForkWire(
            operationID: preview.operationID,
            childWriteOperationID: SSOTOperationID(wire.childWriteOperationID),
            parentSkillID: preview.parentSkillID,
            childSkillID: preview.childSkillID,
            parentRevision: context.domain.revision,
            binding: context.binding,
            evidence: capture.evidence,
            parent: context.domain.payload.skill,
            createdAt: wire.createdAtMilliseconds
        )
        guard try refreshed.canonicalData() == preview.token else {
            throw CopyForkError.previewExpired
        }
        let record = CopyForkOperationRecord(
            operationID: preview.operationID,
            parentSkillID: preview.parentSkillID,
            childSkillID: preview.childSkillID,
            parentRevision: context.domain.revision,
            parentBinding: context.binding,
            observedEvidence: capture.evidence,
            previewPayload: preview.token,
            phase: .reserved,
            outcome: nil,
            verifiedAtMilliseconds: nil,
            attemptCount: 0,
            lastError: nil,
            createdAtMilliseconds: wire.createdAtMilliseconds,
            updatedAtMilliseconds: wire.createdAtMilliseconds
        )
        try CopyForkAdmission(connection: connection).reserve(record)
        return try CopyForkOperationStore(connection: connection).load(record.operationID)
    }

    private func resumeCopyFork(
        _ initial: CopyForkOperationRecord
    ) throws -> CopyForkResult {
        let store = CopyForkOperationStore(connection: connection)
        var operation = try store.load(initial.operationID)
        guard operation.outcome != .needsRepair else { throw CopyForkError.needsRepair }
        let wire = try CopyForkPreviewWire.decode(operation.previewPayload)
        try requireOperation(operation, matches: wire)
        if operation.phase == .reserved {
            if let child = try journal.storedDomain(operation.childSkillID) {
                try requireChildDomain(child, operation: operation)
            } else {
                try createCopyForkChild(operation: operation, wire: wire)
            }
            operation = try store.load(operation.operationID)
            if operation.phase == .reserved {
                try store.markChildCreated(operation, at: nextCopyForkTimestamp(operation))
                operation = try store.load(operation.operationID)
            }
        }
        if operation.phase == .childCreated {
            let context = try copyForkContext(
                parentSkillID: operation.parentSkillID,
                scope: operation.parentBinding.scope
            )
            guard context.domain.revision == operation.parentRevision,
                  context.binding == operation.parentBinding else {
                throw CopyForkError.bindingConflict
            }
            let capture = try fileSystemCapture(
                entry: context.entry,
                baseline: context.baseline
            )
            guard capture.evidence == operation.observedEvidence,
                  let child = try journal.storedDomain(operation.childSkillID) else {
                throw CopyForkError.previewExpired
            }
            try requireChildDomain(child, operation: operation)
            operation = try store.commitTransfer(
                operation: operation,
                parentBindings: context.bindings,
                childDomain: child,
                evidence: capture.evidence,
                verifiedAt: nextCopyForkTimestamp(operation)
            )
        }
        return try completedCopyForkResult(operation)
    }

    private func createCopyForkChild(
        operation: CopyForkOperationRecord,
        wire: CopyForkPreviewWire
    ) throws {
        let context = try copyForkContext(
            parentSkillID: operation.parentSkillID,
            scope: operation.parentBinding.scope
        )
        guard context.domain.revision == operation.parentRevision,
              context.binding == operation.parentBinding else {
            throw CopyForkError.bindingConflict
        }
        let capture = try fileSystemCapture(entry: context.entry, baseline: context.baseline)
        guard capture.evidence == operation.observedEvidence else {
            throw CopyForkError.previewExpired
        }
        let writeOperationID = SSOTOperationID(wire.childWriteOperationID)
        try removeOrphanCopyForkStaging(
            operationID: writeOperationID,
            fingerprint: capture.evidence.contentFingerprint
        )
        let payload = try copyForkPayload(operation: operation, wire: wire)
        _ = try create(
            payload: payload,
            sourceSnapshot: capture.snapshot,
            operationID: writeOperationID,
            copyForkReservation: operation.operationID
        )
        guard let child = try journal.storedDomain(operation.childSkillID) else {
            throw CopyForkError.needsRepair
        }
        try requireChildDomain(child, operation: operation)
    }

    private func completedCopyForkResult(
        _ operation: CopyForkOperationRecord
    ) throws -> CopyForkResult {
        guard operation.phase == .completed,
              operation.outcome == .applied,
              let child = try journal.storedDomain(operation.childSkillID) else {
            throw CopyForkError.needsRepair
        }
        try requireChildDomain(child, operation: operation)
        let parentBindings = try DistributionBindingStore(connection: connection)
            .load(skillID: operation.parentSkillID)
        let childBindings = try DistributionBindingStore(connection: connection)
            .load(skillID: operation.childSkillID)
        guard !parentBindings.contains(where: {
            $0.scope == operation.parentBinding.scope
        }), childBindings.count == 1,
              let binding = childBindings.first,
              binding.scope == operation.parentBinding.scope,
              binding.distributionSlug == operation.parentBinding.distributionSlug,
              binding.copyBaseline?.provenance == .copyFork(operation.operationID),
              binding.copyBaseline?.contentFingerprint
                == operation.observedEvidence.contentFingerprint,
              binding.copyBaseline?.physicalTreeDigest
                == operation.observedEvidence.physicalTreeDigest,
              binding.copyBaseline?.rootIdentity == operation.observedEvidence.rootIdentity,
              binding.copyBaseline?.entryIdentity == operation.observedEvidence.entryIdentity,
              binding.copyBaseline?.verifiedAtMilliseconds
                == operation.verifiedAtMilliseconds else {
            throw CopyForkError.needsRepair
        }
        let entry = try requiredCopyForkEntry(binding)
        let capture = try fileSystemCapture(
            entry: entry,
            baseline: try requiredCopyBaseline(binding)
        )
        guard capture.evidence == operation.observedEvidence,
              capture.evidence.contentFingerprint
                == child.payload.skill.contentFingerprint else {
            throw CopyForkError.needsRepair
        }
        return CopyForkResult(
            operationID: operation.operationID,
            parentSkillID: operation.parentSkillID,
            childSkillID: operation.childSkillID,
            scope: operation.parentBinding.scope
        )
    }
}

nonisolated struct CopyForkContext {
    let domain: StoredSkillDomainSnapshot
    let bindings: [DistributionBinding]
    let binding: DistributionBinding
    let baseline: DistributionCopyBaseline
    let entry: DistributionTargetEntry

    var target: CopyForkTargetReservation {
        CopyForkTargetReservation(
            scopeKey: binding.scope.targetScopeKey,
            slugKey: binding.distributionSlug.collisionKey
        )
    }
}

extension JournaledSSOTWriter {
    func copyForkContext(
        parentSkillID: SkillID,
        scope: DistributionBindingScope
    ) throws -> CopyForkContext {
        guard let domain = try journal.storedDomain(parentSkillID) else {
            throw CopyForkError.bindingConflict
        }
        let bindings = try DistributionBindingStore(connection: connection)
            .load(skillID: parentSkillID)
        guard let binding = bindings.first(where: { $0.scope == scope }),
              binding.syncMode == .copy,
              let baseline = binding.copyBaseline else {
            throw CopyForkError.notCopy
        }
        return CopyForkContext(
            domain: domain,
            bindings: bindings,
            binding: binding,
            baseline: baseline,
            entry: try requiredCopyForkEntry(binding)
        )
    }

    func captureContentOnlyDrift(
        entry: DistributionTargetEntry,
        baseline: DistributionCopyBaseline
    ) throws -> DistributionCopyCapture {
        let capture = try fileSystemCapture(entry: entry, baseline: baseline)
        guard capture.evidence.rootIdentity == baseline.rootIdentity,
              capture.evidence.entryIdentity == baseline.entryIdentity,
              capture.evidence.physicalTreeDigest == baseline.physicalTreeDigest,
              capture.evidence.contentFingerprint.algorithmVersion
                == baseline.contentFingerprint.algorithmVersion,
              capture.evidence.contentFingerprint.digest
                != baseline.contentFingerprint.digest else {
            throw CopyForkError.notContentOnlyDrift
        }
        return capture
    }

    func fileSystemCapture(
        entry: DistributionTargetEntry,
        baseline: DistributionCopyBaseline
    ) throws -> DistributionCopyCapture {
        try copyDistribution.fileSystem.captureCopy(
            entry,
            expectedRootIdentity: baseline.rootIdentity,
            expectedEntryIdentity: baseline.entryIdentity
        )
    }

}

private extension JournaledSSOTWriter {
    func copyForkPayload(
        operation: CopyForkOperationRecord,
        wire: CopyForkPreviewWire
    ) throws -> SSOTSkillWritePayload {
        let child = try copyForkExpectedChildRecord(operation: operation, wire: wire)
        return try SSOTSkillWritePayload(
            skill: child,
            forkLineage: SkillForkLineageRecord(
                forkSkillID: operation.childSkillID,
                parentSkillID: operation.parentSkillID,
                forkedFromFingerprint: try requiredCopyBaseline(
                    operation.parentBinding
                ).contentFingerprint,
                createdAtMilliseconds: operation.createdAtMilliseconds,
                originType: .localFork
            )
        )
    }

    func requireChildDomain(
        _ child: StoredSkillDomainSnapshot,
        operation: CopyForkOperationRecord
    ) throws {
        let wire = try CopyForkPreviewWire.decode(operation.previewPayload)
        let expected = try copyForkPayload(operation: operation, wire: wire)
        guard child.revision == 0,
              child.payload.skill.skillID == operation.childSkillID,
              child.payload.skill.displayName
                == expected.skill.displayName,
              child.payload.skill.defaultDistributionSlug
                == expected.skill.defaultDistributionSlug,
              child.payload.skill.contentFingerprint
                == operation.observedEvidence.contentFingerprint,
              child.payload.source == nil,
              child.payload.providerAliases.isEmpty,
              child.payload.providerProvenance.isEmpty,
              child.payload.localOrigins.isEmpty,
              child.payload.restoredFromSkillID == nil,
              child.payload.forkLineage == expected.forkLineage else {
            throw CopyForkError.needsRepair
        }
    }

    func removeOrphanCopyForkStaging(
        operationID: SSOTOperationID,
        fingerprint: SkillContentFingerprint
    ) throws {
        if (try? journal.loadOperation(operationID)) != nil { return }
        let reference = SSOTOperationItemReference.staging(operationID: operationID.uuid)
        let url = fileSystem.operationItemURL(for: reference)
        guard let identity = try fileSystem.managedRootGuard.itemIdentity(at: url) else {
            return
        }
        let snapshot = try SkillContentSnapshot.capture(at: url)
        guard snapshot.fingerprintDigest == fingerprint.digest else {
            throw CopyForkError.needsRepair
        }
        try fileSystem.removeExpectedOperationItem(
            reference,
            identity: identity,
            fingerprint: fingerprint
        )
    }

    func nextCopyForkTimestamp(_ operation: CopyForkOperationRecord) -> Int64 {
        max(initialTimestamp(), operation.updatedAtMilliseconds + 1)
    }
}

nonisolated func requiredCopyForkEntry(
    _ binding: DistributionBinding
) throws -> DistributionTargetEntry {
    guard let entry = DistributionTargetCatalog.current.entry(
        for: binding.scope,
        slug: binding.distributionSlug
    ) else {
        throw CopyForkError.targetUnavailable
    }
    return entry
}

nonisolated func requiredCopyBaseline(
    _ binding: DistributionBinding
) throws -> DistributionCopyBaseline {
    guard binding.syncMode == .copy, let baseline = binding.copyBaseline else {
        throw CopyForkError.notCopy
    }
    return baseline
}
