import Darwin
import Foundation
import Testing

@testable import SkillsManager

@Suite("Historical Skill migration", .serialized)
struct HistoricalSkillMigrationTests {
    @Test(
        "maps typed backup permission failures without hiding them as unavailable",
        arguments: [Int32(EACCES), Int32(EPERM)]
    )
    func mapsBackupPermissionFailure(_ code: Int32) {
        #expect(
            HistoricalSkillMigrationService.stable(
                SkillBackupFileSystemError.posix(operation: "backup", code: code)
            ) == .permissionDenied
        )
        #expect(
            HistoricalSkillMigrationService.stable(
                SkillBackupFileSystemError.manifestChanged
            ) == .backupUnavailable
        )
    }

    @Test("imports, backs up, and replaces one historical directory with a managed symlink")
    func importsAndMigrates() async throws {
        let fixture = try await HistoricalMigrationFixture(content: "# Historical")
        let prepared = try await fixture.prepare()
        let service = fixture.service()
        let preview = try await service.prepare(
            audit: prepared.audit,
            observation: prepared.observation,
            importAction: .importNew
        )

        async let first = service.confirm(preview.token)
        async let second = service.confirm(preview.token)
        let (result, repeated) = try await (first, second)

        #expect(result.skill.skillID == preview.skillID)
        #expect(repeated.backup.backupID == result.backup.backupID)
        #expect(repeated.distribution.operationID == result.distribution.operationID)
        #expect(result.backup.state == .available)
        #expect(result.distribution.phase == .completed)
        #expect(result.distribution.outcome == .applied)
        #expect(try fixture.workspace.integer("SELECT count(*) FROM skills") == 1)
        #expect(try fixture.workspace.integer("SELECT count(*) FROM local_skill_origins") == 1)
        #expect(try fixture.workspace.integer("SELECT count(*) FROM distribution_bindings") == 1)
        #expect(
            try fixture.workspace.integer("SELECT count(*) FROM distribution_link_ownership") == 1
        )
        #expect(try fixture.workspace.integer("SELECT count(*) FROM skill_backups") == 1)
        #expect(try fixture.isSourceSymlink())
        #expect(
            try fixture.sourceSymlinkDestination()
                == fixture.workspace.root
                    .appendingPathComponent(result.skill.skillID.directoryName)
                    .standardizedFileURL.path
        )
        #expect(try fixture.backupSkillBytes(result.backup) == Data("# Historical".utf8))
        let manifest = try fixture.backupManifest(result.backup)
        #expect(manifest.migrationMetadata?.operationID == result.distribution.operationID)
        #expect(manifest.migrationMetadata?.sourceScope == .global)
        #expect(manifest.migrationMetadata?.normalizedLocator == fixture.slug)
    }

    @Test("claims matching SSOT content before migrating the historical directory")
    func claimsAndMigrates() async throws {
        let fixture = try await HistoricalMigrationFixture(content: "# Existing")
        let snapshot = try fixture.workspace.snapshot(content: "# Existing")
        let payload = try fixture.workspace.payload(name: "Existing", snapshot: snapshot)
        _ = try await fixture.writer.create(payload: payload, sourceSnapshot: snapshot)
        let prepared = try await fixture.prepare()
        #expect(prepared.observation.status == .claimable)
        let service = fixture.service()

        let preview = try await service.prepare(
            audit: prepared.audit,
            observation: prepared.observation,
            importAction: .claimExisting
        )
        let result = try await service.confirm(preview.token)

        #expect(result.skill.skillID == payload.skill.skillID)
        #expect(try fixture.workspace.integer("SELECT count(*) FROM skills") == 1)
        #expect(try fixture.workspace.integer("SELECT count(*) FROM local_skill_origins") == 1)
        #expect(try fixture.isSourceSymlink())
    }

    @Test("resumes from a managed but undistributed import without duplicating state")
    func resumesAfterImportOnly() async throws {
        let fixture = try await HistoricalMigrationFixture(content: "# Resume")
        let initial = try await fixture.scanObservation()
        let importer = ManagedSkillImportService(writer: fixture.writer)
        let importPreview = try await importer.preview(
            observation: initial,
            action: .importNew
        )
        let imported = try await importer.execute(importPreview.token)
        let prepared = try await fixture.prepare()
        #expect(prepared.observation.status == .managed)
        let service = fixture.service()

        let preview = try await service.prepare(
            audit: prepared.audit,
            observation: prepared.observation,
            importAction: nil
        )
        let result = try await service.confirm(preview.token)

        #expect(result.skill.skillID == imported.skill.skillID)
        #expect(try fixture.workspace.integer("SELECT count(*) FROM skills") == 1)
        #expect(try fixture.workspace.integer("SELECT count(*) FROM skill_backups") == 1)
        #expect(try fixture.workspace.integer("SELECT count(*) FROM distribution_bindings") == 1)
        #expect(try fixture.isSourceSymlink())
    }

    @Test("stale audit fails before import, backup, or source mutation")
    func stalePreviewFailsClosed() async throws {
        let fixture = try await HistoricalMigrationFixture(content: "# Before")
        let prepared = try await fixture.prepare()
        let service = fixture.service()
        let preview = try await service.prepare(
            audit: prepared.audit,
            observation: prepared.observation,
            importAction: .importNew
        )
        try Data("# After".utf8).write(
            to: fixture.sourceURL.appendingPathComponent("SKILL.md"),
            options: .atomic
        )

        await #expect(throws: HistoricalSkillMigrationError.stalePreview) {
            _ = try await service.confirm(preview.token)
        }

        #expect(try fixture.workspace.integer("SELECT count(*) FROM skills") == 0)
        #expect(try fixture.workspace.integer("SELECT count(*) FROM skill_backups") == 0)
        #expect(try fixture.workspace.integer("SELECT count(*) FROM distribution_operations") == 0)
        #expect(try !fixture.isSourceSymlink())
        #expect(
            try Data(contentsOf: fixture.sourceURL.appendingPathComponent("SKILL.md"))
                == Data("# After".utf8)
        )
    }

    @Test("backup failure preserves the historical directory and managed SSOT state")
    func backupFailureDoesNotMutateSource() async throws {
        let fixture = try await HistoricalMigrationFixture(content: "# Protected")
        let prepared = try await fixture.prepare()
        let service = fixture.service()
        let preview = try await service.prepare(
            audit: prepared.audit,
            observation: prepared.observation,
            importAction: .importNew
        )
        let backupRoot = fixture.workspace.managementRoot
            .appendingPathComponent("skill-backups", isDirectory: true)
        try FileManager.default.removeItem(at: backupRoot)
        try Data("occupied".utf8).write(to: backupRoot)

        await #expect(throws: HistoricalSkillMigrationError.backupUnavailable) {
            _ = try await service.confirm(preview.token)
        }

        #expect(try fixture.workspace.integer("SELECT count(*) FROM skills") == 1)
        #expect(try fixture.workspace.integer("SELECT count(*) FROM distribution_bindings") == 0)
        #expect(try !fixture.isSourceSymlink())
        #expect(
            try Data(contentsOf: fixture.sourceURL.appendingPathComponent("SKILL.md"))
                == Data("# Protected".utf8)
        )
    }

    @Test("rollback source drift is persisted and returned as needs repair")
    func rollbackSourceDriftNeedsRepair() async throws {
        let fixture = try await HistoricalMigrationFixture(content: "# Rollback")
        let mutation = HistoricalRollbackMutation(sourceURL: fixture.sourceURL)
        let prepared = try await fixture.prepareExecutorMigration(
            hooks: .init(onCheckpoint: mutation.reach)
        )

        #expect(throws: DistributionSymlinkExecutorError.needsRepair(
            "distribution rollback requires repair"
        )) {
            _ = try prepared.executor.apply(
                skillID: prepared.skillID,
                plan: prepared.plan,
                expectedOldBindings: [],
                approvedHistoricalMigration: prepared.approval,
                operationID: prepared.operationID,
                nowMilliseconds: 42
            )
        }

        let operation = try prepared.operationStore.load(prepared.operationID)
        #expect(operation.outcome == .needsRepair)
        #expect(try fixture.workspace.integer("SELECT count(*) FROM distribution_bindings") == 0)
        #expect(try !fixture.isSourceSymlink())
        #expect(
            try Data(contentsOf: fixture.sourceURL.appendingPathComponent("SKILL.md"))
                == Data("# Drifted after restore".utf8)
        )
    }

    @Test("a clean rollback retries with one existing backup and a new operation")
    func cleanRollbackRetriesWithoutDuplicateBackup() async throws {
        let fixture = try await HistoricalMigrationFixture(content: "# Retry")
        let interruption = HistoricalForwardInterruption()
        let first = try await fixture.prepareExecutorMigration(
            hooks: .init(onCheckpoint: interruption.reach)
        )
        #expect(throws: HistoricalForwardInterruption.Failure.self) {
            _ = try first.executor.apply(
                skillID: first.skillID,
                plan: first.plan,
                expectedOldBindings: [],
                approvedHistoricalMigration: first.approval,
                operationID: first.operationID,
                nowMilliseconds: 42
            )
        }
        #expect(try first.operationStore.load(first.operationID).outcome == .rolledBack)
        let prepared = try await fixture.prepare()
        #expect(prepared.observation.status == .managed)
        let service = fixture.service()
        let preview = try await service.prepare(
            audit: prepared.audit,
            observation: prepared.observation,
            importAction: nil
        )
        #expect(preview.operationID != first.operationID)

        let result = try await service.confirm(preview.token)

        #expect(result.backup.backupID == first.approval.backup.backupID)
        #expect(result.distribution.operationID == preview.operationID)
        #expect(try fixture.workspace.integer("SELECT count(*) FROM skill_backups") == 1)
        #expect(try fixture.workspace.integer("SELECT count(*) FROM distribution_operations") == 2)
        #expect(try fixture.workspace.integer("SELECT count(*) FROM distribution_bindings") == 1)
        #expect(try fixture.isSourceSymlink())
    }
}

private final class HistoricalMigrationFixture: @unchecked Sendable {
    let workspace: WriterWorkspace
    let writer: JournaledSSOTWriter
    let globalRoot: URL
    let sourceURL: URL
    let slug = "demo"

    init(content: String) async throws {
        workspace = try WriterWorkspace(distributionEnabled: true)
        globalRoot = workspace.distributionHomeURL
            .appendingPathComponent(".agents/skills", isDirectory: true)
        sourceURL = globalRoot.appendingPathComponent(slug, isDirectory: true)
        try FileManager.default.createDirectory(at: sourceURL, withIntermediateDirectories: true)
        try Data(content.utf8).write(
            to: sourceURL.appendingPathComponent("SKILL.md"),
            options: .atomic
        )
        writer = try await workspace.openWriter()
        _ = try await writer.migrateLegacy(homeURL: workspace.distributionHomeURL)
    }

    func service() -> HistoricalSkillMigrationService {
        HistoricalSkillMigrationService(
            writer: writer,
            homeURL: workspace.distributionHomeURL,
            nowMilliseconds: { 42 }
        )
    }

    func prepare() async throws -> (
        audit: SkillConsistencyAuditPrepared,
        observation: SkillDiscoveryObservation
    ) {
        let audit = try await SkillConsistencyAuditService(
            writer: writer,
            homeURL: workspace.distributionHomeURL
        ).prepare()
        return (audit, try await scanObservation())
    }

    func scanObservation() async throws -> SkillDiscoveryObservation {
        let catalog = try await writer.discoveryCatalog()
        return try #require(
            SkillDiscoveryScanner().scan(
                roots: [SkillDiscoveryRoot(scope: .global, url: globalRoot)],
                catalog: catalog
            ).observations.first
        )
    }

    func isSourceSymlink() throws -> Bool {
        var metadata = stat()
        guard Darwin.lstat(sourceURL.path, &metadata) == 0 else {
            throw CocoaError(.fileReadUnknown)
        }
        return metadata.st_mode & mode_t(S_IFMT) == S_IFLNK
    }

    func sourceSymlinkDestination() throws -> String {
        try FileManager.default.destinationOfSymbolicLink(atPath: sourceURL.path)
    }

    func backupSkillBytes(_ backup: SkillBackupRecord) throws -> Data {
        try Data(contentsOf: backupURL(backup)
            .appendingPathComponent("skill-files", isDirectory: true)
            .appendingPathComponent("SKILL.md"))
    }

    func backupManifest(_ backup: SkillBackupRecord) throws -> SkillBackupManifestV1 {
        try SkillBackupManifestV1.decode(
            Data(contentsOf: backupURL(backup).appendingPathComponent("manifest.json"))
        )
    }

    private func backupURL(_ backup: SkillBackupRecord) -> URL {
        workspace.managementRoot
            .appendingPathComponent("skill-backups", isDirectory: true)
            .appendingPathComponent(backup.locator, isDirectory: true)
    }

    func prepareExecutorMigration(
        hooks: DistributionFilesystemTestHooks
    ) async throws -> HistoricalExecutorPreparation {
        let observation = try await scanObservation()
        let importer = ManagedSkillImportService(writer: writer, nowMilliseconds: { 42 })
        let importPreview = try await importer.preview(
            observation: observation,
            action: .importNew
        )
        let imported = try await importer.execute(importPreview.token)
        let root = try #require(observation.roots.first)
        let source = HistoricalSkillMigrationSource(
            discoveryScope: root.scope,
            scope: .global,
            rawLocator: observation.rawRelativeLocator,
            normalizedLocator: observation.relativeLocator,
            rootIdentity: observation.rootIdentity,
            candidateIdentity: try #require(observation.candidateIdentity),
            fingerprint: try #require(observation.fingerprint)
        )
        let capture = try await writer.captureHistoricalMigrationSource(source)
        let domain = try #require(
            try await writer.storedDomainReadback(imported.skill.skillID)
        )
        let selection = try await writer.loadDistributionSelection(
            skillID: imported.skill.skillID
        )
        let backupID = SkillBackupID()
        let operationID = SSOTOperationID()
        let metadata = try SkillBackupMigrationMetadata(
            operationID: operationID,
            sourceScope: .global,
            rawLocator: source.rawLocator,
            normalizedLocator: source.normalizedLocator,
            rootIdentity: source.rootIdentity,
            candidateIdentity: source.candidateIdentity,
            fingerprint: source.fingerprint,
            createdAtMilliseconds: 42
        )
        let backup = try await writer.publishIndependentBackup(
            domain: domain,
            selection: selection,
            snapshot: capture.snapshot,
            backupID: backupID,
            createdAtMilliseconds: 42,
            migrationMetadata: metadata
        )
        let plan = try await writer.historicalMigrationPlan(
            skillID: imported.skill.skillID,
            scope: .global,
            slug: try DefaultDistributionSlug(validating: slug)
        )
        let connection = try SQLiteConnection(url: workspace.database)
        let backupFileSystem = try SkillBackupFileSystem(
            managementRoot: workspace.verifiedManagementRoot,
            ownership: await writer.ownership
        )
        let executor = try DistributionCopyExecutor(
            connection: connection,
            fileSystem: DistributionSymlinkFileSystem(
                homeURL: workspace.distributionHomeURL,
                hooks: hooks
            ),
            backupFileSystem: backupFileSystem,
            nowMilliseconds: { 42 }
        )
        return HistoricalExecutorPreparation(
            executor: executor,
            operationStore: try DistributionOperationStore(connection: connection),
            skillID: imported.skill.skillID,
            operationID: operationID,
            plan: plan,
            approval: DistributionHistoricalMigrationApproval(
                source: capture.evidence,
                backup: backup,
                metadata: metadata
            )
        )
    }
}

private struct HistoricalExecutorPreparation {
    let executor: DistributionCopyExecutor
    let operationStore: DistributionOperationStore
    let skillID: SkillID
    let operationID: SSOTOperationID
    let plan: DistributionPlan
    let approval: DistributionHistoricalMigrationApproval
}

private final class HistoricalRollbackMutation: @unchecked Sendable {
    struct ForwardFailure: Error {}

    private let sourceURL: URL
    private let lock = NSLock()
    private var failedForward = false

    init(sourceURL: URL) {
        self.sourceURL = sourceURL
    }

    func reach(_ checkpoint: DistributionFilesystemCheckpoint) throws {
        lock.lock()
        defer { lock.unlock() }
        if checkpoint == .afterCreateSync, !failedForward {
            failedForward = true
            throw ForwardFailure()
        }
        guard checkpoint == .afterRollbackSync,
              (try? isDirectory(sourceURL)) == true else {
            return
        }
        try Data("# Drifted after restore".utf8).write(
            to: sourceURL.appendingPathComponent("SKILL.md"),
            options: .atomic
        )
    }

    private func isDirectory(_ url: URL) throws -> Bool {
        var metadata = stat()
        guard Darwin.lstat(url.path, &metadata) == 0 else { return false }
        return metadata.st_mode & mode_t(S_IFMT) == S_IFDIR
    }
}

private final class HistoricalForwardInterruption: @unchecked Sendable {
    struct Failure: Error {}

    private let lock = NSLock()
    private var fired = false

    func reach(_ checkpoint: DistributionFilesystemCheckpoint) throws {
        lock.lock()
        defer { lock.unlock() }
        guard checkpoint == .afterCreateSync, !fired else { return }
        fired = true
        throw Failure()
    }
}
