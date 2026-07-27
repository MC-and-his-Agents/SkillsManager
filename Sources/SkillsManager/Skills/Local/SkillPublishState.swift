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
        return PublishState(state)
    }

    func savePublishState(for slug: String, hash: String) async throws {
        try await savePublishState(PublishState(
            lastPublishedHash: hash,
            lastPublishedAt: Date()
        ), for: slug)
    }

    func savePublishState(_ state: PublishState, for slug: String) async throws {
        guard let persistence else { throw LibraryPersistenceError.runtimeNotReady }
        try await persistence.savePublishState(
            try state.sqliteState(),
            forSlug: slug
        )
    }

    func loadPublishState(for skillID: SkillID) async throws -> PublishState? {
        guard let persistence else { throw LibraryPersistenceError.runtimeNotReady }
        return try await persistence.loadManagedPublishState(skillID).map(PublishState.init)
    }

    func savePublishState(for skillID: SkillID, hash: String) async throws {
        try await savePublishState(
            PublishState(lastPublishedHash: hash, lastPublishedAt: Date()),
            for: skillID
        )
    }

    func savePublishState(_ state: PublishState, for skillID: SkillID) async throws {
        guard let persistence else { throw LibraryPersistenceError.runtimeNotReady }
        try await persistence.saveManagedPublishState(try state.sqliteState(), skillID: skillID)
    }
}

private extension SkillStore.PublishState {
    init(_ state: SQLitePublishState) {
        self.init(
            lastPublishedHash: state.lastPublishedHash,
            lastPublishedAt: Date(
                timeIntervalSince1970: Double(state.lastPublishedAtMilliseconds) / 1_000
            ),
            hashAlgorithmVersion: state.hashAlgorithmVersion
        )
    }

    func sqliteState() throws -> SQLitePublishState {
        SQLitePublishState(
            lastPublishedHash: lastPublishedHash,
            lastPublishedAtMilliseconds: try LegacyDateCodec.milliseconds(from: lastPublishedAt),
            hashAlgorithmVersion: hashAlgorithmVersion
        )
    }
}
