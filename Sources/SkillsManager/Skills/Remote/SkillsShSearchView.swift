import SwiftUI

struct SkillsShSearchDetailView: View {
    @Environment(SkillsShSearchStore.self) private var store
    @State private var installItem: SkillsShSearchItem?

    var body: some View {
        Group {
            if let item = store.selectedItem {
                ScrollView {
                    VStack(alignment: .leading, spacing: 16) {
                        Text(item.name)
                            .font(.largeTitle.bold())

                        HStack(spacing: 6) {
                            TagView(text: item.source)
                            TagView(text: "\(item.installs.formatted()) installs")
                        }

                        Label {
                            Text(
                                "Before installation, Skills Manager verifies a unique "
                                    + "repository subpath and immutable GitHub revision."
                            )
                        } icon: {
                            Image(systemName: "lock.shield")
                        }
                        .foregroundStyle(.secondary)
                        .accessibilityElement(children: .combine)

                        Button("Resolve and Install…") {
                            installItem = item
                        }
                        .buttonStyle(.borderedProminent)
                        .accessibilityHint(
                            "Verifies the public GitHub source before showing an install preview"
                        )
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding()
                }
                .navigationTitle(item.name)
                .navigationSubtitle("skills.sh")
            } else {
                ContentUnavailableView(
                    "Select a skill",
                    systemImage: "magnifyingglass",
                    description: Text("Choose a skills.sh result.")
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
        VStack(alignment: .leading, spacing: 6) {
            Text(item.name)
                .font(.headline)
            Text(item.source)
                .font(.subheadline)
                .foregroundStyle(.secondary)
            HStack(spacing: 6) {
                TagView(text: "skills.sh")
                TagView(text: "\(item.installs.formatted()) installs")
            }
        }
        .padding(.vertical, 6)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(
            "\(item.name), \(item.installs.formatted()) installs, source \(item.source)"
        )
    }
}

extension SkillsShSearchItem {
    var resultID: SkillsShSearchResultID {
        SkillsShSearchResultID(self)
    }
}
