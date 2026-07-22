import Darwin
import Foundation
import Testing

@testable import SkillsManager

@Suite("Managed item identity codec")
struct ManagedItemIdentityCodecTests {
    @Test("identity is encoded as a fixed-width versioned value")
    func fixedWidthRoundTrip() throws {
        try withTemporaryDirectory { temporary in
            let file = temporary.appendingPathComponent("item")
            try Data("content".utf8).write(to: file)
            let descriptor = Darwin.open(file.path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
            #expect(descriptor >= 0)
            defer { if descriptor >= 0 { Darwin.close(descriptor) } }

            let identity = try ManagedItemIdentityCodec.capture(descriptor: descriptor)
            let encoded = try ManagedItemIdentityCodec.encode(identity)

            #expect(encoded.count == 32)
            #expect(Array(encoded.prefix(4)) == [0, 0, 0, 1])
            #expect(try ManagedItemIdentityCodec.decode(encoded) == identity)
        }
    }

    @Test("invalid length, version, and file type fail closed")
    func rejectsInvalidRepresentations() throws {
        #expect(throws: ManagedItemIdentityCodecError.invalidPayload) {
            try ManagedItemIdentityCodec.decode(Data(repeating: 0, count: 31))
        }

        var unsupportedVersion = Data(repeating: 0, count: 32)
        unsupportedVersion[3] = 2
        #expect(throws: ManagedItemIdentityCodecError.unsupportedVersion(2)) {
            try ManagedItemIdentityCodec.decode(unsupportedVersion)
        }

        var unsupportedType = Data(repeating: 0, count: 32)
        unsupportedType[3] = 1
        #expect(throws: ManagedItemIdentityCodecError.unsupportedFileType(0)) {
            try ManagedItemIdentityCodec.decode(unsupportedType)
        }
    }

    @Test("descriptor identity revalidation detects replacement")
    func detectsDescriptorReplacement() throws {
        try withTemporaryDirectory { temporary in
            let first = temporary.appendingPathComponent("first")
            let second = temporary.appendingPathComponent("second")
            try Data("first".utf8).write(to: first)
            try Data("second".utf8).write(to: second)
            let firstDescriptor = Darwin.open(first.path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
            let secondDescriptor = Darwin.open(second.path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
            #expect(firstDescriptor >= 0)
            #expect(secondDescriptor >= 0)
            defer {
                if firstDescriptor >= 0 { Darwin.close(firstDescriptor) }
                if secondDescriptor >= 0 { Darwin.close(secondDescriptor) }
            }

            let expected = try ManagedItemIdentityCodec.capture(descriptor: firstDescriptor)
            try ManagedItemIdentityCodec.revalidate(
                descriptor: firstDescriptor,
                expected: expected
            )
            #expect(throws: ManagedPathError.itemChanged) {
                try ManagedItemIdentityCodec.revalidate(
                    descriptor: secondDescriptor,
                    expected: expected
                )
            }
        }
    }

    private func withTemporaryDirectory(_ body: (URL) throws -> Void) throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: url) }
        try body(url)
    }
}
