import SwiftUI

struct SidebarHeaderView: View {
    let skillCount: Int
    @Binding var source: SkillSource

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Picker("Skill area", selection: areaBinding) {
                ForEach(SkillArea.allCases) { area in
                    Text(area.rawValue).tag(area)
                }
            }
            .labelsHidden()
            .pickerStyle(.segmented)
            .accessibilityLabel("Skill area")
            .accessibilityValue(source.area.rawValue)

            Picker(source.area.sourcePickerLabel, selection: $source) {
                ForEach(source.area.sources) { option in
                    Text(option.navigationLabel).tag(option)
                }
            }
            .labelsHidden()
            .pickerStyle(.segmented)
            .accessibilityLabel(source.area.sourcePickerLabel)
            .accessibilityValue(source.navigationLabel)

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

    private var areaBinding: Binding<SkillArea> {
        Binding(
            get: { source.area },
            set: { source = $0.defaultSource }
        )
    }
}
