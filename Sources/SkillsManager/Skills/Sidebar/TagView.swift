import SwiftUI

struct TagView: View {
    let text: String
    let systemImage: String?
    let tint: Color?

    init(text: String, systemImage: String? = nil, tint: Color? = nil) {
        self.text = text
        self.systemImage = systemImage
        self.tint = tint
    }

    var body: some View {
        Group {
            if let systemImage {
                Label(text, systemImage: systemImage)
            } else {
                Text(text)
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
        let index = abs(text.hashValue) % colors.count
        return colors[index]
    }
}
