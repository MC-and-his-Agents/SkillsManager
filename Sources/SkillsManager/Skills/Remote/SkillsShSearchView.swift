import SwiftUI

struct SkillsShSearchDetailView: View {
    @Environment(SkillsShSearchStore.self) private var store
    @State private var installItem: SkillsShSearchItem?

    var body: some View {
        Group {
            if let item = store.selectedItem {
                ScrollView {
                    VStack(alignment: .leading, spacing: 16) {
                        SkillResultCenterBanner(subject: .skillsSh(item.resultID))
                        Text(verbatim: item.name)
                            .font(.largeTitle.bold())

                        HStack(spacing: 6) {
                            TagView(text: item.source)
                            TagView(localized: LocalizedStringResource(
            "\(item.installs) installs",
            bundle: SkillsManagerLocalizationResources.bundle
        ))
                        }

                        Label {
                            Text(
                                "Before installation, Skills Manager verifies a unique repository subpath and immutable GitHub revision.",
                                bundle: SkillsManagerLocalizationResources.bundle
                            )
                        } icon: {
                            Image(systemName: "lock.shield")
                        }
                        .foregroundStyle(.secondary)
                        .accessibilityElement(children: .combine)

                        Button {
                            installItem = item
                        } label: {
                            Text("Resolve and Install…", bundle: SkillsManagerLocalizationResources.bundle)
                        }
                        .buttonStyle(.borderedProminent)
                        .accessibilityHint(Text(
                            "Verifies the public GitHub source before showing an install preview",
                            bundle: SkillsManagerLocalizationResources.bundle
                        ))
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding()
                }
                .navigationTitle(item.name)
                .navigationSubtitle(String(localized: "skills.sh", bundle: SkillsManagerLocalizationResources.bundle))
            } else {
                ContentUnavailableView(
                    String(localized: "Select a Skill", bundle: SkillsManagerLocalizationResources.bundle),
                    systemImage: "magnifyingglass",
                    description: Text("Choose a skills.sh result.", bundle: SkillsManagerLocalizationResources.bundle)
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
            agentCount: nil,
            accessibilityLabel: String(
                localized: LocalizedStringResource(
            "\(item.name), Available, skills.sh, \(item.installs) installs, source \(item.source)",
            bundle: SkillsManagerLocalizationResources.bundle
        )),
            accessibilityValue: String(localized: "Available, skills.sh", bundle: SkillsManagerLocalizationResources.bundle)
        ))
    }
}

extension SkillsShSearchItem {
    var resultID: SkillsShSearchResultID {
        SkillsShSearchResultID(self)
    }
}
