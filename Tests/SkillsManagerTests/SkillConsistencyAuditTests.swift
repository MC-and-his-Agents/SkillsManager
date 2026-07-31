import Darwin
import CryptoKit
import Foundation
import Synchronization
import Testing
@testable import SkillsManager

@Suite("Skill consistency audit", .serialized)
struct SkillConsistencyAuditTests {
    @Test("returns deterministic canonical bytes without mutating managed state")
    func deterministicAndReadOnly() async throws {
        let workspace = try WriterWorkspace(distributionEnabled: true)
        let writer = try await workspace.openWriter()
        _ = try await writer.migrateLegacy(homeURL: workspace.distributionHomeURL)
        let emptyRoot = workspace.distributionHomeURL
            .appendingPathComponent(".agents/skills", isDirectory: true)
        try FileManager.default.createDirectory(at: emptyRoot, withIntermediateDirectories: true)
        let databaseObserver = try SQLiteConnection(
            url: workspace.database,
            accessMode: .readOnly
        )
        let beforeVersion = try dataVersion(databaseObserver)
        let beforeRows = try rowCounts(workspace)
        let beforeSSOT = try treeSignature(workspace.root)
        let beforeDistribution = try treeSignature(
            workspace.distributionHomeURL.appendingPathComponent(".agents")
        )

        let first = try await SkillConsistencyAuditService(
            writer: writer,
            homeURL: workspace.distributionHomeURL
        ).prepare()
        let second = try await SkillConsistencyAuditService(
            writer: writer,
            homeURL: workspace.distributionHomeURL
        ).prepare()

        #expect(first.canonicalBytes == second.canonicalBytes)
        #expect(first.manifest.schema == "skills-manager-consistency-audit/v1")
        #expect(first.manifest.coverage == .complete)
        #expect(first.manifest.managedSkills.isEmpty)
        #expect(
            first.manifest.discovery.roots.contains {
                $0.root.locator == emptyRoot.standardizedFileURL.path
            }
        )
        #expect(try dataVersion(databaseObserver) == beforeVersion)
        #expect(try rowCounts(workspace) == beforeRows)
        #expect(try treeSignature(workspace.root) == beforeSSOT)
        #expect(
            try treeSignature(
                workspace.distributionHomeURL.appendingPathComponent(".agents")
            ) == beforeDistribution
        )
    }

    @Test("attributes a healthy managed Symlink while preserving scanner evidence")
    func managedSymlinkAttribution() async throws {
        let workspace = try WriterWorkspace(distributionEnabled: true)
        let installed = try await install(workspace: workspace, syncMode: .symlink)
        let databaseObserver = try SQLiteConnection(
            url: workspace.database,
            accessMode: .readOnly
        )
        let beforeVersion = try dataVersion(databaseObserver)
        let beforeRows = try rowCounts(workspace)
        let beforeSSOT = try treeSignature(workspace.root)
        let beforeTarget = try treeSignature(installed.targetURL.deletingLastPathComponent())

        let prepared = try await SkillConsistencyAuditService(
            writer: installed.writer,
            homeURL: workspace.distributionHomeURL
        ).prepare()
        let observation = try #require(
            prepared.manifest.discovery.observations.first {
                $0.relativeLocator == installed.slug.value
            }
        )
        let distribution = try #require(prepared.manifest.distributions.first)

        #expect(observation.status == SkillDiscoveryStatus.claimable.rawValue)
        #expect(observation.reason == nil)
        #expect(observation.symbolicLinkIdentity != nil)
        #expect(observation.managedDistributionTarget?.skillID == installed.skillID.directoryName)
        #expect(observation.managedDistributionTarget?.syncMode == "symlink")
        #expect(distribution.status == DistributionReconcileStatus.inSync.rawValue)
        #expect(distribution.targets.first?.observation.kind == "managed")
        #expect(try dataVersion(databaseObserver) == beforeVersion)
        #expect(try rowCounts(workspace) == beforeRows)
        #expect(try treeSignature(workspace.root) == beforeSSOT)
        #expect(
            try treeSignature(installed.targetURL.deletingLastPathComponent()) == beforeTarget
        )
    }

    @Test("attributes only an in-sync managed Copy")
    func managedCopyAttribution() async throws {
        let workspace = try WriterWorkspace(distributionEnabled: true)
        let installed = try await install(workspace: workspace, syncMode: .copy)
        let databaseObserver = try SQLiteConnection(
            url: workspace.database,
            accessMode: .readOnly
        )
        let beforeVersion = try dataVersion(databaseObserver)
        let beforeTarget = try treeSignature(installed.targetURL)

        let prepared = try await SkillConsistencyAuditService(
            writer: installed.writer,
            homeURL: workspace.distributionHomeURL
        ).prepare()
        let observation = try #require(
            prepared.manifest.discovery.observations.first {
                $0.relativeLocator == installed.slug.value
            }
        )
        let target = try #require(prepared.manifest.distributions.first?.targets.first)

        #expect(observation.managedDistributionTarget?.syncMode == "copy")
        #expect(target.observation.kind == "copy")
        #expect(target.observation.copyState == DistributionCopyObservationState.inSync.rawValue)
        #expect(target.observation.copyEvidence?.skillID == installed.skillID.directoryName)
        #expect(try dataVersion(databaseObserver) == beforeVersion)
        #expect(try treeSignature(installed.targetURL) == beforeTarget)
    }

    @Test("keeps Copy drift visible and does not attribute it as healthy")
    func copyDriftIsNotAttributed() async throws {
        let workspace = try WriterWorkspace(distributionEnabled: true)
        let installed = try await install(workspace: workspace, syncMode: .copy)
        try Data("local Copy edit".utf8).write(
            to: installed.targetURL.appendingPathComponent("SKILL.md"),
            options: .atomic
        )
        let beforeTarget = try treeSignature(installed.targetURL)
        let databaseObserver = try SQLiteConnection(
            url: workspace.database,
            accessMode: .readOnly
        )
        let beforeVersion = try dataVersion(databaseObserver)

        let prepared = try await SkillConsistencyAuditService(
            writer: installed.writer,
            homeURL: workspace.distributionHomeURL
        ).prepare()
        let observation = try #require(
            prepared.manifest.discovery.observations.first {
                $0.relativeLocator == installed.slug.value
            }
        )
        let target = try #require(prepared.manifest.distributions.first?.targets.first)

        #expect(observation.managedDistributionTarget == nil)
        #expect(target.observation.copyState == DistributionCopyObservationState.contentDrift.rawValue)
        #expect(try dataVersion(databaseObserver) == beforeVersion)
        #expect(try treeSignature(installed.targetURL) == beforeTarget)
    }

    @Test("canonicalizes equivalent discovery names independently of input order")
    func equivalentDiscoveryNamesAreDeterministic() throws {
        let workspace = try WriterWorkspace()
        let verified = try ManagedRootReference.capture(at: workspace.root).verifiedRoot()
        let root = SkillDiscoveryRoot(scope: .global, url: workspace.root)
        let composed = equivalentObservation(
            rawLocator: "\u{e9}",
            root: root,
            identity: verified.identity
        )
        let decomposed = equivalentObservation(
            rawLocator: "e\u{301}",
            root: root,
            identity: verified.identity
        )
        let observed = SkillDiscoveryObservedRoot(root: root, identity: verified.identity)
        let first = try SkillConsistencyAuditWire.discovery(
            SkillDiscoveryResult(
                observedRoots: [observed],
                observations: [composed, decomposed],
                rootDiagnostics: []
            ),
            homeURL: workspace.workspace,
            bindingsBySkillID: [:],
            reconcileBySkillID: [:]
        )
        let second = try SkillConsistencyAuditWire.discovery(
            SkillDiscoveryResult(
                observedRoots: [observed],
                observations: [decomposed, composed],
                rootDiagnostics: []
            ),
            homeURL: workspace.workspace,
            bindingsBySkillID: [:],
            reconcileBySkillID: [:]
        )

        #expect(
            try SkillConsistencyAuditManifestCodec.encode(first)
                == SkillConsistencyAuditManifestCodec.encode(second)
        )
    }

    @Test("marks an observed unsupported root as incomplete")
    func incompleteCoverage() async throws {
        let workspace = try WriterWorkspace(distributionEnabled: true)
        let writer = try await workspace.openWriter()
        _ = try await writer.migrateLegacy(homeURL: workspace.distributionHomeURL)
        let agents = workspace.distributionHomeURL.appendingPathComponent(".agents")
        try FileManager.default.createDirectory(at: agents, withIntermediateDirectories: false)
        try Data("not a directory".utf8).write(
            to: agents.appendingPathComponent("skills"),
            options: .atomic
        )
        let databaseObserver = try SQLiteConnection(
            url: workspace.database,
            accessMode: .readOnly
        )
        let beforeVersion = try dataVersion(databaseObserver)
        let beforeSSOT = try treeSignature(workspace.root)
        let beforeAgents = try treeSignature(agents)

        let prepared = try await SkillConsistencyAuditService(
            writer: writer,
            homeURL: workspace.distributionHomeURL
        ).prepare()

        #expect(prepared.manifest.coverage == .incomplete)
        #expect(
            prepared.manifest.discovery.rootDiagnostics.map(\.reason)
                .contains(SkillDiscoveryReason.rootUnsupportedType.rawValue)
        )
        #expect(try dataVersion(databaseObserver) == beforeVersion)
        #expect(try treeSignature(workspace.root) == beforeSSOT)
        #expect(try treeSignature(agents) == beforeAgents)
    }

    @Test("preserves a permission-denied root as incomplete without mutation")
    func permissionCoverageIsReadOnly() async throws {
        let workspace = try WriterWorkspace(distributionEnabled: true)
        let writer = try await workspace.openWriter()
        _ = try await writer.migrateLegacy(homeURL: workspace.distributionHomeURL)
        let agents = workspace.distributionHomeURL.appendingPathComponent(".agents")
        let root = agents.appendingPathComponent("skills", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        guard Darwin.chmod(root.path, 0o000) == 0 else {
            throw CocoaError(.fileWriteNoPermission)
        }
        defer { _ = Darwin.chmod(root.path, 0o700) }
        let databaseObserver = try SQLiteConnection(
            url: workspace.database,
            accessMode: .readOnly
        )
        let beforeVersion = try dataVersion(databaseObserver)
        let beforeSSOT = try treeSignature(workspace.root)
        let beforeAgents = try treeSignature(agents)

        let prepared = try await SkillConsistencyAuditService(
            writer: writer,
            homeURL: workspace.distributionHomeURL
        ).prepare()

        #expect(prepared.manifest.coverage == .incomplete)
        #expect(
            prepared.manifest.discovery.rootDiagnostics.map(\.reason)
                .contains(SkillDiscoveryReason.rootPermissionDenied.rawValue)
        )
        #expect(try dataVersion(databaseObserver) == beforeVersion)
        #expect(try treeSignature(workspace.root) == beforeSSOT)
        #expect(try treeSignature(agents) == beforeAgents)
    }

    @Test("rejects an empty root replacement between captures")
    func rootReplacementExpiresManifest() async throws {
        let workspace = try WriterWorkspace(distributionEnabled: true)
        let writer = try await workspace.openWriter()
        _ = try await writer.migrateLegacy(homeURL: workspace.distributionHomeURL)
        let agents = workspace.distributionHomeURL.appendingPathComponent(".agents")
        let root = agents.appendingPathComponent("skills", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let databaseObserver = try SQLiteConnection(
            url: workspace.database,
            accessMode: .readOnly
        )
        let beforeVersion = try dataVersion(databaseObserver)
        let beforeSSOT = try treeSignature(workspace.root)
        let expectedAgents = Mutex<[String]?>(nil)
        let service = SkillConsistencyAuditService(
            writer: writer,
            homeURL: workspace.distributionHomeURL,
            betweenCaptures: {
                try FileManager.default.removeItem(at: root)
                try FileManager.default.createDirectory(
                    at: root,
                    withIntermediateDirectories: false
                )
                let signature = try treeSignature(agents)
                expectedAgents.withLock { $0 = signature }
            }
        )

        await #expect(throws: SkillConsistencyAuditError.sourceChanged) {
            _ = try await service.prepare()
        }
        let expected = try #require(expectedAgents.withLock { $0 })
        #expect(try dataVersion(databaseObserver) == beforeVersion)
        #expect(try treeSignature(workspace.root) == beforeSSOT)
        #expect(try treeSignature(agents) == expected)
    }

    @Test("cancels after a real first capture without mutation")
    func cancellationIsReadOnly() async throws {
        let workspace = try WriterWorkspace(distributionEnabled: true)
        let writer = try await workspace.openWriter()
        _ = try await writer.migrateLegacy(homeURL: workspace.distributionHomeURL)
        let databaseObserver = try SQLiteConnection(
            url: workspace.database,
            accessMode: .readOnly
        )
        let beforeVersion = try dataVersion(databaseObserver)
        let beforeSSOT = try treeSignature(workspace.root)
        let beforeAgents = try treeSignature(
            workspace.distributionHomeURL.appendingPathComponent(".agents")
        )
        let service = SkillConsistencyAuditService(
            writer: writer,
            homeURL: workspace.distributionHomeURL,
            betweenCaptures: { throw CancellationError() }
        )

        await #expect(throws: CancellationError.self) {
            _ = try await service.prepare()
        }
        #expect(try dataVersion(databaseObserver) == beforeVersion)
        #expect(try treeSignature(workspace.root) == beforeSSOT)
        #expect(
            try treeSignature(
                workspace.distributionHomeURL.appendingPathComponent(".agents")
            ) == beforeAgents
        )
    }

    @Test("maps trust-boundary failures to stable errors")
    func stableErrors() {
        let cases: [(
            source: any Error,
            expected: SkillConsistencyAuditError
        )] = [
            (
                NSError(domain: NSPOSIXErrorDomain, code: Int(EACCES)),
                .permissionDenied
            ),
            (
                SQLiteStoreError.invalidState("test-only"),
                .databaseUnavailable
            ),
            (
                ManagedPathError.rootReplaced,
                .writerUnavailable
            ),
            (
                ManagedLocalCatalogError.inconsistentCatalog,
                .inconsistentCatalog
            ),
        ]
        for (source, expected) in cases {
            #expect(SkillConsistencyAuditWire.stableError(source) == expected)
        }
    }
}

private struct DistributedAuditSkill {
    let writer: JournaledSSOTWriter
    let skillID: SkillID
    let slug: DefaultDistributionSlug
    let targetURL: URL
}

private func install(
    workspace: WriterWorkspace,
    syncMode: DistributionSyncMode
) async throws -> DistributedAuditSkill {
    let writer = try await workspace.openWriter()
    _ = try await writer.migrateLegacy(homeURL: workspace.distributionHomeURL)
    let snapshot = try workspace.snapshot(content: "audit-\(syncMode.rawValue)")
    let skillID = SkillID()
    let payload = try workspace.payload(
        skillID: skillID,
        name: "Audit\(syncMode.rawValue.capitalized)",
        snapshot: snapshot
    )
    _ = try await writer.create(payload: payload, sourceSnapshot: snapshot)
    let plan = try await writer.distributionPlan(
        skillID: skillID,
        desiredConfiguration: .init(
            scope: .global(payload.skill.defaultDistributionSlug),
            syncMode: syncMode
        ),
        requiredAdapterCodes: Set(
            DistributionTargetCatalog.current.globalReaders.map(\.storageKey)
        )
    )
    _ = try await writer.applyDistribution(skillID: skillID, plan: plan)
    let targetURL = workspace.distributionHomeURL
        .appendingPathComponent(".agents/skills", isDirectory: true)
        .appendingPathComponent(
            payload.skill.defaultDistributionSlug.value,
            isDirectory: true
        )
    return DistributedAuditSkill(
        writer: writer,
        skillID: skillID,
        slug: payload.skill.defaultDistributionSlug,
        targetURL: targetURL
    )
}

private func rowCounts(_ workspace: WriterWorkspace) throws -> [String: Int64] {
    let tables = [
        "skills",
        "skill_operations",
        "distribution_bindings",
        "distribution_configurations",
        "distribution_link_ownership",
        "distribution_operations",
        "copy_fork_operations",
        "skill_backups",
        "skill_deletion_operations",
        "local_skill_origins",
        "sources",
        "provider_aliases",
    ]
    return try Dictionary(uniqueKeysWithValues: tables.map {
        ($0, try workspace.integer("SELECT count(*) FROM \($0)") ?? -1)
    })
}

private func dataVersion(_ connection: SQLiteConnection) throws -> Int64 {
    try #require(try connection.querySingleInt("PRAGMA data_version"))
}

private func treeSignature(_ root: URL) throws -> [String] {
    var rootMetadata = stat()
    guard Darwin.lstat(root.path, &rootMetadata) == 0 else {
        if errno == ENOENT { return [] }
        throw CocoaError(.fileReadUnknown)
    }
    let enumerator = FileManager.default.enumerator(
        at: root,
        includingPropertiesForKeys: nil,
        options: [],
        errorHandler: { _, _ in false }
    )
    var urls = [root]
    if let enumerator {
        urls.append(contentsOf: enumerator.compactMap { $0 as? URL })
    }
    return try urls.map { try treeEntrySignature($0, relativeTo: root) }.sorted()
}

private func treeEntrySignature(_ url: URL, relativeTo root: URL) throws -> String {
    var metadata = stat()
    guard Darwin.lstat(url.path, &metadata) == 0 else {
        throw CocoaError(.fileReadUnknown)
    }
    let type = metadata.st_mode & mode_t(S_IFMT)
    let payload: String
    if type == S_IFREG {
        payload = Data(SHA256.hash(data: try Data(contentsOf: url))).base64EncodedString()
    } else if type == S_IFLNK {
        payload = try FileManager.default.destinationOfSymbolicLink(atPath: url.path)
    } else {
        payload = ""
    }
    let relative = url == root ? "." : String(url.path.dropFirst(root.path.count))
    return [
        relative,
        String(metadata.st_mode),
        String(metadata.st_size),
        try ManagedItemIdentityCodec.encode(ManagedItemIdentity(metadata)).base64EncodedString(),
        payload,
    ].joined(separator: "\u{0}")
}
