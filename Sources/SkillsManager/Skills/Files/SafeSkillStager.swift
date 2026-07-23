import Darwin
import Foundation

/// Copies one validated Skill into a same-filesystem staging directory before promotion.
nonisolated struct SafeSkillStager {
    typealias MetadataWriter = (Int32) throws -> Void
    typealias GuardFactory = (URL) throws -> ManagedPathGuard

    private let fileManager: FileManager
    private let limits: SkillContentLimits
    private let guardFactory: GuardFactory
    let onPromotionLockContention: @Sendable () -> Void

    init(
        fileManager: FileManager = .default,
        limits: SkillContentLimits = .default,
        guardFactory: @escaping GuardFactory = { try ManagedPathGuard(rootURL: $0) },
        onPromotionLockContention: @escaping @Sendable () -> Void = {}
    ) {
        self.fileManager = fileManager
        self.limits = limits
        self.guardFactory = guardFactory
        self.onPromotionLockContention = onPromotionLockContention
    }

    func install(
        sourceRoot: URL,
        expectedFingerprint: String,
        destinationRoot: URL,
        preferredName: String,
        conflictPolicy: SkillInstallConflictPolicy,
        managedRoot: ManagedRootReference? = nil,
        checkpoint: SkillCancellationCheckpoint = {},
        metadataWriter: MetadataWriter = { _ in }
    ) throws -> SafeSkillInstallResult {
        let sourceSnapshot = try SkillContentSnapshot.capture(
            at: sourceRoot,
            limits: limits,
            checkpoint: checkpoint
        )
        return try install(
            sourceSnapshot: sourceSnapshot,
            expectedFingerprint: expectedFingerprint,
            destinationRoot: destinationRoot,
            preferredName: preferredName,
            conflictPolicy: conflictPolicy,
            managedRoot: managedRoot,
            checkpoint: checkpoint,
            metadataWriter: metadataWriter
        )
    }

    func install(
        sourceSnapshot: SkillContentSnapshot,
        expectedFingerprint: String,
        destinationRoot: URL,
        preferredName: String,
        conflictPolicy: SkillInstallConflictPolicy,
        managedRoot: ManagedRootReference?,
        checkpoint: SkillCancellationCheckpoint,
        metadataWriter: MetadataWriter = { _ in }
    ) throws -> SafeSkillInstallResult {
        guard sourceSnapshot.fingerprint == expectedFingerprint else {
            throw SafeSkillStagingError.sourceChanged(
                expected: expectedFingerprint,
                actual: sourceSnapshot.fingerprint
            )
        }
        try checkpoint()
        let destination = try verifiedManagedRoot(destinationRoot, reference: managedRoot)
        let guardrail = try guardFactory(destination.url)
        try guardrail.verifyRootIdentity(expected: destination.identity)
        let normalizedName = try validatedName(preferredName)
        let stagedURL = destination.url.appendingPathComponent(
            ".skillsmanager-tmp-\(UUID().uuidString.lowercased())",
            isDirectory: true
        )
        var stagedHandle: ManagedDirectoryHandle?

        do {
            let handle = try guardrail.createDirectory(at: stagedURL)
            stagedHandle = handle
            try sourceSnapshot.copyFiles(
                toDirectoryDescriptor: handle.descriptor,
                limits: limits,
                checkpoint: checkpoint
            )
            try metadataWriter(handle.descriptor)
            try checkpoint()
            return try withPromotionLock(for: destination.identity) {
                try promote(
                    stagedURL: stagedURL,
                    expectedStaged: handle.identity,
                    in: destination.url,
                    preferredName: normalizedName,
                    conflictPolicy: conflictPolicy,
                    guardrail: guardrail,
                    checkpoint: checkpoint,
                    validateBeforeCommit: { descriptor in
                        try validateStaged(
                            descriptor: descriptor,
                            displayPath: stagedURL.path,
                            expectedFingerprint: expectedFingerprint,
                            checkpoint: checkpoint
                        )
                    },
                    validateCommitted: { descriptor in
                        try validateStaged(
                            descriptor: descriptor,
                            displayPath: stagedURL.path,
                            expectedFingerprint: expectedFingerprint,
                            checkpoint: {}
                        )
                    }
                )
            }
        } catch let indeterminate as ManagedPromotionIndeterminate {
            throw indeterminate
        } catch let operationError {
            try throwAfterCleanup(
                operationError,
                itemURL: stagedURL,
                expectedIdentity: stagedHandle?.identity,
                guardrail: guardrail
            )
        }
    }

    /// Extracts an archive inside the managed destination before using the same
    /// fingerprint verification and atomic promotion path as folder imports.
    func installArchive(
        archiveAt archiveURL: URL,
        expectedArchiveIdentity: ManagedItemIdentity? = nil,
        expectedFingerprint: String,
        destinationRoot: URL,
        preferredName: String,
        conflictPolicy: SkillInstallConflictPolicy,
        managedRoot: ManagedRootReference? = nil,
        checkpoint: SkillCancellationCheckpoint = {},
        metadataWriter: MetadataWriter = { _ in }
    ) throws -> SafeSkillInstallResult {
        try checkpoint()
        let destination = try verifiedManagedRoot(destinationRoot, reference: managedRoot)
        let guardrail = try guardFactory(destination.url)
        try guardrail.verifyRootIdentity(expected: destination.identity)
        let extractionURL = destination.url.appendingPathComponent(
            ".skillsmanager-tmp-archive-\(UUID().uuidString.lowercased())",
            isDirectory: true
        )
        var extractionHandle: ManagedDirectoryHandle?

        do {
            let handle = try guardrail.createDirectory(at: extractionURL)
            extractionHandle = handle
            try checkpoint()
            let archiveLimits = SafeSkillArchive.Limits(
                maximumFileCount: limits.maximumFileCount,
                maximumTotalSize: limits.maximumTotalByteCount,
                maximumFileSize: limits.maximumFileByteCount
            )
            try SafeSkillArchive(limits: archiveLimits).extract(
                archiveAt: archiveURL,
                expectedArchiveIdentity: expectedArchiveIdentity,
                toDirectoryDescriptor: handle.descriptor,
                checkpoint: checkpoint
            )
            try checkpoint()
            let package = try AnchoredSkillPackageLocator.locate(
                in: handle.descriptor,
                displayPath: extractionURL.path
            )
            let sourceSnapshot = try SkillContentSnapshot.capture(
                directoryDescriptor: package.descriptor,
                displayPath: package.displayPath,
                limits: limits,
                checkpoint: checkpoint
            )
            guard sourceSnapshot.fingerprint == expectedFingerprint else {
                throw SafeSkillStagingError.sourceChanged(
                    expected: expectedFingerprint,
                    actual: sourceSnapshot.fingerprint
                )
            }

            let result = try install(
                sourceSnapshot: sourceSnapshot,
                expectedFingerprint: expectedFingerprint,
                destinationRoot: destination.url,
                preferredName: preferredName,
                conflictPolicy: conflictPolicy,
                managedRoot: destination.reference,
                checkpoint: checkpoint,
                metadataWriter: metadataWriter
            )
            return finishArchiveInstall(
                result,
                extractionURL: extractionURL,
                extractionIdentity: handle.identity,
                guardrail: guardrail
            )
        } catch let operationError {
            try throwAfterCleanup(
                operationError,
                itemURL: extractionURL,
                expectedIdentity: extractionHandle?.identity,
                guardrail: guardrail
            )
        }
    }

    private func verifiedManagedRoot(
        _ requestedURL: URL,
        reference: ManagedRootReference?
    ) throws -> (url: URL, reference: ManagedRootReference, identity: ManagedItemIdentity) {
        let requested = requestedURL.standardizedFileURL
        if let reference {
            guard requested == reference.registeredURL || requested == reference.canonicalURL else {
                throw SafeSkillStagingError.destinationRootMismatch
            }
            let verified = try reference.verifiedRoot()
            return (verified.url, reference, verified.identity)
        }
        try fileManager.createDirectory(at: requested, withIntermediateDirectories: true)
        let captured = try ManagedRootReference.capture(at: requested)
        let verified = try captured.verifiedRoot()
        return (verified.url, captured, verified.identity)
    }

    private func promote(
        stagedURL: URL,
        expectedStaged: ManagedItemIdentity,
        in root: URL,
        preferredName: String,
        conflictPolicy: SkillInstallConflictPolicy,
        guardrail: ManagedPathGuard,
        checkpoint: SkillCancellationCheckpoint,
        validateBeforeCommit: (Int32) throws -> Void,
        validateCommitted: (Int32) throws -> Void
    ) throws -> SafeSkillInstallResult {
        switch conflictPolicy {
        case .replaceExisting:
            return try replace(
                stagedURL: stagedURL,
                expectedStaged: expectedStaged,
                in: root,
                preferredName: preferredName,
                guardrail: guardrail,
                checkpoint: checkpoint,
                validateBeforeCommit: validateBeforeCommit,
                validateCommitted: validateCommitted
            )
        case .chooseUniqueName:
            while true {
                try checkpoint()
                let finalURL = try destinationURL(
                    in: root,
                    preferredName: preferredName,
                    conflictPolicy: .chooseUniqueName,
                    guardrail: guardrail
                )
                do {
                    try guardrail.promoteStagedItemIfAbsent(
                        at: stagedURL,
                        to: finalURL,
                        expectedStaged: expectedStaged,
                        commitCheckpoint: checkpoint,
                        validateStaged: validateBeforeCommit,
                        validateCommitted: validateCommitted
                    )
                    return SafeSkillInstallResult(installedURL: finalURL)
                } catch ManagedPathError.destinationAlreadyExists {
                    continue
                }
            }
        }
    }

    private func replace(
        stagedURL: URL,
        expectedStaged: ManagedItemIdentity,
        in root: URL,
        preferredName: String,
        guardrail: ManagedPathGuard,
        checkpoint: SkillCancellationCheckpoint,
        validateBeforeCommit: (Int32) throws -> Void,
        validateCommitted: (Int32) throws -> Void
    ) throws -> SafeSkillInstallResult {
        while true {
            try checkpoint()
            let finalURL = try destinationURL(
                in: root,
                preferredName: preferredName,
                conflictPolicy: .replaceExisting,
                guardrail: guardrail
            )
            guard let expectedTarget = try guardrail.itemIdentity(at: finalURL) else {
                do {
                    try guardrail.promoteStagedItemIfAbsent(
                        at: stagedURL,
                        to: finalURL,
                        expectedStaged: expectedStaged,
                        commitCheckpoint: checkpoint,
                        validateStaged: validateBeforeCommit,
                        validateCommitted: validateCommitted
                    )
                    return SafeSkillInstallResult(installedURL: finalURL)
                } catch ManagedPathError.destinationAlreadyExists {
                    continue
                }
            }
            do {
                let result = try guardrail.replaceStagedItem(
                    at: stagedURL,
                    to: finalURL,
                    expectedStaged: expectedStaged,
                    expectedTarget: expectedTarget,
                    commitCheckpoint: checkpoint,
                    validateStaged: validateBeforeCommit,
                    validateCommitted: validateCommitted
                )
                let cleanupDebts = try consume(
                    result,
                    finalURL: finalURL,
                    expectedStaged: expectedStaged,
                    expectedCleanupIdentity: expectedTarget,
                    guardrail: guardrail,
                    validateCommitted: validateCommitted
                )
                return SafeSkillInstallResult(
                    installedURL: finalURL,
                    cleanupDebts: cleanupDebts
                )
            } catch ManagedPathError.itemChanged {
                guard try guardrail.itemIdentity(at: stagedURL) == expectedStaged else {
                    throw ManagedPathError.itemChanged
                }
                continue
            }
        }
    }

    private func consume(
        _ result: ManagedPromotionResult,
        finalURL: URL,
        expectedStaged: ManagedItemIdentity,
        expectedCleanupIdentity: ManagedItemIdentity,
        guardrail: ManagedPathGuard,
        validateCommitted: (Int32) throws -> Void
    ) throws -> [SafeSkillCleanupDebt] {
        guard case .committedWithCleanupDebt(let cleanupURL, let originalError) = result else {
            return []
        }
        let retryError: Error?
        do {
            try guardrail.removeItem(
                at: cleanupURL,
                expectedIdentity: expectedCleanupIdentity
            )
            retryError = nil
        } catch {
            retryError = error
        }
        try guardrail.verifyCommittedPromotion(
            targetURL: finalURL,
            expectedTarget: expectedStaged,
            recoveryURL: cleanupURL,
            expectedRecovery: expectedCleanupIdentity,
            validateTarget: validateCommitted
        )
        guard let retryError else { return [] }
        NSLog(
            "Skills Manager installed the Skill but could not remove %@: %@; retry failed: %@",
            cleanupURL.path, originalError.localizedDescription, retryError.localizedDescription
        )
        return [SafeSkillCleanupDebt(
            url: cleanupURL,
            reason: "\(originalError.localizedDescription); retry failed: \(retryError.localizedDescription)"
        )]
    }

    private static func failure(
        _ operationError: Error,
        appending cleanupDebt: SafeSkillCleanupDebt
    ) -> SafeSkillStagingFailure {
        if let existing = operationError as? SafeSkillStagingFailure {
            return SafeSkillStagingFailure(
                originalReason: existing.originalReason,
                cleanupDebts: existing.cleanupDebts + [cleanupDebt]
            )
        }
        return SafeSkillStagingFailure(
            originalReason: operationError.localizedDescription,
            cleanupDebts: [cleanupDebt]
        )
    }

    private func throwAfterCleanup(
        _ operationError: Error,
        itemURL: URL,
        expectedIdentity: ManagedItemIdentity?,
        guardrail: ManagedPathGuard
    ) throws -> Never {
        if let expectedIdentity {
            do {
                try guardrail.removeItem(at: itemURL, expectedIdentity: expectedIdentity)
            } catch let cleanupError {
                throw Self.failure(
                    operationError,
                    appending: SafeSkillCleanupDebt(
                        url: itemURL,
                        reason: cleanupError.localizedDescription
                    )
                )
            }
        }
        throw operationError
    }

    private func finishArchiveInstall(
        _ result: SafeSkillInstallResult,
        extractionURL: URL,
        extractionIdentity: ManagedItemIdentity?,
        guardrail: ManagedPathGuard
    ) -> SafeSkillInstallResult {
        guard let extractionIdentity else { return result }
        do {
            try guardrail.removeItem(at: extractionURL, expectedIdentity: extractionIdentity)
            return result
        } catch {
            return SafeSkillInstallResult(
                installedURL: result.installedURL,
                cleanupDebts: result.cleanupDebts + [
                    SafeSkillCleanupDebt(url: extractionURL, reason: error.localizedDescription)
                ]
            )
        }
    }

    private func validateStaged(
        descriptor: Int32,
        displayPath: String,
        expectedFingerprint: String,
        checkpoint: SkillCancellationCheckpoint
    ) throws {
        let actual = try SkillContentSnapshot.capture(
            directoryDescriptor: descriptor,
            displayPath: displayPath,
            limits: limits,
            checkpoint: checkpoint
        ).fingerprint
        guard actual == expectedFingerprint else {
            throw SafeSkillStagingError.sourceChanged(
                expected: expectedFingerprint,
                actual: actual
            )
        }
        try checkpoint()
    }
}
