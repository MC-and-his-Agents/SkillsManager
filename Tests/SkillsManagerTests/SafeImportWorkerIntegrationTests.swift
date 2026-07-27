import Foundation
import Testing
import ZIPFoundation

@testable import SkillsManager

@Suite("Safe import worker integration")
struct SafeImportWorkerIntegrationTests {
    @Test("folder validation rejects symbolic links with a useful error")
    func folderValidationRejectsSymbolicLinks() async throws {
        try await withTemporaryDirectory { root in
            let source = root.appendingPathComponent("unsafe", isDirectory: true)
            try makeSkill(at: source, markdown: "# Unsafe")
            try FileManager.default.createSymbolicLink(
                at: source.appendingPathComponent("outside-link"),
                withDestinationURL: root
            )

            do {
                _ = try await SkillImportWorker().validateFolder(source)
                Issue.record("Expected symbolic link validation to fail")
            } catch {
                #expect(error.localizedDescription.contains("unsupported file or symbolic link"))
            }
        }
    }

    @Test("folder validation rejects a non-UTF-8 manifest through the captured snapshot")
    func folderValidationRejectsInvalidUTF8Manifest() async throws {
        try await withTemporaryDirectory { root in
            let source = root.appendingPathComponent("invalid-utf8", isDirectory: true)
            try FileManager.default.createDirectory(at: source, withIntermediateDirectories: false)
            try Data([0xff, 0xfe]).write(to: source.appendingPathComponent("SKILL.md"))

            await #expect(throws: SkillImportValidationError.self) {
                _ = try await SkillImportWorker().validateFolder(source)
            }
        }
    }

    @Test("snapshot UTF-8 reads reject a manifest replaced after capture")
    func snapshotReadRejectsManifestReplacement() async throws {
        try await withTemporaryDirectory { root in
            let source = root.appendingPathComponent("replace-manifest", isDirectory: true)
            let manifest = source.appendingPathComponent("SKILL.md")
            let displaced = source.appendingPathComponent("original.md")
            try makeSkill(at: source, markdown: "# Original")
            let snapshot = try SkillContentSnapshot.capture(at: source)

            try FileManager.default.moveItem(at: manifest, to: displaced)
            try Data("# Replacement".utf8).write(to: manifest)

            #expect(throws: SkillContentSnapshotError.self) {
                _ = try snapshot.readUTF8File(relativePath: "SKILL.md")
            }
            #expect(try String(contentsOf: manifest, encoding: .utf8) == "# Replacement")
            #expect(try String(contentsOf: displaced, encoding: .utf8) == "# Original")
        }
    }

    @Test("zip validation captures the complete Skill snapshot")
    func zipValidationCapturesSnapshot() async throws {
        try await withTemporaryDirectory { root in
            let archiveURL = root.appendingPathComponent("skill.zip")
            try writeArchive(at: archiveURL, entries: [
                ("archive-slug/SKILL.md", Data("# Archived".utf8)),
                ("archive-slug/icon.bin", Data([0x00, 0xff, 0x42])),
            ])

            let worker = SkillImportWorker()
            let candidate = try await worker.validateZip(archiveURL)
            let temporaryRoot = try #require(candidate.temporaryRoot)

            #expect(candidate.markdown == "# Archived")
            #expect(candidate.snapshot.files.map(\.relativePath) == [
                "SKILL.md", "icon.bin",
            ])
            #expect(candidate.snapshot.fingerprint == candidate.fingerprint)
            await worker.cleanupTemporaryRoot(temporaryRoot)
        }
    }

    @Test("zip worker entry rejects symbolic links before installation")
    func zipWorkerRejectsSymbolicLink() async throws {
        try await withTemporaryDirectory { root in
            let archiveURL = root.appendingPathComponent("unsafe.zip")
            try writeArchive(at: archiveURL, entries: [
                ("unsafe/SKILL.md", Data("# Unsafe".utf8)),
            ])
            try addSymbolicLink(
                to: archiveURL,
                path: "unsafe/outside-link",
                destination: "../../outside"
            )

            await #expect(throws: SkillImportValidationError.self) {
                _ = try await SkillImportWorker().validateZip(archiveURL)
            }
            #expect(!FileManager.default.fileExists(atPath: root.appendingPathComponent("outside").path))
        }
    }

    @Test("zip candidate cleanup preserves a replacement at the leased name")
    func zipCandidateCleanupPreservesReplacement() async throws {
        try await withTemporaryDirectory { root in
            let archiveURL = root.appendingPathComponent("candidate.zip")
            try writeArchive(at: archiveURL, entries: [
                ("candidate/SKILL.md", Data("# Candidate".utf8)),
            ])

            let worker = SkillImportWorker()
            let candidate = try await worker.validateZip(archiveURL)
            let lease = try #require(candidate.temporaryRoot)
            let displaced = lease.url.deletingLastPathComponent().appendingPathComponent(
                "displaced-\(UUID().uuidString.lowercased())",
                isDirectory: true
            )
            let sentinel = lease.url.appendingPathComponent("replacement.txt")
            defer {
                try? FileManager.default.removeItem(at: lease.url)
                try? FileManager.default.removeItem(at: displaced)
            }

            try FileManager.default.moveItem(at: lease.url, to: displaced)
            try FileManager.default.createDirectory(
                at: lease.url,
                withIntermediateDirectories: false
            )
            try Data("replacement".utf8).write(to: sentinel)

            await worker.cleanupTemporaryRoot(lease)
            await worker.cleanupTemporaryRoot(lease)

            #expect(try String(contentsOf: sentinel, encoding: .utf8) == "replacement")
            #expect(FileManager.default.fileExists(atPath: displaced.path))
        }
    }

    @Test("zip cleanup cancels and awaits the active snapshot consumer")
    func zipCleanupAwaitsConsumer() async throws {
        try await withTemporaryDirectory { root in
            let archiveURL = root.appendingPathComponent("consumer.zip")
            try writeArchive(at: archiveURL, entries: [
                ("candidate/SKILL.md", Data("# Candidate".utf8)),
            ])

            let worker = SkillImportWorker()
            let candidate = try await worker.validateZip(archiveURL)
            let lease = try #require(candidate.temporaryRoot)
            let gate = ImportConsumerGate()
            let consumer = Task {
                await withTaskCancellationHandler {
                    await gate.waitForRelease()
                } onCancel: {
                    Task { await gate.recordCancellation() }
                }
            }
            #expect(await gate.waitUntilStarted())

            let cleanup = Task {
                await worker.cleanupTemporaryRoot(
                    lease,
                    afterCancelling: consumer
                )
            }
            #expect(await gate.waitUntilCancelled())
            #expect(FileManager.default.fileExists(atPath: lease.url.path))

            await gate.release()
            await cleanup.value
            #expect(!FileManager.default.fileExists(atPath: lease.url.path))
        }
    }

    @Test("zip validation remains anchored when the temporary root name is replaced")
    func zipValidationUsesAnchoredTemporaryRoot() async throws {
        try await withTemporaryDirectory { root in
            let archiveURL = root.appendingPathComponent("anchored.zip")
            let displaced = FileManager.default.temporaryDirectory.appendingPathComponent(
                "displaced-import-\(UUID().uuidString.lowercased())",
                isDirectory: true
            )
            try writeArchive(at: archiveURL, entries: [
                ("original-skill/SKILL.md", Data("# Original".utf8)),
            ])

            let worker = SkillImportWorker()
            let candidate = try await worker.validateZip(
                archiveURL,
                afterExtraction: { lease in
                    try FileManager.default.moveItem(at: lease.url, to: displaced)
                    let replacement = lease.url.appendingPathComponent(
                        "replacement-skill",
                        isDirectory: true
                    )
                    try FileManager.default.createDirectory(
                        at: replacement,
                        withIntermediateDirectories: true
                    )
                    try Data("# Replacement".utf8).write(
                        to: replacement.appendingPathComponent("SKILL.md")
                    )
                }
            )
            let lease = try #require(candidate.temporaryRoot)
            defer {
                try? FileManager.default.removeItem(at: lease.url)
                try? FileManager.default.removeItem(at: displaced)
            }

            let original = displaced.appendingPathComponent("original-skill", isDirectory: true)
            let originalFingerprint = try SkillContentSnapshot.capture(at: original).fingerprint
            try candidate.requireSourceUnchanged()
            #expect(candidate.skillName == "original-skill")
            #expect(candidate.markdown == "# Original")
            #expect(candidate.fingerprint == originalFingerprint)
            #expect(try String(
                contentsOf: lease.url.appendingPathComponent("replacement-skill/SKILL.md"),
                encoding: .utf8
            ) == "# Replacement")
        }
    }

    @Test("preview worker does not delete an archive it does not own")
    func previewWorkerPreservesArchive() async throws {
        try await withTemporaryDirectory { root in
            let archiveURL = root.appendingPathComponent("preview.zip")
            try writeArchive(at: archiveURL, entries: [
                ("preview/SKILL.md", Data("# Preview".utf8)),
            ])

            let markdown = try await SkillFileWorker().loadRawMarkdown(from: archiveURL)

            #expect(markdown == "# Preview")
            #expect(FileManager.default.fileExists(atPath: archiveURL.path))
        }
    }

    private func makeSkill(at root: URL, markdown: String) throws {
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try markdown.write(
            to: root.appendingPathComponent("SKILL.md"),
            atomically: true,
            encoding: .utf8
        )
    }

    private func writeArchive(
        at url: URL,
        entries: [(String, Data)],
        permissions: UInt16 = 0o644
    ) throws {
        let archive = try Archive(url: url, accessMode: .create)
        for (path, contents) in entries {
            try archive.addEntry(
                with: path,
                type: .file,
                uncompressedSize: Int64(contents.count),
                permissions: permissions
            ) { position, size in
                let start = Int(position)
                return contents.subdata(in: start..<min(start + size, contents.count))
            }
        }
    }

    private func addSymbolicLink(to url: URL, path: String, destination: String) throws {
        let archive = try Archive(url: url, accessMode: .update)
        let contents = Data(destination.utf8)
        try archive.addEntry(
            with: path,
            type: .symlink,
            uncompressedSize: Int64(contents.count)
        ) { position, size in
            let start = Int(position)
            return contents.subdata(in: start..<min(start + size, contents.count))
        }
    }

    private func withTemporaryDirectory(
        _ body: (URL) async throws -> Void
    ) async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("safe-import-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try await body(root)
    }
}

private actor ImportConsumerGate {
    private var continuation: CheckedContinuation<Void, Never>?
    private var started = false
    private var cancelled = false

    func waitForRelease() async {
        await withCheckedContinuation {
            continuation = $0
            started = true
        }
    }

    func recordCancellation() { cancelled = true }

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

    private func waitUntil(_ condition: () -> Bool) async -> Bool {
        for _ in 0..<10_000 {
            if condition() { return true }
            await Task.yield()
        }
        return false
    }
}
