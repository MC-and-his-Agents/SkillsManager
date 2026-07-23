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
            == #"{"binding_replacement":[],"bindings_changed":false,"conflicts":[],"filesystem_actions":[],"status":"no_op"}"#)

        let disabled = planner.plan(
            skillID: skillID,
            currentBindings: [],
            desiredScope: .disabled,
            requiredAdapterCodes: [],
            observations: [:]
        )
        #expect(try disabled.canonicalJSONData() == planForDisabledJSON)
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

    private var globalCoverage: Set<String> {
        ["codex", "opencode", "copilot"]
    }

    private var managedCorrect: DistributionTargetObservation {
        .managed(skillID: skillID, ssotDirectoryName: skillID.directoryName)
    }

    private var planForDisabledJSON: Data {
        Data(#"{"binding_replacement":[],"bindings_changed":false,"conflicts":[],"filesystem_actions":[],"status":"no_op"}"#.utf8)
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
