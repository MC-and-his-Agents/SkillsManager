import Foundation

nonisolated enum LegacyMigrationErrorCode: String, Sendable {
    case ownershipUnavailable
    case legacyPathChanged
    case legacyPermissionInvalid
    case legacyInventoryChanged
    case legacyInvalidJSON
    case legacyDuplicateKey
    case legacyUnsupportedFormat
    case legacyDuplicateRecord
    case legacyResourceLimitExceeded
    case customPathURLInvalid
    case legacyDateOutOfRange
    case databaseBusy
    case databaseFailure
    case componentNotAdmitted
    case ledgerInvalid
    case ledgerConflict
}

nonisolated enum LegacyMigrationDiagnosticCode: String, Sendable {
    case legacyArchiveChanged
    case ignoredLegacyEntry
}

nonisolated struct LegacyMigrationDiagnostic: Equatable, Sendable {
    let code: LegacyMigrationDiagnosticCode
    let locator: String?
}

nonisolated struct LegacyMigrationFailure: Error, Equatable, LocalizedError, Sendable {
    let code: LegacyMigrationErrorCode
    let retryable: Bool
    let locator: String?

    init(_ code: LegacyMigrationErrorCode, locator: String? = nil) {
        self.code = code
        self.retryable = switch code {
        case .ledgerInvalid, .ledgerConflict: false
        default: true
        }
        self.locator = locator
    }

    var errorDescription: String? {
        locator.map { "\(code.rawValue): \($0)" } ?? code.rawValue
    }
}

nonisolated struct LegacyCustomPathRecord: Equatable, Sendable {
    let id: UUID
    let absoluteURL: String
    let normalizedURLKey: Data
    let displayName: String
    let addedAtMilliseconds: Int64
}

nonisolated struct LegacyPublishStateRecord: Equatable, Sendable {
    let locator: String
    let fileDigest: Data
    let lastPublishedHash: String
    let lastPublishedAtMilliseconds: Int64
    let hashAlgorithmVersion: Int?
}

nonisolated struct DecodedLegacyState: Equatable, Sendable {
    let customPathsFilePresent: Bool
    let customPaths: [LegacyCustomPathRecord]
    let publishStates: [LegacyPublishStateRecord]
}

nonisolated struct NormalizedCustomPathURL: Equatable, Sendable {
    let absoluteURL: String
    let key: Data
}

nonisolated enum LegacyCustomPathURLNormalizer {
    static func normalize(_ rawValue: String) throws -> NormalizedCustomPathURL {
        guard hasValidPercentSyntax(rawValue),
              let url = URL(string: rawValue), url.scheme?.lowercased() == "file",
              let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              components.query == nil, components.fragment == nil,
              components.user == nil, components.password == nil, components.port == nil,
              components.host.map({ $0.isEmpty || $0.lowercased() == "localhost" }) ?? true else {
            throw LegacyMigrationFailure(.customPathURLInvalid)
        }

        let encodedPath = url.path(percentEncoded: true)
        guard let decodedPath = strictPercentDecodedUTF8(encodedPath),
              !decodedPath.isEmpty, decodedPath.first == "/", !decodedPath.contains("\0"),
              url.path(percentEncoded: false) == decodedPath else {
            throw LegacyMigrationFailure(.customPathURLInvalid)
        }

        let standardized = URL(fileURLWithPath: decodedPath, isDirectory: true).standardizedFileURL
        var key = standardized.path(percentEncoded: false)
        if key.count > 1, key.hasSuffix("/") { key.removeLast() }
        key = key.precomposedStringWithCanonicalMapping
        let absoluteURL = standardized.absoluteString
        guard 1...8_192 ~= absoluteURL.utf8.count,
              1...8_192 ~= key.utf8.count else {
            throw LegacyMigrationFailure(.customPathURLInvalid)
        }
        return NormalizedCustomPathURL(
            absoluteURL: absoluteURL,
            key: Data(key.utf8)
        )
    }

    private static func hasValidPercentSyntax(_ value: String) -> Bool {
        let bytes = Array(value.utf8)
        var index = 0
        while index < bytes.count {
            if bytes[index] == 0x25 {
                guard index + 2 < bytes.count,
                      hexValue(bytes[index + 1]) != nil,
                      hexValue(bytes[index + 2]) != nil else { return false }
                index += 3
            } else {
                index += 1
            }
        }
        return true
    }

    private static func strictPercentDecodedUTF8(_ value: String) -> String? {
        let input = Array(value.utf8)
        var output: [UInt8] = []
        var index = 0
        while index < input.count {
            if input[index] == 0x25 {
                guard index + 2 < input.count,
                      let high = hexValue(input[index + 1]),
                      let low = hexValue(input[index + 2]) else { return nil }
                output.append(high * 16 + low)
                index += 3
            } else {
                output.append(input[index])
                index += 1
            }
        }
        return String(bytes: output, encoding: .utf8)
    }

    private static func hexValue(_ byte: UInt8) -> UInt8? {
        switch byte {
        case 0x30...0x39: byte - 0x30
        case 0x41...0x46: byte - 0x41 + 10
        case 0x61...0x66: byte - 0x61 + 10
        default: nil
        }
    }
}

nonisolated enum LegacyDateCodec {
    static func milliseconds(fromReferenceDateNumber value: String) throws -> Int64 {
        guard let seconds = Double(value), seconds.isFinite else {
            throw LegacyMigrationFailure(.legacyDateOutOfRange)
        }
        let rawMilliseconds = seconds * 1_000
            + Date.timeIntervalBetween1970AndReferenceDate * 1_000
        return try encode(rawMilliseconds)
    }

    static func milliseconds(from date: Date) throws -> Int64 {
        try encode(date.timeIntervalSince1970 * 1_000)
    }

    private static func encode(_ rawMilliseconds: Double) throws -> Int64 {
        guard rawMilliseconds.isFinite else {
            throw LegacyMigrationFailure(.legacyDateOutOfRange)
        }
        let rounded = rawMilliseconds.rounded(.toNearestOrAwayFromZero)
        guard rounded >= -9_223_372_036_854_775_808.0,
              rounded < 9_223_372_036_854_775_808.0 else {
            throw LegacyMigrationFailure(.legacyDateOutOfRange)
        }
        let milliseconds = Int64(rounded)
        let restored = Date(timeIntervalSince1970: Double(milliseconds) / 1_000)
        guard restored.timeIntervalSince1970.isFinite,
              abs(Double(milliseconds) - rawMilliseconds) <= 0.5 else {
            throw LegacyMigrationFailure(.legacyDateOutOfRange)
        }
        return milliseconds
    }
}

nonisolated enum PublishStateLocator {
    static func fromSlug(_ slug: String) throws -> String {
        let leaf = slug.precomposedStringWithCanonicalMapping
        guard leaf == slug, !leaf.isEmpty, leaf != ".", leaf != "..",
              !leaf.contains("/"), !leaf.contains("\0") else {
            throw LegacyMigrationFailure(.legacyDuplicateRecord)
        }
        let locator = "skill-state/\(leaf).json"
        guard 1...512 ~= locator.utf8.count else {
            throw LegacyMigrationFailure(.legacyResourceLimitExceeded)
        }
        return locator
    }

    static func validateLegacy(_ locator: String) throws -> String {
        let prefix = "skill-state/"
        guard locator.hasPrefix(prefix), locator.hasSuffix(".json") else {
            throw LegacyMigrationFailure(.legacyInvalidJSON, locator: locator)
        }
        let start = locator.index(locator.startIndex, offsetBy: prefix.count)
        let end = locator.index(locator.endIndex, offsetBy: -5)
        let leaf = String(locator[start..<end])
        return try fromSlug(leaf)
    }
}
