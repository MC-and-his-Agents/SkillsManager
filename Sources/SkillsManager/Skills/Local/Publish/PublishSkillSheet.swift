import SwiftUI

struct PublishSkillSheet: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(SkillStore.self) private var store

    let skillID: SkillID
    let displayName: String
    let nextVersion: String
    let publishedVersion: String?
    @Binding var bump: PublishBump
    @Binding var changelog: String
    @Binding var tags: String

    @State private var isPublishing = false
    @State private var errorMessage: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            VStack(alignment: .leading, spacing: 6) {
                Text("Publish Skill", bundle: SkillsManagerLocalizationResources.bundle)
                    .font(.title.bold())
                Text(String(
                    localized: LocalizedStringResource(
            "Push changes for \(displayName) to ClawHub.",
            bundle: SkillsManagerLocalizationResources.bundle
        )))
                    .foregroundStyle(.secondary)
            }

            VStack(alignment: .leading, spacing: 8) {
                HStack(alignment: .firstTextBaseline) {
                    Picker(selection: $bump) {
                        ForEach(PublishBump.allCases) { bump in
                            Text(verbatim: bumpText(bump)).tag(bump)
                        }
                    } label: {
                        Text("Version bump", bundle: SkillsManagerLocalizationResources.bundle)
                    }
                    Text(String(
                        localized: LocalizedStringResource(
            "Will publish v\(nextVersion)",
            bundle: SkillsManagerLocalizationResources.bundle
        )))
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }

                VStack(alignment: .leading, spacing: 4) {
                    Text("Changelog", bundle: SkillsManagerLocalizationResources.bundle)
                        .font(.subheadline.weight(.semibold))
                    TextEditor(text: $changelog)
                        .frame(minHeight: 90)
                        .padding(6)
                        .overlay(
                            RoundedRectangle(cornerRadius: 8)
                                .stroke(Color.secondary.opacity(0.3), lineWidth: 1)
                        )
                }

            }

            Spacer()

            HStack {
                Button {
                    dismiss()
                } label: {
                    Text("Cancel", bundle: SkillsManagerLocalizationResources.bundle)
                }
                Spacer()
                Button {
                    Task { await publishSkill() }
                } label: {
                    Text(isPublishing ? "Publishing…" : "Publish", bundle: SkillsManagerLocalizationResources.bundle)
                }
                .buttonStyle(.borderedProminent)
                .disabled(isPublishing || changelog.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding(24)
        .frame(minWidth: 420, minHeight: 360)
        .alert(Text("Publish result", bundle: SkillsManagerLocalizationResources.bundle), isPresented: errorBinding) {
            Button(role: .cancel) {
            } label: {
                Text("OK", bundle: SkillsManagerLocalizationResources.bundle)
            }
        } message: {
            if let errorMessage {
                Text(errorMessage)
            } else {
                Text("Unable to publish this skill.", bundle: SkillsManagerLocalizationResources.bundle)
            }
        }
    }

    private func publishSkill() async {
        isPublishing = true
        errorMessage = nil
        do {
            let tagList = tags
                .split(separator: ",")
                .map { String($0) }
            try await store.publishSkill(
                skillID,
                bump: bump,
                changelog: changelog,
                tags: tagList,
                publishedVersion: publishedVersion
            )
            dismiss()
        } catch {
            errorMessage = if let error = error as? SkillPublishError {
                localizedSkillPublishError(error)
            } else {
                error.localizedDescription
            }
        }
        isPublishing = false
    }

    private var errorBinding: Binding<Bool> {
        Binding(
            get: { errorMessage != nil },
            set: { newValue in
                if !newValue {
                    errorMessage = nil
                }
            }
        )
    }

    private func bumpText(_ bump: PublishBump) -> String {
        switch bump {
        case .patch: String(localized: "Patch", bundle: SkillsManagerLocalizationResources.bundle)
        case .minor: String(localized: "Minor", bundle: SkillsManagerLocalizationResources.bundle)
        case .major: String(localized: "Major", bundle: SkillsManagerLocalizationResources.bundle)
        }
    }
}
