import Darwin
import Foundation
import Testing
import ZIPFoundation
@testable import SkillsManager

@Suite("Safe skill archive snapshot binding")
struct SafeSkillArchiveSnapshotTests {
    @Test("Uses the preflighted archive when its path is replaced by an over-limit archive")
    func ignoresOverLimitPathReplacement() throws {
        let fixture = try SnapshotFixture()
        defer { fixture.remove() }
        try fixture.writeArchive([("safe.txt", Data("safe".utf8))], to: fixture.archiveURL)
        try fixture.writeArchive(
            [("first.txt", Data()), ("second.txt", Data())],
            to: fixture.replacementURL
        )

        let paths = try SafeSkillArchive(limits: .init(maximumEntryCount: 1)).extract(
            archiveAt: fixture.archiveURL,
            to: fixture.destinationURL,
            afterPreflight: fixture.replaceArchivePath
        )

        #expect(paths == ["safe.txt"])
        #expect(try Data(contentsOf: fixture.destinationURL.appendingPathComponent("safe.txt")) == Data("safe".utf8))
    }

    @Test("Uses raw kinds from the same archive when its path is replaced")
    func ignoresDifferentRawKindPathReplacement() throws {
        let fixture = try SnapshotFixture()
        defer { fixture.remove() }
        try fixture.writeArchive([("safe.txt", Data("safe".utf8))], to: fixture.archiveURL)
        try fixture.writeArchive([("unsafe.txt", Data("unsafe".utf8))], to: fixture.replacementURL)
        try fixture.markFirstEntryAsFIFO(in: fixture.replacementURL)

        let paths = try SafeSkillArchive().extract(
            archiveAt: fixture.archiveURL,
            to: fixture.destinationURL,
            afterPreflight: fixture.replaceArchivePath
        )

        #expect(paths == ["safe.txt"])
        #expect(!FileManager.default.fileExists(
            atPath: fixture.destinationURL.appendingPathComponent("unsafe.txt").path
        ))
    }
}

private struct SnapshotFixture {
    let rootURL: URL
    let archiveURL: URL
    let replacementURL: URL
    let destinationURL: URL

    init() throws {
        rootURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("safe-archive-snapshot-tests-\(UUID().uuidString)", isDirectory: true)
        archiveURL = rootURL.appendingPathComponent("fixture.zip")
        replacementURL = rootURL.appendingPathComponent("replacement.zip")
        destinationURL = rootURL.appendingPathComponent("destination", isDirectory: true)
        try FileManager.default.createDirectory(at: destinationURL, withIntermediateDirectories: true)
    }

    func writeArchive(_ entries: [(String, Data)], to url: URL) throws {
        let archive = try Archive(url: url, accessMode: .create)
        for (path, contents) in entries {
            try archive.addEntry(with: path, type: .file, uncompressedSize: Int64(contents.count)) {
                position, size in
                let start = Int(position)
                return contents.subdata(in: start..<min(start + size, contents.count))
            }
        }
    }

    func markFirstEntryAsFIFO(in url: URL) throws {
        var bytes = try Data(contentsOf: url)
        let signature = Data([0x50, 0x4b, 0x01, 0x02])
        guard let header = bytes.range(of: signature) else { throw SafeSkillArchiveError.invalidArchive }
        var attributes = (UInt32(S_IFIFO | 0o600) << 16).littleEndian
        withUnsafeBytes(of: &attributes) {
            bytes.replaceSubrange((header.lowerBound + 38)..<(header.lowerBound + 42), with: $0)
        }
        try bytes.write(to: url)
    }

    func replaceArchivePath() throws {
        try FileManager.default.removeItem(at: archiveURL)
        try FileManager.default.moveItem(at: replacementURL, to: archiveURL)
    }

    func remove() {
        try? FileManager.default.removeItem(at: rootURL)
    }
}
