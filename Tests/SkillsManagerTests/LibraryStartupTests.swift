import Foundation
import Testing

@testable import SkillsManager

@Suite("LibraryStartup")
struct LibraryStartupTests {
    @Test("fresh bootstrap is durable and ordinary restart uses SQLite-only state")
    func freshBootstrapAndRestart() async throws {
        let fixture = try LibraryRuntimeTestHome()
        defer { fixture.remove() }
        var first: LibraryStartupResult? = await LibraryStartupCoordinator(homeURL: fixture.home).start()
        #expect(first?.readiness == .ready)
        #expect(first?.phase == .running)
        #expect(first?.outcome == .firstRunInitialized)
        #expect(first?.diagnostics.isEmpty == true)
        #expect(FileManager.default.fileExists(
            atPath: fixture.home.appendingPathComponent(".SkillsManager/skills").path
        ))
        first = nil

        let second = await LibraryStartupCoordinator(homeURL: fixture.home).start()
        #expect(second.readiness == .ready)
        #expect(second.outcome == .opened)
        #expect(second.diagnostics.isEmpty)
    }

    @Test("each durable bootstrap checkpoint resumes without changing identity")
    func resumesBootstrapCheckpoints() async throws {
        enum InjectedCrash: Error { case stop }
        let checkpoints: [LibraryStartupCheckpoint] = [
            .markerDurable,
            .databasePrepared,
            .migrationCommitted,
            .ssotDurable,
            .databaseCompleted,
            .markerRemoved,
        ]
        for checkpoint in checkpoints {
            let fixture = try LibraryRuntimeTestHome()
            let interrupted = await LibraryStartupCoordinator(
                homeURL: fixture.home,
                hooks: LibraryStartupHooks { reached in
                    if reached == checkpoint { throw InjectedCrash.stop }
                }
            ).start()
            #expect(interrupted.readiness == .blocked)

            let resumed = await LibraryStartupCoordinator(homeURL: fixture.home).start()
            #expect(resumed.readiness == .ready)
            #expect(resumed.phase == .running)
            fixture.remove()
        }
    }

    @Test("two first-run instances produce one ready owner and one busy diagnostic")
    func serializesFirstRun() async throws {
        let fixture = try LibraryRuntimeTestHome()
        defer { fixture.remove() }
        async let first = LibraryStartupCoordinator(homeURL: fixture.home).start()
        async let second = LibraryStartupCoordinator(homeURL: fixture.home).start()
        let results = await [first, second]
        #expect(results.filter { $0.readiness == .ready }.count == 1)
        #expect(results.filter {
            $0.diagnostics.contains { $0.code == .databaseBusy }
        }.count == 1)
    }

    @MainActor
    @Test("legacy-only bootstrap migrates state without changing legacy bytes or metadata")
    func legacyBootstrapPreservesArchive() async throws {
        let fixture = try LibraryRuntimeTestHome()
        defer { fixture.remove() }
        let customRoot = fixture.root.appendingPathComponent("custom", isDirectory: true)
        try FileManager.default.createDirectory(at: customRoot, withIntermediateDirectories: false)
        let legacyPath = CustomSkillPath(url: customRoot, displayName: "Custom")
        let legacy = try fixture.writeLegacyCustomPaths([legacyPath])
        let legacyID = legacyPath.id

        let result = await LibraryStartupCoordinator(homeURL: fixture.home).start()
        #expect(result.readiness == .ready)
        let session = try #require(result.session)
        let paths = try await session.loadCustomPaths()
        #expect(paths.map(\.id) == [legacyID])
        #expect(try Data(contentsOf: legacy.0) == legacy.1)
        var after = stat()
        #expect(Darwin.lstat(legacy.0.path, &after) == 0)
        #expect(after.st_ino == legacy.2.st_ino)
        #expect(after.st_mode == legacy.2.st_mode)
    }

    @Test("ordinary startup does not create a missing database beside an existing SSOT")
    func missingDatabaseFailsClosed() async throws {
        let fixture = try LibraryRuntimeTestHome()
        defer { fixture.remove() }
        let management = fixture.home.appendingPathComponent(".SkillsManager", isDirectory: true)
        let skills = management.appendingPathComponent("skills", isDirectory: true)
        try FileManager.default.createDirectory(at: skills, withIntermediateDirectories: true)
        #expect(Darwin.chmod(management.path, 0o700) == 0)
        #expect(Darwin.chmod(skills.path, 0o700) == 0)

        let result = await LibraryStartupCoordinator(homeURL: fixture.home).start()
        #expect(result.readiness == .blocked)
        #expect(result.diagnostics.map(\.code) == [.databaseMissing])
        #expect(!FileManager.default.fileExists(
            atPath: management.appendingPathComponent("manager.sqlite").path
        ))
    }
}
