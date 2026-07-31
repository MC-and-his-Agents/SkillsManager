import Foundation
import Testing

@testable import SkillsManager

@Suite("Managed Skill update execution", .serialized)
struct ManagedSkillUpdateExecutionTests {
    @Test("ClawHub update backs up, replaces, and records an up-to-date snapshot")
    func updatesClawdhubSkill() async throws {
        let fixture = try await makeExecutionFixture(remoteMarkdown: "# Remote")
        defer { fixture.remote.cleanup() }
        let snapshot = try await fixture.checks.check(fixture.skillID)
        let service = ManagedSkillUpdateExecutionService(
            writer: fixture.writer,
            remote: fixture.remote.client
        )

        let preview = try await service.prepare(snapshot)
        #expect(preview.currentSourceDescription == "ClawHub demo 1.0.0")
        #expect(preview.candidateSourceDescription == "ClawHub demo 2.0.0")
        #expect(preview.distributionDescription == "Disabled · Symlink")
        let result = try await service.confirm(preview.token, selections: [])

        #expect(result.status == .updated)
        #expect(try fixture.workspace.integer("SELECT count(*) FROM skill_backups") == 1)
        #expect(try await fixture.writer.loadUpdateCheck(fixture.skillID)?.status == .upToDate)
        #expect(try await managedMarkdown(fixture) == "# Remote")
    }

    @Test("unchanged candidates do not enter the update write path")
    func noChangeIsZeroWrite() async throws {
        let fixture = try await makeExecutionFixture(remoteMarkdown: "# Original")
        defer { fixture.remote.cleanup() }
        let snapshot = try await fixture.checks.check(fixture.skillID)
        let service = ManagedSkillUpdateExecutionService(
            writer: fixture.writer,
            remote: fixture.remote.client
        )

        await #expect(throws: ManagedSkillUpdateExecutionProblem.noUpdate) {
            _ = try await service.prepare(snapshot)
        }
        #expect(try fixture.workspace.integer("SELECT count(*) FROM skill_backups") == 0)
    }

    @Test("prepare releases its temporary candidate when final readback fails")
    func prepareFailureCleansTemporaryCandidate() async throws {
        let fixture = try await makeExecutionFixture(remoteMarkdown: "# Remote")
        defer { fixture.remote.cleanup() }
        let snapshot = try await fixture.checks.check(fixture.skillID)
        let capture = TemporaryRootCapture()
        let service = ManagedSkillUpdateExecutionService(
            writer: fixture.writer,
            remote: fixture.remote.client,
            beforePrepareFinalReadback: { prepared in
                guard let url = prepared.payload.temporaryRoot?.url else {
                    throw ManagedUpdateExecutionInterruption()
                }
                await capture.record(url)
                throw ManagedUpdateExecutionInterruption()
            }
        )

        await #expect(throws: ManagedSkillUpdateExecutionProblem.failed) {
            _ = try await service.prepare(snapshot)
        }
        let temporaryURL = try #require(await capture.url)
        #expect(!FileManager.default.fileExists(atPath: temporaryURL.path))
        #expect(try fixture.workspace.integer("SELECT count(*) FROM skill_backups") == 0)
    }

    @Test("distribution changes in the replacement reentry window fail before backup")
    func replacementRebindsApprovedDistribution() async throws {
        let fixture = try await makeExecutionFixture(
            remoteMarkdown: "# Remote",
            distributionEnabled: true
        )
        defer { fixture.remote.cleanup() }
        let snapshot = try await fixture.checks.check(fixture.skillID)
        let writer = fixture.writer
        let skillID = fixture.skillID
        let service = ManagedSkillUpdateExecutionService(
            writer: writer,
            remote: fixture.remote.client,
            beforeReplacementBaseline: {
                let slug = try DefaultDistributionSlug(validating: "demo")
                let plan = try await writer.distributionPlan(
                    skillID: skillID,
                    desiredConfiguration: DistributionDesiredConfiguration(
                        scope: .global(slug),
                        syncMode: .symlink
                    ),
                    requiredAdapterCodes: globalReaderCodes
                )
                _ = try await writer.applyDistribution(skillID: skillID, plan: plan)
            }
        )
        let preview = try await service.prepare(snapshot)

        await #expect(throws: ManagedSkillUpdateExecutionProblem.stale) {
            _ = try await service.confirm(preview.token, selections: [])
        }
        #expect(try fixture.workspace.integer("SELECT count(*) FROM skill_backups") == 0)
        #expect(try await managedMarkdown(fixture) == "# Original")
        let selection = try await writer.loadDistributionSelection(skillID: skillID)
        #expect(selection.bindings.first?.syncMode == .symlink)
        #expect(selection.bindings.first?.scope == .global)
    }

    @Test("a changed remote candidate expires the confirmation")
    func remoteCandidateExpires() async throws {
        let fixture = try await makeExecutionFixture(remoteMarkdown: "# Remote")
        defer { fixture.remote.cleanup() }
        let snapshot = try await fixture.checks.check(fixture.skillID)
        let service = ManagedSkillUpdateExecutionService(
            writer: fixture.writer,
            remote: fixture.remote.client
        )
        let preview = try await service.prepare(snapshot)
        let newerArchive = try executionArchive(markdown: "# Newer")
        defer { try? FileManager.default.removeItem(at: newerArchive) }
        fixture.remote.set(version: "3.0.0", archiveURL: newerArchive)

        await #expect(throws: ManagedSkillUpdateExecutionProblem.stale) {
            _ = try await service.confirm(preview.token, selections: [])
        }
        #expect(try fixture.workspace.integer("SELECT count(*) FROM skill_backups") == 0)
        #expect(try await managedMarkdown(fixture) == "# Original")
    }

    @Test("a local SSOT edit expires the confirmation before backup")
    func localEditExpiresConfirmation() async throws {
        let fixture = try await makeExecutionFixture(remoteMarkdown: "# Remote")
        defer { fixture.remote.cleanup() }
        let snapshot = try await fixture.checks.check(fixture.skillID)
        let service = ManagedSkillUpdateExecutionService(
            writer: fixture.writer,
            remote: fixture.remote.client
        )
        let preview = try await service.prepare(snapshot)
        try Data("# Local edit".utf8).write(
            to: fixture.workspace.root
                .appendingPathComponent(fixture.skillID.directoryName)
                .appendingPathComponent("SKILL.md")
        )

        await #expect(throws: ManagedSkillUpdateExecutionProblem.stale) {
            _ = try await service.confirm(preview.token, selections: [])
        }
        #expect(try fixture.workspace.integer("SELECT count(*) FROM skill_backups") == 0)
    }

    @Test("a confirmation token is single-use")
    func duplicateConfirmIsRejected() async throws {
        let fixture = try await makeExecutionFixture(remoteMarkdown: "# Remote")
        defer { fixture.remote.cleanup() }
        let snapshot = try await fixture.checks.check(fixture.skillID)
        let service = ManagedSkillUpdateExecutionService(
            writer: fixture.writer,
            remote: fixture.remote.client
        )
        let preview = try await service.prepare(snapshot)
        #expect(try await service.confirm(preview.token, selections: []).status == .updated)

        await #expect(throws: ManagedSkillUpdateExecutionProblem.stale) {
            _ = try await service.confirm(preview.token, selections: [])
        }
        #expect(try fixture.workspace.integer("SELECT count(*) FROM skill_backups") == 1)
    }

    @Test("a published backup without a replacement has a stable retry-safe result")
    func backupReadyBeforeReplacement() async throws {
        let interruption = UpdateBackupInterruption()
        var hooks = JournaledSSOTWriterHooks()
        hooks.afterUpdateBackupPublished = interruption.reach
        let fixture = try await makeExecutionFixture(
            remoteMarkdown: "# Remote",
            hooks: hooks
        )
        defer { fixture.remote.cleanup() }
        let snapshot = try await fixture.checks.check(fixture.skillID)
        let service = ManagedSkillUpdateExecutionService(
            writer: fixture.writer,
            remote: fixture.remote.client
        )
        let preview = try await service.prepare(snapshot)
        interruption.arm()

        let result = try await service.confirm(preview.token, selections: [])

        #expect(result.status == .backupReadyUpdateNotStarted)
        #expect(result.backupID != nil)
        #expect(try await managedMarkdown(fixture) == "# Original")
        #expect(try await fixture.writer.loadUpdateCheck(fixture.skillID) == snapshot)
    }

    @Test("replacement interruption recovers before returning success")
    func interruptionRecoversBeforeSuccess() async throws {
        let interruption = CopyForkCheckpointInterruption()
        var hooks = JournaledSSOTWriterHooks()
        hooks.checkpoint = interruption.reach
        let fixture = try await makeExecutionFixture(
            remoteMarkdown: "# Remote",
            hooks: hooks
        )
        defer { fixture.remote.cleanup() }
        let snapshot = try await fixture.checks.check(fixture.skillID)
        let service = ManagedSkillUpdateExecutionService(
            writer: fixture.writer,
            remote: fixture.remote.client
        )
        let preview = try await service.prepare(snapshot)
        interruption.arm(at: .beforeReplacementSwap)

        let result = try await service.confirm(preview.token, selections: [])

        #expect(result.status == .updated)
        #expect(try await managedMarkdown(fixture) == "# Remote")
        #expect(try await fixture.writer.loadUpdateCheck(fixture.skillID)?.status == .upToDate)
    }

    @Test("Copy discard keeps Copy mode and refreshes the remote content")
    func updatesAfterDiscardingCopyDrift() async throws {
        let fixture = try await makeExecutionFixture(
            remoteMarkdown: "# Remote",
            copy: true
        )
        defer { fixture.remote.cleanup() }
        try Data("# Local Copy".utf8).write(to: fixture.copyURL!.appendingPathComponent("SKILL.md"))
        let snapshot = try await fixture.checks.check(fixture.skillID)
        #expect(snapshot.status == .copyDrift)
        let service = ManagedSkillUpdateExecutionService(
            writer: fixture.writer,
            remote: fixture.remote.client
        )
        let preview = try await service.prepare(snapshot)
        let choice = try #require(preview.copyChoices.first)

        let result = try await service.confirm(
            preview.token,
            selections: [
                ManagedSkillUpdateDecisionSelection(
                    scopeKey: choice.scopeKey,
                    decision: .discard
                ),
            ]
        )

        #expect(result.status == .updated)
        #expect(try String(
            contentsOf: fixture.copyURL!.appendingPathComponent("SKILL.md"),
            encoding: .utf8
        ) == "# Remote")
        let selection = try await fixture.writer.loadDistributionSelection(
            skillID: fixture.skillID
        )
        #expect(selection.bindings.first?.syncMode == .copy)
        #expect(try await fixture.writer.loadUpdateCheck(fixture.skillID)?.status == .upToDate)
    }

    @Test("Copy Fork preserves local content as an independent managed Skill")
    func updatesParentAfterForkingCopyDrift() async throws {
        let fixture = try await makeExecutionFixture(
            remoteMarkdown: "# Remote",
            copy: true
        )
        defer { fixture.remote.cleanup() }
        try Data("# Local Fork".utf8).write(to: fixture.copyURL!.appendingPathComponent("SKILL.md"))
        let snapshot = try await fixture.checks.check(fixture.skillID)
        let service = ManagedSkillUpdateExecutionService(
            writer: fixture.writer,
            remote: fixture.remote.client
        )
        let preview = try await service.prepare(snapshot)
        let choice = try #require(preview.copyChoices.first)

        let result = try await service.confirm(
            preview.token,
            selections: [
                ManagedSkillUpdateDecisionSelection(
                    scopeKey: choice.scopeKey,
                    decision: .fork
                ),
            ]
        )

        #expect(result.status == .updated)
        #expect(try await managedMarkdown(fixture) == "# Remote")
        #expect(try String(
            contentsOf: fixture.copyURL!.appendingPathComponent("SKILL.md"),
            encoding: .utf8
        ) == "# Local Fork")
        let catalog = try await fixture.writer.managedLocalCatalogReadback()
        let child = try #require(catalog.skills.first(where: {
            $0.skill.skillID != fixture.skillID
        }))
        #expect(
            try await fixture.writer.storedDomainReadback(child.skill.skillID)?
                .payload.forkLineage?.parentSkillID == fixture.skillID
        )
    }

    @Test("mixed Copy decisions advance each scope before updating the parent")
    func updatesAfterMixedCopyDecisions() async throws {
        let fixture = try await makeExecutionFixture(
            remoteMarkdown: "# Remote",
            copy: true,
            copyPlatforms: [.codex, .claude]
        )
        defer { fixture.remote.cleanup() }
        let selection = try await fixture.writer.loadDistributionSelection(
            skillID: fixture.skillID
        )
        let codex = try #require(selection.bindings.first {
            $0.scope == .agent(.codex)
        })
        let claude = try #require(selection.bindings.first {
            $0.scope == .agent(.claude)
        })
        let codexURL = try #require(fixture.copyURLs[codex.scope.targetScopeKey])
        let claudeURL = try #require(fixture.copyURLs[claude.scope.targetScopeKey])
        try Data("# Codex Copy".utf8).write(to: codexURL.appendingPathComponent("SKILL.md"))
        try Data("# Claude Fork".utf8).write(to: claudeURL.appendingPathComponent("SKILL.md"))
        let snapshot = try await fixture.checks.check(fixture.skillID)
        let service = ManagedSkillUpdateExecutionService(
            writer: fixture.writer,
            remote: fixture.remote.client
        )
        let preview = try await service.prepare(snapshot)
        #expect(preview.copyChoices.count == 2)

        let result = try await service.confirm(
            preview.token,
            selections: [
                ManagedSkillUpdateDecisionSelection(
                    scopeKey: codex.scope.targetScopeKey,
                    decision: .discard
                ),
                ManagedSkillUpdateDecisionSelection(
                    scopeKey: claude.scope.targetScopeKey,
                    decision: .fork
                ),
            ]
        )

        #expect(result.status == .updated)
        #expect(try await managedMarkdown(fixture) == "# Remote")
        #expect(try String(
            contentsOf: codexURL.appendingPathComponent("SKILL.md"),
            encoding: .utf8
        ) == "# Remote")
        #expect(try String(
            contentsOf: claudeURL.appendingPathComponent("SKILL.md"),
            encoding: .utf8
        ) == "# Claude Fork")
        let parent = try await fixture.writer.loadDistributionSelection(
            skillID: fixture.skillID
        )
        #expect(parent.bindings.map(\.scope) == [.agent(.codex)])
        let catalog = try await fixture.writer.managedLocalCatalogReadback()
        let child = try #require(catalog.skills.first {
            $0.skill.skillID != fixture.skillID
        })
        #expect(child.bindings.map(\.scope) == [.agent(.claude)])
    }

    @Test("a selected cancel leaves Copy drift and managed content untouched")
    func cancelIsZeroWrite() async throws {
        let fixture = try await makeExecutionFixture(
            remoteMarkdown: "# Remote",
            copy: true
        )
        defer { fixture.remote.cleanup() }
        try Data("# Local Copy".utf8).write(to: fixture.copyURL!.appendingPathComponent("SKILL.md"))
        let snapshot = try await fixture.checks.check(fixture.skillID)
        let service = ManagedSkillUpdateExecutionService(
            writer: fixture.writer,
            remote: fixture.remote.client
        )
        let preview = try await service.prepare(snapshot)
        let choice = try #require(preview.copyChoices.first)
        let backupCount = try fixture.workspace.integer(
            "SELECT count(*) FROM skill_backups"
        )

        let result = try await service.confirm(
            preview.token,
            selections: [
                ManagedSkillUpdateDecisionSelection(
                    scopeKey: choice.scopeKey,
                    decision: .cancel
                ),
            ]
        )

        #expect(result.status == .cancelled)
        #expect(try fixture.workspace.integer(
            "SELECT count(*) FROM skill_backups"
        ) == backupCount)
        #expect(try await managedMarkdown(fixture) == "# Original")
        #expect(try String(
            contentsOf: fixture.copyURL!.appendingPathComponent("SKILL.md"),
            encoding: .utf8
        ) == "# Local Copy")
    }

    @Test("incomplete Copy decisions are rejected before durable writes")
    func invalidDecisionsAreZeroWrite() async throws {
        let fixture = try await makeExecutionFixture(
            remoteMarkdown: "# Remote",
            copy: true
        )
        defer { fixture.remote.cleanup() }
        try Data("# Local Copy".utf8).write(to: fixture.copyURL!.appendingPathComponent("SKILL.md"))
        let snapshot = try await fixture.checks.check(fixture.skillID)
        let service = ManagedSkillUpdateExecutionService(
            writer: fixture.writer,
            remote: fixture.remote.client
        )
        let preview = try await service.prepare(snapshot)

        await #expect(throws: ManagedSkillUpdateExecutionProblem.invalidDecisions) {
            _ = try await service.confirm(preview.token, selections: [])
        }
        #expect(try fixture.workspace.integer("SELECT count(*) FROM skill_backups") == 0)
        #expect(try await managedMarkdown(fixture) == "# Original")
    }

    @Test("a zero-write Copy preflight failure is not reported as applied")
    func zeroWriteCopyFailureKeepsOriginalProblem() async throws {
        let fixture = try await makeExecutionFixture(remoteMarkdown: "# Remote")
        defer { fixture.remote.cleanup() }
        let service = ManagedSkillUpdateExecutionService(
            writer: fixture.writer,
            remote: fixture.remote.client
        )
        let expected = try await fixture.writer.updateCheckReadback(
            skillID: fixture.skillID
        )

        await #expect(throws: ManagedSkillUpdateExecutionProblem.stale) {
            _ = try await service.classifyFailure(
                ManagedSkillUpdateExecutionProblem.stale,
                skillID: fixture.skillID,
                expectedUnupdated: expected,
                durableCopyDecision: false,
                copyMutationAttempted: true,
                operationID: nil,
                backupID: nil
            )
        }
        #expect(try fixture.workspace.integer("SELECT count(*) FROM skill_backups") == 0)
    }
}
