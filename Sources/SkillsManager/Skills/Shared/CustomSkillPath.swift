import Foundation

nonisolated enum CustomSkillPathMode: Codable, Hashable, Sendable {
    case project
    case collection(adapter: SkillPlatform)

    var adapter: SkillPlatform? {
        if case .collection(let adapter) = self { return adapter }
        return nil
    }

    var storageKey: String {
        switch self {
        case .project: "project"
        case .collection: "collection"
        }
    }

    static let directPathVariant = "direct"

    static func suggestedAdapters(for url: URL) -> [SkillPlatform] {
        let components = url.standardizedFileURL.path
            .split(separator: "/", omittingEmptySubsequences: true)
            .map(String.init)
        guard !components.isEmpty else { return [] }
        return SkillPlatform.allCases.filter { platform in
            let paths = Set([platform.dedicatedDistributionRelativePath]
                + platform.relativePaths
                + platform.discoveryCompatibilityRelativePaths)
            return paths.contains { path in
                let suffix = path.split(separator: "/", omittingEmptySubsequences: true)
                    .map(String.init)
                return components.count >= suffix.count
                    && Array(components.suffix(suffix.count)) == suffix
            }
        }
    }

    init(storageKey: String, adapterCode: String?) throws {
        switch storageKey {
        case "project":
            guard adapterCode == nil else { throw CustomPathError.invalidMode }
            self = .project
        case "collection":
            guard let adapterCode,
                  let adapter = SkillPlatform.allCases.first(where: {
                      $0.storageKey == adapterCode
                  }) else {
                throw CustomPathError.invalidMode
            }
            self = .collection(adapter: adapter)
        default:
            throw CustomPathError.invalidMode
        }
    }

    static func collection(adapterCode: String) -> Self? {
        guard let adapter = SkillPlatform.allCases.first(where: {
            $0.storageKey == adapterCode
        }) else { return nil }
        return .collection(adapter: adapter)
    }
}

nonisolated struct CustomSkillPath: Identifiable, Codable, Hashable, Sendable {
    let id: UUID
    let url: URL
    let displayName: String
    let addedAt: Date
    let mode: CustomSkillPathMode

    init(
        url: URL,
        mode: CustomSkillPathMode = .project,
        displayName: String? = nil
    ) {
        self.id = UUID()
        self.url = url
        self.displayName = displayName ?? url.lastPathComponent
        self.addedAt = Date()
        self.mode = mode
    }

    init(
        id: UUID,
        url: URL,
        displayName: String,
        addedAt: Date,
        mode: CustomSkillPathMode = .project
    ) {
        self.id = id
        self.url = url
        self.displayName = displayName
        self.addedAt = addedAt
        self.mode = mode
    }

    var storageKey: String {
        "custom-\(id.uuidString.prefix(8).lowercased())"
    }

    private enum CodingKeys: String, CodingKey {
        case id
        case url
        case displayName
        case addedAt
        case mode
        case adapterCode
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        url = try container.decode(URL.self, forKey: .url)
        displayName = try container.decode(String.self, forKey: .displayName)
        addedAt = try container.decode(Date.self, forKey: .addedAt)
        let modeKey = try container.decodeIfPresent(String.self, forKey: .mode) ?? "project"
        let adapterCode = try container.decodeIfPresent(String.self, forKey: .adapterCode)
        mode = try CustomSkillPathMode(storageKey: modeKey, adapterCode: adapterCode)
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(url, forKey: .url)
        try container.encode(displayName, forKey: .displayName)
        try container.encode(addedAt, forKey: .addedAt)
        // Keep project records byte-compatible with the legacy JSON archive.
        if case .collection(let adapter) = mode {
            try container.encode(mode.storageKey, forKey: .mode)
            try container.encode(adapter.storageKey, forKey: .adapterCode)
        }
    }
}
