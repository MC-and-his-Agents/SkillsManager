import Foundation

extension JournaledSSOTWriter {
    func recoverySnapshot(for operation: SSOTJournalRecord) throws -> SSOTRecoverySnapshot {
        guard operation.expectedRootIdentity == fileSystem.managedRootIdentity,
              operation.stagingLocator == operationItemName(operation.operationID),
              operation.finalLocator == operation.skillID.directoryName,
              operation.recoveryLocator == expectedRecoveryLocator(operation) else {
            return unknownSnapshot(for: operation)
        }
        try fileSystem.validateAuthority()
        let temporary = try temporaryObservations(for: operation)
        return SSOTRecoverySnapshot(
            operationType: operation.operationType,
            journal: operation.state,
            database: try journal.databaseObservation(for: operation),
            final: try finalObservation(for: operation),
            staging: temporary.staging,
            recovery: temporary.recovery,
            cleanupDebt: try journal.cleanupDebtObservation(for: operation),
            attemptCount: operation.attemptCount,
            lastErrorUTF8ByteCount: operation.lastError?.utf8.count ?? 0
        )
    }

    private func finalObservation(
        for operation: SSOTJournalRecord
    ) throws -> SSOTFinalObservation {
        let new = try fileSystem.observeFinal(
            skillID: operation.skillID,
            expectedIdentity: operation.expectedNewIdentity,
            expectedFingerprint: operation.newFingerprint
        )
        if new == .expected { return .expectedNew }
        if let oldIdentity = operation.expectedOldIdentity,
           let oldFingerprint = operation.oldFingerprint {
            let old = try fileSystem.observeFinal(
                skillID: operation.skillID,
                expectedIdentity: oldIdentity,
                expectedFingerprint: oldFingerprint
            )
            if old == .expected { return .expectedOld }
            if new == .absent, old == .absent { return .absent }
            return .unknown
        }
        return new == .absent ? .absent : .unknown
    }

    private func temporaryObservations(
        for operation: SSOTJournalRecord
    ) throws -> (staging: SSOTStagingObservation, recovery: SSOTRecoveryItemObservation) {
        let stagingReference = SSOTOperationItemReference.staging(
            operationID: operation.operationID.uuid
        )
        let staging = try fileSystem.observeOperationItem(
            stagingReference,
            expectedIdentity: operation.expectedStagedIdentity,
            expectedFingerprint: operation.newFingerprint
        )
        if staging == .expected { return (.expectedNew, .missing) }
        guard let oldIdentity = operation.expectedOldIdentity,
              let oldFingerprint = operation.oldFingerprint else {
            return staging == .absent ? (.missing, .missing) : (.unknown, .missing)
        }
        let recovery = try fileSystem.observeOperationItem(
            .recovery(operationID: operation.operationID.uuid),
            expectedIdentity: oldIdentity,
            expectedFingerprint: oldFingerprint
        )
        if recovery == .expected { return (.missing, .expectedOld) }
        if staging == .absent, recovery == .absent { return (.missing, .missing) }
        return (.unknown, .unknown)
    }

    private func unknownSnapshot(for operation: SSOTJournalRecord) -> SSOTRecoverySnapshot {
        SSOTRecoverySnapshot(
            operationType: operation.operationType,
            journal: operation.state,
            database: .unknown,
            final: .unknown,
            staging: .unknown,
            recovery: .unknown,
            cleanupDebt: .unknown,
            attemptCount: operation.attemptCount,
            lastErrorUTF8ByteCount: operation.lastError?.utf8.count ?? 0
        )
    }

    private func expectedRecoveryLocator(_ operation: SSOTJournalRecord) -> String? {
        operation.operationType == .replace ? operationItemName(operation.operationID) : nil
    }

    func operationItemName(_ operationID: SSOTOperationID) -> String {
        fileSystem.operationItemURL(
            for: .staging(operationID: operationID.uuid)
        ).lastPathComponent
    }
}
