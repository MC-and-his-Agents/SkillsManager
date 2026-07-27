import MarkdownUI
import SwiftUI
import UniformTypeIdentifiers

private struct ImportCandidate {
    let displayName: String
    let payload: SkillImportWorker.ImportCandidatePayload
}

struct ImportSkillView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(SkillStore.self) private var store
    @Environment(SkillDiscoveryViewModel.self) private var discoveryModel
    @Environment(LibraryRuntimeState.self) private var libraryRuntime
    @State private var model = ManagedLocalImportViewModel()
    @State private var showingPicker = false
    @State private var candidate: ImportCandidate?
    @State private var status: Status = .idle
    @State private var errorMessage = ""
    @State private var distributionMode: ManagedInstallDistributionMode = .global
    @State private var selectedAgents: Set<SkillPlatform> = [.codex]
    @State private var activeTask: Task<Void, Never>?
    @State private var operationToken = UUID()
    private let importWorker = SkillImportWorker()

    private enum Status {
        case idle
        case validating
        case valid
        case invalid
        case preparing
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            header
            content
            Spacer()
            actions
        }
        .padding(20)
        .frame(minWidth: 720, minHeight: 520)
        .fileImporter(
            isPresented: $showingPicker,
            allowedContentTypes: [.folder, .zip],
            allowsMultipleSelection: false
        ) { handlePick($0) }
        .sheet(item: previewBinding) { preview in
            ManagedLocalImportPreviewView(
                preview: preview,
                onConfirm: confirmImport
            )
            .environment(model)
        }
        .task {
            model.activate(writer: store.persistence)
        }
        .onChange(of: libraryRuntime.readiness) { _, _ in
            if !model.isWorking {
                model.activate(writer: store.persistence)
            }
        }
        .onDisappear {
            cancelAndCleanup()
        }
        .interactiveDismissDisabled(model.isWorking)
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Import Skill")
                .font(.title.bold())
            Text("Choose a Skill folder or zip, then add it to the managed library.")
                .foregroundStyle(.secondary)
        }
    }

    @ViewBuilder
    private var content: some View {
        if model.result != nil {
            resultState
        } else {
            switch status {
            case .idle:
                emptyState
            case .validating:
                ProgressView("Validating…")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            case .valid:
                candidatePreview
            case .invalid:
                invalidState
            case .preparing:
                ProgressView("Preparing import preview…")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
    }

    private var emptyState: some View {
        ContentUnavailableView(
            "Pick a folder or zip",
            systemImage: "tray.and.arrow.down",
            description: Text("We’ll verify it contains a SKILL.md and show a preview.")
        )
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var invalidState: some View {
        ContentUnavailableView(
            "Unable to import",
            systemImage: "xmark.octagon",
            description: Text(errorMessage)
        )
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var resultState: some View {
        let presentation = resultPresentation
        return VStack {
            ContentUnavailableView(
                presentation.title,
                systemImage: presentation.systemImage,
                description: Text(presentation.message)
            )
            if model.isFinalizing {
                ProgressView("Refreshing library…")
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var resultPresentation: (title: String, systemImage: String, message: String) {
        guard let result = model.result else {
            return ("Import status unavailable", "exclamationmark.triangle", "Refresh the library.")
        }
        switch result.status {
        case .distributed:
            return (
                "Imported and enabled",
                "checkmark.seal",
                "\(result.displayName) is managed and available to the selected Agents."
            )
        case .noDistributionChanges:
            return (
                "Imported",
                "checkmark.seal",
                "\(result.displayName) is managed; no distribution changes were needed."
            )
        case .managedUndistributed:
            return (
                "Imported but not enabled",
                "exclamationmark.triangle",
                "\(result.displayName) is safe in the managed library, but distribution was not applied."
            )
        case .managedDistributionIndeterminate:
            return (
                "Distribution needs attention",
                "wrench.and.screwdriver",
                "\(result.displayName) is managed, but its distribution state must be confirmed or repaired."
            )
        case .managementIndeterminate:
            return (
                "Import needs attention",
                "wrench.and.screwdriver",
                "The import state for \(result.displayName) must be confirmed or repaired before retrying."
            )
        case .alreadyManaged:
            return (
                "Already managed",
                "checkmark.circle",
                "\(result.displayName) is already in the managed library."
            )
        case .updateRequired:
            return (
                "Update required",
                "arrow.triangle.2.circlepath",
                "\(result.displayName) differs from the managed version."
            )
        }
    }

    private var candidatePreview: some View {
        guard let candidate else { return AnyView(EmptyView()) }
        return AnyView(
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    VStack(alignment: .leading, spacing: 6) {
                        Text(candidate.displayName)
                            .font(.title2.bold())
                        Text(candidate.payload.rootURL.path)
                            .font(.callout)
                            .foregroundStyle(.secondary)
                    }
                    distributionSelection
                    if let problem = model.problem {
                        Label(problem.localizedDescription, systemImage: "exclamationmark.triangle")
                            .foregroundStyle(.orange)
                    }
                    Markdown(candidate.payload.markdown)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding()
            }
            .background(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .fill(Color.secondary.opacity(0.06))
            )
        )
    }

    private var distributionSelection: some View {
        ManagedInstallScopePicker(
            mode: $distributionMode,
            selectedAgents: $selectedAgents,
            isDisabled: model.isWorking
        )
    }

    @ViewBuilder
    private var actions: some View {
        if model.result != nil {
            HStack {
                Spacer()
                Button("Close") { dismiss() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(model.isWorking)
            }
        } else {
            HStack {
                Button("Cancel") {
                    cancelAndDismiss()
                }
                .keyboardShortcut(.cancelAction)
                .disabled(model.isWorking)

                Spacer()

                Button("Choose…") {
                    showingPicker = true
                }
                .disabled(model.isWorking)

                Button("Review Import…") {
                    prepareImport()
                }
                .buttonStyle(.borderedProminent)
                .disabled(!canPrepareImport)
                .keyboardShortcut(.defaultAction)
            }
        }
    }

    private var canPrepareImport: Bool {
        status == .valid
            && model.result == nil
            && model.isAvailable
            && !model.isWorking
            && (distributionMode == .global || !selectedAgents.isEmpty)
    }

    private var previewBinding: Binding<ManagedLocalImportPreview?> {
        Binding(
            get: { model.preview },
            set: { if $0 == nil { model.cancelPreview() } }
        )
    }

    private func handlePick(_ result: Result<[URL], Error>) {
        switch result {
        case .failure(let error):
            operationToken = UUID()
            status = .invalid
            errorMessage = error.localizedDescription
        case .success(let urls):
            guard let url = urls.first else {
                status = .idle
                return
            }
            let token = UUID()
            activeTask?.cancel()
            operationToken = token
            activeTask = Task { await validate(url: url, token: token) }
        }
    }

    private func validate(url: URL, token: UUID) async {
        guard operationToken == token else { return }
        status = .validating
        errorMessage = ""
        await cleanupCandidate()

        let resolved = url.standardizedFileURL
        let fileValues = try? resolved.resourceValues(forKeys: [.isDirectoryKey])
        guard operationToken == token, !Task.isCancelled else { return }

        do {
            let payload: SkillImportWorker.ImportCandidatePayload
            if fileValues?.isDirectory == true {
                payload = try await importWorker.validateFolder(resolved)
            } else if resolved.pathExtension.lowercased() == "zip" {
                payload = try await importWorker.validateZip(resolved)
            } else {
                throw SkillImportValidationError.contentRejected("Select a folder or .zip file.")
            }
            guard operationToken == token, !Task.isCancelled else {
                if let temporaryRoot = payload.temporaryRoot {
                    await importWorker.cleanupTemporaryRoot(temporaryRoot)
                }
                return
            }
            candidate = ImportCandidate(
                displayName: formatTitle(payload.skillName),
                payload: payload
            )
            model.reset()
            status = .valid
        } catch is CancellationError {
            return
        } catch {
            guard operationToken == token else { return }
            status = .invalid
            errorMessage = error.localizedDescription
        }
    }

    private func prepareImport() {
        guard let candidate else { return }
        let token = operationToken
        status = .preparing
        activeTask?.cancel()
        activeTask = Task {
            await model.prepare(
                candidate: candidate.payload,
                displayName: candidate.displayName,
                scope: distributionMode == .global ? .global : .agents(selectedAgents)
            )
            guard operationToken == token else { return }
            if let problem = model.problem {
                errorMessage = problem.localizedDescription
                status = .valid
            } else {
                status = .valid
            }
        }
    }

    private func confirmImport() {
        let token = operationToken
        activeTask?.cancel()
        activeTask = Task {
            await model.confirm {
                await store.loadSkills()
                await discoveryModel.refresh()
                await cleanupCandidate()
            }
            guard operationToken == token else { return }
            if let problem = model.problem {
                errorMessage = problem.localizedDescription
            }
        }
    }

    private func cancelAndDismiss() {
        let task = activeTask
        activeTask = nil
        operationToken = UUID()
        let temporaryRoot = candidate?.payload.temporaryRoot
        candidate = nil
        Task {
            await importWorker.cleanupTemporaryRoot(
                temporaryRoot,
                afterCancelling: task
            )
            dismiss()
        }
    }

    private func cancelAndCleanup() {
        let task = activeTask
        activeTask = nil
        operationToken = UUID()
        let temporaryRoot = candidate?.payload.temporaryRoot
        candidate = nil
        Task {
            await importWorker.cleanupTemporaryRoot(
                temporaryRoot,
                afterCancelling: task
            )
        }
    }

    private func cleanupCandidate() async {
        let temporaryRoot = candidate?.payload.temporaryRoot
        candidate = nil
        if let temporaryRoot {
            await importWorker.cleanupTemporaryRoot(temporaryRoot)
        }
    }
}
