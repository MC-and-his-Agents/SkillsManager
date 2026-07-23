import Foundation

nonisolated enum LegacyStateWireDecoder {
    static func decodeCustomPaths(_ data: Data) throws -> [LegacyCustomPathRecord] {
        let root = try parse(data, locator: "custom-paths.json")
        guard case .array(let values) = root else {
            throw LegacyMigrationFailure(.legacyInvalidJSON, locator: "custom-paths.json")
        }
        var ids = Set<UUID>()
        var keys = Set<Data>()
        return try values.map { value in
            let object = try exactObject(
                value,
                required: ["id", "url", "displayName", "addedAt"],
                optional: [],
                locator: "custom-paths.json"
            )
            let id = try UUID(uuidString: string(object["id"], locator: "custom-paths.json"))
                .orThrow(LegacyMigrationFailure(.legacyInvalidJSON, locator: "custom-paths.json"))
            let normalized = try LegacyCustomPathURLNormalizer.normalize(
                string(object["url"], locator: "custom-paths.json")
            )
            let displayName = try string(object["displayName"], locator: "custom-paths.json")
            guard 1...512 ~= displayName.utf8.count else {
                throw LegacyMigrationFailure(.legacyResourceLimitExceeded, locator: "custom-paths.json")
            }
            let addedAt = try LegacyDateCodec.milliseconds(
                fromReferenceDateNumber: number(object["addedAt"], locator: "custom-paths.json")
            )
            guard ids.insert(id).inserted, keys.insert(normalized.key).inserted else {
                throw LegacyMigrationFailure(.legacyDuplicateRecord, locator: "custom-paths.json")
            }
            return LegacyCustomPathRecord(
                id: id,
                absoluteURL: normalized.absoluteURL,
                normalizedURLKey: normalized.key,
                displayName: displayName,
                addedAtMilliseconds: addedAt
            )
        }
    }

    static func decodePublishState(
        _ data: Data,
        locator: String,
        digest: Data
    ) throws -> LegacyPublishStateRecord {
        let canonicalLocator = try PublishStateLocator.validateLegacy(locator)
        let object = try exactObject(
            parse(data, locator: locator),
            required: ["lastPublishedHash", "lastPublishedAt"],
            optional: ["hashAlgorithmVersion"],
            locator: locator
        )
        let hash = try string(object["lastPublishedHash"], locator: locator)
        guard 1...512 ~= hash.utf8.count else {
            throw LegacyMigrationFailure(.legacyResourceLimitExceeded, locator: locator)
        }
        let publishedAt = try LegacyDateCodec.milliseconds(
            fromReferenceDateNumber: number(object["lastPublishedAt"], locator: locator)
        )
        let algorithm: Int?
        if let raw = object["hashAlgorithmVersion"] {
            guard case .number(let value) = raw, value == "1" else {
                throw LegacyMigrationFailure(.legacyUnsupportedFormat, locator: locator)
            }
            algorithm = 1
        } else {
            algorithm = nil
        }
        return LegacyPublishStateRecord(
            locator: canonicalLocator,
            fileDigest: digest,
            lastPublishedHash: hash,
            lastPublishedAtMilliseconds: publishedAt,
            hashAlgorithmVersion: algorithm
        )
    }

    private static func parse(_ data: Data, locator: String) throws -> StrictLegacyJSONValue {
        do {
            var parser = try StrictLegacyJSONParser(data: data)
            return try parser.parse()
        } catch StrictLegacyJSONError.duplicateKey {
            throw LegacyMigrationFailure(.legacyDuplicateKey, locator: locator)
        } catch {
            throw LegacyMigrationFailure(.legacyInvalidJSON, locator: locator)
        }
    }

    private static func exactObject(
        _ value: StrictLegacyJSONValue,
        required: Set<String>,
        optional: Set<String>,
        locator: String
    ) throws -> [String: StrictLegacyJSONValue] {
        guard case .object(let object) = value else {
            throw LegacyMigrationFailure(.legacyInvalidJSON, locator: locator)
        }
        let keys = Set(object.keys)
        guard required.isSubset(of: keys) else {
            throw LegacyMigrationFailure(.legacyInvalidJSON, locator: locator)
        }
        guard keys.isSubset(of: required.union(optional)) else {
            throw LegacyMigrationFailure(.legacyUnsupportedFormat, locator: locator)
        }
        return object
    }

    private static func string(
        _ value: StrictLegacyJSONValue?,
        locator: String
    ) throws -> String {
        guard case .string(let result) = value else {
            throw LegacyMigrationFailure(.legacyInvalidJSON, locator: locator)
        }
        return result
    }

    private static func number(
        _ value: StrictLegacyJSONValue?,
        locator: String
    ) throws -> String {
        guard case .number(let result) = value else {
            throw LegacyMigrationFailure(.legacyInvalidJSON, locator: locator)
        }
        return result
    }
}

private nonisolated extension Optional {
    func orThrow(_ error: @autoclosure () -> Error) throws -> Wrapped {
        guard let self else { throw error() }
        return self
    }
}
