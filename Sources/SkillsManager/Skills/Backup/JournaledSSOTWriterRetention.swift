import Foundation

nonisolated struct BackupRetentionResult: Sendable {
    let prunedBackupIDs: [SkillBackupID]
    let needsRepairBackupIDs: [SkillBackupID]
}

extension JournaledSSOTWriter {
    func runBackupRetention(
        originalSkillID: SkillID,
        nowMilliseconds: Int64? = nil
    ) throws -> BackupRetentionResult {
        try requireAuthority()
        let now = nowMilliseconds ?? deletionTimestamp()
        guard now >= 0 else { throw SkillDeletionError.conflict }
        try recoverBackupPruning()
        let store = try SkillBackupStore(connection: connection)
        let backups = try store.list(originalSkillID: originalSkillID)
        let cutoff = now - 30 * 24 * 60 * 60 * 1_000
        let available = backups.filter { $0.state == .available }
        let activeSkillExists = try journal.storedDomain(originalSkillID) != nil
        var remainingValid = available.reduce(into: 0) { count, backup in
            if (try? validateBackup(backup.backupID)) != nil { count += 1 }
        }
        var pruned: [SkillBackupID] = []
        var needsRepair: [SkillBackupID] = []
        for backup in available.dropFirst(10)
        where !backup.isPinned && backup.createdAtMilliseconds < cutoff {
            if !activeSkillExists && remainingValid <= 1 { break }
            do {
                try pruneBackup(backup)
                pruned.append(backup.backupID)
                remainingValid = max(0, remainingValid - 1)
            } catch {
                try markBackupNeedsRepair(backup, error: error)
                needsRepair.append(backup.backupID)
            }
        }
        return BackupRetentionResult(
            prunedBackupIDs: pruned,
            needsRepairBackupIDs: needsRepair
        )
    }

    func recoverBackupPruning() throws {
        let store = try SkillBackupStore(connection: connection)
        for backup in try store.recoverable() where backup.state == .pruning {
            do {
                try continuePruning(backup)
            } catch {
                try markBackupNeedsRepair(backup, error: error)
            }
        }
    }

    private func pruneBackup(_ backup: SkillBackupRecord) throws {
        let store = try SkillBackupStore(connection: connection)
        let parentLocator = backup.locator
            .split(separator: "/")
            .dropLast()
            .map(String.init)
            .joined(separator: "/")
        let quarantineLocator = "\(parentLocator)/.skillsmanager-prune-"
            + backup.backupID.uuid.uuidString.lowercased()
        let pruning = try backupReplacement(
            backup,
            state: .pruning,
            pruneQuarantineLocator: quarantineLocator,
            pruneQuarantineIdentity: backup.directoryIdentity,
            updatedAtMilliseconds: deletionTimestamp(after: backup.updatedAtMilliseconds)
        )
        try store.replace(expected: backup, with: pruning)
        try continuePruning(pruning)
    }

    private func continuePruning(_ backup: SkillBackupRecord) throws {
        guard let quarantineLocator = backup.pruneQuarantineLocator,
              let quarantineIdentity = backup.pruneQuarantineIdentity else {
            throw SkillDeletionError.needsRepair
        }
        let observation = try backupFileSystem.pruneObservation(
            finalLocator: backup.locator,
            quarantineLocator: quarantineLocator,
            expectedIdentity: quarantineIdentity
        )
        if observation.finalIdentity != nil, observation.quarantineIdentity != nil {
            throw SkillDeletionError.needsRepair
        }
        if observation.finalIdentity != nil {
            let actual = try backupFileSystem.quarantineForPruning(
                locator: backup.locator,
                expectedIdentity: quarantineIdentity,
                backupID: backup.backupID.uuid
            )
            guard actual == quarantineLocator else { throw SkillDeletionError.needsRepair }
        }
        let readback = try backupFileSystem.pruneObservation(
            finalLocator: backup.locator,
            quarantineLocator: quarantineLocator,
            expectedIdentity: quarantineIdentity
        )
        if readback.quarantineIdentity != nil {
            try backupFileSystem.removePruningQuarantine(
                locator: quarantineLocator,
                expectedIdentity: quarantineIdentity
            )
        }
        let finalReadback = try backupFileSystem.pruneObservation(
            finalLocator: backup.locator,
            quarantineLocator: quarantineLocator,
            expectedIdentity: quarantineIdentity
        )
        guard finalReadback.finalIdentity == nil,
              finalReadback.quarantineIdentity == nil else {
            throw SkillDeletionError.needsRepair
        }
        try SkillBackupStore(connection: connection).deletePruned(expected: backup)
    }

    private func markBackupNeedsRepair(
        _ stale: SkillBackupRecord,
        error: Error
    ) throws {
        let store = try SkillBackupStore(connection: connection)
        guard let current = try store.load(stale.backupID),
              current.state != .needsRepair else { return }
        let replacement = try backupReplacement(
            current,
            state: .needsRepair,
            lastError: String(error.localizedDescription.prefix(4_096)),
            updatedAtMilliseconds: deletionTimestamp(after: current.updatedAtMilliseconds)
        )
        try store.replace(expected: current, with: replacement)
    }
}
