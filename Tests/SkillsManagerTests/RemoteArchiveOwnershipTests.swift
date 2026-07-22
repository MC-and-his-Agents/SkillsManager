import Foundation
import Testing
import ZIPFoundation

@testable import SkillsManager

@Suite("Remote archive ownership")
struct RemoteArchiveOwnershipTests {
    @Test("owned preview archive is removed after success")
    func ownedPreviewSuccessCleansArchive() async throws {
        try await withTemporaryDirectory { root in
            let archiveURL = root.appendingPathComponent("preview.zip")
            try writeArchive(at: archiveURL, markdown: "# Preview")
            let archive = try DownloadedSkillArchive.takeOwnership(of: archiveURL)

            let markdown = try await SkillFileWorker().loadRawMarkdown(from: archive)

            #expect(markdown == "# Preview")
            #expect(!FileManager.default.fileExists(atPath: archiveURL.path))
        }
    }

    @Test("owned install archive is removed after success")
    func ownedInstallSuccessCleansArchive() async throws {
        try await withTemporaryDirectory { root in
            let archiveURL = root.appendingPathComponent("install.zip")
            let destination = root.appendingPathComponent("destination", isDirectory: true)
            try writeArchive(at: archiveURL, markdown: "# Install")
            let archive = try DownloadedSkillArchive.takeOwnership(of: archiveURL)

            _ = try await SkillFileWorker().installRemoteSkill(
                archive: archive,
                slug: "remote-skill",
                version: "1.0.0",
                destinations: [.init(rootURL: destination, storageKey: "target")]
            )

            #expect(!FileManager.default.fileExists(atPath: archiveURL.path))
            #expect(FileManager.default.fileExists(
                atPath: destination.appendingPathComponent("remote-skill/SKILL.md").path
            ))
        }
    }

    @Test("owned multi-target install rejects replacement before the second target")
    func ownedMultiTargetInstallRejectsLatePermissionReplacement() async throws {
        try await withTemporaryDirectory { root in
            let archiveURL = root.appendingPathComponent("owned.zip")
            let replacementURL = root.appendingPathComponent("replacement.zip")
            let displacedURL = root.appendingPathComponent("displaced.zip")
            let firstDestination = root.appendingPathComponent("first", isDirectory: true)
            let secondDestination = root.appendingPathComponent("second", isDirectory: true)
            try writeArchive(
                at: archiveURL,
                markdown: "# Same content",
                scriptPermissions: 0o644
            )
            try writeArchive(
                at: replacementURL,
                markdown: "# Same content",
                scriptPermissions: 0o755
            )
            let archive = try DownloadedSkillArchive.takeOwnership(of: archiveURL)

            var partialError: PartialSkillInstallError?
            do {
                _ = try await SkillFileWorker().installRemoteSkill(
                    archive: archive,
                    slug: "remote-skill",
                    version: "1.0.0",
                    destinations: [
                        .init(rootURL: firstDestination, storageKey: "first"),
                        .init(rootURL: secondDestination, storageKey: "second"),
                    ],
                    beforeDestinationInstall: { index, _ in
                        guard index == 1 else { return }
                        try FileManager.default.moveItem(at: archiveURL, to: displacedURL)
                        try FileManager.default.moveItem(at: replacementURL, to: archiveURL)
                    }
                )
                Issue.record("Expected the second destination to reject the replacement archive")
            } catch let error as PartialSkillInstallError {
                partialError = error
            }

            #expect(partialError?.installedStorageKeys == ["first"])
            #expect(partialError?.failedStorageKey == "second")
            #expect(FileManager.default.fileExists(atPath: archiveURL.path))
            #expect(FileManager.default.fileExists(atPath: displacedURL.path))
            #expect(FileManager.default.fileExists(
                atPath: firstDestination.appendingPathComponent("remote-skill/SKILL.md").path
            ))
            #expect(!FileManager.default.fileExists(
                atPath: secondDestination.appendingPathComponent("remote-skill").path
            ))
        }
    }

    @Test("owned archive is removed after validation failure")
    func ownedFailureCleansArchive() async throws {
        try await withTemporaryDirectory { root in
            let archiveURL = root.appendingPathComponent("invalid.zip")
            try Data("not a zip".utf8).write(to: archiveURL)
            let archive = try DownloadedSkillArchive.takeOwnership(of: archiveURL)

            await #expect(throws: SkillImportValidationError.self) {
                _ = try await SkillFileWorker().loadRawMarkdown(from: archive)
            }

            #expect(!FileManager.default.fileExists(atPath: archiveURL.path))
        }
    }

    @Test("owned archive is removed after cancellation")
    func ownedCancellationCleansArchive() async throws {
        try await withTemporaryDirectory { root in
            let archiveURL = root.appendingPathComponent("cancel.zip")
            try writeArchive(at: archiveURL, markdown: "# Cancel")
            let archive = try DownloadedSkillArchive.takeOwnership(of: archiveURL)
            let operation = Task {
                try await SkillFileWorker().loadRawMarkdown(
                    from: archive,
                    beforeManifestRead: {
                        withUnsafeCurrentTask { $0?.cancel() }
                    }
                )
            }

            await #expect(throws: CancellationError.self) {
                _ = try await operation.value
            }

            #expect(!FileManager.default.fileExists(atPath: archiveURL.path))
        }
    }

    @Test("owned archive rejects a replacement and preserves both objects")
    func ownedReplacementIsRejectedAndPreserved() async throws {
        try await withTemporaryDirectory { root in
            let archiveURL = root.appendingPathComponent("owned.zip")
            let displacedURL = root.appendingPathComponent("displaced.zip")
            try writeArchive(at: archiveURL, markdown: "# Original")
            let archive = try DownloadedSkillArchive.takeOwnership(of: archiveURL)
            try FileManager.default.moveItem(at: archiveURL, to: displacedURL)
            try writeArchive(at: archiveURL, markdown: "# Replacement")

            await #expect(throws: SkillImportValidationError.self) {
                _ = try await SkillFileWorker().loadRawMarkdown(from: archive)
            }

            #expect(FileManager.default.fileExists(atPath: archiveURL.path))
            #expect(FileManager.default.fileExists(atPath: displacedURL.path))
        }
    }

    @Test("borrowed archive is never removed")
    func borrowedArchiveIsPreserved() async throws {
        try await withTemporaryDirectory { root in
            let archiveURL = root.appendingPathComponent("borrowed.zip")
            try writeArchive(at: archiveURL, markdown: "# Borrowed")
            let archive = DownloadedSkillArchive(borrowedAt: archiveURL)

            _ = try await SkillFileWorker().loadRawMarkdown(from: archive)

            #expect(FileManager.default.fileExists(atPath: archiveURL.path))
        }
    }

    @Test("HTTP validation failure removes an owned download")
    func invalidHTTPResponseCleansArchive() throws {
        try withTemporaryDirectory { root in
            let archiveURL = root.appendingPathComponent("response.zip")
            try Data("temporary download".utf8).write(to: archiveURL)
            let response = try #require(HTTPURLResponse(
                url: URL(string: "https://example.invalid/archive.zip")!,
                statusCode: 500,
                httpVersion: nil,
                headerFields: nil
            ))

            #expect(throws: URLError.self) {
                _ = try checkedDownloadedArchive(at: archiveURL, response: response)
            }

            #expect(!FileManager.default.fileExists(atPath: archiveURL.path))
        }
    }

    private func writeArchive(
        at url: URL,
        markdown: String,
        scriptPermissions: UInt16 = 0o644
    ) throws {
        let manifest = Data(markdown.utf8)
        let script = Data("#!/bin/sh\nexit 0\n".utf8)
        let archive = try Archive(url: url, accessMode: .create)
        try archive.addEntry(
            with: "package/SKILL.md",
            type: .file,
            uncompressedSize: Int64(manifest.count),
            permissions: 0o644
        ) { position, size in
            let start = Int(position)
            return manifest.subdata(in: start..<min(start + size, manifest.count))
        }
        try archive.addEntry(
            with: "package/scripts/run.sh",
            type: .file,
            uncompressedSize: Int64(script.count),
            permissions: scriptPermissions
        ) { position, size in
            let start = Int(position)
            return script.subdata(in: start..<min(start + size, script.count))
        }
    }

    private func withTemporaryDirectory<T>(
        _ body: (URL) async throws -> T
    ) async throws -> T {
        let root = makeTemporaryDirectoryURL()
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: root) }
        return try await body(root)
    }

    private func withTemporaryDirectory<T>(
        _ body: (URL) throws -> T
    ) throws -> T {
        let root = makeTemporaryDirectoryURL()
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: root) }
        return try body(root)
    }

    private func makeTemporaryDirectoryURL() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent(
            "remote-archive-ownership-tests-\(UUID().uuidString.lowercased())",
            isDirectory: true
        )
    }
}
