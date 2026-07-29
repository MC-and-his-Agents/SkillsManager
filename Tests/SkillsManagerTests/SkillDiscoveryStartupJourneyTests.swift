import Darwin
import Foundation
import Testing

@testable import SkillsManager

@Suite("Discovery startup journey", .serialized)
@MainActor
struct SkillDiscoveryStartupJourneyTests {
    @Test("historical database starts, scans Agent roots and reaches import preview")
    func historicalDatabaseJourney() async throws {
        let testHome = try LibraryRuntimeTestHome()
        defer { testHome.remove() }
        let management = testHome.home.appendingPathComponent(
            ".SkillsManager",
            isDirectory: true
        )
        let ssot = management.appendingPathComponent("skills", isDirectory: true)
        try makeOwnerOnlyDirectory(management)
        try createEarlyV9Database(at: management.appendingPathComponent("manager.sqlite"))
        try makeOwnerOnlyDirectory(ssot)

        let agentRoot = testHome.home
            .appendingPathComponent(".agents", isDirectory: true)
            .appendingPathComponent("skills", isDirectory: true)
        let discoveredSkill = agentRoot.appendingPathComponent("demo", isDirectory: true)
        try makeOwnerOnlyDirectory(discoveredSkill)
        let manifest = discoveredSkill.appendingPathComponent("SKILL.md")
        try Data("# Demo\n".utf8).write(to: manifest)
        #expect(Darwin.chmod(manifest.path, 0o600) == 0)

        let startup = await LibraryStartupCoordinator(homeURL: testHome.home).start()
        #expect(startup.readiness == .ready)
        let writer = try #require(startup.session)
        let roots = SkillDiscoveryRootPlan.make(homeURL: testHome.home, customPaths: [])
        let model = SkillDiscoveryViewModel()
        let needsRefresh = model.activate(
            dependencies: .live(writer: writer),
            roots: { roots }
        )
        #expect(needsRefresh)

        await model.refresh()

        #expect(model.loadState == .loaded)
        #expect(model.summary.plannedRootCount == roots.count)
        let item = try #require(model.items.first {
            $0.observation.relativeLocator == "demo"
        })
        #expect(item.observation.status == .unmanaged)
        #expect(item.allowedActions == [.importNew])

        try await model.prepareImport(itemID: item.id, action: .importNew)

        #expect(model.pendingImport?.itemID == item.id)
        let reader = try SQLiteConnection(
            url: management.appendingPathComponent("manager.sqlite"),
            accessMode: .readOnly
        )
        #expect(try reader.querySingleInt("SELECT count(*) FROM skills") == 0)
        #expect(try FileManager.default.contentsOfDirectory(atPath: ssot.path).isEmpty)
    }
}

private func makeOwnerOnlyDirectory(_ url: URL) throws {
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    guard Darwin.chmod(url.path, 0o700) == 0 else {
        throw CocoaError(.fileWriteNoPermission)
    }
}
