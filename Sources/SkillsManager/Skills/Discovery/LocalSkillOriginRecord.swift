import Foundation

nonisolated enum LocalSkillOriginError: Error, Equatable {
    case invalidLocator
    case invalidTimestamp
}

nonisolated struct LocalSkillOriginPosition: Hashable, Sendable {
    let scope: SkillDiscoveryScope
    let collisionKey: String
}

nonisolated struct LocalSkillOriginRecord: Hashable, Sendable {
    let skillID: SkillID
    let scope: SkillDiscoveryScope
    let rawLocator: String
    let normalizedLocator: String
    let collisionKey: String
    let fingerprint: SkillContentFingerprint
    let confirmedAtMilliseconds: Int64

    var position: LocalSkillOriginPosition {
        LocalSkillOriginPosition(scope: scope, collisionKey: collisionKey)
    }

    init(
        skillID: SkillID,
        scope: SkillDiscoveryScope,
        rawLocator: String,
        normalizedLocator: String,
        collisionKey: String,
        fingerprint: SkillContentFingerprint,
        confirmedAtMilliseconds: Int64
    ) throws {
        guard Self.valid(scope) else {
            throw LocalSkillOriginError.invalidLocator
        }
        guard let visibleName = SkillContentPath.visibleDirectoryName(rawLocator),
              visibleName == normalizedLocator,
              collisionKey == SkillContentPath.collisionKey(for: normalizedLocator) else {
            throw LocalSkillOriginError.invalidLocator
        }
        guard confirmedAtMilliseconds >= 0 else {
            throw LocalSkillOriginError.invalidTimestamp
        }
        self.skillID = skillID
        self.scope = scope
        self.rawLocator = rawLocator
        self.normalizedLocator = normalizedLocator
        self.collisionKey = collisionKey
        self.fingerprint = fingerprint
        self.confirmedAtMilliseconds = confirmedAtMilliseconds
    }

    private static func valid(_ scope: SkillDiscoveryScope) -> Bool {
        switch scope.kind {
        case .global:
            return scope.adapterCode == nil
                && scope.pathVariant == nil
                && scope.customPathID == nil
        case .agent:
            return valid(scope.adapterCode, maximumBytes: 128)
                && valid(scope.pathVariant, maximumBytes: 1_024)
                && scope.customPathID == nil
        case .custom:
            return valid(scope.adapterCode, maximumBytes: 128)
                && valid(scope.pathVariant, maximumBytes: 1_024)
                && scope.customPathID != nil
        }
    }

    private static func valid(_ value: String?, maximumBytes: Int) -> Bool {
        guard let value else { return false }
        return 1...maximumBytes ~= value.utf8.count
    }
}
