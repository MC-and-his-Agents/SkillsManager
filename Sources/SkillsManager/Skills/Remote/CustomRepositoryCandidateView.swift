import SwiftUI

struct CustomRepositoryCandidateRow: View {
    let candidate: CustomRepositoryCandidate

    var body: some View {
        SkillListRow(data: SkillListRowData(
            id: "\(candidate.id.repositoryID)-\(candidate.id.subpath.value)",
            title: candidate.displayName,
            detail: candidate.repository.displayName,
            statusIcon: "arrow.down.circle",
            statusTint: .accentColor,
            sources: [SkillListSourceLabel(
                text: "Repository",
                systemImage: "shippingbox",
                knownSource: .repository
            )],
            agentCount: 0,
            accessibilityLabel: String(
                localized: LocalizedStringResource( "%@, Available, Repository, %@, %@",
                defaultValue: "\(candidate.displayName), Available, Repository, \(candidate.repository.displayName), \(candidate.snapshot.subpath.value.isEmpty ? "root" : candidate.snapshot.subpath.value)",
                bundle: .module
            )),
            accessibilityValue: String(localized: "Available, Repository, 0 Agents", bundle: .module)
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
                Text(candidate.displayName).font(.largeTitle.bold())
                HStack(spacing: 6) {
                    TagView(localized: "Available", systemImage: "arrow.down.circle")
                    TagView(localized: "Repository", systemImage: "shippingbox")
                }
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
                    Text("Verified discovery", bundle: .module)
                }
                if candidate.installProblem != nil {
                    Label(String(localized: "This Skill cannot form a valid distribution slug.", bundle: .module), systemImage: "exclamationmark.triangle")
                        .foregroundStyle(.orange)
                        .accessibilityElement(children: .combine)
                }
                Button {
                    showingInstall = true
                } label: {
                    Text("Review and Install…", bundle: .module)
                }
                    .buttonStyle(.borderedProminent)
                    .disabled(candidate.distributionSlug == nil)
                    .accessibilityIdentifier("repository.review-install")
                    .accessibilityHint(Text(
                        "Verifies the immutable GitHub source before installation",
                        bundle: .module
                    ))
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding()
        }
        .navigationTitle(candidate.displayName)
        .navigationSubtitle(String(localized: "Repository", bundle: .module))
        .sheet(isPresented: $showingInstall) {
            ManagedCustomRepositoryInstallView(candidate: candidate)
        }
    }

    private func detailRow(_ title: String, _ value: String) -> some View {
        GridRow {
            Text(title).foregroundStyle(.secondary)
            Text(value)
                .font(.callout.monospaced())
                .textSelection(.enabled)
        }
        .accessibilityElement(children: .combine)
    }
}
