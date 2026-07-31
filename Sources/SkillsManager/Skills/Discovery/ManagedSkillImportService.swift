import Darwin
import Foundation

nonisolated enum ManagedSkillImportAction: Hashable, Sendable {
    case importNew
    case claimExisting
}

nonisolated struct ManagedSkillImportToken: Hashable, Sendable {
    let uuid: UUID

    init(_ uuid: UUID = UUID()) {
        self.uuid = uuid
    }
}

nonisolated struct ManagedSkillImportPreview: Hashable, Sendable {
    let token: ManagedSkillImportToken
    let action: ManagedSkillImportAction
    let displayName: String
    let matchedSkillID: SkillID?
    let newSkillID: SkillID?
}

nonisolated enum ManagedSkillImportDisposition: Hashable, Sendable {
    case created
    case claimed
    case alreadyManaged
}

nonisolated struct ManagedSkillImportResult: Hashable, Sendable {
    let skill: ManagedSkillRecord
    let disposition: ManagedSkillImportDisposition
}

nonisolated enum ManagedSkillImportError: Error, Equatable {
    case actionNotAllowed
    case conflict
    case invalidObservation
    case sourceChanged
    case tokenExpired
}

actor ManagedSkillImportService {
    struct BoundRoot: Sendable {
        let scope: SkillDiscoveryScope
        let reference: ManagedRootReference
    }

    struct Pending: Sendable {
        let action: ManagedSkillImportAction
        let roots: [BoundRoot]
        let rootIdentity: ManagedItemIdentity
        let locator: SkillContentLocator
        let candidateIdentity: ManagedItemIdentity
        let symbolicLinkIdentity: ManagedItemIdentity?
        let candidateReference: ManagedRootReference?
        let locationRevision: SkillDiscoveryLocationRevision
        let fingerprint: SkillContentFingerprint
        let providerAliases: Set<ProviderAliasIdentity>
        let matchedSkillID: SkillID?
        let newSkillID: SkillID?
    }

    private enum State: Sendable {
        case pending(Pending)
        case completed(ManagedSkillImportResult)
    }

    private let writer: JournaledSSOTWriter
    let limits: SkillContentLimits
    private let nowMilliseconds: @Sendable () -> Int64
    private var states: [ManagedSkillImportToken: State] = [:]

    nonisolated static func allowedActions(
        for observation: SkillDiscoveryObservation
    ) -> Set<ManagedSkillImportAction> {
        switch observation.status {
        case .unmanaged:
            [.importNew]
        case .claimable where observation.matchedSkillID != nil:
            [.claimExisting]
        case .conflict:
            switch observation.reason {
            case .ambiguousSource, .ambiguousFingerprint, .evidenceConflict:
                [.importNew]
            default:
                []
            }
        default:
            []
        }
    }

    init(
        writer: JournaledSSOTWriter,
        limits: SkillContentLimits = .default,
        nowMilliseconds: @escaping @Sendable () -> Int64 = {
            max(0, Int64(Date().timeIntervalSince1970 * 1_000))
        }
    ) {
        self.writer = writer
        self.limits = limits
        self.nowMilliseconds = nowMilliseconds
    }

    func preview(
        observation: SkillDiscoveryObservation,
        action: ManagedSkillImportAction
    ) throws -> ManagedSkillImportPreview {
        guard !observation.roots.isEmpty,
              let candidateIdentity = observation.candidateIdentity,
              let fingerprint = observation.fingerprint,
              let locator = SkillContentLocator(observation.rawRelativeLocator),
              locator.normalizedValue == observation.relativeLocator,
              locator.collisionKey == observation.relativeLocatorKey,
              let locationRevision = observation.locationRevision,
              locationRevision.root.identity == observation.rootIdentity,
              locationRevision.candidate?.identity == candidateIdentity,
              (locator.rawComponents.count == 1 && locationRevision.container == nil
                || locator.rawComponents.count == 2 && locationRevision.container != nil),
              observation.symbolicLinkIdentity == nil
                || locator.rawComponents.count == 1 else {
            throw ManagedSkillImportError.invalidObservation
        }
        let matchedSkillID = try matchedSkill(
            observation: observation,
            action: action
        )
        let roots = try observation.roots.map { root in
            do {
                let reference = try ManagedRootReference.capture(at: root.url)
                guard try reference.verifiedRoot().identity == observation.rootIdentity else {
                    throw ManagedSkillImportError.sourceChanged
                }
                return BoundRoot(scope: root.scope, reference: reference)
            } catch let error as ManagedSkillImportError {
                throw error
            } catch {
                throw ManagedSkillImportError.sourceChanged
            }
        }
        let candidateReference: ManagedRootReference?
        if let linkIdentity = observation.symbolicLinkIdentity,
           let root = observation.roots.first {
            let candidateURL = root.url.appendingPathComponent(
                observation.rawRelativeLocator,
                isDirectory: true
            )
            do {
                guard try namedIdentity(at: candidateURL) == linkIdentity else {
                    throw ManagedSkillImportError.sourceChanged
                }
                let reference = try ManagedRootReference.capture(at: candidateURL)
                guard try reference.verifiedRoot().identity == candidateIdentity else {
                    throw ManagedSkillImportError.sourceChanged
                }
                candidateReference = reference
            } catch let error as ManagedSkillImportError {
                throw error
            } catch {
                throw ManagedSkillImportError.sourceChanged
            }
        } else if observation.symbolicLinkIdentity == nil {
            candidateReference = nil
        } else {
            throw ManagedSkillImportError.invalidObservation
        }
        let token = ManagedSkillImportToken()
        let newSkillID = action == .importNew ? SkillID() : nil
        let pending = Pending(
            action: action,
            roots: roots,
            rootIdentity: observation.rootIdentity,
            locator: locator,
            candidateIdentity: candidateIdentity,
            symbolicLinkIdentity: observation.symbolicLinkIdentity,
            candidateReference: candidateReference,
            locationRevision: locationRevision,
            fingerprint: fingerprint,
            providerAliases: observation.providerAliases,
            matchedSkillID: matchedSkillID,
            newSkillID: newSkillID
        )
        _ = try captureSnapshot(pending)
        states[token] = .pending(pending)
        return ManagedSkillImportPreview(
            token: token,
            action: action,
            displayName: locator.leafName,
            matchedSkillID: matchedSkillID,
            newSkillID: newSkillID
        )
    }

    func execute(_ token: ManagedSkillImportToken) async throws
        -> ManagedSkillImportResult {
        guard let state = states[token] else {
            throw ManagedSkillImportError.tokenExpired
        }
        if case .completed(let result) = state {
            return result
        }
        guard case .pending(let pending) = state else {
            throw ManagedSkillImportError.tokenExpired
        }

        let snapshot = try captureSnapshot(pending)
        let timestamp = max(0, nowMilliseconds())
        let result: ManagedSkillImportResult
        do {
            switch pending.action {
            case .importNew:
                let skillID = try required(pending.newSkillID)
                let skill = try managedSkill(
                    skillID: skillID,
                    pending: pending,
                    timestamp: timestamp
                )
                let origins = try localOrigins(
                    skillID: skillID,
                    pending: pending,
                    timestamp: timestamp
                )
                let outcome = try await writer.importNew(
                    payload: SSOTSkillWritePayload(
                        skill: skill,
                        localOrigins: origins
                    ),
                    sourceSnapshot: snapshot
                )
                result = ManagedSkillImportResult(
                    skill: outcome.skill,
                    disposition: outcome.created ? .created : .alreadyManaged
                )
            case .claimExisting:
                let skillID = try required(pending.matchedSkillID)
                let origins = try localOrigins(
                    skillID: skillID,
                    pending: pending,
                    timestamp: timestamp
                )
                result = ManagedSkillImportResult(
                    skill: try await writer.claimExisting(
                        skillID: skillID,
                        candidate: candidate(for: pending),
                        origins: origins
                    ),
                    disposition: .claimed
                )
            }
        } catch LocalSkillOriginStoreError.conflict {
            throw ManagedSkillImportError.conflict
        } catch LocalSkillOriginStoreError.invalidInput {
            throw ManagedSkillImportError.conflict
        }
        states[token] = .completed(result)
        return result
    }

    private func matchedSkill(
        observation: SkillDiscoveryObservation,
        action: ManagedSkillImportAction
    ) throws -> SkillID? {
        guard Self.allowedActions(for: observation).contains(action) else {
            throw ManagedSkillImportError.actionNotAllowed
        }
        switch action {
        case .claimExisting:
            guard let matchedSkillID = observation.matchedSkillID else {
                throw ManagedSkillImportError.actionNotAllowed
            }
            return matchedSkillID
        case .importNew:
            return nil
        }
    }

    private func localOrigins(
        skillID: SkillID,
        pending: Pending,
        timestamp: Int64
    ) throws -> [LocalSkillOriginRecord] {
        try Set(pending.roots.map(\.scope)).sorted { $0.sortKey < $1.sortKey }.map {
            try LocalSkillOriginRecord(
                skillID: skillID,
                scope: $0,
                rawLocator: pending.locator.rawValue,
                normalizedLocator: pending.locator.normalizedValue,
                collisionKey: pending.locator.collisionKey,
                fingerprint: pending.fingerprint,
                confirmedAtMilliseconds: timestamp
            )
        }
    }

    private func candidate(for pending: Pending) -> SkillDiscoveryCandidate {
        SkillDiscoveryCandidate(
            roots: pending.roots.map {
                SkillDiscoveryRoot(scope: $0.scope, url: $0.reference.canonicalURL)
            },
            rootIdentity: pending.rootIdentity,
            rawRelativeLocator: pending.locator.rawValue,
            relativeLocator: pending.locator.normalizedValue,
            relativeLocatorKey: pending.locator.collisionKey,
            candidateIdentity: pending.candidateIdentity,
            symbolicLinkIdentity: pending.symbolicLinkIdentity,
            locationRevision: pending.locationRevision,
            fingerprint: pending.fingerprint,
            providerAliases: pending.providerAliases,
            terminalStatus: nil,
            terminalReason: nil
        )
    }

    private func managedSkill(
        skillID: SkillID,
        pending: Pending,
        timestamp: Int64
    ) throws -> ManagedSkillRecord {
        let displayName = try SkillDisplayName(pending.locator.leafName)
        return try ManagedSkillRecord(
            skillID: skillID,
            displayName: displayName,
            defaultDistributionSlug: DefaultDistributionSlug(candidateFrom: displayName),
            contentFingerprint: pending.fingerprint,
            createdAtMilliseconds: timestamp,
            updatedAtMilliseconds: timestamp
        )
    }

    private func required<T>(_ value: T?) throws -> T {
        guard let value else { throw ManagedSkillImportError.invalidObservation }
        return value
    }
}
