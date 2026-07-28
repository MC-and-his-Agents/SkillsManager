import Darwin
import Foundation
import Testing

@testable import SkillsManager

struct RepairFixture {
    let workspace: WriterWorkspace
    let writer: JournaledSSOTWriter
    let skillID: SkillID
    let slug: DefaultDistributionSlug
    let targetURL: URL
    let oldBindings: [DistributionBinding]
    let oldOwnership: [DistributionLinkOwnership]

    init(agentPlatforms: Set<SkillPlatform>? = nil) async throws {
        workspace = try WriterWorkspace(distributionEnabled: true)
        writer = try await workspace.openWriter()
        _ = try await writer.migrateLegacy(homeURL: workspace.distributionHomeURL)
        let snapshot = try workspace.snapshot(content: "repair")
        skillID = SkillID()
        let payload = try workspace.payload(
            skillID: skillID,
            name: "Repair",
            snapshot: snapshot
        )
        slug = payload.skill.defaultDistributionSlug
        _ = try await writer.create(payload: payload, sourceSnapshot: snapshot)
        let desiredScope: DistributionDesiredScope
        let requiredAdapterCodes: Set<String>
        if let agentPlatforms {
            desiredScope = .agents(agentPlatforms, slug)
            requiredAdapterCodes = Set(agentPlatforms.map(\.storageKey))
        } else {
            desiredScope = .global(slug)
            requiredAdapterCodes = Set(
                DistributionTargetCatalog.current.globalReaders.map(\.storageKey)
            )
        }
        let plan = try await writer.distributionPlan(
            skillID: skillID,
            desiredScope: desiredScope,
            requiredAdapterCodes: requiredAdapterCodes
        )
        _ = try await writer.applyDistribution(skillID: skillID, plan: plan)
        let primaryScope = agentPlatforms?.sorted {
            $0.storageKey < $1.storageKey
        }.first.map(DistributionBindingScope.agent) ?? .global
        targetURL = try repairTargetURL(
            homeURL: workspace.distributionHomeURL,
            scope: primaryScope,
            slug: slug
        )
        oldBindings = try await writer.loadDistributionSelection(skillID: skillID).bindings
        oldOwnership = try ownership(workspace: workspace, skillID: skillID)
    }

    func distributionURL(for scope: DistributionBindingScope) throws -> URL {
        try repairTargetURL(
            homeURL: workspace.distributionHomeURL,
            scope: scope,
            slug: slug
        )
    }
}

func repairTargetURL(
    homeURL: URL,
    scope: DistributionBindingScope,
    slug: DefaultDistributionSlug
) throws -> URL {
    let entry = try #require(DistributionTargetCatalog.current.entry(
        for: scope,
        slug: slug
    ))
    return homeURL.appendingPathComponent(
        String(entry.canonicalLocator.dropFirst(2)),
        isDirectory: true
    )
}

func recoverRebuild() async throws {
    let fixture = try await RepairFixture()
    try FileManager.default.removeItem(at: fixture.targetURL)
    let service = SkillConsistencyRepairService(
        writer: fixture.writer,
        homeURL: fixture.workspace.distributionHomeURL
    )
    let preview = try await service.prepare(
        skillID: fixture.skillID,
        action: .rebuildMissingSymlink(scopeKeys: ["global"])
    )
    let result = try await service.confirm(preview)
    guard case .applied(let operationID) = result else {
        Issue.record("repair did not apply")
        return
    }
    try restoreOwnership(fixture)
    try rewindOperation(
        fixture,
        operationID: operationID,
        phase: .filesystemApplied,
        forwardCursor: 1
    )

    let executor = try recoveryExecutor(fixture)
    try executor.recoverAll()

    let record = try operation(fixture, operationID: operationID)
    #expect(record.phase == .completed)
    #expect(record.outcome == .applied)
    #expect(try ownership(fixture).first?.appliedOperationID == operationID)
}

func recoverDisable() async throws {
    let fixture = try await RepairFixture()
    try FileManager.default.removeItem(at: fixture.targetURL)
    let service = SkillConsistencyRepairService(
        writer: fixture.writer,
        homeURL: fixture.workspace.distributionHomeURL
    )
    let preview = try await service.prepare(
        skillID: fixture.skillID,
        action: .disableMissingBinding(scopeKeys: ["global"])
    )
    let result = try await service.confirm(preview)
    guard case .applied(let operationID) = result else {
        Issue.record("repair did not apply")
        return
    }
    try restoreBindingsAndOwnership(fixture)
    try rewindOperation(
        fixture,
        operationID: operationID,
        phase: .prepared,
        forwardCursor: 0
    )

    let executor = try recoveryExecutor(fixture)
    try executor.recoverAll()

    let record = try operation(fixture, operationID: operationID)
    #expect(record.phase == .completed)
    #expect(record.outcome == .rolledBack)
    #expect(try DistributionBindingStore(
        connection: SQLiteConnection(url: fixture.workspace.database)
    ).load(skillID: fixture.skillID).count == 1)
}

func recoverPartialDisable() async throws {
    let fixture = try await RepairFixture(agentPlatforms: [.codex, .claude])
    try FileManager.default.removeItem(at: fixture.distributionURL(for: .agent(.codex)))
    try FileManager.default.removeItem(at: fixture.distributionURL(for: .agent(.claude)))
    let service = SkillConsistencyRepairService(
        writer: fixture.writer,
        homeURL: fixture.workspace.distributionHomeURL
    )
    let preview = try await service.prepare(
        skillID: fixture.skillID,
        action: .disableMissingBinding(scopeKeys: ["agent:codex"])
    )
    let result = try await service.confirm(preview)
    guard case .applied(let operationID) = result else {
        Issue.record("partial disable did not apply")
        return
    }
    try restoreBindingsAndOwnership(fixture)
    try rewindOperation(
        fixture,
        operationID: operationID,
        phase: .prepared,
        forwardCursor: 0
    )

    try recoveryExecutor(fixture).recoverAll()

    let record = try operation(fixture, operationID: operationID)
    #expect(record.phase == .completed)
    #expect(record.outcome == .rolledBack)
    #expect(try DistributionBindingStore(
        connection: SQLiteConnection(url: fixture.workspace.database)
    ).load(skillID: fixture.skillID).count == 2)
    #expect(try ownership(fixture) == fixture.oldOwnership)
}

func binding(
    skillID: SkillID,
    scope: DistributionBindingScope,
    slug: DefaultDistributionSlug
) throws -> DistributionBinding {
    try DistributionBinding(
        skillID: skillID,
        scope: scope,
        distributionSlug: slug,
        createdAtMilliseconds: 1,
        updatedAtMilliseconds: 1
    )
}

func copyBinding(
    skillID: SkillID,
    slug: DefaultDistributionSlug
) throws -> DistributionBinding {
    var metadata = stat()
    metadata.st_mode = mode_t(S_IFDIR | 0o700)
    let identity = ManagedItemIdentity(metadata)
    return try DistributionBinding(
        skillID: skillID,
        scope: .agent(.codex),
        distributionSlug: slug,
        syncMode: .copy,
        copyBaseline: DistributionCopyBaseline(
            contentFingerprint: SkillContentFingerprint(
                currentDigest: Data(repeating: 1, count: 32)
            ),
            physicalTreeDigest: CopyPhysicalTreeDigest(
                digest: Data(repeating: 2, count: 32)
            ),
            rootIdentity: identity,
            entryIdentity: identity,
            appliedOperationID: SSOTOperationID(),
            verifiedAtMilliseconds: 1
        ),
        createdAtMilliseconds: 1,
        updatedAtMilliseconds: 1
    )
}

func destination(of url: URL) throws -> String? {
    var metadata = stat()
    guard Darwin.lstat(url.path, &metadata) == 0 else { return nil }
    guard metadata.st_mode & mode_t(S_IFMT) == mode_t(S_IFLNK) else { return nil }
    return try FileManager.default.destinationOfSymbolicLink(atPath: url.path)
}

func ownership(_ fixture: RepairFixture) throws -> [DistributionLinkOwnership] {
    try ownership(workspace: fixture.workspace, skillID: fixture.skillID)
}

func ownership(
    workspace: WriterWorkspace,
    skillID: SkillID
) throws -> [DistributionLinkOwnership] {
    try DistributionLinkOwnershipStore(
        connection: SQLiteConnection(url: workspace.database)
    ).load(skillID: skillID)
}

func configuration(_ fixture: RepairFixture) throws -> Bool {
    try DistributionConfigurationStore(
        connection: SQLiteConnection(url: fixture.workspace.database)
    ).load(skillID: fixture.skillID)
}

func deleteOwnership(_ fixture: RepairFixture) throws {
    let connection = try SQLiteConnection(url: fixture.workspace.database)
    let statement = try connection.prepare(
        "DELETE FROM distribution_link_ownership WHERE skill_id = ?"
    )
    try statement.bind(fixture.skillID.bytes, at: 1)
    _ = try statement.step()
}

func changeOwnershipTarget(_ fixture: RepairFixture) throws {
    let connection = try SQLiteConnection(url: fixture.workspace.database)
    let statement = try connection.prepare(
        """
        UPDATE distribution_link_ownership
        SET absolute_link_target = '/tmp/not-the-managed-skill'
        WHERE skill_id = ?
        """
    )
    try statement.bind(fixture.skillID.bytes, at: 1)
    _ = try statement.step()
}

func deleteConfiguration(_ fixture: RepairFixture) throws {
    let connection = try SQLiteConnection(url: fixture.workspace.database)
    let statement = try connection.prepare(
        "DELETE FROM distribution_configurations WHERE skill_id = ?"
    )
    try statement.bind(fixture.skillID.bytes, at: 1)
    _ = try statement.step()
}

func insertConfiguration(_ fixture: RepairFixture) throws {
    let connection = try SQLiteConnection(url: fixture.workspace.database)
    let statement = try connection.prepare(
        "INSERT INTO distribution_configurations(skill_id, configured_at_ms) VALUES (?, 100)"
    )
    try statement.bind(fixture.skillID.bytes, at: 1)
    _ = try statement.step()
}

func operationCount(_ fixture: RepairFixture) throws -> Int64 {
    try #require(try SQLiteConnection(
        url: fixture.workspace.database,
        accessMode: .readOnly
    ).querySingleInt("SELECT count(*) FROM distribution_operations"))
}

func duplicateFirstRepairTarget(
    _ fixture: RepairFixture,
    operationID: SSOTOperationID
) throws {
    let connection = try SQLiteConnection(url: fixture.workspace.database)
    let select = try connection.prepare(
        "SELECT preflight_payload FROM distribution_operations WHERE operation_id = ?"
    )
    try select.bind(operationID.bytes, at: 1)
    guard try select.step(),
          let preflightPayload = select.blob(at: 0),
          var object = try JSONSerialization.jsonObject(
              with: preflightPayload
          ) as? [String: Any],
          var targets = object["repairTargets"] as? [[String: Any]],
          let first = targets.first else {
        throw CocoaError(.fileReadCorruptFile)
    }
    targets.append(first)
    object["repairTargets"] = targets
    let payload = try JSONSerialization.data(
        withJSONObject: object,
        options: [.sortedKeys, .withoutEscapingSlashes]
    )
    let update = try connection.prepare(
        "UPDATE distribution_operations SET preflight_payload = ? WHERE operation_id = ?"
    )
    try update.bind(payload, at: 1)
    try update.bind(operationID.bytes, at: 2)
    _ = try update.step()
}

func restoreOwnership(_ fixture: RepairFixture) throws {
    let connection = try SQLiteConnection(url: fixture.workspace.database)
    let store = DistributionLinkOwnershipStore(connection: connection)
    _ = try store.replace(
        skillID: fixture.skillID,
        expectedOld: store.load(skillID: fixture.skillID),
        desired: fixture.oldOwnership,
        appliedOperationID: try #require(fixture.oldOwnership.first).appliedOperationID,
        nowMilliseconds: 100
    )
}

func restoreBindingsAndOwnership(_ fixture: RepairFixture) throws {
    let connection = try SQLiteConnection(url: fixture.workspace.database)
    let bindingStore = DistributionBindingStore(connection: connection)
    _ = try bindingStore.replace(
        skillID: fixture.skillID,
        expectedOld: bindingStore.load(skillID: fixture.skillID),
        desired: fixture.oldBindings.map(\.intent),
        nowMilliseconds: 100
    )
    let ownershipStore = DistributionLinkOwnershipStore(connection: connection)
    _ = try ownershipStore.replace(
        skillID: fixture.skillID,
        expectedOld: ownershipStore.load(skillID: fixture.skillID),
        desired: fixture.oldOwnership,
        appliedOperationID: try #require(fixture.oldOwnership.first).appliedOperationID,
        nowMilliseconds: 100
    )
}

func rewindOperation(
    _ fixture: RepairFixture,
    operationID: SSOTOperationID,
    phase: DistributionOperationPhase,
    forwardCursor: Int64
) throws {
    let connection = try SQLiteConnection(url: fixture.workspace.database)
    let statement = try connection.prepare(
        """
        UPDATE distribution_operations
        SET phase = ?, outcome = NULL, forward_cursor = ?,
            rollback_cursor = 0, cleanup_cursor = 0
        WHERE operation_id = ?
        """
    )
    try statement.bind(phase.rawValue, at: 1)
    try statement.bind(forwardCursor, at: 2)
    try statement.bind(operationID.bytes, at: 3)
    _ = try statement.step()
}

func recoveryExecutor(
    _ fixture: RepairFixture
) throws -> DistributionSymlinkExecutor {
    let connection = try SQLiteConnection(url: fixture.workspace.database)
    return try DistributionSymlinkExecutor(
        connection: connection,
        fileSystem: DistributionSymlinkFileSystem(
            homeURL: fixture.workspace.distributionHomeURL
        ),
        nowMilliseconds: { 1_000 }
    )
}

func operation(
    _ fixture: RepairFixture,
    operationID: SSOTOperationID
) throws -> DistributionOperationRecord {
    try DistributionOperationStore(
        connection: SQLiteConnection(url: fixture.workspace.database)
    ).load(operationID)
}
