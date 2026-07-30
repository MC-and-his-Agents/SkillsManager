import CryptoKit
import Foundation
import Testing
import ZIPFoundation

@testable import SkillsManager

@Suite("Managed Skill update checks", .serialized)
struct ManagedSkillUpdateCheckTests {
    @Test("Clawdhub exact version uses complete content fingerprints")
    func clawdhubFingerprintTruth() async throws {
        let context = try await makeContext(markdown: "# Original", clawdhubSlug: "demo")
        let unchangedArchive = try writeArchive(markdown: "# Original")
        let changedArchive = try writeArchive(markdown: "# Changed")
        defer {
            try? FileManager.default.removeItem(at: unchangedArchive)
            try? FileManager.default.removeItem(at: changedArchive)
        }
        let recorder = RemoteUpdateRecorder()
        let unchangedService = ManagedSkillUpdateCheckService(
            writer: context.writer,
            remote: remote(
                version: "2.0.0",
                archiveURL: unchangedArchive,
                recorder: recorder
            ),
            nowMilliseconds: { 10 }
        )

        let unchanged = try await unchangedService.check(context.skillID)
        #expect(unchanged.status == .upToDate)
        #expect(unchanged.checkedAtMilliseconds == 10)
        #expect(unchanged.candidate?.contentFingerprint == context.fingerprint)
        #expect(await recorder.values == ["version:demo", "download:demo:2.0.0"])

        let changedService = ManagedSkillUpdateCheckService(
            writer: context.writer,
            remote: remote(version: "3.0.0", archiveURL: changedArchive),
            nowMilliseconds: { 11 }
        )
        let changed = try await changedService.check(context.skillID)
        #expect(changed.status == .remoteChanged)
        #expect(changed.candidate?.contentFingerprint != context.fingerprint)
        #expect(try await changedService.load(context.skillID) == changed)

        let failingService = ManagedSkillUpdateCheckService(
            writer: context.writer,
            remote: RemoteSkillClient(
                fetchLatest: { _, _ in RemoteSkillPage(items: [], nextCursor: nil) },
                search: { _, _ in [] },
                download: { _, _ in throw URLError(.timedOut) },
                fetchDetail: { _ in nil },
                fetchLatestVersion: { _ in throw URLError(.timedOut) }
            )
        )
        await #expect(throws: ManagedSkillUpdateCheckProblem.timeout) {
            _ = try await failingService.check(context.skillID)
        }
        #expect(try await failingService.load(context.skillID) == changed)
    }

    @Test("missing exact source is a stable capability result without remote calls")
    func unavailableCapability() async throws {
        let context = try await makeContext(markdown: "# Local")
        let recorder = RemoteUpdateRecorder()
        let service = ManagedSkillUpdateCheckService(
            writer: context.writer,
            remote: remote(version: nil, archiveURL: nil, recorder: recorder),
            nowMilliseconds: { 12 }
        )

        let snapshot = try await service.check(context.skillID)

        #expect(snapshot.status == .capabilityUnavailable)
        #expect(snapshot.candidate == nil)
        #expect(snapshot.capabilityReason != nil)
        #expect(await recorder.values.isEmpty)
        #expect(try await service.load(context.skillID) == snapshot)
    }

    @Test("live SSOT changes win over a remote candidate")
    func localModificationWins() async throws {
        let context = try await makeContext(markdown: "# Original", clawdhubSlug: "demo")
        let archive = try writeArchive(markdown: "# Remote")
        defer { try? FileManager.default.removeItem(at: archive) }
        try Data("# Local edit".utf8).write(
            to: context.workspace.root
                .appendingPathComponent(context.skillID.directoryName)
                .appendingPathComponent("SKILL.md"),
            options: .atomic
        )
        let service = ManagedSkillUpdateCheckService(
            writer: context.writer,
            remote: remote(version: "2.0.0", archiveURL: archive)
        )

        let snapshot = try await service.check(context.skillID)

        #expect(snapshot.status == .localModified)
        #expect(snapshot.liveFingerprint != snapshot.storedFingerprint)
        #expect(snapshot.candidate != nil)
    }

    @Test("a superseded writer token cannot persist an older result")
    func supersededToken() async throws {
        let context = try await makeContext(markdown: "# Local")
        let oldToken = ManagedSkillUpdateCheckToken()
        let readback = try await context.writer.beginUpdateCheck(
            skillID: context.skillID,
            token: oldToken
        )
        _ = try await context.writer.beginUpdateCheck(
            skillID: context.skillID,
            token: ManagedSkillUpdateCheckToken()
        )
        let payload = try SSOTWritePayloadCodec.encode(readback.domain.payload)
        let snapshot = ManagedSkillUpdateCheckSnapshot(
            skillID: context.skillID,
            checkedAtMilliseconds: 1,
            status: .capabilityUnavailable,
            domainRevision: readback.domain.revision,
            domainPayloadDigest: Data(SHA256.hash(data: payload)),
            storedFingerprint: readback.domain.payload.skill.contentFingerprint,
            liveSSOTIdentity: readback.liveSSOTIdentity,
            liveFingerprint: readback.liveFingerprint,
            candidate: nil,
            copyStates: readback.copyStates,
            capabilityReason: "No source"
        )

        await #expect(throws: ManagedSkillUpdateCheckProblem.stale) {
            try await context.writer.commitUpdateCheck(
                skillID: context.skillID,
                token: oldToken,
                expectedCanonicalReadback: readback.canonicalData,
                stableSnapshot: snapshot
            )
        }
        #expect(try await context.writer.loadUpdateCheck(context.skillID) == nil)
    }

    @Test("cancellation before the writer transaction leaves no stable record")
    func cancelledCommit() async throws {
        let gate = UpdateCheckCancellationGate()
        var hooks = JournaledSSOTWriterHooks()
        hooks.beforeUpdateCheckCommit = gate.reach
        let context = try await makeContext(markdown: "# Local", hooks: hooks)
        let token = ManagedSkillUpdateCheckToken()
        let readback = try await context.writer.beginUpdateCheck(
            skillID: context.skillID,
            token: token
        )
        let payload = try SSOTWritePayloadCodec.encode(readback.domain.payload)
        let snapshot = ManagedSkillUpdateCheckSnapshot(
            skillID: context.skillID,
            checkedAtMilliseconds: 1,
            status: .capabilityUnavailable,
            domainRevision: readback.domain.revision,
            domainPayloadDigest: Data(SHA256.hash(data: payload)),
            storedFingerprint: readback.domain.payload.skill.contentFingerprint,
            liveSSOTIdentity: readback.liveSSOTIdentity,
            liveFingerprint: readback.liveFingerprint,
            candidate: nil,
            copyStates: readback.copyStates,
            capabilityReason: "No source"
        )
        let task = Task {
            try await context.writer.commitUpdateCheck(
                skillID: context.skillID,
                token: token,
                expectedCanonicalReadback: readback.canonicalData,
                stableSnapshot: snapshot
            )
        }
        gate.waitUntilReached()
        task.cancel()
        gate.release()

        await #expect(throws: CancellationError.self) {
            try await task.value
        }
        #expect(try await context.writer.loadUpdateCheck(context.skillID) == nil)
    }

    @Test("Copy source changes do not replace the remote update classification")
    func copySourceChangedIsOnlyANotice() async throws {
        let context = try await makeContext(markdown: "# Local")
        let base = try await context.writer.updateCheckReadback(skillID: context.skillID)
        let sourceChanged = ManagedSkillUpdateCopyState(
            scopeKey: "global",
            state: .sourceChanged,
            baselineFingerprint: context.fingerprint,
            observedFingerprint: context.fingerprint,
            baselineTreeDigest: nil,
            observedTreeDigest: nil,
            baselineRootIdentity: nil,
            observedRootIdentity: nil,
            baselineEntryIdentity: nil,
            observedEntryIdentity: nil
        )
        let readback = ManagedSkillUpdateCheckReadback(
            skillID: base.skillID,
            domain: base.domain,
            canonicalData: base.canonicalData,
            liveSSOTIdentity: base.liveSSOTIdentity,
            liveFingerprint: base.liveFingerprint,
            distributionStatus: .drifted,
            distributionHasOnlyCopySourceDrift: true,
            copyStates: [sourceChanged]
        )
        let candidate = ManagedSkillUpdateCandidate(
            locator: .clawdhub(
                slug: "demo",
                version: try SourceVersion("2.0.0")
            ),
            contentFingerprint: context.fingerprint
        )

        #expect(ManagedSkillUpdateCheckStatus.classify(
            readback: readback,
            candidate: candidate
        ) == .upToDate)
        #expect(ManagedSkillUpdateCheckStatus.classify(
            readback: readback,
            candidate: nil
        ) == .capabilityUnavailable)
    }

    @Test("canonical snapshot codec round-trips Copy notices")
    func codecRoundTrip() throws {
        let skillID = SkillID()
        let fingerprint = try SkillContentFingerprint(
            algorithmVersion: 1,
            digest: Data(repeating: 1, count: 32)
        )
        let snapshot = ManagedSkillUpdateCheckSnapshot(
            skillID: skillID,
            checkedAtMilliseconds: 42,
            status: .capabilityUnavailable,
            domainRevision: 3,
            domainPayloadDigest: Data(repeating: 2, count: 32),
            storedFingerprint: fingerprint,
            liveSSOTIdentity: nil,
            liveFingerprint: nil,
            candidate: nil,
            copyStates: [
                .init(
                    scopeKey: "global",
                    state: .sourceChanged,
                    baselineFingerprint: fingerprint,
                    observedFingerprint: fingerprint,
                    baselineTreeDigest: nil,
                    observedTreeDigest: nil,
                    baselineRootIdentity: nil,
                    observedRootIdentity: nil,
                    baselineEntryIdentity: nil,
                    observedEntryIdentity: nil
                ),
            ],
            capabilityReason: "No source"
        )

        #expect(try ManagedSkillUpdateCheckCodec.decode(
            ManagedSkillUpdateCheckCodec.encode(snapshot)
        ) == snapshot)
        #expect(snapshot.sourceChangedScopeKeys == ["global"])
    }
}

private struct UpdateCheckContext {
    let workspace: WriterWorkspace
    let writer: JournaledSSOTWriter
    let skillID: SkillID
    let fingerprint: SkillContentFingerprint
}

private func makeContext(
    markdown: String,
    clawdhubSlug: String? = nil,
    hooks: JournaledSSOTWriterHooks = .init()
) async throws -> UpdateCheckContext {
    let workspace = try WriterWorkspace()
    let writer = try await workspace.openWriter(hooks: hooks)
    let sourceSnapshot = try workspace.snapshot(content: markdown)
    let skillID = SkillID()
    let base = try workspace.payload(
        skillID: skillID,
        name: "Demo",
        snapshot: sourceSnapshot
    )
    let provenance: [ProviderProvenanceRecord]
    if let clawdhubSlug {
        let identity = try ProviderAliasIdentity(
            provider: "clawdhub",
            identifier: clawdhubSlug
        )
        provenance = [
            try ProviderProvenanceRecord(
                skillID: skillID,
                identity: identity,
                identifierKey: try DefaultDistributionSlug(
                    validating: clawdhubSlug
                ).collisionKey,
                version: try SourceVersion("1.0.0")
            ),
        ]
    } else {
        provenance = []
    }
    let payload = try SSOTSkillWritePayload(
        skill: base.skill,
        providerProvenance: provenance
    )
    _ = try await writer.create(payload: payload, sourceSnapshot: sourceSnapshot)
    return UpdateCheckContext(
        workspace: workspace,
        writer: writer,
        skillID: skillID,
        fingerprint: payload.skill.contentFingerprint
    )
}

private func remote(
    version: String?,
    archiveURL: URL?,
    recorder: RemoteUpdateRecorder? = nil
) -> RemoteSkillClient {
    RemoteSkillClient(
        fetchLatest: { _, _ in RemoteSkillPage(items: [], nextCursor: nil) },
        search: { _, _ in [] },
        download: { slug, version in
            if let recorder { await recorder.append("download:\(slug):\(version ?? "nil")") }
            guard let archiveURL else { throw URLError(.badServerResponse) }
            return DownloadedSkillArchive(borrowedAt: archiveURL)
        },
        fetchDetail: { _ in nil },
        fetchLatestVersion: { slug in
            if let recorder { await recorder.append("version:\(slug)") }
            return version
        }
    )
}

private func writeArchive(markdown: String) throws -> URL {
    let url = FileManager.default.temporaryDirectory
        .appendingPathComponent("update-check-\(UUID().uuidString).zip")
    let archive = try Archive(url: url, accessMode: .create)
    let contents = Data(markdown.utf8)
    try archive.addEntry(
        with: "demo/SKILL.md",
        type: .file,
        uncompressedSize: Int64(contents.count),
        permissions: 0o644
    ) { position, size in
        let start = Int(position)
        return contents.subdata(in: start..<min(start + size, contents.count))
    }
    return url
}

private actor RemoteUpdateRecorder {
    private(set) var values: [String] = []

    func append(_ value: String) {
        values.append(value)
    }
}

private final class UpdateCheckCancellationGate: @unchecked Sendable {
    private let reached = DispatchSemaphore(value: 0)
    private let released = DispatchSemaphore(value: 0)

    func reach() {
        reached.signal()
        released.wait()
    }

    func waitUntilReached() {
        reached.wait()
    }

    func release() {
        released.signal()
    }
}
