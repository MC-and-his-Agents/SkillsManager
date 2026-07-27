import Foundation

actor JournaledSSOTWriter {
    static let maximumRecoverySteps = 32

    let connection: SQLiteConnection
    let ownership: SSOTWriterOwnership
    let fileSystem: SSOTOperationFileSystem
    let journal: SSOTJournalStore
    let distribution: DistributionSymlinkExecutor
    let backupFileSystem: SkillBackupFileSystem
    let hooks: JournaledSSOTWriterHooks

    private init(
        connection: SQLiteConnection,
        ownership: SSOTWriterOwnership,
        fileSystem: SSOTOperationFileSystem,
        distribution: DistributionSymlinkExecutor,
        backupFileSystem: SkillBackupFileSystem,
        hooks: JournaledSSOTWriterHooks
    ) throws {
        self.connection = connection
        self.ownership = ownership
        self.fileSystem = fileSystem
        self.distribution = distribution
        self.backupFileSystem = backupFileSystem
        journal = try SSOTJournalStore(connection: connection)
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
        let connection = try SkillSchemaMigrator.open(
            at: databaseURL,
            expectedParentIdentity: managementRoot.identity
        )
        return try await open(
            managementRoot: managementRoot,
            ssotRoot: ssotRoot,
            connection: connection,
            ownership: ownership,
            hooks: hooks
        )
    }

    static func open(
        managementRoot: VerifiedSSOTRoot,
        ssotRoot: VerifiedSSOTRoot,
        connection: sending SQLiteConnection,
        ownership: SSOTWriterOwnership,
        hooks: JournaledSSOTWriterHooks = .init()
    ) async throws -> JournaledSSOTWriter {
        guard connection.accessMode != .readOnly,
              managementRoot.identity != ssotRoot.identity,
              ssotRoot.url.lastPathComponent == "skills",
              ssotRoot.url.deletingLastPathComponent().standardizedFileURL
                == managementRoot.url.standardizedFileURL else {
            throw ManagedPathError.invalidRoot("SSOT root must be the management root's skills directory")
        }
        try ownership.validateForMutation()
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
        let distributionFileSystem = try DistributionSymlinkFileSystem(
            homeURL: FileManager.default.homeDirectoryForCurrentUser
        )
        let distribution = try DistributionSymlinkExecutor(
            connection: connection,
            fileSystem: distributionFileSystem
        )
        let backupFileSystem = try SkillBackupFileSystem(
            managementRoot: managementRoot,
            ownership: ownership
        )
        try distribution.recoverAll()
        let writer = try JournaledSSOTWriter(
            connection: connection,
            ownership: ownership,
            fileSystem: fileSystem,
            distribution: distribution,
            backupFileSystem: backupFileSystem,
            hooks: hooks
        )
        try await writer.recoverAll()
        try await writer.recoverDeletions()
        return writer
    }

    func loadCustomPaths() throws -> [SQLiteCustomPathRecord] {
        try SQLiteCustomPathPersistence(connection: connection).loadAll()
    }

    func insertCustomPath(_ path: CustomSkillPath) throws {
        try requireAuthority()
        try SQLiteCustomPathPersistence(connection: connection).insert(path)
    }

    func removeCustomPath(id: UUID) throws {
        try requireAuthority()
        try SQLiteCustomPathPersistence(connection: connection).remove(id: id)
    }

    func loadPublishState(forSlug slug: String) throws -> SQLitePublishState? {
        try SQLitePublishStatePersistence(connection: connection).load(forSlug: slug)
    }

    func savePublishState(_ state: SQLitePublishState, forSlug slug: String) throws {
        try requireAuthority()
        try SQLitePublishStatePersistence(connection: connection).save(state, forSlug: slug)
    }

    func migrateLegacy(homeURL: URL) throws -> LegacyMigrationResult {
        try LegacyStateMigrationGate.migrateIfNeeded(
            homeURL: homeURL,
            connection: connection,
            ownership: ownership
        )
    }

    func healthDiagnostics() throws -> [LibraryRuntimeDiagnostic] {
        try LibraryHealthInspector.inspect(
            connection: connection,
            ssotRoot: fileSystem.verifiedRoot
        )
    }

    func distributionPlan(
        skillID: SkillID,
        desiredScope: DistributionDesiredScope,
        requiredAdapterCodes: Set<String>,
        catalog: DistributionTargetCatalog = .current
    ) throws -> DistributionPlan {
        try requireAuthority()
        let bindings = try DistributionBindingStore(connection: connection).load(skillID: skillID)
        return try distribution.dryRun(
            skillID: skillID,
            currentBindings: bindings,
            desiredScope: desiredScope,
            requiredAdapterCodes: requiredAdapterCodes,
            catalog: catalog
        )
    }

    func loadDistributionSelection(
        skillID: SkillID
    ) throws -> DistributionSelectionReadback {
        try requireAuthority()
        return DistributionSelectionReadback(
            bindings: try DistributionBindingStore(connection: connection).load(skillID: skillID),
            isExplicitlyConfigured: try DistributionConfigurationStore(connection: connection)
                .load(skillID: skillID)
        )
    }

    func applyDistribution(
        skillID: SkillID,
        plan: DistributionPlan
    ) throws -> DistributionOperationRecord {
        try requireAuthority()
        let bindingStore = DistributionBindingStore(connection: connection)
        let ownershipStore = DistributionLinkOwnershipStore(connection: connection)
        return try distribution.apply(
            skillID: skillID,
            plan: plan,
            expectedOldBindings: bindingStore.load(skillID: skillID),
            expectedOldOwnership: ownershipStore.load(skillID: skillID)
        )
    }

    func reconcileDistribution(
        skillID: SkillID
    ) throws -> DistributionReconcileResult {
        try requireAuthority()
        return try distribution.reconcile(skillID: skillID)
    }

    func discoveryCatalog() throws -> SkillDiscoveryCatalog {
        try journal.discoveryCatalog()
    }

    func managedLocalCatalogReadback() throws -> ManagedLocalCatalogReadback {
        try requireAuthority()
        let root = try ManagedRootReference.capture(at: fileSystem.verifiedRoot.url)
        guard try root.verifiedRoot().identity == fileSystem.verifiedRoot.identity else {
            throw ManagedLocalCatalogError.inconsistentCatalog
        }
        let bindingStore = DistributionBindingStore(connection: connection)
        let skillIDs = try journal.discoveryCatalog().managedSkills.map(\.skillID)
        let skills = try skillIDs.map { skillID in
            guard let domain = try journal.storedDomain(skillID) else {
                throw ManagedLocalCatalogError.inconsistentCatalog
            }
            return ManagedLocalSkillReadback(
                skill: domain.payload.skill,
                providerProvenance: domain.payload.providerProvenance,
                bindings: try bindingStore.load(skillID: skillID)
            )
        }
        return ManagedLocalCatalogReadback(root: root, skills: skills)
    }

    func managedSkillPublicationSnapshot(_ skillID: SkillID) throws -> SkillContentSnapshot {
        try requireAuthority()
        guard let record = try journal.managedSkillRecord(skillID) else {
            throw ManagedLocalCatalogError.skillUnavailable
        }
        guard record.status == .managed else {
            throw ManagedLocalCatalogError.skillNeedsRepair
        }
        let url = fileSystem.finalURL(skillID: skillID)
        guard let identity = try fileSystem.managedRootGuard.itemIdentity(at: url) else {
            throw ManagedLocalCatalogError.skillUnavailable
        }
        return try fileSystem.captureExpectedFinal(
            skillID: skillID,
            expectedIdentity: identity,
            expectedFingerprint: record.contentFingerprint
        )
    }

    func loadManagedPublishState(_ skillID: SkillID) throws -> SQLitePublishState? {
        try requireAuthority()
        return try ManagedPublishStateStore(connection: connection).load(skillID: skillID)
    }

    func saveManagedPublishState(
        _ state: SQLitePublishState,
        skillID: SkillID
    ) throws {
        try requireAuthority()
        try ManagedPublishStateStore(connection: connection).save(state, skillID: skillID)
    }

    func ssotOperationReadback(_ operationID: SSOTOperationID) throws -> SSOTJournalRecord {
        try requireAuthority()
        do {
            try recoverAll()
        } catch {
            if let record = try? journal.loadOperation(operationID) {
                return record
            }
            throw error
        }
        return try journal.loadOperation(operationID)
    }

    func managedSkillReadback(_ skillID: SkillID) throws -> ManagedSkillRecord? {
        try requireAuthority()
        return try journal.managedSkillRecord(skillID)
    }

    func providerProvenance(
        _ identity: ProviderAliasIdentity
    ) throws -> ProviderProvenanceRecord? {
        try requireAuthority()
        return try journal.providerProvenance(identity)
    }

    func storedDomainReadback(
        _ skillID: SkillID
    ) throws -> StoredSkillDomainSnapshot? {
        try requireAuthority()
        return try journal.storedDomain(skillID)
    }

    func importNew(
        payload: SSOTSkillWritePayload,
        sourceSnapshot: SkillContentSnapshot,
        operationID: SSOTOperationID = SSOTOperationID()
    ) throws -> (skill: ManagedSkillRecord, created: Bool) {
        guard !payload.localOrigins.isEmpty else {
            throw JournaledSSOTWriterError.invalidInput
        }
        try requireAuthority()
        try recoverAll()
        if let existing = try journal.resolveExistingImport(origins: payload.localOrigins) {
            return (existing, false)
        }
        _ = try create(
            payload: payload,
            sourceSnapshot: sourceSnapshot,
            operationID: operationID
        )
        return (payload.skill, true)
    }

    func claimExisting(
        skillID: SkillID,
        candidate: SkillDiscoveryCandidate,
        origins: [LocalSkillOriginRecord]
    ) throws -> ManagedSkillRecord {
        try requireAuthority()
        try recoverAll()
        return try journal.claimLocalOrigins(
            skillID: skillID,
            candidate: candidate,
            origins: origins
        )
    }

    func create(
        payload: SSOTSkillWritePayload,
        sourceSnapshot: SkillContentSnapshot,
        operationID: SSOTOperationID = SSOTOperationID()
    ) throws -> SSOTJournalRecord {
        guard payload.skill.contentFingerprint.digest == sourceSnapshot.fingerprintDigest else {
            throw JournaledSSOTWriterError.invalidInput
        }
        try requireProviderProvenanceAvailable(
            payload.providerProvenance,
            existingOwner: nil
        )
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
        guard payload.localOrigins.isEmpty,
              payload.skill.contentFingerprint.digest == sourceSnapshot.fingerprintDigest else {
            throw JournaledSSOTWriterError.invalidInput
        }
        try requireProviderProvenanceAvailable(
            payload.providerProvenance,
            existingOwner: payload.skill.skillID
        )
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

    private func requireProviderProvenanceAvailable(
        _ records: [ProviderProvenanceRecord],
        existingOwner: SkillID?
    ) throws {
        try requireAuthority()
        for record in records {
            if let existing = try journal.providerProvenance(record.identity),
               existing.skillID != existingOwner {
                throw SSOTJournalStoreError.databaseConflict
            }
        }
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
