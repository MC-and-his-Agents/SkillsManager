import Foundation
import Testing

@testable import SkillsManager

@Suite("Skill content snapshot")
struct SkillContentSnapshotTests {
    @Test("v1 fingerprint is stable and includes binary content")
    func fixedHashVector() throws {
        try withTemporaryDirectory { root in
            try write(Data("# Demo\n".utf8), to: root.appendingPathComponent("SKILL.md"))
            let binaryURL = root.appendingPathComponent("assets/icon.bin")
            try write(
                Data([0x00, 0xff, 0x10, 0x80]),
                to: binaryURL
            )

            let snapshot = try SkillContentSnapshot.capture(at: root)

            #expect(snapshot.fingerprint == "5e989a06efbf35ff2d7f38a7d39531f14120448def4260b64499e0dffdc81008")
            #expect(snapshot.files == [
                .init(relativePath: "SKILL.md", byteCount: 7),
                .init(relativePath: "assets/icon.bin", byteCount: 4),
            ])
            #expect(snapshot.statistics == .init(fileCount: 2, totalByteCount: 11))

            try write(
                Data([0x00, 0xff, 0x10, 0x81]),
                to: binaryURL
            )
            let changedByte = try SkillContentSnapshot.capture(at: root)
            #expect(changedByte.fingerprint != snapshot.fingerprint)

            try write(Data([0x00, 0xff, 0x10, 0x81, 0x00]), to: binaryURL)
            let changedLength = try SkillContentSnapshot.capture(at: root)
            #expect(changedLength.fingerprint != changedByte.fingerprint)

            try FileManager.default.moveItem(
                at: binaryURL,
                to: root.appendingPathComponent("assets/renamed.bin")
            )
            #expect(try SkillContentSnapshot.capture(at: root).fingerprint != changedLength.fingerprint)
        }
    }

    @Test("paths use NFC and Unicode byte ordering")
    func normalizesAndSortsPaths() throws {
        try withTemporaryDirectory { root in
            try write(Data(), to: root.appendingPathComponent("z.txt"))
            try write(Data(), to: root.appendingPathComponent("cafe\u{301}.txt"))

            let snapshot = try SkillContentSnapshot.capture(at: root)

            #expect(snapshot.files.map(\.relativePath) == ["caf\u{e9}.txt", "z.txt"])
        }
    }

    @Test("NFC-equivalent and case-only names collide")
    func rejectsNormalizedPathCollisions() throws {
        #expect(throws: SkillContentSnapshotError.pathCollision(
            first: "Cafe\u{301}",
            second: "Caf\u{e9}"
        )) {
            try SkillContentPath.uniqueNormalizedComponents(["Cafe\u{301}", "Caf\u{e9}"])
        }
        #expect(throws: SkillContentSnapshotError.pathCollision(
            first: "SKILL.md",
            second: "skill.md"
        )) {
            try SkillContentPath.uniqueNormalizedComponents(["SKILL.md", "skill.md"])
        }
    }

    @Test("management metadata is excluded centrally")
    func excludesManagementMetadata() throws {
        try withTemporaryDirectory { root in
            try write(Data("content".utf8), to: root.appendingPathComponent("SKILL.md"))
            try write(Data("finder".utf8), to: root.appendingPathComponent(".DS_Store"))
            try write(Data("state".utf8), to: root.appendingPathComponent(".skillsmanager.json"))
            try write(Data("temp".utf8), to: root.appendingPathComponent(".skillsmanager-tmp-run"))
            try write(Data("git".utf8), to: root.appendingPathComponent(".git/config"))
            try write(Data("origin".utf8), to: root.appendingPathComponent(".clawdhub/origin.json"))
            try write(Data("managed".utf8), to: root.appendingPathComponent(".skillsmanager/state.json"))

            let before = try SkillContentSnapshot.capture(at: root)
            try write(Data("changed".utf8), to: root.appendingPathComponent(".git/config"))
            let after = try SkillContentSnapshot.capture(at: root)

            #expect(before.fingerprint == after.fingerprint)
            #expect(before.files == [.init(relativePath: "SKILL.md", byteCount: 7)])
        }
    }

    @Test("resource limits return typed errors")
    func enforcesLimits() throws {
        try withTemporaryDirectory { root in
            try write(Data([1, 2]), to: root.appendingPathComponent("one"))
            try write(Data([3, 4]), to: root.appendingPathComponent("two"))

            #expect(throws: SkillContentSnapshotError.fileCountLimitExceeded(limit: 1)) {
                try SkillContentSnapshot.capture(
                    at: root,
                    limits: .init(
                        maximumFileCount: 1,
                        maximumTotalByteCount: 10,
                        maximumFileByteCount: 10
                    )
                )
            }
            #expect(throws: SkillContentSnapshotError.fileByteLimitExceeded(
                path: "one",
                limit: 1,
                actual: 2
            )) {
                try SkillContentSnapshot.capture(
                    at: root,
                    limits: .init(
                        maximumFileCount: 10,
                        maximumTotalByteCount: 10,
                        maximumFileByteCount: 1
                    )
                )
            }
            #expect(throws: SkillContentSnapshotError.totalByteLimitExceeded(
                limit: 3,
                actual: 4
            )) {
                try SkillContentSnapshot.capture(
                    at: root,
                    limits: .init(
                        maximumFileCount: 10,
                        maximumTotalByteCount: 3,
                        maximumFileByteCount: 10
                    )
                )
            }
        }
    }

    @Test("symbolic links are rejected without traversal")
    func rejectsSymbolicLinks() throws {
        try withTemporaryDirectory { root in
            let outside = root.deletingLastPathComponent().appendingPathComponent(UUID().uuidString)
            defer { try? FileManager.default.removeItem(at: outside) }
            try write(Data("outside".utf8), to: outside.appendingPathComponent("value"))
            try FileManager.default.createSymbolicLink(
                at: root.appendingPathComponent("linked"),
                withDestinationURL: outside
            )

            #expect(throws: SkillContentSnapshotError.unsupportedEntry(path: "linked")) {
                try SkillContentSnapshot.capture(at: root)
            }
        }
    }

    @Test("retained copy plan rejects an intermediate directory replaced by a link")
    func copyPlanRejectsDirectorySwap() throws {
        try withTemporaryDirectory { root in
            let source = root.appendingPathComponent("source")
            let nested = source.appendingPathComponent("nested")
            try write(Data("approved".utf8), to: nested.appendingPathComponent("value"))
            let snapshot = try SkillContentSnapshot.capture(at: source)

            let displaced = root.appendingPathComponent("displaced")
            let outside = root.appendingPathComponent("outside")
            try FileManager.default.moveItem(at: nested, to: displaced)
            try write(Data("outside".utf8), to: outside.appendingPathComponent("value"))
            try FileManager.default.createSymbolicLink(at: nested, withDestinationURL: outside)

            let destination = root.appendingPathComponent("destination")
            try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
            #expect(throws: SkillContentSnapshotError.self) {
                try snapshot.copyFiles(to: destination)
            }
            #expect(!FileManager.default.fileExists(
                atPath: destination.appendingPathComponent("nested/value").path
            ))
        }
    }

    private func withTemporaryDirectory(
        _ body: (URL) throws -> Void
    ) throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try body(root)
    }

    private func write(_ data: Data, to url: URL) throws {
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try data.write(to: url)
    }
}
