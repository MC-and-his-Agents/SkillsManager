import Foundation

nonisolated enum DistributionRepairSelectionToken {
    static func encode(
        _ selection: DistributionSelectionReadback,
        skillID: SkillID
    ) throws -> Data {
        guard selection.bindings.allSatisfy({ $0.skillID == skillID }) else {
            throw DistributionRepairPlanningError.invalidSelection
        }
        let bindings = selection.bindings.map(Binding.init).sorted {
            if $0.targetScopeKey != $1.targetScopeKey {
                return utf8Precedes($0.targetScopeKey, $1.targetScopeKey)
            }
            if $0.slugKey != $1.slugKey {
                return utf8Precedes($0.slugKey, $1.slugKey)
            }
            return utf8Precedes($0.syncMode, $1.syncMode)
        }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return try encoder.encode(Token(
            schemaVersion: 1,
            skillID: skillID.directoryName,
            isExplicitlyConfigured: selection.isExplicitlyConfigured,
            bindings: bindings
        ))
    }

    private struct Token: Encodable {
        let schemaVersion: Int
        let skillID: String
        let isExplicitlyConfigured: Bool
        let bindings: [Binding]
    }

    private struct Binding: Encodable {
        let skillID: String
        let targetScopeKey: String
        let distributionSlug: String
        let slugKey: String
        let syncMode: String

        init(_ binding: DistributionBinding) {
            skillID = binding.skillID.directoryName
            targetScopeKey = binding.scope.targetScopeKey
            distributionSlug = binding.distributionSlug.value
            slugKey = binding.distributionSlug.collisionKey
            syncMode = binding.syncMode.rawValue
        }
    }
}
