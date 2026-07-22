import Darwin
import Foundation
import Testing

@testable import SkillsManager

@Suite("SSOT journal store")
struct SSOTJournalStoreTests {
    enum CleanupRepairFixture: CaseIterable {
        case appliedRecovery
        case rolledBackStaging
    }

    @Test("create commits the complete payload and journal phase atomically")
    func commitsCreateDomain() throws {
        try withJournalStore { store, connection in
            let payload = try makePayload(name: "Original", digestByte: 0x11, alias: "original")
            let operation = try makeCreateOperation(payload: payload)
            try store.insertPrepared(operation)
            try store.recordFilesystemApplied(
                operationID: operation.operationID,
                updatedAtMilliseconds: 2
            )

            try store.commitCreate(
                operationID: operation.operationID,
                updatedAtMilliseconds: 3
            )

            #expect(try store.databaseObservation(for: operation) == .expectedNew)
            #expect(try store.loadOperation(operation.operationID).state.phase == .databaseCommitted)
            #expect(try connection.querySingleText(
                "SELECT provider_identifier FROM provider_aliases"
            ) == "original")
            #expect(try connection.querySingleInt(
                "SELECT db_revision FROM skills"
            ) == 0)
        }
    }

    @Test("replace uses revision CAS and replaces source metadata in one transaction")
    func commitsReplacementDomain() throws {
        try withJournalStore { store, connection in
            let original = try makePayload(name: "Original", digestByte: 0x11, alias: "original")
            let create = try makeCreateOperation(payload: original)
            try commitCreate(create, store: store)

            let replacement = try makePayload(
                skillID: original.skill.skillID,
                name: "Replacement",
                digestByte: 0x22,
                alias: "replacement"
            )
            let operation = try makeReplaceOperation(old: original, new: replacement)
            try store.insertPrepared(operation)
            try store.recordFilesystemApplied(
                operationID: operation.operationID,
                updatedAtMilliseconds: 6
            )

            try store.commitReplacement(
                operationID: operation.operationID,
                updatedAtMilliseconds: 7
            )

            #expect(try store.databaseObservation(for: operation) == .expectedNew)
            #expect(try connection.querySingleText("SELECT display_name FROM skills") == "Replacement")
            #expect(try connection.querySingleInt("SELECT db_revision FROM skills") == 1)
            #expect(try connection.querySingleText(
                "SELECT provider_identifier FROM provider_aliases"
            ) == "replacement")
        }
    }

    @Test("replace revision conflict rolls back both domain and phase")
    func rejectsRevisionConflictAtomically() throws {
        try withJournalStore { store, connection in
            let original = try makePayload(name: "Original", digestByte: 0x11, alias: "original")
            let create = try makeCreateOperation(payload: original)
            try commitCreate(create, store: store)
            let replacement = try makePayload(
                skillID: original.skill.skillID,
                name: "Replacement",
                digestByte: 0x22,
                alias: "replacement"
            )
            let operation = try makeReplaceOperation(old: original, new: replacement)
            try store.insertPrepared(operation)
            try store.recordFilesystemApplied(
                operationID: operation.operationID,
                updatedAtMilliseconds: 6
            )
            try connection.execute("UPDATE skills SET db_revision = 9")

            #expect(throws: SSOTJournalStoreError.databaseConflict) {
                try store.commitReplacement(
                    operationID: operation.operationID,
                    updatedAtMilliseconds: 7
                )
            }

            #expect(try connection.querySingleText("SELECT display_name FROM skills") == "Original")
            #expect(try store.loadOperation(operation.operationID).state.phase == .filesystemApplied)
        }
    }

    @Test("database observation compares source and aliases, not only fingerprint")
    func observesCompletePayload() throws {
        try withJournalStore { store, connection in
            let payload = try makePayload(name: "Original", digestByte: 0x11, alias: "original")
            let operation = try makeCreateOperation(payload: payload)
            try commitCreate(operation, store: store)
            #expect(try store.databaseObservation(for: operation) == .expectedNew)

            try connection.execute(
                "UPDATE provider_aliases SET provider_identifier = 'externally-modified'"
            )
            #expect(try store.databaseObservation(for: operation) == .unknown)
        }
    }

    @Test("staging cleanup debt binds rollback and retry success atomically")
    func handlesRolledBackCleanupDebt() throws {
        try withJournalStore { store, connection in
            let payload = try makePayload(name: "Original", digestByte: 0x11, alias: "original")
            let operation = try makeCreateOperation(payload: payload)
            try store.insertPrepared(operation)
            let debt = try makeStagingDebt(for: operation)

            try store.completeRolledBackWithCleanupDebt(
                operationID: operation.operationID,
                debt: debt,
                updatedAtMilliseconds: 2
            )

            let pending = try store.loadOperation(operation.operationID)
            #expect(pending.state == .init(
                phase: .completed,
                outcome: .rolledBack,
                cleanupState: .pending
            ))
            #expect(try store.cleanupDebtObservation(for: pending) == .verifiedStaging)

            try store.completeCleanupDebt(
                operationID: operation.operationID,
                debtID: debt.debtID,
                updatedAtMilliseconds: 3
            )
            let completed = try store.loadOperation(operation.operationID)
            #expect(completed.state.cleanupState == .completed)
            #expect(try connection.querySingleInt("SELECT count(*) FROM cleanup_debts") == 0)
        }
    }

    @Test("recovery cleanup debt binds applied replacement and records retries")
    func handlesAppliedCleanupDebt() throws {
        try withJournalStore { store, connection in
            let original = try makePayload(name: "Original", digestByte: 0x11, alias: "original")
            let create = try makeCreateOperation(payload: original)
            try commitCreate(create, store: store)
            let replacement = try makePayload(
                skillID: original.skill.skillID,
                name: "Replacement",
                digestByte: 0x22,
                alias: "replacement"
            )
            let operation = try makeReplaceOperation(old: original, new: replacement)
            try store.insertPrepared(operation)
            try store.recordFilesystemApplied(operationID: operation.operationID, updatedAtMilliseconds: 6)
            try store.commitReplacement(operationID: operation.operationID, updatedAtMilliseconds: 7)
            let debt = try makeRecoveryDebt(for: operation)

            try store.completeAppliedWithCleanupDebt(
                operationID: operation.operationID,
                debt: debt,
                updatedAtMilliseconds: 8
            )
            let pending = try store.loadOperation(operation.operationID)
            #expect(try store.cleanupDebtObservation(for: pending) == .verifiedRecovery)

            try store.recordCleanupDebtFailure(
                operationID: operation.operationID,
                debtID: debt.debtID,
                errorCode: "ioFailure",
                updatedAtMilliseconds: 9
            )
            #expect(try connection.querySingleInt(
                "SELECT attempt_count FROM cleanup_debts"
            ) == 1)
            #expect(try store.loadOperation(operation.operationID).attemptCount == 1)
        }
    }

    @Test(
        "cleanup identity drift becomes durable repair debt",
        arguments: CleanupRepairFixture.allCases
    )
    func persistsCleanupRepairDebt(_ fixture: CleanupRepairFixture) throws {
        try withJournalStoreURL { databaseURL, store, _ in
            let (pending, debt) = try prepareCleanupRepairFixture(fixture, store: store)

            try store.markCleanupNeedsRepair(
                operationID: pending.operationID,
                debtID: debt.debtID,
                errorCode: .cleanupIdentityDrift,
                updatedAtMilliseconds: 10
            )

            let marked = try store.loadOperation(pending.operationID)
            #expect(marked.state.phase == .completed)
            #expect(marked.state.outcome == pending.state.outcome)
            #expect(marked.state.cleanupState == .needsRepair)
            #expect(marked.cleanupDebtID == debt.debtID)
            #expect(marked.attemptCount == pending.attemptCount)
            let loadedDebt = try store.loadCleanupDebt(for: marked)
            let markedDebt = try #require(loadedDebt)
            #expect(markedDebt.attemptCount == debt.attemptCount + 1)
            #expect(markedDebt.lastErrorCode == SSOTRecoveryErrorCode.cleanupIdentityDrift.rawValue)
            #expect(try store.recoverableOperations().isEmpty)
            #expect(try store.repairRequiredOperations().map(\.operationID) == [pending.operationID])

            #expect(throws: SSOTJournalStoreError.stateConflict) {
                try store.completeCleanupDebt(
                    operationID: pending.operationID,
                    debtID: debt.debtID,
                    updatedAtMilliseconds: 11
                )
            }
            #expect(throws: SSOTJournalStoreError.stateConflict) {
                try store.recordCleanupDebtFailure(
                    operationID: pending.operationID,
                    debtID: debt.debtID,
                    errorCode: "retry",
                    updatedAtMilliseconds: 11
                )
            }
            #expect(throws: SSOTJournalStoreError.stateConflict) {
                try store.markCleanupNeedsRepair(
                    operationID: pending.operationID,
                    debtID: debt.debtID,
                    errorCode: .cleanupIdentityDrift,
                    updatedAtMilliseconds: 11
                )
            }

            let reopened = try SSOTJournalStore(
                connection: SkillSchemaMigrator.open(at: databaseURL)
            )
            let reopenedOperation = try reopened.loadOperation(pending.operationID)
            #expect(reopenedOperation.state.cleanupState == .needsRepair)
            #expect(reopenedOperation.cleanupDebtID == debt.debtID)
            let reopenedDebt = try #require(try reopened.loadCleanupDebt(for: reopenedOperation))
            #expect(reopenedDebt.debtID == debt.debtID)
            #expect(
                reopenedDebt.lastErrorCode
                    == SSOTRecoveryErrorCode.cleanupIdentityDrift.rawValue
            )
            #expect(try reopened.repairRequiredOperations().map(\.operationID) == [pending.operationID])
            let reopenedBlocker = try #require(try reopened.firstRepairRequiredOperation())
            #expect(reopenedBlocker.operationID == pending.operationID)
            #expect(reopenedBlocker.code == .cleanupIdentityDrift)
        }
    }

    @Test("cleanup repair transition rejects the wrong debt atomically")
    func rejectsWrongCleanupDebtAtomically() throws {
        try withJournalStore { store, connection in
            let (pending, debt) = try prepareCleanupRepairFixture(.rolledBackStaging, store: store)

            #expect(throws: SSOTJournalStoreError.stateConflict) {
                try store.markCleanupNeedsRepair(
                    operationID: pending.operationID,
                    debtID: SSOTCleanupDebtID(),
                    errorCode: .cleanupIdentityDrift,
                    updatedAtMilliseconds: 10
                )
            }

            #expect(try store.loadOperation(pending.operationID).state.cleanupState == .pending)
            #expect(try connection.querySingleInt(
                "SELECT attempt_count FROM cleanup_debts"
            ) == 0)
            #expect(try store.loadCleanupDebt(for: pending)?.debtID == debt.debtID)
        }
    }
}

private func withJournalStore(
    _ body: (SSOTJournalStore, SQLiteConnection) throws -> Void
) throws {
    try withJournalStoreURL { _, store, connection in
        try body(store, connection)
    }
}

private func withJournalStoreURL(
    _ body: (URL, SSOTJournalStore, SQLiteConnection) throws -> Void
) throws {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("ssot-journal-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
    defer { try? FileManager.default.removeItem(at: root) }
    let databaseURL = root.appendingPathComponent("manager.sqlite")
    let connection = try SkillSchemaMigrator.open(at: databaseURL)
    try body(databaseURL, try SSOTJournalStore(connection: connection), connection)
}

private func prepareCleanupRepairFixture(
    _ fixture: SSOTJournalStoreTests.CleanupRepairFixture,
    store: SSOTJournalStore
) throws -> (SSOTJournalRecord, SSOTCleanupDebtRecord) {
    let original = try makePayload(name: "Original", digestByte: 0x11, alias: "original")
    switch fixture {
    case .rolledBackStaging:
        let operation = try makeCreateOperation(payload: original)
        try store.insertPrepared(operation)
        let debt = try makeStagingDebt(for: operation)
        try store.completeRolledBackWithCleanupDebt(
            operationID: operation.operationID, debt: debt, updatedAtMilliseconds: 2
        )
        return (try store.loadOperation(operation.operationID), debt)
    case .appliedRecovery:
        try commitCreate(try makeCreateOperation(payload: original), store: store)
        let replacement = try makePayload(
            skillID: original.skill.skillID,
            name: "Replacement",
            digestByte: 0x22,
            alias: "replacement"
        )
        let operation = try makeReplaceOperation(old: original, new: replacement)
        try store.insertPrepared(operation)
        try store.recordFilesystemApplied(operationID: operation.operationID, updatedAtMilliseconds: 6)
        try store.commitReplacement(operationID: operation.operationID, updatedAtMilliseconds: 7)
        let debt = try makeRecoveryDebt(for: operation)
        try store.completeAppliedWithCleanupDebt(
            operationID: operation.operationID, debt: debt, updatedAtMilliseconds: 8
        )
        return (try store.loadOperation(operation.operationID), debt)
    }
}

private func commitCreate(_ operation: SSOTJournalRecord, store: SSOTJournalStore) throws {
    try store.insertPrepared(operation)
    try store.recordFilesystemApplied(operationID: operation.operationID, updatedAtMilliseconds: 2)
    try store.commitCreate(operationID: operation.operationID, updatedAtMilliseconds: 3)
    try store.completeApplied(
        operationID: operation.operationID,
        cleanupState: .notApplicable,
        updatedAtMilliseconds: 4
    )
}

private func makePayload(
    skillID: SkillID = SkillID(UUID(uuidString: "aaaaaaaa-1111-4222-8333-bbbbbbbbbbbb")!),
    name: String,
    digestByte: UInt8,
    alias: String
) throws -> SSOTSkillWritePayload {
    let sourceID = SourceID(UUID(uuidString: "bbbbbbbb-2222-4333-8444-cccccccccccc")!)
    return try SSOTSkillWritePayload(
        skill: ManagedSkillRecord(
            skillID: skillID,
            displayName: SkillDisplayName(name),
            defaultDistributionSlug: DefaultDistributionSlug(validating: name.lowercased()),
            contentFingerprint: SkillContentFingerprint(
                algorithmVersion: 1,
                digest: Data(repeating: digestByte, count: 32)
            ),
            createdAtMilliseconds: 1,
            updatedAtMilliseconds: 1
        ),
        source: SkillSourceRecord(
            sourceID: sourceID,
            skillID: skillID,
            repositoryURL: try NormalizedRepositoryURL("https://example.com/repository"),
            subpath: try RepositorySubpath("skills/demo"),
            revision: try SourceRevision(alias)
        ),
        providerAliases: [
            ProviderAliasRecord(
                sourceID: sourceID,
                identity: try ProviderAliasIdentity(provider: "skills.sh", identifier: alias)
            ),
        ]
    )
}

private func makeCreateOperation(payload: SSOTSkillWritePayload) throws -> SSOTJournalRecord {
    let operationID = SSOTOperationID()
    return try SSOTJournalRecord(
        operationID: operationID,
        operationType: .create,
        skillID: payload.skill.skillID,
        state: .init(phase: .prepared, outcome: .pending, cleanupState: .notApplicable),
        stagingLocator: ".skillsmanager-tmp-\(operationID.uuid.uuidString.lowercased())",
        finalLocator: payload.skill.skillID.directoryName,
        recoveryLocator: nil,
        oldFingerprint: nil,
        newFingerprint: payload.skill.contentFingerprint,
        payload: payload,
        expectedStagedIdentity: journalIdentity(inode: 1),
        expectedOldIdentity: nil,
        expectedNewIdentity: journalIdentity(inode: 2),
        expectedDatabaseRevision: 0,
        expectedRootIdentity: journalIdentity(inode: 9),
        createdAtMilliseconds: 1,
        updatedAtMilliseconds: 1
    )
}

private func makeReplaceOperation(
    old: SSOTSkillWritePayload,
    new: SSOTSkillWritePayload
) throws -> SSOTJournalRecord {
    let operationID = SSOTOperationID()
    let suffix = operationID.uuid.uuidString.lowercased()
    return try SSOTJournalRecord(
        operationID: operationID,
        operationType: .replace,
        skillID: new.skill.skillID,
        state: .init(phase: .prepared, outcome: .pending, cleanupState: .notStarted),
        stagingLocator: ".skillsmanager-tmp-staging-\(suffix)",
        finalLocator: new.skill.skillID.directoryName,
        recoveryLocator: ".skillsmanager-tmp-recovery-\(suffix)",
        oldFingerprint: old.skill.contentFingerprint,
        newFingerprint: new.skill.contentFingerprint,
        payload: new,
        expectedStagedIdentity: journalIdentity(inode: 3),
        expectedOldIdentity: journalIdentity(inode: 2),
        expectedNewIdentity: journalIdentity(inode: 4),
        expectedDatabaseRevision: 0,
        expectedRootIdentity: journalIdentity(inode: 9),
        createdAtMilliseconds: 5,
        updatedAtMilliseconds: 5
    )
}

private func makeStagingDebt(for operation: SSOTJournalRecord) throws -> SSOTCleanupDebtRecord {
    try SSOTCleanupDebtRecord(
        operationID: operation.operationID,
        itemRole: .staging,
        recoveryLocator: operation.stagingLocator,
        expectedItemIdentity: operation.expectedStagedIdentity,
        expectedFingerprint: operation.newFingerprint,
        expectedRootIdentity: operation.expectedRootIdentity,
        lastErrorCode: "ioFailure",
        createdAtMilliseconds: 2,
        updatedAtMilliseconds: 2
    )
}

private func makeRecoveryDebt(for operation: SSOTJournalRecord) throws -> SSOTCleanupDebtRecord {
    try SSOTCleanupDebtRecord(
        operationID: operation.operationID,
        itemRole: .recovery,
        recoveryLocator: operation.recoveryLocator!,
        expectedItemIdentity: operation.expectedOldIdentity!,
        expectedFingerprint: operation.oldFingerprint!,
        expectedRootIdentity: operation.expectedRootIdentity,
        lastErrorCode: "ioFailure",
        createdAtMilliseconds: 8,
        updatedAtMilliseconds: 8
    )
}

private func journalIdentity(inode: UInt64) -> ManagedItemIdentity {
    ManagedItemIdentity(persistedComponents: .init(
        device: 1,
        inode: inode,
        fileType: UInt32(S_IFDIR),
        generation: 0
    ))
}
