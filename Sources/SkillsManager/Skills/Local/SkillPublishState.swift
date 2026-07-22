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

    func loadPublishState(for slug: String) -> PublishState? {
        let url = publishStateURL(for: slug)
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(PublishState.self, from: data)
    }

    func savePublishState(for slug: String, hash: String) {
        savePublishState(PublishState(
            lastPublishedHash: hash,
            lastPublishedAt: Date()
        ), for: slug)
    }

    func savePublishState(_ state: PublishState, for slug: String) {
        let directory = publishStateDirectory()
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        if let data = try? JSONEncoder().encode(state) {
            try? data.write(to: publishStateURL(for: slug), options: [.atomic])
        }
    }

    private func publishStateDirectory() -> URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)
            .first ?? FileManager.default.homeDirectoryForCurrentUser
        return base
            .appendingPathComponent("SkillsManager")
            .appendingPathComponent("skill-state")
    }

    private func publishStateURL(for slug: String) -> URL {
        publishStateDirectory().appendingPathComponent("\(slug).json")
    }
}
