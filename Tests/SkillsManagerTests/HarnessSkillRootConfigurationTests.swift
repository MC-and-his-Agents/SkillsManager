import Darwin
import Foundation
import Testing

@testable import SkillsManager

@Suite("Harness Skill root configuration", .serialized)
struct HarnessSkillRootConfigurationTests {
    @Test("environment detection is a hint and does not persist or change the catalog")
    func environmentIsHintOnly() throws {
        let defaults = try isolatedDefaults()
        let store = HarnessSkillRootConfigurationStore(defaults: defaults)
        let home = try temporaryDirectory("home")
        let codexHome = try temporaryDirectory("external-codex")
        let root = codexHome.appendingPathComponent("skills", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)

        let resolution = store.resolution(
            for: .codex,
            homeURL: home,
            environment: ["CODEX_HOME": codexHome.path]
        )
        #expect(resolution.status == .environmentHint)
        #expect(resolution.configuration == nil)
        #expect(store.configurations().isEmpty)
        #expect(
            DistributionTargetCatalog.current(
                homeURL: home,
                configurationStore: store
            ).target(for: .agent(.codex))?.isConfigured == false
        )
    }

    @Test("confirmation persists absolute URL and resolves a root symlink")
    func confirmationAndRestart() throws {
        let defaults = try isolatedDefaults()
        let store = HarnessSkillRootConfigurationStore(defaults: defaults)
        let real = try temporaryDirectory("real-codex")
        let parent = try temporaryDirectory("link-parent")
        let link = parent.appendingPathComponent("codex", isDirectory: true)
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: real)

        let saved = try store.confirm(platform: .codex, registeredURL: link)
        #expect(saved.registeredURL.path == link.standardizedFileURL.path)
        #expect(saved.canonicalURL.path == real.standardizedFileURL.path)

        let restarted = HarnessSkillRootConfigurationStore(defaults: defaults)
        let resolution = restarted.resolution(for: .codex)
        #expect(resolution.status == .configured)
        #expect(resolution.isConfigured)
        #expect(resolution.canonicalURL == real.standardizedFileURL)
        let target = DistributionTargetCatalog.current(
            homeURL: try temporaryDirectory("home"),
            configurationStore: restarted
        ).target(for: .agent(.codex))
        #expect(target?.rootLocator == link.standardizedFileURL.path)
        #expect(target?.resolvedRootURL == real.standardizedFileURL)
        let planHome = try temporaryDirectory("home-for-plan")
        let planCatalog = DistributionTargetCatalog.current(
            homeURL: planHome,
            configurationStore: restarted
        )
        let roots = SkillDiscoveryRootPlan.make(
            homeURL: planHome,
            customPaths: [],
            catalog: planCatalog
        )
        #expect(roots.contains {
            $0.scope.adapterCode == SkillPlatform.codex.storageKey
                && $0.url == real.standardizedFileURL
        })
        #expect(!roots.contains {
            $0.scope.adapterCode == SkillPlatform.codex.storageKey
                && $0.url.path.hasSuffix("/.codex/skills")
        })
    }

    @Test("changed or unavailable configured roots are blocked without filesystem writes")
    func changedRootIsBlocked() throws {
        let defaults = try isolatedDefaults()
        let store = HarnessSkillRootConfigurationStore(defaults: defaults)
        let root = try temporaryDirectory("codex")
        _ = try store.confirm(platform: .codex, registeredURL: root)
        try FileManager.default.removeItem(at: root)

        let resolution = store.resolution(for: .codex)
        #expect(resolution.status == .unavailable)
        #expect(resolution.isConfigured)
        let home = try temporaryDirectory("home")
        let catalog = DistributionTargetCatalog.current(
            homeURL: home,
            configurationStore: store
        )
        let fileSystem = try DistributionSymlinkFileSystem(homeURL: home, catalog: catalog)
        let entry = try #require(catalog.entry(
            for: .agent(.codex),
            slug: DefaultDistributionSlug(validating: "demo")
        ))
        #expect(throws: DistributionSymlinkFileSystemError.self) {
            _ = try fileSystem.absoluteTargetURL(for: entry)
        }
        let roots = SkillDiscoveryRootPlan.make(
            homeURL: home,
            customPaths: [],
            catalog: catalog
        )
        #expect(roots.first {
            $0.scope.adapterCode == SkillPlatform.codex.storageKey
        }?.diagnostic == .rootReadFailed)
        #expect(!FileManager.default.fileExists(atPath: root.path))
    }

    @Test("repeated confirmation replaces one platform record and rejects cross-platform conflicts")
    func idempotentAndConflictSafe() throws {
        let defaults = try isolatedDefaults()
        let store = HarnessSkillRootConfigurationStore(defaults: defaults)
        let first = try temporaryDirectory("first")
        let second = try temporaryDirectory("second")
        _ = try store.confirm(platform: .codex, registeredURL: first)
        _ = try store.confirm(platform: .codex, registeredURL: second)
        #expect(store.configurations().count == 1)
        #expect(store.configuration(for: .codex)?.registeredURL == second.standardizedFileURL)
        #expect(throws: HarnessSkillRootConfigurationError.conflictingRoot) {
            _ = try store.confirm(platform: .claude, registeredURL: second)
        }

        let real = try temporaryDirectory("identity-conflict")
        let aliases = try temporaryDirectory("identity-aliases")
        let firstAlias = aliases.appendingPathComponent("first", isDirectory: true)
        let secondAlias = aliases.appendingPathComponent("second", isDirectory: true)
        try FileManager.default.createSymbolicLink(at: firstAlias, withDestinationURL: real)
        try FileManager.default.createSymbolicLink(at: secondAlias, withDestinationURL: real)
        let identityStore = HarnessSkillRootConfigurationStore(defaults: try isolatedDefaults())
        _ = try identityStore.confirm(platform: .codex, registeredURL: firstAlias)
        #expect(throws: HarnessSkillRootConfigurationError.conflictingRoot) {
            _ = try identityStore.confirm(platform: .claude, registeredURL: secondAlias)
        }
    }

    @Test("same lexical root retains Codex default and confirmed Claude scopes")
    func sameRootRetainsScopeAliases() throws {
        let defaults = try isolatedDefaults()
        let store = HarnessSkillRootConfigurationStore(defaults: defaults)
        let home = try temporaryDirectory("home")
        let codexRoot = home.appendingPathComponent(".codex/skills", isDirectory: true)
        try FileManager.default.createDirectory(at: codexRoot, withIntermediateDirectories: true)
        _ = try store.confirm(platform: .claude, registeredURL: codexRoot)

        let catalog = DistributionTargetCatalog.current(
            homeURL: home,
            configurationStore: store
        )
        let roots = SkillDiscoveryRootPlan.make(
            homeURL: home,
            customPaths: [],
            catalog: catalog
        )
        let aliases = roots.filter {
            $0.url.standardizedFileURL == codexRoot.standardizedFileURL
                && $0.scope.kind == .agent
        }
        #expect(aliases.contains { $0.scope.adapterCode == SkillPlatform.codex.storageKey })
        #expect(aliases.contains { $0.scope.adapterCode == SkillPlatform.claude.storageKey })
    }

    @Test("distribution filesystem uses the configured external root")
    func externalDistributionLifecycle() throws {
        let defaults = try isolatedDefaults()
        let store = HarnessSkillRootConfigurationStore(defaults: defaults)
        let home = try temporaryDirectory("home")
        let external = try temporaryDirectory("codex")
        _ = try store.confirm(platform: .codex, registeredURL: external)
        let catalog = DistributionTargetCatalog.current(
            homeURL: home,
            configurationStore: store
        )
        let fileSystem = try DistributionSymlinkFileSystem(homeURL: home, catalog: catalog)
        let scope: DistributionBindingScope = .agent(.codex)
        let slug = try DefaultDistributionSlug(validating: "demo")
        let entry = try #require(catalog.entry(for: scope, slug: slug))
        let rootIdentity = try fileSystem.ensureRoot(for: scope)
        let managed = external.appendingPathComponent("managed", isDirectory: true)
        try FileManager.default.createDirectory(at: managed, withIntermediateDirectories: false)
        let target = managed.path
        let evidence = try fileSystem.create(
            entry,
            absoluteTarget: target,
            expectedRootIdentity: rootIdentity
        )
        #expect(FileManager.default.fileExists(atPath: external.appendingPathComponent("demo").path))
        #expect(!FileManager.default.fileExists(
            atPath: home.appendingPathComponent(".codex/skills/demo").path
        ))
        try fileSystem.removeCreated(entry, expected: evidence)
    }

    private func isolatedDefaults() throws -> UserDefaults {
        let suite = "SkillsManagerHarnessRootsTests.\(UUID().uuidString)"
        guard let defaults = UserDefaults(suiteName: suite) else {
            throw CocoaError(.fileWriteUnknown)
        }
        defaults.removePersistentDomain(forName: suite)
        return defaults
    }

    private func temporaryDirectory(_ name: String) throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("harness-root-\(name)-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: false)
        return url
    }
}
