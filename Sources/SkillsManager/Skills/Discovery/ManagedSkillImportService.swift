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
    private struct BoundRoot: Sendable {
        let scope: SkillDiscoveryScope
        let reference: ManagedRootReference
    }

    private struct Pending: Sendable {
        let action: ManagedSkillImportAction
        let roots: [BoundRoot]
        let rootIdentity: ManagedItemIdentity
        let rawLocator: String
        let normalizedLocator: String
        let collisionKey: String
        let candidateIdentity: ManagedItemIdentity
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
    private let limits: SkillContentLimits
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
              SkillContentPath.visibleDirectoryName(observation.rawRelativeLocator)
                == observation.relativeLocator,
              SkillContentPath.collisionKey(for: observation.relativeLocator)
                == observation.relativeLocatorKey else {
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
        let token = ManagedSkillImportToken()
        let newSkillID = action == .importNew ? SkillID() : nil
        states[token] = .pending(Pending(
            action: action,
            roots: roots,
            rootIdentity: observation.rootIdentity,
            rawLocator: observation.rawRelativeLocator,
            normalizedLocator: observation.relativeLocator,
            collisionKey: observation.relativeLocatorKey,
            candidateIdentity: candidateIdentity,
            fingerprint: fingerprint,
            providerAliases: observation.providerAliases,
            matchedSkillID: matchedSkillID,
            newSkillID: newSkillID
        ))
        return ManagedSkillImportPreview(
            token: token,
            action: action,
            displayName: observation.relativeLocator,
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

    private func captureSnapshot(_ pending: Pending) throws -> SkillContentSnapshot {
        do {
            let verified = try pending.roots.map { try $0.reference.verifiedRoot() }
            guard !verified.isEmpty,
                  verified.allSatisfy({ $0.identity == pending.rootIdentity }) else {
                throw ManagedSkillImportError.sourceChanged
            }
            let rootDescriptor = Darwin.open(
                verified[0].url.path,
                O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC
            )
            guard rootDescriptor >= 0 else {
                throw ManagedSkillImportError.sourceChanged
            }
            defer { Darwin.close(rootDescriptor) }
            guard try identity(of: rootDescriptor) == pending.rootIdentity else {
                throw ManagedSkillImportError.sourceChanged
            }
            let collidingNames = try SafeSourceTree.names(
                in: rootDescriptor,
                displayPath: verified[0].url.path
            ).filter {
                guard let normalized = SkillContentPath.visibleDirectoryName($0) else {
                    return false
                }
                return SkillContentPath.collisionKey(for: normalized) == pending.collisionKey
            }
            guard collidingNames == [pending.rawLocator] else {
                throw ManagedSkillImportError.conflict
            }
            let candidateDescriptor = Darwin.openat(
                rootDescriptor,
                pending.rawLocator,
                O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC
            )
            guard candidateDescriptor >= 0 else {
                throw ManagedSkillImportError.sourceChanged
            }
            defer { Darwin.close(candidateDescriptor) }
            guard try identity(of: candidateDescriptor) == pending.candidateIdentity else {
                throw ManagedSkillImportError.sourceChanged
            }
            let snapshot = try SkillContentSnapshot.capture(
                directoryDescriptor: candidateDescriptor,
                displayPath: pending.normalizedLocator,
                limits: limits,
                checkpoint: { try Task.checkCancellation() }
            )
            _ = try snapshot.readUTF8File(
                relativePath: "SKILL.md",
                checkpoint: { try Task.checkCancellation() }
            )
            guard try identity(of: candidateDescriptor) == pending.candidateIdentity,
                  try SkillContentFingerprint(currentDigest: snapshot.fingerprintDigest)
                    == pending.fingerprint,
                  try pending.roots.allSatisfy({
                      try $0.reference.verifiedRoot().identity == pending.rootIdentity
                  }) else {
                throw ManagedSkillImportError.sourceChanged
            }
            return snapshot
        } catch is CancellationError {
            throw CancellationError()
        } catch let error as ManagedSkillImportError {
            throw error
        } catch {
            throw ManagedSkillImportError.sourceChanged
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
                rawLocator: pending.rawLocator,
                normalizedLocator: pending.normalizedLocator,
                collisionKey: pending.collisionKey,
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
            rawRelativeLocator: pending.rawLocator,
            relativeLocator: pending.normalizedLocator,
            relativeLocatorKey: pending.collisionKey,
            candidateIdentity: pending.candidateIdentity,
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
        let displayName = try SkillDisplayName(pending.normalizedLocator)
        return try ManagedSkillRecord(
            skillID: skillID,
            displayName: displayName,
            defaultDistributionSlug: DefaultDistributionSlug(candidateFrom: displayName),
            contentFingerprint: pending.fingerprint,
            createdAtMilliseconds: timestamp,
            updatedAtMilliseconds: timestamp
        )
    }

    private func identity(of descriptor: Int32) throws -> ManagedItemIdentity {
        var metadata = stat()
        guard Darwin.fstat(descriptor, &metadata) == 0 else {
            throw ManagedSkillImportError.sourceChanged
        }
        return ManagedItemIdentity(metadata)
    }

    private func required<T>(_ value: T?) throws -> T {
        guard let value else { throw ManagedSkillImportError.invalidObservation }
        return value
    }
}
