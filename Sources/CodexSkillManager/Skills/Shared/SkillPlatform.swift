import SwiftUI

enum SkillPlatform: String, CaseIterable, Identifiable, Hashable, Sendable, Codable {
    case codex = "Codex"
    case claude = "Claude Code"
    case opencode = "OpenCode"
    case copilot = "GitHub Copilot"

    var id: String { rawValue }

    var storageKey: String {
        switch self {
        case .codex:
            return "codex"
        case .claude:
            return "claude"
        case .opencode:
            return "opencode"
        case .copilot:
            return "copilot"
        }
    }

    func storageKey(forRelativePath relativePath: String) -> String {
        guard relativePath != self.relativePath else { return storageKey }
        let sanitized = relativePath
            .replacingOccurrences(of: ".", with: "")
            .replacingOccurrences(of: "/", with: "-")
            .trimmingCharacters(in: CharacterSet(charactersIn: "-"))
        return "\(storageKey)-\(sanitized)"
    }

    /// Primary relative path from a base directory to the skills folder.
    var relativePath: String {
        relativePaths.first ?? ".codex/skills"
    }

    /// Relative paths from a base directory to the skills folder(s).
    var relativePaths: [String] {
        switch self {
        case .codex:
            return [".codex/skills", ".codex/skills/public"]
        case .claude:
            return [".claude/skills"]
        case .opencode:
            return [".config/opencode/skill"]
        case .copilot:
            return [".copilot/skills"]
        }
    }

    var rootURL: URL {
        let home = FileManager.default.homeDirectoryForCurrentUser
        return home.appendingPathComponent(relativePath)
    }

    var rootURLs: [URL] {
        let home = FileManager.default.homeDirectoryForCurrentUser
        return relativePaths.map { home.appendingPathComponent($0) }
    }

    /// Returns the skills URL for this platform within a given base directory
    func skillsURL(in baseURL: URL) -> URL {
        baseURL.appendingPathComponent(relativePath)
    }

    /// Returns all skills URLs for this platform within a given base directory
    func skillsURLs(in baseURL: URL) -> [URL] {
        relativePaths.map { baseURL.appendingPathComponent($0) }
    }

    var description: String {
        "Install in \(rootURL.path)"
    }

    var badgeTint: Color {
        switch self {
        case .codex:
            return Color(red: 164.0 / 255.0, green: 97.0 / 255.0, blue: 212.0 / 255.0)
        case .claude:
            return Color(red: 217.0 / 255.0, green: 119.0 / 255.0, blue: 87.0 / 255.0)
        case .opencode:
            return Color(red: 76.0 / 255.0, green: 144.0 / 255.0, blue: 226.0 / 255.0)
        case .copilot:
            return Color(red: 77.0 / 255.0, green: 212.0 / 255.0, blue: 212.0 / 255.0)
        }
    }
}
