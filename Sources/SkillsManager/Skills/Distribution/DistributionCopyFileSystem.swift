import Darwin
import Foundation

nonisolated struct DistributionCopySource: Sendable {
    let absoluteTarget: String
    let ssotIdentity: ManagedItemIdentity
    let snapshot: SkillContentSnapshot
    let physicalTree: CopyPhysicalTreeSnapshot

    func decisionEvidence() throws -> DistributionCopySourceEvidence {
        DistributionCopySourceEvidence(
            absoluteTarget: absoluteTarget,
            ssotIdentity: ssotIdentity,
            contentFingerprint: try SkillContentFingerprint(
                currentDigest: snapshot.fingerprintDigest
            ),
            physicalTreeDigest: physicalTree.digest
        )
    }
}

nonisolated struct DistributionCopySourceEvidence: Equatable, Sendable {
    let absoluteTarget: String
    let ssotIdentity: ManagedItemIdentity
    let contentFingerprint: SkillContentFingerprint
    let physicalTreeDigest: CopyPhysicalTreeDigest
}

nonisolated struct DistributionCopyEvidence: Equatable, Sendable {
    let rootIdentity: ManagedItemIdentity
    let entryIdentity: ManagedItemIdentity
    let contentFingerprint: SkillContentFingerprint
    let physicalTreeDigest: CopyPhysicalTreeDigest
}

nonisolated struct DistributionCopyCapture: Sendable {
    let snapshot: SkillContentSnapshot
    let evidence: DistributionCopyEvidence
}

nonisolated struct DistributionStagedCopy: Equatable, Sendable {
    let temporaryName: String
    let evidence: DistributionCopyEvidence
}

nonisolated struct DistributionQuarantinedCopy: Equatable, Sendable {
    let temporaryName: String
    let evidence: DistributionCopyEvidence
}

nonisolated enum DistributionCopyFilesystemObservation: Equatable, Sendable {
    case missing(rootIdentity: ManagedItemIdentity?)
    case unavailable
    case directory(DistributionCopyEvidence)
    case invalid(rootIdentity: ManagedItemIdentity, entryIdentity: ManagedItemIdentity)
    case unknown(rootIdentity: ManagedItemIdentity, entryIdentity: ManagedItemIdentity)
}

nonisolated extension DistributionSymlinkFileSystem {
    func captureCopy(
        _ entry: DistributionTargetEntry,
        expectedRootIdentity: ManagedItemIdentity,
        expectedEntryIdentity: ManagedItemIdentity
    ) throws -> DistributionCopyCapture {
        let components = try components(for: entry)
        let root = try openDirectory(components: components, createMissing: false)
        defer { Darwin.close(root.descriptor) }
        guard root.identity == expectedRootIdentity else {
            throw DistributionSymlinkFileSystemError.entryChanged
        }
        try requireUniqueName(entry.distributionSlug.value, in: root.descriptor)
        let descriptor = try openCopyDirectory(
            named: entry.distributionSlug.value,
            in: root.descriptor,
            expectedIdentity: expectedEntryIdentity
        )
        defer { Darwin.close(descriptor) }
        let snapshot = try SkillContentSnapshot.capture(
            directoryDescriptor: descriptor,
            displayPath: entry.canonicalLocator
        )
        _ = try snapshot.readUTF8File(relativePath: "SKILL.md")
        let physical = try CopyPhysicalTreeSnapshot.captureTarget(
            directoryDescriptor: descriptor,
            displayPath: entry.canonicalLocator
        )
        try snapshot.requireUnchanged()
        guard try requiredIdentity(
            entry.distributionSlug.value,
            in: root.descriptor
        ) == expectedEntryIdentity else {
            throw DistributionSymlinkFileSystemError.entryChanged
        }
        try verifyRoot(root, components: components)
        return DistributionCopyCapture(
            snapshot: snapshot,
            evidence: DistributionCopyEvidence(
                rootIdentity: root.identity,
                entryIdentity: expectedEntryIdentity,
                contentFingerprint: try SkillContentFingerprint(
                    currentDigest: snapshot.fingerprintDigest
                ),
                physicalTreeDigest: physical.digest
            )
        )
    }

    func copySource(for skillID: SkillID) throws -> DistributionCopySource {
        let ssot = try ssotEvidence(for: skillID)
        let snapshot = try SkillContentSnapshot.capture(
            at: URL(fileURLWithPath: ssot.absoluteTarget, isDirectory: true)
        )
        let physical = try CopyPhysicalTreeSnapshot.captureSource(snapshot)
        guard try ssotEvidence(for: skillID).identity == ssot.identity else {
            throw DistributionSymlinkFileSystemError.entryChanged
        }
        return DistributionCopySource(
            absoluteTarget: ssot.absoluteTarget,
            ssotIdentity: ssot.identity,
            snapshot: snapshot,
            physicalTree: physical
        )
    }

    func requireUnchanged(_ source: DistributionCopySource, skillID: SkillID) throws {
        let current = try ssotEvidence(for: skillID)
        guard current.identity == source.ssotIdentity,
              current.absoluteTarget == source.absoluteTarget else {
            throw DistributionSymlinkFileSystemError.entryChanged
        }
        try source.snapshot.requireUnchanged()
        guard try CopyPhysicalTreeSnapshot.captureSource(source.snapshot).digest
                == source.physicalTree.digest else {
            throw DistributionSymlinkFileSystemError.entryChanged
        }
    }

    func observeCopy(
        _ entry: DistributionTargetEntry
    ) throws -> DistributionCopyFilesystemObservation {
        let components = try components(for: entry)
        let root: DirectoryHandle
        do {
            root = try openDirectory(components: components, createMissing: false)
        } catch DistributionSymlinkFileSystemError.unavailable {
            if try classifyUnavailableRoot(components) == .missing {
                return .missing(rootIdentity: nil)
            }
            return .unavailable
        }
        defer { Darwin.close(root.descriptor) }
        try requireUniqueName(entry.distributionSlug.value, in: root.descriptor)
        guard let identity = try identityIfPresent(
            entry.distributionSlug.value,
            in: root.descriptor
        ) else {
            try verifyRoot(root, components: components)
            return .missing(rootIdentity: root.identity)
        }
        let descriptor: Int32
        do {
            descriptor = try openCopyDirectory(
                named: entry.distributionSlug.value,
                in: root.descriptor,
                expectedIdentity: identity
            )
        } catch DistributionSymlinkFileSystemError.entryChanged {
            return .unknown(rootIdentity: root.identity, entryIdentity: identity)
        }
        defer { Darwin.close(descriptor) }
        do {
            let evidence = try copyEvidence(
                descriptor: descriptor,
                displayPath: entry.canonicalLocator,
                rootIdentity: root.identity,
                entryIdentity: identity
            )
            try verifyRoot(root, components: components)
            return .directory(evidence)
        } catch is SkillContentSnapshotError {
            try verifyRoot(root, components: components)
            return .invalid(rootIdentity: root.identity, entryIdentity: identity)
        }
    }

    func stageCopy(
        _ entry: DistributionTargetEntry,
        source: DistributionCopySource,
        expectedRootIdentity: ManagedItemIdentity,
        operationID: UUID,
        actionIndex: Int
    ) throws -> DistributionStagedCopy {
        let components = try components(for: entry)
        let root = try openDirectory(components: components, createMissing: false)
        defer { Darwin.close(root.descriptor) }
        guard root.identity == expectedRootIdentity else {
            throw DistributionSymlinkFileSystemError.entryChanged
        }
        let name = Self.copyTemporaryName(
            operationID: operationID,
            actionIndex: actionIndex,
            suffix: "staging"
        )
        guard try identityIfPresent(name, in: root.descriptor) == nil,
              Darwin.mkdirat(root.descriptor, name, mode_t(0o700)) == 0 else {
            throw DistributionSymlinkFileSystemError.temporaryEntryExists
        }
        do {
            try hooks.reach(.beforeCopyStage)
            let descriptor = try openCopyDirectory(named: name, in: root.descriptor)
            defer { Darwin.close(descriptor) }
            try source.snapshot.copyFiles(toDirectoryDescriptor: descriptor)
            guard Darwin.fchmod(descriptor, source.physicalTree.rootPermissions) == 0 else {
                throw posix("set Copy staging permissions")
            }
            let stagedSnapshot = try SkillContentSnapshot.capture(
                directoryDescriptor: descriptor,
                displayPath: name
            )
            let stagedPhysical = try CopyPhysicalTreeSnapshot.captureTarget(
                directoryDescriptor: descriptor,
                displayPath: name
            )
            guard stagedSnapshot.fingerprintDigest == source.snapshot.fingerprintDigest,
                  stagedPhysical.digest == source.physicalTree.digest else {
                throw DistributionSymlinkFileSystemError.entryChanged
            }
            try synchronize(stagedSnapshot)
            try hooks.reach(.afterCopyStageBeforeSync)
            try SSOTDurability.syncDirectory(root.descriptor)
            try hooks.reach(.afterCopyStageSync)
            let identity = try requiredIdentity(name, in: root.descriptor)
            try verifyRoot(root, components: components)
            return DistributionStagedCopy(
                temporaryName: name,
                evidence: DistributionCopyEvidence(
                    rootIdentity: root.identity,
                    entryIdentity: identity,
                    contentFingerprint: try SkillContentFingerprint(
                        currentDigest: stagedSnapshot.fingerprintDigest
                    ),
                    physicalTreeDigest: stagedPhysical.digest
                )
            )
        } catch {
            try? removeOwnedCopy(
                named: name,
                rootDescriptor: root.descriptor,
                expectedIdentity: try? identityIfPresent(name, in: root.descriptor),
                expectedContent: nil,
                expectedDigest: nil
            )
            throw error
        }
    }

    func quarantineCopy(
        _ entry: DistributionTargetEntry,
        expected: DistributionCopyEvidence,
        operationID: UUID,
        actionIndex: Int
    ) throws -> DistributionQuarantinedCopy {
        let components = try components(for: entry)
        let root = try openDirectory(components: components, createMissing: false)
        defer { Darwin.close(root.descriptor) }
        guard root.identity == expected.rootIdentity else {
            throw DistributionSymlinkFileSystemError.entryChanged
        }
        try requireCopy(
            named: entry.distributionSlug.value,
            in: root.descriptor,
            expected: expected,
            displayPath: entry.canonicalLocator
        )
        let temporaryName = Self.copyTemporaryName(
            operationID: operationID,
            actionIndex: actionIndex,
            suffix: "quarantine"
        )
        guard try identityIfPresent(temporaryName, in: root.descriptor) == nil else {
            throw DistributionSymlinkFileSystemError.temporaryEntryExists
        }
        try hooks.reach(.beforeRemoveRename)
        guard Darwin.renameatx_np(
                  root.descriptor,
                  entry.distributionSlug.value,
                  root.descriptor,
                  temporaryName,
                  UInt32(RENAME_EXCL)
              ) == 0 else {
            throw posix("quarantine distribution copy")
        }
        try hooks.reach(.afterRemoveRenameBeforeSync)
        try SSOTDurability.syncDirectory(root.descriptor)
        try hooks.reach(.afterRemoveSync)
        try requireCopy(
            named: temporaryName,
            in: root.descriptor,
            expected: expected,
            displayPath: temporaryName
        )
        return DistributionQuarantinedCopy(
            temporaryName: temporaryName,
            evidence: expected
        )
    }

    func promoteCopy(
        _ entry: DistributionTargetEntry,
        staged: DistributionStagedCopy
    ) throws -> DistributionCopyEvidence {
        let components = try components(for: entry)
        let root = try openDirectory(components: components, createMissing: false)
        defer { Darwin.close(root.descriptor) }
        guard root.identity == staged.evidence.rootIdentity,
              try identityIfPresent(entry.distributionSlug.value, in: root.descriptor) == nil else {
            throw DistributionSymlinkFileSystemError.entryChanged
        }
        try requireCopy(
            named: staged.temporaryName,
            in: root.descriptor,
            expected: staged.evidence,
            displayPath: staged.temporaryName
        )
        try hooks.reach(.beforeCopyPromote)
        guard Darwin.renameatx_np(
            root.descriptor,
            staged.temporaryName,
            root.descriptor,
            entry.distributionSlug.value,
            UInt32(RENAME_EXCL)
        ) == 0 else {
            throw posix("promote distribution copy")
        }
        try hooks.reach(.afterCopyPromoteBeforeSync)
        try SSOTDurability.syncDirectory(root.descriptor)
        try hooks.reach(.afterCopyPromoteSync)
        try requireCopy(
            named: entry.distributionSlug.value,
            in: root.descriptor,
            expected: staged.evidence,
            displayPath: entry.canonicalLocator
        )
        try verifyRoot(root, components: components)
        return staged.evidence
    }

    func restoreCopy(
        _ entry: DistributionTargetEntry,
        quarantined: DistributionQuarantinedCopy
    ) throws {
        let components = try components(for: entry)
        let root = try openDirectory(components: components, createMissing: false)
        defer { Darwin.close(root.descriptor) }
        guard root.identity == quarantined.evidence.rootIdentity else {
            throw DistributionSymlinkFileSystemError.entryChanged
        }
        if try identityIfPresent(entry.distributionSlug.value, in: root.descriptor) != nil {
            try requireCopy(
                named: entry.distributionSlug.value,
                in: root.descriptor,
                expected: quarantined.evidence,
                displayPath: entry.canonicalLocator
            )
            guard try identityIfPresent(quarantined.temporaryName, in: root.descriptor) == nil else {
                throw DistributionSymlinkFileSystemError.entryChanged
            }
            return
        }
        try requireCopy(
            named: quarantined.temporaryName,
            in: root.descriptor,
            expected: quarantined.evidence,
            displayPath: quarantined.temporaryName
        )
        try hooks.reach(.beforeRollback)
        guard Darwin.renameatx_np(
            root.descriptor,
            quarantined.temporaryName,
            root.descriptor,
            entry.distributionSlug.value,
            UInt32(RENAME_EXCL)
        ) == 0 else {
            throw posix("restore distribution copy")
        }
        try hooks.reach(.afterRollbackBeforeSync)
        try SSOTDurability.syncDirectory(root.descriptor)
        try hooks.reach(.afterRollbackSync)
    }

    func cleanupCopy(
        _ entry: DistributionTargetEntry,
        quarantined: DistributionQuarantinedCopy
    ) throws {
        let components = try components(for: entry)
        let root = try openDirectory(components: components, createMissing: false)
        defer { Darwin.close(root.descriptor) }
        guard root.identity == quarantined.evidence.rootIdentity else {
            throw DistributionSymlinkFileSystemError.entryChanged
        }
        try hooks.reach(.beforeCleanup)
        try removeOwnedCopy(
            named: quarantined.temporaryName,
            rootDescriptor: root.descriptor,
            expectedIdentity: quarantined.evidence.entryIdentity,
            expectedContent: quarantined.evidence.contentFingerprint,
            expectedDigest: quarantined.evidence.physicalTreeDigest
        )
        try hooks.reach(.afterCleanupBeforeSync)
        try SSOTDurability.syncDirectory(root.descriptor)
        try hooks.reach(.afterCleanupSync)
    }

    func removeCreatedCopy(
        _ entry: DistributionTargetEntry,
        expected: DistributionCopyEvidence
    ) throws {
        let components = try components(for: entry)
        let root = try openDirectory(components: components, createMissing: false)
        defer { Darwin.close(root.descriptor) }
        guard root.identity == expected.rootIdentity else {
            throw DistributionSymlinkFileSystemError.entryChanged
        }
        try removeOwnedCopy(
            named: entry.distributionSlug.value,
            rootDescriptor: root.descriptor,
            expectedIdentity: expected.entryIdentity,
            expectedContent: expected.contentFingerprint,
            expectedDigest: expected.physicalTreeDigest
        )
        try SSOTDurability.syncDirectory(root.descriptor)
    }

    func discardOperationCopy(
        _ entry: DistributionTargetEntry,
        name: String,
        expectedRootIdentity: ManagedItemIdentity?,
        expectedContent: SkillContentFingerprint,
        expectedPhysicalTree: CopyPhysicalTreeDigest
    ) throws {
        let components = try components(for: entry)
        let root: DirectoryHandle
        do {
            root = try openDirectory(components: components, createMissing: false)
        } catch DistributionSymlinkFileSystemError.unavailable {
            return
        }
        defer { Darwin.close(root.descriptor) }
        if let expectedRootIdentity, root.identity != expectedRootIdentity {
            throw DistributionSymlinkFileSystemError.entryChanged
        }
        guard let identity = try identityIfPresent(name, in: root.descriptor) else {
            try verifyRoot(root, components: components)
            return
        }
        let descriptor = try openCopyDirectory(
            named: name,
            in: root.descriptor,
            expectedIdentity: identity
        )
        defer { Darwin.close(descriptor) }
        let evidence = try copyEvidence(
            descriptor: descriptor,
            displayPath: name,
            rootIdentity: root.identity,
            entryIdentity: identity
        )
        guard evidence.contentFingerprint == expectedContent,
              evidence.physicalTreeDigest == expectedPhysicalTree else {
            throw DistributionSymlinkFileSystemError.entryChanged
        }
        try removeOwnedCopy(
            named: name,
            rootDescriptor: root.descriptor,
            expectedIdentity: identity,
            expectedContent: expectedContent,
            expectedDigest: expectedPhysicalTree
        )
        try SSOTDurability.syncDirectory(root.descriptor)
    }

    static func copyTemporaryName(
        operationID: UUID,
        actionIndex: Int,
        suffix: String
    ) -> String {
        ".skillsmanager-distribution-\(operationID.uuidString.lowercased())-\(actionIndex)-\(suffix)"
    }
}
