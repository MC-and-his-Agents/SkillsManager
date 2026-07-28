import Foundation

extension JournaledSSOTWriter {
    func copyDriftDecisionPreview(
        parentSkillID: SkillID,
        scope: DistributionBindingScope
    ) throws -> CopyDriftDecisionPreview {
        try withStableCopyForkErrors {
            try requireAuthority()
            let context = try copyForkContext(
                parentSkillID: parentSkillID,
                scope: scope
            )
            try CopyForkAdmission(connection: connection).requireAvailable(
                skillIDs: [parentSkillID],
                target: context.target
            )
            let capture = try captureContentOnlyDrift(
                entry: context.entry,
                baseline: context.baseline
            )
            let operationID = SSOTOperationID()
            let childSkillID = SkillID()
            let createdAt = initialTimestamp()
            let wire = try copyForkWire(
                operationID: operationID,
                childWriteOperationID: SSOTOperationID(),
                parentSkillID: parentSkillID,
                childSkillID: childSkillID,
                parentRevision: context.domain.revision,
                binding: context.binding,
                evidence: capture.evidence,
                parent: context.domain.payload.skill,
                createdAt: createdAt
            )
            let forkToken = try wire.canonicalData()
            let sourceEvidence = try copyDistribution.fileSystem
                .copySource(for: parentSkillID)
                .decisionEvidence()
            let decisionWire = try CopyDriftDecisionPreviewWire(
                forkPreviewToken: forkToken,
                sourceEvidence: sourceEvidence
            )
            return CopyDriftDecisionPreview(
                parentRevision: context.domain.revision,
                binding: context.binding,
                observedEvidence: capture.evidence,
                sourceEvidence: sourceEvidence,
                token: try decisionWire.canonicalData(),
                forkPreview: CopyForkPreview(
                    operationID: operationID,
                    parentSkillID: parentSkillID,
                    childSkillID: childSkillID,
                    scope: scope,
                    distributionSlug: context.binding.distributionSlug,
                    contentFingerprint: capture.evidence.contentFingerprint,
                    token: forkToken
                )
            )
        }
    }

    func discardCopyDrift(
        _ preview: CopyDriftDecisionPreview
    ) throws -> DistributionOperationRecord {
        try withStableCopyForkErrors {
            try requireAuthority()
            let fork = preview.forkPreview
            let wire = try CopyForkPreviewWire.decode(fork.token)
            try requirePreview(fork, matches: wire)
            try requireCopyDriftDecisionSource(preview)
            let context = try copyForkContext(
                parentSkillID: fork.parentSkillID,
                scope: fork.scope
            )
            try CopyForkAdmission(connection: connection).requireAvailable(
                skillIDs: [fork.parentSkillID],
                target: context.target
            )
            let capture = try captureContentOnlyDrift(
                entry: context.entry,
                baseline: context.baseline
            )
            let refreshed = try copyForkWire(
                operationID: fork.operationID,
                childWriteOperationID: SSOTOperationID(wire.childWriteOperationID),
                parentSkillID: fork.parentSkillID,
                childSkillID: fork.childSkillID,
                parentRevision: context.domain.revision,
                binding: context.binding,
                evidence: capture.evidence,
                parent: context.domain.payload.skill,
                createdAt: wire.createdAtMilliseconds
            )
            guard context.domain.revision == preview.parentRevision,
                  context.binding == preview.binding,
                  capture.evidence == preview.observedEvidence,
                  try refreshed.canonicalData() == fork.token else {
                throw CopyForkError.previewExpired
            }

            let configured = try DistributionConfigurationStore(
                connection: connection
            ).load(skillID: fork.parentSkillID)
            let plan = DistributionPlan(
                status: .executable,
                filesystemActions: [DistributionFilesystemAction(
                    kind: .discardCopyDrift,
                    entry: context.entry,
                    ssotLocator: DistributionTargetCatalog.current.ssotLocator(
                        for: fork.parentSkillID
                    )
                )],
                bindingsChanged: false,
                bindingReplacement: context.bindings.map(\.intent).sorted {
                    distributionBindingIntentPrecedes($0, $1)
                },
                configurationChanged: false,
                expectedOldConfigured: configured,
                desiredConfigured: configured,
                conflicts: []
            )
            return try copyDistribution.apply(
                skillID: fork.parentSkillID,
                plan: plan,
                expectedOldBindings: context.bindings,
                approvedCopyDrift: capture.evidence,
                approvedCopySource: preview.sourceEvidence
            )
        }
    }

    func createCopyFork(
        _ preview: CopyDriftDecisionPreview
    ) throws -> CopyForkResult {
        try withStableCopyForkErrors {
            try requireAuthority()
            try requireCopyDriftDecisionSource(preview)
            return try createCopyFork(preview.forkPreview)
        }
    }

    private func requireCopyDriftDecisionSource(
        _ preview: CopyDriftDecisionPreview
    ) throws {
        let wire = try CopyDriftDecisionPreviewWire.decode(preview.token)
        let expectedWire = try CopyDriftDecisionPreviewWire(
            forkPreviewToken: preview.forkPreview.token,
            sourceEvidence: preview.sourceEvidence
        )
        let currentSource = try copyDistribution.fileSystem
            .copySource(for: preview.forkPreview.parentSkillID)
            .decisionEvidence()
        guard wire == expectedWire,
              try expectedWire.canonicalData() == preview.token,
              currentSource == preview.sourceEvidence else {
            throw CopyForkError.previewExpired
        }
    }
}
