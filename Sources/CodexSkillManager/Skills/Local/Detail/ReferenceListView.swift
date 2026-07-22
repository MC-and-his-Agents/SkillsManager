import SwiftUI

struct ReferenceListView: View {
    @Environment(SkillStore.self) private var store

    let references: [SkillReference]

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(references) { reference in
                VStack(alignment: .leading, spacing: 8) {
                    Button {
                        Task { await toggleReference(reference) }
                    } label: {
                        HStack(spacing: 8) {
                            Image(systemName: "doc.text")
                                .foregroundStyle(.secondary)
                            Text(reference.name)
                                .foregroundStyle(.primary)
                            Spacer(minLength: 0)
                            Image(systemName: isSelected(reference) ? "chevron.down" : "chevron.right")
                                .foregroundStyle(.secondary)
                        }
                        .padding(.vertical, 6)
                        .padding(.horizontal, 8)
                        .background(selectionBackground(for: reference))
                        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                    }
                    .buttonStyle(.plain)

                    if isSelected(reference) {
                        ReferenceDetailInlineView()
                            .padding(.horizontal, 8)
                    }
                }
            }
        }
    }

    private func selectionBackground(for reference: SkillReference) -> some View {
        let isSelected = store.selectedReferenceID == reference.id
        return RoundedRectangle(cornerRadius: 8, style: .continuous)
            .fill(isSelected ? Color.accentColor.opacity(0.15) : Color.secondary.opacity(0.08))
    }

    private func isSelected(_ reference: SkillReference) -> Bool {
        store.selectedReferenceID == reference.id
    }

    private func toggleReference(_ reference: SkillReference) async {
        if isSelected(reference) {
            store.selectedReferenceID = nil
            store.selectedReferenceMarkdown = ""
            store.referenceState = .idle
        } else {
            await store.selectReference(reference)
        }
    }
}
