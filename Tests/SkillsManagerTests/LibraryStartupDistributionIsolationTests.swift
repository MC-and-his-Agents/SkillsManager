import Darwin
import Foundation
import Testing

@testable import SkillsManager

@Suite("LibraryStartup distribution isolation")
struct LibraryStartupDistributionIsolationTests {
    private struct HomeRecord {
        let root: URL
        let url: URL
        let identity: ManagedItemIdentity
    }

    private struct SeededSkill {
        let skillID: SkillID
        let slug: DefaultDistributionSlug
        let configuration: DistributionDesiredConfiguration
        let capturedTargets: [URL]
    }

    @Test("fresh bootstrap captures and applies distribution targets only under the injected home")
    func freshBootstrapStaysInsideInjectedHome() async throws {
        let home = try makeOwnerOnlyHome()
        defer { try? FileManager.default.removeItem(at: home.root) }

        let result = await LibraryStartupCoordinator(homeURL: home.url).start()
        #expect(result.readiness == .ready)
        #expect(result.outcome == .firstRunInitialized)
        let writer = try #require(result.session)

        let seeded = try await seedAndApply(home: home.url, writer: writer)
        #expect(!seeded.capturedTargets.isEmpty)

        let converged = try await writer.distributionPlan(
            skillID: seeded.skillID,
            desiredConfiguration: seeded.configuration,
            requiredAdapterCodes: seeded.configuration.scope.requiredAdapterCodes
        )
        #expect(converged.status == .noOp)
        for url in seeded.capturedTargets {
            try assertArtifactInsideHome(home: home.url, url: url)
        }
    }

    @Test("reopen/recovery fixes the same explicit home and keeps all targets contained")
    func reopenRecoveryStaysInsideInjectedHome() async throws {
        let home = try makeOwnerOnlyHome()
        defer { try? FileManager.default.removeItem(at: home.root) }

        let seeded: SeededSkill
        do {
            var first: LibraryStartupResult? = await LibraryStartupCoordinator(
                homeURL: home.url
            ).start()
            #expect(first?.readiness == .ready)
            let writer = try #require(first?.session)
            seeded = try await seedAndApply(home: home.url, writer: writer)
            let bindings = try await writer.loadDistributionSelection(
                skillID: seeded.skillID
            ).bindings
            #expect(bindings.map(\.scope) == [.global])
            #expect(bindings.map(\.distributionSlug) == [seeded.slug])
            first = nil
        }

        let reopened = await LibraryStartupCoordinator(homeURL: home.url).start()
        #expect(reopened.readiness == .ready)
        #expect(reopened.outcome == .opened)
        let recovered = try #require(reopened.session)

        let recoveryPlan = try await recovered.distributionPlan(
            skillID: seeded.skillID,
            desiredConfiguration: seeded.configuration,
            requiredAdapterCodes: seeded.configuration.scope.requiredAdapterCodes
        )
        #expect(recoveryPlan.status == .noOp)
        let recaptured = try await recovered.distributionTargetURLs(for: recoveryPlan)
        try assertContained(home: home.url, urls: recaptured)

        let catalog = DistributionTargetCatalog.current
        let entry = try #require(catalog.entry(for: .global, slug: seeded.slug))
        #expect(entry.canonicalLocator.hasPrefix("~/.agents/skills/"))
        for url in seeded.capturedTargets {
            try assertArtifactInsideHome(home: home.url, url: url)
        }
        try assertHomeIdentityUnchanged(home)
    }

    private func seedAndApply(
        home: URL,
        writer: JournaledSSOTWriter
    ) async throws -> SeededSkill {
        let source = home.appendingPathComponent("fixture-source/seed", isDirectory: true)
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
        guard Darwin.chmod(source.path, 0o700) == 0 else {
            throw CocoaError(.fileWriteNoPermission)
        }
        try Data("# Demo\n".utf8).write(to: source.appendingPathComponent("SKILL.md"))
        let snapshot = try SkillContentSnapshot.capture(at: source)
        let skill = try makeManagedSkill(snapshot: snapshot)
        let payload = try SSOTSkillWritePayload(skill: skill)
        _ = try await writer.create(payload: payload, sourceSnapshot: snapshot)

        let configuration = DistributionDesiredConfiguration(
            scope: .global(skill.defaultDistributionSlug),
            syncMode: .symlink
        )
        let plan = try await writer.distributionPlan(
            skillID: skill.skillID,
            desiredConfiguration: configuration,
            requiredAdapterCodes: configuration.scope.requiredAdapterCodes
        )
        #expect(plan.status == .executable)
        let captured = try await writer.distributionTargetURLs(for: plan)
        try assertContained(home: home, urls: captured)
        _ = try await writer.applyDistribution(skillID: skill.skillID, plan: plan)
        return SeededSkill(
            skillID: skill.skillID,
            slug: skill.defaultDistributionSlug,
            configuration: configuration,
            capturedTargets: captured
        )
    }

    private func makeOwnerOnlyHome() throws -> HomeRecord {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("skillsmanager-isolation-\(UUID().uuidString)", isDirectory: true)
        let url = root.appendingPathComponent("home", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        guard Darwin.chmod(root.path, 0o700) == 0,
              Darwin.chmod(url.path, 0o700) == 0 else {
            throw CocoaError(.fileWriteNoPermission)
        }
        return HomeRecord(root: root, url: url, identity: try lstatIdentity(url))
    }

    private func assertContained(home: URL, urls: [URL]) throws {
        let prefix = home.standardizedFileURL.path + "/"
        for url in urls {
            let path = url.standardizedFileURL.path
            #expect(path.hasPrefix(prefix))
            #expect(path != home.standardizedFileURL.path)
        }
    }

    private func assertArtifactInsideHome(home: URL, url: URL) throws {
        let prefix = home.standardizedFileURL.path + "/"
        let path = url.standardizedFileURL.path
        #expect(path.hasPrefix(prefix))
        var value = stat()
        guard Darwin.lstat(path, &value) == 0 else {
            throw CocoaError(.fileReadNoSuchFile)
        }
        if value.st_mode & mode_t(S_IFMT) == mode_t(S_IFLNK) {
            var target = [UInt8](repeating: 0, count: Int(PATH_MAX) + 1)
            let count = Darwin.readlink(path, &target, target.count - 1)
            #expect(count > 0)
            let resolved = String(decoding: target.prefix(count), as: UTF8.self)
            #expect(resolved.hasPrefix(prefix))
        }
    }

    private func assertHomeIdentityUnchanged(_ home: HomeRecord) throws {
        let after = try lstatIdentity(home.url)
        #expect(after == home.identity)
    }

    private func lstatIdentity(_ url: URL) throws -> ManagedItemIdentity {
        var value = stat()
        guard Darwin.lstat(url.path, &value) == 0 else {
            throw CocoaError(.fileReadNoSuchFile)
        }
        #expect(value.st_uid == Darwin.geteuid())
        #expect(value.st_mode & 0o7777 == 0o700)
        return ManagedItemIdentity(value)
    }
}
