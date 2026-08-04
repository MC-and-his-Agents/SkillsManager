import Foundation
import Testing

@testable import SkillsManager

@Suite("Custom repository catalog", .serialized)
struct CustomRepositoryCatalogTests {
    @Test("validates GitHub URLs, refs, CRUD, ordering, and CAS")
    func catalog() throws {
        try withStore { store in
            let beta = try store.insert(
                CustomRepositoryCatalogInput(
                    repositoryURL: "https://github.com/Owner/Beta.git",
                    requestedRef: try .explicit(validating: "feature/one")
                ),
                nowMilliseconds: 10
            )
            let alpha = try store.insert(
                CustomRepositoryCatalogInput(repositoryURL: "https://github.com/a/alpha"),
                nowMilliseconds: 20
            )
            #expect(try store.list().map(\.repositoryID) == [alpha.repositoryID, beta.repositoryID])
            #expect(beta.repositoryURL.value == "https://github.com/owner/beta")
            #expect(beta.displayName == "owner/beta")

            let disabled = try store.replace(
                id: beta.repositoryID,
                expectedRevision: 0,
                input: CustomRepositoryCatalogInput(
                    repositoryURL: beta.repositoryURL.value,
                    requestedRef: .defaultBranch,
                    displayName: "Beta",
                    enabled: false
                ),
                nowMilliseconds: 30
            )
            #expect(disabled.databaseRevision == 1)
            #expect(!disabled.enabled)
            #expect(throws: CustomRepositoryCatalogError.conflict) {
                _ = try store.replace(
                    id: beta.repositoryID,
                    expectedRevision: 0,
                    input: CustomRepositoryCatalogInput(repositoryURL: beta.repositoryURL.value),
                    nowMilliseconds: 40
                )
            }
            try store.remove(id: beta.repositoryID, expectedRevision: 1)
            #expect(try store.load(id: beta.repositoryID) == nil)
        }
    }

    @Test("rejects non-public GitHub inputs and duplicate canonical URL")
    func validation() throws {
        for url in [
            "http://github.com/a/b", "ssh://git@github.com/a/b", "git@github.com:a/b",
            "https://gitlab.com/a/b", "https://github.com/a/b/extra",
            "https://github.com/a/b?x=1", "https://github.com/a/b.git.git",
            "https://github.com/a!/b", "https://github.com/owner/repo!",
            "https://github.com/aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa/b",
        ] {
            #expect(throws: CustomRepositoryCatalogError.invalidURL) {
                try CustomRepositoryCatalogInput(repositoryURL: url)
            }
        }
        for ref in ["", "a b", "a..b", "a@{b", "/a", "a/", "a.lock"] {
            #expect(throws: CustomRepositoryCatalogError.invalidRef) {
                try CustomRepositoryRef.explicit(validating: ref)
            }
        }
        try withStore { store in
            _ = try store.insert(
                CustomRepositoryCatalogInput(repositoryURL: "https://github.com/A/B"),
                nowMilliseconds: 1
            )
            #expect(throws: CustomRepositoryCatalogError.alreadyExists) {
                _ = try store.insert(
                    CustomRepositoryCatalogInput(repositoryURL: "https://github.com/a/b.git"),
                    nowMilliseconds: 2
                )
            }
            #expect(throws: CustomRepositoryCatalogError.notFound) {
                try store.remove(id: UUID(), expectedRevision: 0)
            }

            let originalID = try #require(store.list().first?.repositoryID)
            try store.remove(id: originalID, expectedRevision: 0)
            let recreated = try store.insert(
                CustomRepositoryCatalogInput(repositoryURL: "https://github.com/a/b"),
                nowMilliseconds: 3
            )
            #expect(recreated.repositoryID != originalID)
        }
    }

    private func withStore(_ body: (RepositoryCatalogStore) throws -> Void) throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("repository-catalog-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: root) }
        let connection = try SkillSchemaMigrator.open(at: root.appendingPathComponent("db.sqlite"))
        try body(RepositoryCatalogStore(connection: connection))
    }
}
