nonisolated struct SkillDistributionDependencies: Sendable {
    let loadBindings: @Sendable (SkillID) async throws -> [DistributionBinding]
    let reconcile: @Sendable (SkillID) async throws -> DistributionReconcileResult
    let plan: @Sendable (
        SkillID,
        DistributionDesiredScope,
        Set<String>
    ) async throws -> DistributionPlan
    let apply: @Sendable (SkillID, DistributionPlan) async throws -> DistributionOperationRecord

    static func live(writer: JournaledSSOTWriter) -> Self {
        let session = SkillDistributionSession(writer: writer)
        return Self(
            loadBindings: { try await session.loadBindings(skillID: $0) },
            reconcile: { try await session.reconcile(skillID: $0) },
            plan: { try await session.plan(skillID: $0, desiredScope: $1, requiredAdapterCodes: $2) },
            apply: { try await session.apply(skillID: $0, plan: $1) }
        )
    }
}

private actor SkillDistributionSession {
    private let writer: JournaledSSOTWriter

    init(writer: JournaledSSOTWriter) {
        self.writer = writer
    }

    func loadBindings(skillID: SkillID) async throws -> [DistributionBinding] {
        try await writer.loadDistributionBindings(skillID: skillID)
    }

    func reconcile(skillID: SkillID) async throws -> DistributionReconcileResult {
        try await writer.reconcileDistribution(skillID: skillID)
    }

    func plan(
        skillID: SkillID,
        desiredScope: DistributionDesiredScope,
        requiredAdapterCodes: Set<String>
    ) async throws -> DistributionPlan {
        try await writer.distributionPlan(
            skillID: skillID,
            desiredScope: desiredScope,
            requiredAdapterCodes: requiredAdapterCodes
        )
    }

    func apply(
        skillID: SkillID,
        plan: DistributionPlan
    ) async throws -> DistributionOperationRecord {
        try await writer.applyDistribution(skillID: skillID, plan: plan)
    }
}
