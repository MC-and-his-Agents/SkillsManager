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
            sources: [SkillListSourceLabel(text: "Repository", systemImage: "shippingbox")],
            agentCount: 0,
            accessibilityLabel: candidate.accessibilitySummary,
            accessibilityValue: "Available, Repository, 0 Agents"
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
                    TagView(text: "Available", systemImage: "arrow.down.circle")
                    TagView(text: "Repository", systemImage: "shippingbox")
                }
                GroupBox("Verified discovery") {
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
                }
                if let problem = candidate.installProblem {
                    Label(problem, systemImage: "exclamationmark.triangle")
                        .foregroundStyle(.orange)
                        .accessibilityElement(children: .combine)
                }
                Button("Review and Install…") { showingInstall = true }
                    .buttonStyle(.borderedProminent)
                    .disabled(candidate.distributionSlug == nil)
                    .accessibilityIdentifier("repository.review-install")
                    .accessibilityHint("Verifies the immutable GitHub source before installation")
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding()
        }
        .navigationTitle(candidate.displayName)
        .navigationSubtitle("Repository")
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
