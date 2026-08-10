import Foundation

extension SkillBatchUpdateViewModel {
    func apply(
        _ snapshot: ManagedSkillUpdateCheckSnapshot,
        at index: Int
    ) {
        items[index].snapshot = snapshot
        switch snapshot.status {
        case .upToDate:
            setResult(.upToDate, detail: nil, at: index)
        case .remoteChanged:
            guard hasRemoteChange(snapshot) else {
                setResult(
                    .needsAttention,
                    detail: String(localized: "The remote update could not be proven.", bundle: .module),
                    at: index
                )
                return
            }
            items[index].phase = .ready
        case .copyDrift:
            let drifts = snapshot.copyStates.filter(\.isTargetDrift)
            guard hasRemoteChange(snapshot),
                  !drifts.isEmpty,
                  drifts.allSatisfy({ $0.state == .contentDrift }) else {
                setResult(
                    .needsAttention,
                    detail: String(localized: "The Copy state cannot be handled safely in a batch.", bundle: .module),
                    at: index
                )
                return
            }
            items[index].scopes = drifts.map {
                SkillBatchUpdateScope(
                    scopeKey: $0.scopeKey,
                    title: SkillBatchUpdatePresentation.scopeTitle($0.scopeKey)
                )
            }.sorted {
                $0.scopeKey.utf8.lexicographicallyPrecedes($1.scopeKey.utf8)
            }
            items[index].phase = .decisionRequired
        case .localModified:
            setResult(
                .conflict,
                detail: String(localized: "The managed SSOT content was modified locally.", bundle: .module),
                at: index
            )
        case .capabilityUnavailable:
            setResult(
                .needsAttention,
                detail: snapshot.capabilityReason,
                at: index
            )
        case .conflict:
            setResult(
                .conflict,
                detail: String(localized: "The managed or distributed state changed.", bundle: .module),
                at: index
            )
        }
    }

    func applyCheckError(_ error: Error, at index: Int) {
        let problem = error as? ManagedSkillUpdateCheckProblem ?? .failed
        switch problem {
        case .stale:
            setResult(.conflict, detail: problem.localizedDescription, at: index)
        case .cancelled:
            setResult(.cancelled, detail: problem.localizedDescription, at: index)
        case .unavailable:
            setResult(.needsAttention, detail: problem.localizedDescription, at: index)
        case .timeout, .offline, .rateLimited, .providerUnavailable,
             .unsafeContent, .databaseUnavailable, .failed:
            setResult(.failed, detail: problem.localizedDescription, at: index)
        }
    }

    func applyExecutionError(_ error: Error, for skillID: SkillID) {
        let problem = error as? ManagedSkillUpdateExecutionProblem ?? .failed
        switch problem {
        case .noUpdate:
            setResult(.upToDate, detail: problem.localizedDescription, for: skillID)
        case .stale:
            setResult(.conflict, detail: problem.localizedDescription, for: skillID)
        case .unavailable, .invalidDecisions, .unsafeCopyState,
             .operationInProgress, .permissionDenied, .needsRepair:
            setResult(.needsAttention, detail: problem.localizedDescription, for: skillID)
        case .providerUnavailable, .failed:
            setResult(.failed, detail: problem.localizedDescription, for: skillID)
        }
    }

    func apply(
        _ result: ManagedSkillUpdateExecutionResult,
        hadForkDecision: Bool,
        for skillID: SkillID
    ) {
        switch result.status {
        case .cancelled:
            setResult(.cancelled, detail: nil, for: skillID)
        case .noChange:
            setResult(.upToDate, detail: nil, for: skillID)
        case .updated:
            setResult(hadForkDecision ? .forked : .updated, detail: nil, for: skillID)
        case .updateRolledBack:
            setResult(
                .failed,
                detail: String(localized: "The update was rolled back without changing the managed Skill.", bundle: .module),
                for: skillID
            )
        case .backupReadyUpdateNotStarted:
            setResult(
                .needsAttention,
                detail: String(localized: "A backup is ready, but the update did not start. Recheck first.", bundle: .module),
                for: skillID
            )
        case .copyDecisionsAppliedUpdateNotCompleted:
            setResult(
                .needsAttention,
                detail: String(localized: "Copy decisions were saved, but the parent Skill was not updated.", bundle: .module),
                for: skillID
            )
        case .updatedNeedsAttention:
            setResult(
                .needsAttention,
                detail: String(localized: "The Skill was updated, but distribution needs attention.", bundle: .module),
                for: skillID
            )
        case .updateIndeterminate:
            setResult(
                .needsAttention,
                detail: String(localized: "The update state could not be confirmed safely.", bundle: .module),
                for: skillID
            )
        case .needsRepair:
            setResult(
                .needsAttention,
                detail: String(localized: "The managed Skill requires repair.", bundle: .module),
                for: skillID
            )
        }
    }

    private func hasRemoteChange(
        _ snapshot: ManagedSkillUpdateCheckSnapshot
    ) -> Bool {
        guard let candidate = snapshot.candidate,
              let liveFingerprint = snapshot.liveFingerprint else { return false }
        return candidate.contentFingerprint != liveFingerprint
    }
}
