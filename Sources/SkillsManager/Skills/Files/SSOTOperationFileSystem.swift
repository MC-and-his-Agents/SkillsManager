import Darwin
import Foundation

/// Descriptor-anchored primitives for the journaled SSOT writer. The caller
/// supplies an already verified root and a lifetime writer-ownership token.
nonisolated final class SSOTOperationFileSystem {
    private let verifiedRoot: VerifiedSSOTRoot
    private let ownership: SSOTWriterOwnership
    private let guardValue: ManagedPathGuard
    private let limits: SkillContentLimits
    private let hooks: SSOTOperationFileSystemTestHooks

    init(
        verifiedRoot: VerifiedSSOTRoot,
        ownership: SSOTWriterOwnership,
        limits: SkillContentLimits = .default,
        hooks: SSOTOperationFileSystemTestHooks = .init()
    ) throws {
        let guardValue = try ManagedPathGuard(verifiedRoot: verifiedRoot)
        try ownership.validateForMutation(using: guardValue)
        self.verifiedRoot = verifiedRoot
        self.ownership = ownership
        self.guardValue = guardValue
        self.limits = limits
        self.hooks = hooks
    }

    var managedRootGuard: ManagedPathGuard { guardValue }
    var managedRootIdentity: ManagedItemIdentity { verifiedRoot.identity }

    func operationItemURL(for reference: SSOTOperationItemReference) -> URL {
        verifiedRoot.url.appendingPathComponent(
            ".skillsmanager-tmp-\(reference.operationID.uuidString.lowercased())",
            isDirectory: true
        )
    }

    func finalURL(skillID: SkillID) -> URL {
        verifiedRoot.url.appendingPathComponent(skillID.directoryName, isDirectory: true)
    }

    func stage(
        sourceSnapshot: SkillContentSnapshot,
        expectedFingerprint: SkillContentFingerprint,
        operationID: UUID,
        checkpoint: @escaping SkillCancellationCheckpoint = {}
    ) throws -> SSOTStagedItem {
        guard expectedFingerprint.algorithmVersion == SkillContentSnapshot.fingerprintAlgorithmVersion,
              sourceSnapshot.fingerprintDigest == expectedFingerprint.digest else {
            throw SSOTOperationFileSystemError.stagedContentMismatch
        }
        let reference = SSOTOperationItemReference.staging(operationID: operationID)
        let url = operationItemURL(for: reference)
        try requireOwnership()
        guard try !guardValue.itemExists(at: url) else {
            throw SSOTOperationFileSystemError.stagingAlreadyExists
        }

        try hooks.reach(.beforeStagingDirectoryCreate)
        guard try !guardValue.itemExists(at: url) else {
            throw SSOTOperationFileSystemError.stagingAlreadyExists
        }
        try requireOwnership()
        let handle = try guardValue.createDirectory(
            at: url,
            afterTemporaryCreate: { [self] _ in try requireOwnership() },
            afterCreate: { [self] in try requireOwnership() },
            admitFailureCleanup: { [self] in try requireOwnership() }
        )
        do {
            try hooks.reach(.afterStagingDirectoryCreateBeforeCopy)
            try requireMutableOperationItem(reference, identity: handle.identity)
            let guardedCheckpoint = mutationCheckpoint(
                checkpoint,
                operationItem: reference,
                identity: handle.identity
            )
            try sourceSnapshot.copyFiles(
                toDirectoryDescriptor: handle.descriptor,
                limits: limits,
                checkpoint: guardedCheckpoint,
                failureCleanupAdmission: { [self] in
                    try requireMutableOperationItem(reference, identity: handle.identity)
                }
            )
            try requireMutableOperationItem(reference, identity: handle.identity)
            let stagedSnapshot = try SkillContentSnapshot.capture(
                directoryDescriptor: handle.descriptor,
                displayPath: url.path,
                limits: limits,
                checkpoint: guardedCheckpoint
            )
            guard stagedSnapshot.fingerprintDigest == expectedFingerprint.digest else {
                throw SSOTOperationFileSystemError.stagedContentMismatch
            }
            try hooks.reach(.beforeStagingDurability)
            try synchronize(snapshot: stagedSnapshot, checkpoint: guardedCheckpoint)
            try hooks.reach(.afterStagingDurabilityBeforeParentSync)
            try SSOTDurability.syncDirectory(guardValue.rootDescriptor)
            try hooks.reach(.afterStagingParentSyncBeforeValidation)
            try requireOwnership()
            try requireExpectedOperationItem(
                reference,
                identity: handle.identity,
                fingerprint: expectedFingerprint
            )
            return SSOTStagedItem(
                reference: reference,
                identity: handle.identity,
                fingerprint: expectedFingerprint
            )
        } catch let preserved as SSOTOperationFileSystemError {
            if case .stagingCleanupFailed = preserved { throw preserved }
            throw SSOTOperationFileSystemError.stagingCleanupFailed(
                preserved.localizedDescription
            )
        } catch {
            throw SSOTOperationFileSystemError.stagingCleanupFailed(
                error.localizedDescription
            )
        }
    }

    func promoteCreate(staged: SSOTStagedItem, skillID: SkillID) throws {
        guard staged.reference.role == .staging else {
            throw SSOTOperationFileSystemError.invalidOperationItemRole
        }
        let stagedURL = operationItemURL(for: staged.reference)
        let finalURL = finalURL(skillID: skillID)
        try requireExpectedOperationItem(
            staged.reference,
            identity: staged.identity,
            fingerprint: staged.fingerprint
        )
        let stagedName = try guardValue.managedName(for: stagedURL).value
        let finalName = try guardValue.managedName(for: finalURL).value
        try hooks.reach(.beforeCreateRename)
        try requireExpectedOperationItem(
            staged.reference,
            identity: staged.identity,
            fingerprint: staged.fingerprint
        )
        guard try guardValue.itemIdentity(at: finalURL) == nil else {
            throw SSOTOperationFileSystemError.destinationAlreadyExists
        }
        try requireOwnership()
        guard Darwin.renameatx_np(
            guardValue.rootDescriptor,
            stagedName,
            guardValue.rootDescriptor,
            finalName,
            UInt32(RENAME_EXCL)
        ) == 0 else {
            if errno == EEXIST {
                throw SSOTOperationFileSystemError.destinationAlreadyExists
            }
            throw SSOTOperationFileSystemError.posix(operation: "promote SSOT Skill", code: errno)
        }
        try hooks.reach(.afterCreateRenameBeforeParentSync)
        try SSOTDurability.syncDirectory(guardValue.rootDescriptor)
        try hooks.reach(.afterCreateParentSyncBeforeValidation)
        try requireOwnership()
        try requireExpectedFinal(
            skillID: skillID,
            identity: staged.identity,
            fingerprint: staged.fingerprint
        )
        guard try guardValue.itemIdentity(at: stagedURL) == nil else {
            throw SSOTOperationFileSystemError.itemChanged
        }
    }

    func swapReplacement(
        staged: SSOTStagedItem,
        skillID: SkillID,
        expectedOldIdentity: ManagedItemIdentity,
        expectedOldFingerprint: SkillContentFingerprint
    ) throws -> SSOTOperationItemReference {
        guard staged.reference.role == .staging else {
            throw SSOTOperationFileSystemError.invalidOperationItemRole
        }
        let stagedURL = operationItemURL(for: staged.reference)
        let finalURL = finalURL(skillID: skillID)
        try requireExpectedOperationItem(
            staged.reference,
            identity: staged.identity,
            fingerprint: staged.fingerprint
        )
        try requireExpectedFinal(
            skillID: skillID,
            identity: expectedOldIdentity,
            fingerprint: expectedOldFingerprint
        )
        let names = ManagedPathGuard.PromotionNames(
            staged: try guardValue.managedName(for: stagedURL).value,
            target: try guardValue.managedName(for: finalURL).value
        )
        try hooks.reach(.beforeReplacementSwap)
        try requireExpectedOperationItem(
            staged.reference,
            identity: staged.identity,
            fingerprint: staged.fingerprint
        )
        try requireExpectedFinal(
            skillID: skillID,
            identity: expectedOldIdentity,
            fingerprint: expectedOldFingerprint
        )
        try requireOwnership()
        guard guardValue.swap(names) == 0 else {
            throw SSOTOperationFileSystemError.posix(operation: "swap SSOT Skill", code: errno)
        }
        try hooks.reach(.afterReplacementSwapBeforeParentSync)
        try SSOTDurability.syncDirectory(guardValue.rootDescriptor)
        try hooks.reach(.afterReplacementParentSyncBeforeValidation)
        try requireOwnership()
        let recovery = SSOTOperationItemReference.recovery(
            operationID: staged.reference.operationID
        )
        try requireExpectedFinal(
            skillID: skillID,
            identity: staged.identity,
            fingerprint: staged.fingerprint
        )
        try requireExpectedOperationItem(
            recovery,
            identity: expectedOldIdentity,
            fingerprint: expectedOldFingerprint
        )
        return recovery
    }

    func observeFinal(
        skillID: SkillID,
        expectedIdentity: ManagedItemIdentity,
        expectedFingerprint: SkillContentFingerprint,
        checkpoint: SkillCancellationCheckpoint = {}
    ) throws -> SSOTManagedItemObservation {
        try observe(
            url: finalURL(skillID: skillID),
            expectedIdentity: expectedIdentity,
            expectedFingerprint: expectedFingerprint,
            checkpoint: checkpoint
        )
    }

    func observeOperationItem(
        _ reference: SSOTOperationItemReference,
        expectedIdentity: ManagedItemIdentity,
        expectedFingerprint: SkillContentFingerprint,
        checkpoint: SkillCancellationCheckpoint = {}
    ) throws -> SSOTManagedItemObservation {
        try observe(
            url: operationItemURL(for: reference),
            expectedIdentity: expectedIdentity,
            expectedFingerprint: expectedFingerprint,
            checkpoint: checkpoint
        )
    }

    func removeExpectedOperationItem(
        _ reference: SSOTOperationItemReference,
        identity: ManagedItemIdentity,
        fingerprint: SkillContentFingerprint
    ) throws {
        let url = operationItemURL(for: reference)
        guard try observeOperationItem(
            reference,
            expectedIdentity: identity,
            expectedFingerprint: fingerprint
        ) == .expected else {
            throw SSOTOperationFileSystemError.itemChanged
        }
        try hooks.reach(.beforeCleanupRemoval)
        try requireExpectedOperationItem(
            reference,
            identity: identity,
            fingerprint: fingerprint
        )
        try requireOwnership()
        try removeOperationItem(reference, identity: identity)
        try hooks.reach(.afterCleanupRemovalBeforeParentSync)
        try SSOTDurability.syncDirectory(guardValue.rootDescriptor)
        try hooks.reach(.afterCleanupParentSyncBeforeValidation)
        guard try guardValue.itemIdentity(at: url) == nil else {
            throw SSOTOperationFileSystemError.itemChanged
        }
        try requireOwnership()
    }

    private func removeOperationItem(
        _ reference: SSOTOperationItemReference,
        identity: ManagedItemIdentity
    ) throws {
        let name = try guardValue.managedName(for: operationItemURL(for: reference)).value
        let removal = SSOTJournalOwnedItemRemoval(
            rootDescriptor: guardValue.rootDescriptor,
            maximumDepth: limits.maximumPathDepth,
            boundary: removalBoundary
        )
        try removal.remove(named: name, expectedIdentity: identity)
    }

    private func observe(
        url: URL,
        expectedIdentity: ManagedItemIdentity,
        expectedFingerprint: SkillContentFingerprint,
        checkpoint: SkillCancellationCheckpoint
    ) throws -> SSOTManagedItemObservation {
        try verifiedRoot.revalidate()
        guard let actualIdentity = try guardValue.itemIdentity(at: url) else { return .absent }
        guard actualIdentity == expectedIdentity else { return .unknown }
        do {
            let actualFingerprint = try fingerprint(
                at: url,
                expectedIdentity: expectedIdentity,
                checkpoint: checkpoint
            )
            try verifiedRoot.revalidate()
            return actualFingerprint == expectedFingerprint ? .expected : .unknown
        } catch let cancellation as CancellationError {
            throw cancellation
        } catch ManagedPathError.rootReplaced {
            throw ManagedPathError.rootReplaced
        } catch {
            try verifiedRoot.revalidate()
            return .unknown
        }
    }

    private func requireExpectedFinal(
        skillID: SkillID,
        identity: ManagedItemIdentity,
        fingerprint: SkillContentFingerprint
    ) throws {
        guard try observeFinal(
            skillID: skillID,
            expectedIdentity: identity,
            expectedFingerprint: fingerprint
        ) == .expected else {
            throw SSOTOperationFileSystemError.itemChanged
        }
    }

    private func requireExpectedOperationItem(
        _ reference: SSOTOperationItemReference,
        identity: ManagedItemIdentity,
        fingerprint: SkillContentFingerprint
    ) throws {
        guard try observeOperationItem(
            reference,
            expectedIdentity: identity,
            expectedFingerprint: fingerprint
        ) == .expected else {
            throw SSOTOperationFileSystemError.itemChanged
        }
    }

    private func fingerprint(
        at url: URL,
        expectedIdentity: ManagedItemIdentity,
        checkpoint: SkillCancellationCheckpoint
    ) throws -> SkillContentFingerprint {
        try guardValue.withItemDescriptor(at: url, expectedIdentity: expectedIdentity) { descriptor in
            let snapshot = try SkillContentSnapshot.capture(
                directoryDescriptor: descriptor,
                displayPath: url.path,
                limits: limits,
                checkpoint: checkpoint
            )
            return try SkillContentFingerprint(currentDigest: snapshot.fingerprintDigest)
        }
    }

    private func requireOwnership() throws {
        try verifiedRoot.revalidate()
        try ownership.validateForMutation(using: guardValue)
    }

    private func removalBoundary(_ checkpoint: SSOTOperationFileSystemCheckpoint) throws {
        try requireOwnership()
        try hooks.reach(checkpoint)
        try requireOwnership()
    }

    private func requireMutableOperationItem(
        _ reference: SSOTOperationItemReference,
        identity: ManagedItemIdentity
    ) throws {
        try requireOwnership()
        guard try guardValue.itemIdentity(at: operationItemURL(for: reference)) == identity else {
            throw SSOTOperationFileSystemError.itemChanged
        }
        try requireOwnership()
    }

    private func mutationCheckpoint(
        _ checkpoint: @escaping SkillCancellationCheckpoint,
        operationItem reference: SSOTOperationItemReference,
        identity: ManagedItemIdentity
    ) -> SkillCancellationCheckpoint {
        { [self] in
            try requireMutableOperationItem(reference, identity: identity)
            try checkpoint()
            try requireMutableOperationItem(reference, identity: identity)
        }
    }
}
