import Foundation
import Testing
import ZIPFoundation

@testable import SkillsManager

@Suite("Multi-skill ZIP import")
struct ManagedLocalImportMultiSkillZipTests {
    @Test("enumerates independent candidates on one shared lease")
    func enumeratesCandidates() async throws {
        try await withTemporaryDirectory { root in
            let archiveURL = root.appendingPathComponent("bundle.zip")
            try writeArchive(at: archiveURL, entries: [
                ("alpha/SKILL.md", Data("# Alpha".utf8)),
                ("alpha/icon.txt", Data("a".utf8)),
                ("beta/SKILL.md", Data("# Beta".utf8)),
            ])

            let session = try await SkillImportWorker().validateZipSession(archiveURL)
            defer { Task { await SkillImportWorker().cleanupArchiveSession(session) } }

            #expect(session.candidates.map(\.canonicalSubpath) == ["alpha", "beta"])
            #expect(session.importableCandidates.count == 2)
            #expect(session.candidates.allSatisfy { $0.payload?.temporaryRoot == nil })
            #expect(Set(session.candidates.compactMap { $0.payload?.markdown }) == [
                "# Alpha", "# Beta",
            ])
            #expect(session.candidates.allSatisfy { $0.id.archiveSessionID == session.id })
        }
    }

    @Test("blocks overlapping candidates while keeping unrelated candidates")
    func blocksOverlappingCandidates() async throws {
        try await withTemporaryDirectory { root in
            let archiveURL = root.appendingPathComponent("overlap.zip")
            try writeArchive(at: archiveURL, entries: [
                ("group/SKILL.md", Data("# Group".utf8)),
                ("group/nested/SKILL.md", Data("# Nested".utf8)),
                ("independent/SKILL.md", Data("# Independent".utf8)),
            ])

            let session = try await SkillImportWorker().validateZipSession(archiveURL)
            defer { Task { await SkillImportWorker().cleanupArchiveSession(session) } }

            #expect(session.candidates.count == 3)
            #expect(session.candidates.filter { !$0.isImportable }.count == 2)
            #expect(session.importableCandidates.map(\.canonicalSubpath) == ["independent"])
            #expect(session.candidates
                .filter { !$0.isImportable }
                .allSatisfy { $0.blockedReason?.contains("overlaps") == true })
        }
    }

    @Test("blocks candidate content failures without rejecting other candidates")
    func candidateContentFailure() async throws {
        try await withTemporaryDirectory { root in
            let archiveURL = root.appendingPathComponent("invalid-content.zip")
            try writeArchive(at: archiveURL, entries: [
                ("good/SKILL.md", Data("# Good".utf8)),
                ("bad/SKILL.md", Data([0xff, 0xfe])),
            ])

            let session = try await SkillImportWorker().validateZipSession(archiveURL)
            defer { Task { await SkillImportWorker().cleanupArchiveSession(session) } }

            #expect(session.importableCandidates.map(\.canonicalSubpath) == ["good"])
            #expect(session.candidates.first { $0.canonicalSubpath == "bad" }?.blockedReason?
                .contains("UTF-8") == true)
        }
    }

    @Test("duplicate derived slugs block only the conflicting candidates")
    func duplicateSlugs() async throws {
        try await withTemporaryDirectory { root in
            let archiveURL = root.appendingPathComponent("slugs.zip")
            try writeArchive(at: archiveURL, entries: [
                ("a-b/SKILL.md", Data("# One".utf8)),
                ("a b/SKILL.md", Data("# Two".utf8)),
                ("other/SKILL.md", Data("# Other".utf8)),
            ])

            let session = try await SkillImportWorker().validateZipSession(archiveURL)
            defer { Task { await SkillImportWorker().cleanupArchiveSession(session) } }

            #expect(session.importableCandidates.map(\.canonicalSubpath) == ["other"])
            #expect(session.candidates
                .filter { $0.canonicalSubpath != "other" }
                .allSatisfy { $0.blockedReason?.contains("same distribution slug") == true })
        }
    }

    @Test("archive with no manifest fails closed before retaining a lease")
    func noCandidatesFailsClosed() async throws {
        try await withTemporaryDirectory { root in
            let archiveURL = root.appendingPathComponent("empty.zip")
            try writeArchive(at: archiveURL, entries: [("README.txt", Data("none".utf8))])

            await #expect(throws: SkillImportValidationError.self) {
                _ = try await SkillImportWorker().validateZipSession(archiveURL)
            }
        }
    }

    @Test("root manifest uses the archive filename as its display name")
    func rootCandidate() async throws {
        try await withTemporaryDirectory { root in
            let archiveURL = root.appendingPathComponent("Root Bundle.zip")
            try writeArchive(at: archiveURL, entries: [
                ("SKILL.md", Data("# Root".utf8)),
            ])

            let session = try await SkillImportWorker().validateZipSession(archiveURL)
            #expect(session.candidates.count == 1)
            #expect(session.candidates[0].canonicalSubpath.isEmpty)
            #expect(session.candidates[0].displayName == "Root Bundle")
            #expect(session.candidates[0].payload?.markdown == "# Root")
            await SkillImportWorker().cleanupArchiveSession(session)
        }
    }

    @Test("normalizes the displayed subpath without losing the raw archive locator")
    func normalizedCandidateSubpath() async throws {
        try await withTemporaryDirectory { root in
            let archiveURL = root.appendingPathComponent("unicode.zip")
            let decomposed = "e\u{301}"
            try writeArchive(at: archiveURL, entries: [
                ("\(decomposed)/SKILL.md", Data("# Unicode".utf8)),
            ])

            let worker = SkillImportWorker()
            let session = try await worker.validateZipSession(archiveURL)
            #expect(session.candidates.count == 1)
            #expect(session.candidates[0].canonicalSubpath == "é")
            #expect(session.candidates[0].displayName == "é")
            #expect(session.candidates[0].payload?.markdown == "# Unicode")
            await worker.cleanupArchiveSession(session)
        }
    }

    @Test("selection is partial and confirmation is single flight")
    @MainActor
    func partialSelectionAndDuplicateConfirmation() async throws {
        try await withMainActorTemporaryDirectory { root in
            let archiveURL = root.appendingPathComponent("selection.zip")
            try writeArchive(at: archiveURL, entries: [
                ("first/SKILL.md", Data("# First".utf8)),
                ("second/SKILL.md", Data("# Second".utf8)),
            ])
            let worker = SkillImportWorker()
            let session = try await worker.validateZipSession(archiveURL)
            defer { Task { await worker.cleanupArchiveSession(session) } }

            let probe = ManagedLocalImportProbe(planStatuses: [.noOp])
            let model = ManagedArchiveImportViewModel()
            model.activate(dependencies: probe.dependencies())
            model.configure(session: session)
            model.clearSelection()
            let first = try #require(session.candidates.first)
            model.toggleSelection(first.id)
            await model.prepare(scope: .global)
            await model.confirm()
            await model.confirm()

            #expect(model.resultItems.count == 1)
            #expect(await probe.createCount == 1)
        }
    }

    @Test("one preview failure does not block another candidate")
    @MainActor
    func mixedPreviewResultsContinue() async throws {
        try await withMainActorTemporaryDirectory { root in
            let archiveURL = root.appendingPathComponent("mixed.zip")
            try writeArchive(at: archiveURL, entries: [
                ("first/SKILL.md", Data("# First".utf8)),
                ("second/SKILL.md", Data("# Second".utf8)),
            ])
            let worker = SkillImportWorker()
            let session = try await worker.validateZipSession(archiveURL)

            let probe = ManagedLocalImportProbe(
                planStatuses: [.noOp],
                planFailureIndex: 1
            )
            let model = ManagedArchiveImportViewModel()
            model.activate(dependencies: probe.dependencies())
            model.configure(session: session)
            await model.prepare(scope: .global)

            await model.confirm()

            #expect(model.resultItems.count == 2)
            #expect(model.summary.imported == 1)
            #expect(model.summary.skipped == 1)
            #expect(await probe.createCount == 1)
            await worker.cleanupArchiveSession(session)
        }
    }

    @Test("blocked distribution still keeps the managed Skill")
    @MainActor
    func blockedDistributionKeepsManagedSkill() async throws {
        try await withMainActorTemporaryDirectory { root in
            let archiveURL = root.appendingPathComponent("blocked.zip")
            try writeArchive(at: archiveURL, entries: [
                ("blocked/SKILL.md", Data("# Blocked".utf8)),
            ])
            let worker = SkillImportWorker()
            let session = try await worker.validateZipSession(archiveURL)
            defer { Task { await worker.cleanupArchiveSession(session) } }

            let probe = ManagedLocalImportProbe(planStatuses: [.blocked, .blocked])
            let model = ManagedArchiveImportViewModel()
            model.activate(dependencies: probe.dependencies())
            model.configure(session: session)
            await model.prepare(scope: .global)

            #expect(model.hasBlockedDistribution)
            #expect(model.previewItems.first?.preview?.plan.conflicts.first?.reason == .slugOccupied)
            #expect(
                model.previewItems.first?.preview?.plan.conflicts.first?.canonicalLocator
                    == "~/.agents/skills/blocked"
            )
            await model.confirm()

            #expect(await probe.createCount == 1)
            guard case .imported(.managedUndistributed) = model.resultItems.first?.management else {
                Issue.record("Expected a managed but undistributed result")
                return
            }
        }
    }

    @Test("lease drift blocks writes after preview")
    @MainActor
    func leaseDriftBlocksWrites() async throws {
        try await withMainActorTemporaryDirectory { root in
            let archiveURL = root.appendingPathComponent("drift.zip")
            try writeArchive(at: archiveURL, entries: [
                ("drift/SKILL.md", Data("# Drift".utf8)),
            ])
            let worker = SkillImportWorker()
            let session = try await worker.validateZipSession(archiveURL)

            let probe = ManagedLocalImportProbe(planStatuses: [.noOp])
            let model = ManagedArchiveImportViewModel()
            model.activate(dependencies: probe.dependencies())
            model.configure(session: session)
            await model.prepare(scope: .global)

            let displaced = session.temporaryRoot.url
                .deletingLastPathComponent()
                .appendingPathComponent("displaced-\(UUID().uuidString)", isDirectory: true)
            try FileManager.default.moveItem(at: session.temporaryRoot.url, to: displaced)
            try FileManager.default.createDirectory(
                at: session.temporaryRoot.url,
                withIntermediateDirectories: false
            )
            await model.confirm()

            #expect(await probe.createCount == 0)
            if case .failed = model.resultItems.first?.management {
                // expected
            } else {
                Issue.record("Expected lease drift to fail before create")
            }
            await worker.cleanupArchiveSession(session)
            #expect(FileManager.default.fileExists(atPath: session.temporaryRoot.url.path))
            try? FileManager.default.removeItem(at: session.temporaryRoot.url)
            try? FileManager.default.removeItem(at: displaced)
        }
    }

    @Test("shared lease cleanup waits for the last consumer")
    func sharedLeaseCleanupWaitsForConsumer() async throws {
        try await withTemporaryDirectory { root in
            let archiveURL = root.appendingPathComponent("cleanup.zip")
            try writeArchive(at: archiveURL, entries: [
                ("cleanup/SKILL.md", Data("# Cleanup".utf8)),
            ])
            let worker = SkillImportWorker()
            let session = try await worker.validateZipSession(archiveURL)
            let gate = ArchiveSessionConsumerGate()
            let consumer = Task {
                await withTaskCancellationHandler {
                    await gate.waitForRelease()
                } onCancel: {
                    Task { await gate.recordCancellation() }
                }
            }
            #expect(await gate.waitUntilStarted())

            let cleanup = Task {
                await worker.cleanupArchiveSession(session, afterCancelling: consumer)
            }
            #expect(await gate.waitUntilCancelled())
            #expect(FileManager.default.fileExists(atPath: session.temporaryRoot.url.path))
            await gate.release()
            await cleanup.value
            #expect(!FileManager.default.fileExists(atPath: session.temporaryRoot.url.path))
        }
    }

    private func writeArchive(
        at url: URL,
        entries: [(String, Data)]
    ) throws {
        let archive = try Archive(url: url, accessMode: .create)
        for (path, contents) in entries {
            try archive.addEntry(
                with: path,
                type: .file,
                uncompressedSize: Int64(contents.count)
            ) { position, size in
                let start = Int(position)
                return contents.subdata(in: start..<min(start + size, contents.count))
            }
        }
    }

    private func withTemporaryDirectory(
        _ body: (URL) async throws -> Void
    ) async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("multi-skill-import-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try await body(root)
    }

    @MainActor
    private func withMainActorTemporaryDirectory(
        _ body: @MainActor (URL) async throws -> Void
    ) async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("multi-skill-import-main-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try await body(root)
    }
}

private actor ArchiveSessionConsumerGate {
    private var continuation: CheckedContinuation<Void, Never>?
    private var started = false
    private var cancelled = false

    func waitForRelease() async {
        await withCheckedContinuation {
            continuation = $0
            started = true
        }
    }

    func recordCancellation() {
        cancelled = true
    }

    func waitUntilStarted() async -> Bool {
        await waitUntil { started }
    }

    func waitUntilCancelled() async -> Bool {
        await waitUntil { cancelled }
    }

    func release() {
        continuation?.resume()
        continuation = nil
    }

    private func waitUntil(_ predicate: () -> Bool) async -> Bool {
        for _ in 0..<10_000 {
            if predicate() { return true }
            await Task.yield()
        }
        return false
    }
}
