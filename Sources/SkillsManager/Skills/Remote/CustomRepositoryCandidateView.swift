import SwiftUI

struct CustomRepositoryCandidateRow: View {
    let candidate: CustomRepositoryCandidate

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(candidate.displayName).font(.headline)
            Text(candidate.repository.displayName)
                .font(.subheadline)
                .foregroundStyle(.secondary)
            Text(candidate.snapshot.subpath.value.isEmpty ? "/" : candidate.snapshot.subpath.value)
                .font(.caption.monospaced())
                .foregroundStyle(.secondary)
                .lineLimit(1)
            HStack(spacing: 6) {
                TagView(text: "Available", systemImage: "arrow.down.circle")
                TagView(text: "Repository", systemImage: "shippingbox")
            }
        }
        .padding(.vertical, 6)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(candidate.accessibilitySummary)
        .accessibilityValue("Available, Repository, 0 Agents")
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
