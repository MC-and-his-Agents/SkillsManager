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
    @Test("blocked skill store does not write custom paths")
    func blocksCustomPathWritesAfterRuntimeBlock() async throws {
        let fixture = try LibraryRuntimeTestHome()
        defer { fixture.remove() }
        let firstURL = fixture.root.appendingPathComponent("first", isDirectory: true)
        let secondURL = fixture.root.appendingPathComponent("second", isDirectory: true)
        try FileManager.default.createDirectory(at: firstURL, withIntermediateDirectories: false)
        try FileManager.default.createDirectory(at: secondURL, withIntermediateDirectories: false)

        let result = await LibraryStartupCoordinator(homeURL: fixture.home).start()
        let session = try #require(result.session)
        let paths = CustomPathStore()
        try await paths.activate(using: session)
        let store = SkillStore(customPathStore: paths)
        store.activatePersistence(session)
        try await paths.addPath(firstURL)
        let before = try await session.loadCustomPaths()

        store.blockRuntime(message: "A concrete library diagnostic.")

        await #expect(throws: LibraryPersistenceError.self) {
            try await store.addCustomPath(secondURL)
        }
        let existing = try #require(paths.customPaths.first)
        await #expect(throws: LibraryPersistenceError.self) {
            try await store.removeCustomPath(existing)
        }
        #expect(try await session.loadCustomPaths() == before)
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

        #expect(try Data(contentsOf: legacy.0) == legacy.1)
    }

    @MainActor
    @Test("persists direct collection semantics and rejects equivalent paths")
    func persistsCollectionMode() async throws {
        let fixture = try LibraryRuntimeTestHome()
        defer { fixture.remove() }
        let collection = fixture.root.appendingPathComponent(".codex/skills", isDirectory: true)
        try FileManager.default.createDirectory(at: collection, withIntermediateDirectories: true)
        let result = await LibraryStartupCoordinator(homeURL: fixture.home).start()
        let session = try #require(result.session)
        let paths = CustomPathStore()
        try await paths.activate(using: session)

        try await paths.addPath(collection, mode: .collection(adapter: .codex))
        #expect(paths.customPaths.first?.mode == .collection(adapter: .codex))
        await #expect(throws: CustomPathError.duplicatePath) {
            try await paths.addPath(
                URL(fileURLWithPath: collection.path + "/", isDirectory: true),
                mode: .project
            )
        }
        #expect(try await session.loadCustomPaths().first?.mode == .collection(adapter: .codex))

        let reloaded = CustomPathStore()
        try await reloaded.activate(using: session)
        #expect(reloaded.customPaths.first?.mode == .collection(adapter: .codex))
    }

    @MainActor
    @Test("repeated window startup shares one ready runtime and one persistence cutover")
    func coalescesRepeatedStartup() async throws {
        let fixture = try LibraryRuntimeTestHome()
        defer { fixture.remove() }
        let invocations = StartupInvocationCounter()
        let coordinator = LibraryStartupCoordinator(homeURL: fixture.home)
        let paths = CustomPathStore()
        let skills = SkillStore(customPathStore: paths)
        let state = LibraryRuntimeState()
        let bootstrap = AppLibraryRuntimeBootstrap()
        let startup: @Sendable () async -> LibraryStartupResult = {
            await invocations.record()
            return await coordinator.start()
        }

        await bootstrap.start(
            using: startup,
            runtimeState: state,
            customPathStore: paths,
            skillStore: skills
        )
        await bootstrap.start(
            using: startup,
            runtimeState: state,
            customPathStore: paths,
            skillStore: skills
        )

        #expect(await invocations.count == 1)
        #expect(state.readiness == .ready)
        #expect(state.phase == .running)
        #expect(skills.persistence != nil)
    }
}

private actor StartupInvocationCounter {
    private(set) var count = 0

    func record() {
        count += 1
    }
}
