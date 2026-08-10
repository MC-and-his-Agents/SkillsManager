import Foundation
import Testing
@testable import SkillsManager

@Suite("Skill update badge store")
@MainActor
struct SkillUpdateBadgeStoreTests {
    private final class CallCounter: @unchecked Sendable {
        var value = 0
    }

    private func client(
        latestVersion: @escaping @Sendable (String) async throws -> String?
    ) -> RemoteSkillClient {
        RemoteSkillClient(
            fetchLatest: { _, _ in
                RemoteSkillPage(items: [], nextCursor: nil)
            },
            search: { _, _ in [] },
            download: { _, _ in throw RemoteSkillClientError.providerUnavailable },
            fetchDetail: { _ in nil },
            fetchLatestVersion: latestVersion
        )
    }

    private func skill(
        id: String = "skill-id",
        slug: String? = "clawhub-slug",
        installed: String? = "1.0.0",
        status: ManagedSkillStatus = .managed
    ) throws -> Skill {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("badge-test-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let folder = root.appendingPathComponent("skill-id", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: false)
        return Skill(
            id: id,
            managedSkillID: SkillID(),
            name: "skill",
            displayName: "Skill",
            description: "",
            managedStatus: status,
            identitySummary: "",
            listOrigin: SkillListOriginProjection(hasRepositorySource: false, providers: ["clawdhub"]),
            clawdhubSlug: slug,
            clawdhubVersion: installed,
            enabledPlatforms: [],
            managedRoot: try ManagedRootReference.capture(at: root),
            folderURL: folder,
            skillMarkdownURL: folder.appendingPathComponent("SKILL.md"),
            references: [],
            stats: SkillStats(references: 0, assets: 0, scripts: 0, templates: 0)
        )
    }

    @Test("ClawHub skill with newer remote version gets an update badge")
    func updateAvailableBadge() async throws {
        let store = SkillUpdateBadgeStore(
            remote: client(latestVersion: { _ in "1.0.1" })
        )
        await store.checkIfNeeded(for: try skill())
        #expect(
            store.badge(for: try skill()) == .updateAvailable(version: "1.0.1")
        )
    }

    @Test("equal remote version is up to date and cached")
    func upToDateBadge() async throws {
        let store = SkillUpdateBadgeStore(
            remote: client(latestVersion: { _ in "1.0.0" })
        )
        await store.checkIfNeeded(for: try skill())
        #expect(store.badge(for: try skill()) == .upToDate)
    }

    @Test("non-ClawHub skill resolves without any network request")
    func nonClawHubNoNetwork() async throws {
        let calls = CallCounter()
        let store = SkillUpdateBadgeStore(
            remote: client(latestVersion: { _ in
                calls.value += 1
                return "9.9.9"
            })
        )
        await store.checkIfNeeded(
            for: try skill(slug: nil, installed: nil)
        )
        #expect(store.badge(for: try skill(slug: nil, installed: nil)) == .upToDate)
        #expect(calls.value == 0)
    }

    @Test("needsRepair resolves to needsAttention without any network request")
    func needsRepairBadge() async throws {
        let calls = CallCounter()
        let store = SkillUpdateBadgeStore(
            remote: client(latestVersion: { _ in
                calls.value += 1
                return "9.9.9"
            })
        )
        let broken = try skill(status: .needsRepair)
        await store.checkIfNeeded(for: broken)
        #expect(store.badge(for: broken) == .needsAttention)
        #expect(calls.value == 0)
    }

    @Test("remote failure is silent and does not cache a result")
    func failureSilentAndRetryable() async throws {
        let calls = CallCounter()
        let store = SkillUpdateBadgeStore(
            remote: client(latestVersion: { _ in
                calls.value += 1
                if calls.value == 1 {
                    throw RemoteSkillClientError.providerUnavailable
                }
                return "1.0.2"
            })
        )
        await store.checkIfNeeded(for: try skill())
        #expect(store.badge(for: try skill()) == nil)
        await store.checkIfNeeded(for: try skill())
        #expect(calls.value == 2)
        #expect(store.badge(for: try skill()) == .updateAvailable(version: "1.0.2"))
    }

    @Test("second check after resolution does not repeat the request")
    func cachedResolutionNoRepeat() async throws {
        let calls = CallCounter()
        let store = SkillUpdateBadgeStore(
            remote: client(latestVersion: { _ in
                calls.value += 1
                return "1.0.1"
            })
        )
        await store.checkIfNeeded(for: try skill())
        await store.checkIfNeeded(for: try skill())
        #expect(calls.value == 1)
        #expect(store.badge(for: try skill()) == .updateAvailable(version: "1.0.1"))
    }

    @Test("invalidateAll clears state and advances the refresh generation")
    func invalidateAllClearsAndAdvances() async throws {
        let store = SkillUpdateBadgeStore(
            remote: client(latestVersion: { _ in "1.0.1" })
        )
        await store.checkIfNeeded(for: try skill())
        #expect(store.badge(for: try skill()) != nil)
        store.invalidateAll()
        #expect(store.badge(for: try skill()) == nil)
        #expect(store.refreshGeneration == 1)
    }

    @Test("refresh ignores a stale request and accepts the current request")
    func staleRequestCannotOverwriteRefresh() async throws {
        let gate = BadgeVersionRequestGate()
        let store = SkillUpdateBadgeStore(
            remote: client(latestVersion: { _ in await gate.fetch() })
        )
        let target = try skill()

        let first = Task { @MainActor in
            await store.checkIfNeeded(for: target)
        }
        await gate.waitUntilStarted(count: 1)

        store.invalidateAll()

        let second = Task { @MainActor in
            await store.checkIfNeeded(for: target)
        }
        await gate.waitUntilStarted(count: 2)

        await gate.releaseNext("9.9.9")
        await first.value
        #expect(store.badge(for: target) == nil)

        await gate.releaseNext("1.0.1")
        await second.value
        #expect(store.badge(for: target) == .updateAvailable(version: "1.0.1"))
        #expect(await gate.callCount == 2)
    }

    @Test("backfill records a checked latest version without a request")
    func backfillAvoidsNetwork() async throws {
        let calls = CallCounter()
        let store = SkillUpdateBadgeStore(
            remote: client(latestVersion: { _ in
                calls.value += 1
                return "9.9.9"
            })
        )
        let target = try skill()
        store.backfill(
            target,
            latestVersion: "1.2.3",
            generation: store.refreshGeneration
        )
        #expect(
            store.badge(for: target) == .updateAvailable(version: "1.2.3")
        )
        #expect(calls.value == 0)
    }

    @Test("backfill rejects an old generation and supersedes an older row request")
    func backfillIsGenerationGuarded() async throws {
        let gate = BadgeVersionRequestGate()
        let store = SkillUpdateBadgeStore(
            remote: client(latestVersion: { _ in await gate.fetch() })
        )
        let target = try skill()
        let generation = store.refreshGeneration
        let rowRequest = Task { @MainActor in
            await store.checkIfNeeded(for: target)
        }
        await gate.waitUntilStarted(count: 1)

        store.backfill(target, latestVersion: "1.2.3", generation: generation)
        await gate.releaseNext("9.9.9")
        await rowRequest.value
        #expect(store.badge(for: target) == .updateAvailable(version: "1.2.3"))

        store.invalidateAll()
        store.backfill(target, latestVersion: "1.2.4", generation: generation)
        #expect(store.badge(for: target) == nil)
    }

    @Test("version comparison only accepts three-part numeric versions")
    func versionComparisonShape() throws {
        #expect(SkillVersionComparison.isNewer("1.0.1", than: "1.0.0"))
        #expect(!SkillVersionComparison.isNewer("1.0.0", than: "1.0.0"))
        #expect(!SkillVersionComparison.isNewer("1.0", than: "1.0.0"))
        #expect(!SkillVersionComparison.isNewer("v1.0.1", than: "1.0.0"))
        #expect(SkillVersionComparison.isNewer("1.0.0", than: "0.9.9"))
    }
}

private actor BadgeVersionRequestGate {
    private var continuations: [CheckedContinuation<String?, Never>] = []
    private(set) var callCount = 0

    func fetch() async -> String? {
        callCount += 1
        return await withCheckedContinuation { continuation in
            continuations.append(continuation)
        }
    }

    func waitUntilStarted(count: Int) async {
        while callCount < count {
            await Task.yield()
        }
    }

    func releaseNext(_ value: String?) {
        let continuation = continuations.removeFirst()
        continuation.resume(returning: value)
    }
}
