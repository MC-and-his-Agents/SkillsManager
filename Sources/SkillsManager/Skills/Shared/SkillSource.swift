import Foundation

enum SkillSource: String, CaseIterable, Identifiable {
    case local = "Local"
    case discovery = "Discovery"
    case clawdhub = "Clawdhub"
    case skillsSh = "skills.sh"

    var id: String { rawValue }

    var sidebarTitle: String {
        switch self {
        case .local: "Installed Skills"
        case .discovery: "Skill Discovery"
        case .clawdhub: "Clawdhub"
        case .skillsSh: "skills.sh Search"
        }
    }
}
