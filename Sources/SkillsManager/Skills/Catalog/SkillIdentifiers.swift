import Foundation

nonisolated enum SkillIdentifierError: Error, Equatable {
    case invalidByteCount(Int)
}

nonisolated struct SkillID: Hashable, Sendable {
    let uuid: UUID

    init(_ uuid: UUID = UUID()) {
        self.uuid = uuid
    }

    init(bytes: Data) throws {
        uuid = try catalogUUID(from: bytes)
    }

    var bytes: Data { catalogUUIDBytes(uuid) }
    var directoryName: String { uuid.uuidString.lowercased() }
}

nonisolated struct SourceID: Hashable, Sendable {
    let uuid: UUID

    init(_ uuid: UUID = UUID()) {
        self.uuid = uuid
    }

    init(bytes: Data) throws {
        uuid = try catalogUUID(from: bytes)
    }

    var bytes: Data { catalogUUIDBytes(uuid) }
}

nonisolated func catalogUUIDBytes(_ uuid: UUID) -> Data {
    let value = uuid.uuid
    return Data([
        value.0, value.1, value.2, value.3,
        value.4, value.5, value.6, value.7,
        value.8, value.9, value.10, value.11,
        value.12, value.13, value.14, value.15,
    ])
}

nonisolated func catalogUUID(from bytes: Data) throws -> UUID {
    guard bytes.count == 16 else {
        throw SkillIdentifierError.invalidByteCount(bytes.count)
    }
    let value = Array(bytes)
    return UUID(uuid: (
        value[0], value[1], value[2], value[3],
        value[4], value[5], value[6], value[7],
        value[8], value[9], value[10], value[11],
        value[12], value[13], value[14], value[15]
    ))
}
