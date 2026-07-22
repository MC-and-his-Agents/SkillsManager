import Darwin
import Foundation

nonisolated enum SkillInstallConflictPolicy: Sendable {
    case chooseUniqueName
    case replaceExisting
}

nonisolated enum SafeSkillStagingError: LocalizedError, Equatable {
    case invalidDestinationName(String)
    case destinationRootMismatch
    case destinationPathCollision(String, String)
    case sourceChanged(expected: String, actual: String)

    var errorDescription: String? {
        switch self {
        case .invalidDestinationName(let name):
            return "The Skill destination name is unsafe: \(name)"
        case .destinationRootMismatch:
            return "The Skill destination does not match its registered managed root."
        case .destinationPathCollision(let first, let second):
            return "The destination contains conflicting Skill names: \(first) and \(second)"
        case .sourceChanged:
            return "The Skill contents changed while they were being imported. Try again."
        }
    }
}

nonisolated struct SafeSkillCleanupDebt: Equatable, Sendable {
    let url: URL
    let reason: String
}

nonisolated struct SafeSkillInstallResult: Equatable, Sendable {
    let installedURL: URL
    let cleanupDebts: [SafeSkillCleanupDebt]

    init(installedURL: URL, cleanupDebts: [SafeSkillCleanupDebt] = []) {
        self.installedURL = installedURL
        self.cleanupDebts = cleanupDebts
    }
}

/// Copies one validated Skill into a same-filesystem staging directory before promotion.
nonisolated struct SafeSkillStager {
    typealias MetadataWriter = (URL) throws -> Void
    typealias GuardFactory = (URL) throws -> ManagedPathGuard

    private let fileManager: FileManager
    private let limits: SkillContentLimits
    private let guardFactory: GuardFactory

    init(
        fileManager: FileManager = .default,
        limits: SkillContentLimits = .default,
        guardFactory: @escaping GuardFactory = { try ManagedPathGuard(rootURL: $0) }
    ) {
        self.fileManager = fileManager
        self.limits = limits
        self.guardFactory = guardFactory
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
        guard sourceSnapshot.fingerprint == expectedFingerprint else {
            throw SafeSkillStagingError.sourceChanged(
                expected: expectedFingerprint,
                actual: sourceSnapshot.fingerprint
            )
        }
        try checkpoint()
        let destination = try verifiedManagedRoot(destinationRoot, reference: managedRoot)
        let guardrail = try guardFactory(destination.url)
        let normalizedName = try validatedName(preferredName)
        let stagedURL = destination.url.appendingPathComponent(
            ".skillsmanager-tmp-\(UUID().uuidString.lowercased())",
            isDirectory: true
        )
        var stagedIdentity: ManagedItemIdentity?

        do {
            try fileManager.createDirectory(at: stagedURL, withIntermediateDirectories: false)
            stagedIdentity = try guardrail.itemIdentity(at: stagedURL)
            try sourceSnapshot.copyFiles(
                to: stagedURL,
                limits: limits,
                checkpoint: checkpoint
            )
            try metadataWriter(stagedURL)
            let stagedSnapshot = try SkillContentSnapshot.capture(
                at: stagedURL,
                limits: limits,
                checkpoint: checkpoint
            )
            guard stagedSnapshot.fingerprint == expectedFingerprint else {
                throw SafeSkillStagingError.sourceChanged(
                    expected: expectedFingerprint,
                    actual: stagedSnapshot.fingerprint
                )
            }
            try checkpoint()
            return try promote(
                stagedURL: stagedURL,
                in: destination.url,
                preferredName: normalizedName,
                conflictPolicy: conflictPolicy,
                guardrail: guardrail,
                checkpoint: checkpoint
            )
        } catch {
            if let stagedIdentity {
                try? guardrail.removeItem(at: stagedURL, expectedIdentity: stagedIdentity)
            }
            throw error
        }
    }

    /// Extracts an archive inside the managed destination before using the same
    /// fingerprint verification and atomic promotion path as folder imports.
    func installArchive(
        archiveAt archiveURL: URL,
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
        let extractionURL = destination.url.appendingPathComponent(
            ".skillsmanager-tmp-archive-\(UUID().uuidString.lowercased())",
            isDirectory: true
        )
        var extractionIdentity: ManagedItemIdentity?

        do {
            try fileManager.createDirectory(at: extractionURL, withIntermediateDirectories: false)
            extractionIdentity = try guardrail.itemIdentity(at: extractionURL)
            try checkpoint()
            let archiveLimits = SafeSkillArchive.Limits(
                maximumFileCount: limits.maximumFileCount,
                maximumTotalSize: limits.maximumTotalByteCount,
                maximumFileSize: limits.maximumFileByteCount
            )
            try SafeSkillArchive(limits: archiveLimits).extract(
                archiveAt: archiveURL,
                to: extractionURL,
                checkpoint: checkpoint
            )
            try checkpoint()
            let sourceRoot = try SkillPackageLocator().locateSkillRoot(in: extractionURL)
            let extractedFingerprint = try SkillContentSnapshot.capture(
                at: sourceRoot,
                limits: limits,
                checkpoint: checkpoint
            ).fingerprint
            guard extractedFingerprint == expectedFingerprint else {
                throw SafeSkillStagingError.sourceChanged(
                    expected: expectedFingerprint,
                    actual: extractedFingerprint
                )
            }

            var result = try install(
                sourceRoot: sourceRoot,
                expectedFingerprint: expectedFingerprint,
                destinationRoot: destination.url,
                preferredName: preferredName,
                conflictPolicy: conflictPolicy,
                managedRoot: destination.reference,
                checkpoint: checkpoint,
                metadataWriter: metadataWriter
            )
            if let extractionIdentity {
                do {
                    try guardrail.removeItem(at: extractionURL, expectedIdentity: extractionIdentity)
                } catch {
                    result = SafeSkillInstallResult(
                        installedURL: result.installedURL,
                        cleanupDebts: result.cleanupDebts + [
                            SafeSkillCleanupDebt(
                                url: extractionURL,
                                reason: error.localizedDescription
                            )
                        ]
                    )
                }
            }
            return result
        } catch {
            if let extractionIdentity {
                try? guardrail.removeItem(at: extractionURL, expectedIdentity: extractionIdentity)
            }
            throw error
        }
    }

    private func verifiedManagedRoot(
        _ requestedURL: URL,
        reference: ManagedRootReference?
    ) throws -> (url: URL, reference: ManagedRootReference) {
        let requested = requestedURL.standardizedFileURL
        if let reference {
            guard requested == reference.registeredURL || requested == reference.canonicalURL else {
                throw SafeSkillStagingError.destinationRootMismatch
            }
            return (try reference.verifiedRootURL(), reference)
        }
        try fileManager.createDirectory(at: requested, withIntermediateDirectories: true)
        let captured = try ManagedRootReference.capture(at: requested)
        return (try captured.verifiedRootURL(), captured)
    }

    private func promote(
        stagedURL: URL,
        in root: URL,
        preferredName: String,
        conflictPolicy: SkillInstallConflictPolicy,
        guardrail: ManagedPathGuard,
        checkpoint: SkillCancellationCheckpoint
    ) throws -> SafeSkillInstallResult {
        switch conflictPolicy {
        case .replaceExisting:
            return try replace(
                stagedURL: stagedURL,
                in: root,
                preferredName: preferredName,
                guardrail: guardrail,
                checkpoint: checkpoint
            )
        case .chooseUniqueName:
            while true {
                try checkpoint()
                let finalURL = try destinationURL(
                    in: root,
                    preferredName: preferredName,
                    conflictPolicy: .chooseUniqueName
                )
                do {
                    try guardrail.promoteStagedItemIfAbsent(at: stagedURL, to: finalURL)
                    return SafeSkillInstallResult(installedURL: finalURL)
                } catch ManagedPathError.destinationAlreadyExists {
                    continue
                }
            }
        }
    }

    private func replace(
        stagedURL: URL,
        in root: URL,
        preferredName: String,
        guardrail: ManagedPathGuard,
        checkpoint: SkillCancellationCheckpoint
    ) throws -> SafeSkillInstallResult {
        while true {
            try checkpoint()
            let finalURL = try destinationURL(
                in: root,
                preferredName: preferredName,
                conflictPolicy: .replaceExisting
            )
            guard let expectedTarget = try guardrail.itemIdentity(at: finalURL) else {
                do {
                    try guardrail.promoteStagedItemIfAbsent(at: stagedURL, to: finalURL)
                    return SafeSkillInstallResult(installedURL: finalURL)
                } catch ManagedPathError.destinationAlreadyExists {
                    continue
                }
            }
            do {
                let result = try guardrail.replaceStagedItem(
                    at: stagedURL,
                    to: finalURL,
                    expectedTarget: expectedTarget
                )
                let cleanupDebts = consume(
                    result,
                    expectedCleanupIdentity: expectedTarget,
                    guardrail: guardrail
                )
                return SafeSkillInstallResult(
                    installedURL: finalURL,
                    cleanupDebts: cleanupDebts
                )
            } catch ManagedPathError.itemChanged {
                continue
            }
        }
    }

    private func consume(
        _ result: ManagedPromotionResult,
        expectedCleanupIdentity: ManagedItemIdentity,
        guardrail: ManagedPathGuard
    ) -> [SafeSkillCleanupDebt] {
        guard case .committedWithCleanupDebt(let cleanupURL, let originalError) = result else {
            return []
        }
        do {
            try guardrail.removeItem(
                at: cleanupURL,
                expectedIdentity: expectedCleanupIdentity
            )
            return []
        } catch {
            NSLog(
                "Skills Manager installed the Skill but could not remove %@: %@; retry failed: %@",
                cleanupURL.path,
                originalError.localizedDescription,
                error.localizedDescription
            )
            return [
                SafeSkillCleanupDebt(
                    url: cleanupURL,
                    reason: "\(originalError.localizedDescription); retry failed: \(error.localizedDescription)"
                )
            ]
        }
    }

    private func destinationURL(
        in root: URL,
        preferredName: String,
        conflictPolicy: SkillInstallConflictPolicy
    ) throws -> URL {
        let children = try fileManager.contentsOfDirectory(
            at: root,
            includingPropertiesForKeys: nil,
            options: []
        ).filter { !$0.lastPathComponent.hasPrefix(".skillsmanager-tmp-") }

        let matches = children.filter {
            SkillContentPath.collisionKey(for: $0.lastPathComponent)
                == SkillContentPath.collisionKey(for: preferredName)
        }
        guard matches.count <= 1 else {
            throw SafeSkillStagingError.destinationPathCollision(
                matches[0].lastPathComponent,
                matches[1].lastPathComponent
            )
        }

        switch (conflictPolicy, matches.first) {
        case (.replaceExisting, let existing?):
            return existing
        case (.replaceExisting, nil), (.chooseUniqueName, nil):
            return root.appendingPathComponent(preferredName, isDirectory: true)
        case (.chooseUniqueName, .some):
            var suffix = 1
            while true {
                let candidateName = "\(preferredName)-\(suffix)"
                let candidateKey = SkillContentPath.collisionKey(for: candidateName)
                if children.contains(where: {
                    SkillContentPath.collisionKey(for: $0.lastPathComponent) == candidateKey
                }) == false {
                    return root.appendingPathComponent(candidateName, isDirectory: true)
                }
                suffix += 1
            }
        }
    }

    private func validatedName(_ name: String) throws -> String {
        let normalized = name.precomposedStringWithCanonicalMapping
        guard !normalized.isEmpty,
              normalized != ".",
              normalized != "..",
              !normalized.hasPrefix("."),
              !normalized.contains("/"),
              !normalized.contains("\\"),
              !normalized.contains("\0") else {
            throw SafeSkillStagingError.invalidDestinationName(name)
        }
        return normalized
    }
}
