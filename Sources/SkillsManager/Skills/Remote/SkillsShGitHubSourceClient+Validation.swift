import Foundation

nonisolated extension SkillsShGitHubContract {
    static func validatedEntries(
        _ rawEntries: [TreeResponse.Entry]
    ) throws -> [TreeEntry] {
        var entries: [TreeEntry] = []
        entries.reserveCapacity(rawEntries.count)
        var exactPaths = Set<String>()
        var collisionPaths = Set<String>()

        for raw in rawEntries {
            let components = try pathComponents(raw.path)
            let path = components.joined(separator: "/")
            guard validSHA(raw.sha),
                  exactPaths.insert(path).inserted,
                  collisionPaths.insert(
                    components.map(SkillContentPath.collisionKey).joined(separator: "/")
                  ).inserted else {
                throw SkillsShGitHubSourceError.contractChanged
            }
            switch (raw.type, raw.mode, raw.size) {
            case ("tree", "040000", nil),
                 ("commit", "160000", nil),
                 ("blob", "120000", _):
                break
            case ("blob", "100644", .some(let size)),
                 ("blob", "100755", .some(let size)):
                guard size >= 0 else { throw SkillsShGitHubSourceError.contractChanged }
            default:
                throw SkillsShGitHubSourceError.contractChanged
            }
            entries.append(TreeEntry(
                path: path,
                components: components,
                mode: raw.mode,
                type: raw.type,
                sha: raw.sha,
                size: raw.size
            ))
        }

        let byPath = Dictionary(uniqueKeysWithValues: entries.map { ($0.path, $0) })
        for entry in entries where entry.components.count > 1 {
            for end in 1..<entry.components.count {
                let prefix = entry.components[..<end].joined(separator: "/")
                if let ancestor = byPath[prefix], ancestor.type != "tree" {
                    throw SkillsShGitHubSourceError.contractChanged
                }
            }
        }
        return entries
    }

    static func target(
        in entries: [TreeEntry],
        skillID: String
    ) throws -> (RepositorySubpath, [SkillsShGitHubBlob]) {
        let matches = entries.filter {
            $0.type == "blob"
                && ($0.mode == "100644" || $0.mode == "100755")
                && $0.components.last == "SKILL.md"
                && $0.components.count > 1
                && $0.components[$0.components.count - 2] == skillID
        }
        guard matches.count == 1 else {
            throw SkillsShGitHubSourceError.noUniqueSkillMatch
        }
        let targetComponents = Array(matches[0].components.dropLast())
        let targetPath = targetComponents.joined(separator: "/")
        guard entries.contains(where: {
            $0.path == targetPath && $0.type == "tree" && $0.mode == "040000"
        }) else {
            throw SkillsShGitHubSourceError.contractChanged
        }

        var blobs: [SkillsShGitHubBlob] = []
        for entry in entries where entry.path == targetPath || entry.path.hasPrefix(targetPath + "/") {
            guard entry.path != targetPath else { continue }
            if entry.type == "tree", entry.mode == "040000" { continue }
            guard entry.type == "blob",
                  entry.mode == "100644" || entry.mode == "100755",
                  let size = entry.size else {
                throw SkillsShGitHubSourceError.contractChanged
            }
            let relative = entry.components.dropFirst(targetComponents.count).joined(separator: "/")
            blobs.append(SkillsShGitHubBlob(
                relativePath: relative,
                mode: entry.mode,
                size: size,
                gitBlobSHA: entry.sha
            ))
        }
        guard blobs.contains(where: { $0.relativePath == "SKILL.md" }) else {
            throw SkillsShGitHubSourceError.contractChanged
        }
        blobs.sort { $0.relativePath.utf8.lexicographicallyPrecedes($1.relativePath.utf8) }
        return (try RepositorySubpath(targetPath), blobs)
    }

    static func exactTarget(
        in entries: [TreeEntry],
        subpath: RepositorySubpath
    ) throws -> [SkillsShGitHubBlob] {
        let targetComponents = try pathComponents(subpath.value)
        let targetKey = targetComponents.map(SkillContentPath.collisionKey).joined(separator: "/")
        let skillPathKey = targetKey + "/" + SkillContentPath.collisionKey(for: "SKILL.md")
        let matches = entries.filter {
            $0.type == "blob"
                && ($0.mode == "100644" || $0.mode == "100755")
                && $0.components.map(SkillContentPath.collisionKey).joined(separator: "/")
                    == skillPathKey
        }
        guard matches.count == 1 else {
            throw SkillsShGitHubSourceError.noUniqueSkillMatch
        }
        let actualTargetComponents = Array(matches[0].components.dropLast())
        let actualTargetPath = actualTargetComponents.joined(separator: "/")
        guard entries.contains(where: {
            $0.path == actualTargetPath && $0.type == "tree" && $0.mode == "040000"
        }) else {
            throw SkillsShGitHubSourceError.contractChanged
        }

        var blobs: [SkillsShGitHubBlob] = []
        for entry in entries
            where entry.path.hasPrefix(actualTargetPath + "/") {
            if entry.type == "tree", entry.mode == "040000" { continue }
            guard entry.type == "blob",
                  entry.mode == "100644" || entry.mode == "100755",
                  let size = entry.size else {
                throw SkillsShGitHubSourceError.contractChanged
            }
            blobs.append(SkillsShGitHubBlob(
                relativePath: entry.components
                    .dropFirst(actualTargetComponents.count)
                    .joined(separator: "/"),
                mode: entry.mode,
                size: size,
                gitBlobSHA: entry.sha
            ))
        }
        blobs.sort { $0.relativePath.utf8.lexicographicallyPrecedes($1.relativePath.utf8) }
        return blobs
    }

    static func apiRequest(
        path: [String],
        queryItems: [URLQueryItem] = []
    ) throws -> URLRequest {
        request(
            url: try apiURL(path: path, queryItems: queryItems),
            accept: "application/vnd.github+json",
            timeout: 10
        )
    }

    static func apiURL(
        path: [String],
        queryItems: [URLQueryItem] = []
    ) throws -> URL {
        var components = URLComponents()
        components.scheme = "https"
        components.host = "api.github.com"
        components.percentEncodedPath = "/" + path.map(percentEncodedPathComponent).joined(separator: "/")
        if !queryItems.isEmpty {
            components.queryItems = queryItems
        }
        guard let url = components.url else { throw SkillsShGitHubSourceError.invalidSource }
        return url
    }

    static func request(url: URL, accept: String, timeout: TimeInterval) -> URLRequest {
        var request = URLRequest(
            url: url,
            cachePolicy: .reloadIgnoringLocalCacheData,
            timeoutInterval: timeout
        )
        request.httpMethod = "GET"
        request.setValue(accept, forHTTPHeaderField: "Accept")
        request.setValue("2022-11-28", forHTTPHeaderField: "X-GitHub-Api-Version")
        request.setValue("SkillsManager/0.2.0", forHTTPHeaderField: "User-Agent")
        return request
    }

    static func throwHTTPError(
        _ response: HTTPURLResponse,
        expectedStatus: Int
    ) throws {
        guard response.statusCode == expectedStatus else {
            switch response.statusCode {
            case 403, 429: throw SkillsShGitHubSourceError.rateLimited
            case 404: throw SkillsShGitHubSourceError.repositoryUnavailable
            case 500...599: throw SkillsShGitHubSourceError.providerUnavailable
            default: throw SkillsShGitHubSourceError.contractChanged
            }
        }
    }

    static func validateResponseURL(
        _ response: HTTPURLResponse,
        requestURL: URL?
    ) throws {
        guard let requestURL, response.url == requestURL else {
            throw SkillsShGitHubSourceError.contractChanged
        }
    }

    static func validCodeloadURL(
        _ url: URL,
        owner: String,
        repository: String,
        commitSHA: String
    ) -> Bool {
        guard !url.absoluteString.contains("%"),
              let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              components.scheme == "https",
              components.host?.lowercased() == "codeload.github.com",
              components.port == nil,
              components.user == nil,
              components.password == nil,
              components.query == nil,
              components.fragment == nil else {
            return false
        }
        let path = components.path.split(separator: "/", omittingEmptySubsequences: false)
        return path.count == 5
            && path[0].isEmpty
            && asciiEqual(String(path[1]), owner)
            && asciiEqual(String(path[2]), repository)
            && path[3] == "legacy.zip"
            && path[4] == Substring(commitSHA)
    }

    static func pathComponents(_ path: String) throws -> [String] {
        guard !path.isEmpty, path.utf8.count <= 4_096 else {
            throw SkillsShGitHubSourceError.contractChanged
        }
        let raw = path.split(separator: "/", omittingEmptySubsequences: false)
        guard !raw.isEmpty else { throw SkillsShGitHubSourceError.contractChanged }
        return try raw.map {
            let normalized = String($0).precomposedStringWithCanonicalMapping
            guard !normalized.isEmpty,
                  normalized != ".",
                  normalized != "..",
                  !normalized.contains("\\"),
                  !normalized.contains("\0"),
                  !normalized.contains("%"),
                  !normalized.unicodeScalars.contains(where: {
                      CharacterSet.controlCharacters.contains($0)
                  }) else {
                throw SkillsShGitHubSourceError.contractChanged
            }
            return normalized
        }
    }

    static func canonicalAlias(
        id: String,
        source: String,
        skillID: String
    ) throws -> String {
        let data = try JSONSerialization.data(
            withJSONObject: ["id": id, "skillId": skillID, "source": source],
            options: [.sortedKeys, .withoutEscapingSlashes]
        )
        guard data.count <= 1_024, let value = String(data: data, encoding: .utf8) else {
            throw SkillsShGitHubSourceError.invalidSource
        }
        return value
    }

    static func validOwner(_ value: String) -> Bool {
        1...39 ~= value.utf8.count
            && value.utf8.allSatisfy { asciiLetterOrDigit($0) || $0 == 0x2D }
            && value.first != "-"
            && value.last != "-"
    }

    static func validRepository(_ value: String) -> Bool {
        1...100 ~= value.utf8.count
            && value != "."
            && value != ".."
            && value.utf8.allSatisfy {
                asciiLetterOrDigit($0) || $0 == 0x2E || $0 == 0x5F || $0 == 0x2D
            }
    }

    static func validDefaultBranch(_ value: String) -> Bool {
        !value.isEmpty
            && value.utf8.count <= 512
            && !value.contains("\0")
            && !value.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) })
    }

    static func validSHA(_ value: String) -> Bool {
        value.utf8.count == 40
            && value.unicodeScalars.allSatisfy { hexadecimal.contains($0) }
    }

    static func asciiEqual(_ lhs: String, _ rhs: String) -> Bool {
        lhs.utf8.count == rhs.utf8.count
            && zip(lhs.utf8, rhs.utf8).allSatisfy { asciiLower($0) == asciiLower($1) }
    }

    static func asciiLower(_ value: UInt8) -> UInt8 {
        0x41...0x5A ~= value ? value + 0x20 : value
    }

    static func asciiLetterOrDigit(_ value: UInt8) -> Bool {
        0x41...0x5A ~= value || 0x61...0x7A ~= value || 0x30...0x39 ~= value
    }

    static func percentEncodedPathComponent(_ value: String) -> String {
        value.utf8.map { byte in
            if asciiLetterOrDigit(byte) || [0x2D, 0x2E, 0x5F, 0x7E].contains(byte) {
                return String(UnicodeScalar(byte))
            }
            return String(format: "%%%02X", byte)
        }.joined()
    }

    static func baseMIME(_ response: HTTPURLResponse) -> String {
        response.value(forHTTPHeaderField: "Content-Type")?
            .split(separator: ";", maxSplits: 1)
            .first?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased() ?? ""
    }
}
