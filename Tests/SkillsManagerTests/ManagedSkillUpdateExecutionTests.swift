import Foundation
import Testing
import ZIPFoundation

@testable import SkillsManager

@Suite("Managed Skill update execution", .serialized)
struct ManagedSkillUpdateExecutionTests {
    @Test("Clawdhub update backs up, replaces, and records an up-to-date snapshot")
    func updatesClawdhubSkill() async throws {
        let fixture = try await makeExecutionFixture(remoteMarkdown: "# Remote")
        defer { fixture.remote.cleanup() }
        let snapshot = try await fixture.checks.check(fixture.skillID)
        let service = ManagedSkillUpdateExecutionService(
            writer: fixture.writer,
            remote: fixture.remote.client
        )

        let preview = try await service.prepare(snapshot)
        let result = try await service.confirm(preview.token, selections: [])

        #expect(result.status == .updated)
        #expect(try fixture.workspace.integer("SELECT count(*) FROM skill_backups") == 1)
        #expect(try await fixture.writer.loadUpdateCheck(fixture.skillID)?.status == .upToDate)
        #expect(try await managedMarkdown(fixture) == "# Remote")
    }

    @Test("unchanged candidates do not enter the update write path")
    func noChangeIsZeroWrite() async throws {
        let fixture = try await makeExecutionFixture(remoteMarkdown: "# Original")
        defer { fixture.remote.cleanup() }
        let snapshot = try await fixture.checks.check(fixture.skillID)
        let service = ManagedSkillUpdateExecutionService(
            writer: fixture.writer,
            remote: fixture.remote.client
        )

        await #expect(throws: ManagedSkillUpdateExecutionProblem.noUpdate) {
            _ = try await service.prepare(snapshot)
        }
        #expect(try fixture.workspace.integer("SELECT count(*) FROM skill_backups") == 0)
    }

    @Test("a changed remote candidate expires the confirmation")
    func remoteCandidateExpires() async throws {
        let fixture = try await makeExecutionFixture(remoteMarkdown: "# Remote")
        defer { fixture.remote.cleanup() }
        let snapshot = try await fixture.checks.check(fixture.skillID)
        let service = ManagedSkillUpdateExecutionService(
            writer: fixture.writer,
            remote: fixture.remote.client
        )
        let preview = try await service.prepare(snapshot)
        let newerArchive = try executionArchive(markdown: "# Newer")
        defer { try? FileManager.default.removeItem(at: newerArchive) }
        fixture.remote.set(version: "3.0.0", archiveURL: newerArchive)

        await #expect(throws: ManagedSkillUpdateExecutionProblem.stale) {
            _ = try await service.confirm(preview.token, selections: [])
        }
        #expect(try fixture.workspace.integer("SELECT count(*) FROM skill_backups") == 0)
        #expect(try await managedMarkdown(fixture) == "# Original")
    }

    @Test("a local SSOT edit expires the confirmation before backup")
    func localEditExpiresConfirmation() async throws {
        let fixture = try await makeExecutionFixture(remoteMarkdown: "# Remote")
        defer { fixture.remote.cleanup() }
        let snapshot = try await fixture.checks.check(fixture.skillID)
        let service = ManagedSkillUpdateExecutionService(
            writer: fixture.writer,
            remote: fixture.remote.client
        )
        let preview = try await service.prepare(snapshot)
        try Data("# Local edit".utf8).write(
            to: fixture.workspace.root
                .appendingPathComponent(fixture.skillID.directoryName)
                .appendingPathComponent("SKILL.md")
        )

        await #expect(throws: ManagedSkillUpdateExecutionProblem.stale) {
            _ = try await service.confirm(preview.token, selections: [])
        }
        #expect(try fixture.workspace.integer("SELECT count(*) FROM skill_backups") == 0)
    }

    @Test("a confirmation token is single-use")
    func duplicateConfirmIsRejected() async throws {
        let fixture = try await makeExecutionFixture(remoteMarkdown: "# Remote")
        defer { fixture.remote.cleanup() }
        let snapshot = try await fixture.checks.check(fixture.skillID)
        let service = ManagedSkillUpdateExecutionService(
            writer: fixture.writer,
            remote: fixture.remote.client
        )
        let preview = try await service.prepare(snapshot)
        #expect(try await service.confirm(preview.token, selections: []).status == .updated)

        await #expect(throws: ManagedSkillUpdateExecutionProblem.stale) {
            _ = try await service.confirm(preview.token, selections: [])
        }
        #expect(try fixture.workspace.integer("SELECT count(*) FROM skill_backups") == 1)
    }

    @Test("a published backup without a replacement has a stable retry-safe result")
    func backupReadyBeforeReplacement() async throws {
        let interruption = UpdateBackupInterruption()
        var hooks = JournaledSSOTWriterHooks()
        hooks.afterUpdateBackupPublished = interruption.reach
        let fixture = try await makeExecutionFixture(
            remoteMarkdown: "# Remote",
            hooks: hooks
        )
        defer { fixture.remote.cleanup() }
        let snapshot = try await fixture.checks.check(fixture.skillID)
        let service = ManagedSkillUpdateExecutionService(
            writer: fixture.writer,
            remote: fixture.remote.client
        )
        let preview = try await service.prepare(snapshot)
        interruption.arm()

        let result = try await service.confirm(preview.token, selections: [])

        #expect(result.status == .backupReadyUpdateNotStarted)
        #expect(result.backupID != nil)
        #expect(try await managedMarkdown(fixture) == "# Original")
        #expect(try await fixture.writer.loadUpdateCheck(fixture.skillID) == snapshot)
    }

    @Test("replacement interruption recovers before returning success")
    func interruptionRecoversBeforeSuccess() async throws {
        let interruption = CopyForkCheckpointInterruption()
        var hooks = JournaledSSOTWriterHooks()
        hooks.checkpoint = interruption.reach
        let fixture = try await makeExecutionFixture(
            remoteMarkdown: "# Remote",
            hooks: hooks
        )
        defer { fixture.remote.cleanup() }
        let snapshot = try await fixture.checks.check(fixture.skillID)
        let service = ManagedSkillUpdateExecutionService(
            writer: fixture.writer,
            remote: fixture.remote.client
        )
        let preview = try await service.prepare(snapshot)
        interruption.arm(at: .beforeReplacementSwap)

        let result = try await service.confirm(preview.token, selections: [])

        #expect(result.status == .updated)
        #expect(try await managedMarkdown(fixture) == "# Remote")
        #expect(try await fixture.writer.loadUpdateCheck(fixture.skillID)?.status == .upToDate)
    }

    @Test("Copy discard keeps Copy mode and refreshes the remote content")
    func updatesAfterDiscardingCopyDrift() async throws {
        let fixture = try await makeExecutionFixture(
            remoteMarkdown: "# Remote",
            copy: true
        )
        defer { fixture.remote.cleanup() }
        try Data("# Local Copy".utf8).write(to: fixture.copyURL!.appendingPathComponent("SKILL.md"))
        let snapshot = try await fixture.checks.check(fixture.skillID)
        #expect(snapshot.status == .copyDrift)
        let service = ManagedSkillUpdateExecutionService(
            writer: fixture.writer,
            remote: fixture.remote.client
        )
        let preview = try await service.prepare(snapshot)
        let choice = try #require(preview.copyChoices.first)

        let result = try await service.confirm(
            preview.token,
            selections: [
                ManagedSkillUpdateDecisionSelection(
                    scopeKey: choice.scopeKey,
                    decision: .discard
                ),
            ]
        )

        #expect(result.status == .updated)
        #expect(try String(
            contentsOf: fixture.copyURL!.appendingPathComponent("SKILL.md"),
            encoding: .utf8
        ) == "# Remote")
        let selection = try await fixture.writer.loadDistributionSelection(
            skillID: fixture.skillID
        )
        #expect(selection.bindings.first?.syncMode == .copy)
        #expect(try await fixture.writer.loadUpdateCheck(fixture.skillID)?.status == .upToDate)
    }

    @Test("Copy Fork preserves local content as an independent managed Skill")
    func updatesParentAfterForkingCopyDrift() async throws {
        let fixture = try await makeExecutionFixture(
            remoteMarkdown: "# Remote",
            copy: true
        )
        defer { fixture.remote.cleanup() }
        try Data("# Local Fork".utf8).write(to: fixture.copyURL!.appendingPathComponent("SKILL.md"))
        let snapshot = try await fixture.checks.check(fixture.skillID)
        let service = ManagedSkillUpdateExecutionService(
            writer: fixture.writer,
            remote: fixture.remote.client
        )
        let preview = try await service.prepare(snapshot)
        let choice = try #require(preview.copyChoices.first)

        let result = try await service.confirm(
            preview.token,
            selections: [
                ManagedSkillUpdateDecisionSelection(
                    scopeKey: choice.scopeKey,
                    decision: .fork
                ),
            ]
        )

        #expect(result.status == .updated)
        #expect(try await managedMarkdown(fixture) == "# Remote")
        #expect(try String(
            contentsOf: fixture.copyURL!.appendingPathComponent("SKILL.md"),
            encoding: .utf8
        ) == "# Local Fork")
        let catalog = try await fixture.writer.managedLocalCatalogReadback()
        let child = try #require(catalog.skills.first(where: {
            $0.skill.skillID != fixture.skillID
        }))
        #expect(
            try await fixture.writer.storedDomainReadback(child.skill.skillID)?
                .payload.forkLineage?.parentSkillID == fixture.skillID
        )
    }

    @Test("a selected cancel leaves Copy drift and managed content untouched")
    func cancelIsZeroWrite() async throws {
        let fixture = try await makeExecutionFixture(
            remoteMarkdown: "# Remote",
            copy: true
        )
        defer { fixture.remote.cleanup() }
        try Data("# Local Copy".utf8).write(to: fixture.copyURL!.appendingPathComponent("SKILL.md"))
        let snapshot = try await fixture.checks.check(fixture.skillID)
        let service = ManagedSkillUpdateExecutionService(
            writer: fixture.writer,
            remote: fixture.remote.client
        )
        let preview = try await service.prepare(snapshot)
        let choice = try #require(preview.copyChoices.first)
        let backupCount = try fixture.workspace.integer(
            "SELECT count(*) FROM skill_backups"
        )

        let result = try await service.confirm(
            preview.token,
            selections: [
                ManagedSkillUpdateDecisionSelection(
                    scopeKey: choice.scopeKey,
                    decision: .cancel
                ),
            ]
        )

        #expect(result.status == .cancelled)
        #expect(try fixture.workspace.integer(
            "SELECT count(*) FROM skill_backups"
        ) == backupCount)
        #expect(try await managedMarkdown(fixture) == "# Original")
        #expect(try String(
            contentsOf: fixture.copyURL!.appendingPathComponent("SKILL.md"),
            encoding: .utf8
        ) == "# Local Copy")
    }

    @Test("incomplete Copy decisions are rejected before durable writes")
    func invalidDecisionsAreZeroWrite() async throws {
        let fixture = try await makeExecutionFixture(
            remoteMarkdown: "# Remote",
            copy: true
        )
        defer { fixture.remote.cleanup() }
        try Data("# Local Copy".utf8).write(to: fixture.copyURL!.appendingPathComponent("SKILL.md"))
        let snapshot = try await fixture.checks.check(fixture.skillID)
        let service = ManagedSkillUpdateExecutionService(
            writer: fixture.writer,
            remote: fixture.remote.client
        )
        let preview = try await service.prepare(snapshot)

        await #expect(throws: ManagedSkillUpdateExecutionProblem.invalidDecisions) {
            _ = try await service.confirm(preview.token, selections: [])
        }
        #expect(try fixture.workspace.integer("SELECT count(*) FROM skill_backups") == 0)
        #expect(try await managedMarkdown(fixture) == "# Original")
    }
}

private struct ManagedUpdateExecutionFixture {
    let workspace: WriterWorkspace
    let writer: JournaledSSOTWriter
    let skillID: SkillID
    let checks: ManagedSkillUpdateCheckService
    let remote: MutableExecutionRemote
    let copyURL: URL?
}

private func makeExecutionFixture(
    remoteMarkdown: String,
    copy: Bool = false,
    hooks: JournaledSSOTWriterHooks = .init()
) async throws -> ManagedUpdateExecutionFixture {
    let workspace = try WriterWorkspace(distributionEnabled: copy)
    let writer = try await workspace.openWriter(hooks: hooks)
    let source = try workspace.snapshot(content: "# Original")
    let skillID = SkillID()
    let identity = try ProviderAliasIdentity(provider: "clawdhub", identifier: "demo")
    let payload = try SSOTSkillWritePayload(
        skill: workspace.payload(
            skillID: skillID,
            name: "Demo",
            snapshot: source
        ).skill,
        providerProvenance: [
            try ProviderProvenanceRecord(
                skillID: skillID,
                identity: identity,
                identifierKey: try DefaultDistributionSlug(
                    validating: "demo"
                ).collisionKey,
                version: try SourceVersion("1.0.0")
            ),
        ]
    )
    _ = try await writer.create(payload: payload, sourceSnapshot: source)
    var copyURL: URL?
    if copy {
        let slug = payload.skill.defaultDistributionSlug
        let plan = try await writer.distributionPlan(
            skillID: skillID,
            desiredConfiguration: DistributionDesiredConfiguration(
                scope: .global(slug),
                syncMode: .copy
            ),
            requiredAdapterCodes: globalReaderCodes
        )
        _ = try await writer.applyDistribution(skillID: skillID, plan: plan)
        copyURL = workspace.workspace
            .appendingPathComponent(".agents/skills", isDirectory: true)
            .appendingPathComponent(slug.value, isDirectory: true)
    }
    let archive = try executionArchive(markdown: remoteMarkdown)
    let remote = MutableExecutionRemote(version: "2.0.0", archiveURL: archive)
    return ManagedUpdateExecutionFixture(
        workspace: workspace,
        writer: writer,
        skillID: skillID,
        checks: ManagedSkillUpdateCheckService(
            writer: writer,
            remote: remote.client
        ),
        remote: remote,
        copyURL: copyURL
    )
}

private func managedMarkdown(
    _ fixture: ManagedUpdateExecutionFixture
) async throws -> String {
    try String(
        contentsOf: fixture.workspace.root
            .appendingPathComponent(fixture.skillID.directoryName)
            .appendingPathComponent("SKILL.md"),
        encoding: .utf8
    )
}

private func executionArchive(markdown: String) throws -> URL {
    let url = FileManager.default.temporaryDirectory
        .appendingPathComponent("managed-update-\(UUID().uuidString).zip")
    let archive = try Archive(url: url, accessMode: .create)
    let contents = Data(markdown.utf8)
    try archive.addEntry(
        with: "demo/SKILL.md",
        type: .file,
        uncompressedSize: Int64(contents.count),
        permissions: 0o644
    ) { position, size in
        let start = Int(position)
        return contents.subdata(in: start..<min(start + size, contents.count))
    }
    return url
}

private final class MutableExecutionRemote: @unchecked Sendable {
    private let lock = NSLock()
    private var version: String
    private var archiveURL: URL
    private var ownedURLs: [URL]

    init(version: String, archiveURL: URL) {
        self.version = version
        self.archiveURL = archiveURL
        ownedURLs = [archiveURL]
    }

    var client: RemoteSkillClient {
        RemoteSkillClient(
            fetchLatest: { _ in [] },
            search: { _, _ in [] },
            download: { [self] _, _ in
                lock.withLock { DownloadedSkillArchive(borrowedAt: archiveURL) }
            },
            fetchDetail: { _ in nil },
            fetchLatestVersion: { [self] _ in lock.withLock { version } }
        )
    }

    func set(version: String, archiveURL: URL) {
        lock.withLock {
            self.version = version
            self.archiveURL = archiveURL
            ownedURLs.append(archiveURL)
        }
    }

    func cleanup() {
        for url in lock.withLock({ ownedURLs }) {
            try? FileManager.default.removeItem(at: url)
        }
    }
}

private final class UpdateBackupInterruption: @unchecked Sendable {
    private let lock = NSLock()
    private var armed = false

    func arm() {
        lock.withLock { armed = true }
    }

    func reach(_: SkillBackupID) throws {
        let shouldStop = lock.withLock {
            defer { armed = false }
            return armed
        }
        if shouldStop {
            throw ManagedUpdateExecutionInterruption()
        }
    }
}

private struct ManagedUpdateExecutionInterruption: Error {}
