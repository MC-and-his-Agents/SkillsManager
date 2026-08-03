import Foundation

enum SkillArea: String, CaseIterable, Identifiable {
    case local = "Local"
    case discovery = "Discovery"

    var id: String { rawValue }

    var sources: [SkillSource] {
        switch self {
        case .local: [.local, .discovery]
        case .discovery: [.clawdhub, .skillsSh]
        }
    }

    var defaultSource: SkillSource {
        sources[0]
    }

    var sourcePickerLabel: String {
        switch self {
        case .local: "Management state"
        case .discovery: "Discovery source"
        }
    }
}

enum SkillSource: String, CaseIterable, Identifiable {
    case local = "Local"
    case discovery = "Discovery"
    case clawdhub = "ClawHub"
    case skillsSh = "skills.sh"

    var id: String { rawValue }

    var area: SkillArea {
        switch self {
        case .local, .discovery: .local
        case .clawdhub, .skillsSh: .discovery
        }
    }

    var navigationLabel: String {
        switch self {
        case .local: "Managed"
        case .discovery: "Discovered"
        case .clawdhub: "ClawHub"
        case .skillsSh: "skills.sh"
        }
    }

    var sidebarTitle: String {
        switch self {
        case .local: "Managed Skills"
        case .discovery: "Discovered Skills"
        case .clawdhub: "ClawHub"
        case .skillsSh: "skills.sh Search"
        }
    }
}
