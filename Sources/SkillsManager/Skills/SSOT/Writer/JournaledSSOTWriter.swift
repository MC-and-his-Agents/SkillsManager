import Foundation

actor JournaledSSOTWriter {
    static let maximumRecoverySteps = 32

    let connection: SQLiteConnection
    let ownership: SSOTWriterOwnership
    let fileSystem: SSOTOperationFileSystem
    let journal: SSOTJournalStore
    let hooks: JournaledSSOTWriterHooks

    private init(
        connection: SQLiteConnection,
        ownership: SSOTWriterOwnership,
        fileSystem: SSOTOperationFileSystem,
        journal: SSOTJournalStore,
        hooks: JournaledSSOTWriterHooks
    ) {
        self.connection = connection
        self.ownership = ownership
        self.fileSystem = fileSystem
        self.journal = journal
        self.hooks = hooks
    }

    static func open(
        managementRoot: VerifiedSSOTRoot,
        ssotRoot: VerifiedSSOTRoot,
        databaseURL: URL,
        hooks: JournaledSSOTWriterHooks = .init()
    ) async throws -> JournaledSSOTWriter {
        guard managementRoot.identity != ssotRoot.identity,
              ssotRoot.url.lastPathComponent == "skills",
              ssotRoot.url.deletingLastPathComponent().standardizedFileURL
                == managementRoot.url.standardizedFileURL else {
            throw ManagedPathError.invalidRoot("SSOT root must be the management root's skills directory")
        }
        let authorityGuard = try ManagedPathGuard(verifiedRoot: managementRoot)
        let ownership = try SSOTWriterOwnership.acquire(using: authorityGuard)
        let connection = try SkillSchemaMigrator.open(at: databaseURL)
        let fileSystem = try SSOTOperationFileSystem(
            verifiedRoot: ssotRoot,
            ownership: ownership,
            hooks: SSOTOperationFileSystemTestHooks(
                onCheckpoint: { point in
                    do { try hooks.fileSystemCheckpoint(point) }
                    catch { throw SSOTWriterCheckpointInterruption(detail: error.localizedDescription) }
                }
            )
        )
        let writer = try JournaledSSOTWriter(
            connection: connection,
            ownership: ownership,
            fileSystem: fileSystem,
            journal: SSOTJournalStore(connection: connection),
            hooks: hooks
        )
        try await writer.recoverAll()
        return writer
    }

    func create(
        payload: SSOTSkillWritePayload,
        sourceSnapshot: SkillContentSnapshot,
        operationID: SSOTOperationID = SSOTOperationID()
    ) throws -> SSOTJournalRecord {
        guard payload.skill.contentFingerprint.digest == sourceSnapshot.fingerprintDigest else {
            throw JournaledSSOTWriterError.invalidInput
        }
        let staged = try stage(
            snapshot: sourceSnapshot,
            fingerprint: payload.skill.contentFingerprint,
            operationID: operationID
        )
        let now = initialTimestamp()
        let record = try SSOTJournalRecord(
            operationID: operationID,
            operationType: .create,
            skillID: payload.skill.skillID,
            state: .init(phase: .prepared, outcome: .pending, cleanupState: .notApplicable),
            stagingLocator: operationItemName(operationID),
            finalLocator: payload.skill.skillID.directoryName,
            recoveryLocator: nil,
            oldFingerprint: nil,
            newFingerprint: payload.skill.contentFingerprint,
            payload: payload,
            expectedStagedIdentity: staged.identity,
            expectedOldIdentity: nil,
            expectedNewIdentity: staged.identity,
            expectedDatabaseRevision: 0,
            expectedRootIdentity: fileSystem.managedRootIdentity,
            createdAtMilliseconds: now,
            updatedAtMilliseconds: now
        )
        try insertAndExecute(record)
        return try journal.loadOperation(operationID)
    }

    func replace(
        payload: SSOTSkillWritePayload,
        sourceSnapshot: SkillContentSnapshot,
        expectedOld: SSOTReplacementExpectation,
        operationID: SSOTOperationID = SSOTOperationID()
    ) throws -> SSOTJournalRecord {
        guard payload.skill.contentFingerprint.digest == sourceSnapshot.fingerprintDigest else {
            throw JournaledSSOTWriterError.invalidInput
        }
        let staged = try stage(
            snapshot: sourceSnapshot,
            fingerprint: payload.skill.contentFingerprint,
            operationID: operationID
        )
        let now = initialTimestamp()
        let record = try SSOTJournalRecord(
            operationID: operationID,
            operationType: .replace,
            skillID: payload.skill.skillID,
            state: .init(phase: .prepared, outcome: .pending, cleanupState: .notStarted),
            stagingLocator: operationItemName(operationID),
            finalLocator: payload.skill.skillID.directoryName,
            recoveryLocator: operationItemName(operationID),
            oldFingerprint: expectedOld.fingerprint,
            newFingerprint: payload.skill.contentFingerprint,
            payload: payload,
            expectedStagedIdentity: staged.identity,
            expectedOldIdentity: expectedOld.identity,
            expectedNewIdentity: staged.identity,
            expectedDatabaseRevision: expectedOld.databaseRevision,
            expectedRootIdentity: fileSystem.managedRootIdentity,
            createdAtMilliseconds: now,
            updatedAtMilliseconds: now
        )
        try insertAndExecute(record)
        return try journal.loadOperation(operationID)
    }

    func recoverAll() throws {
        var firstError: Error?
        for operationID in try journal.recoverableOperationIDs() {
            do {
                _ = try execute(operationID)
            } catch is CancellationError {
                throw CancellationError()
            } catch let error as SSOTWriterOwnershipError {
                throw error
            } catch let error as ManagedPathError where error == .rootReplaced {
                throw error
            } catch let error where isCorruptJournalRecord(error) {
                try requireAuthority()
                try journal.markCorruptOperationNeedsRepair(
                    operationID: operationID,
                    detail: error.localizedDescription,
                    updatedAtMilliseconds: initialTimestamp()
                )
                if firstError == nil {
                    firstError = JournaledSSOTWriterError.operationNeedsRepair(
                        operationID,
                        .invalidJournalState
                    )
                }
            } catch {
                if firstError == nil { firstError = error }
            }
        }
        if let firstError { throw firstError }
        try requireNoRepairBlockers()
    }

    private func stage(
        snapshot: SkillContentSnapshot,
        fingerprint: SkillContentFingerprint,
        operationID: SSOTOperationID
    ) throws -> SSOTStagedItem {
        try checkpoint(.beforeStaging, operationID)
        let staged = try fileSystem.stage(
            sourceSnapshot: snapshot,
            expectedFingerprint: fingerprint,
            operationID: operationID.uuid,
            checkpoint: { try Task.checkCancellation() }
        )
        try checkpoint(.afterStaging, operationID)
        return staged
    }

    private func insertAndExecute(_ record: SSOTJournalRecord) throws {
        try checkpoint(.beforePreparedInsert, record.operationID)
        try requireAuthority()
        try journal.insertPrepared(record)
        try checkpoint(.afterPreparedInsert, record.operationID)
        let terminal = try execute(record.operationID)
        guard terminal.state.phase == .completed,
              terminal.state.outcome == .applied else {
            throw JournaledSSOTWriterError.operationRolledBack(record.operationID)
        }
    }

    func checkpoint(
        _ point: SSOTWriterCheckpoint,
        _ operationID: SSOTOperationID
    ) throws {
        do { try hooks.checkpoint(point, operationID) }
        catch { throw SSOTWriterCheckpointInterruption(detail: error.localizedDescription) }
    }

    func timestamp(for operation: SSOTJournalRecord) -> Int64 {
        max(operation.updatedAtMilliseconds, initialTimestamp())
    }

    func requireAuthority() throws {
        try fileSystem.validateAuthority()
    }

    private func requireNoRepairBlockers() throws {
        guard let blocker = try journal.firstRepairRequiredOperation() else { return }
        throw JournaledSSOTWriterError.operationNeedsRepair(blocker.operationID, blocker.code)
    }

    private func isCorruptJournalRecord(_ error: Error) -> Bool {
        guard let error = error as? SSOTJournalStoreError else { return false }
        switch error {
        case .corruptRecord, .invalidRecord, .payloadMismatch:
            return true
        default:
            return false
        }
    }

    private func initialTimestamp() -> Int64 {
        max(0, hooks.nowMilliseconds())
    }
}
