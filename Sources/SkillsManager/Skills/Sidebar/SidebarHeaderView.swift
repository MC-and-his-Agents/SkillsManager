import SwiftUI

struct SidebarHeaderView: View {
    let skillCount: Int
    @Binding var source: SkillSource

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Picker("Skill source", selection: $source) {
                ForEach(SkillSource.allCases) { source in
                    Text(source.rawValue).tag(source)
                }
            }
            .pickerStyle(.menu)
            .accessibilityLabel("Skill source")
            .accessibilityValue(source.rawValue)

            VStack(alignment: .leading, spacing: 2) {
                Text(source.sidebarTitle)
                    .font(.title2.bold())
                    .foregroundStyle(.primary)
                Text("\(skillCount) skills")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 6)
        .textCase(nil)
    }
}
