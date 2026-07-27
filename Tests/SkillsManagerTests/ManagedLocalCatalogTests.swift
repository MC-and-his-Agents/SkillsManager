import Foundation
import Testing

@testable import SkillsManager

@Suite("Managed Local catalog", .serialized)
struct ManagedLocalCatalogTests {
    @MainActor
    @Test("Local reads only the SQLite catalog and UUID SSOT")
    func loadsManagedCatalog() async throws {
        let workspace = try WriterWorkspace()
        let writer = try await workspace.openWriter()
        let skillID = SkillID()
        let snapshot = try workspace.snapshot(
            content: """
            ---
            name: Published Skill
            description: Managed content
            ---
            # Managed
            """
        )
        let base = try workspace.payload(
            skillID: skillID,
            name: "Published Skill",
            snapshot: snapshot
        )
        let slug = try DefaultDistributionSlug(validating: "published-skill")
        let provenance = try ProviderProvenanceRecord(
            skillID: skillID,
            identity: ProviderAliasIdentity(
                provider: "clawdhub",
                identifier: slug.value
            ),
            identifierKey: slug.collisionKey,
            version: try SourceVersion("1.2.3")
        )
        _ = try await writer.create(
            payload: try SSOTSkillWritePayload(
                skill: base.skill,
                providerProvenance: [provenance]
            ),
            sourceSnapshot: snapshot
        )

        let unmanagedRoot = workspace.workspace.appendingPathComponent(
            "agent-copy",
            isDirectory: true
        )
        try FileManager.default.createDirectory(
            at: unmanagedRoot,
            withIntermediateDirectories: false
        )
        try snapshot.copyFiles(to: unmanagedRoot)

        let store = SkillStore()
        store.activatePersistence(writer)
        await store.loadSkills()

        let skill = try #require(store.skills.first)
        #expect(store.skills.count == 1)
        #expect(skill.managedSkillID == skillID)
        #expect(skill.id == skillID.directoryName)
        #expect(skill.folderURL.deletingLastPathComponent().standardizedFileURL
            == workspace.root.standardizedFileURL)
        #expect(skill.clawdhubSlug == "published-skill")
        #expect(skill.clawdhubVersion == "1.2.3")
        #expect(skill.enabledPlatforms.isEmpty)
    }

    @Test("publication snapshot rejects SSOT drift and freezes copied content")
    func validatesAndFreezesPublicationSnapshot() async throws {
        let workspace = try WriterWorkspace()
        let writer = try await workspace.openWriter()
        let skillID = SkillID()
        let snapshot = try workspace.snapshot(content: "# Original")
        _ = try await writer.create(
            payload: try workspace.payload(
                skillID: skillID,
                name: "Original",
                snapshot: snapshot
            ),
            sourceSnapshot: snapshot
        )

        let publication = try await writer.managedSkillPublicationSnapshot(skillID)
        let temporary = try TemporaryItemLease.createDirectory(
            in: FileManager.default.temporaryDirectory,
            prefix: "managed-local-test-"
        )
        defer { try? temporary.lease.removeIfCurrent() }
        try publication.copyFiles(toDirectoryDescriptor: temporary.handle.descriptor)

        let managedMarkdown = workspace.root
            .appendingPathComponent(skillID.directoryName, isDirectory: true)
            .appendingPathComponent("SKILL.md")
        try "# Drifted".write(to: managedMarkdown, atomically: true, encoding: .utf8)

        #expect(try String(
            contentsOf: temporary.handle.url.appendingPathComponent("SKILL.md"),
            encoding: .utf8
        ) == "# Original")
        await #expect(throws: Error.self) {
            _ = try await writer.managedSkillPublicationSnapshot(skillID)
        }
    }
}

@Suite("SkillStore publish")
struct SkillStorePublishTests {
    @MainActor
    @Test("state persistence failure reports a partial publish success")
    func reportsPartialSuccess() async {
        let store = SkillStore()

        await #expect(throws: SkillPublishError.publishedButStateNotRecorded) {
            try await store.recordPublishedState(for: SkillID(), hash: "published")
        }
        #expect(
            SkillPublishError.publishedButStateNotRecorded.localizedDescription
                .contains("Clawdhub published")
        )
    }
}
