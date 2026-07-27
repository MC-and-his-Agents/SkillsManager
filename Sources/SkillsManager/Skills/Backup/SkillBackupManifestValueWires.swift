import Foundation

nonisolated extension SkillBackupManifestV1 {
    struct ProvenanceWire: Codable {
        let provider: String
        let identifier: String
        let identifierKey: String
        let version: String?

        enum CodingKeys: String, CodingKey {
            case identifier
            case identifierKey = "identifier_key"
            case provider
            case version
        }

        init(_ provenance: ProviderProvenanceRecord) {
            provider = provenance.identity.provider
            identifier = provenance.identity.identifier
            identifierKey = provenance.identifierKey
            version = provenance.version?.value
        }

        var sortKey: String { provider + "\u{0}" + identifierKey }

        func record(skillID: SkillID) throws -> ProviderProvenanceRecord {
            try ProviderProvenanceRecord(
                skillID: skillID,
                identity: ProviderAliasIdentity(
                    provider: provider,
                    identifier: identifier
                ),
                identifierKey: identifierKey,
                version: try version.map(SourceVersion.init)
            )
        }
    }

    struct ContentWire: Codable {
        let fingerprintAlgorithmVersion: Int
        let contentFingerprint: String
        let fileCount: Int
        let totalByteCount: UInt64

        enum CodingKeys: String, CodingKey {
            case contentFingerprint = "content_fingerprint"
            case fileCount = "file_count"
            case fingerprintAlgorithmVersion = "fingerprint_algorithm_version"
            case totalByteCount = "total_byte_count"
        }

        init(
            fingerprint: SkillContentFingerprint,
            statistics: SkillContentSnapshot.Statistics
        ) {
            fingerprintAlgorithmVersion = fingerprint.algorithmVersion
            contentFingerprint = lowerHex(fingerprint.digest)
            fileCount = statistics.fileCount
            totalByteCount = statistics.totalByteCount
        }

        var fingerprint: SkillContentFingerprint {
            get throws {
                try SkillContentFingerprint(
                    algorithmVersion: fingerprintAlgorithmVersion,
                    digest: try lowerHexData(contentFingerprint)
                )
            }
        }

        var statistics: SkillContentSnapshot.Statistics {
            .init(fileCount: fileCount, totalByteCount: totalByteCount)
        }
    }
}
