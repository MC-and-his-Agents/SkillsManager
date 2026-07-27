import Foundation

extension JournaledSSOTWriter {
    func deleteManagedSkill(
        skillID: SkillID,
        operationID: SSOTOperationID = SSOTOperationID(),
        backupID: SkillBackupID = SkillBackupID()
    ) throws -> SkillDeletionResult {
        try withStableSkillLifecycleErrors(.mutation) {
            try performDeleteManagedSkill(
                skillID: skillID,
                operationID: operationID,
                backupID: backupID
            )
        }
    }

    private func performDeleteManagedSkill(
        skillID: SkillID,
        operationID: SSOTOperationID,
        backupID: SkillBackupID
    ) throws -> SkillDeletionResult {
        try requireAuthority()
        _ = try deletionPreview(skillID: skillID)
        guard let domain = try journal.storedDomain(skillID) else {
            throw SkillDeletionError.skillNotFound
        }
        let selection = try loadDistributionSelection(skillID: skillID)
        let ownership = try DistributionLinkOwnershipStore(connection: connection)
            .load(skillID: skillID)
        guard let ssotIdentity = try fileSystem.managedRootGuard.itemIdentity(
            at: fileSystem.finalURL(skillID: skillID)
        ) else {
            throw SkillDeletionError.conflict
        }
        let snapshot = try fileSystem.captureExpectedFinal(
            skillID: skillID,
            expectedIdentity: ssotIdentity,
            expectedFingerprint: domain.payload.skill.contentFingerprint
        )
        let createdAt = deletionTimestamp()
        let manifest = try SkillBackupManifestV1(
            backupID: backupID,
            payload: domain.payload,
            databaseRevision: domain.revision,
            distributionSelection: SkillBackupDistributionSelection(selection),
            statistics: snapshot.statistics,
            createdAtMilliseconds: createdAt
        )
        let manifestBytes = try manifest.encoded()
        let expectation = SkillDeletionExpectation(
            databaseRevision: domain.revision,
            selection: selection,
            ownership: ownership
        )
        let plan = try distribution.dryRun(
            skillID: skillID,
            currentBindings: selection.bindings,
            desiredScope: .disabled,
            desiredConfigured: selection.isExplicitlyConfigured,
            requiredAdapterCodes: []
        )
        guard plan.status != .blocked else { throw SkillDeletionError.conflict }
        let draft = try SkillDeletionOperationDraft(
            operationID: operationID,
            skillID: skillID,
            backupID: backupID,
            domainPayload: SSOTWritePayloadCodec.encode(domain.payload),
            expectationPayload: expectation.canonicalData(),
            distributionPlan: plan.canonicalJSONData(),
            ssotIdentity: ssotIdentity,
            quarantineLocator: operationItemName(operationID),
            createdAtMilliseconds: createdAt
        )
        _ = try backupFileSystem.publish(
            snapshot: snapshot,
            skillID: skillID,
            backupID: backupID.uuid,
            createdAtMilliseconds: createdAt,
            manifestBytes: manifestBytes,
            expectedFingerprint: domain.payload.skill.contentFingerprint,
            beforePromotion: { publication in
                try self.insertDeletionPreparation(
                    publication: publication,
                    backupID: backupID,
                    skillID: skillID,
                    draft: draft,
                    createdAtMilliseconds: createdAt,
                )
            },
            afterPreparationRecorded: {
                try self.reachDeletionCheckpoint(.afterPreparedInsert)
            },
            afterPromotion: {
                try self.reachDeletionCheckpoint(.afterBackupPromotion)
            }
        )
        return try executeDeletion(operationID)
    }

    private func insertDeletionPreparation(
        publication: SkillBackupPublication,
        backupID: SkillBackupID,
        skillID: SkillID,
        draft: SkillDeletionOperationDraft,
        createdAtMilliseconds: Int64
    ) throws {
        let backup = try SkillBackupRecord(
            backupID: backupID,
            originalSkillID: skillID,
            state: .preparing,
            locator: publication.locator,
            directoryIdentity: publication.identity,
            manifestDigest: publication.manifestDigest,
            contentFingerprint: publication.contentFingerprint,
            createdAtMilliseconds: createdAtMilliseconds,
            updatedAtMilliseconds: createdAtMilliseconds
        )
        let operationStore = try SkillDeletionOperationStore(connection: connection)
        let backupStore = try SkillBackupStore(connection: connection)
        try requireAuthority()
        try operationStore.transaction {
            try backupStore.insertPreparing(backup)
            _ = try operationStore.insertPrepared(draft)
        }
    }

    func listBackups(originalSkillID: SkillID) throws -> [SkillBackupRecord] {
        try withStableSkillLifecycleErrors(.backupRead) {
            try requireAuthority()
            return try SkillBackupStore(connection: connection).list(
                originalSkillID: originalSkillID
            )
        }
    }

    func validateBackup(_ backupID: SkillBackupID) throws -> SkillBackupRecord {
        try withStableSkillLifecycleErrors(.backupRead) {
            try requireAuthority()
            let store = try SkillBackupStore(connection: connection)
            guard let backup = try store.load(backupID), backup.state == .available else {
                throw SkillDeletionError.backupCorrupt
            }
            _ = try backupFileSystem.validate(
                locator: backup.locator,
                expectedIdentity: backup.directoryIdentity,
                expectedManifestDigest: backup.manifestDigest,
                expectedFingerprint: backup.contentFingerprint
            )
            return backup
        }
    }

    func setBackupPinned(
        _ backupID: SkillBackupID,
        isPinned: Bool
    ) throws -> SkillBackupRecord {
        try withStableSkillLifecycleErrors(.backupRead) {
            try requireAuthority()
            let store = try SkillBackupStore(connection: connection)
            guard let current = try store.load(backupID), current.state == .available else {
                throw SkillDeletionError.backupCorrupt
            }
            let replacement = try backupReplacement(
                current,
                isPinned: isPinned,
                updatedAtMilliseconds: deletionTimestamp(after: current.updatedAtMilliseconds)
            )
            try requireAuthority()
            try store.replace(expected: current, with: replacement)
            return replacement
        }
    }

    func deletionResult(
        _ operation: SkillDeletionOperationRecord
    ) -> SkillDeletionResult {
        let status: SkillDeletionStatus
        if operation.outcome == .needsRepair || operation.cleanupState == .needsRepair {
            status = .needsRepair
        } else if operation.outcome == .applied && operation.cleanupState == .completed {
            status = .completed
        } else if operation.outcome == .applied {
            status = .cleanupPending
        } else {
            status = .operationInProgress
        }
        return SkillDeletionResult(
            operationID: operation.operationID,
            backupID: operation.backupID,
            status: status
        )
    }

    func deletionDomain(
        _ operation: SkillDeletionOperationRecord
    ) throws -> StoredSkillDomainSnapshot {
        let payload = try SSOTWritePayloadCodec.decode(operation.domainPayload)
        let expectation = try deletionExpectation(operation)
        return StoredSkillDomainSnapshot(
            payload: payload,
            revision: expectation.databaseRevision
        )
    }

    func deletionExpectation(
        _ operation: SkillDeletionOperationRecord
    ) throws -> SkillDeletionExpectation {
        try SkillDeletionExpectation.decode(
            operation.expectationPayload,
            skillID: operation.skillID
        )
    }

    func finishDeletionCleanup(
        _ current: SkillDeletionOperationRecord
    ) throws -> SkillDeletionResult {
        let store = try SkillDeletionOperationStore(connection: connection)
        var operation = try store.load(current.operationID)
        guard operation.phase == .databaseCommitted
                || (operation.phase == .completed && operation.outcome == .applied) else {
            return deletionResult(operation)
        }
        guard let identity = operation.quarantineIdentity else {
            throw SkillDeletionError.needsRepair
        }
        let domain = try deletionDomain(operation)
        let reference = SSOTOperationItemReference.recovery(
            operationID: operation.operationID.uuid
        )
        let observation = try fileSystem.observeOperationItem(
            reference,
            expectedIdentity: identity,
            expectedFingerprint: domain.payload.skill.contentFingerprint
        )
        if observation == .expected {
            try requireAuthority()
            try fileSystem.removeExpectedOperationItem(
                reference,
                identity: identity,
                fingerprint: domain.payload.skill.contentFingerprint
            )
        } else if observation != .absent {
            throw SkillDeletionError.needsRepair
        }
        let completed = try deletionTransition(
            operation,
            phase: .completed,
            outcome: .applied,
            cleanupState: .completed
        )
        try requireAuthority()
        try store.transition(expected: operation, to: completed)
        operation = completed
        return deletionResult(operation)
    }

    func cancelPreparedDeletion(
        _ operation: SkillDeletionOperationRecord
    ) throws {
        guard operation.phase == .prepared, operation.outcome == .pending,
              let currentDomain = try journal.storedDomain(operation.skillID) else {
            throw SkillDeletionError.needsRepair
        }
        let expectedDomain = try deletionDomain(operation)
        let expected = try deletionExpectation(operation)
        let currentSelection = try loadDistributionSelection(skillID: operation.skillID)
        let currentOwnership = try DistributionLinkOwnershipStore(connection: connection)
            .load(skillID: operation.skillID)
        guard currentDomain.revision == expectedDomain.revision,
              try SSOTWritePayloadCodec.encode(currentDomain.payload)
                == SSOTWritePayloadCodec.encode(expectedDomain.payload),
              currentSelection.bindings == expected.selection.bindings,
              currentSelection.isExplicitlyConfigured
                == expected.selection.isExplicitlyConfigured,
              currentOwnership == expected.ownership,
              try fileSystem.observeFinal(
                skillID: operation.skillID,
                expectedIdentity: operation.ssotIdentity,
                expectedFingerprint: expectedDomain.payload.skill.contentFingerprint
              ) == .expected else {
            throw SkillDeletionError.needsRepair
        }
        let backupStore = try SkillBackupStore(connection: connection)
        guard let backup = try backupStore.load(operation.backupID),
              backup.state == .preparing else {
            throw SkillDeletionError.needsRepair
        }
        let rolledBack = try deletionTransition(
            operation,
            phase: .completed,
            outcome: .rolledBack,
            cleanupState: .notApplicable
        )
        let store = try SkillDeletionOperationStore(connection: connection)
        try requireAuthority()
        try store.transaction {
            try backupStore.deletePreparingInCurrentTransaction(expected: backup)
            try store.transitionInCurrentTransaction(expected: operation, to: rolledBack)
        }
    }

    func rollBackDeletion(_ current: SkillDeletionOperationRecord) throws {
        let store = try SkillDeletionOperationStore(connection: connection)
        let operation = try store.load(current.operationID)
        guard operation.phase != .databaseCommitted,
              operation.outcome != .applied else {
            throw SkillDeletionError.needsRepair
        }
        let domain = try deletionDomain(operation)
        let identity = operation.quarantineIdentity ?? operation.ssotIdentity
        let quarantined = SSOTQuarantinedSkill(
            reference: .recovery(operationID: operation.operationID.uuid),
            identity: identity,
            fingerprint: domain.payload.skill.contentFingerprint
        )
        let quarantineObservation = try fileSystem.observeOperationItem(
            quarantined.reference,
            expectedIdentity: identity,
            expectedFingerprint: quarantined.fingerprint
        )
        if quarantineObservation == .expected {
            try requireAuthority()
            try fileSystem.restoreQuarantinedFinal(
                quarantined,
                skillID: operation.skillID
            )
        } else if try fileSystem.observeFinal(
            skillID: operation.skillID,
            expectedIdentity: identity,
            expectedFingerprint: quarantined.fingerprint
        ) != .expected {
            throw SkillDeletionError.needsRepair
        }
        try restoreDeletionDistribution(operation)
        let rolledBack = try deletionTransition(
            operation,
            phase: .completed,
            outcome: .rolledBack,
            cleanupState: .notApplicable
        )
        try requireAuthority()
        try store.transition(expected: operation, to: rolledBack)
    }

    func restoreDeletionDistribution(
        _ operation: SkillDeletionOperationRecord
    ) throws {
        let expected = try deletionExpectation(operation)
        let current = try loadDistributionSelection(skillID: operation.skillID)
        let currentOwnership = try DistributionLinkOwnershipStore(connection: connection)
            .load(skillID: operation.skillID)
        let desired = try desiredScope(expected.selection.bindings)
        let plan = try distribution.dryRun(
            skillID: operation.skillID,
            currentBindings: current.bindings,
            desiredScope: desired,
            desiredConfigured: expected.selection.isExplicitlyConfigured,
            requiredAdapterCodes: desired.requiredAdapterCodes
        )
        guard plan.status != .blocked else { throw SkillDeletionError.needsRepair }
        if plan.status == .executable {
            try requireAuthority()
            let result = try distribution.apply(
                skillID: operation.skillID,
                plan: plan,
                expectedOldBindings: current.bindings,
                expectedOldOwnership: currentOwnership
            )
            guard result.phase == .completed, result.outcome == .applied else {
                throw SkillDeletionError.needsRepair
            }
        }
        let readback = try loadDistributionSelection(skillID: operation.skillID)
        guard readback.bindings.map(\.intent)
                == expected.selection.bindings.map(\.intent),
              readback.isExplicitlyConfigured
                == expected.selection.isExplicitlyConfigured else {
            throw SkillDeletionError.needsRepair
        }
    }

    func markDeletionNeedsRepair(
        _ current: SkillDeletionOperationRecord,
        error: Error
    ) throws {
        let store = try SkillDeletionOperationStore(connection: connection)
        let operation = try store.load(current.operationID)
        let cleanup: SkillDeletionCleanupState? =
            operation.phase == .completed || operation.phase == .databaseCommitted
            ? .needsRepair : nil
        let replacement = try deletionTransition(
            operation,
            outcome: operation.outcome == .applied ? nil : .needsRepair,
            cleanupState: cleanup,
            attemptIncrement: 1,
            lastError: String(error.localizedDescription.prefix(4_096))
        )
        try requireAuthority()
        try store.transition(expected: operation, to: replacement)
    }

    func deletionTimestamp(after previous: Int64 = -1) -> Int64 {
        max(previous + 1, max(0, hooks.nowMilliseconds()))
    }

    private func desiredScope(
        _ bindings: [DistributionBinding]
    ) throws -> DistributionDesiredScope {
        guard let slug = bindings.first?.distributionSlug else { return .disabled }
        guard bindings.allSatisfy({ $0.distributionSlug == slug }) else {
            throw SkillDeletionError.needsRepair
        }
        if bindings.count == 1, bindings[0].scope == .global {
            return .global(slug)
        }
        let agents = Set(bindings.compactMap(\.scope.adapter))
        guard agents.count == bindings.count else { throw SkillDeletionError.needsRepair }
        return .agents(agents, slug)
    }
}

nonisolated func deletionTransition(
    _ old: SkillDeletionOperationRecord,
    phase: SkillDeletionPhase? = nil,
    outcome: SkillDeletionOutcome? = nil,
    cleanupState: SkillDeletionCleanupState? = nil,
    quarantineIdentity: ManagedItemIdentity? = nil,
    attemptIncrement: Int64 = 0,
    updatedAtMilliseconds: Int64? = nil,
    lastError: String? = nil
) throws -> SkillDeletionOperationRecord {
    try SkillDeletionOperationRecord(
        operationID: old.operationID,
        skillID: old.skillID,
        backupID: old.backupID,
        phase: phase ?? old.phase,
        outcome: outcome ?? old.outcome,
        cleanupState: cleanupState ?? old.cleanupState,
        domainPayload: old.domainPayload,
        expectationPayload: old.expectationPayload,
        distributionPlan: old.distributionPlan,
        ssotIdentity: old.ssotIdentity,
        quarantineLocator: old.quarantineLocator,
        quarantineIdentity: quarantineIdentity ?? old.quarantineIdentity,
        attemptCount: old.attemptCount + attemptIncrement,
        lastError: lastError,
        createdAtMilliseconds: old.createdAtMilliseconds,
        updatedAtMilliseconds: updatedAtMilliseconds
            ?? max(old.updatedAtMilliseconds + 1, old.createdAtMilliseconds)
    )
}

nonisolated func backupReplacement(
    _ old: SkillBackupRecord,
    state: SkillBackupState? = nil,
    isPinned: Bool? = nil,
    restoredSkillID: SkillID? = nil,
    restoreResultJSON: Data? = nil,
    pruneQuarantineLocator: String? = nil,
    pruneQuarantineIdentity: ManagedItemIdentity? = nil,
    lastError: String? = nil,
    updatedAtMilliseconds: Int64
) throws -> SkillBackupRecord {
    try SkillBackupRecord(
        backupID: old.backupID,
        originalSkillID: old.originalSkillID,
        state: state ?? old.state,
        locator: old.locator,
        directoryIdentity: old.directoryIdentity,
        manifestDigest: old.manifestDigest,
        contentFingerprint: old.contentFingerprint,
        isPinned: isPinned ?? old.isPinned,
        restoredSkillID: restoredSkillID ?? old.restoredSkillID,
        restoreResultJSON: restoreResultJSON ?? old.restoreResultJSON,
        pruneQuarantineLocator: pruneQuarantineLocator ?? old.pruneQuarantineLocator,
        pruneQuarantineIdentity: pruneQuarantineIdentity ?? old.pruneQuarantineIdentity,
        lastError: lastError,
        createdAtMilliseconds: old.createdAtMilliseconds,
        updatedAtMilliseconds: updatedAtMilliseconds
    )
}
