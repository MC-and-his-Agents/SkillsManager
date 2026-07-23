import Darwin
import Foundation
import Testing

@testable import SkillsManager

@Suite("Managed Skill import")
struct ManagedSkillImportTests {
    enum PreviewMutation: CaseIterable, Sendable {
        case rootReplacement
        case candidateReplacement
        case contentChange
        case collisionSibling
    }

    @Test("new import preserves the source and persists every alias scope")
    func importsNewSkillWithoutChangingSource() async throws {
        let workspace = try WriterWorkspace()
        let root = try discoveryRoot(in: workspace)
        let alias = workspace.workspace.appendingPathComponent("discovery-alias", isDirectory: true)
        let rawName = "cafe\u{301}"
        let skillURL = try createSkill(named: rawName, content: "# café", in: root)
        try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: root)
        let beforeIdentity = try identity(of: skillURL)
        let beforeBytes = try Data(contentsOf: skillURL.appendingPathComponent("SKILL.md"))
        let writer = try await workspace.openWriter()
        let observation = try await scanObservation(
            roots: [
                SkillDiscoveryRoot(scope: .global, url: root),
                SkillDiscoveryRoot(
                    scope: .agent(adapterCode: "codex", pathVariant: ".codex/skills"),
                    url: alias
                ),
            ],
            writer: writer
        )
        let service = ManagedSkillImportService(writer: writer, nowMilliseconds: { 42 })

        let preview = try await service.preview(observation: observation, action: .importNew)
        let result = try await service.execute(preview.token)

        #expect(result.disposition == .created)
        #expect(try workspace.integer("SELECT count(*) FROM skills") == 1)
        #expect(try workspace.integer("SELECT count(*) FROM local_skill_origins") == 2)
        #expect(try workspace.scalar(
            "SELECT raw_locator FROM local_skill_origins ORDER BY scope_kind LIMIT 1"
        ) == rawName)
        #expect(try workspace.scalar(
            "SELECT normalized_locator FROM local_skill_origins ORDER BY scope_kind LIMIT 1"
        ) == "café")
        #expect(FileManager.default.fileExists(
            atPath: workspace.root.appendingPathComponent(result.skill.skillID.directoryName).path
        ))
        #expect(try identity(of: skillURL) == beforeIdentity)
        #expect(try Data(contentsOf: skillURL.appendingPathComponent("SKILL.md")) == beforeBytes)
    }

    @Test("same and different preview tokens converge to one Skill")
    func previewRetriesAreIdempotent() async throws {
        let workspace = try WriterWorkspace()
        let root = try discoveryRoot(in: workspace)
        _ = try createSkill(named: "demo", content: "# Demo", in: root)
        let writer = try await workspace.openWriter()
        let observation = try await scanObservation(
            roots: [SkillDiscoveryRoot(scope: .global, url: root)],
            writer: writer
        )
        let service = ManagedSkillImportService(writer: writer)
        let firstPreview = try await service.preview(
            observation: observation,
            action: .importNew
        )
        let secondPreview = try await service.preview(
            observation: observation,
            action: .importNew
        )

        async let firstExecution = service.execute(firstPreview.token)
        async let secondExecution = service.execute(secondPreview.token)
        let (first, second) = try await (firstExecution, secondExecution)
        let repeated = try await service.execute(firstPreview.token)

        #expect(first.skill.skillID == second.skill.skillID)
        #expect(repeated == first)
        #expect(Set([first.disposition, second.disposition]) == [.created, .alreadyManaged])
        #expect(try workspace.integer("SELECT count(*) FROM skills") == 1)
        #expect(try workspace.integer("SELECT count(*) FROM local_skill_origins") == 1)
        #expect(try workspace.internalItemCount() == 0)
    }

    @Test("preview tokens expire with their service process state")
    func previewTokenExpiresAfterRestart() async throws {
        let workspace = try WriterWorkspace()
        let root = try discoveryRoot(in: workspace)
        _ = try createSkill(named: "demo", content: "# Demo", in: root)
        let writer = try await workspace.openWriter()
        let observation = try await scanObservation(
            roots: [SkillDiscoveryRoot(scope: .global, url: root)],
            writer: writer
        )
        let firstService = ManagedSkillImportService(writer: writer)
        let preview = try await firstService.preview(
            observation: observation,
            action: .importNew
        )
        let restartedService = ManagedSkillImportService(writer: writer)

        await #expect(throws: ManagedSkillImportError.tokenExpired) {
            _ = try await restartedService.execute(preview.token)
        }
        #expect(try workspace.integer("SELECT count(*) FROM skills") == 0)
    }

    @Test("a fingerprint match can be claimed without copying SSOT content")
    func claimsExistingSkill() async throws {
        let workspace = try WriterWorkspace()
        let root = try discoveryRoot(in: workspace)
        _ = try createSkill(named: "demo", content: "# Demo", in: root)
        let writer = try await workspace.openWriter()
        let snapshot = try workspace.snapshot(content: "# Demo")
        let seed = try workspace.payload(name: "Existing", snapshot: snapshot)
        _ = try await writer.create(payload: seed, sourceSnapshot: snapshot)
        let observation = try await scanObservation(
            roots: [SkillDiscoveryRoot(scope: .global, url: root)],
            writer: writer
        )
        #expect(observation.status == .claimable)
        let service = ManagedSkillImportService(writer: writer)

        let preview = try await service.preview(
            observation: observation,
            action: .claimExisting
        )
        let result = try await service.execute(preview.token)

        #expect(result.disposition == .claimed)
        #expect(result.skill.skillID == seed.skill.skillID)
        #expect(try workspace.integer("SELECT count(*) FROM skills") == 1)
        #expect(try workspace.integer("SELECT count(*) FROM local_skill_origins") == 1)
    }

    @Test("claim rejects matching evidence that became ambiguous after preview")
    func staleClaimEvidenceConflicts() async throws {
        let workspace = try WriterWorkspace()
        let root = try discoveryRoot(in: workspace)
        _ = try createSkill(named: "demo", content: "# Demo", in: root)
        let writer = try await workspace.openWriter()
        let snapshot = try workspace.snapshot(content: "# Demo")
        _ = try await writer.create(
            payload: workspace.payload(name: "First", snapshot: snapshot),
            sourceSnapshot: snapshot
        )
        let observation = try await scanObservation(
            roots: [SkillDiscoveryRoot(scope: .global, url: root)],
            writer: writer
        )
        let service = ManagedSkillImportService(writer: writer)
        let preview = try await service.preview(
            observation: observation,
            action: .claimExisting
        )
        _ = try await writer.create(
            payload: workspace.payload(name: "Second", snapshot: snapshot),
            sourceSnapshot: snapshot
        )

        await #expect(throws: ManagedSkillImportError.conflict) {
            _ = try await service.execute(preview.token)
        }
        #expect(try workspace.integer("SELECT count(*) FROM skills") == 2)
        #expect(try workspace.integer("SELECT count(*) FROM local_skill_origins") == 0)
    }

    @Test("claim fills a missing alias scope atomically")
    func fillsMissingAliasScope() async throws {
        let workspace = try WriterWorkspace()
        let root = try discoveryRoot(in: workspace)
        let alias = workspace.workspace.appendingPathComponent("discovery-alias", isDirectory: true)
        _ = try createSkill(named: "demo", content: "# Demo", in: root)
        try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: root)
        let writer = try await workspace.openWriter()
        let snapshot = try workspace.snapshot(content: "# Demo")
        let seed = try workspace.payload(name: "Existing", snapshot: snapshot)
        _ = try await writer.create(payload: seed, sourceSnapshot: snapshot)
        let service = ManagedSkillImportService(writer: writer)
        let globalObservation = try await scanObservation(
            roots: [SkillDiscoveryRoot(scope: .global, url: root)],
            writer: writer
        )
        let globalPreview = try await service.preview(
            observation: globalObservation,
            action: .claimExisting
        )
        _ = try await service.execute(globalPreview.token)
        let observation = try await scanObservation(
            roots: [
                SkillDiscoveryRoot(scope: .global, url: root),
                SkillDiscoveryRoot(
                    scope: .agent(adapterCode: "codex", pathVariant: ".codex/skills"),
                    url: alias
                ),
            ],
            writer: writer
        )
        #expect(observation.status == .claimable)

        let preview = try await service.preview(
            observation: observation,
            action: .claimExisting
        )
        let result = try await service.execute(preview.token)

        #expect(result.skill.skillID == seed.skill.skillID)
        #expect(try workspace.integer("SELECT count(*) FROM local_skill_origins") == 2)
    }

    @Test("explicit independent import is allowed for ambiguous content")
    func importsAmbiguousContentAsIndependentSkill() async throws {
        let workspace = try WriterWorkspace()
        let root = try discoveryRoot(in: workspace)
        _ = try createSkill(named: "demo", content: "# Shared", in: root)
        let writer = try await workspace.openWriter()
        let snapshot = try workspace.snapshot(content: "# Shared")
        _ = try await writer.create(
            payload: workspace.payload(name: "First", snapshot: snapshot),
            sourceSnapshot: snapshot
        )
        _ = try await writer.create(
            payload: workspace.payload(name: "Second", snapshot: snapshot),
            sourceSnapshot: snapshot
        )
        let observation = try await scanObservation(
            roots: [SkillDiscoveryRoot(scope: .global, url: root)],
            writer: writer
        )
        #expect(observation.reason == .ambiguousFingerprint)
        let service = ManagedSkillImportService(writer: writer)

        let preview = try await service.preview(
            observation: observation,
            action: .importNew
        )
        let result = try await service.execute(preview.token)

        #expect(result.disposition == .created)
        #expect(try workspace.integer("SELECT count(*) FROM skills") == 3)
        #expect(try workspace.integer("SELECT count(*) FROM local_skill_origins") == 1)
    }

    @Test(
        "root, candidate, content, and collision changes invalidate a preview",
        arguments: PreviewMutation.allCases
    )
    func previewChangesFailClosed(_ mutation: PreviewMutation) async throws {
        let workspace = try WriterWorkspace()
        let root = try discoveryRoot(in: workspace)
        let skillURL = try createSkill(named: "demo", content: "# Demo", in: root)
        let writer = try await workspace.openWriter()
        let observation = try await scanObservation(
            roots: [SkillDiscoveryRoot(scope: .global, url: root)],
            writer: writer
        )
        let service = ManagedSkillImportService(writer: writer)
        let preview = try await service.preview(
            observation: observation,
            action: .importNew
        )

        switch mutation {
        case .rootReplacement:
            try FileManager.default.moveItem(
                at: root,
                to: workspace.workspace.appendingPathComponent("discovery-old")
            )
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        case .candidateReplacement:
            try FileManager.default.removeItem(at: skillURL)
            _ = try createSkill(named: "demo", content: "# Demo", in: root)
        case .contentChange:
            try "# Changed".write(
                to: skillURL.appendingPathComponent("SKILL.md"),
                atomically: true,
                encoding: .utf8
            )
        case .collisionSibling:
            do {
                _ = try createSkill(named: "Demo", content: "# Demo", in: root)
            } catch let error as CocoaError where error.code == .fileWriteFileExists {
                // Default macOS volumes are case-insensitive; classifier coverage
                // exercises this branch when two physical siblings can coexist.
                return
            }
        }

        let expected: ManagedSkillImportError = mutation == .collisionSibling
            ? .conflict
            : .sourceChanged
        await #expect(throws: expected) {
            _ = try await service.execute(preview.token)
        }
        #expect(try workspace.integer("SELECT count(*) FROM skills") == 0)
        #expect(try workspace.integer("SELECT count(*) FROM local_skill_origins") == 0)
    }

    @Test("an associated location with content drift cannot be imported again")
    func associatedDriftCannotBecomeIndependentImport() async throws {
        let workspace = try WriterWorkspace()
        let root = try discoveryRoot(in: workspace)
        let skillURL = try createSkill(named: "demo", content: "# Demo", in: root)
        let writer = try await workspace.openWriter()
        var observation = try await scanObservation(
            roots: [SkillDiscoveryRoot(scope: .global, url: root)],
            writer: writer
        )
        let service = ManagedSkillImportService(writer: writer)
        let preview = try await service.preview(
            observation: observation,
            action: .importNew
        )
        _ = try await service.execute(preview.token)
        try "# Changed".write(
            to: skillURL.appendingPathComponent("SKILL.md"),
            atomically: true,
            encoding: .utf8
        )
        observation = try await scanObservation(
            roots: [SkillDiscoveryRoot(scope: .global, url: root)],
            writer: writer
        )
        #expect(observation.reason == .localAssociationDrift)

        await #expect(throws: ManagedSkillImportError.actionNotAllowed) {
            _ = try await service.preview(observation: observation, action: .importNew)
        }
        #expect(try workspace.integer("SELECT count(*) FROM skills") == 1)
    }

    private func discoveryRoot(in workspace: WriterWorkspace) throws -> URL {
        let root = workspace.workspace.appendingPathComponent("discovery", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        return root
    }

    private func createSkill(
        named name: String,
        content: String,
        in root: URL
    ) throws -> URL {
        let skill = root.appendingPathComponent(name, isDirectory: true)
        try FileManager.default.createDirectory(at: skill, withIntermediateDirectories: false)
        try content.write(
            to: skill.appendingPathComponent("SKILL.md"),
            atomically: true,
            encoding: .utf8
        )
        return skill
    }

    private func scanObservation(
        roots: [SkillDiscoveryRoot],
        writer: JournaledSSOTWriter
    ) async throws -> SkillDiscoveryObservation {
        let catalog = try await writer.discoveryCatalog()
        return try #require(
            SkillDiscoveryScanner().scan(roots: roots, catalog: catalog).observations.first
        )
    }

    private func identity(of url: URL) throws -> ManagedItemIdentity {
        var metadata = stat()
        guard Darwin.lstat(url.path, &metadata) == 0 else {
            throw CocoaError(.fileReadUnknown)
        }
        return ManagedItemIdentity(metadata)
    }
}
