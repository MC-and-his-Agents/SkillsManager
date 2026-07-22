import Darwin
import Foundation
import Testing
import ZIPFoundation

@testable import SkillsManager

@Suite("Safe Skill Stager")
struct SafeSkillStagerTests {
    @Test("copies validated contents and promotes without a partial destination")
    func installsValidatedSkill() throws {
        try withTemporaryDirectory { root in
            let source = root.appendingPathComponent("source", isDirectory: true)
            let destination = root.appendingPathComponent("destination", isDirectory: true)
            try makeSkill(at: source, markdown: "# Example")
            let fingerprint = try SkillContentSnapshot.capture(at: source).fingerprint

            let installed = try SafeSkillStager().install(
                sourceRoot: source,
                expectedFingerprint: fingerprint,
                destinationRoot: destination,
                preferredName: "example",
                conflictPolicy: .replaceExisting
            )

            #expect(installed.lastPathComponent == "example")
            #expect(FileManager.default.fileExists(atPath: installed.appendingPathComponent("SKILL.md").path))
            #expect(try FileManager.default.contentsOfDirectory(atPath: destination.path).allSatisfy {
                !$0.hasPrefix(".skillsmanager-tmp-")
            })
        }
    }

    @Test("does not replace an existing destination when the source changes")
    func rejectsChangedSource() throws {
        try withTemporaryDirectory { root in
            let source = root.appendingPathComponent("source", isDirectory: true)
            let destination = root.appendingPathComponent("destination", isDirectory: true)
            let existing = destination.appendingPathComponent("example", isDirectory: true)
            try makeSkill(at: source, markdown: "# Before")
            try makeSkill(at: existing, markdown: "# Existing")
            let fingerprint = try SkillContentSnapshot.capture(at: source).fingerprint
            try "# After".write(
                to: source.appendingPathComponent("SKILL.md"),
                atomically: true,
                encoding: .utf8
            )

            #expect(throws: SafeSkillStagingError.self) {
                try SafeSkillStager().install(
                    sourceRoot: source,
                    expectedFingerprint: fingerprint,
                    destinationRoot: destination,
                    preferredName: "example",
                    conflictPolicy: .replaceExisting
                )
            }
            #expect(try String(contentsOf: existing.appendingPathComponent("SKILL.md"), encoding: .utf8) == "# Existing")
            #expect(try FileManager.default.contentsOfDirectory(atPath: destination.path).allSatisfy {
                !$0.hasPrefix(".skillsmanager-tmp-")
            })
        }
    }

    @Test("chooses a normalization-safe unique destination")
    func choosesUniqueDestination() throws {
        try withTemporaryDirectory { root in
            let source = root.appendingPathComponent("source", isDirectory: true)
            let destination = root.appendingPathComponent("destination", isDirectory: true)
            try makeSkill(at: source, markdown: "# New")
            try makeSkill(at: destination.appendingPathComponent("Example", isDirectory: true), markdown: "# Old")
            let fingerprint = try SkillContentSnapshot.capture(at: source).fingerprint

            let installed = try SafeSkillStager().install(
                sourceRoot: source,
                expectedFingerprint: fingerprint,
                destinationRoot: destination,
                preferredName: "example",
                conflictPolicy: .chooseUniqueName
            )

            #expect(installed.lastPathComponent == "example-1")
        }
    }

    @Test("copies only approved files and strips unsafe permission bits")
    func excludesMetadataAndUnsafeEntries() throws {
        try withTemporaryDirectory { root in
            let source = root.appendingPathComponent("source", isDirectory: true)
            let destination = root.appendingPathComponent("destination", isDirectory: true)
            try makeSkill(at: source, markdown: "# Safe")
            let skillFile = source.appendingPathComponent("SKILL.md")
            #expect(Darwin.chmod(skillFile.path, mode_t(0o6755)) == 0)

            let metadata = source.appendingPathComponent(".git", isDirectory: true)
            try FileManager.default.createDirectory(at: metadata, withIntermediateDirectories: true)
            let oversized = metadata.appendingPathComponent("oversized")
            #expect(FileManager.default.createFile(atPath: oversized.path, contents: nil))
            #expect(Darwin.truncate(oversized.path, off_t(129 * 1_024 * 1_024)) == 0)
            try FileManager.default.createSymbolicLink(
                at: metadata.appendingPathComponent("outside"),
                withDestinationURL: root
            )
            try FileManager.default.createSymbolicLink(
                at: source.appendingPathComponent(".skillsmanager.json"),
                withDestinationURL: root
            )

            let fingerprint = try SkillContentSnapshot.capture(at: source).fingerprint
            let installed = try SafeSkillStager().install(
                sourceRoot: source,
                expectedFingerprint: fingerprint,
                destinationRoot: destination,
                preferredName: "safe",
                conflictPolicy: .replaceExisting
            )

            #expect(!FileManager.default.fileExists(atPath: installed.appendingPathComponent(".git").path))
            #expect(!FileManager.default.fileExists(
                atPath: installed.appendingPathComponent(".skillsmanager.json").path
            ))
            var status = stat()
            let installedStatus = installed.appendingPathComponent("SKILL.md").path.withCString {
                Darwin.lstat($0, &status)
            }
            #expect(installedStatus == 0)
            #expect(status.st_mode & mode_t(0o7777) == mode_t(0o755))
        }
    }

    @Test("cancellation during streaming copy removes staging")
    func cancellationCleansStaging() throws {
        try withTemporaryDirectory { root in
            let source = root.appendingPathComponent("source", isDirectory: true)
            let destination = root.appendingPathComponent("destination", isDirectory: true)
            try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
            try Data(repeating: 0x41, count: 256 * 1_024).write(
                to: source.appendingPathComponent("SKILL.md")
            )
            let fingerprint = try SkillContentSnapshot.capture(at: source).fingerprint

            #expect(throws: CancellationError.self) {
                try SafeSkillStager().install(
                    sourceRoot: source,
                    expectedFingerprint: fingerprint,
                    destinationRoot: destination,
                    preferredName: "cancelled",
                    conflictPolicy: .replaceExisting,
                    checkpoint: {
                        if try hasPartiallyCopiedFile(in: destination) {
                            throw CancellationError()
                        }
                    }
                )
            }
            #expect(try FileManager.default.contentsOfDirectory(atPath: destination.path).isEmpty)
        }
    }

    @Test("registered managed root cannot authorize another destination")
    func rejectsMismatchedManagedRoot() throws {
        try withTemporaryDirectory { root in
            let source = root.appendingPathComponent("source")
            let registered = root.appendingPathComponent("registered")
            let other = root.appendingPathComponent("other")
            try makeSkill(at: source, markdown: "# Managed")
            try FileManager.default.createDirectory(at: registered, withIntermediateDirectories: true)
            try FileManager.default.createDirectory(at: other, withIntermediateDirectories: true)
            let fingerprint = try SkillContentSnapshot.capture(at: source).fingerprint
            let managedRoot = try ManagedRootReference.capture(at: registered)

            #expect(throws: SafeSkillStagingError.destinationRootMismatch) {
                try SafeSkillStager().install(
                    sourceRoot: source,
                    expectedFingerprint: fingerprint,
                    destinationRoot: other,
                    preferredName: "managed",
                    conflictPolicy: .replaceExisting,
                    managedRoot: managedRoot
                )
            }
            #expect(try FileManager.default.contentsOfDirectory(atPath: other.path).isEmpty)
        }
    }

    @Test("extracts a wrapped archive inside the managed root before promotion")
    func installsArchiveFromManagedStaging() throws {
        try withTemporaryDirectory { root in
            let source = root.appendingPathComponent("source", isDirectory: true)
            let destination = root.appendingPathComponent("destination", isDirectory: true)
            let archiveURL = root.appendingPathComponent("example.zip")
            try makeSkill(at: source, markdown: "# Archived")
            let fingerprint = try SkillContentSnapshot.capture(at: source).fingerprint
            let contents = try Data(contentsOf: source.appendingPathComponent("SKILL.md"))
            let archive = try Archive(url: archiveURL, accessMode: .create)
            try archive.addEntry(
                with: "wrapper/SKILL.md",
                type: .file,
                uncompressedSize: Int64(contents.count)
            ) { position, size in
                let start = Int(position)
                return contents.subdata(in: start..<min(start + size, contents.count))
            }

            let installed = try SafeSkillStager().installArchive(
                archiveAt: archiveURL,
                expectedFingerprint: fingerprint,
                destinationRoot: destination,
                preferredName: "example",
                conflictPolicy: .replaceExisting
            )

            #expect(try String(
                contentsOf: installed.appendingPathComponent("SKILL.md"),
                encoding: .utf8
            ) == "# Archived")
            #expect(try FileManager.default.contentsOfDirectory(atPath: destination.path).allSatisfy {
                !$0.hasPrefix(".skillsmanager-tmp-")
            })
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

    private func hasPartiallyCopiedFile(in destination: URL) throws -> Bool {
        guard FileManager.default.fileExists(atPath: destination.path) else { return false }
        let staged = try FileManager.default.contentsOfDirectory(
            at: destination,
            includingPropertiesForKeys: nil
        ).first { $0.lastPathComponent.hasPrefix(".skillsmanager-tmp-") }
        guard let staged else { return false }
        let skillFile = staged.appendingPathComponent("SKILL.md")
        var status = stat()
        return skillFile.path.withCString { Darwin.lstat($0, &status) } == 0 && status.st_size > 0
    }

    private func withTemporaryDirectory(_ body: (URL) throws -> Void) throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try body(root)
    }
}
