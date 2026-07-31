import Foundation

enum SkillSource: String, CaseIterable, Identifiable {
    case local = "Local"
    case discovery = "Discovery"
    case clawdhub = "ClawHub"
    case skillsSh = "skills.sh"

    var id: String { rawValue }

    var sidebarTitle: String {
        switch self {
        case .local: "Installed Skills"
        case .discovery: "Skill Discovery"
        case .clawdhub: "ClawHub"
        case .skillsSh: "skills.sh Search"
        }
    }
}
