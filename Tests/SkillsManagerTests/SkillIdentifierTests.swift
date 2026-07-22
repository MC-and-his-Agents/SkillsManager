import Foundation
import Testing
@testable import SkillsManager

@Suite("Stable catalog identifiers")
struct SkillIdentifierTests {
    private let uuid = UUID(uuidString: "00112233-4455-6677-8899-aabbccddeeff")!
    private let bytes = Data([
        0x00, 0x11, 0x22, 0x33, 0x44, 0x55, 0x66, 0x77,
        0x88, 0x99, 0xaa, 0xbb, 0xcc, 0xdd, 0xee, 0xff,
    ])

    @Test("uses RFC 4122 network byte order")
    func networkByteOrder() throws {
        let skillID = SkillID(uuid)
        let sourceID = SourceID(uuid)

        #expect(skillID.bytes == bytes)
        #expect(sourceID.bytes == bytes)
        #expect(try SkillID(bytes: bytes).uuid == uuid)
        #expect(try SourceID(bytes: bytes).uuid == uuid)
        #expect(skillID.directoryName == "00112233-4455-6677-8899-aabbccddeeff")
    }

    @Test("rejects non-UUID BLOB lengths")
    func invalidLengths() {
        #expect(throws: SkillIdentifierError.invalidByteCount(15)) {
            try SkillID(bytes: Data(repeating: 0, count: 15))
        }
        #expect(throws: SkillIdentifierError.invalidByteCount(17)) {
            try SourceID(bytes: Data(repeating: 0, count: 17))
        }
    }
}
