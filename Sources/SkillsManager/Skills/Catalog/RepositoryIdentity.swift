import Foundation

nonisolated enum RepositoryIdentityError: Error, Equatable {
    case invalidURL
    case ambiguousGitSuffix
    case URLTooLong
}

nonisolated struct NormalizedRepositoryURL: Hashable, Sendable {
    let value: String

    init(_ rawValue: String) throws {
        let normalized: String
        if rawValue.hasPrefix("git@"),
           rawValue.dropFirst(4).lowercased().hasPrefix("github.com:") {
            normalized = try Self.normalizeGitHubSCP(rawValue)
        } else {
            guard let components = URLComponents(string: rawValue),
                  let host = components.host,
                  !host.isEmpty,
                  !host.hasSuffix(".") else {
                throw RepositoryIdentityError.invalidURL
            }
            if host.lowercased() == "github.com" {
                normalized = try Self.normalizeGitHubURL(components, rawValue: rawValue)
            } else {
                normalized = try Self.normalizeGenericHTTPS(components, rawValue: rawValue)
            }
        }

        guard normalized.utf8.count <= 2_048 else {
            throw RepositoryIdentityError.URLTooLong
        }
        value = normalized
    }

    private static func normalizeGitHubSCP(_ rawValue: String) throws -> String {
        let userPrefix = "git@"
        let hostPrefix = "github.com:"
        guard rawValue.hasPrefix(userPrefix),
              rawValue.dropFirst(userPrefix.count).lowercased().hasPrefix(hostPrefix),
              rawValue.count > userPrefix.count + hostPrefix.count else {
            throw RepositoryIdentityError.invalidURL
        }
        return try normalizedGitHubPath(String(
            rawValue.dropFirst(userPrefix.count + hostPrefix.count)
        ))
    }

    private static func normalizeGitHubURL(
        _ components: URLComponents,
        rawValue: String
    ) throws -> String {
        guard components.port == nil,
              !Self.authority(in: rawValue).hasSuffix(":"),
              components.query == nil,
              components.fragment == nil,
              components.password == nil,
              let scheme = components.scheme?.lowercased() else {
            throw RepositoryIdentityError.invalidURL
        }

        switch scheme {
        case "https":
            guard components.user == nil else {
                throw RepositoryIdentityError.invalidURL
            }
        case "ssh":
            guard components.user == "git", components.percentEncodedUser == "git" else {
                throw RepositoryIdentityError.invalidURL
            }
        default:
            throw RepositoryIdentityError.invalidURL
        }

        guard components.percentEncodedPath.hasPrefix("/") else {
            throw RepositoryIdentityError.invalidURL
        }
        return try normalizedGitHubPath(String(components.percentEncodedPath.dropFirst()))
    }

    private static func authority(in rawValue: String) -> Substring {
        guard let separator = rawValue.range(of: "://") else { return "" }
        let remainder = rawValue[separator.upperBound...]
        let end = remainder.firstIndex(where: { $0 == "/" || $0 == "?" || $0 == "#" })
            ?? remainder.endIndex
        return remainder[..<end]
    }

    private static func normalizedGitHubPath(_ path: String) throws -> String {
        guard !path.contains("%"),
              !path.contains("\\"),
              !path.hasSuffix("/") else {
            throw RepositoryIdentityError.invalidURL
        }
        let components = path.split(separator: "/", omittingEmptySubsequences: false)
        guard components.count == 2 else {
            throw RepositoryIdentityError.invalidURL
        }

        let owner = String(components[0])
        var repository = String(components[1])
        guard validGitHubSegment(owner), validGitHubSegment(repository) else {
            throw RepositoryIdentityError.invalidURL
        }

        if repository.lowercased().hasSuffix(".git") {
            guard repository.hasSuffix(".git") else {
                throw RepositoryIdentityError.ambiguousGitSuffix
            }
            repository.removeLast(4)
            guard !repository.lowercased().hasSuffix(".git"),
                  validGitHubSegment(repository) else {
                throw RepositoryIdentityError.ambiguousGitSuffix
            }
        }
        return "https://github.com/\(owner.lowercased())/\(repository.lowercased())"
    }

    private static func validGitHubSegment(_ value: String) -> Bool {
        guard !value.isEmpty, value != ".", value != ".." else { return false }
        return value.unicodeScalars.allSatisfy {
            $0.isASCII && $0.value > 0x20 && $0.value < 0x7f
                && $0 != "%" && $0 != "/" && $0 != "\\"
                && $0 != "?" && $0 != "#"
        }
    }

    private static func normalizeGenericHTTPS(
        _ input: URLComponents,
        rawValue: String
    ) throws -> String {
        guard input.scheme?.lowercased() == "https",
              !Self.authority(in: rawValue).hasSuffix(":"),
              input.user == nil,
              input.password == nil,
              input.query == nil,
              input.fragment == nil,
              let host = input.host,
              !host.isEmpty else {
            throw RepositoryIdentityError.invalidURL
        }

        var path = try decodeUnreserved(in: input.percentEncodedPath)
        path = removeDotSegments(from: path)
        while path.hasSuffix("/") { path.removeLast() }
        if path.hasSuffix(".git") {
            path.removeLast(4)
            guard !path.hasSuffix(".git") else {
                throw RepositoryIdentityError.ambiguousGitSuffix
            }
        }

        var output = URLComponents()
        output.scheme = "https"
        output.host = host.lowercased()
        output.port = input.port == 443 ? nil : input.port
        output.percentEncodedPath = path
        guard let normalized = output.url?.absoluteString else {
            throw RepositoryIdentityError.invalidURL
        }
        return normalized
    }

    private static func decodeUnreserved(in value: String) throws -> String {
        let bytes = Array(value.utf8)
        var output: [UInt8] = []
        var index = 0
        while index < bytes.count {
            guard bytes[index] == 0x25 else {
                output.append(bytes[index])
                index += 1
                continue
            }
            guard index + 2 < bytes.count,
                  let high = hexValue(bytes[index + 1]),
                  let low = hexValue(bytes[index + 2]) else {
                throw RepositoryIdentityError.invalidURL
            }
            let decoded = high << 4 | low
            if isUnreserved(decoded) {
                output.append(decoded)
            } else {
                output.append(contentsOf: [0x25, uppercaseHex(decoded >> 4), uppercaseHex(decoded & 0x0f)])
            }
            index += 3
        }
        guard let result = String(bytes: output, encoding: .utf8) else {
            throw RepositoryIdentityError.invalidURL
        }
        return result
    }

    private static func removeDotSegments(from value: String) -> String {
        var input = value
        var output = ""
        while !input.isEmpty {
            if input.hasPrefix("../") {
                input.removeFirst(3)
            } else if input.hasPrefix("./") {
                input.removeFirst(2)
            } else if input.hasPrefix("/./") {
                input.removeFirst(2)
            } else if input == "/." {
                input = "/"
            } else if input.hasPrefix("/../") {
                input.removeFirst(3)
                removeLastPathSegment(from: &output)
            } else if input == "/.." {
                input = "/"
                removeLastPathSegment(from: &output)
            } else if input == "." || input == ".." {
                input = ""
            } else {
                let searchStart = input.hasPrefix("/") ? input.index(after: input.startIndex) : input.startIndex
                if let slash = input[searchStart...].firstIndex(of: "/") {
                    output += input[..<slash]
                    input.removeSubrange(..<slash)
                } else {
                    output += input
                    input = ""
                }
            }
        }
        return output
    }

    private static func removeLastPathSegment(from value: inout String) {
        guard let slash = value.lastIndex(of: "/") else {
            value = ""
            return
        }
        value.removeSubrange(slash...)
    }

    private static func isUnreserved(_ value: UInt8) -> Bool {
        (0x41...0x5a).contains(value) || (0x61...0x7a).contains(value)
            || (0x30...0x39).contains(value) || [0x2d, 0x2e, 0x5f, 0x7e].contains(value)
    }

    private static func hexValue(_ value: UInt8) -> UInt8? {
        switch value {
        case 0x30...0x39: value - 0x30
        case 0x41...0x46: value - 0x41 + 10
        case 0x61...0x66: value - 0x61 + 10
        default: nil
        }
    }

    private static func uppercaseHex(_ value: UInt8) -> UInt8 {
        value < 10 ? value + 0x30 : value - 10 + 0x41
    }
}

nonisolated struct SkillSourceRecord: Hashable, Sendable {
    let sourceID: SourceID
    let skillID: SkillID
    let repositoryURL: NormalizedRepositoryURL
    let subpath: RepositorySubpath
    let revision: SourceRevision?
    let version: SourceVersion?
    let downloadURL: PublicDownloadURL?

    init(
        sourceID: SourceID = SourceID(),
        skillID: SkillID,
        repositoryURL: NormalizedRepositoryURL,
        subpath: RepositorySubpath,
        revision: SourceRevision? = nil,
        version: SourceVersion? = nil,
        downloadURL: PublicDownloadURL? = nil
    ) {
        self.sourceID = sourceID
        self.skillID = skillID
        self.repositoryURL = repositoryURL
        self.subpath = subpath
        self.revision = revision
        self.version = version
        self.downloadURL = downloadURL
    }
}
