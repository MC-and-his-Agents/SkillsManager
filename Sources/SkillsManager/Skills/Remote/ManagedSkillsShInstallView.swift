import SwiftUI

struct ManagedSkillsShInstallView: View {
    let item: SkillsShSearchItem
    @Environment(\.skillsManagerGitHubClient) private var githubClient

    var body: some View {
        ManagedGitHubInstallView(
            request: .skillsSh(item, client: githubClient),
            subject: .skillsSh(item.resultID)
        )
    }
}

struct ManagedCustomRepositoryInstallView: View {
    @Environment(SkillStore.self) private var store
    @Environment(\.skillsManagerGitHubClient) private var githubClient

    let candidate: CustomRepositoryCandidate

    var body: some View {
        if let writer = store.persistence, let slug = candidate.distributionSlug {
            ManagedGitHubInstallView(
                request: .customRepository(
                    candidate,
                    writer: writer,
                    slug: slug,
                    client: githubClient
                ),
                subject: .repository(candidate.id)
            )
        } else {
            ContentUnavailableView(
                String(localized: "Installation unavailable", bundle: .module),
                systemImage: "exclamationmark.triangle",
                description: Text(
                    candidate.installProblem
                        ?? String(localized: "The managed library is unavailable.", bundle: .module)
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

@MainActor struct ManagedGitHubInstallRequest: Sendable {
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
            detail: String(
                localized: LocalizedStringResource(
            "verify \(item.source), find one matching SKILL.md, and pin the install to an immutable GitHub commit.",
            bundle: .module
        )),
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
            detail: String(
                localized: LocalizedStringResource(
            "verify \(candidate.repository.displayName) at the discovered commit and exact Skill subpath.",
            bundle: .module
        )),
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
    @Environment(SkillResultCenter.self) private var resultCenter

    let request: ManagedGitHubInstallRequest
    let subject: SkillResultCenter.Subject

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
                    ProgressView(String(localized: "Resolving and validating GitHub source…", bundle: .module))
                }
                if let problem = model.problem {
                    problemLabel(localizedManagedLocalImportProblem(problem))
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
            Text(
                String(
                    localized: LocalizedStringResource(
            "Resolve and Install \(request.displayName)",
            bundle: .module
        ))
            )
                .font(.title.bold())
            Text(
                verbatim: String(
                    localized: LocalizedStringResource(
            "Skills Manager will \(request.detail)",
            bundle: .module
        ))
            )
                .foregroundStyle(.secondary)
        }
    }

    private var actions: some View {
        HStack {
            Button {
                cancelAndDismiss()
            } label: {
                Text("Cancel", bundle: .module)
            }
            .keyboardShortcut(.cancelAction)
            .disabled(model.isExecuting || model.isFinalizing)

            Spacer()

            Button {
                prepareInstall()
            } label: {
                Text("Resolve and Review…", bundle: .module)
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
                if let problem = model.problem {
                    resultCenter.publishInstallFailure(
                        localizedManagedLocalImportProblem(problem),
                        subject: subject
                    )
                    await cleanupCandidate()
                }
            } catch {
                if Task.isCancelled { return }
                model.reset()
                let message = localizedManagedInstallError(error)
                errorMessage = message
                resultCenter.publishInstallFailure(message, subject: subject)
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
            if let result = model.result {
                resultCenter.publishInstallResult(result, subject: subject)
            } else if let problem = model.problem {
                let message = localizedManagedLocalImportProblem(problem)
                errorMessage = message
                resultCenter.publishInstallFailure(message, subject: subject)
            }
        }
    }

    private func problemLabel(_ message: String) -> some View {
        Label {
            Text(verbatim: message)
        } icon: {
            Image(systemName: "exclamationmark.triangle")
        }
            .foregroundStyle(.orange)
            .accessibilityElement(children: .combine)
    }

    @ViewBuilder
    private func resultView(_ result: ManagedLocalImportResult) -> some View {
        let presentation = managedInstallResultPresentation(result)
        ContentUnavailableView(
            localizedManagedInstallResultTitle(result.status),
            systemImage: presentation.systemImage,
            description: Text(verbatim: localizedManagedInstallResultMessage(result))
        )
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        HStack {
            Spacer()
            Button {
                dismiss()
            } label: {
                Text("Close", bundle: .module)
            }
                .keyboardShortcut(.defaultAction)
                .accessibilityIdentifier("install.result.close")
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
