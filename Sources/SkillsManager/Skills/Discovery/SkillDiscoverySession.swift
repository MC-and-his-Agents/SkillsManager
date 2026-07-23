import Foundation

actor SkillDiscoverySession {
    private let writer: JournaledSSOTWriter
    private let scanner = SkillDiscoveryScanner()
    private let importer: ManagedSkillImportService

    init(writer: JournaledSSOTWriter) {
        self.writer = writer
        importer = ManagedSkillImportService(writer: writer)
    }

    func scan(roots: [SkillDiscoveryRoot]) async throws -> SkillDiscoveryResult {
        try Task.checkCancellation()
        let catalog = try await writer.discoveryCatalog()
        try Task.checkCancellation()
        return try scanner.scan(
            roots: roots,
            catalog: catalog,
            checkpoint: { try Task.checkCancellation() }
        )
    }

    func preview(
        observation: SkillDiscoveryObservation,
        action: ManagedSkillImportAction
    ) async throws -> ManagedSkillImportPreview {
        try await importer.preview(observation: observation, action: action)
    }

    func execute(_ token: ManagedSkillImportToken) async throws -> ManagedSkillImportResult {
        try await importer.execute(token)
    }
}
