import Foundation

extension SkillStore {
    nonisolated struct PublishState: Codable, Equatable {
        static let currentHashAlgorithmVersion = 1

        enum Resolution: Equatable {
            case unchanged
            case changed
            case migrate(PublishState)
        }

        let lastPublishedHash: String
        let lastPublishedAt: Date
        let hashAlgorithmVersion: Int?

        init(
            lastPublishedHash: String,
            lastPublishedAt: Date,
            hashAlgorithmVersion: Int? = currentHashAlgorithmVersion
        ) {
            self.lastPublishedHash = lastPublishedHash
            self.lastPublishedAt = lastPublishedAt
            self.hashAlgorithmVersion = hashAlgorithmVersion
        }

        func resolve(currentHash: String, legacyHash: String?) -> Resolution {
            switch hashAlgorithmVersion {
            case Self.currentHashAlgorithmVersion:
                return lastPublishedHash == currentHash ? .unchanged : .changed
            case nil:
                guard lastPublishedHash == legacyHash else { return .changed }
                return .migrate(PublishState(
                    lastPublishedHash: currentHash,
                    lastPublishedAt: lastPublishedAt
                ))
            default:
                return .changed
            }
        }
    }

    func loadPublishState(for slug: String) async throws -> PublishState? {
        guard let persistence else { throw LibraryPersistenceError.runtimeNotReady }
        guard let state = try await persistence.loadPublishState(forSlug: slug) else {
            return nil
        }
        return PublishState(
            lastPublishedHash: state.lastPublishedHash,
            lastPublishedAt: Date(
                timeIntervalSince1970: Double(state.lastPublishedAtMilliseconds) / 1_000
            ),
            hashAlgorithmVersion: state.hashAlgorithmVersion
        )
    }

    func savePublishState(for slug: String, hash: String) async throws {
        try await savePublishState(PublishState(
            lastPublishedHash: hash,
            lastPublishedAt: Date()
        ), for: slug)
    }

    func savePublishState(_ state: PublishState, for slug: String) async throws {
        guard let persistence else { throw LibraryPersistenceError.runtimeNotReady }
        let milliseconds = try LegacyDateCodec.milliseconds(from: state.lastPublishedAt)
        try await persistence.savePublishState(
            SQLitePublishState(
                lastPublishedHash: state.lastPublishedHash,
                lastPublishedAtMilliseconds: milliseconds,
                hashAlgorithmVersion: state.hashAlgorithmVersion
            ),
            forSlug: slug
        )
    }
}
