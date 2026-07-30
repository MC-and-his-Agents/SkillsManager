import Foundation
import Testing

@testable import SkillsManager

@Suite("skills.sh search client")
struct SkillsShSearchClientTests {
    enum InvalidRequestFixture: CaseIterable {
        case emptyQuery
        case shortQuery
        case tooManyScalars
        case tooManyBytes
        case lowLimit
        case highLimit
        case negativeOffset
        case highOffset

        var input: (query: String, limit: Int, offset: Int) {
            switch self {
            case .emptyQuery: (" \n ", 20, 0)
            case .shortQuery: ("a", 20, 0)
            case .tooManyScalars: (String(repeating: "a", count: 201), 20, 0)
            case .tooManyBytes: (String(repeating: "😀", count: 200), 20, 0)
            case .lowLimit: ("swift", 0, 0)
            case .highLimit: ("swift", 51, 0)
            case .negativeOffset: ("swift", 20, -1)
            case .highOffset: ("swift", 20, 1_000_001)
            }
        }
    }

    enum TransportErrorFixture: CaseIterable {
        case timeout
        case offline
        case lostConnection
        case hostFailure
        case other

        var input: (URLError.Code, SkillsShSearchError) {
            switch self {
            case .timeout: (.timedOut, .timeout)
            case .offline: (.notConnectedToInternet, .offline)
            case .lostConnection: (.networkConnectionLost, .offline)
            case .hostFailure: (.cannotFindHost, .offline)
            case .other: (.badServerResponse, .network)
            }
        }
    }

    enum HTTPErrorFixture: CaseIterable {
        case sameOriginRedirect
        case crossOriginRedirect
        case rateLimited
        case invalidRetryAfter
        case nonCanonicalRetryAfter
        case unicodeRetryAfter
        case maximumRetryAfter
        case notFound
        case unauthorized
        case unavailable
        case unexpectedSuccess

        var statusCode: Int {
            switch self {
            case .sameOriginRedirect, .crossOriginRedirect: 302
            case .rateLimited,
                 .invalidRetryAfter,
                 .nonCanonicalRetryAfter,
                 .unicodeRetryAfter,
                 .maximumRetryAfter:
                429
            case .notFound: 404
            case .unauthorized: 401
            case .unavailable: 503
            case .unexpectedSuccess: 204
            }
        }

        var expected: SkillsShSearchError {
            switch self {
            case .sameOriginRedirect, .crossOriginRedirect: .redirectRejected
            case .rateLimited: .rateLimited(retryAfterSeconds: 30)
            case .maximumRetryAfter: .rateLimited(retryAfterSeconds: 3_600)
            case .invalidRetryAfter, .nonCanonicalRetryAfter, .unicodeRetryAfter:
                .rateLimited(retryAfterSeconds: nil)
            case .notFound, .unauthorized, .unexpectedSuccess: .contractChanged
            case .unavailable: .providerUnavailable
            }
        }
    }

    enum ContractFailureFixture: CaseIterable {
        case nonJSON
        case malformedJSON
        case missingField
        case queryMismatch
        case emptySearchType
        case tooManyResults
        case negativeCount
        case emptyID
        case oversizedName
        case invalidSource
        case negativeInstalls
        case durationOverflow
    }

    @Test("builds one fixed request and preserves neutral provider count")
    func fixedRequest() async throws {
        let client = SkillsShSearchClient.live { request, maximumBytes in
            let url = try #require(request.url)
            let components = try #require(URLComponents(url: url, resolvingAgainstBaseURL: false))
            #expect(request.httpMethod == "GET")
            #expect(components.scheme == "https")
            #expect(components.host == "skills.sh")
            #expect(components.path == "/api/search")
            #expect(components.queryItems == [
                URLQueryItem(name: "q", value: "swift"),
                URLQueryItem(name: "limit", value: "2"),
                URLQueryItem(name: "offset", value: "0"),
            ])
            #expect(request.value(forHTTPHeaderField: "Accept") == "application/json")
            #expect(request.value(forHTTPHeaderField: "Authorization") == nil)
            #expect(request.value(forHTTPHeaderField: "Cookie") == nil)
            #expect(request.value(forHTTPHeaderField: "Referer") == nil)
            #expect(request.cachePolicy == .reloadIgnoringLocalCacheData)
            #expect(request.timeoutInterval == 10)
            #expect(maximumBytes == 1_048_576)
            return (
                try responseData(query: "swift", count: 99, includeExtraField: true),
                try httpResponse(url: url)
            )
        }

        let page = try await client.search(" \n swift \t", 2, 0)

        #expect(page.query == "swift")
        #expect(page.reportedCount == 99)
        #expect(page.items == [
            SkillsShSearchItem(
                id: "owner/repo/demo",
                skillID: "demo",
                name: "Demo",
                installs: 42,
                source: "owner/repo"
            ),
        ])
    }

    @Test(
        "rejects invalid input before loading",
        arguments: InvalidRequestFixture.allCases
    )
    func invalidInput(_ fixture: InvalidRequestFixture) async {
        let client = SkillsShSearchClient.live { _, _ in
            throw URLError(.badServerResponse)
        }
        let input = fixture.input

        await #expect(throws: SkillsShSearchError.invalidRequest) {
            _ = try await client.search(input.query, input.limit, input.offset)
        }
    }

    @Test("accepts exact query limit and offset boundaries")
    func validBoundaries() async throws {
        let client = SkillsShSearchClient.live { request, _ in
            let url = try #require(request.url)
            let components = try #require(URLComponents(url: url, resolvingAgainstBaseURL: false))
            let query = try #require(
                components.queryItems?.first(where: { $0.name == "q" })?.value
            )
            return (
                try responseData(query: query, count: 0, items: []),
                try httpResponse(url: url)
            )
        }

        _ = try await client.search("ab", 1, 0)
        _ = try await client.search(String(repeating: "😀", count: 128), 50, 1_000_000)
    }

    @Test(
        "maps transport failures",
        arguments: TransportErrorFixture.allCases
    )
    func transportErrors(_ fixture: TransportErrorFixture) async {
        let input = fixture.input
        let client = SkillsShSearchClient.live { _, _ in
            throw URLError(input.0)
        }

        await #expect(throws: input.1) {
            _ = try await client.search("swift", 2, 0)
        }
    }

    @Test("propagates cancellation without provider failure")
    func cancellation() async {
        let client = SkillsShSearchClient.live { _, _ in
            throw URLError(.cancelled)
        }

        await #expect(throws: CancellationError.self) {
            _ = try await client.search("swift", 2, 0)
        }
    }

    @Test(
        "maps redirects and HTTP failures without reading error bodies",
        arguments: HTTPErrorFixture.allCases
    )
    func httpErrors(_ fixture: HTTPErrorFixture) async throws {
        let client = SkillsShSearchClient.live { request, _ in
            let requestURL = try #require(request.url)
            let responseURL = fixture == .crossOriginRedirect
                ? URL(string: "https://example.invalid/elsewhere")!
                : requestURL
            let retryAfter: String? = switch fixture {
            case .rateLimited: "30"
            case .invalidRetryAfter: "3601"
            case .nonCanonicalRetryAfter: "030"
            case .unicodeRetryAfter: "٣٠"
            case .maximumRetryAfter: "3600"
            default: nil
            }
            return (
                Data("<html>must not be decoded</html>".utf8),
                try httpResponse(
                    url: responseURL,
                    statusCode: fixture.statusCode,
                    retryAfter: retryAfter
                )
            )
        }

        await #expect(throws: fixture.expected) {
            _ = try await client.search("swift", 2, 0)
        }
    }

    @Test(
        "fails the whole page when the search contract changes",
        arguments: ContractFailureFixture.allCases
    )
    func contractFailures(_ fixture: ContractFailureFixture) async throws {
        let client = SkillsShSearchClient.live { request, _ in
            let url = try #require(request.url)
            let contentType = fixture == .nonJSON ? "text/html" : "application/json"
            return (
                try contractFailureData(fixture),
                try httpResponse(url: url, contentType: contentType)
            )
        }

        await #expect(throws: SkillsShSearchError.contractChanged) {
            _ = try await client.search("swift", 2, 0)
        }
    }

    @Test("rejects a changed final URL even with a 200 response")
    func changedFinalURL() async throws {
        let client = SkillsShSearchClient.live { _, _ in
            (
                try responseData(),
                try httpResponse(url: URL(string: "https://skills.sh/api/other")!)
            )
        }

        await #expect(throws: SkillsShSearchError.redirectRejected) {
            _ = try await client.search("swift", 2, 0)
        }

        let changedPort = SkillsShSearchClient.live { _, _ in
            (
                try responseData(),
                try httpResponse(url: URL(string: "https://skills.sh:444/api/search")!)
            )
        }
        await #expect(throws: SkillsShSearchError.redirectRejected) {
            _ = try await changedPort.search("swift", 2, 0)
        }
    }

    @Test("uses an ephemeral transport without cookies credentials or cache")
    func ephemeralConfiguration() {
        let configuration = SkillsShHTTPTransport.makeConfiguration()

        #expect(configuration.identifier == nil)
        #expect(configuration.requestCachePolicy == .reloadIgnoringLocalCacheData)
        #expect(configuration.urlCache == nil)
        #expect(configuration.httpCookieStorage == nil)
        #expect(configuration.urlCredentialStorage == nil)
        #expect(!configuration.httpShouldSetCookies)
        #expect(configuration.timeoutIntervalForRequest == 10)
        #expect(configuration.timeoutIntervalForResource == 10)
        #expect(!configuration.waitsForConnectivity)
    }

    @Test("collects at the byte limit and rejects the next byte")
    func incrementalLimit() async throws {
        let accepted = byteStream([1, 2, 3])
        let data = try await SkillsShHTTPTransport.collect(
            accepted,
            expectedLength: -1,
            maximumBytes: 3
        )
        #expect(data == Data([1, 2, 3]))

        await #expect(throws: SkillsShSearchError.responseTooLarge) {
            _ = try await SkillsShHTTPTransport.collect(
                byteStream([1, 2, 3, 4]),
                expectedLength: -1,
                maximumBytes: 3
            )
        }
        await #expect(throws: SkillsShSearchError.responseTooLarge) {
            _ = try await SkillsShHTTPTransport.collect(
                byteStream([]),
                expectedLength: 4,
                maximumBytes: 3
            )
        }
    }

    @Test("does not retry a failed request")
    func noRetry() async {
        let counter = CallCounter()
        let client = SkillsShSearchClient.live { _, _ in
            await counter.increment()
            throw URLError(.timedOut)
        }

        await #expect(throws: SkillsShSearchError.timeout) {
            _ = try await client.search("swift", 2, 0)
        }
        #expect(await counter.value == 1)
    }

    private func contractFailureData(_ fixture: ContractFailureFixture) throws -> Data {
        if fixture == .malformedJSON {
            return Data("{".utf8)
        }
        if fixture == .durationOverflow {
            return Data("""
                {"query":"swift","searchType":"fuzzy","skills":[],"count":0,
                "duration_ms":18446744073709551616}
                """.utf8)
        }

        var object = responseObject(query: fixture == .queryMismatch ? "other" : "swift")
        switch fixture {
        case .nonJSON:
            return Data("<html></html>".utf8)
        case .missingField:
            object.removeValue(forKey: "skills")
        case .emptySearchType:
            object["searchType"] = ""
        case .tooManyResults:
            let item = try #require((object["skills"] as? [[String: Any]])?.first)
            object["skills"] = [item, item, item]
        case .negativeCount:
            object["count"] = -1
        case .emptyID:
            try mutateFirstItem(&object) { $0["id"] = "" }
        case .oversizedName:
            try mutateFirstItem(&object) { $0["name"] = String(repeating: "a", count: 513) }
        case .invalidSource:
            try mutateFirstItem(&object) { $0["source"] = "owner/repo/extra" }
        case .negativeInstalls:
            try mutateFirstItem(&object) { $0["installs"] = -1 }
        case .malformedJSON, .queryMismatch, .durationOverflow:
            break
        }
        return try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
    }

    private func responseData(
        query: String = "swift",
        count: Int = 1,
        items: [[String: Any]]? = nil,
        includeExtraField: Bool = false
    ) throws -> Data {
        var object = responseObject(query: query, count: count)
        if let items {
            object["skills"] = items
        }
        if includeExtraField {
            object["futureField"] = true
        }
        return try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
    }

    private func responseObject(
        query: String,
        count: Int = 1
    ) -> [String: Any] {
        [
            "query": query,
            "searchType": "fuzzy",
            "skills": [[
                "id": "owner/repo/demo",
                "skillId": "demo",
                "name": "Demo",
                "installs": 42,
                "source": "owner/repo",
            ]],
            "count": count,
            "duration_ms": 10,
        ]
    }

    private func mutateFirstItem(
        _ object: inout [String: Any],
        _ mutation: (inout [String: Any]) -> Void
    ) throws {
        var skills = try #require(object["skills"] as? [[String: Any]])
        mutation(&skills[0])
        object["skills"] = skills
    }

    private func httpResponse(
        url: URL,
        statusCode: Int = 200,
        contentType: String = "application/json; charset=utf-8",
        retryAfter: String? = nil
    ) throws -> HTTPURLResponse {
        var headers = ["Content-Type": contentType]
        if let retryAfter {
            headers["Retry-After"] = retryAfter
        }
        return try #require(HTTPURLResponse(
            url: url,
            statusCode: statusCode,
            httpVersion: nil,
            headerFields: headers
        ))
    }

    private func byteStream(_ bytes: [UInt8]) -> AsyncStream<UInt8> {
        AsyncStream { continuation in
            for byte in bytes {
                continuation.yield(byte)
            }
            continuation.finish()
        }
    }
}

private actor CallCounter {
    private(set) var value = 0

    func increment() {
        value += 1
    }
}
