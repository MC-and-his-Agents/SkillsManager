import SwiftUI

struct TagView: View {
    private let label: Text
    let systemImage: String?
    let tint: Color?

    init(text: String, systemImage: String? = nil, tint: Color? = nil) {
        self.label = Text(verbatim: text)
        self.systemImage = systemImage
        self.tint = tint
    }

    init(
        localized resource: LocalizedStringResource,
        systemImage: String? = nil,
        tint: Color? = nil
    ) {
        self.label = Text(resource)
        self.systemImage = systemImage
        self.tint = tint
    }

    var body: some View {
        Group {
            if let systemImage {
                Label {
                    label
                } icon: {
                    Image(systemName: systemImage)
                }
            } else {
                label
            }
        }
            .font(.caption2)
            .foregroundStyle(.primary)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(tint == nil ? Color.secondary.opacity(0.14) : tint!.opacity(0.18))
            )
    }
}
