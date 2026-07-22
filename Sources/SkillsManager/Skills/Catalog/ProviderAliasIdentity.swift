import Foundation

nonisolated enum SourceMetadataError: Error, Equatable {
    case invalidProvider
    case invalidProviderIdentifier
    case invalidRevision
    case invalidVersion
    case invalidDownloadURL
}

nonisolated struct ProviderAliasIdentity: Hashable, Sendable {
    let provider: String
    let identifier: String

    init(provider: String, identifier: String) throws {
        let providerScalars = provider.unicodeScalars
        guard 1...64 ~= provider.utf8.count,
              providerScalars.allSatisfy({
                  ($0 >= "a" && $0 <= "z")
                      || ($0 >= "0" && $0 <= "9")
                      || $0 == "." || $0 == "_" || $0 == "-"
              }),
              let first = providerScalars.first,
              (first >= "a" && first <= "z") || (first >= "0" && first <= "9") else {
            throw SourceMetadataError.invalidProvider
        }
        guard 1...1_024 ~= identifier.utf8.count else {
            throw SourceMetadataError.invalidProviderIdentifier
        }
        self.provider = provider
        self.identifier = identifier
    }
}

nonisolated struct ProviderAliasRecord: Hashable, Sendable {
    let sourceID: SourceID
    let identity: ProviderAliasIdentity

    init(sourceID: SourceID, identity: ProviderAliasIdentity) {
        self.sourceID = sourceID
        self.identity = identity
    }
}

nonisolated struct SourceRevision: Hashable, Sendable {
    let value: String

    init(_ value: String) throws {
        guard 1...512 ~= value.utf8.count else {
            throw SourceMetadataError.invalidRevision
        }
        self.value = value
    }
}

nonisolated struct SourceVersion: Hashable, Sendable {
    let value: String

    init(_ value: String) throws {
        guard 1...512 ~= value.utf8.count else {
            throw SourceMetadataError.invalidVersion
        }
        self.value = value
    }
}

nonisolated struct PublicDownloadURL: Hashable, Sendable {
    let value: String

    init(_ rawValue: String) throws {
        guard var components = URLComponents(string: rawValue),
              components.scheme?.lowercased() == "https",
              components.user == nil,
              components.password == nil,
              components.query == nil,
              components.fragment == nil,
              let host = components.host,
              !host.isEmpty,
              !host.hasSuffix(".") else {
            throw SourceMetadataError.invalidDownloadURL
        }

        components.scheme = "https"
        components.host = host.lowercased()
        if components.port == 443 { components.port = nil }
        guard let normalized = components.url?.absoluteString,
              normalized.utf8.count <= 2_048 else {
            throw SourceMetadataError.invalidDownloadURL
        }
        value = normalized
    }
}
