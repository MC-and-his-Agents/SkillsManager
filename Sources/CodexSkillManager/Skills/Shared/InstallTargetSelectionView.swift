import SwiftUI

struct InstallTargetSelectionView: View {
    let installedTargets: Set<SkillPlatform>
    @Binding var selection: Set<SkillPlatform>

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Install for")
                .font(.headline)

            ForEach(SkillPlatform.allCases) { platform in
                Toggle(isOn: binding(for: platform)) {
                    HStack(spacing: 8) {
                        Text(platform.rawValue)
                        if installedTargets.contains(platform) {
                            TagView(text: "Installed", tint: .green)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    Text(platform.rootURL.path)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .toggleStyle(.checkbox)
    }

    private func binding(for platform: SkillPlatform) -> Binding<Bool> {
        Binding(
            get: { selection.contains(platform) },
            set: { isOn in
                if isOn {
                    selection.insert(platform)
                } else {
                    selection.remove(platform)
                }
            }
        )
    }
}
