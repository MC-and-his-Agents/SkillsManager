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

    @Test("Counts explicit and implicit directories once during preflight")
    func enforcesDirectoryCountLimit() throws {
        let accepted = try Fixture()
        defer { accepted.remove() }
        try accepted.writeArchive([
            .directory("one/"),
            .file("one/two/SKILL.md", Data()),
        ])
        _ = try SafeSkillArchive(limits: .init(maximumDirectoryCount: 2))
            .extract(archiveAt: accepted.archiveURL, to: accepted.destinationURL)

        let rejected = try Fixture()
        defer { rejected.remove() }
        try rejected.writeArchive([
            .directory("one/"),
            .directory("two/"),
            .directory("three/"),
        ])
        expectError(.tooManyDirectories) {
            try SafeSkillArchive(limits: .init(maximumDirectoryCount: 2))
                .extract(archiveAt: rejected.archiveURL, to: rejected.destinationURL)
        }
        #expect(try FileManager.default.contentsOfDirectory(atPath: rejected.destinationURL.path).isEmpty)
    }

    @Test("Rejects deep archive paths before staging content")
    func enforcesPathDepthLimit() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let path = "one/two/SKILL.md"
        try fixture.writeArchive([.file(path, Data())])

        expectError(.pathTooDeep(path)) {
            try SafeSkillArchive(limits: .init(maximumPathDepth: 2))
                .extract(archiveAt: fixture.archiveURL, to: fixture.destinationURL)
        }
        #expect(try FileManager.default.contentsOfDirectory(atPath: fixture.destinationURL.path).isEmpty)
    }

    @Test("Rejects an oversized ZIP64 declaration before enumerating entries")
    func rejectsOversizedZIP64DeclarationBeforeEnumeration() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        try fixture.writeZIP64Declaration(entryCount: 50_001)
        var completedPreflight = false

        expectError(.tooManyEntries) {
            try SafeSkillArchive().extract(
                archiveAt: fixture.archiveURL,
                to: fixture.destinationURL,
                afterPreflight: { completedPreflight = true }
            )
        }

        #expect(!completedPreflight)
        #expect(try FileManager.default.contentsOfDirectory(atPath: fixture.destinationURL.path).isEmpty)
    }

    @Test("Rejects a shadow end record that the ZIP consumer would select")
    func rejectsShadowEndRecordInComment() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        try fixture.writeShadowEndRecordInComment()

        expectError(.invalidArchive) {
            try SafeSkillArchive().extract(
                archiveAt: fixture.archiveURL,
                to: fixture.destinationURL
            )
        }

        #expect(try FileManager.default.contentsOfDirectory(atPath: fixture.destinationURL.path).isEmpty)
    }

    @Test("Rejects ZIP64 extensible records unsupported by the ZIP consumer")
    func rejectsExtensibleZIP64Record() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        try fixture.writeZIP64Declaration(entryCount: 0, recordSize: 45)

        expectError(.invalidArchive) {
            try SafeSkillArchive().extract(
                archiveAt: fixture.archiveURL,
                to: fixture.destinationURL
            )
        }

        #expect(try FileManager.default.contentsOfDirectory(atPath: fixture.destinationURL.path).isEmpty)
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

    @Test("Failed ZIP entry cleanup preserves a concurrently replaced file")
    func failedEntryCleanupPreservesConcurrentReplacement() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let original = fixture.destinationURL.appendingPathComponent("entry")
        let displaced = fixture.destinationURL.appendingPathComponent("displaced")
        try Data("original".utf8).write(to: original)
        let descriptor = Darwin.open(original.path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
        #expect(descriptor >= 0)
        defer { Darwin.close(descriptor) }
        var metadata = stat()
        #expect(Darwin.fstat(descriptor, &metadata) == 0)
        let expectedIdentity = ManagedItemIdentity(metadata)
        let parent = Darwin.open(
            fixture.destinationURL.path,
            O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC
        )
        #expect(parent >= 0)
        defer { Darwin.close(parent) }

        try FileManager.default.moveItem(at: original, to: displaced)
        try Data("concurrent".utf8).write(to: original)

        #expect(!unlinkCreatedFileIfUnchanged(
            named: original.lastPathComponent,
            in: parent,
            expectedIdentity: expectedIdentity
        ))
        #expect(try String(contentsOf: original, encoding: .utf8) == "concurrent")
        #expect(try String(contentsOf: displaced, encoding: .utf8) == "original")
    }

    @Test("Atomic cleanup preserves a replacement created before unlink")
    func atomicCleanupPreservesReplacementInUnlinkWindow() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let original = fixture.destinationURL.appendingPathComponent("entry")
        try Data("original".utf8).write(to: original)
        let descriptor = Darwin.open(original.path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
        #expect(descriptor >= 0)
        defer { Darwin.close(descriptor) }
        var metadata = stat()
        #expect(Darwin.fstat(descriptor, &metadata) == 0)
        let expectedIdentity = ManagedItemIdentity(metadata)
        let parent = Darwin.open(
            fixture.destinationURL.path,
            O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC
        )
        #expect(parent >= 0)
        defer { Darwin.close(parent) }

        #expect(unlinkCreatedFileIfUnchanged(
            named: original.lastPathComponent,
            in: parent,
            expectedIdentity: expectedIdentity,
            beforeUnlink: {
                try? Data("concurrent".utf8).write(to: original)
            }
        ))
        #expect(try String(contentsOf: original, encoding: .utf8) == "concurrent")
    }

    @Test("Keeps owner access for archive directories with no permissions")
    func preservesOwnerAccessForLockedDirectory() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        try fixture.writeArchive([
            .directory("locked/", permissions: 0o1000),
            .file("locked/SKILL.md", Data("# Locked".utf8)),
        ])

        try SafeSkillArchive().extract(archiveAt: fixture.archiveURL, to: fixture.destinationURL)

        let locked = fixture.destinationURL.appendingPathComponent("locked", isDirectory: true)
        let attributes = try FileManager.default.attributesOfItem(atPath: locked.path)
        let permissions = (attributes[.posixPermissions] as? NSNumber)?.uint16Value
        #expect(permissions == 0o700)
        #expect(try SkillPackageLocator().locateSkillRoot(in: fixture.destinationURL) == locked.standardizedFileURL)
        try FileManager.default.removeItem(at: locked)
        #expect(!FileManager.default.fileExists(atPath: locked.path))
    }

    @Test("Cancellation cleans archive directories that request no permissions")
    func cancellationCleansLockedDirectories() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        try fixture.writeArchive([
            .directory("first/", permissions: 0o1000),
            .directory("second/", permissions: 0o1000),
        ])
        var applyingAttributes = false
        var attributeCheckpoints = 0

        #expect(throws: CancellationError.self) {
            try SafeSkillArchive().extract(
                archiveAt: fixture.archiveURL,
                to: fixture.destinationURL,
                checkpoint: {
                    guard applyingAttributes else { return }
                    attributeCheckpoints += 1
                    if attributeCheckpoints == 2 { throw CancellationError() }
                },
                beforeEntry: { components in
                    if components == ["second"] { applyingAttributes = true }
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
        case directory(String, permissions: UInt16? = nil)
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
            case let .directory(path, permissions):
                try add(path: path, type: .directory, contents: Data(), permissions: permissions, to: archive)
            case let .symbolicLink(path, destination):
                try add(path: path, type: .symlink, contents: Data(destination.utf8), to: archive)
            }
        }
    }

    func writeZIP64Declaration(entryCount: UInt64, recordSize: UInt64 = 44) throws {
        var data = Data()
        data.appendLittleEndian(UInt32(0x0606_4b50))
        data.appendLittleEndian(recordSize)
        data.appendLittleEndian(UInt16(45))
        data.appendLittleEndian(UInt16(45))
        data.appendLittleEndian(UInt32(0))
        data.appendLittleEndian(UInt32(0))
        data.appendLittleEndian(entryCount)
        data.appendLittleEndian(entryCount)
        data.appendLittleEndian(UInt64(0))
        data.appendLittleEndian(UInt64(0))
        if recordSize > 44 {
            data.append(Data(repeating: 0, count: Int(recordSize - 44)))
        }

        data.appendLittleEndian(UInt32(0x0706_4b50))
        data.appendLittleEndian(UInt32(0))
        data.appendLittleEndian(UInt64(0))
        data.appendLittleEndian(UInt32(1))

        data.appendLittleEndian(UInt32(0x0605_4b50))
        data.appendLittleEndian(UInt16(0))
        data.appendLittleEndian(UInt16(0))
        data.appendLittleEndian(UInt16.max)
        data.appendLittleEndian(UInt16.max)
        data.appendLittleEndian(UInt32.max)
        data.appendLittleEndian(UInt32.max)
        data.appendLittleEndian(UInt16(0))
        try data.write(to: archiveURL)
    }

    func writeShadowEndRecordInComment() throws {
        var data = Data()
        data.appendClassicEndRecord(entryCount: 0, commentLength: 23)
        data.appendClassicEndRecord(entryCount: UInt16.max, commentLength: 0)
        data.append(0)
        try data.write(to: archiveURL)
    }

    func remove() {
        try? FileManager.default.removeItem(at: rootURL)
    }

    private func add(
        path: String,
        type: Entry.EntryType,
        contents: Data,
        permissions: UInt16? = nil,
        to archive: Archive
    ) throws {
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

private extension Data {
    mutating func appendClassicEndRecord(entryCount: UInt16, commentLength: UInt16) {
        appendLittleEndian(UInt32(0x0605_4b50))
        appendLittleEndian(UInt16(0))
        appendLittleEndian(UInt16(0))
        appendLittleEndian(entryCount)
        appendLittleEndian(entryCount)
        appendLittleEndian(UInt32(0))
        appendLittleEndian(UInt32(0))
        appendLittleEndian(commentLength)
    }

    mutating func appendLittleEndian<T: FixedWidthInteger>(_ value: T) {
        var encoded = value.littleEndian
        Swift.withUnsafeBytes(of: &encoded) { append(contentsOf: $0) }
    }
}
