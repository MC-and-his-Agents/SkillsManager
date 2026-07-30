import Foundation

nonisolated struct SkillsShSearchItem: Equatable, Sendable {
    let id: String
    let skillID: String
    let name: String
    let installs: UInt64
    let source: String
}

nonisolated struct SkillsShSearchPage: Equatable, Sendable {
    let query: String
    let items: [SkillsShSearchItem]
    let reportedCount: Int
}

nonisolated enum SkillsShSearchError: Error, Equatable, LocalizedError, Sendable {
    case invalidRequest
    case timeout
    case offline
    case network
    case redirectRejected
    case rateLimited(retryAfterSeconds: Int?)
    case providerUnavailable
    case responseTooLarge
    case contractChanged

    var errorDescription: String? {
        switch self {
        case .invalidRequest:
            "The skills.sh search request is invalid."
        case .timeout:
            "skills.sh did not respond in time."
        case .offline:
            "skills.sh is unavailable while the network is offline."
        case .network:
            "skills.sh could not be reached."
        case .redirectRejected:
            "skills.sh redirected the search endpoint."
        case .rateLimited(let retryAfterSeconds):
            if let retryAfterSeconds {
                "skills.sh rate limited this request. Try again in \(retryAfterSeconds) seconds."
            } else {
                "skills.sh rate limited this request."
            }
        case .providerUnavailable:
            "skills.sh is temporarily unavailable."
        case .responseTooLarge:
            "skills.sh returned more search data than can be handled safely."
        case .contractChanged:
            "The skills.sh search interface has changed."
        }
    }
}

nonisolated struct SkillsShSearchClient: Sendable {
    typealias DataLoader = @Sendable (URLRequest, Int) async throws -> (Data, HTTPURLResponse)

    var search: @Sendable (
        _ query: String,
        _ limit: Int,
        _ offset: Int
    ) async throws -> SkillsShSearchPage

    static func live(
        load: @escaping DataLoader = SkillsShHTTPTransport.load
    ) -> SkillsShSearchClient {
        SkillsShSearchClient { query, limit, offset in
            let prepared = try SkillsShSearchContract.request(
                query: query,
                limit: limit,
                offset: offset
            )
            do {
                try Task.checkCancellation()
                let (data, response) = try await load(
                    prepared.request,
                    SkillsShHTTPTransport.maximumResponseBytes
                )
                try Task.checkCancellation()
                return try SkillsShSearchContract.page(
                    from: data,
                    response: response,
                    requestURL: prepared.request.url,
                    query: prepared.query,
                    limit: limit
                )
            } catch is CancellationError {
                throw CancellationError()
            } catch let error as SkillsShSearchError {
                throw error
            } catch let error as URLError {
                throw SkillsShSearchContract.map(error)
            } catch {
                throw SkillsShSearchError.network
            }
        }
    }
}

nonisolated enum SkillsShHTTPTransport {
    static let maximumResponseBytes = 1_048_576

    private static let redirectDelegate = SkillsShRedirectDelegate()
    private static let session = URLSession(configuration: makeConfiguration())

    static func makeConfiguration() -> URLSessionConfiguration {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.urlCache = nil
        configuration.httpCookieStorage = nil
        configuration.urlCredentialStorage = nil
        configuration.httpShouldSetCookies = false
        configuration.timeoutIntervalForRequest = 10
        configuration.timeoutIntervalForResource = 10
        configuration.waitsForConnectivity = false
        return configuration
    }

    static func load(
        _ request: URLRequest,
        maximumBytes: Int
    ) async throws -> (Data, HTTPURLResponse) {
        let (bytes, response) = try await session.bytes(
            for: request,
            delegate: redirectDelegate
        )
        guard let response = response as? HTTPURLResponse else {
            throw SkillsShSearchError.contractChanged
        }
        if 300...399 ~= response.statusCode {
            throw SkillsShSearchError.redirectRejected
        }
        guard response.statusCode == 200 else {
            return (Data(), response)
        }
        let data = try await collect(
            bytes,
            expectedLength: response.expectedContentLength,
            maximumBytes: maximumBytes
        )
        return (data, response)
    }

    static func collect<Bytes: AsyncSequence>(
        _ bytes: Bytes,
        expectedLength: Int64,
        maximumBytes: Int
    ) async throws -> Data where Bytes.Element == UInt8 {
        guard maximumBytes >= 0,
              expectedLength < 0 || expectedLength <= Int64(maximumBytes) else {
            throw SkillsShSearchError.responseTooLarge
        }

        var data = Data()
        if expectedLength > 0 {
            data.reserveCapacity(Int(expectedLength))
        }
        for try await byte in bytes {
            try Task.checkCancellation()
            guard data.count < maximumBytes else {
                throw SkillsShSearchError.responseTooLarge
            }
            data.append(byte)
        }
        return data
    }
}

private nonisolated final class SkillsShRedirectDelegate:
    NSObject,
    URLSessionTaskDelegate,
    @unchecked Sendable
{
    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest,
        completionHandler: @escaping @Sendable (URLRequest?) -> Void
    ) {
        completionHandler(nil)
    }
}

private nonisolated enum SkillsShSearchContract {
    private static let endpoint = URL(string: "https://skills.sh/api/search")!
    private static let maximumStringBytes = 512

    struct PreparedRequest {
        let query: String
        let request: URLRequest
    }

    private struct APIResponse: Decodable {
        let query: String
        let searchType: String
        let skills: [APIItem]
        let count: Int
        let durationMilliseconds: UInt64

        enum CodingKeys: String, CodingKey {
            case query
            case searchType
            case skills
            case count
            case durationMilliseconds = "duration_ms"
        }
    }

    private struct APIItem: Decodable {
        let id: String
        let skillID: String
        let name: String
        let installs: UInt64
        let source: String

        enum CodingKeys: String, CodingKey {
            case id
            case skillID = "skillId"
            case name
            case installs
            case source
        }
    }

    static func request(
        query: String,
        limit: Int,
        offset: Int
    ) throws -> PreparedRequest {
        let query = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard 2...200 ~= query.unicodeScalars.count,
              query.utf8.count <= maximumStringBytes,
              1...50 ~= limit,
              0...1_000_000 ~= offset,
              var components = URLComponents(url: endpoint, resolvingAgainstBaseURL: false) else {
            throw SkillsShSearchError.invalidRequest
        }
        components.queryItems = [
            URLQueryItem(name: "q", value: query),
            URLQueryItem(name: "limit", value: String(limit)),
            URLQueryItem(name: "offset", value: String(offset)),
        ]
        guard let url = components.url else {
            throw SkillsShSearchError.invalidRequest
        }
        var request = URLRequest(
            url: url,
            cachePolicy: .reloadIgnoringLocalCacheData,
            timeoutInterval: 10
        )
        request.httpMethod = "GET"
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        return PreparedRequest(query: query, request: request)
    }

    static func page(
        from data: Data,
        response: HTTPURLResponse,
        requestURL: URL?,
        query: String,
        limit: Int
    ) throws -> SkillsShSearchPage {
        try validate(response: response, requestURL: requestURL)
        guard response.statusCode == 200 else {
            throw error(for: response)
        }
        guard response.mimeType?.lowercased() == "application/json" else {
            throw SkillsShSearchError.contractChanged
        }

        let decoded: APIResponse
        do {
            decoded = try JSONDecoder().decode(APIResponse.self, from: data)
        } catch {
            throw SkillsShSearchError.contractChanged
        }
        guard decoded.query == query,
              bounded(decoded.searchType),
              decoded.count >= 0,
              decoded.skills.count <= limit else {
            throw SkillsShSearchError.contractChanged
        }
        let items = try decoded.skills.map(validated)
        return SkillsShSearchPage(
            query: decoded.query,
            items: items,
            reportedCount: decoded.count
        )
    }

    static func map(_ error: URLError) -> Error {
        switch error.code {
        case .cancelled:
            CancellationError()
        case .timedOut:
            SkillsShSearchError.timeout
        case .notConnectedToInternet,
             .networkConnectionLost,
             .cannotFindHost,
             .cannotConnectToHost,
             .dnsLookupFailed:
            SkillsShSearchError.offline
        default:
            SkillsShSearchError.network
        }
    }

    private static func validate(
        response: HTTPURLResponse,
        requestURL: URL?
    ) throws {
        guard let responseURL = response.url,
              let requestURL,
              responseURL.scheme?.lowercased() == "https",
              responseURL.host?.lowercased() == "skills.sh",
              responseURL.user == nil,
              responseURL.password == nil,
              responseURL.port == requestURL.port,
              responseURL.path == "/api/search",
              responseURL.scheme?.caseInsensitiveCompare(requestURL.scheme ?? "") == .orderedSame,
              responseURL.host?.caseInsensitiveCompare(requestURL.host ?? "") == .orderedSame,
              responseURL.path == requestURL.path else {
            throw SkillsShSearchError.redirectRejected
        }
        if 300...399 ~= response.statusCode {
            throw SkillsShSearchError.redirectRejected
        }
    }

    private static func error(for response: HTTPURLResponse) -> SkillsShSearchError {
        switch response.statusCode {
        case 429:
            .rateLimited(retryAfterSeconds: retryAfterSeconds(response))
        case 500...599:
            .providerUnavailable
        default:
            .contractChanged
        }
    }

    private static func retryAfterSeconds(_ response: HTTPURLResponse) -> Int? {
        guard let rawValue = response.value(forHTTPHeaderField: "Retry-After"),
              !rawValue.isEmpty,
              rawValue.utf8.allSatisfy({ 0x30...0x39 ~= $0 }),
              let value = Int(rawValue),
              rawValue == String(value),
              0...3_600 ~= value else {
            return nil
        }
        return value
    }

    private static func validated(_ item: APIItem) throws -> SkillsShSearchItem {
        guard bounded(item.id),
              bounded(item.skillID),
              bounded(item.name),
              bounded(item.source),
              item.source.split(separator: "/", omittingEmptySubsequences: false).count == 2 else {
            throw SkillsShSearchError.contractChanged
        }
        do {
            _ = try NormalizedRepositoryURL("https://github.com/\(item.source)")
        } catch {
            throw SkillsShSearchError.contractChanged
        }
        return SkillsShSearchItem(
            id: item.id,
            skillID: item.skillID,
            name: item.name,
            installs: item.installs,
            source: item.source
        )
    }

    private static func bounded(_ value: String) -> Bool {
        !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && value.utf8.count <= maximumStringBytes
            && !value.contains("\0")
    }
}
