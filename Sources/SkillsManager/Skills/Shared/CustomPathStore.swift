import Foundation
import Observation

enum CustomPathError: LocalizedError {
    case directoryNotFound
    case duplicatePath

    var errorDescription: String? {
        switch self {
        case .directoryNotFound:
            return "The selected directory does not exist."
        case .duplicatePath:
            return "This path has already been added."
        }
    }
}

@MainActor
@Observable final class CustomPathStore {
    private(set) var customPaths: [CustomSkillPath] = []

    init() {
        loadPaths()
    }

    func addPath(_ url: URL) throws {
        let fileManager = FileManager.default
        guard fileManager.fileExists(atPath: url.path) else {
            throw CustomPathError.directoryNotFound
        }

        guard !customPaths.contains(where: { $0.url == url }) else {
            throw CustomPathError.duplicatePath
        }

        let newPath = CustomSkillPath(url: url)
        customPaths.append(newPath)
        savePaths()
    }

    func removePath(_ path: CustomSkillPath) {
        customPaths.removeAll { $0.id == path.id }
        savePaths()
    }

    func removePath(at url: URL) {
        customPaths.removeAll { $0.url == url }
        savePaths()
    }

    // MARK: - Persistence

    private func configDirectory() -> URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)
            .first ?? FileManager.default.homeDirectoryForCurrentUser
        return base.appendingPathComponent("SkillsManager")
    }

    private func configURL() -> URL {
        configDirectory().appendingPathComponent("custom-paths.json")
    }

    private func loadPaths() {
        let url = configURL()
        guard let data = try? Data(contentsOf: url) else {
            customPaths = []
            return
        }
        customPaths = (try? JSONDecoder().decode([CustomSkillPath].self, from: data)) ?? []
    }

    private func savePaths() {
        let dir = configDirectory()
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        if let data = try? JSONEncoder().encode(customPaths) {
            try? data.write(to: configURL(), options: [.atomic])
        }
    }
}
