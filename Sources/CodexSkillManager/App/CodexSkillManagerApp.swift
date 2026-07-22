import Security
import SwiftUI

#if canImport(Sparkle) && ENABLE_SPARKLE
import Sparkle
#endif

@main
struct CodexSkillManagerApp: App {
    @Environment(\.openWindow) private var openWindow
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @State private var customPathStore: CustomPathStore
    @State private var store: SkillStore
    @State private var remoteStore = RemoteSkillStore(client: .live())

    init() {
        let pathStore = CustomPathStore()
        _customPathStore = State(initialValue: pathStore)
        _store = State(initialValue: SkillStore(customPathStore: pathStore))
    }

    var body: some Scene {
        WindowGroup("Skills Manager") {
            SkillSplitView()
                .environment(store)
                .environment(remoteStore)
                .environment(customPathStore)
        }
        .commands {
            CommandGroup(replacing: .appInfo) {
                Button("About Skills Manager") {
                    openWindow(id: "about")
                }
            }
            CommandGroup(after: .appInfo) {
                Button("Check for Updates…") {
                    appDelegate.checkForUpdates()
                }
                .keyboardShortcut("u", modifiers: [.command, .option])
            }
        }
        Window("About Skills Manager", id: "about") {
            AboutView()
        }
        .windowResizability(.contentSize)
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
#if canImport(Sparkle) && ENABLE_SPARKLE
    private var updaterController: SPUStandardUpdaterController?
#endif

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Ensure the app becomes key when launched from `swift run`.
        NSApplication.shared.setActivationPolicy(.regular)
        NSApplication.shared.activate(ignoringOtherApps: true)

#if canImport(Sparkle) && ENABLE_SPARKLE
        guard shouldEnableSparkle() else { return }
        updaterController = SPUStandardUpdaterController(
            startingUpdater: true,
            updaterDelegate: nil,
            userDriverDelegate: nil
        )
#endif
    }

    func checkForUpdates() {
#if canImport(Sparkle) && ENABLE_SPARKLE
        updaterController?.checkForUpdates(nil)
#endif
    }

#if canImport(Sparkle) && ENABLE_SPARKLE
    private func shouldEnableSparkle() -> Bool {
        let bundleURL = Bundle.main.bundleURL
        guard bundleURL.pathExtension == "app" else { return false }
        guard isDeveloperIDSigned(bundleURL: bundleURL) else { return false }
        let info = Bundle.main.infoDictionary
        let feedURL = info?["SUFeedURL"] as? String
        let publicKey = info?["SUPublicEDKey"] as? String
        return (feedURL?.isEmpty == false) && (publicKey?.isEmpty == false)
    }

    private func isDeveloperIDSigned(bundleURL: URL) -> Bool {
        var staticCode: SecStaticCode?
        guard SecStaticCodeCreateWithPath(bundleURL as CFURL, SecCSFlags(), &staticCode) == errSecSuccess,
              let code = staticCode else { return false }

        var infoCF: CFDictionary?
        guard SecCodeCopySigningInformation(code, SecCSFlags(rawValue: kSecCSSigningInformation), &infoCF) == errSecSuccess,
              let info = infoCF as? [String: Any],
              let certs = info[kSecCodeInfoCertificates as String] as? [SecCertificate],
              let leaf = certs.first else { return false }

        if let summary = SecCertificateCopySubjectSummary(leaf) as String? {
            return summary.hasPrefix("Developer ID Application:")
        }
        return false
    }
#endif
}
