import Foundation
import ZIPFoundation

@testable import SkillsManager

struct ManagedUpdateExecutionFixture {
    let workspace: WriterWorkspace
    let writer: JournaledSSOTWriter
    let skillID: SkillID
    let checks: ManagedSkillUpdateCheckService
    let remote: MutableExecutionRemote
    let copyURL: URL?
    let copyURLs: [String: URL]
}

func makeExecutionFixture(
    remoteMarkdown: String,
    copy: Bool = false,
    copyPlatforms: Set<SkillPlatform>? = nil,
    distributionEnabled: Bool? = nil,
    hooks: JournaledSSOTWriterHooks = .init()
) async throws -> ManagedUpdateExecutionFixture {
    let workspace = try WriterWorkspace(distributionEnabled: distributionEnabled ?? copy)
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
    var copyURLs: [String: URL] = [:]
    if copy {
        let slug = payload.skill.defaultDistributionSlug
        let scope: DistributionDesiredScope = copyPlatforms.map {
            .agents($0, slug)
        } ?? .global(slug)
        let plan = try await writer.distributionPlan(
            skillID: skillID,
            desiredConfiguration: DistributionDesiredConfiguration(
                scope: scope,
                syncMode: .copy
            ),
            requiredAdapterCodes: scope.requiredAdapterCodes
        )
        _ = try await writer.applyDistribution(skillID: skillID, plan: plan)
        let selection = try await writer.loadDistributionSelection(skillID: skillID)
        copyURLs = try Dictionary(uniqueKeysWithValues: selection.bindings.map { binding in
            guard let target = DistributionTargetCatalog.current.target(for: binding.scope),
                  target.rootLocator.hasPrefix("~/") else {
                throw ManagedUpdateExecutionInterruption()
            }
            let root = workspace.workspace.appendingPathComponent(
                String(target.rootLocator.dropFirst(2)),
                isDirectory: true
            )
            return (
                binding.scope.targetScopeKey,
                root.appendingPathComponent(slug.value, isDirectory: true)
            )
        })
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
        copyURL: copyURLs[DistributionBindingScope.global.targetScopeKey],
        copyURLs: copyURLs
    )
}

func managedMarkdown(
    _ fixture: ManagedUpdateExecutionFixture
) async throws -> String {
    try String(
        contentsOf: fixture.workspace.root
            .appendingPathComponent(fixture.skillID.directoryName)
            .appendingPathComponent("SKILL.md"),
        encoding: .utf8
    )
}

func executionArchive(markdown: String) throws -> URL {
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

final class MutableExecutionRemote: @unchecked Sendable {
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

final class UpdateBackupInterruption: @unchecked Sendable {
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

struct ManagedUpdateExecutionInterruption: Error {}

actor TemporaryRootCapture {
    private(set) var url: URL?

    func record(_ url: URL) {
        self.url = url
    }
}
