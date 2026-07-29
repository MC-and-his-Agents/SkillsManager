import CryptoKit
import Foundation

actor ManagedSkillUpdateCheckService {
    private let writer: JournaledSSOTWriter
    private let remote: RemoteSkillClient
    private let github: SkillsShGitHubSourceClient
    private let importWorker: SkillImportWorker
    private let nowMilliseconds: @Sendable () -> Int64

    init(
        writer: JournaledSSOTWriter,
        remote: RemoteSkillClient,
        github: SkillsShGitHubSourceClient = .live(),
        importWorker: SkillImportWorker = SkillImportWorker(),
        nowMilliseconds: @escaping @Sendable () -> Int64 = {
            Int64(Date().timeIntervalSince1970 * 1_000)
        }
    ) {
        self.writer = writer
        self.remote = remote
        self.github = github
        self.importWorker = importWorker
        self.nowMilliseconds = nowMilliseconds
    }

    func load(_ skillID: SkillID) async throws -> ManagedSkillUpdateCheckSnapshot? {
        try await writer.loadUpdateCheck(skillID)
    }

    func check(_ skillID: SkillID) async throws -> ManagedSkillUpdateCheckSnapshot {
        let token = ManagedSkillUpdateCheckToken()
        let initial = try await writer.beginUpdateCheck(skillID: skillID, token: token)
        let candidate: ManagedSkillUpdateCandidate?
        let capabilityReason: String?
        do {
            candidate = try await remoteCandidate(for: initial.domain)
            capabilityReason = nil
        } catch ManagedSkillUpdateCheckProblem.unavailable {
            candidate = nil
            capabilityReason = "No exact remote source is available for this Skill."
        } catch {
            throw Self.problem(for: error)
        }
        try Task.checkCancellation()
        let final = try await writer.updateCheckReadback(skillID: skillID)
        guard final.canonicalData == initial.canonicalData else {
            throw ManagedSkillUpdateCheckProblem.stale
        }
        let checkedAt = max(0, nowMilliseconds())
        let payload = try SSOTWritePayloadCodec.encode(final.domain.payload)
        let snapshot = ManagedSkillUpdateCheckSnapshot(
            skillID: skillID,
            checkedAtMilliseconds: checkedAt,
            status: ManagedSkillUpdateCheckStatus.classify(
                readback: final,
                candidate: candidate
            ),
            domainRevision: final.domain.revision,
            domainPayloadDigest: Data(SHA256.hash(data: payload)),
            storedFingerprint: final.domain.payload.skill.contentFingerprint,
            liveSSOTIdentity: final.liveSSOTIdentity,
            liveFingerprint: final.liveFingerprint,
            candidate: candidate,
            copyStates: final.copyStates,
            capabilityReason: capabilityReason
        )
        do {
            try await writer.commitUpdateCheck(
                skillID: skillID,
                token: token,
                expectedCanonicalReadback: final.canonicalData,
                stableSnapshot: snapshot
            )
        } catch {
            throw Self.problem(for: error)
        }
        return snapshot
    }

    private func remoteCandidate(
        for domain: StoredSkillDomainSnapshot
    ) async throws -> ManagedSkillUpdateCandidate {
        if let source = domain.payload.source {
            return try await githubCandidate(source)
        }
        let provenance = domain.payload.providerProvenance.filter {
            $0.identity.provider == "clawdhub"
        }
        guard provenance.count == 1 else {
            throw ManagedSkillUpdateCheckProblem.unavailable
        }
        return try await clawdhubCandidate(provenance[0])
    }

    private func clawdhubCandidate(
        _ provenance: ProviderProvenanceRecord
    ) async throws -> ManagedSkillUpdateCandidate {
        let slug = provenance.identity.identifier
        guard let rawVersion = try await remote.fetchLatestVersion(slug),
              !rawVersion.isEmpty else {
            throw ManagedSkillUpdateCheckProblem.unavailable
        }
        let version: SourceVersion
        do {
            version = try SourceVersion(rawVersion)
        } catch {
            throw ManagedSkillUpdateCheckProblem.unavailable
        }
        let archive = try await remote.download(slug, version.value)
        let payload: SkillImportWorker.ImportCandidatePayload
        do {
            payload = try await importWorker.validateZip(archive.url)
        } catch {
            try? archive.removeIfOwned()
            throw error
        }
        do {
            try archive.removeIfOwned()
        } catch {
            if let lease = payload.temporaryRoot {
                await importWorker.cleanupTemporaryRoot(lease)
            }
            throw error
        }
        do {
            let candidate = ManagedSkillUpdateCandidate(
                locator: .clawdhub(slug: slug, version: version),
                contentFingerprint: try SkillContentFingerprint(
                    currentDigest: payload.snapshot.fingerprintDigest
                )
            )
            if let lease = payload.temporaryRoot {
                await importWorker.cleanupTemporaryRoot(lease)
            }
            return candidate
        } catch {
            if let lease = payload.temporaryRoot {
                await importWorker.cleanupTemporaryRoot(lease)
            }
            throw error
        }
    }

    private func githubCandidate(
        _ source: SkillSourceRecord
    ) async throws -> ManagedSkillUpdateCandidate {
        let resolved: SkillsShResolvedGitHubUpdateSource
        do {
            resolved = try await github.resolveExisting(
                source.repositoryURL,
                source.subpath
            )
        } catch let error as SkillsShGitHubSourceError {
            switch error {
            case .invalidSource, .repositoryUnavailable, .treeTruncated,
                 .noUniqueSkillMatch:
                throw ManagedSkillUpdateCheckProblem.unavailable
            case .rateLimited, .timeout, .offline, .network, .cancelled,
                 .providerUnavailable, .responseTooLarge, .contractChanged:
                throw error
            }
        }
        let downloaded = try await github.downloadExisting(resolved)
        let archive = try await Task.detached {
            try persistDownloadedSkillArchive(data: downloaded.data)
        }.value
        let payload: SkillImportWorker.ImportCandidatePayload
        do {
            payload = try await importWorker.validateZip(
                archive.url,
                repositorySubpath: resolved.subpath,
                expectedBlobs: try resolved.blobs.map {
                    guard let byteCount = UInt64(exactly: $0.size) else {
                        throw SkillsShGitHubSourceError.contractChanged
                    }
                    return try SafeSkillArchive.RepositoryBlobExpectation(
                        relativePath: $0.relativePath,
                        mode: $0.mode,
                        byteCount: byteCount,
                        gitBlobSHA: $0.gitBlobSHA
                    )
                }
            )
        } catch {
            try? archive.removeIfOwned()
            throw error
        }
        do {
            try archive.removeIfOwned()
        } catch {
            if let lease = payload.temporaryRoot {
                await importWorker.cleanupTemporaryRoot(lease)
            }
            throw error
        }
        do {
            let candidate = ManagedSkillUpdateCandidate(
                locator: .github(
                    repositoryURL: resolved.repositoryURL,
                    subpath: resolved.subpath,
                    revision: try SourceRevision(resolved.commitSHA),
                    downloadURL: try PublicDownloadURL(resolved.archiveURL.absoluteString)
                ),
                contentFingerprint: try SkillContentFingerprint(
                    currentDigest: payload.snapshot.fingerprintDigest
                )
            )
            if let lease = payload.temporaryRoot {
                await importWorker.cleanupTemporaryRoot(lease)
            }
            return candidate
        } catch {
            if let lease = payload.temporaryRoot {
                await importWorker.cleanupTemporaryRoot(lease)
            }
            throw error
        }
    }

    private nonisolated static func problem(
        for error: Error
    ) -> ManagedSkillUpdateCheckProblem {
        if let problem = error as? ManagedSkillUpdateCheckProblem {
            return problem
        }
        if error is CancellationError { return .cancelled }
        if let urlError = error as? URLError {
            return switch urlError.code {
            case .cancelled: .cancelled
            case .timedOut: .timeout
            case .notConnectedToInternet, .networkConnectionLost,
                 .cannotConnectToHost, .cannotFindHost: .offline
            default: .providerUnavailable
            }
        }
        if let remoteError = error as? RemoteSkillClientError {
            return switch remoteError {
            case .rateLimited: .rateLimited
            case .providerUnavailable: .providerUnavailable
            case .invalidResponse: .failed
            }
        }
        if let githubError = error as? SkillsShGitHubSourceError {
            return switch githubError {
            case .rateLimited: .rateLimited
            case .timeout: .timeout
            case .offline: .offline
            case .cancelled: .cancelled
            case .network: .providerUnavailable
            case .providerUnavailable: .providerUnavailable
            case .invalidSource, .noUniqueSkillMatch, .treeTruncated,
                 .contractChanged, .repositoryUnavailable, .responseTooLarge:
                .unsafeContent
            }
        }
        if error is SkillImportValidationError || error is SafeSkillArchiveError {
            return .unsafeContent
        }
        if error is UpdateCheckStoreError || error is SQLiteStoreError {
            return .databaseUnavailable
        }
        return .failed
    }
}
