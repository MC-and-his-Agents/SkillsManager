nonisolated struct SkillForkLineageReadback: Equatable, Sendable {
    let parentSkillID: SkillID
    let parentDisplayName: String?
    let createdAtMilliseconds: Int64
    let forkedFromFingerprint: SkillContentFingerprint
}

nonisolated struct SkillDistributionDependencies: Sendable {
    let loadSelection: @Sendable (SkillID) async throws -> DistributionSelectionReadback
    let reconcile: @Sendable (SkillID) async throws -> DistributionReconcileResult
    let plan: @Sendable (
        SkillID,
        DistributionDesiredConfiguration,
        Set<String>
    ) async throws -> DistributionPlan
    let apply: @Sendable (SkillID, DistributionPlan) async throws -> DistributionOperationRecord
    let copyDriftPreview: @Sendable (
        SkillID,
        DistributionBindingScope
    ) async throws -> CopyDriftDecisionPreview
    let discardCopyDrift: @Sendable (
        CopyDriftDecisionPreview
    ) async throws -> DistributionOperationRecord
    let createCopyFork: @Sendable (
        CopyDriftDecisionPreview
    ) async throws -> CopyForkResult
    let loadForkLineage: @Sendable (
        SkillID
    ) async throws -> SkillForkLineageReadback?

    init(
        loadSelection: @escaping @Sendable (SkillID) async throws
            -> DistributionSelectionReadback,
        reconcile: @escaping @Sendable (SkillID) async throws
            -> DistributionReconcileResult,
        plan: @escaping @Sendable (
            SkillID,
            DistributionDesiredConfiguration,
            Set<String>
        ) async throws -> DistributionPlan,
        apply: @escaping @Sendable (
            SkillID,
            DistributionPlan
        ) async throws -> DistributionOperationRecord,
        copyDriftPreview: @escaping @Sendable (
            SkillID,
            DistributionBindingScope
        ) async throws -> CopyDriftDecisionPreview = { _, _ in
            throw CopyForkError.notContentOnlyDrift
        },
        discardCopyDrift: @escaping @Sendable (
            CopyDriftDecisionPreview
        ) async throws -> DistributionOperationRecord = { _ in
            throw CopyForkError.notContentOnlyDrift
        },
        createCopyFork: @escaping @Sendable (
            CopyDriftDecisionPreview
        ) async throws -> CopyForkResult = { _ in
            throw CopyForkError.notContentOnlyDrift
        },
        loadForkLineage: @escaping @Sendable (
            SkillID
        ) async throws -> SkillForkLineageReadback? = { _ in nil }
    ) {
        self.loadSelection = loadSelection
        self.reconcile = reconcile
        self.plan = plan
        self.apply = apply
        self.copyDriftPreview = copyDriftPreview
        self.discardCopyDrift = discardCopyDrift
        self.createCopyFork = createCopyFork
        self.loadForkLineage = loadForkLineage
    }

    static func live(writer: JournaledSSOTWriter) -> Self {
        let session = SkillDistributionSession(writer: writer)
        return Self(
            loadSelection: { try await session.loadSelection(skillID: $0) },
            reconcile: { try await session.reconcile(skillID: $0) },
            plan: {
                try await session.plan(
                    skillID: $0,
                    desiredConfiguration: $1,
                    requiredAdapterCodes: $2
                )
            },
            apply: { try await session.apply(skillID: $0, plan: $1) },
            copyDriftPreview: {
                try await session.copyDriftPreview(skillID: $0, scope: $1)
            },
            discardCopyDrift: { try await session.discardCopyDrift($0) },
            createCopyFork: { try await session.createCopyFork($0) },
            loadForkLineage: { try await session.loadForkLineage(skillID: $0) }
        )
    }
}

private actor SkillDistributionSession {
    private let writer: JournaledSSOTWriter

    init(writer: JournaledSSOTWriter) {
        self.writer = writer
    }

    func loadSelection(skillID: SkillID) async throws -> DistributionSelectionReadback {
        try await writer.loadDistributionSelection(skillID: skillID)
    }

    func reconcile(skillID: SkillID) async throws -> DistributionReconcileResult {
        try await writer.reconcileDistribution(skillID: skillID)
    }

    func plan(
        skillID: SkillID,
        desiredConfiguration: DistributionDesiredConfiguration,
        requiredAdapterCodes: Set<String>
    ) async throws -> DistributionPlan {
        try await writer.distributionPlan(
            skillID: skillID,
            desiredConfiguration: desiredConfiguration,
            requiredAdapterCodes: requiredAdapterCodes
        )
    }

    func apply(
        skillID: SkillID,
        plan: DistributionPlan
    ) async throws -> DistributionOperationRecord {
        try await writer.applyDistribution(skillID: skillID, plan: plan)
    }

    func copyDriftPreview(
        skillID: SkillID,
        scope: DistributionBindingScope
    ) async throws -> CopyDriftDecisionPreview {
        try await writer.copyDriftDecisionPreview(
            parentSkillID: skillID,
            scope: scope
        )
    }

    func discardCopyDrift(
        _ preview: CopyDriftDecisionPreview
    ) async throws -> DistributionOperationRecord {
        try await writer.discardCopyDrift(preview)
    }

    func createCopyFork(
        _ preview: CopyDriftDecisionPreview
    ) async throws -> CopyForkResult {
        try await writer.createCopyFork(preview)
    }

    func loadForkLineage(
        skillID: SkillID
    ) async throws -> SkillForkLineageReadback? {
        guard let lineage = try await writer.storedDomainReadback(skillID)?
                .payload.forkLineage else {
            return nil
        }
        let parentName = try await writer.storedDomainReadback(lineage.parentSkillID)?
            .payload.skill.displayName.value
        return SkillForkLineageReadback(
            parentSkillID: lineage.parentSkillID,
            parentDisplayName: parentName,
            createdAtMilliseconds: lineage.createdAtMilliseconds,
            forkedFromFingerprint: lineage.forkedFromFingerprint
        )
    }
}
