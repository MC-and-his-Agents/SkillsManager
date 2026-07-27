import Foundation
import Testing

@testable import SkillsManager

@Suite("Skill backup store", .serialized)
struct SkillBackupStoreTests {
    @Test("persists CAS transitions, restore identity, and pruning deletion")
    func lifecycle() throws {
        try withSkillSchemaV9 { connection, root in
            let identity = try ManagedRootReference.capture(at: root).verifiedRoot().identity
            let store = try SkillBackupStore(connection: connection)
            let preparing = try backupRecord(identity: identity, state: .preparing, updated: 1)
            try store.insertPreparing(preparing)
            #expect(try store.load(preparing.backupID) == preparing)
            try connection.withImmediateTransaction {
                try store.deletePreparingInCurrentTransaction(expected: preparing)
            }
            #expect(try store.load(preparing.backupID) == nil)
            try store.insertPreparing(preparing)

            let available = try backupRecord(
                identity: identity,
                state: .available,
                restoredSkillID: SkillID(
                    UUID(uuidString: "9999aaaa-bbbb-4ccc-8ddd-eeeeffff0000")!
                ),
                restoreResult: Data("{\"warnings\":[]}".utf8),
                updated: 2
            )
            try store.replace(expected: preparing, with: available)
            #expect(try store.list(originalSkillID: preparing.originalSkillID) == [available])
            #expect(throws: SkillBackupStoreError.conflict) {
                try store.replace(expected: preparing, with: available)
            }

            let pruning = try backupRecord(
                identity: identity,
                state: .pruning,
                restoredSkillID: available.restoredSkillID,
                restoreResult: available.restoreResultJSON,
                pruneLocator: "00112233/prune",
                pruneIdentity: identity,
                updated: 3
            )
            try store.replace(expected: available, with: pruning)
            try store.deletePruned(expected: pruning)
            #expect(try store.load(preparing.backupID) == nil)
        }
    }
}

private func backupRecord(
    identity: ManagedItemIdentity,
    state: SkillBackupState,
    restoredSkillID: SkillID? = nil,
    restoreResult: Data? = nil,
    pruneLocator: String? = nil,
    pruneIdentity: ManagedItemIdentity? = nil,
    updated: Int64
) throws -> SkillBackupRecord {
    try SkillBackupRecord(
        backupID: SkillBackupID(
            UUID(uuidString: "aaaaaaaa-1111-4222-8333-bbbbbbbbbbbb")!
        ),
        originalSkillID: SkillID(
            UUID(uuidString: "00112233-4455-4677-8899-aabbccddeeff")!
        ),
        state: state,
        locator: "00112233/1-aaaaaaaa",
        directoryIdentity: identity,
        manifestDigest: Data(repeating: 0x11, count: 32),
        contentFingerprint: SkillContentFingerprint(
            algorithmVersion: 1,
            digest: Data(repeating: 0x22, count: 32)
        ),
        restoredSkillID: restoredSkillID,
        restoreResultJSON: restoreResult,
        pruneQuarantineLocator: pruneLocator,
        pruneQuarantineIdentity: pruneIdentity,
        createdAtMilliseconds: 1,
        updatedAtMilliseconds: updated
    )
}
