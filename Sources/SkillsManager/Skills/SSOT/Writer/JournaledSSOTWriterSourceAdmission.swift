import Foundation

nonisolated struct SourceInstallAdmissionExpectation: Sendable {
    let repositoryURL: NormalizedRepositoryURL
    let subpath: RepositorySubpath
    let alias: ProviderAliasIdentity
    let expectedSkillID: SkillID?
    let expectedSourceID: SourceID?
    let expectedAliasOwner: ProviderAliasSourceOwner?
}

nonisolated enum SourceInstallAdmissionError: Error, Equatable {
    case invalidInput
    case previewExpired
    case providerAliasConflict
}

extension JournaledSSOTWriter {
    func sourceDomainReadback(
        repositoryURL: NormalizedRepositoryURL,
        subpath: RepositorySubpath
    ) throws -> StoredSkillDomainSnapshot? {
        try requireAuthority()
        return try journal.sourceDomain(repositoryURL: repositoryURL, subpath: subpath)
    }

    func providerAliasOwnerReadback(
        _ identity: ProviderAliasIdentity
    ) throws -> ProviderAliasSourceOwner? {
        try requireAuthority()
        return try journal.providerAliasOwner(identity)
    }

    func createSourceBacked(
        payload: SSOTSkillWritePayload,
        sourceSnapshot: SkillContentSnapshot,
        operationID: SSOTOperationID,
        admission: SourceInstallAdmissionExpectation
    ) throws -> SSOTJournalRecord {
        try requireSourceAdmission(admission, payload: payload)
        return try create(
            payload: payload,
            sourceSnapshot: sourceSnapshot,
            operationID: operationID
        )
    }

    func replaceSourceBackedWithBackup(
        expected: ManagedSkillUpdateBaseline,
        replacementPayload: SSOTSkillWritePayload,
        sourceSnapshot: SkillContentSnapshot,
        operationID: SSOTOperationID,
        backupID: SkillBackupID,
        admission: SourceInstallAdmissionExpectation
    ) throws -> ManagedSkillUpdateWriteResult {
        try requireSourceAdmission(admission, payload: replacementPayload)
        return try replaceManagedSkillWithBackup(
            expected: expected,
            replacementPayload: replacementPayload,
            sourceSnapshot: sourceSnapshot,
            operationID: operationID,
            backupID: backupID
        )
    }

    private func requireSourceAdmission(
        _ expectation: SourceInstallAdmissionExpectation,
        payload: SSOTSkillWritePayload
    ) throws {
        try requireAuthority()
        guard let source = payload.source,
              source.repositoryURL == expectation.repositoryURL,
              source.subpath == expectation.subpath,
              source.skillID == payload.skill.skillID,
              payload.providerAliases.contains(where: {
                  $0.sourceID == source.sourceID && $0.identity == expectation.alias
              }) else {
            throw SourceInstallAdmissionError.invalidInput
        }

        let sourceDomain = try journal.sourceDomain(
            repositoryURL: expectation.repositoryURL,
            subpath: expectation.subpath
        )
        let aliasOwner = try journal.providerAliasOwner(expectation.alias)

        if let expectedSkillID = expectation.expectedSkillID,
           let expectedSourceID = expectation.expectedSourceID {
            guard sourceDomain?.payload.skill.skillID == expectedSkillID,
                  sourceDomain?.payload.source?.sourceID == expectedSourceID,
                  source.sourceID == expectedSourceID,
                  aliasOwner == expectation.expectedAliasOwner else {
                if let aliasOwner, aliasOwner.sourceID != expectedSourceID {
                    throw SourceInstallAdmissionError.providerAliasConflict
                }
                throw SourceInstallAdmissionError.previewExpired
            }
            return
        }

        guard expectation.expectedSkillID == nil,
              expectation.expectedSourceID == nil,
              expectation.expectedAliasOwner == nil else {
            throw SourceInstallAdmissionError.invalidInput
        }
        guard sourceDomain == nil else {
            throw SourceInstallAdmissionError.previewExpired
        }
        guard aliasOwner == nil else {
            throw SourceInstallAdmissionError.providerAliasConflict
        }
    }
}
