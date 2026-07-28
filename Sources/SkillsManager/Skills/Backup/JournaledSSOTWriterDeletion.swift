import Foundation

extension JournaledSSOTWriter {
    func deletionPreview(skillID: SkillID) throws -> SkillDeletionPreview {
        try withStableSkillLifecycleErrors(.mutation) {
            try requireAuthority()
            let operations = try SkillDeletionOperationStore(connection: connection).recoverable()
                .filter { $0.skillID == skillID }
            if let operation = operations.first {
                let readback = deletionResult(operation)
                return SkillDeletionPreview(
                    skillID: skillID,
                    displayName: try journal.managedSkillRecord(skillID)?.displayName.value ?? "",
                    content: nil,
                    targets: [],
                    status: readback.status,
                    operation: readback,
                    token: nil
                )
            }
            guard let domain = try journal.storedDomain(skillID) else {
                throw SkillDeletionError.skillNotFound
            }
            let selection = try loadDistributionSelection(skillID: skillID)
            let ownership = try DistributionLinkOwnershipStore(connection: connection)
                .load(skillID: skillID)
            let reconcile = try reconcileDistribution(skillID: skillID)
            guard reconcile.status == .inSync else {
                if reconcile.status == .needsRepair { throw SkillDeletionError.needsRepair }
                if reconcile.status == .operationInProgress {
                    throw SkillDeletionError.operationInProgress
                }
                throw SkillDeletionError.conflict
            }
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
            let expectation = SkillDeletionExpectation(
                databaseRevision: domain.revision,
                selection: selection,
                ownership: ownership
            )
            let targets = try selection.bindings.map { binding in
                guard let entry = DistributionTargetCatalog.current.entry(
                    for: binding.scope,
                    slug: binding.distributionSlug
                ) else {
                    throw SkillDeletionError.needsRepair
                }
                return SkillDistributionTargetSummary(
                    scopeKey: binding.scope.targetScopeKey,
                    canonicalLocator: entry.canonicalLocator
                )
            }
            return SkillDeletionPreview(
                skillID: skillID,
                displayName: domain.payload.skill.displayName.value,
                content: SkillContentSummary(
                    displayName: domain.payload.skill.displayName.value,
                    contentFingerprint: domain.payload.skill.contentFingerprint,
                    statistics: snapshot.statistics
                ),
                targets: targets,
                status: .ready,
                operation: nil,
                token: SkillDeletionPreviewToken(
                    skillID: skillID,
                    databaseRevision: domain.revision,
                    domainPayload: try SSOTWritePayloadCodec.encode(domain.payload),
                    expectationPayload: try expectation.canonicalData(),
                    ssotIdentity: ssotIdentity,
                    contentFingerprint: domain.payload.skill.contentFingerprint,
                    statistics: snapshot.statistics
                )
            )
        }
    }

    func deletionOperation(
        _ operationID: SSOTOperationID
    ) throws -> SkillDeletionOperationRecord {
        try withStableSkillLifecycleErrors(.mutation) {
            try requireAuthority()
            return try SkillDeletionOperationStore(connection: connection).load(operationID)
        }
    }

    func deletionReadback(
        _ operationID: SSOTOperationID
    ) throws -> SkillDeletionResult {
        try withStableSkillLifecycleErrors(.mutation) {
            try requireAuthority()
            return deletionResult(
                try SkillDeletionOperationStore(connection: connection).load(operationID)
            )
        }
    }

    func recoverableDeletionReadbacks() throws -> [SkillDeletionResult] {
        try withStableSkillLifecycleErrors(.mutation) {
            try requireAuthority()
            return try SkillDeletionOperationStore(connection: connection)
                .recoverable()
                .map(deletionResult)
        }
    }

    func retryDeletion(
        _ operationID: SSOTOperationID
    ) throws -> SkillDeletionResult {
        try withStableSkillLifecycleErrors(.mutation) {
            try requireAuthority()
            let store = try SkillDeletionOperationStore(connection: connection)
            var operation = try store.load(operationID)
            if operation.phase == .completed,
               operation.outcome == .applied,
               operation.cleanupState == .needsRepair {
                operation = try deletionTransition(
                    operation,
                    cleanupState: .pending,
                    lastError: nil
                )
                try requireAuthority()
                try store.transition(expected: try store.load(operationID), to: operation)
            } else if operation.outcome == .needsRepair {
                let resumed = try deletionTransition(
                    operation,
                    outcome: .pending,
                    cleanupState: operation.cleanupState == .needsRepair ? .pending : nil,
                    attemptIncrement: 1,
                    lastError: nil
                )
                try requireAuthority()
                try store.transition(expected: operation, to: resumed)
                operation = resumed
            }
            return try executeDeletion(operationID)
        }
    }

    func recoverDeletions() throws {
        try withStableSkillLifecycleErrors(.mutation) {
            try performDeletionRecovery()
        }
    }

    private func performDeletionRecovery() throws {
        let store = try SkillDeletionOperationStore(connection: connection)
        for operation in try store.recoverable() {
            guard operation.outcome != .needsRepair,
                  operation.cleanupState != .needsRepair else { continue }
            do {
                switch operation.phase {
                case .prepared:
                    do {
                        try rollBackDeletion(try confirmPublishedBackup(operation))
                    } catch SkillBackupFileSystemError.preparedContentMissing {
                        try cancelPreparedDeletion(operation)
                    }
                case .backupPublished:
                    try rollBackDeletion(operation)
                case .distributionRemoved, .ssotQuarantined:
                    try rollBackDeletion(operation)
                case .databaseCommitted, .completed:
                    _ = try finishDeletionCleanup(operation)
                }
            } catch {
                try markDeletionNeedsRepair(operation, error: error)
            }
        }
        try recoverBackupPruning()
    }

    func executeDeletion(
        _ operationID: SSOTOperationID
    ) throws -> SkillDeletionResult {
        try requireAuthority()
        let store = try SkillDeletionOperationStore(connection: connection)
        var operation = try store.load(operationID)
        guard operation.outcome == .pending else {
            if operation.outcome == .applied {
                return try finishDeletionCleanup(operation)
            }
            if operation.outcome == .needsRepair { throw SkillDeletionError.needsRepair }
            return deletionResult(operation)
        }
        do {
            if operation.phase == .prepared {
                operation = try confirmPublishedBackup(operation)
                try reachDeletionCheckpoint(.afterBackupPublished)
            }
            if operation.phase == .backupPublished {
                try Task.checkCancellation()
                operation = try removeDistribution(operation)
                try reachDeletionCheckpoint(.afterDistributionRemoved)
            }
            if operation.phase == .distributionRemoved {
                operation = try quarantineSSOT(operation)
                try reachDeletionCheckpoint(.afterSSOTQuarantined)
            }
            if operation.phase == .ssotQuarantined {
                operation = try commitDeletedDomain(operation)
                try reachDeletionCheckpoint(.afterDatabaseCommitted)
            }
            try reachDeletionCheckpoint(.beforeCleanup)
            return try finishDeletionCleanup(operation)
        } catch {
            if error is SSOTWriterCheckpointInterruption { throw error }
            let latest = try store.load(operationID)
            if latest.phase == .prepared,
               error as? SkillBackupFileSystemError == .preparedContentMissing {
                try cancelPreparedDeletion(latest)
                throw error
            }
            switch latest.phase {
            case .prepared, .backupPublished, .distributionRemoved, .ssotQuarantined:
                do {
                    try rollBackDeletion(latest)
                } catch {
                    try markDeletionNeedsRepair(
                        try store.load(operationID),
                        error: error
                    )
                }
            case .databaseCommitted, .completed:
                try markDeletionNeedsRepair(
                    latest,
                    error: error
                )
            }
            throw error
        }
    }

    func reachDeletionCheckpoint(
        _ checkpoint: SkillDeletionCheckpoint
    ) throws {
        do {
            try hooks.deletionCheckpoint(checkpoint)
        } catch {
            throw SSOTWriterCheckpointInterruption(detail: error.localizedDescription)
        }
    }

    private func confirmPublishedBackup(
        _ operation: SkillDeletionOperationRecord
    ) throws -> SkillDeletionOperationRecord {
        let backupStore = try SkillBackupStore(connection: connection)
        guard let backup = try backupStore.load(operation.backupID) else {
            throw SkillDeletionError.backupCorrupt
        }
        try backupFileSystem.ensurePublished(
            backupID: backup.backupID.uuid,
            publication: SkillBackupPublication(
                locator: backup.locator,
                identity: backup.directoryIdentity,
                manifestDigest: backup.manifestDigest,
                contentFingerprint: backup.contentFingerprint
            )
        )
        let timestamp = deletionTimestamp(after: operation.updatedAtMilliseconds)
        let available = try backupReplacement(
            backup,
            state: .available,
            updatedAtMilliseconds: timestamp
        )
        let advanced = try deletionTransition(
            operation,
            phase: .backupPublished,
            updatedAtMilliseconds: timestamp
        )
        let operationStore = try SkillDeletionOperationStore(connection: connection)
        try requireAuthority()
        try operationStore.transaction {
            try backupStore.replaceInCurrentTransaction(
                expected: backup,
                with: available
            )
            try operationStore.transitionInCurrentTransaction(
                expected: operation,
                to: advanced
            )
        }
        return advanced
    }

    private func removeDistribution(
        _ operation: SkillDeletionOperationRecord
    ) throws -> SkillDeletionOperationRecord {
        let expectation = try deletionExpectation(operation)
        let current = try loadDistributionSelection(skillID: operation.skillID)
        let ownership = try DistributionLinkOwnershipStore(connection: connection)
            .load(skillID: operation.skillID)
        guard current.bindings == expectation.selection.bindings,
              current.isExplicitlyConfigured
                == expectation.selection.isExplicitlyConfigured,
              ownership == expectation.ownership else {
            throw SkillDeletionError.conflict
        }
        let mode = current.bindings.first?.syncMode ?? .symlink
        let plan = try distributionPlan(
            skillID: operation.skillID,
            desiredConfiguration: DistributionDesiredConfiguration(
                scope: .disabled,
                syncMode: mode
            ),
            desiredConfigured: current.isExplicitlyConfigured,
            requiredAdapterCodes: []
        )
        guard try plan.canonicalJSONData() == operation.distributionPlan,
              plan.status != .blocked else {
            throw SkillDeletionError.conflict
        }
        try requireAuthority()
        if plan.status == .executable {
            let applied = try applyDistribution(
                skillID: operation.skillID,
                plan: plan
            )
            guard applied.phase == .completed, applied.outcome == .applied else {
                throw SkillDeletionError.needsRepair
            }
        }
        let readback = try loadDistributionSelection(skillID: operation.skillID)
        guard readback.bindings.isEmpty,
              try DistributionLinkOwnershipStore(connection: connection)
                .load(skillID: operation.skillID).isEmpty else {
            throw SkillDeletionError.needsRepair
        }
        let advanced = try deletionTransition(operation, phase: .distributionRemoved)
        try requireAuthority()
        try SkillDeletionOperationStore(connection: connection)
            .transition(expected: operation, to: advanced)
        return advanced
    }

    private func quarantineSSOT(
        _ operation: SkillDeletionOperationRecord
    ) throws -> SkillDeletionOperationRecord {
        let domain = try deletionDomain(operation)
        try requireAuthority()
        let quarantined = try fileSystem.quarantineFinal(
            skillID: operation.skillID,
            operationID: operation.operationID.uuid,
            expectedIdentity: operation.ssotIdentity,
            expectedFingerprint: domain.payload.skill.contentFingerprint
        )
        let advanced = try deletionTransition(
            operation,
            phase: .ssotQuarantined,
            cleanupState: .notStarted,
            quarantineIdentity: quarantined.identity
        )
        try requireAuthority()
        try SkillDeletionOperationStore(connection: connection)
            .transition(expected: operation, to: advanced)
        return advanced
    }

    private func commitDeletedDomain(
        _ operation: SkillDeletionOperationRecord
    ) throws -> SkillDeletionOperationRecord {
        let domain = try deletionDomain(operation)
        let advanced = try deletionTransition(operation, phase: .databaseCommitted)
        let store = try SkillDeletionOperationStore(connection: connection)
        try requireAuthority()
        try store.commitDomainDeletion(
            journal: journal,
            skillID: operation.skillID,
            expectedDomain: domain,
            expected: operation,
            replacement: advanced
        )
        return advanced
    }
}
