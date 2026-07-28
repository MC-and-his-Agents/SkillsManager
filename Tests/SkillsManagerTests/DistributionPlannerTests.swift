import Darwin
import Foundation
import Testing
@testable import SkillsManager

@Suite("Distribution planner")
struct DistributionPlannerTests {
    private let planner = DistributionPlanner()
    private let catalog = DistributionTargetCatalog.current
    private let skillID = SkillID(
        UUID(uuidString: "00112233-4455-6677-8899-aabbccddeeff")!
    )
    private let otherSkillID = SkillID(
        UUID(uuidString: "ffeeddcc-bbaa-9988-7766-554433221100")!
    )

    @Test("plans missing additions and managed binding-only repair")
    func additions() throws {
        let slug = try DefaultDistributionSlug(validating: "review")
        let entry = try #require(catalog.entry(for: .global, slug: slug))

        let create = planner.plan(
            skillID: skillID,
            currentBindings: [],
            desiredScope: .global(slug),
            requiredAdapterCodes: globalCoverage,
            observations: [entry: .missing]
        )
        #expect(create.status == .executable)
        #expect(create.filesystemActions.map(\.kind) == [.createSymlink])
        #expect(create.bindingsChanged)
        #expect(create.bindingReplacement.map(\.scope) == [.global])

        let repair = planner.plan(
            skillID: skillID,
            currentBindings: [],
            desiredScope: .global(slug),
            requiredAdapterCodes: globalCoverage,
            observations: [entry: managedCorrect]
        )
        #expect(repair.status == .executable)
        #expect(repair.filesystemActions.isEmpty)
        #expect(repair.bindingsChanged)
        #expect(repair.bindingReplacement.count == 1)
    }

    @Test("blocks every unsafe addition observation")
    func blockedAdditions() throws {
        let slug = try DefaultDistributionSlug(validating: "review")
        let entry = try #require(catalog.entry(for: .global, slug: slug))
        let cases: [(DistributionTargetObservation, DistributionConflictReason)] = [
            (
                .managed(skillID: skillID, ssotDirectoryName: "wrong"),
                .managedTargetMismatch
            ),
            (
                .managed(skillID: otherSkillID, ssotDirectoryName: otherSkillID.directoryName),
                .slugOccupied
            ),
            (.unknownObject, .unknownObject),
            (.unavailable, .targetUnavailable),
        ]

        for (observation, reason) in cases {
            let plan = planner.plan(
                skillID: skillID,
                currentBindings: [],
                desiredScope: .global(slug),
                requiredAdapterCodes: globalCoverage,
                observations: [entry: observation]
            )
            expectBlocked(plan, reason: reason)
        }
    }

    @Test("plans only verified removals")
    func removals() throws {
        let slug = try DefaultDistributionSlug(validating: "review")
        let current = [try binding(scope: .agent(.claude), slug: slug)]
        let entry = try #require(catalog.entry(for: .agent(.claude), slug: slug))

        let remove = planner.plan(
            skillID: skillID,
            currentBindings: current,
            desiredScope: .disabled,
            requiredAdapterCodes: [],
            observations: [entry: managedCorrect]
        )
        #expect(remove.status == .executable)
        #expect(remove.filesystemActions.map(\.kind) == [.removeSymlink])
        #expect(remove.bindingsChanged)
        #expect(remove.bindingReplacement.isEmpty)

        let cases: [(DistributionTargetObservation, DistributionConflictReason)] = [
            (.missing, .currentBindingMissing),
            (
                .managed(skillID: skillID, ssotDirectoryName: "wrong"),
                .managedTargetMismatch
            ),
            (
                .managed(skillID: otherSkillID, ssotDirectoryName: otherSkillID.directoryName),
                .managedTargetMismatch
            ),
            (.unknownObject, .unknownObject),
            (.unavailable, .targetUnavailable),
        ]
        for (observation, reason) in cases {
            let plan = planner.plan(
                skillID: skillID,
                currentBindings: current,
                desiredScope: .disabled,
                requiredAdapterCodes: [],
                observations: [entry: observation]
            )
            expectBlocked(plan, reason: reason)
        }
    }

    @Test("retains matching bindings as the unique no-op representation")
    func retentionAndNoOp() throws {
        let slug = try DefaultDistributionSlug(validating: "review")
        let current = [try binding(scope: .global, slug: slug)]
        let entry = try #require(catalog.entry(for: .global, slug: slug))

        let plan = planner.plan(
            skillID: skillID,
            currentBindings: current,
            desiredScope: .global(slug),
            requiredAdapterCodes: globalCoverage,
            observations: [entry: managedCorrect]
        )

        #expect(plan.status == .noOp)
        #expect(plan.filesystemActions.isEmpty)
        #expect(!plan.bindingsChanged)
        #expect(plan.bindingReplacement.isEmpty)
        #expect(plan.conflicts.isEmpty)
        #expect(try plan.canonicalJSONString()
            == #"{"binding_replacement":[],"bindings_changed":false,"configuration_changed":false,"conflicts":[],"desired_configured":true,"expected_old_configured":true,"filesystem_actions":[],"status":"no_op"}"#)

        let disabled = planner.plan(
            skillID: skillID,
            currentBindings: [],
            desiredScope: .disabled,
            requiredAdapterCodes: [],
            observations: [:]
        )
        #expect(try disabled.canonicalJSONData() == planForDisabledJSON)
    }

    @Test("explicitly disabling an unconfigured Skill is a marker-only operation")
    func markerOnlyDisable() {
        let plan = planner.plan(
            skillID: skillID,
            currentBindings: [],
            currentConfigured: false,
            desiredScope: .disabled,
            desiredConfigured: true,
            requiredAdapterCodes: [],
            observations: [:]
        )

        #expect(plan.status == .executable)
        #expect(plan.filesystemActions.isEmpty)
        #expect(!plan.bindingsChanged)
        #expect(plan.bindingReplacement.isEmpty)
        #expect(plan.configurationChanged)
        #expect(!plan.expectedOldConfigured)
        #expect(plan.desiredConfigured)
    }

    @Test("blocks missing and drifted retained bindings")
    func blockedRetentions() throws {
        let slug = try DefaultDistributionSlug(validating: "review")
        let current = [try binding(scope: .global, slug: slug)]
        let entry = try #require(catalog.entry(for: .global, slug: slug))
        let cases: [(DistributionTargetObservation, DistributionConflictReason)] = [
            (.missing, .currentBindingMissing),
            (
                .managed(skillID: skillID, ssotDirectoryName: "wrong"),
                .managedTargetMismatch
            ),
            (
                .managed(skillID: otherSkillID, ssotDirectoryName: otherSkillID.directoryName),
                .managedTargetMismatch
            ),
            (.unknownObject, .unknownObject),
            (.unavailable, .targetUnavailable),
        ]
        for (observation, reason) in cases {
            let plan = planner.plan(
                skillID: skillID,
                currentBindings: current,
                desiredScope: .global(slug),
                requiredAdapterCodes: globalCoverage,
                observations: [entry: observation]
            )
            expectBlocked(plan, reason: reason)
        }
    }

    @Test("validates desired coverage and unavailable catalog targets")
    func desiredValidation() throws {
        let slug = try DefaultDistributionSlug(validating: "review")

        let invalidDisabled = planner.plan(
            skillID: skillID,
            currentBindings: [],
            desiredScope: .disabled,
            requiredAdapterCodes: ["codex"],
            observations: [:]
        )
        #expect(invalidDisabled.conflicts.map(\.reason) == [.invalidDesiredScope])

        let unsupported = planner.plan(
            skillID: skillID,
            currentBindings: [],
            desiredScope: .global(slug),
            requiredAdapterCodes: globalCoverage.union(["future"]),
            observations: [:]
        )
        #expect(unsupported.conflicts.map(\.reason) == [
            .unsupportedAdapter, .globalCoverageMismatch, .targetUnavailable,
        ])

        let missingClaudeCatalog = DistributionTargetCatalog(
            globalTarget: catalog.globalTarget,
            dedicatedTargets: Dictionary(uniqueKeysWithValues: SkillPlatform.allCases
                .filter { $0 != .claude }
                .compactMap { adapter in
                    catalog.target(for: .agent(adapter)).map { (adapter, $0) }
                })
        )
        let missingDedicated = planner.plan(
            skillID: skillID,
            currentBindings: [],
            desiredScope: .agents([.claude], slug),
            requiredAdapterCodes: ["claude"],
            observations: [:],
            catalog: missingClaudeCatalog
        )
        #expect(missingDedicated.conflicts.map(\.reason) == [.dedicatedTargetUnavailable])
    }

    @Test("orders removals before creates and discards all executable fields when blocked")
    func conversionOrderingAndAtomicBlocking() throws {
        let slug = try DefaultDistributionSlug(validating: "review")
        let current = [try binding(scope: .global, slug: slug)]
        let global = try #require(catalog.entry(for: .global, slug: slug))
        let codex = try #require(catalog.entry(for: .agent(.codex), slug: slug))
        let claude = try #require(catalog.entry(for: .agent(.claude), slug: slug))

        let executable = planner.plan(
            skillID: skillID,
            currentBindings: current,
            desiredScope: .agents([.codex, .claude], slug),
            requiredAdapterCodes: ["codex", "claude"],
            observations: [
                global: managedCorrect,
                codex: .missing,
                claude: .missing,
            ]
        )
        #expect(executable.filesystemActions.map(\.kind) == [
            .removeSymlink, .createSymlink, .createSymlink,
        ])
        #expect(executable.filesystemActions.map(\.entry.target.scope) == [
            .global, .agent(.codex), .agent(.claude),
        ])

        let blocked = planner.plan(
            skillID: skillID,
            currentBindings: current,
            desiredScope: .agents([.codex, .claude], slug),
            requiredAdapterCodes: ["codex", "claude"],
            observations: [
                global: managedCorrect,
                codex: .unknownObject,
                claude: .unavailable,
            ]
        )
        #expect(blocked.status == .blocked)
        #expect(blocked.filesystemActions.isEmpty)
        #expect(!blocked.bindingsChanged)
        #expect(blocked.bindingReplacement.isEmpty)
        #expect(blocked.conflicts.map(\.reason) == [.targetUnavailable, .unknownObject])
    }

    @Test("encodes stable canonical JSON without legacy Codex public paths or timestamps")
    func canonicalJSON() throws {
        let slug = try DefaultDistributionSlug(validating: "review")
        let codex = try #require(catalog.entry(for: .agent(.codex), slug: slug))
        let plan = planner.plan(
            skillID: skillID,
            currentBindings: [],
            desiredScope: .agents([.codex], slug),
            requiredAdapterCodes: ["codex"],
            observations: [codex: .missing]
        )
        let first = try plan.canonicalJSONString()
        let second = try plan.canonicalJSONString()

        #expect(first == second)
        #expect(first.contains(#""action":"create_symlink""#))
        #expect(first.contains(#""target_locator":"~/.codex/skills/review""#))
        #expect(first.contains(#""ssot_locator":"~/.SkillsManager/skills/00112233-4455-6677-8899-aabbccddeeff""#))
        #expect(!first.contains(".codex/skills/public"))
        #expect(!first.contains("created_at"))
        #expect(!first.contains("updated_at"))
        #expect(!first.contains("\\/"))
    }

    @Test("plans Copy add, refresh, removal, and mode transitions")
    func copyMatrix() throws {
        let slug = try DefaultDistributionSlug(validating: "review")
        let entry = try #require(catalog.entry(for: .global, slug: slug))
        let desiredCopy = DistributionDesiredConfiguration(
            scope: .global(slug),
            syncMode: .copy
        )
        let create = planner.plan(
            skillID: skillID,
            currentBindings: [],
            desiredConfiguration: desiredCopy,
            requiredAdapterCodes: globalCoverage,
            observations: [entry: .missing]
        )
        #expect(create.filesystemActions.map(\.kind) == [.createCopy])
        #expect(create.bindingReplacement.map(\.syncMode) == [.copy])

        let copy = try copyBinding(scope: .global, slug: slug)
        let refresh = planner.plan(
            skillID: skillID,
            currentBindings: [copy],
            desiredConfiguration: desiredCopy,
            requiredAdapterCodes: globalCoverage,
            observations: [entry: copyObservation(.sourceChanged)]
        )
        #expect(refresh.filesystemActions.map(\.kind) == [.refreshCopy])

        let remove = planner.plan(
            skillID: skillID,
            currentBindings: [copy],
            desiredConfiguration: .init(scope: .disabled, syncMode: .copy),
            requiredAdapterCodes: [],
            observations: [entry: copyObservation(.inSync)]
        )
        #expect(remove.filesystemActions.map(\.kind) == [.removeCopy])

        let toSymlink = planner.plan(
            skillID: skillID,
            currentBindings: [copy],
            desiredConfiguration: .init(scope: .global(slug), syncMode: .symlink),
            requiredAdapterCodes: globalCoverage,
            observations: [entry: copyObservation(.inSync)]
        )
        #expect(toSymlink.filesystemActions.map(\.kind) == [.replaceCopyWithSymlink])

        let symlink = try binding(scope: .global, slug: slug)
        let toCopy = planner.plan(
            skillID: skillID,
            currentBindings: [symlink],
            desiredConfiguration: desiredCopy,
            requiredAdapterCodes: globalCoverage,
            observations: [entry: managedCorrect]
        )
        #expect(toCopy.filesystemActions.map(\.kind) == [.replaceSymlinkWithCopy])
    }

    @Test("Copy drift states fail closed with stable evidence")
    func copyDrift() throws {
        let slug = try DefaultDistributionSlug(validating: "review")
        let entry = try #require(catalog.entry(for: .global, slug: slug))
        let current = [try copyBinding(scope: .global, slug: slug)]
        let cases: [(DistributionCopyObservationState, DistributionConflictReason)] = [
            (.contentDrift, .copyContentDrift),
            (.physicalDrift, .copyPhysicalDrift),
            (.rootReplaced, .copyRootReplaced),
            (.targetReplaced, .copyTargetReplaced),
            (.targetMissing, .copyTargetMissing),
            (.baselineInvalid, .copyBaselineInvalid),
        ]
        for (state, reason) in cases {
            let plan = planner.plan(
                skillID: skillID,
                currentBindings: current,
                desiredConfiguration: .init(scope: .disabled, syncMode: .copy),
                requiredAdapterCodes: [],
                observations: [entry: copyObservation(state)]
            )
            expectBlocked(plan, reason: reason)
            #expect(plan.conflicts.first?.copyEvidence?.skillID == skillID)
        }
    }

    @Test("mixed persisted modes fail closed")
    func mixedModes() throws {
        let slug = try DefaultDistributionSlug(validating: "review")
        let global = try copyBinding(scope: .global, slug: slug)
        let agent = try binding(scope: .agent(.claude), slug: slug)
        let plan = planner.plan(
            skillID: skillID,
            currentBindings: [global, agent],
            desiredConfiguration: .init(scope: .disabled, syncMode: .copy),
            requiredAdapterCodes: [],
            observations: [:]
        )
        #expect(plan.status == .blocked)
        #expect(plan.conflicts.contains(where: { $0.reason == .invalidDesiredScope }))
    }

    private var globalCoverage: Set<String> {
        ["codex", "opencode", "copilot"]
    }

    private var managedCorrect: DistributionTargetObservation {
        .managed(skillID: skillID, ssotDirectoryName: skillID.directoryName)
    }

    private var planForDisabledJSON: Data {
        Data(#"{"binding_replacement":[],"bindings_changed":false,"configuration_changed":false,"conflicts":[],"desired_configured":true,"expected_old_configured":true,"filesystem_actions":[],"status":"no_op"}"#.utf8)
    }

    private func binding(
        scope: DistributionBindingScope,
        slug: DefaultDistributionSlug
    ) throws -> DistributionBinding {
        try DistributionBinding(
            skillID: skillID,
            scope: scope,
            distributionSlug: slug,
            createdAtMilliseconds: 10,
            updatedAtMilliseconds: 11
        )
    }

    private func copyBinding(
        scope: DistributionBindingScope,
        slug: DefaultDistributionSlug
    ) throws -> DistributionBinding {
        let identity = try plannerIdentity()
        return try DistributionBinding(
            skillID: skillID,
            scope: scope,
            distributionSlug: slug,
            syncMode: .copy,
            copyBaseline: DistributionCopyBaseline(
                contentFingerprint: SkillContentFingerprint(
                    algorithmVersion: 1,
                    digest: Data(repeating: 1, count: 32)
                ),
                physicalTreeDigest: CopyPhysicalTreeDigest(
                    digest: Data(repeating: 2, count: 32)
                ),
                rootIdentity: identity,
                entryIdentity: identity,
                appliedOperationID: SSOTOperationID(),
                verifiedAtMilliseconds: 9
            ),
            createdAtMilliseconds: 10,
            updatedAtMilliseconds: 11
        )
    }

    private func copyObservation(
        _ state: DistributionCopyObservationState
    ) -> DistributionTargetObservation {
        .copy(DistributionCopyObservation(
            state: state,
            evidence: DistributionCopyConflictEvidence(
                skillID: skillID,
                baselineContentFingerprint: try? SkillContentFingerprint(
                    algorithmVersion: 1,
                    digest: Data(repeating: 1, count: 32)
                ),
                observedContentFingerprint: try? SkillContentFingerprint(
                    algorithmVersion: 1,
                    digest: Data(repeating: 3, count: 32)
                ),
                baselinePhysicalTreeDigest: try? CopyPhysicalTreeDigest(
                    digest: Data(repeating: 2, count: 32)
                ),
                observedPhysicalTreeDigest: try? CopyPhysicalTreeDigest(
                    digest: Data(repeating: 4, count: 32)
                ),
                baselineRootIdentity: try? plannerIdentity(),
                observedRootIdentity: try? plannerIdentity(),
                baselineEntryIdentity: try? plannerIdentity(),
                observedEntryIdentity: try? plannerIdentity()
            )
        ))
    }

    private func expectBlocked(
        _ plan: DistributionPlan,
        reason: DistributionConflictReason
    ) {
        #expect(plan.status == .blocked)
        #expect(plan.filesystemActions.isEmpty)
        #expect(!plan.bindingsChanged)
        #expect(plan.bindingReplacement.isEmpty)
        #expect(plan.conflicts.map(\.reason) == [reason])
    }
}

private func plannerIdentity() throws -> ManagedItemIdentity {
    let descriptor = Darwin.open("/", O_RDONLY | O_DIRECTORY | O_CLOEXEC)
    guard descriptor >= 0 else {
        throw DistributionSymlinkFileSystemError.posix(
            operation: "open planner identity fixture",
            code: errno
        )
    }
    defer { Darwin.close(descriptor) }
    return try ManagedItemIdentityCodec.capture(descriptor: descriptor)
}
