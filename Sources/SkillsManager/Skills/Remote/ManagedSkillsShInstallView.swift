import SwiftUI

struct ManagedSkillsShInstallView: View {
    let item: SkillsShSearchItem

    var body: some View {
        ManagedGitHubInstallView(request: .skillsSh(item))
    }
}

struct ManagedCustomRepositoryInstallView: View {
    @Environment(SkillStore.self) private var store

    let candidate: CustomRepositoryCandidate

    var body: some View {
        if let writer = store.persistence, let slug = candidate.distributionSlug {
            ManagedGitHubInstallView(
                request: .customRepository(candidate, writer: writer, slug: slug)
            )
        } else {
            ContentUnavailableView(
                "Installation unavailable",
                systemImage: "exclamationmark.triangle",
                description: Text(
                    candidate.installProblem ?? "The managed library is unavailable."
                )
            )
            .frame(minWidth: 520, minHeight: 320)
        }
    }
}

nonisolated struct ManagedGitHubResolvedInstall: Sendable {
    let source: SkillsShResolvedGitHubUpdateSource
    let sourceInput: ManagedSourceInstallInput
}

nonisolated struct ManagedGitHubInstallRequest: Sendable {
    let displayName: String
    let detail: String
    let resolve: @Sendable () async throws -> ManagedGitHubResolvedInstall
    let download:
        @Sendable (SkillsShResolvedGitHubUpdateSource) async throws -> SkillsShGitHubArchive

    static func skillsSh(
        _ item: SkillsShSearchItem,
        client: SkillsShGitHubSourceClient = .live()
    ) -> Self {
        Self(
            displayName: item.name,
            detail: "verify \(item.source), find one matching SKILL.md, and pin the install to an immutable GitHub commit.",
            resolve: {
                let source = try await client.resolve(item.id, item.source, item.skillID)
                let updateSource = SkillsShResolvedGitHubUpdateSource(
                    repositoryURL: source.repositoryURL,
                    owner: source.owner,
                    repository: source.repository,
                    defaultBranch: source.defaultBranch,
                    commitSHA: source.commitSHA,
                    treeSHA: source.treeSHA,
                    subpath: source.subpath,
                    blobs: source.blobs,
                    archiveURL: source.archiveURL
                )
                return ManagedGitHubResolvedInstall(
                    source: updateSource,
                    sourceInput: ManagedSourceInstallInput(
                        displayName: item.name,
                        distributionSlug: source.defaultDistributionSlug,
                        repositoryURL: source.repositoryURL,
                        subpath: source.subpath,
                        revision: try SourceRevision(source.commitSHA),
                        downloadURL: try PublicDownloadURL(source.archiveURL.absoluteString),
                        alias: try ProviderAliasIdentity(
                            provider: "skills.sh",
                            identifier: source.providerAliasIdentifier
                        ),
                        refreshHead: {
                            try SourceRevision(try await client.currentCommitSHA(source))
                        }
                    )
                )
            },
            download: { try await client.downloadExisting($0) }
        )
    }

    static func customRepository(
        _ candidate: CustomRepositoryCandidate,
        writer: JournaledSSOTWriter,
        slug: DefaultDistributionSlug,
        client: SkillsShGitHubSourceClient = .live()
    ) -> Self {
        Self(
            displayName: candidate.displayName,
            detail: "verify \(candidate.repository.displayName) at the discovered commit and exact Skill subpath.",
            resolve: {
                let source = try await client.resolveCustomRepository(candidate.snapshot)
                return ManagedGitHubResolvedInstall(
                    source: source,
                    sourceInput: try candidate.snapshot.managedSourceInput(
                        displayName: candidate.displayName,
                        distributionSlug: slug,
                        loadCatalog: { try await writer.loadCustomRepository(id: $0) },
                        refresh: { try await client.discoverRepository($0) }
                    )
                )
            },
            download: { try await client.downloadExisting($0) }
        )
    }
}

private struct ManagedGitHubInstallView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(SkillStore.self) private var store
    @Environment(SkillDiscoveryViewModel.self) private var discoveryModel
    @Environment(LibraryRuntimeState.self) private var libraryRuntime
    @Environment(CustomRepositoryViewModel.self) private var customRepositoryModel

    let request: ManagedGitHubInstallRequest

    @State private var model = ManagedLocalImportViewModel()
    @State private var distributionMode: ManagedInstallDistributionMode = .global
    @State private var selectedAgents: Set<SkillPlatform> = [.codex]
    @State private var candidate: SkillImportWorker.ImportCandidatePayload?
    @State private var activeTask: Task<Void, Never>?
    @State private var isResolving = false
    @State private var errorMessage: String?

    private let importWorker = SkillImportWorker()

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            header
            if let result = model.result {
                resultView(result)
            } else {
                ManagedInstallScopePicker(
                    mode: $distributionMode,
                    selectedAgents: $selectedAgents,
                    isDisabled: isWorking
                )
                if isResolving {
                    ProgressView("Resolving and validating GitHub source…")
                }
                if let problem = model.problem {
                    problemLabel(problem.localizedDescription)
                } else if let errorMessage {
                    problemLabel(errorMessage)
                }
                Spacer()
                actions
            }
        }
        .padding(20)
        .frame(minWidth: 620, minHeight: 440)
        .sheet(item: previewBinding) { preview in
            ManagedLocalImportPreviewView(preview: preview, onConfirm: confirmInstall)
                .environment(model)
        }
        .task {
            model.activate(writer: store.persistence)
        }
        .onChange(of: libraryRuntime.readiness) { _, _ in
            if !isWorking {
                model.activate(writer: store.persistence)
            }
        }
        .onDisappear {
            cancelAndCleanup()
        }
        .interactiveDismissDisabled(isWorking)
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Resolve and Install \(request.displayName)")
                .font(.title.bold())
            Text(
                "Skills Manager will \(request.detail)"
            )
            .foregroundStyle(.secondary)
        }
    }

    private var actions: some View {
        HStack {
            Button("Cancel") {
                cancelAndDismiss()
            }
            .keyboardShortcut(.cancelAction)
            .disabled(model.isExecuting || model.isFinalizing)

            Spacer()

            Button("Resolve and Review…") {
                prepareInstall()
            }
            .buttonStyle(.borderedProminent)
            .disabled(!canPrepare)
            .keyboardShortcut(.defaultAction)
        }
    }

    private var canPrepare: Bool {
        model.isAvailable
            && !isWorking
            && (distributionMode == .global || !selectedAgents.isEmpty)
    }

    private var isWorking: Bool {
        isResolving || model.isWorking
    }

    private var previewBinding: Binding<ManagedLocalImportPreview?> {
        Binding(
            get: { model.preview },
            set: { if $0 == nil { model.cancelPreview() } }
        )
    }

    private func prepareInstall() {
        activeTask?.cancel()
        activeTask = Task {
            await cleanupCandidate()
            model.reset()
            errorMessage = nil
            isResolving = true
            defer { isResolving = false }
            do {
                let resolved = try await request.resolve()
                let downloaded = try await request.download(resolved.source)
                try Task.checkCancellation()
                let archive = try await Task.detached {
                    try persistDownloadedSkillArchive(data: downloaded.data)
                }.value
                let payload: SkillImportWorker.ImportCandidatePayload
                do {
                    payload = try await importWorker.validateZip(
                        archive.url,
                        repositorySubpath: resolved.source.subpath,
                        expectedBlobs: try resolved.source.blobs.map {
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
                    if let temporaryRoot = payload.temporaryRoot {
                        await importWorker.cleanupTemporaryRoot(temporaryRoot)
                    }
                    throw error
                }
                guard !Task.isCancelled else {
                    if let temporaryRoot = payload.temporaryRoot {
                        await importWorker.cleanupTemporaryRoot(temporaryRoot)
                    }
                    return
                }
                candidate = payload
                await model.prepareSourceBacked(
                    candidate: payload,
                    sourceInput: resolved.sourceInput,
                    scope: distributionMode == .global ? .global : .agents(selectedAgents)
                )
                if model.problem != nil {
                    await cleanupCandidate()
                }
            } catch {
                if Task.isCancelled { return }
                model.reset()
                errorMessage = error.localizedDescription
            }
        }
    }

    private func confirmInstall() {
        activeTask?.cancel()
        activeTask = Task {
            await model.confirm {
                await cleanupCandidate()
                await store.loadSkills()
                await discoveryModel.refresh()
                await customRepositoryModel.refreshAll()
            }
            if let problem = model.problem {
                errorMessage = problem.localizedDescription
            }
        }
    }

    private func problemLabel(_ message: String) -> some View {
        Label(message, systemImage: "exclamationmark.triangle")
            .foregroundStyle(.orange)
            .accessibilityElement(children: .combine)
    }

    @ViewBuilder
    private func resultView(_ result: ManagedLocalImportResult) -> some View {
        let presentation = managedInstallResultPresentation(result)
        ContentUnavailableView(
            presentation.title,
            systemImage: presentation.systemImage,
            description: Text(presentation.message)
        )
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        HStack {
            Spacer()
            Button("Close") { dismiss() }
                .keyboardShortcut(.defaultAction)
        }
    }

    private func cancelAndDismiss() {
        cancelAndCleanup()
        dismiss()
    }

    private func cancelAndCleanup() {
        let task = activeTask
        activeTask = nil
        let temporaryRoot = candidate?.temporaryRoot
        candidate = nil
        Task {
            await importWorker.cleanupTemporaryRoot(
                temporaryRoot,
                afterCancelling: task
            )
        }
    }

    private func cleanupCandidate() async {
        let temporaryRoot = candidate?.temporaryRoot
        candidate = nil
        if let temporaryRoot {
            await importWorker.cleanupTemporaryRoot(temporaryRoot)
        }
    }
}

nonisolated func persistDownloadedSkillArchive(
    data: Data
) throws -> DownloadedSkillArchive {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent(
        "skillsmanager-github-\(UUID().uuidString.lowercased()).zip"
    )
    do {
        try data.write(to: url, options: [.atomic])
        return try DownloadedSkillArchive.takeOwnership(of: url)
    } catch {
        try? FileManager.default.removeItem(at: url)
        throw error
    }
}
