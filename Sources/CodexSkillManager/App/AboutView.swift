import SwiftUI

struct AboutView: View {
    private let appName = Bundle.main.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String
        ?? Bundle.main.object(forInfoDictionaryKey: "CFBundleName") as? String
        ?? "Skills Manager"
    private let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String
        ?? "1.0"
    private let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String
        ?? "1"

    var body: some View {
        VStack(spacing: 20) {
            HStack(alignment: .top, spacing: 16) {
                Image(nsImage: NSApp.applicationIconImage)
                    .resizable()
                    .frame(width: 64, height: 64)
                    .cornerRadius(12)

                VStack(alignment: .leading, spacing: 6) {
                    Text(appName)
                        .font(.system(size: 24, weight: .semibold, design: .rounded))
                    Text("Version \(version) (\(build))")
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(.secondary)
                    Text("Built for Codex and your other agents to manage and inspect skills on your Mac.")
                        .font(.system(size: 13))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 0)
            }

            Divider()

            HStack(spacing: 12) {
                Link("GitHub", destination: URL(string: "https://github.com/MC-and-his-Agents/SkillsManager")!)
                Link("Releases", destination: URL(string: "https://github.com/MC-and-his-Agents/SkillsManager/releases")!)
                Link("Original Project", destination: URL(string: "https://github.com/Dimillian/CodexSkillManager")!)
            }
            .font(.system(size: 12, weight: .semibold))

            Text("Maintained by MC and his Agents. Originally created by @Dimillian.")
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(.secondary)
        }
        .padding(24)
        .frame(width: 420)
        .background(
            LinearGradient(
                colors: [
                    Color(NSColor.windowBackgroundColor),
                    Color(NSColor.windowBackgroundColor).opacity(0.94),
                ],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
        )
    }
}
