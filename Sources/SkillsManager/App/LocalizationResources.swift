import Foundation

private final class SkillsManagerLocalizationBundleToken {}

/// The one native resource entry point shared by UI and contract tests.
enum SkillsManagerLocalizationResources {
    static nonisolated var bundle: Bundle {
        let name = "SkillsManager_SkillsManager.bundle"
        let codeBundle = Bundle(for: SkillsManagerLocalizationBundleToken.self)
        let roots = [
            Bundle.main.resourceURL,
            Bundle.main.bundleURL,
            Bundle.main.bundleURL.deletingLastPathComponent(),
            codeBundle.resourceURL,
            codeBundle.bundleURL,
            codeBundle.bundleURL.deletingLastPathComponent(),
        ].compactMap { $0 }

        for root in roots {
            if let bundle = Bundle(url: root.appendingPathComponent(name)) {
                return bundle
            }
        }
        fatalError("could not load \(name)")
    }
}
