import Foundation

nonisolated enum ProviderProvenanceError: Error, Equatable {
    case invalidIdentifier
    case invalidIdentifierKey
}

nonisolated struct ProviderProvenanceRecord: Hashable, Sendable {
    let skillID: SkillID
    let identity: ProviderAliasIdentity
    let identifierKey: String
    let version: SourceVersion?

    init(
        skillID: SkillID,
        identity: ProviderAliasIdentity,
        identifierKey: String,
        version: SourceVersion? = nil
    ) throws {
        let slug = try DefaultDistributionSlug(validating: identity.identifier)
        guard identity.identifier.utf8.elementsEqual(slug.value.utf8) else {
            throw ProviderProvenanceError.invalidIdentifier
        }
        guard identifierKey == slug.collisionKey else {
            throw ProviderProvenanceError.invalidIdentifierKey
        }
        self.skillID = skillID
        self.identity = identity
        self.identifierKey = identifierKey
        self.version = version
    }
}
