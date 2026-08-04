import Foundation
import Testing

@testable import SkillsManager

@Suite("SkillStore selection freshness")
@MainActor
struct SkillStoreSelectionTests {
    @Test("a slower previous detail request cannot replace the current selection")
    func staleDetailIsIgnored() async throws {
        let rootURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(
            at: rootURL,
            withIntermediateDirectories: true
        )
        defer { try? FileManager.default.removeItem(at: rootURL) }

        let managedRoot = try ManagedRootReference.capture(at: rootURL)
        let first = skill("first", root: managedRoot, rootURL: rootURL)
        let second = skill("second", root: managedRoot, rootURL: rootURL)
        let store = SkillStore(markdownLoader: { url in
            if url.lastPathComponent == "first.md" {
                try await Task.sleep(for: .milliseconds(40))
                return "# First"
            }
            return "# Second"
        })
        store.skills = [first, second]
        store.selectedSkillID = first.id

        let stale = Task { await store.loadSelectedSkill() }
        try await Task.sleep(for: .milliseconds(5))
        store.selectedSkillID = second.id
        await store.loadSelectedSkill()
        await stale.value

        #expect(store.selectedSkillID == second.id)
        #expect(store.selectedMarkdown == "# Second")
        #expect(store.detailState == .loaded)
    }

    private func skill(
        _ id: String,
        root: ManagedRootReference,
        rootURL: URL
    ) -> Skill {
        let folderURL = rootURL.appendingPathComponent(id, isDirectory: true)
        return Skill(
            id: id,
            managedSkillID: SkillID(),
            name: id,
            displayName: id.capitalized,
            description: "",
            managedStatus: .managed,
            identitySummary: "On This Mac",
            listOrigin: SkillListOriginProjection(
                hasRepositorySource: false,
                providers: []
            ),
            clawdhubSlug: nil,
            clawdhubVersion: nil,
            enabledPlatforms: [],
            managedRoot: root,
            folderURL: folderURL,
            skillMarkdownURL: rootURL.appendingPathComponent("\(id).md"),
            references: [],
            stats: SkillStats(references: 0, assets: 0, scripts: 0, templates: 0)
        )
    }
}
