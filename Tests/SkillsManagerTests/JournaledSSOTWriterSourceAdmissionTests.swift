import Foundation
import Testing

@testable import SkillsManager

@Suite("Journaled SSOT writer source admission", .serialized)
struct JournaledSSOTWriterSourceAdmissionTests {
    @Test("source drift rejects create before staging or journal")
    func sourceDriftRejectsCreate() async throws {
        let context = try await SourceAdmissionWriterContext()
        _ = try await context.createInitial()
        let counts = try context.counts()
        let attemptedSnapshot = try context.snapshot("attempted")
        let attempted = try context.payload(
            snapshot: attemptedSnapshot,
            sourceID: SourceID(),
            alias: context.alias
        )

        await #expect(throws: SourceInstallAdmissionError.previewExpired) {
            _ = try await context.writer.createSourceBacked(
                payload: attempted,
                sourceSnapshot: attemptedSnapshot,
                operationID: SSOTOperationID(),
                admission: context.absentAdmission(alias: context.alias)
            )
        }
        try context.expectUnchanged(counts)
    }

    @Test("alias drift rejects create before staging or journal")
    func aliasDriftRejectsCreate() async throws {
        let context = try await SourceAdmissionWriterContext()
        _ = try await context.createInitial()
        let counts = try context.counts()
        let attemptedSnapshot = try context.snapshot("other")
        let attempted = try context.payload(
            snapshot: attemptedSnapshot,
            sourceID: SourceID(),
            alias: context.alias,
            repository: "https://github.com/example/other",
            subpath: "skills/other"
        )

        await #expect(throws: SourceInstallAdmissionError.providerAliasConflict) {
            _ = try await context.writer.createSourceBacked(
                payload: attempted,
                sourceSnapshot: attemptedSnapshot,
                operationID: SSOTOperationID(),
                admission: context.absentAdmission(
                    alias: context.alias,
                    repository: "https://github.com/example/other",
                    subpath: "skills/other"
                )
            )
        }
        try context.expectUnchanged(counts)
    }

    @Test("update admission drift rejects before backup, staging, or journal")
    func updateDriftRejectsBeforeBackup() async throws {
        let context = try await SourceAdmissionWriterContext()
        let initial = try await context.createInitial()
        let baseline = try await context.writer.managedSkillUpdateBaseline(
            initial.skill.skillID
        )
        let counts = try context.counts()
        let replacementSnapshot = try context.snapshot("replacement")
        let replacement = try context.payload(
            skillID: initial.skill.skillID,
            snapshot: replacementSnapshot,
            sourceID: try #require(initial.source?.sourceID),
            alias: context.alias,
            revision: "replacement"
        )
        let source = try #require(initial.source)
        let stale = SourceInstallAdmissionExpectation(
            repositoryURL: source.repositoryURL,
            subpath: source.subpath,
            alias: context.alias,
            expectedSkillID: initial.skill.skillID,
            expectedSourceID: source.sourceID,
            expectedAliasOwner: nil
        )

        await #expect(throws: SourceInstallAdmissionError.previewExpired) {
            _ = try await context.writer.replaceSourceBackedWithBackup(
                expected: baseline,
                replacementPayload: replacement,
                sourceSnapshot: replacementSnapshot,
                operationID: SSOTOperationID(),
                backupID: SkillBackupID(),
                admission: stale
            )
        }
        try context.expectUnchanged(counts)
    }
}

private final class SourceAdmissionWriterContext: @unchecked Sendable {
    struct Counts {
        let skills: Int64?
        let operations: Int64?
        let backups: Int64?
        let internalItems: Int
    }

    let workspace: WriterWorkspace
    let writer: JournaledSSOTWriter
    let alias: ProviderAliasIdentity

    init() async throws {
        workspace = try WriterWorkspace()
        writer = try await workspace.openWriter()
        alias = try ProviderAliasIdentity(
            provider: "skills.sh",
            identifier: "example/repository:demo"
        )
    }

    func snapshot(_ content: String) throws -> SkillContentSnapshot {
        try workspace.snapshot(content: content)
    }

    func createInitial() async throws -> SSOTSkillWritePayload {
        let snapshot = try snapshot("initial")
        let payload = try payload(
            snapshot: snapshot,
            sourceID: SourceID(),
            alias: alias
        )
        _ = try await writer.createSourceBacked(
            payload: payload,
            sourceSnapshot: snapshot,
            operationID: SSOTOperationID(),
            admission: absentAdmission(alias: alias)
        )
        return payload
    }

    func payload(
        skillID: SkillID = SkillID(),
        snapshot: SkillContentSnapshot,
        sourceID: SourceID,
        alias: ProviderAliasIdentity,
        repository: String = "https://github.com/example/repository",
        subpath: String = "skills/demo",
        revision: String = "initial"
    ) throws -> SSOTSkillWritePayload {
        let skill = try ManagedSkillRecord(
            skillID: skillID,
            displayName: SkillDisplayName("Source Demo"),
            defaultDistributionSlug: DefaultDistributionSlug(validating: "source-demo"),
            contentFingerprint: SkillContentFingerprint(
                currentDigest: snapshot.fingerprintDigest
            ),
            createdAtMilliseconds: 1,
            updatedAtMilliseconds: revision == "initial" ? 1 : 2
        )
        return try SSOTSkillWritePayload(
            skill: skill,
            source: SkillSourceRecord(
                sourceID: sourceID,
                skillID: skillID,
                repositoryURL: NormalizedRepositoryURL(repository),
                subpath: RepositorySubpath(subpath),
                revision: SourceRevision(revision),
                downloadURL: PublicDownloadURL(
                    "https://codeload.github.com/example/repository/legacy.zip/\(revision)"
                )
            ),
            providerAliases: [
                ProviderAliasRecord(sourceID: sourceID, identity: alias),
            ]
        )
    }

    func absentAdmission(
        alias: ProviderAliasIdentity,
        repository: String = "https://github.com/example/repository",
        subpath: String = "skills/demo"
    ) throws -> SourceInstallAdmissionExpectation {
        SourceInstallAdmissionExpectation(
            repositoryURL: try NormalizedRepositoryURL(repository),
            subpath: try RepositorySubpath(subpath),
            alias: alias,
            expectedSkillID: nil,
            expectedSourceID: nil,
            expectedAliasOwner: nil
        )
    }

    func counts() throws -> Counts {
        Counts(
            skills: try workspace.integer("SELECT count(*) FROM skills"),
            operations: try workspace.integer("SELECT count(*) FROM skill_operations"),
            backups: try workspace.integer("SELECT count(*) FROM skill_backups"),
            internalItems: try workspace.internalItemCount()
        )
    }

    func expectUnchanged(_ expected: Counts) throws {
        #expect(try workspace.integer("SELECT count(*) FROM skills") == expected.skills)
        #expect(
            try workspace.integer("SELECT count(*) FROM skill_operations")
                == expected.operations
        )
        #expect(
            try workspace.integer("SELECT count(*) FROM skill_backups")
                == expected.backups
        )
        #expect(try workspace.internalItemCount() == expected.internalItems)
    }
}
