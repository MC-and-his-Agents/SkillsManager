import Foundation

nonisolated enum StrictLegacyJSONError: Error, Equatable {
    case invalid
    case duplicateKey
}

nonisolated indirect enum StrictLegacyJSONValue: Equatable {
    case object([String: StrictLegacyJSONValue])
    case array([StrictLegacyJSONValue])
    case string(String)
    case number(String)
    case bool(Bool)
    case null
}

nonisolated struct StrictLegacyJSONParser {
    private let bytes: [UInt8]
    private var index = 0

    init(data: Data) throws {
        let bytes = Array(data)
        guard !bytes.starts(with: [0xef, 0xbb, 0xbf]),
              String(data: data, encoding: .utf8) != nil else {
            throw StrictLegacyJSONError.invalid
        }
        self.bytes = bytes
    }

    mutating func parse() throws -> StrictLegacyJSONValue {
        skipWhitespace()
        let value = try parseValue(depth: 0)
        skipWhitespace()
        guard index == bytes.count else { throw StrictLegacyJSONError.invalid }
        return value
    }

    private mutating func parseValue(depth: Int) throws -> StrictLegacyJSONValue {
        guard depth <= 64, let byte = current else { throw StrictLegacyJSONError.invalid }
        switch byte {
        case 0x7b: return try parseObject(depth: depth + 1)
        case 0x5b: return try parseArray(depth: depth + 1)
        case 0x22: return .string(try parseString())
        case 0x74: try consume("true"); return .bool(true)
        case 0x66: try consume("false"); return .bool(false)
        case 0x6e: try consume("null"); return .null
        case 0x2d, 0x30...0x39: return .number(try parseNumber())
        default: throw StrictLegacyJSONError.invalid
        }
    }

    private mutating func parseObject(depth: Int) throws -> StrictLegacyJSONValue {
        index += 1
        skipWhitespace()
        if consumeIf(0x7d) { return .object([:]) }
        var object: [String: StrictLegacyJSONValue] = [:]
        while true {
            guard current == 0x22 else { throw StrictLegacyJSONError.invalid }
            let key = try parseString()
            guard object[key] == nil else { throw StrictLegacyJSONError.duplicateKey }
            skipWhitespace()
            guard consumeIf(0x3a) else { throw StrictLegacyJSONError.invalid }
            skipWhitespace()
            object[key] = try parseValue(depth: depth)
            skipWhitespace()
            if consumeIf(0x7d) { return .object(object) }
            guard consumeIf(0x2c) else { throw StrictLegacyJSONError.invalid }
            skipWhitespace()
        }
    }

    private mutating func parseArray(depth: Int) throws -> StrictLegacyJSONValue {
        index += 1
        skipWhitespace()
        if consumeIf(0x5d) { return .array([]) }
        var values: [StrictLegacyJSONValue] = []
        while true {
            values.append(try parseValue(depth: depth))
            skipWhitespace()
            if consumeIf(0x5d) { return .array(values) }
            guard consumeIf(0x2c) else { throw StrictLegacyJSONError.invalid }
            skipWhitespace()
        }
    }

    private mutating func parseString() throws -> String {
        guard consumeIf(0x22) else { throw StrictLegacyJSONError.invalid }
        var output: [UInt8] = []
        while let byte = current {
            index += 1
            switch byte {
            case 0x22:
                guard let value = String(bytes: output, encoding: .utf8) else {
                    throw StrictLegacyJSONError.invalid
                }
                return value
            case 0x00...0x1f:
                throw StrictLegacyJSONError.invalid
            case 0x5c:
                try appendEscape(to: &output)
            default:
                output.append(byte)
            }
        }
        throw StrictLegacyJSONError.invalid
    }

    private mutating func appendEscape(to output: inout [UInt8]) throws {
        guard let escape = current else { throw StrictLegacyJSONError.invalid }
        index += 1
        switch escape {
        case 0x22, 0x5c, 0x2f: output.append(escape)
        case 0x62: output.append(0x08)
        case 0x66: output.append(0x0c)
        case 0x6e: output.append(0x0a)
        case 0x72: output.append(0x0d)
        case 0x74: output.append(0x09)
        case 0x75:
            let scalar = try parseEscapedScalar()
            output.append(contentsOf: String(scalar).utf8)
        default: throw StrictLegacyJSONError.invalid
        }
    }

    private mutating func parseEscapedScalar() throws -> Unicode.Scalar {
        let first = try parseHexQuad()
        if 0xd800...0xdbff ~= first {
            guard consumeIf(0x5c), consumeIf(0x75) else {
                throw StrictLegacyJSONError.invalid
            }
            let second = try parseHexQuad()
            guard 0xdc00...0xdfff ~= second else { throw StrictLegacyJSONError.invalid }
            let value = 0x10000 + ((first - 0xd800) << 10) + (second - 0xdc00)
            guard let scalar = Unicode.Scalar(value) else { throw StrictLegacyJSONError.invalid }
            return scalar
        }
        guard !(0xdc00...0xdfff).contains(first), let scalar = Unicode.Scalar(first) else {
            throw StrictLegacyJSONError.invalid
        }
        return scalar
    }

    private mutating func parseHexQuad() throws -> UInt32 {
        var value: UInt32 = 0
        for _ in 0..<4 {
            guard let byte = current, let digit = hexValue(byte) else {
                throw StrictLegacyJSONError.invalid
            }
            index += 1
            value = value * 16 + UInt32(digit)
        }
        return value
    }

    private mutating func parseNumber() throws -> String {
        let start = index
        _ = consumeIf(0x2d)
        if consumeIf(0x30) {
            guard !(current.map(isDigit) ?? false) else { throw StrictLegacyJSONError.invalid }
        } else {
            guard consumeDigit(in: 0x31...0x39) else { throw StrictLegacyJSONError.invalid }
            while current.map(isDigit) == true { index += 1 }
        }
        if consumeIf(0x2e) {
            guard consumeDigit(in: 0x30...0x39) else { throw StrictLegacyJSONError.invalid }
            while current.map(isDigit) == true { index += 1 }
        }
        if current == 0x65 || current == 0x45 {
            index += 1
            if current == 0x2b || current == 0x2d { index += 1 }
            guard consumeDigit(in: 0x30...0x39) else { throw StrictLegacyJSONError.invalid }
            while current.map(isDigit) == true { index += 1 }
        }
        return String(decoding: bytes[start..<index], as: UTF8.self)
    }

    private mutating func consume(_ literal: StaticString) throws {
        for expected in literal.withUTF8Buffer({ Array($0) }) {
            guard consumeIf(expected) else { throw StrictLegacyJSONError.invalid }
        }
    }

    private mutating func consumeDigit(in range: ClosedRange<UInt8>) -> Bool {
        guard let current, range.contains(current) else { return false }
        index += 1
        return true
    }

    private mutating func consumeIf(_ byte: UInt8) -> Bool {
        guard current == byte else { return false }
        index += 1
        return true
    }

    private mutating func skipWhitespace() {
        while let byte = current, byte == 0x20 || byte == 0x09 || byte == 0x0a || byte == 0x0d {
            index += 1
        }
    }

    private var current: UInt8? { index < bytes.count ? bytes[index] : nil }
    private func isDigit(_ byte: UInt8) -> Bool { (0x30...0x39).contains(byte) }
    private func hexValue(_ byte: UInt8) -> UInt8? {
        switch byte {
        case 0x30...0x39: byte - 0x30
        case 0x41...0x46: byte - 0x41 + 10
        case 0x61...0x66: byte - 0x61 + 10
        default: nil
        }
    }
}
