import Foundation
import Testing
import ZIPFoundation

@testable import SkillsManager

@Suite("Skill store remote identity")
struct SkillStoreRemoteIdentityTests {
    @MainActor
    @Test("remote row platform lookup matches case and NFC equivalent slugs")
    func installedPlatformsUseNormalizedIdentity() async throws {
        try await withTemporaryDirectory { root in
            let store = SkillStore()
            store.skills = [
                try makeSkill(named: "Remote-Slug", platform: .codex, in: root),
                try makeSkill(named: "cafe\u{301}-skill", platform: .claude, in: root),
            ]

            #expect(store.isInstalled(slug: "remote-slug"))
            #expect(store.isInstalled(slug: "CAFÉ-SKILL", in: .claude))
            #expect(store.installedPlatforms(for: "remote-slug") == [.codex])
            #expect(store.installedPlatforms(for: "caf\u{e9}-skill") == [.claude])
            let index = store.installedSkillPlatformIndex
            #expect(index.platforms(forSlug: "REMOTE-SLUG") == [.codex])
            #expect(index.platforms(forSlug: "CAFÉ-SKILL") == [.claude])
        }
    }

    @MainActor
    @Test("local groups combine case and NFC equivalent names across platforms")
    func localGroupsUseNormalizedIdentity() async throws {
        try await withTemporaryDirectory { root in
            let store = SkillStore()
            store.skills = [
                try makeSkill(named: "Remote-Slug", platform: .codex, in: root),
                try makeSkill(named: "remote-slug", platform: .claude, in: root),
                try makeSkill(named: "cafe\u{301}-skill", platform: .opencode, in: root),
                try makeSkill(named: "CAF\u{c9}-SKILL", platform: .copilot, in: root),
            ]

            let groups = store.groupedPlatformSkills(from: store.skills)
            #expect(groups.count == 2)
            #expect(groups.contains { $0.installedPlatforms == [.codex, .claude] })
            #expect(groups.contains { $0.installedPlatforms == [.opencode, .copilot] })
        }
    }

    @MainActor
    @Test("selection prefers the highest-priority platform for an equivalent name")
    func selectionUsesNormalizedIdentity() async throws {
        try await withTemporaryDirectory { root in
            let store = SkillStore()
            let codex = try makeSkill(named: "CAF\u{c9}-SKILL", platform: .codex, in: root)
            let claude = try makeSkill(named: "cafe\u{301}-skill", platform: .claude, in: root)
            store.skills = [claude, codex]
            store.selectedSkillID = claude.id

            store.normalizeSelectionToPreferredPlatform()

            #expect(store.selectedSkillID == codex.id)
        }
    }

    @MainActor
    @Test("remote update finds an NFC equivalent installed directory")
    func updateUsesNormalizedIdentity() async throws {
        try await withTemporaryDirectory { root in
            let existingName = "cafe\u{301}-skill"
            let remoteSlug = "caf\u{e9}-skill"
            let existing = try makeSkill(named: existingName, platform: .codex, in: root)
            let archiveURL = root.appendingPathComponent("remote.zip")
            try writeArchive(at: archiveURL, markdown: "# Updated")

            let store = SkillStore()
            store.skills = [existing]
            var downloadCount = 0
            let client = RemoteSkillClient(
                fetchLatest: { _ in [] },
                search: { _, _ in [] },
                download: { _, _ in
                    downloadCount += 1
                    return archiveURL
                },
                fetchDetail: { _ in nil },
                fetchLatestVersion: { _ in nil }
            )

            _ = try await store.updateInstalledSkill(
                slug: remoteSlug,
                version: "2.0.0",
                client: client
            )

            #expect(downloadCount == 1)
            #expect(try String(
                contentsOf: existing.skillMarkdownURL,
                encoding: .utf8
            ) == "# Updated")
        }
    }

    @MainActor
    @Test("remote update touches a physical root only once through path aliases")
    func updateDeduplicatesRootAliases() async throws {
        try await withTemporaryDirectory { root in
            let slug = "shared-skill"
            let aliases = try makeAliasedSkills(named: slug, in: root)
            let archiveURL = root.appendingPathComponent("remote.zip")
            try writeArchive(at: archiveURL, markdown: "# Updated")
            let store = SkillStore()
            store.skills = [aliases.realSkill, aliases.aliasSkill]
            let client = RemoteSkillClient(
                fetchLatest: { _ in [] },
                search: { _, _ in [] },
                download: { _, _ in
                    try FileManager.default.removeItem(at: aliases.aliasRoot)
                    return archiveURL
                },
                fetchDetail: { _ in nil },
                fetchLatestVersion: { _ in nil }
            )

            _ = try await store.updateInstalledSkill(
                slug: slug,
                version: "2.0.0",
                client: client
            )

            #expect(try String(
                contentsOf: aliases.realSkill.skillMarkdownURL,
                encoding: .utf8
            ) == "# Updated")
        }
    }

    @MainActor
    @Test("cancellation across root aliases is not reported as a partial duplicate")
    func cancellationDoesNotCountRootAliasesTwice() async throws {
        try await withTemporaryDirectory { root in
            let slug = "shared-skill"
            let aliases = try makeAliasedSkills(named: slug, in: root)
            let archiveURL = root.appendingPathComponent("remote.zip")
            try writeArchive(at: archiveURL, markdown: "# Updated")
            let store = SkillStore()
            store.skills = [aliases.realSkill, aliases.aliasSkill]
            let client = RemoteSkillClient(
                fetchLatest: { _ in [] },
                search: { _, _ in [] },
                download: { _, _ in
                    withUnsafeCurrentTask { $0?.cancel() }
                    return archiveURL
                },
                fetchDetail: { _ in nil },
                fetchLatestVersion: { _ in nil }
            )
            let update = Task {
                try await store.updateInstalledSkill(
                    slug: slug,
                    version: "2.0.0",
                    client: client
                )
            }

            do {
                _ = try await update.value
                Issue.record("Expected cancellation")
            } catch is CancellationError {
                // Expected: no logical alias was counted as a completed physical destination.
            } catch let error as PartialSkillInstallError {
                Issue.record("Unexpected duplicate destination report: \(error)")
            }
        }
    }

    @MainActor
    private func makeAliasedSkills(
        named name: String,
        in root: URL
    ) throws -> (aliasRoot: URL, realSkill: Skill, aliasSkill: Skill) {
        let realRoot = root.appendingPathComponent("real", isDirectory: true)
        let aliasRoot = root.appendingPathComponent("alias", isDirectory: true)
        try FileManager.default.createDirectory(at: realRoot, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: aliasRoot, withDestinationURL: realRoot)
        return (
            aliasRoot,
            try makeSkill(
                named: name,
                platform: .codex,
                managedRoot: try ManagedRootReference.capture(at: realRoot)
            ),
            try makeSkill(
                named: name,
                platform: .claude,
                managedRoot: try ManagedRootReference.capture(at: aliasRoot)
            )
        )
    }

    @MainActor
    private func makeSkill(
        named name: String,
        platform: SkillPlatform,
        in temporaryRoot: URL
    ) throws -> Skill {
        let platformRoot = temporaryRoot.appendingPathComponent(platform.storageKey, isDirectory: true)
        try FileManager.default.createDirectory(at: platformRoot, withIntermediateDirectories: true)
        let managedRoot = try ManagedRootReference.capture(at: platformRoot)
        return try makeSkill(named: name, platform: platform, managedRoot: managedRoot)
    }

    @MainActor
    private func makeSkill(
        named name: String,
        platform: SkillPlatform,
        managedRoot: ManagedRootReference
    ) throws -> Skill {
        let skillRoot = managedRoot.registeredURL.appendingPathComponent(name, isDirectory: true)
        try FileManager.default.createDirectory(at: skillRoot, withIntermediateDirectories: true)
        let skillFile = skillRoot.appendingPathComponent("SKILL.md")
        if !FileManager.default.fileExists(atPath: skillFile.path) {
            try "# Existing".write(to: skillFile, atomically: true, encoding: .utf8)
        }
        return Skill(
            id: "\(platform.storageKey)-\(name)",
            name: name,
            displayName: name,
            description: "",
            platform: platform,
            customPath: nil,
            managedRoot: managedRoot,
            folderURL: skillRoot,
            skillMarkdownURL: skillFile,
            references: [],
            stats: SkillStats(references: 0, assets: 0, scripts: 0, templates: 0)
        )
    }

    private func writeArchive(at url: URL, markdown: String) throws {
        let contents = Data(markdown.utf8)
        let archive = try Archive(url: url, accessMode: .create)
        try archive.addEntry(
            with: "package/SKILL.md",
            type: .file,
            uncompressedSize: Int64(contents.count)
        ) { position, size in
            let start = Int(position)
            return contents.subdata(in: start..<min(start + size, contents.count))
        }
    }

    @MainActor
    private func withTemporaryDirectory(
        _ body: (URL) async throws -> Void
    ) async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("skill-store-identity-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try await body(root)
    }
}
