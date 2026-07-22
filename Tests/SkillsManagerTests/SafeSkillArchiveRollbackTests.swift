import Foundation
import Testing

@testable import SkillsManager

extension SafeSkillArchiveTests {
    @Test("rollback preserves an external top-level entry")
    func rollbackPreservesExternalTopLevelEntry() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        try fixture.writeArchive([
            .file("owned.txt", Data("owned".utf8)),
            .file("trigger.txt", Data("trigger".utf8)),
        ])
        let external = fixture.destinationURL.appendingPathComponent("external.txt")

        #expect(throws: CancellationError.self) {
            try SafeSkillArchive().extract(
                archiveAt: fixture.archiveURL,
                to: fixture.destinationURL,
                beforeEntry: { components in
                    guard components == ["trigger.txt"] else { return }
                    try Data("external".utf8).write(to: external)
                    throw CancellationError()
                }
            )
        }

        #expect(!FileManager.default.fileExists(
            atPath: fixture.destinationURL.appendingPathComponent("owned.txt").path
        ))
        #expect(try String(contentsOf: external, encoding: .utf8) == "external")
    }

    @Test("rollback preserves a replacement for a completed file")
    func rollbackPreservesCompletedFileReplacement() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        try fixture.writeArchive([
            .file("owned.txt", Data("owned".utf8)),
            .file("trigger.txt", Data("trigger".utf8)),
        ])
        let owned = fixture.destinationURL.appendingPathComponent("owned.txt")
        let displaced = fixture.destinationURL.appendingPathComponent("displaced.txt")

        #expect(throws: CancellationError.self) {
            try SafeSkillArchive().extract(
                archiveAt: fixture.archiveURL,
                to: fixture.destinationURL,
                beforeEntry: { components in
                    guard components == ["trigger.txt"] else { return }
                    try FileManager.default.moveItem(at: owned, to: displaced)
                    try Data("replacement".utf8).write(to: owned)
                    throw CancellationError()
                }
            )
        }

        #expect(try String(contentsOf: owned, encoding: .utf8) == "replacement")
        #expect(try String(contentsOf: displaced, encoding: .utf8) == "owned")
    }

    @Test("rollback keeps an owned directory containing an external child")
    func rollbackPreservesExternalNestedEntry() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        try fixture.writeArchive([
            .file("inside/owned.txt", Data("owned".utf8)),
            .file("trigger.txt", Data("trigger".utf8)),
        ])
        let inside = fixture.destinationURL.appendingPathComponent("inside", isDirectory: true)
        let external = inside.appendingPathComponent("external.txt")

        #expect(throws: CancellationError.self) {
            try SafeSkillArchive().extract(
                archiveAt: fixture.archiveURL,
                to: fixture.destinationURL,
                beforeEntry: { components in
                    guard components == ["trigger.txt"] else { return }
                    try Data("external".utf8).write(to: external)
                    throw CancellationError()
                }
            )
        }

        #expect(!FileManager.default.fileExists(atPath: inside.appendingPathComponent("owned.txt").path))
        #expect(try String(contentsOf: external, encoding: .utf8) == "external")
    }

    @Test("rollback never enters a replacement directory")
    func rollbackPreservesReplacementDirectory() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        try fixture.writeArchive([
            .file("inside/owned.txt", Data("owned".utf8)),
            .file("trigger.txt", Data("trigger".utf8)),
        ])
        let inside = fixture.destinationURL.appendingPathComponent("inside", isDirectory: true)
        let displaced = fixture.destinationURL.appendingPathComponent("displaced", isDirectory: true)
        let sentinel = inside.appendingPathComponent("sentinel.txt")

        #expect(throws: CancellationError.self) {
            try SafeSkillArchive().extract(
                archiveAt: fixture.archiveURL,
                to: fixture.destinationURL,
                beforeEntry: { components in
                    guard components == ["trigger.txt"] else { return }
                    try FileManager.default.moveItem(at: inside, to: displaced)
                    try FileManager.default.createDirectory(at: inside, withIntermediateDirectories: false)
                    try Data("external".utf8).write(to: sentinel)
                    throw CancellationError()
                }
            )
        }

        #expect(try String(contentsOf: sentinel, encoding: .utf8) == "external")
        #expect(try String(
            contentsOf: displaced.appendingPathComponent("owned.txt"),
            encoding: .utf8
        ) == "owned")
    }

    @Test("directory publication rejects an unjournaled existing name")
    func directoryPublicationRejectsExternalCollision() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        try fixture.writeArchive([
            .directory("inside/"),
        ])
        let inside = fixture.destinationURL.appendingPathComponent("inside", isDirectory: true)
        let sentinel = inside.appendingPathComponent("sentinel.txt")

        #expect(throws: (any Error).self) {
            try SafeSkillArchive().extract(
                archiveAt: fixture.archiveURL,
                to: fixture.destinationURL,
                beforeEntry: { components in
                    guard components == ["inside"] else { return }
                    try FileManager.default.createDirectory(at: inside, withIntermediateDirectories: false)
                    try Data("external".utf8).write(to: sentinel)
                }
            )
        }

        #expect(try String(contentsOf: sentinel, encoding: .utf8) == "external")
        #expect(try FileManager.default.contentsOfDirectory(atPath: fixture.destinationURL.path) == ["inside"])
    }

    @Test("directory attributes never target a replacement directory")
    func directoryAttributesRejectReplacement() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        try fixture.writeArchive([
            .directory("first/", permissions: 0o1000),
            .directory("second/", permissions: 0o1000),
        ])
        let second = fixture.destinationURL.appendingPathComponent("second", isDirectory: true)
        let displaced = fixture.destinationURL.appendingPathComponent("displaced", isDirectory: true)
        let sentinel = second.appendingPathComponent("sentinel.txt")
        var extractionFinished = false
        var replaced = false

        #expect(throws: (any Error).self) {
            try SafeSkillArchive().extract(
                archiveAt: fixture.archiveURL,
                to: fixture.destinationURL,
                checkpoint: {
                    guard extractionFinished, !replaced else { return }
                    try FileManager.default.moveItem(at: second, to: displaced)
                    try FileManager.default.createDirectory(at: second, withIntermediateDirectories: false)
                    try Data("external".utf8).write(to: sentinel)
                    replaced = true
                },
                beforeEntry: { components in
                    if components == ["second"] { extractionFinished = true }
                }
            )
        }

        #expect(replaced)
        #expect(try String(contentsOf: sentinel, encoding: .utf8) == "external")
        #expect(FileManager.default.fileExists(atPath: displaced.path))
    }
}
