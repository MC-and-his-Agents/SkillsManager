import Foundation
import Testing

@testable import SkillsManager

@Suite("AppPersistenceCutover")
struct AppPersistenceCutoverTests {
    @MainActor
    @Test("custom path store stays blocked before runtime readiness")
    func blocksBeforeActivation() async throws {
        let fixture = try LibraryRuntimeTestHome()
        defer { fixture.remove() }
        let store = CustomPathStore()
        await #expect(throws: LibraryPersistenceError.self) {
            try await store.addPath(fixture.home)
        }
        #expect(store.customPaths.isEmpty)
        #expect(!FileManager.default.fileExists(
            atPath: fixture.home.appendingPathComponent(
                "Library/Application Support/SkillsManager/custom-paths.json"
            ).path
        ))
    }

    @MainActor
    @Test("runtime activation reads and mutates SQLite without rewriting legacy JSON")
    func usesSQLiteOnlyAfterLedgerCommit() async throws {
        let fixture = try LibraryRuntimeTestHome()
        defer { fixture.remove() }
        let firstURL = fixture.root.appendingPathComponent("first", isDirectory: true)
        let secondURL = fixture.root.appendingPathComponent("second", isDirectory: true)
        try FileManager.default.createDirectory(at: firstURL, withIntermediateDirectories: false)
        try FileManager.default.createDirectory(at: secondURL, withIntermediateDirectories: false)
        let legacyPath = CustomSkillPath(url: firstURL, displayName: "First")
        let legacy = try fixture.writeLegacyCustomPaths([legacyPath])
        let result = await LibraryStartupCoordinator(homeURL: fixture.home).start()
        let session = try #require(result.session)

        let paths = CustomPathStore()
        try await paths.activate(using: session)
        #expect(paths.customPaths.map(\.id) == [legacyPath.id])
        try await paths.addPath(secondURL)
        #expect(paths.customPaths.count == 2)
        #expect(try Data(contentsOf: legacy.0) == legacy.1)
        #expect(try await session.loadCustomPaths().count == 2)

        let skillStore = SkillStore(customPathStore: paths)
        skillStore.activatePersistence(session)
        try await skillStore.savePublishState(for: "demo", hash: "abc")
        #expect(try await skillStore.loadPublishState(for: "demo")?.lastPublishedHash == "abc")
        #expect(try Data(contentsOf: legacy.0) == legacy.1)
    }
}
