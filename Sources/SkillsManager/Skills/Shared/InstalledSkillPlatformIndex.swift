nonisolated struct InstalledSkillPlatformIndex: Equatable, Sendable {
    private let platformsByIdentityKey: [String: Set<SkillPlatform>]

    init(entries: [(slug: String, platform: SkillPlatform)]) {
        var platformsByIdentityKey: [String: Set<SkillPlatform>] = [:]
        for entry in entries {
            let key = SkillContentPath.collisionKey(for: entry.slug)
            platformsByIdentityKey[key, default: []].insert(entry.platform)
        }
        self.platformsByIdentityKey = platformsByIdentityKey
    }

    func platforms(forSlug slug: String) -> Set<SkillPlatform> {
        platformsByIdentityKey[SkillContentPath.collisionKey(for: slug), default: []]
    }
}
