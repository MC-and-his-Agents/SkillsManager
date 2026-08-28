import SwiftUI

extension CustomRepositoryCandidate {
    var resultSubjectID: String {
        "\(id.repositoryID)-\(id.subpath.value)"
    }
}

struct CustomRepositoryCandidateRow: View {
    let candidate: CustomRepositoryCandidate

    var body: some View {
        SkillListRow(data: SkillListRowData(
            id: candidate.resultSubjectID,
            title: candidate.displayName,
            detail: candidate.repository.displayName,
            statusIcon: "arrow.down.circle",
            statusTint: .accentColor,
            sources: [SkillListSourceLabel(
                text: "Repository",
                systemImage: "shippingbox",
                knownSource: .repository
            )],
            agentCount: nil,
            accessibilityLabel: String(
                localized: LocalizedStringResource(
            "\(candidate.displayName), Available, Repository, \(candidate.repository.displayName), \(candidate.snapshot.subpath.value.isEmpty ? "root" : candidate.snapshot.subpath.value)",
            bundle: SkillsManagerLocalizationResources.bundle
        )),
            accessibilityValue: String(localized: "Available, Repository", bundle: SkillsManagerLocalizationResources.bundle)
        ))
        .help(candidate.snapshot.subpath.value.isEmpty ? "/" : candidate.snapshot.subpath.value)
    }
}

struct CustomRepositoryCandidateDetailView: View {
    let candidate: CustomRepositoryCandidate

    @State private var showingInstall = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                SkillResultCenterBanner(subject: .repository(candidate.id))
                SkillDetailPageHeader(
                    title: candidate.displayName,
                    tags: {
                        TagView(localized: "Available", systemImage: "arrow.down.circle")
                        TagView(localized: "Repository", systemImage: "shippingbox")
                    },
                    actions: {
                        Button {
                            showingInstall = true
                        } label: {
                            Text("Review and Install…", bundle: SkillsManagerLocalizationResources.bundle)
                        }
                        .buttonStyle(.borderedProminent)
                        .disabled(candidate.distributionSlug == nil)
                        .accessibilityIdentifier("repository.review-install")
                        .accessibilityHint(Text(
                            "Verifies the immutable GitHub source before installation",
                            bundle: SkillsManagerLocalizationResources.bundle
                        ))
                    }
                )
                GroupBox {
                    Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 6) {
                        detailRow("Repository", candidate.repository.repositoryURL.value)
                        detailRow(
                            "Subpath",
                            candidate.snapshot.subpath.value.isEmpty ? "/" : candidate.snapshot.subpath.value
                        )
                        detailRow("Revision", candidate.snapshot.commitSHA)
                        if let slug = candidate.distributionSlug {
                            detailRow("Target slug", slug.value)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                } label: {
                    Text("Verified discovery", bundle: SkillsManagerLocalizationResources.bundle)
                }
                if candidate.installProblem != nil {
                    Label(String(localized: "This Skill cannot form a valid distribution slug.", bundle: SkillsManagerLocalizationResources.bundle), systemImage: "exclamationmark.triangle")
                        .foregroundStyle(.orange)
                        .accessibilityElement(children: .combine)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding()
        }
        .navigationTitle(candidate.displayName)
        .navigationSubtitle(String(localized: "Repository", bundle: SkillsManagerLocalizationResources.bundle))
        .sheet(isPresented: $showingInstall) {
            ManagedCustomRepositoryInstallView(candidate: candidate)
        }
    }

    private func detailRow(_ title: String, _ value: String) -> some View {
        GridRow {
            localizedDetailTitle(title).foregroundStyle(.secondary)
            Text(verbatim: value)
                .font(.callout.monospaced())
                .textSelection(.enabled)
        }
        .accessibilityElement(children: .combine)
    }

    private func localizedDetailTitle(_ title: String) -> Text {
        switch title {
        case "Repository": Text("Repository", bundle: SkillsManagerLocalizationResources.bundle)
        case "Subpath": Text("Subpath", bundle: SkillsManagerLocalizationResources.bundle)
        case "Revision": Text("Revision", bundle: SkillsManagerLocalizationResources.bundle)
        case "Target slug": Text("Target slug", bundle: SkillsManagerLocalizationResources.bundle)
        default: Text(verbatim: title)
        }
    }
}
