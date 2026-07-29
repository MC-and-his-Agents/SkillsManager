import Foundation

nonisolated struct ProviderAliasSourceOwner: Equatable, Sendable {
    let sourceID: SourceID
    let skillID: SkillID
}

nonisolated extension SSOTJournalStore {
    func sourceDomain(
        repositoryURL: NormalizedRepositoryURL,
        subpath: RepositorySubpath
    ) throws -> StoredSkillDomainSnapshot? {
        let statement = try connection.prepare(
            """
            SELECT skill_id FROM sources
            WHERE normalized_repository_url = ? AND normalized_subpath = ?
            """
        )
        try statement.bind(repositoryURL.value, at: 1)
        try statement.bind(subpath.value, at: 2)
        guard try statement.step() else { return nil }
        let skillID = try SkillID(bytes: journalRequiredBlob(statement, 0))
        guard try !statement.step(),
              let domain = try storedDomain(skillID) else {
            throw SSOTJournalStoreError.corruptRecord("source identity has no unique Skill")
        }
        return domain
    }

    func providerAliasOwner(
        _ identity: ProviderAliasIdentity
    ) throws -> ProviderAliasSourceOwner? {
        let statement = try connection.prepare(
            """
            SELECT sources.source_id, sources.skill_id
            FROM provider_aliases
            JOIN sources ON sources.source_id = provider_aliases.source_id
            WHERE provider_aliases.provider = ?
              AND provider_aliases.provider_identifier = ?
            """
        )
        try statement.bind(identity.provider, at: 1)
        try statement.bind(identity.identifier, at: 2)
        guard try statement.step() else { return nil }
        let owner = ProviderAliasSourceOwner(
            sourceID: try SourceID(bytes: journalRequiredBlob(statement, 0)),
            skillID: try SkillID(bytes: journalRequiredBlob(statement, 1))
        )
        guard try !statement.step() else {
            throw SSOTJournalStoreError.corruptRecord("provider alias has multiple owners")
        }
        return owner
    }
}
