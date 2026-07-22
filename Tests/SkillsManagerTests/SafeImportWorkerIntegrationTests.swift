import Foundation
import Testing
import ZIPFoundation

@testable import SkillsManager

@Suite("Safe import worker integration")
struct SafeImportWorkerIntegrationTests {
    @Test("a single-target folder import never moves the selected source")
    func singleTargetFolderImportRetainsSource() async throws {
        try await withTemporaryDirectory { root in
            let source = root.appendingPathComponent("source-slug", isDirectory: true)
            let destination = root.appendingPathComponent("destination", isDirectory: true)
            try makeSkill(at: source, markdown: "# Source")

            let worker = SkillImportWorker()
            let candidate = try await worker.validateFolder(source)
            try await worker.importCandidate(candidate, destinations: [
                .init(rootURL: destination, storageKey: "destination"),
            ])

            #expect(FileManager.default.fileExists(atPath: source.appendingPathComponent("SKILL.md").path))
            #expect(FileManager.default.fileExists(
                atPath: destination.appendingPathComponent("source-slug/SKILL.md").path
            ))
        }
    }

    @Test("folder imports retain the source and preserve one fingerprint across targets")
    func folderImportRetainsSource() async throws {
        try await withTemporaryDirectory { root in
            let source = root.appendingPathComponent("original-slug", isDirectory: true)
            let firstTarget = root.appendingPathComponent("first", isDirectory: true)
            let secondTarget = root.appendingPathComponent("second", isDirectory: true)
            try makeSkill(at: source, markdown: "# Original")

            let worker = SkillImportWorker()
            let candidate = try await worker.validateFolder(source)
            try await worker.importCandidate(candidate, destinations: [
                .init(rootURL: firstTarget, storageKey: "first"),
                .init(rootURL: secondTarget, storageKey: "second"),
            ])

            #expect(FileManager.default.fileExists(atPath: source.appendingPathComponent("SKILL.md").path))
            for destination in [firstTarget, secondTarget] {
                let installed = destination.appendingPathComponent("original-slug", isDirectory: true)
                #expect(try SkillContentSnapshot.capture(at: installed).fingerprint == candidate.fingerprint)
            }
        }
    }

    @Test("multi-target failure reports completed targets without hiding their state")
    func multiTargetFailureReportsCompletedTargets() async throws {
        try await withTemporaryDirectory { root in
            let source = root.appendingPathComponent("partial-slug", isDirectory: true)
            let firstTarget = root.appendingPathComponent("first", isDirectory: true)
            let invalidTarget = root.appendingPathComponent("not-a-directory")
            try makeSkill(at: source, markdown: "# Partial")
            try Data("file".utf8).write(to: invalidTarget)
            let worker = SkillImportWorker()
            let candidate = try await worker.validateFolder(source)

            do {
                try await worker.importCandidate(candidate, destinations: [
                    .init(rootURL: firstTarget, storageKey: "first"),
                    .init(rootURL: invalidTarget, storageKey: "second"),
                ])
                Issue.record("Expected the second destination to fail")
            } catch let error as PartialSkillInstallError {
                #expect(error.installedStorageKeys == ["first"])
                #expect(error.failedStorageKey == "second")
            }
            #expect(FileManager.default.fileExists(
                atPath: firstTarget.appendingPathComponent("partial-slug/SKILL.md").path
            ))
        }
    }

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

    @Test("zip validation and installation use the safe archive path")
    func zipImportUsesSafeArchive() async throws {
        try await withTemporaryDirectory { root in
            let archiveURL = root.appendingPathComponent("skill.zip")
            let destination = root.appendingPathComponent("destination", isDirectory: true)
            try writeArchive(at: archiveURL, entries: [
                ("archive-slug/SKILL.md", Data("# Archived".utf8)),
                ("archive-slug/icon.bin", Data([0x00, 0xff, 0x42])),
            ])

            let worker = SkillImportWorker()
            let candidate = try await worker.validateZip(archiveURL)
            try await worker.importCandidate(candidate, destinations: [
                .init(rootURL: destination, storageKey: "destination"),
            ])
            if let temporaryRoot = candidate.temporaryRoot {
                await worker.cleanupTemporaryRoot(temporaryRoot)
            }

            let installed = destination.appendingPathComponent("archive-slug", isDirectory: true)
            #expect(try SkillContentSnapshot.capture(at: installed).fingerprint == candidate.fingerprint)
            #expect(try Data(contentsOf: installed.appendingPathComponent("icon.bin")) == Data([0x00, 0xff, 0x42]))
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

    @Test("remote worker rejects a link archive without replacing the installed Skill")
    func remoteWorkerRejectsLinkWithoutReplacement() async throws {
        try await withTemporaryDirectory { root in
            let archiveURL = root.appendingPathComponent("unsafe-remote.zip")
            let destination = root.appendingPathComponent("destination", isDirectory: true)
            let existing = destination.appendingPathComponent("remote-slug", isDirectory: true)
            try makeSkill(at: existing, markdown: "# Existing")
            try writeArchive(at: archiveURL, entries: [
                ("unsafe/SKILL.md", Data("# Unsafe".utf8)),
            ])
            try addSymbolicLink(
                to: archiveURL,
                path: "unsafe/outside-link",
                destination: "../../outside"
            )

            await #expect(throws: SkillImportValidationError.self) {
                _ = try await SkillFileWorker().installRemoteSkill(
                    zipURL: archiveURL,
                    slug: "remote-slug",
                    version: "1.0.0",
                    destinations: [.init(rootURL: destination, storageKey: "destination")]
                )
            }
            #expect(try String(
                contentsOf: existing.appendingPathComponent("SKILL.md"),
                encoding: .utf8
            ) == "# Existing")
        }
    }

    @Test("remote installation writes Clawdhub metadata after safe staging")
    func remoteInstallWritesMetadata() async throws {
        try await withTemporaryDirectory { root in
            let archiveURL = root.appendingPathComponent("remote.zip")
            let destination = root.appendingPathComponent("destination", isDirectory: true)
            try writeArchive(at: archiveURL, entries: [
                ("package/SKILL.md", Data("# Remote".utf8)),
            ])

            let worker = SkillFileWorker()
            let selectedID = try await worker.installRemoteSkill(
                zipURL: archiveURL,
                slug: "remote-slug",
                version: "1.2.3",
                destinations: [.init(rootURL: destination, storageKey: "target")]
            )

            let installed = destination.appendingPathComponent("remote-slug", isDirectory: true)
            let metadataURL = installed.appendingPathComponent(".clawdhub/origin.json")
            let metadata = try JSONSerialization.jsonObject(with: Data(contentsOf: metadataURL)) as? [String: Any]
            #expect(selectedID == "target-remote-slug")
            #expect(metadata?["slug"] as? String == "remote-slug")
            #expect(metadata?["version"] as? String == "1.2.3")
            #expect(metadata?["source"] as? String == "clawdhub")
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

    private func writeArchive(at url: URL, entries: [(String, Data)]) throws {
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
