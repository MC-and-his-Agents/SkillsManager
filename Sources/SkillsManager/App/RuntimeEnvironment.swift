import Foundation
import SwiftUI

private struct SkillsManagerHomeURLKey: EnvironmentKey {
    static let defaultValue = FileManager.default.homeDirectoryForCurrentUser
}

private struct SkillsManagerGitHubClientKey: EnvironmentKey {
    static let defaultValue = SkillsShGitHubSourceClient.live()
}

extension EnvironmentValues {
    var skillsManagerHomeURL: URL {
        get { self[SkillsManagerHomeURLKey.self] }
        set { self[SkillsManagerHomeURLKey.self] = newValue }
    }

    var skillsManagerGitHubClient: SkillsShGitHubSourceClient {
        get { self[SkillsManagerGitHubClientKey.self] }
        set { self[SkillsManagerGitHubClientKey.self] = newValue }
    }
}
