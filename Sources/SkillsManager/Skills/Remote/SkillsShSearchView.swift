import SwiftUI

struct SkillsShSearchDetailView: View {
    @Environment(SkillsShSearchStore.self) private var store
    @State private var installItem: SkillsShSearchItem?

    var body: some View {
        Group {
            if let item = store.selectedItem {
                ScrollView {
                    VStack(alignment: .leading, spacing: 16) {
                        SkillResultCenterBanner(skillID: item.resultID.id)
                        Text(verbatim: item.name)
                            .font(.largeTitle.bold())

                        HStack(spacing: 6) {
                            TagView(text: item.source)
                            TagView(localized: LocalizedStringResource(
            "\(item.installs) installs",
            bundle: .module
        ))
                        }

                        Label {
                            Text(
                                "Before installation, Skills Manager verifies a unique repository subpath and immutable GitHub revision.",
                                bundle: .module
                            )
                        } icon: {
                            Image(systemName: "lock.shield")
                        }
                        .foregroundStyle(.secondary)
                        .accessibilityElement(children: .combine)

                        Button {
                            installItem = item
                        } label: {
                            Text("Resolve and Install…", bundle: .module)
                        }
                        .buttonStyle(.borderedProminent)
                        .accessibilityHint(Text(
                            "Verifies the public GitHub source before showing an install preview",
                            bundle: .module
                        ))
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding()
                }
                .navigationTitle(item.name)
                .navigationSubtitle(String(localized: "skills.sh", bundle: .module))
            } else {
                ContentUnavailableView(
                    String(localized: "Select a skill", bundle: .module),
                    systemImage: "magnifyingglass",
                    description: Text("Choose a skills.sh result.", bundle: .module)
                )
            }
        }
        .sheet(
            isPresented: Binding(
                get: { installItem != nil },
                set: { if !$0 { installItem = nil } }
            )
        ) {
            if let installItem {
                ManagedSkillsShInstallView(item: installItem)
            }
        }
    }
}

struct SkillsShSearchRow: View {
    let item: SkillsShSearchItem

    var body: some View {
        SkillListRow(data: SkillListRowData(
            id: item.resultID.id,
            title: item.name,
            detail: item.source,
            statusIcon: "arrow.down.circle",
            statusTint: .accentColor,
                sources: [SkillListSourceLabel(
                    text: "skills.sh",
                    systemImage: "magnifyingglass",
                    knownSource: .skillsSh
                )],
            agentCount: 0,
            accessibilityLabel: String(
                localized: LocalizedStringResource(
            "\(item.name), Available, skills.sh, \(item.installs) installs, source \(item.source)",
            bundle: .module
        )),
            accessibilityValue: String(localized: "Available, skills.sh, 0 Agents", bundle: .module)
        ))
    }
}

extension SkillsShSearchItem {
    var resultID: SkillsShSearchResultID {
        SkillsShSearchResultID(self)
    }
}
