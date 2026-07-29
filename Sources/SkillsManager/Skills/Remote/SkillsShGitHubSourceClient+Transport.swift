import Foundation

nonisolated enum SkillsShGitHubHTTPTransport {
    private static let redirectDelegate = SkillsShGitHubRedirectDelegate()
    private static let session = URLSession(configuration: makeConfiguration())

    static func makeConfiguration() -> URLSessionConfiguration {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.urlCache = nil
        configuration.httpCookieStorage = nil
        configuration.urlCredentialStorage = nil
        configuration.httpShouldSetCookies = false
        configuration.timeoutIntervalForRequest = 10
        configuration.timeoutIntervalForResource = 60
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
            throw SkillsShGitHubSourceError.contractChanged
        }
        guard response.statusCode == 200 else {
            return (Data(), response)
        }
        return (
            try await collect(
                bytes,
                expectedLength: response.expectedContentLength,
                maximumBytes: maximumBytes
            ),
            response
        )
    }

    static func collect<Bytes: AsyncSequence>(
        _ bytes: Bytes,
        expectedLength: Int64,
        maximumBytes: Int
    ) async throws -> Data where Bytes.Element == UInt8 {
        guard maximumBytes >= 0,
              expectedLength < 0 || expectedLength <= Int64(maximumBytes) else {
            throw SkillsShGitHubSourceError.responseTooLarge
        }
        var data = Data()
        if expectedLength > 0 {
            data.reserveCapacity(Int(expectedLength))
        }
        for try await byte in bytes {
            try Task.checkCancellation()
            guard data.count < maximumBytes else {
                throw SkillsShGitHubSourceError.responseTooLarge
            }
            data.append(byte)
        }
        return data
    }
}

private nonisolated final class SkillsShGitHubRedirectDelegate:
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
