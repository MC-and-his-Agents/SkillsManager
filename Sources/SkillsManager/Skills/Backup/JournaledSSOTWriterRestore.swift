import CryptoKit
import Foundation

private nonisolated struct StoredRestoreResult: Codable {
    let schemaVersion: Int
    let restoredSkillID: String
    let status: String
    let warnings: [String]

    enum CodingKeys: String, CodingKey {
        case schemaVersion = "schema_version"
        case restoredSkillID = "restored_skill_id"
        case status
        case warnings
    }
}

extension JournaledSSOTWriter {
    func restorePreview(_ backupID: SkillBackupID) throws -> SkillRestorePreview {
        try withStableSkillLifecycleErrors(.backupRead) {
            try requireAuthority()
            let (backup, manifest, _) = try validatedManifest(backupID)
            let targetID = try resolvedRestoreID(
                backup: backup, manifest: manifest, persist: false
            )
            let existing = try journal.storedDomain(targetID)
            let status: SkillRestoreStatus =
                existing?.payload.skill.contentFingerprint == backup.contentFingerprint
                ? .noOp : .ready
            let targets = try manifest.distributionSelection.bindingIntents.map { intent in
                guard let entry = DistributionTargetCatalog.current.entry(
                    for: intent.scope,
                    slug: intent.distributionSlug
                ) else {
                    throw SkillDeletionError.backupCorrupt
                }
                return SkillDistributionTargetSummary(
                    scopeKey: intent.scope.targetScopeKey,
                    canonicalLocator: entry.canonicalLocator
                )
            }
            let targetPayload = try existing.map {
                try SSOTWritePayloadCodec.encode($0.payload)
            }
            return SkillRestorePreview(
                backupID: backupID,
                originalSkillID: manifest.originalSkillID,
                targetSkillID: targetID,
                status: status,
                summary: SkillBackupSummary(
                    content: SkillContentSummary(
                        displayName: manifest.payload.skill.displayName.value,
                        contentFingerprint: manifest.contentFingerprint,
                        statistics: manifest.statistics
                    ),
                    sourceLocator: manifest.payload.source.map {
                        $0.subpath.value.isEmpty || $0.subpath.value == "."
                            ? $0.repositoryURL.value
                            : "\($0.repositoryURL.value)#\($0.subpath.value)"
                    },
                    targets: targets
                ),
                token: SkillRestorePreviewToken(
                    backupUpdatedAtMilliseconds: backup.updatedAtMilliseconds,
                    directoryIdentity: backup.directoryIdentity,
                    manifestDigest: backup.manifestDigest,
                    contentFingerprint: backup.contentFingerprint,
                    targetSkillID: targetID,
                    targetRevision: existing?.revision,
                    targetPayload: targetPayload
                )
            )
        }
    }

    func restoreBackup(
        preview: SkillRestorePreview,
        restoreDistribution: Bool = false
    ) throws -> SkillRestoreResult {
        try withStableSkillLifecycleErrors(.backupRead) {
            guard try restorePreview(preview.backupID).token == preview.token else {
                throw SkillDeletionError.previewExpired
            }
            return try performRestoreBackup(
                preview.backupID,
                restoreDistribution: restoreDistribution
            )
        }
    }

    private func performRestoreBackup(
        _ backupID: SkillBackupID,
        restoreDistribution: Bool
    ) throws -> SkillRestoreResult {
        try requireAuthority()
        let (initialBackup, manifest, validated) = try validatedManifest(backupID)
        let stored = try storedRestoreResult(
            initialBackup,
            expectedFingerprint: manifest.contentFingerprint
        )
        if let stored, !restoreDistribution { return stored }
        let targetID = try stored?.restoredSkillID ?? resolvedRestoreID(
            backup: initialBackup, manifest: manifest, persist: true
        )
        var warnings = stored?.warnings.filter { $0 != "distribution_conflict" } ?? []
        var status: SkillRestoreStatus =
            stored?.status == .restoredUndistributed ? .completed : stored?.status ?? .completed
        if stored == nil {
            let restored = try restorationPayload(
                manifest.payload,
                targetSkillID: targetID
            )
            warnings.append(contentsOf: restored.warnings)
            if let existing = try journal.storedDomain(targetID) {
                guard existing.payload.skill.contentFingerprint == backupFingerprint(manifest) else {
                    throw SkillDeletionError.conflict
                }
                status = initialBackup.restoredSkillID == nil ? .noOp : .completed
            } else {
                _ = try create(
                    payload: restored.payload,
                    sourceSnapshot: validated.snapshot
                )
            }
        }
        if restoreDistribution {
            do {
                try restoreManifestDistribution(
                    manifest.distributionSelection.rebased(to: targetID),
                    skillID: targetID
                )
            } catch SkillDeletionError.conflict {
                warnings.append("distribution_conflict")
                status = .restoredUndistributed
            }
        }
        warnings = Array(Set(warnings)).sorted()
        let result = SkillRestoreResult(
            backupID: backupID,
            restoredSkillID: targetID,
            status: status,
            warnings: warnings
        )
        if stored.map({ !sameRestoreResult($0, result) }) ?? true {
            try persistRestoreResult(result)
        }
        return result
    }

    private func validatedManifest(
        _ backupID: SkillBackupID
    ) throws -> (
        SkillBackupRecord,
        SkillBackupManifestV1,
        ValidatedSkillBackup
    ) {
        let store = try SkillBackupStore(connection: connection)
        guard let backup = try store.load(backupID), backup.state == .available else {
            throw SkillDeletionError.backupCorrupt
        }
        let validated = try backupFileSystem.validate(
            locator: backup.locator,
            expectedIdentity: backup.directoryIdentity,
            expectedManifestDigest: backup.manifestDigest,
            expectedFingerprint: backup.contentFingerprint
        )
        let manifest = try SkillBackupManifestV1.decode(validated.manifestBytes)
        guard manifest.backupID == backupID,
              manifest.originalSkillID == backup.originalSkillID,
              manifest.contentFingerprint == backup.contentFingerprint else {
            throw SkillDeletionError.backupCorrupt
        }
        return (backup, manifest, validated)
    }

    private func resolvedRestoreID(
        backup: SkillBackupRecord,
        manifest: SkillBackupManifestV1,
        persist: Bool
    ) throws -> SkillID {
        if let restoredSkillID = backup.restoredSkillID { return restoredSkillID }
        let original = try journal.storedDomain(manifest.originalSkillID)
        let target: SkillID
        if original == nil
            || original?.payload.skill.contentFingerprint == manifest.contentFingerprint {
            target = manifest.originalSkillID
        } else {
            target = try deterministicRestoreSkillID(backup.backupID)
        }
        guard persist else { return target }
        let store = try SkillBackupStore(connection: connection)
        let replacement = try backupReplacement(
            backup,
            restoredSkillID: target,
            updatedAtMilliseconds: deletionTimestamp(after: backup.updatedAtMilliseconds)
        )
        try requireAuthority()
        try store.replace(expected: backup, with: replacement)
        return target
    }

    private func restorationPayload(
        _ original: SSOTSkillWritePayload,
        targetSkillID: SkillID
    ) throws -> (payload: SSOTSkillWritePayload, warnings: [String]) {
        let skill = try ManagedSkillRecord(
            skillID: targetSkillID,
            displayName: original.skill.displayName,
            defaultDistributionSlug: original.skill.defaultDistributionSlug,
            contentFingerprint: original.skill.contentFingerprint,
            status: .managed,
            createdAtMilliseconds: original.skill.createdAtMilliseconds,
            updatedAtMilliseconds: deletionTimestamp(
                after: original.skill.updatedAtMilliseconds
            )
        )
        var warnings: [String] = []
        let source = try restoredSource(
            original.source,
            targetSkillID: targetSkillID,
            warnings: &warnings
        )
        let aliases = try restoredAliases(
            original.providerAliases,
            source: source,
            warnings: &warnings
        )
        let provenance = try restoredProviderProvenance(
            original.providerProvenance,
            targetSkillID: targetSkillID,
            warnings: &warnings
        )
        let origins = try restoredOrigins(
            original.localOrigins,
            skill: skill,
            warnings: &warnings
        )
        return (
            try SSOTSkillWritePayload(
                skill: skill,
                source: source,
                providerAliases: aliases,
                providerProvenance: provenance,
                localOrigins: origins,
                restoredFromSkillID: targetSkillID == original.skill.skillID
                    ? original.restoredFromSkillID : original.skill.skillID
            ),
            warnings.sorted()
        )
    }

    private func restoredSource(
        _ original: SkillSourceRecord?,
        targetSkillID: SkillID,
        warnings: inout [String]
    ) throws -> SkillSourceRecord? {
        guard let original else { return nil }
        let statement = try connection.prepare(
            """
            SELECT skill_id FROM sources
            WHERE source_id = ?
               OR (normalized_repository_url = ? AND normalized_subpath = ?)
            """
        )
        try statement.bind(original.sourceID.bytes, at: 1)
        try statement.bind(original.repositoryURL.value, at: 2)
        try statement.bind(original.subpath.value, at: 3)
        while try statement.step() {
            guard try SkillID(bytes: restoreRequiredBlob(statement, 0)) == targetSkillID else {
                warnings.append("source_conflict")
                return nil
            }
        }
        return SkillSourceRecord(
            sourceID: original.sourceID,
            skillID: targetSkillID,
            repositoryURL: original.repositoryURL,
            subpath: original.subpath,
            revision: original.revision,
            version: original.version,
            downloadURL: original.downloadURL
        )
    }

    private func restoredAliases(
        _ aliases: [ProviderAliasRecord],
        source: SkillSourceRecord?,
        warnings: inout [String]
    ) throws -> [ProviderAliasRecord] {
        guard let source else {
            if !aliases.isEmpty, !warnings.contains("source_conflict") {
                warnings.append("source_unavailable")
            }
            return []
        }
        var result: [ProviderAliasRecord] = []
        for alias in aliases {
            let statement = try connection.prepare(
                """
                SELECT source_id FROM provider_aliases
                WHERE provider = ? AND provider_identifier = ?
                """
            )
            try statement.bind(alias.identity.provider, at: 1)
            try statement.bind(alias.identity.identifier, at: 2)
            if try statement.step(),
               try SourceID(bytes: restoreRequiredBlob(statement, 0)) != source.sourceID {
                warnings.append(
                    "alias_conflict:\(alias.identity.provider):\(alias.identity.identifier)"
                )
                continue
            }
            result.append(ProviderAliasRecord(sourceID: source.sourceID, identity: alias.identity))
        }
        return result
    }

    private func restoredOrigins(
        _ origins: [LocalSkillOriginRecord],
        skill: ManagedSkillRecord,
        warnings: inout [String]
    ) throws -> [LocalSkillOriginRecord] {
        let occupied = try journal.localOrigins()
        var result: [LocalSkillOriginRecord] = []
        for origin in origins {
            let restored = try LocalSkillOriginRecord(
                skillID: skill.skillID,
                scope: origin.scope,
                rawLocator: origin.rawLocator,
                normalizedLocator: origin.normalizedLocator,
                collisionKey: origin.collisionKey,
                fingerprint: skill.contentFingerprint,
                confirmedAtMilliseconds: origin.confirmedAtMilliseconds
            )
            if let existing = occupied.first(where: { $0.position == restored.position }) {
                if existing.skillID == restored.skillID,
                   existing.rawLocator == restored.rawLocator,
                   existing.normalizedLocator == restored.normalizedLocator,
                   existing.fingerprint == restored.fingerprint {
                    continue
                }
                warnings.append("origin_conflict:\(origin.scope.sortKey):\(origin.collisionKey)")
                continue
            }
            result.append(restored)
        }
        return result
    }

    private func restoredProviderProvenance(
        _ records: [ProviderProvenanceRecord],
        targetSkillID: SkillID,
        warnings: inout [String]
    ) throws -> [ProviderProvenanceRecord] {
        var result: [ProviderProvenanceRecord] = []
        for record in records {
            if let existing = try journal.providerProvenance(record.identity),
               existing.skillID != targetSkillID {
                warnings.append(
                    "provider_provenance_conflict:"
                        + "\(record.identity.provider):\(record.identifierKey)"
                )
                continue
            }
            result.append(try ProviderProvenanceRecord(
                skillID: targetSkillID,
                identity: record.identity,
                identifierKey: record.identifierKey,
                version: record.version
            ))
        }
        return result
    }

    private func restoreManifestDistribution(
        _ selection: SkillBackupDistributionSelection,
        skillID: SkillID
    ) throws {
        let desired = try distributionDesiredConfiguration(
            selection.bindingIntents,
            skillID: skillID
        )
        let plan = try distributionPlan(
            skillID: skillID,
            desiredConfiguration: desired,
            desiredConfigured: selection.isExplicitlyConfigured,
            requiredAdapterCodes: desired.scope.requiredAdapterCodes
        )
        guard plan.status != .blocked else { throw SkillDeletionError.conflict }
        try requireAuthority()
        if plan.status == .executable {
            let operation = try applyDistribution(
                skillID: skillID,
                plan: plan
            )
            guard operation.phase == .completed, operation.outcome == .applied else {
                throw SkillDeletionError.needsRepair
            }
        }
    }

    private func persistRestoreResult(_ result: SkillRestoreResult) throws {
        try requireAuthority()
        let store = try SkillBackupStore(connection: connection)
        guard let backup = try store.load(result.backupID),
              backup.restoredSkillID == result.restoredSkillID else {
            throw SkillDeletionError.conflict
        }
        let payload = StoredRestoreResult(
            schemaVersion: 1,
            restoredSkillID: result.restoredSkillID.uuid.uuidString.lowercased(),
            status: result.status.rawValue,
            warnings: result.warnings
        )
        let replacement = try backupReplacement(
            backup,
            restoreResultJSON: SkillBackupCanonicalJSON.encode(payload),
            updatedAtMilliseconds: deletionTimestamp(after: backup.updatedAtMilliseconds)
        )
        try requireAuthority()
        try store.replace(expected: backup, with: replacement)
    }

    private func sameRestoreResult(
        _ lhs: SkillRestoreResult,
        _ rhs: SkillRestoreResult
    ) -> Bool {
        lhs.backupID == rhs.backupID
            && lhs.restoredSkillID == rhs.restoredSkillID
            && lhs.status == rhs.status
            && lhs.warnings == rhs.warnings
    }

    private func storedRestoreResult(
        _ backup: SkillBackupRecord,
        expectedFingerprint: SkillContentFingerprint
    ) throws -> SkillRestoreResult? {
        guard let bytes = backup.restoreResultJSON,
              let restoredSkillID = backup.restoredSkillID else { return nil }
        try SkillBackupCanonicalJSON.validate(bytes)
        let stored = try JSONDecoder().decode(StoredRestoreResult.self, from: bytes)
        guard stored.schemaVersion == 1,
              stored.restoredSkillID == restoredSkillID.directoryName,
              let status = SkillRestoreStatus(rawValue: stored.status),
              stored.warnings == stored.warnings.sorted(),
              try journal.storedDomain(restoredSkillID)?.payload.skill.contentFingerprint
                == expectedFingerprint else {
            throw SkillDeletionError.conflict
        }
        return SkillRestoreResult(
            backupID: backup.backupID,
            restoredSkillID: restoredSkillID,
            status: status,
            warnings: stored.warnings
        )
    }

    private func deterministicRestoreSkillID(
        _ backupID: SkillBackupID
    ) throws -> SkillID {
        var bytes = Data("SkillsManager.RestoreSkillID.v1".utf8)
        bytes.append(backupID.bytes)
        return try SkillID(bytes: Data(SHA256.hash(data: bytes).prefix(16)))
    }

    private func backupFingerprint(
        _ manifest: SkillBackupManifestV1
    ) -> SkillContentFingerprint {
        manifest.contentFingerprint
    }
}

private nonisolated func restoreRequiredBlob(
    _ statement: SQLiteStatement,
    _ column: Int32
) throws -> Data {
    guard let value = statement.blob(at: column) else {
        throw SkillDeletionError.conflict
    }
    return value
}
