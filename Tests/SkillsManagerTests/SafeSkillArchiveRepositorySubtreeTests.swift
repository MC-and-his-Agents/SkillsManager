import CryptoKit
import Darwin
import Foundation
import Testing
import ZIPFoundation

@testable import SkillsManager

@Suite("Safe repository subtree archive extraction")
struct SafeSkillArchiveRepositorySubtreeTests {
    @Test("Extracts only the verified subtree and captures a snapshot")
    func extractsVerifiedSubtree() async throws {
        try await withFixture { fixture in
            let manifest = Data("# Verified".utf8)
            let icon = Data([0x00, 0xff, 0x42])
            try fixture.write([
                .directory("owner-repo-commit/"),
                .file("owner-repo-commit/README.md", Data("outside".utf8)),
                .file("owner-repo-commit/skills/demo/SKILL.md", manifest),
                .file("owner-repo-commit/skills/demo/icon.bin", icon, permissions: 0o755),
            ])
            let worker = SkillImportWorker()
            let candidate = try await worker.validateZip(
                fixture.archiveURL,
                repositorySubpath: try RepositorySubpath("skills/demo"),
                expectedBlobs: [
                    try expectation("SKILL.md", manifest),
                    try expectation("icon.bin", icon, mode: "100755"),
                ]
            )
            let lease = try #require(candidate.temporaryRoot)

            #expect(candidate.skillName == "demo")
            #expect(candidate.markdown == "# Verified")
            #expect(candidate.snapshot.files.map(\.relativePath) == ["SKILL.md", "icon.bin"])
            #expect(!FileManager.default.fileExists(
                atPath: candidate.rootURL.appendingPathComponent("README.md").path
            ))
            await worker.cleanupTemporaryRoot(lease)
        }
    }

    @Test(
        "Rejects a target file set, size, mode, or Git blob mismatch",
        arguments: Mismatch.allCases
    )
    func rejectsEvidenceMismatch(_ mismatch: Mismatch) throws {
        try withFixture { fixture in
            let manifest = Data("# Verified".utf8)
            let extra = Data("extra".utf8)
            try fixture.write([
                .file("wrapper/skills/demo/SKILL.md", manifest),
                .file("wrapper/skills/demo/extra.txt", extra),
            ])
            var expected = [
                try expectation("SKILL.md", manifest),
                try expectation("extra.txt", extra),
            ]
            switch mismatch {
            case .missing: expected.removeLast()
            case .size:
                expected[0] = try expectation("SKILL.md", manifest, byteCount: UInt64(manifest.count + 1))
            case .mode:
                expected[0] = try expectation("SKILL.md", manifest, mode: "100755")
            case .hash:
                expected[0] = try SafeSkillArchive.RepositoryBlobExpectation(
                    relativePath: "SKILL.md",
                    mode: "100644",
                    byteCount: UInt64(manifest.count),
                    gitBlobSHA: String(repeating: "0", count: 40)
                )
            }

            try expectRejected(fixture, expected: expected)
        }
    }

    @Test("Rejects multiple wrappers and special entries anywhere in the archive")
    func rejectsInvalidCentralDirectory() throws {
        for entries in [
            [
                ArchiveItem.file("first/skills/demo/SKILL.md", Data("# Demo".utf8)),
                .file("second/README.md", Data()),
            ],
            [
                ArchiveItem.file("wrapper/skills/demo/SKILL.md", Data("# Demo".utf8)),
                .symbolicLink("wrapper/outside", "../escape"),
            ],
        ] {
            try withFixture { fixture in
                try fixture.write(entries)
                try expectRejected(
                    fixture,
                    expected: [try expectation("SKILL.md", Data("# Demo".utf8))]
                )
            }
        }
    }

    @Test("Rejects archive and expectation collisions or prefix conflicts")
    func rejectsCollisions() throws {
        try withFixture { fixture in
            let manifest = Data("# Demo".utf8)
            try fixture.write([
                .file("wrapper/skills/demo/SKILL.md", manifest),
                .file("wrapper/skills/demo/Cafe\u{301}.txt", Data()),
                .file("wrapper/skills/demo/CAFÉ.txt", Data()),
            ])
            try expectRejected(
                fixture,
                expected: [try expectation("SKILL.md", manifest)]
            )
        }

        let manifest = Data("# Demo".utf8)
        let valid = try expectation("SKILL.md", manifest)
        let duplicate = [valid, valid]
        #expect(throws: SafeSkillArchiveError.invalidRepositorySubtree) {
            _ = try validatedFixtureExtraction(expected: duplicate)
        }

        let prefix = [
            valid,
            try expectation("nested", Data()),
            try expectation("nested/file", Data()),
        ]
        #expect(throws: SafeSkillArchiveError.invalidRepositorySubtree) {
            _ = try validatedFixtureExtraction(expected: prefix)
        }
    }

    @Test("Cancellation rolls back selected files")
    func cancellationRollsBack() throws {
        try withFixture { fixture in
            let manifest = Data("# Demo".utf8)
            let payload = Data(repeating: 7, count: 256 * 1_024)
            try fixture.write([
                .file("wrapper/skills/demo/SKILL.md", manifest),
                .file("wrapper/skills/demo/payload.bin", payload),
            ])
            let descriptor = try fixture.openDestination()
            defer { Darwin.close(descriptor) }

            #expect(throws: CancellationError.self) {
                _ = try SafeSkillArchive().extractRepositorySubtree(
                    archiveAt: fixture.archiveURL,
                    repositorySubpath: try RepositorySubpath("skills/demo"),
                    expectedBlobs: [
                        try expectation("SKILL.md", manifest),
                        try expectation("payload.bin", payload),
                    ],
                    toDirectoryDescriptor: descriptor,
                    checkpoint: {
                        if FileManager.default.fileExists(
                            atPath: fixture.destinationURL.appendingPathComponent("SKILL.md").path
                        ) {
                            throw CancellationError()
                        }
                    }
                )
            }
            #expect(try FileManager.default.contentsOfDirectory(
                atPath: fixture.destinationURL.path
            ).isEmpty)
        }
    }

    enum Mismatch: CaseIterable, Sendable {
        case missing, size, mode, hash
    }

    private func expectRejected(
        _ fixture: RepositoryArchiveFixture,
        expected: [SafeSkillArchive.RepositoryBlobExpectation]
    ) throws {
        let descriptor = try fixture.openDestination()
        defer { Darwin.close(descriptor) }
        #expect(throws: SafeSkillArchiveError.self) {
            _ = try SafeSkillArchive().extractRepositorySubtree(
                archiveAt: fixture.archiveURL,
                repositorySubpath: try RepositorySubpath("skills/demo"),
                expectedBlobs: expected,
                toDirectoryDescriptor: descriptor
            )
        }
        #expect(try FileManager.default.contentsOfDirectory(
            atPath: fixture.destinationURL.path
        ).isEmpty)
    }

    private func validatedFixtureExtraction(
        expected: [SafeSkillArchive.RepositoryBlobExpectation]
    ) throws -> [String] {
        let fixture = try RepositoryArchiveFixture()
        defer { fixture.remove() }
        try fixture.write([
            .file("wrapper/skills/demo/SKILL.md", Data("# Demo".utf8)),
        ])
        let descriptor = try fixture.openDestination()
        defer { Darwin.close(descriptor) }
        return try SafeSkillArchive().extractRepositorySubtree(
            archiveAt: fixture.archiveURL,
            repositorySubpath: try RepositorySubpath("skills/demo"),
            expectedBlobs: expected,
            toDirectoryDescriptor: descriptor
        )
    }

    private func expectation(
        _ relativePath: String,
        _ contents: Data,
        mode: String = "100644",
        byteCount: UInt64? = nil
    ) throws -> SafeSkillArchive.RepositoryBlobExpectation {
        var hasher = Insecure.SHA1()
        hasher.update(data: Data("blob \(contents.count)\0".utf8))
        hasher.update(data: contents)
        let digest = Data(hasher.finalize()).map { String(format: "%02x", $0) }.joined()
        return try SafeSkillArchive.RepositoryBlobExpectation(
            relativePath: relativePath,
            mode: mode,
            byteCount: byteCount ?? UInt64(contents.count),
            gitBlobSHA: digest
        )
    }

    private func withFixture(_ body: (RepositoryArchiveFixture) throws -> Void) throws {
        let fixture = try RepositoryArchiveFixture()
        defer { fixture.remove() }
        try body(fixture)
    }

    private func withFixture(
        _ body: (RepositoryArchiveFixture) async throws -> Void
    ) async throws {
        let fixture = try RepositoryArchiveFixture()
        defer { fixture.remove() }
        try await body(fixture)
    }
}

private enum ArchiveItem {
    case file(String, Data, permissions: UInt16 = 0o644)
    case directory(String)
    case symbolicLink(String, String)
}

private struct RepositoryArchiveFixture {
    let rootURL: URL
    let archiveURL: URL
    let destinationURL: URL

    init() throws {
        rootURL = FileManager.default.temporaryDirectory.appendingPathComponent(
            "repository-subtree-tests-\(UUID().uuidString)",
            isDirectory: true
        )
        archiveURL = rootURL.appendingPathComponent("fixture.zip")
        destinationURL = rootURL.appendingPathComponent("destination", isDirectory: true)
        try FileManager.default.createDirectory(at: destinationURL, withIntermediateDirectories: true)
    }

    func write(_ items: [ArchiveItem]) throws {
        let archive = try Archive(url: archiveURL, accessMode: .create)
        for item in items {
            let path: String
            let contents: Data
            let type: Entry.EntryType
            let permissions: UInt16?
            switch item {
            case let .file(value, data, valuePermissions):
                (path, contents, type, permissions) = (value, data, .file, valuePermissions)
            case let .directory(value):
                (path, contents, type, permissions) = (value, Data(), .directory, 0o755)
            case let .symbolicLink(value, destination):
                (path, contents, type, permissions) = (value, Data(destination.utf8), .symlink, nil)
            }
            try archive.addEntry(
                with: path,
                type: type,
                uncompressedSize: Int64(contents.count),
                permissions: permissions
            ) { position, size in
                let start = Int(position)
                return contents.subdata(in: start..<min(start + size, contents.count))
            }
        }
    }

    func openDestination() throws -> Int32 {
        let descriptor = Darwin.open(
            destinationURL.path,
            O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC
        )
        guard descriptor >= 0 else { throw POSIXError(.EIO) }
        return descriptor
    }

    func remove() {
        try? FileManager.default.removeItem(at: rootURL)
    }
}
