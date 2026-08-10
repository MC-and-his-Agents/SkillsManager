import Foundation

nonisolated enum SkillListStatusFilter: String, CaseIterable, Identifiable, Sendable {
    case all = "All Statuses"
    case managed = "Managed"
    case needsImport = "Needs Import"
    case available = "Available"

    var id: Self { self }

    func includesDiscoveryStatus(_ status: SkillDiscoveryStatus) -> Bool {
        switch self {
        case .all, .needsImport:
            true
        case .managed, .available:
            false
        }
    }
}

nonisolated enum SkillListSource: String, CaseIterable, Identifiable, Sendable {
    case local = "Local"
    case repository = "Repository"
    case clawHub = "ClawHub"
    case skillsSh = "skills.sh"

    var id: Self { self }

    var systemImage: String {
        switch self {
        case .local: "internaldrive"
        case .repository: "shippingbox"
        case .clawHub: "sparkles"
        case .skillsSh: "magnifyingglass"
        }
    }

    var storageKey: String {
        switch self {
        case .local: "local"
        case .repository: "repository"
        case .clawHub: "clawhub"
        case .skillsSh: "skills-sh"
        }
    }
}

nonisolated enum SkillListSourceFilter: Hashable, Identifiable, Sendable {
    case all
    case source(SkillListSource)

    static var allCases: [Self] {
        [.all] + SkillListSource.allCases.map(Self.source)
    }

    var id: String {
        switch self {
        case .all: "all"
        case .source(let source): "source:\(source.storageKey)"
        }
    }

    var displayName: String {
        switch self {
        case .all: "All Sources"
        case .source(let source): source.rawValue
        }
    }
}

nonisolated enum SkillListAgentFilter: Hashable, Identifiable, Sendable {
    case all
    case agent(SkillPlatform)

    static var allCases: [Self] {
        [.all] + SkillPlatform.allCases.map(Self.agent)
    }

    var id: String {
        switch self {
        case .all: "all"
        case .agent(let platform): "agent:\(platform.storageKey)"
        }
    }

    var displayName: String {
        switch self {
        case .all: "All Agents"
        case .agent(let platform): platform.rawValue
        }
    }
}

nonisolated struct SkillListOriginProjection: Hashable, Sendable {
    let sources: Set<SkillListSource>
    let unknownProviders: [String]

    init(hasRepositorySource: Bool, providers: [String]) {
        let providers = Set(providers)
        var sources = Set<SkillListSource>()
        if hasRepositorySource { sources.insert(.repository) }
        if providers.contains("clawdhub") { sources.insert(.clawHub) }
        if providers.contains("skills.sh") { sources.insert(.skillsSh) }

        unknownProviders = providers
            .subtracting(["clawdhub", "skills.sh"])
            .sorted { $0.utf8.lexicographicallyPrecedes($1.utf8) }
        if !hasRepositorySource && providers.isEmpty {
            sources.insert(.local)
        }
        self.sources = sources
    }

    var labels: [SkillListSourceLabel] {
        let known = SkillListSource.allCases.compactMap { source in
            sources.contains(source)
                ? SkillListSourceLabel(text: source.rawValue, systemImage: source.systemImage)
                : nil
        }
        return known + unknownProviders.map {
            SkillListSourceLabel(text: $0, systemImage: "questionmark.circle")
        }
    }
}

nonisolated struct SkillListSourceLabel: Hashable, Identifiable, Sendable {
    let text: String
    let systemImage: String

    var id: String { "\(systemImage):\(text)" }
}

nonisolated struct SkillListFilters: Hashable, Sendable {
    var status: SkillListStatusFilter = .all
    var source: SkillListSourceFilter = .all
    var agent: SkillListAgentFilter = .all

    var isActive: Bool { status != .all || source != .all || agent != .all }

    func includesManaged(_ skill: Skill) -> Bool {
        includesManaged(
            origin: skill.listOrigin,
            enabledPlatforms: skill.enabledPlatforms
        )
    }

    func includesManaged(
        origin: SkillListOriginProjection,
        enabledPlatforms: Set<SkillPlatform>
    ) -> Bool {
        guard status == .all || status == .managed,
              includes(origin: origin) else { return false }
        switch agent {
        case .all: return true
        case .agent(let platform): return enabledPlatforms.contains(platform)
        }
    }

    func includesDiscovery(_ observation: SkillDiscoveryObservation) -> Bool {
        includesDiscovery(status: observation.status, origin: observation.listOrigin)
    }

    func includesDiscovery(
        status discoveryStatus: SkillDiscoveryStatus,
        origin: SkillListOriginProjection
    ) -> Bool {
        guard status.includesDiscoveryStatus(discoveryStatus), agent == .all else {
            return false
        }
        return includes(origin: origin)
    }

    func includesRemote(_ source: SkillListSource) -> Bool {
        guard status == .all || status == .available, agent == .all else { return false }
        switch self.source {
        case .all: return true
        case .source(let selected): return selected == source
        }
    }

    private func includes(origin: SkillListOriginProjection) -> Bool {
        switch source {
        case .all: true
        case .source(let selected): origin.sources.contains(selected)
        }
    }
}

nonisolated extension SkillDiscoveryObservation {
    var listOrigin: SkillListOriginProjection {
        SkillListOriginProjection(
            hasRepositorySource: matchedSourceKey != nil,
            providers: providerAliases.map(\.provider)
        )
    }
}

nonisolated enum SkillListAgentSummary {
    static func text(count: Int, locale: Locale? = nil) -> String {
        let resource = LocalizedStringResource(
            "%lld Agents",
            defaultValue: "\(count) Agents",
            locale: locale ?? .current,
            bundle: .module
        )
        return String(localized: resource)
    }
}
