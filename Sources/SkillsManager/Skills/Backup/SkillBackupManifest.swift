import Foundation

nonisolated enum SkillBackupManifestError: Error, Equatable {
    case invalidManifest
    case unsupportedSchemaVersion(Int)
    case notCanonical
}

nonisolated struct SkillBackupDistributionSelection: Sendable {
    let isExplicitlyConfigured: Bool
    let bindingIntents: [DistributionBindingIntent]

    init(
        isExplicitlyConfigured: Bool,
        bindingIntents: [DistributionBindingIntent]
    ) throws {
        let ordered = bindingIntents.sorted(by: distributionBindingIntentPrecedes)
        guard Set(ordered.map(\.scope.targetScopeKey)).count == ordered.count,
              Set(ordered).count == ordered.count else {
            throw SkillBackupManifestError.invalidManifest
        }
        self.isExplicitlyConfigured = isExplicitlyConfigured
        self.bindingIntents = ordered
    }

    init(_ readback: DistributionSelectionReadback) throws {
        try self.init(
            isExplicitlyConfigured: readback.isExplicitlyConfigured,
            bindingIntents: readback.bindings.map(\.intent)
        )
    }

    func rebased(to skillID: SkillID) throws -> Self {
        try Self(
            isExplicitlyConfigured: isExplicitlyConfigured,
            bindingIntents: bindingIntents.map {
                DistributionBindingIntent(
                    skillID: skillID,
                    scope: $0.scope,
                    distributionSlug: $0.distributionSlug,
                    syncMode: $0.syncMode
                )
            }
        )
    }
}

nonisolated struct SkillBackupManifestV1: Sendable {
    static let schemaVersion = 1

    let backupID: SkillBackupID
    let originalSkillID: SkillID
    let payload: SSOTSkillWritePayload
    let databaseRevision: Int64
    let distributionSelection: SkillBackupDistributionSelection
    let contentFingerprint: SkillContentFingerprint
    let statistics: SkillContentSnapshot.Statistics
    let createdAtMilliseconds: Int64

    init(
        backupID: SkillBackupID,
        payload: SSOTSkillWritePayload,
        databaseRevision: Int64,
        distributionSelection: SkillBackupDistributionSelection,
        statistics: SkillContentSnapshot.Statistics,
        createdAtMilliseconds: Int64
    ) throws {
        guard databaseRevision >= 0,
              createdAtMilliseconds >= 0,
              statistics.fileCount >= 0,
              distributionSelection.bindingIntents.allSatisfy({
                  $0.skillID == payload.skill.skillID
              }) else {
            throw SkillBackupManifestError.invalidManifest
        }
        self.backupID = backupID
        originalSkillID = payload.skill.skillID
        self.payload = payload
        self.databaseRevision = databaseRevision
        self.distributionSelection = distributionSelection
        contentFingerprint = payload.skill.contentFingerprint
        self.statistics = statistics
        self.createdAtMilliseconds = createdAtMilliseconds
    }

    func encoded() throws -> Data {
        try SkillBackupCanonicalJSON.encode(Wire(self))
    }

    static func decode(_ data: Data) throws -> Self {
        do {
            try SkillBackupCanonicalJSON.validate(data)
            let wire = try JSONDecoder().decode(Wire.self, from: data)
            guard wire.schemaVersion == schemaVersion else {
                throw SkillBackupManifestError.unsupportedSchemaVersion(wire.schemaVersion)
            }
            let manifest = try wire.manifest()
            guard try manifest.encoded() == data else {
                throw SkillBackupManifestError.notCanonical
            }
            return manifest
        } catch let error as SkillBackupManifestError {
            throw error
        } catch {
            throw SkillBackupManifestError.invalidManifest
        }
    }
}
