import Foundation

enum PublishBump: String, CaseIterable, Identifiable {
    case patch
    case minor
    case major

    var id: String { rawValue }

    var label: String {
        rawValue.capitalized
    }
}
