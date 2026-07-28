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

    init() async throws {
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
        let plan = try await writer.distributionPlan(
            skillID: skillID,
            desiredScope: .global(slug),
            requiredAdapterCodes: Set(
                DistributionTargetCatalog.current.globalReaders.map(\.storageKey)
            )
        )
        _ = try await writer.applyDistribution(skillID: skillID, plan: plan)
        targetURL = workspace.distributionHomeURL
            .appendingPathComponent(".agents/skills", isDirectory: true)
            .appendingPathComponent(slug.value, isDirectory: true)
        oldBindings = try await writer.loadDistributionSelection(skillID: skillID).bindings
        oldOwnership = try ownership(workspace: workspace, skillID: skillID)
    }
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
