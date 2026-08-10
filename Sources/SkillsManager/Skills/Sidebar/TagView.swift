import SwiftUI

struct TagView: View {
    private let label: Text
    private let colorSeed: String
    let systemImage: String?
    let tint: Color?

    init(text: String, systemImage: String? = nil, tint: Color? = nil) {
        self.label = Text(verbatim: text)
        self.colorSeed = text
        self.systemImage = systemImage
        self.tint = tint
    }

    init(
        localized resource: LocalizedStringResource,
        systemImage: String? = nil,
        tint: Color? = nil
    ) {
        self.label = Text(resource)
        self.colorSeed = ""
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
                    .fill(tagColor.opacity(tint == nil ? 0.18 : 0.28))
            )
    }

    private var tagColor: Color {
        if let tint {
            return tint
        }
        let colors: [Color] = [
            .mint, .teal, .cyan, .blue, .indigo, .green, .orange
        ]
        let index = abs(colorSeed.hashValue) % colors.count
        return colors[index]
    }
}
