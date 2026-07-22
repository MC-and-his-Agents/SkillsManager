import Foundation
import Testing
import ZIPFoundation

@testable import SkillsManager

@Suite("Import snapshot consistency")
struct ImportSnapshotConsistencyTests {
    @Test("folder import rejects permission drift after validation")
    func folderImportRejectsPermissionDrift() async throws {
        try await withTemporaryDirectory { root in
            let source = root.appendingPathComponent("permission-drift", isDirectory: true)
            let destination = root.appendingPathComponent("destination", isDirectory: true)
            try makeSkill(at: source)
            let script = source.appendingPathComponent("scripts/run.sh", isDirectory: false)
            try FileManager.default.createDirectory(
                at: script.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try Data("#!/bin/sh\nexit 0\n".utf8).write(to: script)
            try setPermissions(0o644, at: script)

            let worker = SkillImportWorker()
            let candidate = try await worker.validateFolder(source)
            try setPermissions(0o755, at: script)

            await #expect(throws: SkillContentSnapshotError.self) {
                _ = try await worker.importCandidate(candidate, destinations: [
                    .init(rootURL: destination, storageKey: "destination"),
                ])
            }
            #expect(!FileManager.default.fileExists(
                atPath: destination.appendingPathComponent("permission-drift").path
            ))
        }
    }

    @Test("zip import uses its validated snapshot after an in-place archive rewrite")
    func zipImportUsesValidatedSnapshotAfterInPlaceRewrite() async throws {
        try await withTemporaryDirectory { root in
            let archiveURL = root.appendingPathComponent("original.zip")
            let replacementURL = root.appendingPathComponent("replacement.zip")
            let destination = root.appendingPathComponent("destination", isDirectory: true)
            try writeArchive(at: archiveURL, permissions: 0o644)
            try writeArchive(at: replacementURL, permissions: 0o755)

            let worker = SkillImportWorker()
            let candidate = try await worker.validateZip(archiveURL)
            try overwriteFileInPlace(at: archiveURL, withContentsOf: replacementURL)

            _ = try await worker.importCandidate(candidate, destinations: [
                .init(rootURL: destination, storageKey: "destination"),
            ])
            if let temporaryRoot = candidate.temporaryRoot {
                await worker.cleanupTemporaryRoot(temporaryRoot)
            }

            #expect(FileManager.default.fileExists(atPath: archiveURL.path))
            let script = destination.appendingPathComponent(
                "archive-slug/scripts/run.sh",
                isDirectory: false
            )
            let permissions = try filePermissions(at: script)
            #expect(permissions & 0o111 == 0)
        }
    }

    private func makeSkill(at root: URL) throws {
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try Data("# Original".utf8).write(to: root.appendingPathComponent("SKILL.md"))
    }

    private func writeArchive(at url: URL, permissions: UInt16) throws {
        let entries = [
            ("archive-slug/SKILL.md", Data("# Archived".utf8)),
            ("archive-slug/scripts/run.sh", Data("#!/bin/sh\nexit 0\n".utf8)),
        ]
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

    private func overwriteFileInPlace(at destination: URL, withContentsOf source: URL) throws {
        let replacement = try Data(contentsOf: source)
        let handle = try FileHandle(forWritingTo: destination)
        defer { try? handle.close() }
        try handle.truncate(atOffset: 0)
        try handle.write(contentsOf: replacement)
        try handle.synchronize()
    }

    private func setPermissions(_ permissions: UInt16, at url: URL) throws {
        try FileManager.default.setAttributes(
            [.posixPermissions: permissions],
            ofItemAtPath: url.path
        )
    }

    private func filePermissions(at url: URL) throws -> UInt16 {
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        return try #require(attributes[.posixPermissions] as? NSNumber).uint16Value
    }

    private func withTemporaryDirectory(
        _ body: (URL) async throws -> Void
    ) async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(
            "import-snapshot-tests-\(UUID().uuidString.lowercased())",
            isDirectory: true
        )
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: root) }
        try await body(root)
    }
}
