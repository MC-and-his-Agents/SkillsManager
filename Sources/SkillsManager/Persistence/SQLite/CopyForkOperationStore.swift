import Foundation

nonisolated enum CopyForkOperationStoreError: Error, Equatable {
    case conflict
    case corruptRecord
    case operationNotFound
}

nonisolated struct CopyForkOperationStore {
    let connection: SQLiteConnection

    init(connection: SQLiteConnection) {
        self.connection = connection
    }

    func insertReservation(_ record: CopyForkOperationRecord) throws {
        guard record.phase == .reserved,
              record.outcome == nil,
              record.verifiedAtMilliseconds == nil else {
            throw CopyForkOperationStoreError.corruptRecord
        }
        let baseline = try requiredBaseline(record.parentBinding)
        let statement = try connection.prepare(
            """
            INSERT INTO copy_fork_operations(
              operation_id, parent_skill_id, child_skill_id, parent_revision,
              scope_kind, adapter_code, target_scope_key,
              distribution_slug, slug_key,
              parent_copy_provenance_kind, parent_provenance_operation_id,
              parent_content_algorithm_version, parent_content_fingerprint,
              parent_tree_algorithm_version, parent_tree_digest,
              parent_root_identity, parent_entry_identity, parent_verified_at_ms,
              parent_binding_created_at_ms, parent_binding_updated_at_ms,
              observed_content_algorithm_version, observed_content_fingerprint,
              observed_tree_algorithm_version, observed_tree_digest,
              observed_root_identity, observed_entry_identity,
              preview_payload, phase, outcome, verified_at_ms,
              attempt_count, last_error, created_at_ms, updated_at_ms
            ) VALUES (
              ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?,
              ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?,
              ?, 'reserved', NULL, NULL, 0, NULL, ?, ?
            )
            """
        )
        var index: Int32 = 1
        for value in [
            record.operationID.bytes,
            record.parentSkillID.bytes,
            record.childSkillID.bytes,
        ] {
            try statement.bind(value, at: index)
            index += 1
        }
        try statement.bind(record.parentRevision, at: index); index += 1
        try statement.bind(record.parentBinding.scope.kind, at: index); index += 1
        if let adapter = record.parentBinding.scope.adapter {
            try statement.bind(adapter.storageKey, at: index)
        } else {
            try statement.bindNull(at: index)
        }
        index += 1
        try statement.bind(record.parentBinding.scope.targetScopeKey, at: index); index += 1
        try statement.bind(record.parentBinding.distributionSlug.value, at: index); index += 1
        try statement.bind(record.parentBinding.distributionSlug.collisionKey, at: index); index += 1
        try bindProvenance(baseline.provenance, to: statement, kindAt: index)
        index += 2
        try bindBaseline(baseline, to: statement, startingAt: index)
        index += 7
        try statement.bind(record.parentBinding.createdAtMilliseconds, at: index); index += 1
        try statement.bind(record.parentBinding.updatedAtMilliseconds, at: index); index += 1
        try bindEvidence(record.observedEvidence, to: statement, startingAt: index)
        index += 6
        try statement.bind(record.previewPayload, at: index); index += 1
        try statement.bind(record.createdAtMilliseconds, at: index); index += 1
        try statement.bind(record.updatedAtMilliseconds, at: index)
        try finishExactlyOne(statement)
    }

    func load(_ operationID: SSOTOperationID) throws -> CopyForkOperationRecord {
        let statement = try connection.prepare(Self.selectSQL + " AND operation_id = ?")
        try statement.bind(operationID.bytes, at: 1)
        guard try statement.step() else {
            throw CopyForkOperationStoreError.operationNotFound
        }
        let record = try decode(statement)
        guard try !statement.step() else {
            throw CopyForkOperationStoreError.corruptRecord
        }
        return record
    }

    func active() throws -> [CopyForkOperationRecord] {
        let statement = try connection.prepare(
            Self.selectSQL
                + " AND (outcome IS NULL OR outcome = 'needsRepair')"
                + " ORDER BY created_at_ms, operation_id"
        )
        var result: [CopyForkOperationRecord] = []
        while try statement.step() { result.append(try decode(statement)) }
        return result
    }

    func markChildCreated(_ record: CopyForkOperationRecord, at timestamp: Int64) throws {
        try update(
            record,
            phase: .childCreated,
            outcome: nil,
            verifiedAt: nil,
            error: nil,
            timestamp: timestamp
        )
    }

    func markNeedsRepair(
        _ record: CopyForkOperationRecord,
        error: String,
        at timestamp: Int64
    ) throws {
        try update(
            record,
            phase: record.phase,
            outcome: .needsRepair,
            verifiedAt: nil,
            error: String(error.prefix(4_096)),
            timestamp: timestamp
        )
    }

    func commitTransfer(
        operation: CopyForkOperationRecord,
        parentBindings: [DistributionBinding],
        childDomain: StoredSkillDomainSnapshot,
        evidence: DistributionCopyEvidence,
        verifiedAt timestamp: Int64
    ) throws -> CopyForkOperationRecord {
        try connection.withImmediateTransaction {
            guard try load(operation.operationID) == operation,
                  operation.phase == .childCreated,
                  operation.outcome == nil,
                  childDomain.payload.skill.skillID == operation.childSkillID,
                  childDomain.payload.forkLineage?.parentSkillID == operation.parentSkillID,
                  evidence == operation.observedEvidence,
                  try currentRevision(operation.parentSkillID) == operation.parentRevision else {
                throw CopyForkOperationStoreError.conflict
            }
            let bindingStore = DistributionBindingStore(connection: connection)
            let currentParent = try bindingStore.load(skillID: operation.parentSkillID)
            guard currentParent == parentBindings,
                  currentParent.contains(operation.parentBinding),
                  try bindingStore.load(skillID: operation.childSkillID).isEmpty else {
                throw CopyForkOperationStoreError.conflict
            }
            _ = try bindingStore.replaceFinalizedInCurrentTransaction(
                skillID: operation.parentSkillID,
                expectedOld: currentParent,
                desired: currentParent.filter { $0.scope != operation.parentBinding.scope }
            )
            try updateInCurrentTransaction(
                operation,
                phase: .completed,
                outcome: .applied,
                verifiedAt: timestamp,
                error: nil,
                timestamp: timestamp
            )
            let childBaseline = try DistributionCopyBaseline(
                contentFingerprint: evidence.contentFingerprint,
                physicalTreeDigest: evidence.physicalTreeDigest,
                rootIdentity: evidence.rootIdentity,
                entryIdentity: evidence.entryIdentity,
                provenance: .copyFork(operation.operationID),
                verifiedAtMilliseconds: timestamp
            )
            let childBinding = try DistributionBinding(
                skillID: operation.childSkillID,
                scope: operation.parentBinding.scope,
                distributionSlug: operation.parentBinding.distributionSlug,
                syncMode: .copy,
                copyBaseline: childBaseline,
                createdAtMilliseconds: timestamp,
                updatedAtMilliseconds: timestamp
            )
            _ = try bindingStore.replaceFinalizedInCurrentTransaction(
                skillID: operation.childSkillID,
                expectedOld: [],
                desired: [childBinding]
            )
            return try load(operation.operationID)
        }
    }

    func requireCompletedBindingEvidence(_ binding: DistributionBinding) throws {
        guard let baseline = binding.copyBaseline,
              case .copyFork(let operationID) = baseline.provenance else { return }
        let record = try load(operationID)
        guard record.phase == .completed,
              record.outcome == .applied,
              record.childSkillID == binding.skillID,
              record.parentBinding.scope == binding.scope,
              record.parentBinding.distributionSlug == binding.distributionSlug,
              record.observedEvidence.contentFingerprint == baseline.contentFingerprint,
              record.observedEvidence.physicalTreeDigest == baseline.physicalTreeDigest,
              record.observedEvidence.rootIdentity == baseline.rootIdentity,
              record.observedEvidence.entryIdentity == baseline.entryIdentity,
              record.verifiedAtMilliseconds == baseline.verifiedAtMilliseconds else {
            throw CopyForkOperationStoreError.corruptRecord
        }
    }

    private func update(
        _ record: CopyForkOperationRecord,
        phase: CopyForkOperationPhase,
        outcome: CopyForkOperationOutcome?,
        verifiedAt: Int64?,
        error: String?,
        timestamp: Int64
    ) throws {
        try connection.withImmediateTransaction {
            try updateInCurrentTransaction(
                record,
                phase: phase,
                outcome: outcome,
                verifiedAt: verifiedAt,
                error: error,
                timestamp: timestamp
            )
        }
    }

    private func updateInCurrentTransaction(
        _ record: CopyForkOperationRecord,
        phase: CopyForkOperationPhase,
        outcome: CopyForkOperationOutcome?,
        verifiedAt: Int64?,
        error: String?,
        timestamp: Int64
    ) throws {
        guard timestamp >= record.updatedAtMilliseconds,
              (outcome == .needsRepair) == !(error?.isEmpty ?? true),
              (phase == .completed) == (outcome == .applied) else {
            throw CopyForkOperationStoreError.corruptRecord
        }
        let statement = try connection.prepare(
            """
            UPDATE copy_fork_operations
            SET phase = ?, outcome = ?, verified_at_ms = ?,
                attempt_count = ?, last_error = ?, updated_at_ms = ?
            WHERE operation_id = ? AND phase = ?
              AND outcome IS ? AND updated_at_ms = ?
            """
        )
        try statement.bind(phase.rawValue, at: 1)
        if let outcome { try statement.bind(outcome.rawValue, at: 2) }
        else { try statement.bindNull(at: 2) }
        if let verifiedAt { try statement.bind(verifiedAt, at: 3) }
        else { try statement.bindNull(at: 3) }
        try statement.bind(record.attemptCount + 1, at: 4)
        if let error { try statement.bind(error, at: 5) }
        else { try statement.bindNull(at: 5) }
        try statement.bind(timestamp, at: 6)
        try statement.bind(record.operationID.bytes, at: 7)
        try statement.bind(record.phase.rawValue, at: 8)
        if let oldOutcome = record.outcome { try statement.bind(oldOutcome.rawValue, at: 9) }
        else { try statement.bindNull(at: 9) }
        try statement.bind(record.updatedAtMilliseconds, at: 10)
        try finishExactlyOne(statement)
    }

    private func currentRevision(_ skillID: SkillID) throws -> Int64? {
        let statement = try connection.prepare("SELECT db_revision FROM skills WHERE skill_id = ?")
        try statement.bind(skillID.bytes, at: 1)
        guard try statement.step() else { return nil }
        let revision = statement.int64(at: 0)
        guard try !statement.step() else {
            throw CopyForkOperationStoreError.corruptRecord
        }
        return revision
    }

    private func decode(_ statement: SQLiteStatement) throws -> CopyForkOperationRecord {
        do {
            let parentID = try SkillID(bytes: requiredBlob(statement, 1))
            let childID = try SkillID(bytes: requiredBlob(statement, 2))
            let scope = try decodeScope(statement, kindAt: 4, adapterAt: 5, keyAt: 6)
            let slug = try DefaultDistributionSlug(validating: requiredText(statement, 7))
            guard slug.collisionKey == (try requiredText(statement, 8)) else {
                throw CopyForkOperationStoreError.corruptRecord
            }
            let baseline = try DistributionCopyBaseline(
                contentFingerprint: SkillContentFingerprint(
                    algorithmVersion: Int(statement.int64(at: 11)),
                    digest: requiredBlob(statement, 12)
                ),
                physicalTreeDigest: CopyPhysicalTreeDigest(
                    algorithmVersion: Int(statement.int64(at: 13)),
                    digest: requiredBlob(statement, 14)
                ),
                rootIdentity: ManagedItemIdentityCodec.decode(requiredBlob(statement, 15)),
                entryIdentity: ManagedItemIdentityCodec.decode(requiredBlob(statement, 16)),
                provenance: try decodeProvenance(statement, kindAt: 9, idAt: 10),
                verifiedAtMilliseconds: statement.int64(at: 17)
            )
            let binding = try DistributionBinding(
                skillID: parentID,
                scope: scope,
                distributionSlug: slug,
                syncMode: .copy,
                copyBaseline: baseline,
                createdAtMilliseconds: statement.int64(at: 18),
                updatedAtMilliseconds: statement.int64(at: 19)
            )
            let evidence = try DistributionCopyEvidence(
                rootIdentity: ManagedItemIdentityCodec.decode(requiredBlob(statement, 24)),
                entryIdentity: ManagedItemIdentityCodec.decode(requiredBlob(statement, 25)),
                contentFingerprint: SkillContentFingerprint(
                    algorithmVersion: Int(statement.int64(at: 20)),
                    digest: requiredBlob(statement, 21)
                ),
                physicalTreeDigest: CopyPhysicalTreeDigest(
                    algorithmVersion: Int(statement.int64(at: 22)),
                    digest: requiredBlob(statement, 23)
                )
            )
            let record = CopyForkOperationRecord(
                operationID: try SSOTOperationID(bytes: requiredBlob(statement, 0)),
                parentSkillID: parentID,
                childSkillID: childID,
                parentRevision: statement.int64(at: 3),
                parentBinding: binding,
                observedEvidence: evidence,
                previewPayload: try requiredBlob(statement, 26),
                phase: try requiredEnum(statement, 27, as: CopyForkOperationPhase.self),
                outcome: try optionalEnum(statement, 28, as: CopyForkOperationOutcome.self),
                verifiedAtMilliseconds: statement.isNull(at: 29) ? nil : statement.int64(at: 29),
                attemptCount: statement.int64(at: 30),
                lastError: statement.text(at: 31),
                createdAtMilliseconds: statement.int64(at: 32),
                updatedAtMilliseconds: statement.int64(at: 33)
            )
            try validate(record)
            return record
        } catch let error as CopyForkOperationStoreError {
            throw error
        } catch {
            throw CopyForkOperationStoreError.corruptRecord
        }
    }

    private func validate(_ record: CopyForkOperationRecord) throws {
        guard record.parentSkillID != record.childSkillID,
              record.parentRevision >= 0,
              record.attemptCount >= 0,
              record.createdAtMilliseconds >= 0,
              record.updatedAtMilliseconds >= record.createdAtMilliseconds,
              (record.lastError?.utf8.count ?? 0) <= 4_096,
              (try? CopyForkPreviewWire.decode(record.previewPayload)) != nil else {
            throw CopyForkOperationStoreError.corruptRecord
        }
        switch (record.phase, record.outcome, record.verifiedAtMilliseconds) {
        case (.reserved, nil, nil), (.childCreated, nil, nil),
             (.reserved, .needsRepair, nil), (.childCreated, .needsRepair, nil),
             (.completed, .applied, .some):
            break
        default:
            throw CopyForkOperationStoreError.corruptRecord
        }
    }

    private static let selectSQL = """
    SELECT operation_id, parent_skill_id, child_skill_id, parent_revision,
           scope_kind, adapter_code, target_scope_key, distribution_slug, slug_key,
           parent_copy_provenance_kind, parent_provenance_operation_id,
           parent_content_algorithm_version, parent_content_fingerprint,
           parent_tree_algorithm_version, parent_tree_digest,
           parent_root_identity, parent_entry_identity, parent_verified_at_ms,
           parent_binding_created_at_ms, parent_binding_updated_at_ms,
           observed_content_algorithm_version, observed_content_fingerprint,
           observed_tree_algorithm_version, observed_tree_digest,
           observed_root_identity, observed_entry_identity,
           preview_payload, phase, outcome, verified_at_ms,
           attempt_count, last_error, created_at_ms, updated_at_ms
    FROM copy_fork_operations WHERE 1 = 1
    """
}
