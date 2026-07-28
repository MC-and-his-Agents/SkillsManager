import Foundation

@testable import SkillsManager

actor DistributionLoadProbe {
    private(set) var loadCount = 0

    func load() -> [DistributionBinding] {
        loadCount += 1
        return []
    }
}

actor DistributionSelectionProbe {
    private let selections: [DistributionSelectionReadback]
    private var index = 0

    init(_ selections: [DistributionSelectionReadback]) {
        self.selections = selections
    }

    func load() -> DistributionSelectionReadback {
        let selection = selections[min(index, selections.count - 1)]
        index += 1
        return selection
    }
}

actor DistributionPlanProbe {
    private let plans: [DistributionPlan]
    private let applyRecord: DistributionOperationRecord
    private let applyDelay: Duration?
    private let initialPlanDelay: Duration?
    private let replanDelay: Duration?
    private let planError: DistributionSymlinkFileSystemError?
    private var planIndex = 0
    private(set) var planCallCount = 0
    private(set) var applyCount = 0
    private(set) var requestedScopes: [DistributionDesiredScope] = []
    private(set) var requestedAdapterCodes: [Set<String>] = []

    init(
        plans: [DistributionPlan],
        applyRecord: DistributionOperationRecord? = nil,
        applyDelay: Duration? = nil,
        initialPlanDelay: Duration? = nil,
        replanDelay: Duration? = nil,
        planError: DistributionSymlinkFileSystemError? = nil
    ) {
        self.plans = plans
        self.applyRecord = applyRecord ?? distributionOperation(skillID: distributionSkillID())
        self.applyDelay = applyDelay
        self.initialPlanDelay = initialPlanDelay
        self.replanDelay = replanDelay
        self.planError = planError
    }

    func nextPlan(
        desiredScope: DistributionDesiredScope,
        requiredAdapterCodes: Set<String>
    ) async throws -> DistributionPlan {
        let index = planIndex
        planIndex += 1
        planCallCount += 1
        requestedScopes.append(desiredScope)
        requestedAdapterCodes.append(requiredAdapterCodes)
        if let delay = index == 0 ? initialPlanDelay : replanDelay {
            try await Task.sleep(for: delay)
        }
        if let planError { throw planError }
        return plans[min(index, plans.count - 1)]
    }

    func apply() async throws -> DistributionOperationRecord {
        applyCount += 1
        if let applyDelay {
            try await Task.sleep(for: applyDelay)
        }
        return applyRecord
    }
}

@MainActor
func distributionModel(
    bindings: [DistributionBinding] = [],
    isExplicitlyConfigured: Bool = false,
    reconcileStatus: DistributionReconcileStatus = .inSync,
    plan: DistributionPlan = distributionPlan(status: .noOp),
    loadError: DistributionSymlinkFileSystemError? = nil,
    apply: @escaping @Sendable (SkillID, DistributionPlan)
        async throws -> DistributionOperationRecord = {
        skillID, _ in distributionOperation(skillID: skillID)
    }
) -> SkillDistributionViewModel {
    let model = SkillDistributionViewModel()
    model.activate(dependencies: SkillDistributionDependencies(
        loadSelection: { _ in
            if let loadError { throw loadError }
            return DistributionSelectionReadback(
                bindings: bindings,
                isExplicitlyConfigured: isExplicitlyConfigured
            )
        },
        reconcile: { _ in
            DistributionReconcileResult(status: reconcileStatus, observations: [:])
        },
        plan: { _, _, _ in plan },
        apply: apply
    ))
    return model
}

@MainActor
func distributionModel(probe: DistributionPlanProbe) -> SkillDistributionViewModel {
    let model = SkillDistributionViewModel()
    model.activate(dependencies: SkillDistributionDependencies(
        loadSelection: { _ in DistributionSelectionReadback(
            bindings: [],
            isExplicitlyConfigured: false
        ) },
        reconcile: { _ in DistributionReconcileResult(status: .inSync, observations: [:]) },
        plan: { _, configuration, codes in
            try await probe.nextPlan(
                desiredScope: configuration.scope,
                requiredAdapterCodes: codes
            )
        },
        apply: { _, _ in try await probe.apply() }
    ))
    return model
}

func distributionSkillID() -> SkillID {
    .init(UUID(uuidString: "00112233-4455-6677-8899-aabbccddeeff")!)
}

func distributionBinding(
    skillID: SkillID,
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

func distributionPlan(
    status: DistributionPlanStatus,
    actions: [DistributionFilesystemAction] = [],
    replacement: [DistributionBindingIntent] = [],
    configurationChanged: Bool = false,
    expectedOldConfigured: Bool = true,
    desiredConfigured: Bool = true,
    conflicts: [DistributionPlanConflict] = []
) -> DistributionPlan {
    DistributionPlan(
        status: status,
        filesystemActions: actions,
        bindingsChanged: !replacement.isEmpty,
        bindingReplacement: replacement,
        configurationChanged: configurationChanged,
        expectedOldConfigured: expectedOldConfigured,
        desiredConfigured: desiredConfigured,
        conflicts: conflicts
    )
}

func distributionOperation(
    skillID: SkillID,
    phase: DistributionOperationPhase = .completed,
    outcome: DistributionOperationOutcome? = .applied
) -> DistributionOperationRecord {
    let payload = Data("{}".utf8)
    return DistributionOperationRecord(
        operationID: SSOTOperationID(),
        skillID: skillID,
        phase: phase,
        outcome: outcome,
        oldBindings: payload,
        newBindings: payload,
        planPayload: payload,
        preflightPayload: payload,
        runtimePayload: payload,
        forwardCursor: 0,
        rollbackCursor: 0,
        cleanupCursor: 0,
        attemptCount: 1,
        lastError: nil,
        createdAtMilliseconds: 1,
        updatedAtMilliseconds: 2
    )
}
