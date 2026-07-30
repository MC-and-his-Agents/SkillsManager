import Foundation

nonisolated struct DownloadedSkillArchive: Sendable {
    let url: URL
    let expectedIdentity: ManagedItemIdentity?
    private let cleanupLease: TemporaryItemLease?

    init(borrowedAt url: URL) {
        self.url = url
        expectedIdentity = nil
        cleanupLease = nil
    }

    static func takeOwnership(of url: URL) throws -> DownloadedSkillArchive {
        let lease = try TemporaryItemLease.captureFile(at: url)
        return DownloadedSkillArchive(url: lease.url, cleanupLease: lease)
    }

    func removeIfOwned() throws {
        try cleanupLease?.removeIfCurrent()
    }

    private init(url: URL, cleanupLease: TemporaryItemLease) {
        self.url = url
        expectedIdentity = cleanupLease.identity
        self.cleanupLease = cleanupLease
    }
}

nonisolated enum RemoteSkillClientError: Error, Equatable, LocalizedError, Sendable {
    case rateLimited
    case providerUnavailable
    case invalidResponse

    var errorDescription: String? {
        switch self {
        case .rateLimited: "Clawdhub rate limited this request."
        case .providerUnavailable: "Clawdhub is temporarily unavailable."
        case .invalidResponse: "Clawdhub returned an invalid response."
        }
    }
}

nonisolated struct RemoteSkillPage: Sendable {
    let items: [RemoteSkill]
    let nextCursor: String?
}

nonisolated struct RemoteSkillClient: Sendable {
    typealias DataLoader = @Sendable (URL) async throws -> (Data, URLResponse)

    var fetchLatest: @Sendable (
        _ limit: Int,
        _ cursor: String?
    ) async throws -> RemoteSkillPage
    var search: @Sendable (_ query: String, _ limit: Int) async throws -> [RemoteSkill]
    var download: @Sendable (
        _ slug: String,
        _ version: String?
    ) async throws -> DownloadedSkillArchive
    var fetchDetail: @Sendable (_ slug: String) async throws -> RemoteSkillOwner?
    var fetchLatestVersion: @Sendable (_ slug: String) async throws -> String?
}

extension RemoteSkillClient {
    // Static URLSession configured with URLCache (10MB memory, 50MB disk)
    // Shared across all client instances for efficiency
    private static let session: URLSession = {
        let urlCache = URLCache(
            memoryCapacity: 10 * 1024 * 1024,
            diskCapacity: 50 * 1024 * 1024
        )
        let config = URLSessionConfiguration.default
        config.urlCache = urlCache
        return URLSession(configuration: config)
    }()

    static func live(
        baseURL: URL = URL(string: "https://clawhub.ai")!,
        load: @escaping DataLoader = { try await Self.session.data(from: $0) }
    ) -> RemoteSkillClient {
        let session = Self.session

        return RemoteSkillClient(
            fetchLatest: { limit, cursor in
                var components = URLComponents(
                    url: baseURL.appendingPathComponent("/api/v1/skills"),
                    resolvingAgainstBaseURL: false
                )
                var queryItems = [
                    URLQueryItem(name: "limit", value: String(limit)),
                ]
                if let cursor {
                    queryItems.append(URLQueryItem(name: "cursor", value: cursor))
                }
                components?.queryItems = queryItems
                guard let url = components?.url else {
                    throw URLError(.badURL)
                }

                let (data, response) = try await load(url)
                try validate(response: response)
                let decoded = try JSONDecoder().decode(RemoteSkillAPI.SkillListResponse.self, from: data)
                return RemoteSkillPage(
                    items: decoded.items.map(remoteSkill),
                    nextCursor: decoded.nextCursor
                )
            },
            search: { query, limit in
                var components = URLComponents(
                    url: baseURL.appendingPathComponent("/api/v1/search"),
                    resolvingAgainstBaseURL: false
                )
                components?.queryItems = [
                    URLQueryItem(name: "q", value: query),
                    URLQueryItem(name: "limit", value: String(limit)),
                ]
                guard let url = components?.url else {
                    throw URLError(.badURL)
                }

                let (data, response) = try await load(url)
                try validate(response: response)
                let decoded = try JSONDecoder().decode(RemoteSkillAPI.SearchResponse.self, from: data)
                return decoded.results.compactMap { result in
                    guard let slug = result.slug, let displayName = result.displayName else { return nil }
                    return RemoteSkill(
                        id: slug,
                        slug: slug,
                        displayName: displayName,
                        summary: result.summary,
                        latestVersion: result.version,
                        updatedAt: result.updatedAt.map { Date(timeIntervalSince1970: $0 / 1000) },
                        downloads: nil,
                        stars: nil
                    )
                }
            },
            download: { slug, version in
                var components = URLComponents(
                    url: baseURL.appendingPathComponent("/api/v1/download"),
                    resolvingAgainstBaseURL: false
                )
                var queryItems = [URLQueryItem(name: "slug", value: slug)]
                if let version, !version.isEmpty {
                    queryItems.append(URLQueryItem(name: "version", value: version))
                } else {
                    queryItems.append(URLQueryItem(name: "tag", value: "latest"))
                }
                components?.queryItems = queryItems
                guard let url = components?.url else {
                    throw URLError(.badURL)
                }

                let (downloadURL, response) = try await session.download(from: url)
                return try checkedDownloadedArchive(at: downloadURL, response: response)
            },
            fetchDetail: { slug in
                var components = URLComponents(
                    url: baseURL.appendingPathComponent("/api/skill"),
                    resolvingAgainstBaseURL: false
                )
                components?.queryItems = [
                    URLQueryItem(name: "slug", value: slug),
                ]
                guard let url = components?.url else {
                    throw URLError(.badURL)
                }

                let (data, response) = try await load(url)
                try validate(response: response)
                let decoded = try JSONDecoder().decode(RemoteSkillAPI.SkillDetailResponse.self, from: data)
                guard let owner = decoded.owner else { return nil }
                return RemoteSkillOwner(
                    handle: owner.handle,
                    displayName: owner.displayName,
                    imageURL: owner.image
                )
            },
            fetchLatestVersion: { slug in
                let url = baseURL
                    .appendingPathComponent("/api/v1/skills")
                    .appendingPathComponent(slug)
                let (data, response) = try await load(url)
                try validate(response: response)
                let decoded = try JSONDecoder().decode(RemoteSkillAPI.SkillResponse.self, from: data)
                return decoded.latestVersion?.version
            }
        )
    }
}

nonisolated private func remoteSkill(
    _ item: RemoteSkillAPI.SkillListItem
) -> RemoteSkill {
    RemoteSkill(
        id: item.slug,
        slug: item.slug,
        displayName: item.displayName,
        summary: item.summary,
        latestVersion: item.latestVersion?.version,
        updatedAt: Date(timeIntervalSince1970: item.updatedAt / 1000),
        downloads: item.stats?.downloads,
        stars: item.stats?.stars
    )
}

nonisolated func checkedDownloadedArchive(
    at downloadURL: URL,
    response: URLResponse
) throws -> DownloadedSkillArchive {
    let archive = try DownloadedSkillArchive.takeOwnership(of: downloadURL)
    do {
        try validate(response: response)
        return archive
    } catch {
        try? archive.removeIfOwned()
        throw error
    }
}

nonisolated private func validate(response: URLResponse) throws {
    guard let http = response as? HTTPURLResponse else {
        throw RemoteSkillClientError.invalidResponse
    }
    switch http.statusCode {
    case 200..<300:
        return
    case 429:
        throw RemoteSkillClientError.rateLimited
    case 500..<600:
        throw RemoteSkillClientError.providerUnavailable
    default:
        throw RemoteSkillClientError.invalidResponse
    }
}
