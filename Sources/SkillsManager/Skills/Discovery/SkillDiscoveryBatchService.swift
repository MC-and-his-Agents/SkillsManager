import Foundation

nonisolated struct SkillDiscoveryBatchDependencies: Sendable {
    let preview: @Sendable (
        SkillDiscoveryObservation,
        ManagedSkillImportAction
    ) async throws -> ManagedSkillImportPreview
    let execute: @Sendable (ManagedSkillImportToken) async throws -> ManagedSkillImportResult
    let plan: @Sendable (
        SkillID,
        DistributionDesiredConfiguration,
        Set<String>
    ) async throws -> DistributionPlan
    let apply: @Sendable (SkillID, DistributionPlan) async throws -> DistributionOperationRecord

    init(
        preview: @escaping @Sendable (
            SkillDiscoveryObservation,
            ManagedSkillImportAction
        ) async throws -> ManagedSkillImportPreview,
        execute: @escaping @Sendable (ManagedSkillImportToken) async throws
            -> ManagedSkillImportResult,
        plan: @escaping @Sendable (
            SkillID,
            DistributionDesiredConfiguration,
            Set<String>
        ) async throws -> DistributionPlan,
        apply: @escaping @Sendable (SkillID, DistributionPlan) async throws
            -> DistributionOperationRecord
    ) {
        self.preview = preview
        self.execute = execute
        self.plan = plan
        self.apply = apply
    }

    static func live(writer: JournaledSSOTWriter) -> Self {
        let importer = ManagedSkillImportService(writer: writer)
        let distribution = SkillDistributionDependencies.live(writer: writer)
        return Self(
            preview: { try await importer.preview(observation: $0, action: $1) },
            execute: { try await importer.execute($0) },
            plan: distribution.plan,
            apply: distribution.apply
        )
    }
}

actor SkillDiscoveryBatchImportService {
    private let dependencies: SkillDiscoveryBatchDependencies

    init(dependencies: SkillDiscoveryBatchDependencies) {
        self.dependencies = dependencies
    }

    func preview(
        candidate: SkillDiscoveryBatchCandidate,
        action: ManagedSkillImportAction,
        scope: ManagedLocalImportScope
    ) async throws -> SkillDiscoveryBatchPreviewItem {
        let preview = try await dependencies.preview(candidate.observation, action)
        let skillID = preview.newSkillID ?? preview.matchedSkillID
        var slug: DefaultDistributionSlug?
        var plan: DistributionPlan?
        var planReason: String?
        if action == .importNew {
            do {
                let displayName = try SkillDisplayName(preview.displayName)
                slug = try DefaultDistributionSlug(candidateFrom: displayName)
                guard let skillID, let slug else {
                    throw ManagedSkillImportError.invalidObservation
                }
                let desiredScope = try scope.desiredScope(slug: slug)
                let configuration = DistributionDesiredConfiguration(
                    scope: desiredScope,
                    syncMode: .symlink
                )
                plan = try await dependencies.plan(
                    skillID,
                    configuration,
                    desiredScope.requiredAdapterCodes
                )
            } catch {
                planReason = Self.message(for: error)
            }
        }
        return SkillDiscoveryBatchPreviewItem(
            id: candidate.id,
            action: action,
            token: preview.token,
            displayName: preview.displayName,
            skillID: skillID,
            distributionSlug: slug,
            sourceURLs: candidate.aliases.map(\.url),
            reason: planReason,
            plan: plan,
            canonicalPlan: try plan?.canonicalJSONData()
        )
    }

    func execute(_ token: ManagedSkillImportToken) async throws -> ManagedSkillImportResult {
        try await dependencies.execute(token)
    }

    func apply(
        skillID: SkillID,
        plan: DistributionPlan
    ) async throws -> DistributionOperationRecord {
        try await dependencies.apply(skillID, plan)
    }

    func replan(
        skillID: SkillID,
        slug: DefaultDistributionSlug,
        scope: ManagedLocalImportScope
    ) async throws -> DistributionPlan {
        let desiredScope = try scope.desiredScope(slug: slug)
        return try await dependencies.plan(
            skillID,
            DistributionDesiredConfiguration(scope: desiredScope, syncMode: .symlink),
            desiredScope.requiredAdapterCodes
        )
    }

    nonisolated static func message(for error: Error) -> String {
        if let error = error as? ManagedSkillImportError {
            switch error {
            case .actionNotAllowed:
                "This action is no longer available."
            case .conflict:
                "The source now conflicts with another managed Skill."
            case .invalidObservation:
                "The discovery result is no longer valid."
            case .sourceChanged:
                "The source changed after preview."
            case .tokenExpired:
                "The preview expired."
            }
        } else if let error = error as? ManagedLocalImportProblem {
            switch error {
            case .failed, .updateFailed:
                "The operation could not be completed safely."
            default:
                error.errorDescription ?? "The import could not be completed safely."
            }
        } else {
            "The operation could not be completed safely."
        }
    }
}
