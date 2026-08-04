import Foundation

nonisolated enum CustomRepositoryRef: Equatable, Sendable {
    case defaultBranch
    case explicit(String)

    static func explicit(validating rawValue: String) throws -> Self {
        let value = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
        let invalid = CharacterSet.controlCharacters
            .union(.whitespacesAndNewlines)
            .union(CharacterSet(charactersIn: "\\~^:?*[") )
        let segments = value.split(separator: "/", omittingEmptySubsequences: false)
        guard 1...512 ~= value.utf8.count,
              !value.unicodeScalars.contains(where: invalid.contains),
              value.first != "/", value.last != "/",
              value.first != ".", value.last != ".",
              !value.contains("//"), !value.contains(".."), !value.contains("@{"),
              segments.allSatisfy({ !$0.isEmpty && !$0.hasSuffix(".lock") }) else {
            throw CustomRepositoryCatalogError.invalidRef
        }
        return .explicit(value)
    }
}

nonisolated struct CustomRepositoryCatalogRecord: Equatable, Sendable {
    let repositoryID: UUID
    let repositoryURL: NormalizedRepositoryURL
    let requestedRef: CustomRepositoryRef
    let displayName: String
    let enabled: Bool
    let createdAtMilliseconds: Int64
    let updatedAtMilliseconds: Int64
    let databaseRevision: Int64
}

nonisolated struct CustomRepositoryCatalogInput: Equatable, Sendable {
    let repositoryURL: NormalizedRepositoryURL
    let requestedRef: CustomRepositoryRef
    let displayName: String
    let enabled: Bool

    init(
        repositoryURL rawURL: String,
        requestedRef: CustomRepositoryRef = .defaultBranch,
        displayName rawDisplayName: String? = nil,
        enabled: Bool = true
    ) throws {
        let repositoryURL = try CustomRepositoryCatalogValidation.githubURL(rawURL)
        let displayName = rawDisplayName
            ?? repositoryURL.value.dropFirst("https://github.com/".count).description
        try CustomRepositoryCatalogValidation.validate(displayName: displayName)
        let normalizedRef = switch requestedRef {
        case .defaultBranch: CustomRepositoryRef.defaultBranch
        case .explicit(let value): try CustomRepositoryRef.explicit(validating: value)
        }
        self.repositoryURL = repositoryURL
        self.requestedRef = normalizedRef
        self.displayName = displayName
        self.enabled = enabled
    }
}

nonisolated enum CustomRepositoryCatalogError: Error, Equatable, Sendable {
    case invalidURL
    case invalidRef
    case invalidDisplayName
    case alreadyExists
    case notFound
    case conflict
    case corruptRecord
}

nonisolated enum CustomRepositoryCatalogValidation {
    static func githubURL(_ rawValue: String) throws -> NormalizedRepositoryURL {
        guard rawValue.hasPrefix("https://"),
              let components = URLComponents(string: rawValue),
              components.scheme == "https",
              components.host?.lowercased() == "github.com",
              components.port == nil,
              components.user == nil,
              components.password == nil,
              components.query == nil,
              components.fragment == nil else {
            throw CustomRepositoryCatalogError.invalidURL
        }
        do {
            let normalized = try NormalizedRepositoryURL(rawValue)
            let path = normalized.value.dropFirst("https://github.com/".count)
                .split(separator: "/", omittingEmptySubsequences: false)
            guard path.count == 2,
                  SkillsShGitHubContract.validOwner(String(path[0])),
                  SkillsShGitHubContract.validRepository(String(path[1])) else {
                throw CustomRepositoryCatalogError.invalidURL
            }
            return normalized
        } catch {
            throw CustomRepositoryCatalogError.invalidURL
        }
    }

    static func validate(displayName: String) throws {
        guard 1...512 ~= displayName.utf8.count,
              !displayName.contains("\0"),
              !displayName.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains) else {
            throw CustomRepositoryCatalogError.invalidDisplayName
        }
    }
}
