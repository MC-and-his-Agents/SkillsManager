import CryptoKit
import Darwin
import Foundation

@testable import SkillsManager

enum ReleaseV010ArtifactBuilder {
    static func payload(
        skillID: SkillID,
        sourceID: SourceID,
        slug: String,
        snapshot: SkillContentSnapshot
    ) throws -> SSOTSkillWritePayload {
        let alias = try ProviderAliasIdentity(provider: "clawdhub", identifier: slug)
        let version = try SourceVersion("0.1.0")
        return try SSOTSkillWritePayload(
            skill: ManagedSkillRecord(
                skillID: skillID,
                displayName: SkillDisplayName("Release Fixture"),
                defaultDistributionSlug: DefaultDistributionSlug(validating: slug),
                contentFingerprint: SkillContentFingerprint(
                    currentDigest: snapshot.fingerprintDigest
                ),
                createdAtMilliseconds: 10,
                updatedAtMilliseconds: 20
            ),
            source: SkillSourceRecord(
                sourceID: sourceID,
                skillID: skillID,
                repositoryURL: try NormalizedRepositoryURL(
                    "https://github.com/example/release-skill"
                ),
                subpath: try RepositorySubpath("skills/release"),
                revision: try SourceRevision(
                    "480316947d5df2c95c5f3775c1ed991f4e9549bc"
                ),
                version: version,
                downloadURL: try PublicDownloadURL(
                    "https://github.com/example/release-skill/archive/4803169.zip"
                )
            ),
            providerAliases: [
                ProviderAliasRecord(sourceID: sourceID, identity: alias),
            ],
            providerProvenance: [
                try ProviderProvenanceRecord(
                    skillID: skillID,
                    identity: alias,
                    identifierKey: slug,
                    version: version
                ),
            ]
        )
    }

    static func createBackup(
        workspace: WriterWorkspace,
        backupID: SkillBackupID,
        payload: SSOTSkillWritePayload,
        snapshot: SkillContentSnapshot,
        slug: String
    ) throws -> SkillBackupRecord {
        let selection = try SkillBackupDistributionSelection(
            isExplicitlyConfigured: true,
            bindingIntents: [
                DistributionBindingIntent(
                    skillID: payload.skill.skillID,
                    scope: .global,
                    distributionSlug: try DefaultDistributionSlug(validating: slug)
                ),
            ]
        )
        let manifest = try SkillBackupManifestV1(
            backupID: backupID,
            payload: payload,
            databaseRevision: 3,
            distributionSelection: selection,
            statistics: snapshot.statistics,
            createdAtMilliseconds: 50
        )
        let manifestBytes = try manifest.encoded()
        let locator = "\(payload.skill.skillID.directoryName)/50-"
            + backupID.uuid.uuidString.lowercased()
        let backupRoot = workspace.managementRoot.appendingPathComponent(
            "skill-backups",
            isDirectory: true
        )
        let skillBackupRoot = backupRoot.appendingPathComponent(
            payload.skill.skillID.directoryName,
            isDirectory: true
        )
        let backupURL = backupRoot.appendingPathComponent(locator, isDirectory: true)
        try FileManager.default.createDirectory(
            at: backupURL,
            withIntermediateDirectories: true
        )
        for url in [backupRoot, skillBackupRoot, backupURL] {
            guard Darwin.chmod(url.path, 0o700) == 0 else {
                throw CocoaError(.fileWriteUnknown)
            }
        }
        try FileManager.default.copyItem(
            at: workspace.root.appendingPathComponent(
                payload.skill.skillID.directoryName,
                isDirectory: true
            ),
            to: backupURL.appendingPathComponent(
                SkillBackupFileSystem.filesName,
                isDirectory: true
            )
        )
        try manifestBytes.write(
            to: backupURL.appendingPathComponent(SkillBackupFileSystem.manifestName),
            options: .atomic
        )
        var metadata = stat()
        guard Darwin.lstat(backupURL.path, &metadata) == 0 else {
            throw CocoaError(.fileReadUnknown)
        }
        return try SkillBackupRecord(
            backupID: backupID,
            originalSkillID: payload.skill.skillID,
            state: .available,
            locator: locator,
            directoryIdentity: ManagedItemIdentity(metadata),
            manifestDigest: Data(SHA256.hash(data: manifestBytes)),
            contentFingerprint: payload.skill.contentFingerprint,
            isPinned: true,
            createdAtMilliseconds: 50,
            updatedAtMilliseconds: 50
        )
    }

    static func insertCompletedOperation(
        connection: SQLiteConnection,
        operationID: SSOTOperationID,
        skillID: SkillID,
        skillRoot: URL
    ) throws {
        struct Plan: Encodable {
            let status = "executable"
            let filesystemActions: [String] = []
            let bindingsChanged = false
            let bindingReplacement: [String] = []
            let configurationChanged = true
            let expectedOldConfigured = false
            let desiredConfigured = true
            let conflicts: [String] = []

            enum CodingKeys: String, CodingKey {
                case status
                case filesystemActions = "filesystem_actions"
                case bindingsChanged = "bindings_changed"
                case bindingReplacement = "binding_replacement"
                case configurationChanged = "configuration_changed"
                case expectedOldConfigured = "expected_old_configured"
                case desiredConfigured = "desired_configured"
                case conflicts
            }
        }
        struct Preflight: Encodable {
            let actions: [String] = []
            let ssotIdentity: Data
            let absoluteLinkTarget: String
            let expectedOldConfigured = false
            let desiredConfigured = true
        }
        let runtime = Data(#"{"created":[],"removed":[]}"#.utf8)
        let draft = try DistributionOperationDraft(
            operationID: operationID,
            skillID: skillID,
            oldBindings: Data("[]".utf8),
            newBindings: Data("[]".utf8),
            planPayload: try DistributionOperationPayloadCodec.encode(Plan()),
            preflightPayload: try DistributionOperationPayloadCodec.encode(
                Preflight(
                    ssotIdentity: try identityBytes(at: skillRoot),
                    absoluteLinkTarget: skillRoot.path
                )
            ),
            runtimePayload: runtime,
            createdAtMilliseconds: 30
        )
        let store = try DistributionOperationStore(connection: connection)
        _ = try store.insertPrepared(draft)
        for (phase, timestamp) in [
            (DistributionOperationPhase.applying, Int64(31)),
            (.filesystemApplied, 32),
            (.databaseCommitted, 33),
            (.cleaning, 34),
        ] {
            try store.updateProgress(
                operationID: operationID,
                phase: phase,
                forwardCursor: 0,
                rollbackCursor: 0,
                cleanupCursor: 0,
                runtimePayload: runtime,
                attemptCount: 1,
                lastError: nil,
                updatedAtMilliseconds: timestamp
            )
        }
        try store.complete(
            operationID: operationID,
            outcome: .applied,
            updatedAtMilliseconds: 40
        )
    }

    private static func identityBytes(at url: URL) throws -> Data {
        var metadata = stat()
        guard Darwin.lstat(url.path, &metadata) == 0 else {
            throw CocoaError(.fileReadUnknown)
        }
        return try ManagedItemIdentityCodec.encode(ManagedItemIdentity(metadata))
    }
}
