import Foundation
import Testing

@testable import SkillsManager

@Suite("Legacy state inventory")
struct LegacyStateInventoryTests {
    @Test("empty inventory matches the fixed digest")
    func emptyDigestVector() throws {
        let fixture = try LegacyMigrationTestFixture()
        let inventory = try fixture.inventory()
        #expect(inventory.entryCount == 0)
        #expect(inventory.inventoryDigest == LegacyStateInventory.emptyDigest)
    }

    @Test("normalizes file URLs exactly once and rejects malformed paths")
    func customPathURLVectors() throws {
        let localhost = try LegacyCustomPathURLNormalizer.normalize("file://localhost/tmp/a")
        #expect(localhost.absoluteURL == "file:///tmp/a/")
        #expect(String(decoding: localhost.key, as: UTF8.self) == "/tmp/a")
        let root = try LegacyCustomPathURLNormalizer.normalize("file:///")
        #expect(root.absoluteURL == "file:///")
        #expect(String(decoding: root.key, as: UTF8.self) == "/")
        let space = try LegacyCustomPathURLNormalizer.normalize("file:///tmp/a%20b")
        #expect(String(decoding: space.key, as: UTF8.self) == "/tmp/a b")
        let slash = try LegacyCustomPathURLNormalizer.normalize("file:///tmp/a%2Fb")
        #expect(slash.absoluteURL == "file:///tmp/a/b/")
        #expect(String(decoding: slash.key, as: UTF8.self) == "/tmp/a/b")
        let escapedSlash = try LegacyCustomPathURLNormalizer.normalize("file:///tmp/a%252Fb")
        #expect(escapedSlash.absoluteURL == "file:///tmp/a%252Fb/")
        #expect(String(decoding: escapedSlash.key, as: UTF8.self) == "/tmp/a%2Fb")
        let percent = try LegacyCustomPathURLNormalizer.normalize("file:///tmp/a%25b")
        #expect(String(decoding: percent.key, as: UTF8.self) == "/tmp/a%b")
        let parent = try LegacyCustomPathURLNormalizer.normalize("file:///tmp/%2E%2E/x")
        #expect(parent.absoluteURL == "file:///x/")
        #expect(
            try LegacyCustomPathURLNormalizer.normalize("file:///tmp/a").key
                == LegacyCustomPathURLNormalizer.normalize("file:///tmp/a/").key
        )

        for invalid in [
            "file:///tmp/a%00b", "file:///tmp/a%ZZb", "file:///tmp/a%FFb",
            "file:///tmp/a%C3%28b", "file:///tmp/a%ED%A0%80b", "file://localhost",
            "https:///tmp/a", "file://example.com/tmp/a", "file://user@localhost/tmp/a",
            "file://localhost:80/tmp/a", "file:///tmp/a?query", "file:///tmp/a#fragment",
        ] {
            #expect(throws: LegacyMigrationFailure.self) {
                _ = try LegacyCustomPathURLNormalizer.normalize(invalid)
            }
        }
    }

    @Test("strict JSON rejects duplicate and unknown fields")
    func strictWireContract() throws {
        let duplicate = Data("{\"lastPublishedHash\":\"a\",\"lastPublishedHash\":\"b\",\"lastPublishedAt\":0}".utf8)
        #expect(throws: LegacyMigrationFailure.self) {
            _ = try LegacyStateWireDecoder.decodePublishState(
                duplicate,
                locator: "skill-state/demo.json",
                digest: Data(repeating: 0, count: 32)
            )
        }
        let unknown = Data("{\"lastPublishedHash\":\"a\",\"lastPublishedAt\":0,\"future\":1}".utf8)
        do {
            _ = try LegacyStateWireDecoder.decodePublishState(
                unknown,
                locator: "skill-state/demo.json",
                digest: Data(repeating: 0, count: 32)
            )
            Issue.record("Expected unknown field rejection")
        } catch let failure as LegacyMigrationFailure {
            #expect(failure.code == .legacyUnsupportedFormat)
        }

        for json in [
            "[]",
            "{\"lastPublishedHash\":\"a\"}",
            "{\"lastPublishedHash\":\"a\",\"lastPublishedAt\":0,\"hashAlgorithmVersion\":null}",
            "{\"lastPublishedHash\":\"a\",\"lastPublishedAt\":0,\"hashAlgorithmVersion\":2}",
            "{\"lastPublishedHash\":\"a\",\"lastPublishedAt\":0} trailing",
        ] {
            #expect(throws: LegacyMigrationFailure.self) {
                _ = try LegacyStateWireDecoder.decodePublishState(
                    Data(json.utf8),
                    locator: "skill-state/demo.json",
                    digest: Data(repeating: 0, count: 32)
                )
            }
        }

        let duplicateCustomPath = Data(
            """
            [
              {"id":"aaaaaaaa-1111-4222-8333-bbbbbbbbbbbb","url":"file:///tmp/a","displayName":"A","addedAt":0},
              {"id":"aaaaaaaa-1111-4222-8333-bbbbbbbbbbbb","url":"file:///tmp/b","displayName":"B","addedAt":0}
            ]
            """.utf8
        )
        do {
            _ = try LegacyStateWireDecoder.decodeCustomPaths(duplicateCustomPath)
            Issue.record("Expected duplicate custom path rejection")
        } catch let failure as LegacyMigrationFailure {
            #expect(failure.code == .legacyDuplicateRecord)
        }
    }

    @Test("encodes legacy reference dates as bounded Unix milliseconds")
    func dateVectors() throws {
        #expect(try LegacyDateCodec.milliseconds(fromReferenceDateNumber: "0") == 978_307_200_000)
        #expect(try LegacyDateCodec.milliseconds(fromReferenceDateNumber: "-978307201") == -1_000)
        #expect(try LegacyDateCodec.milliseconds(fromReferenceDateNumber: "-978307199.9995") == 1)
        #expect(try LegacyDateCodec.milliseconds(fromReferenceDateNumber: "-978307200.0005") == -1)
        #expect(
            try LegacyDateCodec.milliseconds(fromReferenceDateNumber: "9000000000000000")
                == 9_000_000_978_307_200_000
        )
        #expect(
            try LegacyDateCodec.milliseconds(
                from: Date(timeIntervalSince1970: Double(Int64.min) / 1_000)
            ) == Int64.min
        )
        #expect(throws: LegacyMigrationFailure.self) {
            _ = try LegacyDateCodec.milliseconds(
                from: Date(timeIntervalSince1970: Double(Int64.max) / 1_000)
            )
        }
        for invalid in ["1e309", "10000000000000000", "-10000000000000000"] {
            #expect(throws: LegacyMigrationFailure.self) {
                _ = try LegacyDateCodec.milliseconds(fromReferenceDateNumber: invalid)
            }
        }
    }

    @Test("digest uses fixed big-endian single and sorted multi-entry vectors")
    func digestVectors() throws {
        let single = try LegacyMigrationTestFixture(
            publishStates: ["demo": "{\"lastPublishedHash\":\"a\",\"lastPublishedAt\":0}"]
        )
        #expect(try single.inventory().inventoryDigest == dataFromHex(
            "8f94fae68ade9adbfa3cb36bf8a091a72e2b1a7e1bf9926380ecdea62694c214"
        ))

        let multiple = try LegacyMigrationTestFixture(publishStates: [
            "z": "{\"lastPublishedHash\":\"z\",\"lastPublishedAt\":0}",
            "A": "{\"lastPublishedHash\":\"a\",\"lastPublishedAt\":0}",
        ])
        #expect(try multiple.inventory().inventoryDigest == dataFromHex(
            "cda4f2192c127392403d978b363bc7eedd34c1bf7d44d6e65b615bc9b004b510"
        ))
    }

    @Test("ignored entries produce relative diagnostics without following symlinks")
    func ignoredEntryDiagnostics() throws {
        let fixture = try LegacyMigrationTestFixture()
        let destination = fixture.root.appendingPathComponent("outside.json")
        try writeLegacy(legacyPublishFixture, to: destination)
        try FileManager.default.createSymbolicLink(
            at: fixture.skillState.appendingPathComponent("linked.json"),
            withDestinationURL: destination
        )
        try createOwnerOnlyDirectory(
            fixture.skillState.appendingPathComponent("directory.json", isDirectory: true)
        )
        try writeLegacy("ignored", to: fixture.skillState.appendingPathComponent("notes.txt"))
        try writeLegacy("ignored", to: fixture.legacyRoot.appendingPathComponent("unknown.dat"))
        let inventory = try fixture.inventory()
        #expect(inventory.entryCount == 0)
        #expect(inventory.inventoryDigest == LegacyStateInventory.emptyDigest)
        #expect(inventory.diagnostics == [
            LegacyMigrationDiagnostic(code: .ignoredLegacyEntry, locator: "skill-state/directory.json"),
            LegacyMigrationDiagnostic(code: .ignoredLegacyEntry, locator: "skill-state/linked.json"),
            LegacyMigrationDiagnostic(code: .ignoredLegacyEntry, locator: "skill-state/notes.txt"),
            LegacyMigrationDiagnostic(code: .ignoredLegacyEntry, locator: "unknown.dat"),
        ])
    }

    @Test("rejects a publish-state file above the one-megabyte limit")
    func rejectsOversizedPublishState() throws {
        let fixture = try LegacyMigrationTestFixture()
        try Data(repeating: 0x20, count: 1_048_577).write(to: fixture.publishURL("oversized"))
        #expect(throws: LegacyMigrationFailure.self) {
            _ = try fixture.inventory()
        }
    }

    @Test("enforces the aggregate byte budget while capturing files")
    func rejectsAggregateLimitDuringCapture() throws {
        let fixture = try LegacyMigrationTestFixture()
        try writeLegacy("1234", to: fixture.publishURL("a"))
        try writeLegacy("5678", to: fixture.publishURL("b"))
        do {
            _ = try fixture.inventory(maximumTotalBytes: 6)
            Issue.record("Expected aggregate resource limit rejection")
        } catch let failure as LegacyMigrationFailure {
            #expect(failure.code == .legacyResourceLimitExceeded)
            #expect(failure.locator == "skill-state/b.json")
        }
    }
}

private func dataFromHex(_ value: String) -> Data {
    var bytes: [UInt8] = []
    var index = value.startIndex
    while index < value.endIndex {
        let next = value.index(index, offsetBy: 2)
        bytes.append(UInt8(value[index..<next], radix: 16)!)
        index = next
    }
    return Data(bytes)
}
