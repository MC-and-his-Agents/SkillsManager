import Foundation
import Testing
import ZIPFoundation

@testable import SkillsManager

@Suite("Managed local import service")
struct ManagedLocalImportServiceTests {
    @Test("pre-create distribution plan does not require an existing Skill row")
    func preCreatePlan() async throws {
        let workspace = try WriterWorkspace()
        let writer = try await workspace.openWriter()
        let skillID = SkillID()
        let slug = try DefaultDistributionSlug(validating: "precreate-\(skillID.directoryName)")
        let plan = try await writer.distributionPlan(
            skillID: skillID,
            desiredScope: .global(slug),
            requiredAdapterCodes: Set(
                DistributionTargetCatalog.current.globalReaders.map(\.storageKey)
            )
        )

        #expect(plan.status == .executable)
        #expect(try workspace.integer("SELECT COUNT(*) FROM skills") == 0)
    }

    @Test("default global import creates SSOT before distribution without fabricated source")
    func globalImport() async throws {
        try await withImportCandidate { candidate in
            let probe = ManagedLocalImportProbe()
            let service = ManagedLocalImportService(dependencies: probe.dependencies())
            let preview = try await service.prepare(
                candidate: candidate,
                displayName: "Demo Skill",
                scope: .global
            )

            if case .global = preview.desiredScope {} else {
                Issue.record("Expected global distribution")
            }
            #expect(await probe.requestedAdapterCodes.first
                == Set(DistributionTargetCatalog.current.globalReaders.map(\.storageKey)))

            let result = try await service.execute(preview.token)
            #expect(result.status == .distributed)
            #expect(await probe.createCount == 1)
            #expect(await probe.applyCount == 1)
            let payload = try #require(await probe.createdPayload)
            #expect(payload.skill.skillID == preview.skillID)
            #expect(payload.source == nil)
            #expect(payload.providerAliases.isEmpty)
            #expect(payload.localOrigins.isEmpty)
        }
    }

    @Test("Agent-specific import requires at least one Agent")
    func agentSelectionRequired() async throws {
        try await withImportCandidate { candidate in
            let service = ManagedLocalImportService(
                dependencies: ManagedLocalImportProbe().dependencies()
            )
            await #expect(throws: ManagedLocalImportProblem.emptyAgentSelection) {
                _ = try await service.prepare(
                    candidate: candidate,
                    displayName: "Demo",
                    scope: .agents([])
                )
            }
        }
    }

    @Test("ZIP candidate keeps one stable Skill identity through SSOT and distribution")
    func zipImport() async throws {
        try await withZipImportCandidate { candidate in
            let probe = ManagedLocalImportProbe()
            let service = ManagedLocalImportService(dependencies: probe.dependencies())
            let preview = try await service.prepare(
                candidate: candidate,
                displayName: "ZIP Demo",
                scope: .agents([.claude])
            )
            let result = try await service.execute(preview.token)

            #expect(result.skillID == preview.skillID)
            #expect(result.status == .distributed)
            #expect(await probe.createdPayload?.skill.skillID == preview.skillID)
        }
    }

    @Test("ZIP source drift expires before create")
    func zipSourceDrift() async throws {
        try await withZipImportCandidate { candidate in
            let probe = ManagedLocalImportProbe()
            let service = ManagedLocalImportService(dependencies: probe.dependencies())
            let preview = try await service.prepare(
                candidate: candidate,
                displayName: "ZIP Demo",
                scope: .global
            )
            try Data("# Changed".utf8).write(to: candidate.skillFileURL)

            await #expect(throws: ManagedLocalImportProblem.sourceChanged) {
                _ = try await service.execute(preview.token)
            }
            #expect(await probe.createCount == 0)
        }
    }

    @Test("source content drift expires before create")
    func sourceDrift() async throws {
        try await withImportCandidate { candidate in
            let probe = ManagedLocalImportProbe()
            let service = ManagedLocalImportService(dependencies: probe.dependencies())
            let preview = try await service.prepare(
                candidate: candidate,
                displayName: "Demo",
                scope: .global
            )
            try Data("# Changed".utf8).write(to: candidate.skillFileURL)

            await #expect(throws: ManagedLocalImportProblem.sourceChanged) {
                _ = try await service.execute(preview.token)
            }
            #expect(await probe.createCount == 0)
        }
    }

    @Test("same-content root replacement still expires before create")
    func rootIdentityDrift() async throws {
        try await withImportCandidate { candidate in
            let probe = ManagedLocalImportProbe()
            let service = ManagedLocalImportService(dependencies: probe.dependencies())
            let preview = try await service.prepare(
                candidate: candidate,
                displayName: "Demo",
                scope: .global
            )
            let moved = candidate.rootURL.deletingLastPathComponent()
                .appendingPathComponent("moved", isDirectory: true)
            try FileManager.default.moveItem(at: candidate.rootURL, to: moved)
            try FileManager.default.createDirectory(at: candidate.rootURL, withIntermediateDirectories: false)
            try Data("# Demo".utf8).write(to: candidate.rootURL.appendingPathComponent("SKILL.md"))

            await #expect(throws: ManagedLocalImportProblem.sourceChanged) {
                _ = try await service.execute(preview.token)
            }
            #expect(await probe.createCount == 0)
        }
    }

    @Test("canonical plan drift expires before create")
    func planDrift() async throws {
        try await withImportCandidate { candidate in
            let probe = ManagedLocalImportProbe(planStatuses: [.executable, .noOp])
            let service = ManagedLocalImportService(dependencies: probe.dependencies())
            let preview = try await service.prepare(
                candidate: candidate,
                displayName: "Demo",
                scope: .global
            )

            await #expect(throws: ManagedLocalImportProblem.previewExpired) {
                _ = try await service.execute(preview.token)
            }
            #expect(await probe.createCount == 0)
        }
    }

    @Test("concurrent and repeated confirmation consumes create once")
    func confirmationIsSingleFlight() async throws {
        try await withImportCandidate { candidate in
            let probe = ManagedLocalImportProbe(createDelay: .milliseconds(50))
            let service = ManagedLocalImportService(dependencies: probe.dependencies())
            let preview = try await service.prepare(
                candidate: candidate,
                displayName: "Demo",
                scope: .global
            )

            let first = Task { try await service.execute(preview.token) }
            while await probe.createCount == 0 {
                await Task.yield()
            }
            await #expect(throws: ManagedLocalImportProblem.operationInProgress) {
                _ = try await service.execute(preview.token)
            }
            let completed = try await first.value
            let repeated = try await service.execute(preview.token)

            #expect(completed == repeated)
            #expect(await probe.createCount == 1)
            #expect(await probe.applyCount == 1)
        }
    }

    @Test("unknown prepared create is cached and never retried")
    func unknownCreateResult() async throws {
        try await withImportCandidate { candidate in
            let probe = ManagedLocalImportProbe(
                createThrows: true,
                readbackState: .init(
                    phase: .prepared,
                    outcome: .pending,
                    cleanupState: .notApplicable
                )
            )
            let service = ManagedLocalImportService(dependencies: probe.dependencies())
            let preview = try await service.prepare(
                candidate: candidate,
                displayName: "Demo",
                scope: .global
            )

            let first = try await service.execute(preview.token)
            let repeated = try await service.execute(preview.token)
            #expect(first.status == .managementIndeterminate)
            #expect(first == repeated)
            #expect(await probe.createCount == 1)
            #expect(await probe.applyCount == 0)
        }
    }

    @Test("distribution repair state is not reported as undistributed")
    func distributionIndeterminate() async throws {
        try await withImportCandidate { candidate in
            let probe = ManagedLocalImportProbe(
                applyThrows: true,
                reconcileStatus: .needsRepair
            )
            let service = ManagedLocalImportService(dependencies: probe.dependencies())
            let preview = try await service.prepare(
                candidate: candidate,
                displayName: "Demo",
                scope: .global
            )

            let result = try await service.execute(preview.token)
            #expect(result.status == .managedDistributionIndeterminate)
            #expect(await probe.createCount == 1)
            #expect(await probe.applyCount == 1)
        }
    }

    @Test("proved distribution rollback is reported as managed but undistributed")
    func distributionRolledBack() async throws {
        try await withImportCandidate { candidate in
            let probe = ManagedLocalImportProbe(
                applyThrows: true,
                reconcileStatus: .inSync
            )
            let service = ManagedLocalImportService(dependencies: probe.dependencies())
            let preview = try await service.prepare(
                candidate: candidate,
                displayName: "Demo",
                scope: .global
            )

            let result = try await service.execute(preview.token)
            #expect(result.status == .managedUndistributed)
        }
    }

    @Test("blocked preview never creates a managed Skill")
    func blockedPreview() async throws {
        try await withImportCandidate { candidate in
            let probe = ManagedLocalImportProbe(planStatuses: [.blocked])
            let service = ManagedLocalImportService(dependencies: probe.dependencies())
            let preview = try await service.prepare(
                candidate: candidate,
                displayName: "Demo",
                scope: .global
            )

            await #expect(throws: ManagedLocalImportProblem.previewBlocked) {
                _ = try await service.execute(preview.token)
            }
            #expect(await probe.createCount == 0)
        }
    }
}

private func withImportCandidate(
    _ body: (SkillImportWorker.ImportCandidatePayload) async throws -> Void
) async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(
        "managed-local-import-tests-\(UUID().uuidString.lowercased())",
        isDirectory: true
    )
    let skill = root.appendingPathComponent("demo", isDirectory: true)
    try FileManager.default.createDirectory(at: skill, withIntermediateDirectories: true)
    try Data("# Demo".utf8).write(to: skill.appendingPathComponent("SKILL.md"))
    defer { try? FileManager.default.removeItem(at: root) }
    let candidate = try await SkillImportWorker().validateFolder(skill)
    try await body(candidate)
}

private func withZipImportCandidate(
    _ body: (SkillImportWorker.ImportCandidatePayload) async throws -> Void
) async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(
        "managed-local-import-zip-\(UUID().uuidString.lowercased())",
        isDirectory: true
    )
    let archiveURL = root.appendingPathComponent("demo.zip")
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
    defer { try? FileManager.default.removeItem(at: root) }
    try writeImportArchive(at: archiveURL)

    let worker = SkillImportWorker()
    let candidate = try await worker.validateZip(archiveURL)
    do {
        try await body(candidate)
    } catch {
        if let lease = candidate.temporaryRoot {
            await worker.cleanupTemporaryRoot(lease)
        }
        throw error
    }
    if let lease = candidate.temporaryRoot {
        await worker.cleanupTemporaryRoot(lease)
        #expect(!FileManager.default.fileExists(atPath: lease.url.path))
    }
}

private func writeImportArchive(at url: URL) throws {
    let contents = Data("# ZIP Demo".utf8)
    let archive = try Archive(url: url, accessMode: .create)
    try archive.addEntry(
        with: "zip-demo/SKILL.md",
        type: .file,
        uncompressedSize: Int64(contents.count)
    ) { position, size in
        let start = Int(position)
        return contents.subdata(in: start..<min(start + size, contents.count))
    }
}
