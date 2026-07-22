import Foundation
import Testing
import ZIPFoundation
@testable import SkillsManager

@Suite("Safe skill archive extraction")
struct SafeSkillArchiveTests {
    @Test("Extracts regular directories, text, and binary bytes")
    func extractsValidBinaryArchive() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let binary = Data([0x00, 0xff, 0x80, 0x0a, 0x42])
        try fixture.writeArchive([
            .directory("example/"),
            .file("example/SKILL.md", Data("# Example".utf8)),
            .file("example/icon.bin", binary),
        ])

        let paths = try SafeSkillArchive().extract(archiveAt: fixture.archiveURL, to: fixture.destinationURL)

        #expect(Set(paths) == ["example", "example/SKILL.md", "example/icon.bin"])
        #expect(try Data(contentsOf: fixture.destinationURL.appendingPathComponent("example/icon.bin")) == binary)
    }

    @Test("Rejects parent traversal before writing any entry")
    func rejectsTraversal() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        try fixture.writeArchive([
            .file("safe.txt", Data("must be cleaned".utf8)),
            .file("../escaped.txt", Data("escape".utf8)),
        ])

        expectError(.unsafePath("../escaped.txt")) {
            try SafeSkillArchive().extract(archiveAt: fixture.archiveURL, to: fixture.destinationURL)
        }
        #expect(try FileManager.default.contentsOfDirectory(atPath: fixture.destinationURL.path).isEmpty)
        #expect(!FileManager.default.fileExists(atPath: fixture.rootURL.appendingPathComponent("escaped.txt").path))
    }

    @Test("Rejects absolute and Windows-style paths")
    func rejectsAbsolutePaths() throws {
        for path in ["/tmp/escaped-skill", "C:/escaped-skill", "folder\\..\\escaped-skill"] {
            let fixture = try Fixture()
            defer { fixture.remove() }
            try fixture.writeArchive([.file(path, Data())])

            expectError(.unsafePath(path)) {
                try SafeSkillArchive().extract(archiveAt: fixture.archiveURL, to: fixture.destinationURL)
            }
        }
    }

    @Test("Rejects symbolic links")
    func rejectsSymbolicLinks() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        try fixture.writeArchive([.symbolicLink("link", "../outside")])

        expectError(.unsupportedEntryType("link")) {
            try SafeSkillArchive().extract(archiveAt: fixture.archiveURL, to: fixture.destinationURL)
        }
        #expect(try FileManager.default.contentsOfDirectory(atPath: fixture.destinationURL.path).isEmpty)
    }

    @Test("Enforces entry, individual file, and total byte limits")
    func enforcesLimits() throws {
        let entryFixture = try Fixture()
        defer { entryFixture.remove() }
        try entryFixture.writeArchive([.file("a", Data()), .file("b", Data())])
        expectError(.tooManyEntries) {
            try SafeSkillArchive(limits: .init(maximumEntryCount: 1))
                .extract(archiveAt: entryFixture.archiveURL, to: entryFixture.destinationURL)
        }

        let fileFixture = try Fixture()
        defer { fileFixture.remove() }
        try fileFixture.writeArchive([.file("large", Data(repeating: 1, count: 4))])
        expectError(.fileTooLarge("large")) {
            try SafeSkillArchive(limits: .init(maximumFileSize: 3))
                .extract(archiveAt: fileFixture.archiveURL, to: fileFixture.destinationURL)
        }

        let totalFixture = try Fixture()
        defer { totalFixture.remove() }
        try totalFixture.writeArchive([
            .file("first", Data(repeating: 1, count: 2)),
            .file("second", Data(repeating: 2, count: 2)),
        ])
        expectError(.archiveTooLarge) {
            try SafeSkillArchive(limits: .init(maximumTotalSize: 3))
                .extract(archiveAt: totalFixture.archiveURL, to: totalFixture.destinationURL)
        }

        let fileCountFixture = try Fixture()
        defer { fileCountFixture.remove() }
        try fileCountFixture.writeArchive([
            .directory("folder/"),
            .file("folder/first", Data()),
        ])
        _ = try SafeSkillArchive(limits: .init(maximumEntryCount: 2, maximumFileCount: 1))
            .extract(archiveAt: fileCountFixture.archiveURL, to: fileCountFixture.destinationURL)

        let tooManyFilesFixture = try Fixture()
        defer { tooManyFilesFixture.remove() }
        try tooManyFilesFixture.writeArchive([.file("first", Data()), .file("second", Data())])
        expectError(.tooManyFiles) {
            try SafeSkillArchive(limits: .init(maximumFileCount: 1))
                .extract(archiveAt: tooManyFilesFixture.archiveURL, to: tooManyFilesFixture.destinationURL)
        }
    }

    @Test("Rejects NFC and case-insensitive path collisions")
    func rejectsNormalizedCollision() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let decomposed = "Cafe\u{301}.md"
        let composedUppercase = "CAFÉ.md"
        try fixture.writeArchive([
            .file(decomposed, Data()),
            .file(composedUppercase, Data()),
        ])

        expectError(.pathCollision(decomposed, composedUppercase)) {
            try SafeSkillArchive().extract(archiveAt: fixture.archiveURL, to: fixture.destinationURL)
        }
    }

    @Test("Rejects case-only collisions in implicit parent directories")
    func rejectsImplicitParentCollision() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        try fixture.writeArchive([
            .file("Folder/one.md", Data()),
            .file("folder/two.md", Data()),
        ])

        expectError(.pathCollision("Folder/one.md", "folder/two.md")) {
            try SafeSkillArchive().extract(archiveAt: fixture.archiveURL, to: fixture.destinationURL)
        }
        #expect(try FileManager.default.contentsOfDirectory(atPath: fixture.destinationURL.path).isEmpty)
    }

    @Test("Does not follow an intermediate directory replaced by a symbolic link")
    func rejectsReplacedIntermediateDirectory() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let outside = fixture.rootURL.appendingPathComponent("outside", isDirectory: true)
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: false)
        let sentinel = outside.appendingPathComponent("keep.txt")
        try Data("keep".utf8).write(to: sentinel)
        try fixture.writeArchive([
            .directory("inside/"),
            .file("inside/escaped.txt", Data("escape".utf8)),
        ])

        #expect(throws: (any Error).self) {
            try SafeSkillArchive().extract(
                archiveAt: fixture.archiveURL,
                to: fixture.destinationURL,
                beforeEntry: { components in
                    guard components == ["inside", "escaped.txt"] else { return }
                    let inside = fixture.destinationURL.appendingPathComponent("inside")
                    try FileManager.default.removeItem(at: inside)
                    try FileManager.default.createSymbolicLink(at: inside, withDestinationURL: outside)
                }
            )
        }
        #expect(!FileManager.default.fileExists(atPath: outside.appendingPathComponent("escaped.txt").path))
        #expect(FileManager.default.fileExists(atPath: sentinel.path))
        #expect(try FileManager.default.contentsOfDirectory(atPath: fixture.destinationURL.path).isEmpty)
    }

    @Test("Cancellation removes partially extracted content")
    func cancellationCleansDestination() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        try fixture.writeArchive([
            .directory("inside/"),
            .file("inside/file.bin", Data(repeating: 1, count: 128 * 1_024)),
        ])
        var cancelDuringFile = false

        #expect(throws: CancellationError.self) {
            try SafeSkillArchive().extract(
                archiveAt: fixture.archiveURL,
                to: fixture.destinationURL,
                checkpoint: {
                    if cancelDuringFile { throw CancellationError() }
                },
                beforeEntry: { components in
                    if components == ["inside", "file.bin"] { cancelDuringFile = true }
                }
            )
        }
        #expect(try FileManager.default.contentsOfDirectory(atPath: fixture.destinationURL.path).isEmpty)
    }

    private func expectError(
        _ expected: SafeSkillArchiveError,
        sourceLocation: SourceLocation = #_sourceLocation,
        _ operation: () throws -> Void
    ) {
        do {
            try operation()
            Issue.record("Expected \(expected)", sourceLocation: sourceLocation)
        } catch let error as SafeSkillArchiveError {
            #expect(error == expected, sourceLocation: sourceLocation)
        } catch {
            Issue.record("Unexpected error: \(error)", sourceLocation: sourceLocation)
        }
    }
}

private struct Fixture {
    enum Item {
        case file(String, Data)
        case directory(String)
        case symbolicLink(String, String)
    }

    let rootURL: URL
    let archiveURL: URL
    let destinationURL: URL

    init() throws {
        rootURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("safe-archive-tests-\(UUID().uuidString)", isDirectory: true)
        archiveURL = rootURL.appendingPathComponent("fixture.zip")
        destinationURL = rootURL.appendingPathComponent("destination", isDirectory: true)
        try FileManager.default.createDirectory(at: destinationURL, withIntermediateDirectories: true)
    }

    func writeArchive(_ items: [Item]) throws {
        let archive = try Archive(url: archiveURL, accessMode: .create)
        for item in items {
            switch item {
            case let .file(path, contents):
                try add(path: path, type: .file, contents: contents, to: archive)
            case let .directory(path):
                try add(path: path, type: .directory, contents: Data(), to: archive)
            case let .symbolicLink(path, destination):
                try add(path: path, type: .symlink, contents: Data(destination.utf8), to: archive)
            }
        }
    }

    func remove() {
        try? FileManager.default.removeItem(at: rootURL)
    }

    private func add(path: String, type: Entry.EntryType, contents: Data, to archive: Archive) throws {
        try archive.addEntry(with: path, type: type, uncompressedSize: Int64(contents.count)) { position, size in
            let start = Int(position)
            return contents.subdata(in: start..<min(start + size, contents.count))
        }
    }
}
