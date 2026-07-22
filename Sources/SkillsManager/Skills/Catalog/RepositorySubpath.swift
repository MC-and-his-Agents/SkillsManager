import Foundation

nonisolated enum RepositorySubpathError: Error, Equatable {
    case invalidPath
    case pathTooLong
}

nonisolated struct RepositorySubpath: Hashable, Sendable {
    let value: String

    init(_ rawValue: String) throws {
        guard !rawValue.hasPrefix("/"),
              !rawValue.hasSuffix("/"),
              !rawValue.contains("//"),
              !rawValue.contains("\\"),
              !rawValue.contains("\0"),
              !rawValue.contains("%") else {
            throw RepositorySubpathError.invalidPath
        }

        var components: [String] = []
        for component in rawValue.split(separator: "/", omittingEmptySubsequences: false) {
            if component == "." { continue }
            guard component != ".." else {
                throw RepositorySubpathError.invalidPath
            }
            components.append(String(component).precomposedStringWithCanonicalMapping)
        }

        let normalized = components.joined(separator: "/")
        guard normalized.utf8.count <= 1_024 else {
            throw RepositorySubpathError.pathTooLong
        }
        value = normalized
    }
}
