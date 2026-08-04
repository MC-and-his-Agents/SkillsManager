import Darwin
import Foundation
import Testing

@testable import SkillsManager

@Suite("SkillDiscovery batch import")
struct SkillDiscoveryBatchImportTests {
    @Test("defaults only safe candidates and leaves conflicts explicit")
    @MainActor
    func safeDefaults() throws {
        let safe = SkillDiscoveryViewModel.Item(
            discoveryTestObservation(name: "safe", status: .unmanaged)
        )
        let conflict = SkillDiscoveryViewModel.Item(
            discoveryTestObservation(
                name: "conflict",
                status: .conflict,
                reason: .ambiguousSource
            )
        )
        let model = SkillDiscoveryBatchViewModel()
        model.configure(items: [safe, conflict], generation: 7)

        #expect(model.availableCandidateCount == 2)
        #expect(model.selectedCount == 1)
        let safeID = try #require(model.candidates.first { $0.observation.displayName == "safe" }?.id)
        let conflictID = try #require(model.candidates.first { $0.observation.displayName == "conflict" }?.id)
        #expect(model.action(for: safeID) == .importNew)
        #expect(model.action(for: conflictID) == nil)

        model.selectAllSafe()
        #expect(model.selectedCount == 1)
        model.setAction(.importNew, for: conflictID)
        #expect(model.selectedCount == 2)
    }

    @Test("merges one physical candidate and keeps the direct locator first")
    func canonicalPhysicalCandidate() throws {
        var candidateMetadata = stat()
        candidateMetadata.st_dev = 12
        candidateMetadata.st_ino = 42
        candidateMetadata.st_mode = mode_t(S_IFDIR)
        var rootMetadata = stat()
        rootMetadata.st_dev = 12
        rootMetadata.st_ino = 7
        rootMetadata.st_mode = mode_t(S_IFDIR)
        var linkMetadata = stat()
        linkMetadata.st_dev = 12
        linkMetadata.st_ino = 99
        linkMetadata.st_mode = mode_t(S_IFLNK)

        let root = discoveryTestRoot()
        let otherRoot = SkillDiscoveryRoot(
            scope: .agent(adapterCode: "claude", pathVariant: "default"),
            url: URL(fileURLWithPath: "/tmp/other-root", isDirectory: true)
        )
        let fingerprint = try SkillContentFingerprint(
            currentDigest: Data(repeating: 3, count: 32)
        )
        func observation(
            name: String,
            root: SkillDiscoveryRoot,
            rootIdentity: ManagedItemIdentity,
            symbolicLink: ManagedItemIdentity?
        ) -> SkillDiscoveryObservation {
            SkillDiscoveryObservation(
                roots: [root],
                rootIdentity: rootIdentity,
                rawRelativeLocator: name,
                relativeLocator: name,
                relativeLocatorKey: SkillContentPath.collisionKey(for: name),
                candidateIdentity: ManagedItemIdentity(candidateMetadata),
                symbolicLinkIdentity: symbolicLink,
                fingerprint: fingerprint,
                providerAliases: [],
                status: .unmanaged,
                reason: nil,
                matchedSkillID: nil,
                matchedSourceKey: nil
            )
        }

        let candidates = SkillDiscoveryBatchCandidate.canonicalCandidates(from: [
            SkillDiscoveryViewModel.Item(observation(
                name: "direct",
                root: root,
                rootIdentity: ManagedItemIdentity(rootMetadata),
                symbolicLink: nil
            )),
            SkillDiscoveryViewModel.Item(observation(
                name: "alias",
                root: otherRoot,
                rootIdentity: ManagedItemIdentity(linkMetadata),
                symbolicLink: ManagedItemIdentity(linkMetadata)
            )),
        ])
        #expect(candidates.count == 1)
        #expect(candidates[0].aliases.count == 2)
        #expect(candidates[0].aliases[0].isDirect)
        #expect(candidates[0].observation.rawRelativeLocator == "direct")
        #expect(candidates[0].observation.roots == [root])
    }

    @Test("prefers one managed identity across physical aliases and rejects disagreement")
    func canonicalManagementEvidence() throws {
        var candidateMetadata = stat()
        candidateMetadata.st_dev = 12
        candidateMetadata.st_ino = 42
        candidateMetadata.st_mode = mode_t(S_IFDIR)
        var rootMetadata = stat()
        rootMetadata.st_dev = 12
        rootMetadata.st_ino = 7
        rootMetadata.st_mode = mode_t(S_IFDIR)
        var linkMetadata = stat()
        linkMetadata.st_dev = 12
        linkMetadata.st_ino = 99
        linkMetadata.st_mode = mode_t(S_IFLNK)

        let directRoot = discoveryTestRoot()
        let aliasRoot = SkillDiscoveryRoot(
            scope: .agent(adapterCode: "claude", pathVariant: "default"),
            url: URL(fileURLWithPath: "/tmp/other-root", isDirectory: true)
        )
        let candidateIdentity = ManagedItemIdentity(candidateMetadata)
        let fingerprint = try SkillContentFingerprint(
            currentDigest: Data(repeating: 3, count: 32)
        )
        func observation(
            root: SkillDiscoveryRoot,
            rootIdentity: ManagedItemIdentity,
            symbolicLink: ManagedItemIdentity?,
            status: SkillDiscoveryStatus,
            matchedSkillID: SkillID?
        ) -> SkillDiscoveryViewModel.Item {
            SkillDiscoveryViewModel.Item(SkillDiscoveryObservation(
                roots: [root],
                rootIdentity: rootIdentity,
                rawRelativeLocator: "shared",
                relativeLocator: "shared",
                relativeLocatorKey: SkillContentPath.collisionKey(for: "shared"),
                candidateIdentity: candidateIdentity,
                symbolicLinkIdentity: symbolicLink,
                fingerprint: fingerprint,
                providerAliases: [],
                status: status,
                reason: nil,
                matchedSkillID: matchedSkillID,
                matchedSourceKey: nil
            ))
        }

        let skillID = SkillID()
        let direct = observation(
            root: directRoot,
            rootIdentity: ManagedItemIdentity(rootMetadata),
            symbolicLink: nil,
            status: .unmanaged,
            matchedSkillID: nil
        )
        let claimable = observation(
            root: aliasRoot,
            rootIdentity: ManagedItemIdentity(linkMetadata),
            symbolicLink: ManagedItemIdentity(linkMetadata),
            status: .claimable,
            matchedSkillID: skillID
        )
        let compatible = try #require(
            SkillDiscoveryBatchCandidate.canonicalCandidates(from: [direct, claimable]).first
        )
        #expect(compatible.observation.status == .claimable)
        #expect(compatible.observation.matchedSkillID == skillID)
        #expect(compatible.observation.roots == [aliasRoot])
        #expect(compatible.defaultAction == .claimExisting)

        let disagreement = try #require(
            SkillDiscoveryBatchCandidate.canonicalCandidates(from: [
                claimable,
                observation(
                    root: directRoot,
                    rootIdentity: ManagedItemIdentity(rootMetadata),
                    symbolicLink: nil,
                    status: .managed,
                    matchedSkillID: SkillID()
                ),
            ]).first
        )
        #expect(disagreement.observation.status == .conflict)
        #expect(disagreement.observation.reason == .evidenceConflict)
        #expect(!disagreement.isSelectable)
        #expect(disagreement.defaultAction == nil)
        #expect(disagreement.selectionBlockReason != nil)
    }

    @Test("executes in order and refreshes only through the finalizer")
    @MainActor
    func orderedExecution() async throws {
        let safe = SkillDiscoveryViewModel.Item(
            discoveryTestObservation(name: "ordered", status: .unmanaged)
        )
        let model = SkillDiscoveryBatchViewModel()
        model.activate(dependencies: SkillDiscoveryBatchDependencies(
            preview: { observation, action in
                discoveryTestPreview(observation: observation, action: action)
            },
            execute: { _ in try discoveryTestImportResult() },
            plan: { _, _, _ in distributionPlan(status: .noOp) },
            apply: { skillID, _ in distributionOperation(skillID: skillID) }
        ))
        model.configure(items: [safe], generation: 3)
        await model.preparePreview()
        #expect(model.state == .ready)

        var finalizerCalls = 0
        await model.confirm {
            #expect(model.state == .executing)
            finalizerCalls += 1
        }
        #expect(model.state == .completed)
        #expect(model.summary.created == 1)
        #expect(model.summary.distributed == 0)
        #expect(model.resultItems.count == 1)
        #expect(finalizerCalls == 1)
    }

    @Test("preserves existing bindings when claiming a discovered origin")
    @MainActor
    func claimPreservesBindings() async throws {
        let skillID = SkillID()
        let claim = SkillDiscoveryViewModel.Item(
            discoveryTestObservation(
                name: "claim",
                status: .claimable,
                matchedSkillID: skillID
            )
        )
        let imports = SkillDiscoveryImportProbe(outcomes: [.success(.claimed)])
        let plans = DistributionPlanProbe(plans: [distributionPlan(status: .noOp)])
        let model = SkillDiscoveryBatchViewModel()
        model.activate(dependencies: SkillDiscoveryBatchDependencies(
            preview: { try await imports.preview($0, action: $1) },
            execute: { try await imports.execute($0) },
            plan: { _, configuration, codes in
                try await plans.nextPlan(
                    desiredScope: configuration.scope,
                    requiredAdapterCodes: codes
                )
            },
            apply: { _, _ in try await plans.apply() }
        ))
        model.configure(items: [claim], generation: 5)
        await model.preparePreview()
        await model.confirm()

        #expect(model.summary.claimed == 1)
        #expect(await plans.planCallCount == 0)
        #expect(await plans.applyCount == 0)
        #expect(model.resultItems.first?.distribution
            == .notApplicable("Existing Agent bindings were preserved."))
    }

    @Test("continues after one item fails")
    @MainActor
    func mixedResultsContinue() async throws {
        let imports = SkillDiscoveryImportProbe(outcomes: [
            .sourceChanged,
            .success(.created),
        ])
        let model = SkillDiscoveryBatchViewModel()
        model.activate(dependencies: SkillDiscoveryBatchDependencies(
            preview: { try await imports.preview($0, action: $1) },
            execute: { try await imports.execute($0) },
            plan: { _, _, _ in distributionPlan(status: .noOp) },
            apply: { skillID, _ in distributionOperation(skillID: skillID) }
        ))
        model.configure(items: [
            SkillDiscoveryViewModel.Item(
                discoveryTestObservation(name: "a-fails", status: .unmanaged)
            ),
            SkillDiscoveryViewModel.Item(
                discoveryTestObservation(name: "b-succeeds", status: .unmanaged)
            ),
        ], generation: 6)
        await model.preparePreview()
        await model.confirm()

        #expect(model.resultItems.count == 2)
        #expect(model.summary.failed == 1)
        #expect(model.summary.created == 1)
        #expect(await imports.executeCount == 2)
    }

    @Test("rejects a preview after Discovery changes")
    @MainActor
    func staleGeneration() async throws {
        let imports = SkillDiscoveryImportProbe(outcomes: [.success(.created)])
        let model = SkillDiscoveryBatchViewModel()
        model.activate(dependencies: SkillDiscoveryBatchDependencies(
            preview: { try await imports.preview($0, action: $1) },
            execute: { try await imports.execute($0) },
            plan: { _, _, _ in distributionPlan(status: .noOp) },
            apply: { skillID, _ in distributionOperation(skillID: skillID) }
        ))
        model.configure(items: [
            SkillDiscoveryViewModel.Item(
                discoveryTestObservation(name: "stale", status: .unmanaged)
            ),
        ], generation: 7)
        await model.preparePreview()
        model.invalidate(generation: 8)
        await model.confirm()

        #expect(model.state == .idle)
        #expect(await imports.executeCount == 0)
    }

    @Test("consumes confirmation once")
    @MainActor
    func duplicateConfirm() async throws {
        let imports = SkillDiscoveryImportProbe(outcomes: [.success(.created)])
        let model = SkillDiscoveryBatchViewModel()
        model.activate(dependencies: SkillDiscoveryBatchDependencies(
            preview: { try await imports.preview($0, action: $1) },
            execute: { try await imports.execute($0) },
            plan: { _, _, _ in distributionPlan(status: .noOp) },
            apply: { skillID, _ in distributionOperation(skillID: skillID) }
        ))
        model.configure(items: [
            SkillDiscoveryViewModel.Item(
                discoveryTestObservation(name: "once", status: .unmanaged)
            ),
        ], generation: 9)
        await model.preparePreview()
        await model.confirm()
        await model.confirm()

        #expect(await imports.executeCount == 1)
    }

    @Test("does not apply when the distribution plan changes after import")
    @MainActor
    func staleDistributionPlan() async throws {
        let plans = DistributionPlanProbe(plans: [
            distributionPlan(status: .executable),
            distributionPlan(status: .executable, configurationChanged: true),
        ])
        let model = SkillDiscoveryBatchViewModel()
        model.activate(dependencies: SkillDiscoveryBatchDependencies(
            preview: { discoveryTestPreview(observation: $0, action: $1) },
            execute: { _ in try discoveryTestImportResult() },
            plan: { _, configuration, codes in
                try await plans.nextPlan(
                    desiredScope: configuration.scope,
                    requiredAdapterCodes: codes
                )
            },
            apply: { _, _ in try await plans.apply() }
        ))
        model.configure(items: [
            SkillDiscoveryViewModel.Item(
                discoveryTestObservation(name: "changed-plan", status: .unmanaged)
            ),
        ], generation: 10)
        await model.preparePreview()
        await model.confirm()

        #expect(await plans.applyCount == 0)
        #expect(model.summary.needsAttention == 1)
        guard case .indeterminate = model.resultItems.first?.distribution else {
            Issue.record("Expected changed plan to require attention")
            return
        }
    }

    @Test("does not report an unfinished distribution as distributed")
    @MainActor
    func unfinishedDistribution() async throws {
        let safe = SkillDiscoveryViewModel.Item(
            discoveryTestObservation(name: "unfinished", status: .unmanaged)
        )
        let model = SkillDiscoveryBatchViewModel()
        model.activate(dependencies: SkillDiscoveryBatchDependencies(
            preview: { observation, action in
                discoveryTestPreview(observation: observation, action: action)
            },
            execute: { _ in try discoveryTestImportResult() },
            plan: { _, _, _ in distributionPlan(status: .executable) },
            apply: { skillID, _ in
                distributionOperation(
                    skillID: skillID,
                    phase: .applying,
                    outcome: nil
                )
            }
        ))
        model.configure(items: [safe], generation: 4)
        await model.preparePreview()
        await model.confirm()

        #expect(model.summary.created == 1)
        #expect(model.summary.distributed == 0)
        #expect(model.summary.needsAttention == 1)
        guard case .indeterminate = model.resultItems.first?.distribution else {
            Issue.record("Expected an indeterminate distribution result")
            return
        }
    }
}
