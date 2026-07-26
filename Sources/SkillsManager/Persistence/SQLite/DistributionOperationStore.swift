import Foundation

nonisolated enum DistributionOperationPhase: String, CaseIterable, Codable, Sendable {
    case prepared
    case applying
    case filesystemApplied
    case databaseCommitted
    case rollingBack
    case cleaning
    case completed
}

nonisolated enum DistributionOperationOutcome: String, CaseIterable, Codable, Sendable {
    case applied
    case rolledBack
    case needsRepair
}

nonisolated enum DistributionOperationPayloadError: Error, Equatable {
    case empty
    case tooLarge
    case notCanonical
    case invalid
}

/// Canonical JSON for journal payloads. The store keeps payloads opaque so the
/// executor can evolve its versioned plan without widening the SQLite schema.
nonisolated enum DistributionOperationPayloadCodec {
    static let maximumByteCount = 65_536

    static func encode<T: Encodable>(_ value: T) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        let data = try encoder.encode(value)
        try validate(data)
        return data
    }

    static func decode<T: Decodable & Encodable>(_ type: T.Type, from data: Data) throws -> T {
        try validate(data)
        let value = try JSONDecoder().decode(type, from: data)
        guard try encode(value) == data else {
            throw DistributionOperationPayloadError.notCanonical
        }
        return value
    }

    static func validate(_ data: Data) throws {
        guard !data.isEmpty else { throw DistributionOperationPayloadError.empty }
        guard data.count <= maximumByteCount else {
            throw DistributionOperationPayloadError.tooLarge
        }
        let object: Any
        do {
            object = try JSONSerialization.jsonObject(with: data)
        } catch {
            throw DistributionOperationPayloadError.invalid
        }
        guard JSONSerialization.isValidJSONObject(object) else {
            throw DistributionOperationPayloadError.invalid
        }
        let canonical = try JSONSerialization.data(
            withJSONObject: object,
            options: [.sortedKeys, .withoutEscapingSlashes]
        )
        guard canonical == data else {
            throw DistributionOperationPayloadError.notCanonical
        }
    }
}

private nonisolated struct DistributionBindingWire: Codable, Equatable {
    let skillID: String
    let scope: String
    let adapter: String?
    let slug: String
    let syncMode: String
    let createdAtMilliseconds: Int64?
    let updatedAtMilliseconds: Int64?

    private enum CodingKeys: String, CodingKey {
        case skillID
        case scope
        case adapter
        case slug
        case syncMode
        case createdAtMilliseconds
        case updatedAtMilliseconds
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        skillID = try container.decode(String.self, forKey: .skillID)
        scope = try container.decode(String.self, forKey: .scope)
        adapter = try container.decodeIfPresent(String.self, forKey: .adapter)
        slug = try container.decode(String.self, forKey: .slug)
        syncMode = try container.decode(String.self, forKey: .syncMode)
        createdAtMilliseconds = try container.decodeIfPresent(
            Int64.self,
            forKey: .createdAtMilliseconds
        )
        updatedAtMilliseconds = try container.decodeIfPresent(
            Int64.self,
            forKey: .updatedAtMilliseconds
        )
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(skillID, forKey: .skillID)
        try container.encode(scope, forKey: .scope)
        try container.encode(adapter, forKey: .adapter)
        try container.encode(slug, forKey: .slug)
        try container.encode(syncMode, forKey: .syncMode)
        try container.encodeIfPresent(createdAtMilliseconds, forKey: .createdAtMilliseconds)
        try container.encodeIfPresent(updatedAtMilliseconds, forKey: .updatedAtMilliseconds)
    }
}

private nonisolated struct DistributionPlanBindingWire: Codable, Equatable {
    let skillID: String
    let scopeKind: String
    let adapterCode: String?
    let targetScopeKey: String
    let distributionSlug: String
    let slugKey: String
    let syncMode: String

    enum CodingKeys: String, CodingKey {
        case skillID = "skill_id"
        case scopeKind = "scope_kind"
        case adapterCode = "adapter_code"
        case targetScopeKey = "target_scope_key"
        case distributionSlug = "distribution_slug"
        case slugKey = "slug_key"
        case syncMode = "sync_mode"
    }
}

private nonisolated struct DistributionPlanActionWire: Codable, Equatable {
    let action: String
    let targetScopeKey: String
    let targetLocator: String
    let ssotLocator: String

    enum CodingKeys: String, CodingKey {
        case action
        case targetScopeKey = "target_scope_key"
        case targetLocator = "target_locator"
        case ssotLocator = "ssot_locator"
    }
}

private nonisolated struct DistributionPlanConflictWire: Codable, Equatable {
    let reason: String
    let targetScopeKey: String
    let slugKey: String
    let targetLocator: String

    enum CodingKeys: String, CodingKey {
        case reason
        case targetScopeKey = "target_scope_key"
        case slugKey = "slug_key"
        case targetLocator = "target_locator"
    }
}

private nonisolated struct DistributionPlanWire: Codable, Equatable {
    let status: String
    let filesystemActions: [DistributionPlanActionWire]
    let bindingsChanged: Bool
    let bindingReplacement: [DistributionPlanBindingWire]
    let conflicts: [DistributionPlanConflictWire]

    enum CodingKeys: String, CodingKey {
        case status
        case filesystemActions = "filesystem_actions"
        case bindingsChanged = "bindings_changed"
        case bindingReplacement = "binding_replacement"
        case conflicts
    }
}

private nonisolated struct DistributionPreflightWire: Codable, Equatable {
    let kind: String
    let targetScopeKey: String
    let slug: String
    let absoluteLinkTarget: String
    let ssotIdentity: Data
    let rootIdentity: Data
    let entryIdentity: Data?
    let temporaryName: String
}

private nonisolated struct DistributionRuntimeWire: Codable, Equatable {
    struct OldOwnership: Codable, Equatable {
        let targetScopeKey: String
        let appliedOperationID: Data
        let rootIdentity: Data
        let entryIdentity: Data
        let absoluteLinkTarget: String
        let verifiedAtMilliseconds: Int64
    }

    struct Created: Codable, Equatable {
        let actionIndex: Int
        let rootIdentity: Data
        let entryIdentity: Data
        let absoluteLinkTarget: String
    }

    struct Removed: Codable, Equatable {
        let actionIndex: Int
        let temporaryName: String
        let rootIdentity: Data
        let entryIdentity: Data
        let absoluteLinkTarget: String
    }

    let created: [Created]
    let removed: [Removed]
    let oldOwnership: [OldOwnership]

    private enum CodingKeys: String, CodingKey {
        case created
        case removed
        case oldOwnership
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        created = try container.decode([Created].self, forKey: .created)
        removed = try container.decode([Removed].self, forKey: .removed)
        oldOwnership = try container.decodeIfPresent(
            [OldOwnership].self,
            forKey: .oldOwnership
        ) ?? []
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(created, forKey: .created)
        try container.encode(removed, forKey: .removed)
        if !oldOwnership.isEmpty {
            try container.encode(oldOwnership, forKey: .oldOwnership)
        }
    }
}

private nonisolated enum DistributionOperationPayloadValidator {
    static let maximumRoots = 5
    static let maximumActions = 8

    static func validate(
        operationID: SSOTOperationID,
        skillID: SkillID,
        oldBindingsData: Data,
        newBindingsData: Data,
        planData: Data,
        preflightData: Data,
        runtimeData: Data,
        phase: DistributionOperationPhase,
        forwardCursor: Int64,
        rollbackCursor: Int64,
        cleanupCursor: Int64
    ) throws {
        let old = try decodeBindings(oldBindingsData)
        let new = try decodeBindings(newBindingsData)
        try validateBindings(old, skillID: skillID, requireTimestamps: true)
        try validateBindings(new, skillID: skillID, requireTimestamps: false)
        let plan = try decodePlan(planData)
        try validatePlan(
            plan,
            skillID: skillID,
            old: old,
            new: new
        )
        let preflight = try decodePreflight(preflightData)
        try validatePreflight(
            preflight,
            plan: plan,
            skillID: skillID,
            operationID: operationID
        )
        let runtime = try decodeRuntime(runtimeData)
        guard Set(runtime.oldOwnership.map(\.targetScopeKey))
                == Set(old.map(bindingScopeKey)),
              runtime.oldOwnership.allSatisfy({
                  $0.absoluteLinkTarget.hasSuffix(
                      "/.SkillsManager/skills/\(skillID.directoryName)"
                  )
              }) else {
            throw DistributionOperationStoreError.invalidRecord
        }
        try validateRuntime(
            runtime,
            preflight: preflight,
            plan: plan,
            forwardCursor: forwardCursor,
            rollbackCursor: rollbackCursor,
            cleanupCursor: cleanupCursor,
            phase: phase
        )
    }

    static func validateRuntime(
        _ data: Data,
        planData: Data,
        preflightData: Data,
        forwardCursor: Int64,
        rollbackCursor: Int64,
        cleanupCursor: Int64,
        phase: DistributionOperationPhase
    ) throws {
        let plan = try decodePlan(planData)
        let preflight = try decodePreflight(preflightData)
        let runtime = try decodeRuntime(data)
        try validateRuntime(
            runtime,
            preflight: preflight,
            plan: plan,
            forwardCursor: forwardCursor,
            rollbackCursor: rollbackCursor,
            cleanupCursor: cleanupCursor,
            phase: phase
        )
    }

    private static func decodeBindings(_ data: Data) throws -> [DistributionBindingWire] {
        let value = try DistributionOperationPayloadCodec.decode(
            [DistributionBindingWire].self,
            from: data
        )
        guard let array = try JSONSerialization.jsonObject(with: data) as? [[String: Any]],
              array.allSatisfy({
                  let keys = Set($0.keys)
                  return keys == ["skillID", "scope", "adapter", "slug", "syncMode"]
                      || keys == [
                          "skillID", "scope", "adapter", "slug", "syncMode",
                          "createdAtMilliseconds", "updatedAtMilliseconds"
                      ]
              }) else {
            throw DistributionOperationStoreError.invalidRecord
        }
        return value
    }

    private static func decodePlan(_ data: Data) throws -> DistributionPlanWire {
        let value = try DistributionOperationPayloadCodec.decode(
            DistributionPlanWire.self,
            from: data
        )
        guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              Set(object.keys) == [
                  "status", "filesystem_actions", "bindings_changed",
                  "binding_replacement", "conflicts"
              ],
              let actions = object["filesystem_actions"] as? [[String: Any]],
              actions.allSatisfy({
                  Set($0.keys) == ["action", "target_scope_key", "target_locator", "ssot_locator"]
              }),
              let bindings = object["binding_replacement"] as? [[String: Any]],
              bindings.allSatisfy({
                  let keys = Set($0.keys)
                  let complete = Set([
                      "skill_id", "scope_kind", "adapter_code", "target_scope_key",
                      "distribution_slug", "slug_key", "sync_mode"
                  ])
                  let globalWithoutAdapter = complete.subtracting(["adapter_code"])
                  return keys == complete
                      || (keys == globalWithoutAdapter && $0["scope_kind"] as? String == "global")
              }),
              let conflicts = object["conflicts"] as? [[String: Any]],
              conflicts.allSatisfy({
                  Set($0.keys) == ["reason", "target_scope_key", "slug_key", "target_locator"]
              }) else {
            throw DistributionOperationStoreError.invalidRecord
        }
        return value
    }

    private static func decodePreflight(_ data: Data) throws -> [DistributionPreflightWire] {
        let value = try DistributionOperationPayloadCodec.decode(
            [DistributionPreflightWire].self,
            from: data
        )
        guard let array = try JSONSerialization.jsonObject(with: data) as? [[String: Any]],
              array.allSatisfy({
                  let complete = Set([
                      "kind", "targetScopeKey", "slug", "absoluteLinkTarget",
                      "ssotIdentity", "rootIdentity", "entryIdentity", "temporaryName"
                  ])
                  let createWithoutEntry = complete.subtracting(["entryIdentity"])
                  return Set($0.keys) == complete
                      || (Set($0.keys) == createWithoutEntry
                          && $0["kind"] as? String == "create_symlink")
              }) else {
            throw DistributionOperationStoreError.invalidRecord
        }
        return value
    }

    private static func decodeRuntime(_ data: Data) throws -> DistributionRuntimeWire {
        let value = try DistributionOperationPayloadCodec.decode(
            DistributionRuntimeWire.self,
            from: data
        )
        guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              (Set(object.keys) == ["created", "removed"]
                  || Set(object.keys) == ["created", "removed", "oldOwnership"]),
              let created = object["created"] as? [[String: Any]],
              created.allSatisfy({
                  Set($0.keys) == [
                      "actionIndex", "rootIdentity", "entryIdentity", "absoluteLinkTarget"
                  ]
              }),
              let removed = object["removed"] as? [[String: Any]],
              removed.allSatisfy({
                  Set($0.keys) == [
                      "actionIndex", "temporaryName", "rootIdentity", "entryIdentity",
                      "absoluteLinkTarget"
                  ]
              }) else {
            throw DistributionOperationStoreError.invalidRecord
        }
        let oldOwnership = (object["oldOwnership"] as? [[String: Any]]) ?? []
        guard !object.keys.contains("oldOwnership")
                || oldOwnership.allSatisfy({
                    Set($0.keys) == [
                        "targetScopeKey", "appliedOperationID", "rootIdentity",
                        "entryIdentity", "absoluteLinkTarget", "verifiedAtMilliseconds"
                    ]
                }) else {
            throw DistributionOperationStoreError.invalidRecord
        }
        guard value.oldOwnership.count <= maximumRoots,
              Set(value.oldOwnership.map(\.targetScopeKey)).count
                  == value.oldOwnership.count,
              value.oldOwnership.allSatisfy({
                  $0.appliedOperationID.count == 16
                      && $0.rootIdentity.count == ManagedItemIdentityCodec.encodedByteCount
                      && $0.entryIdentity.count == ManagedItemIdentityCodec.encodedByteCount
                      && $0.absoluteLinkTarget.hasPrefix("/")
                      && URL(fileURLWithPath: $0.absoluteLinkTarget).standardizedFileURL.path
                        == $0.absoluteLinkTarget
                      && $0.verifiedAtMilliseconds >= 0
              }) else {
            throw DistributionOperationStoreError.invalidRecord
        }
        for ownership in value.oldOwnership {
            try validateIdentity(ownership.rootIdentity)
            try validateIdentity(ownership.entryIdentity)
        }
        return value
    }

    private static func validateBindings(
        _ bindings: [DistributionBindingWire],
        skillID: SkillID,
        requireTimestamps: Bool
    ) throws {
        guard bindings.count <= maximumRoots else {
            throw DistributionOperationStoreError.invalidRecord
        }
        var scopes = Set<String>()
        for binding in bindings {
            let timestampsValid: Bool
            if requireTimestamps {
                if let created = binding.createdAtMilliseconds,
                   let updated = binding.updatedAtMilliseconds {
                    timestampsValid = created >= 0 && updated >= created
                } else {
                    timestampsValid = false
                }
            } else {
                timestampsValid = binding.createdAtMilliseconds == nil
                    && binding.updatedAtMilliseconds == nil
            }
            guard binding.skillID == skillID.directoryName,
                  binding.syncMode == DistributionSyncMode.symlink.rawValue,
                  let slug = try? DefaultDistributionSlug(validating: binding.slug),
                  slug.collisionKey == SkillContentPath.collisionKey(for: slug.value),
                  timestampsValid
            else {
                throw DistributionOperationStoreError.invalidRecord
            }
            let scopeKey: String
            switch binding.scope {
            case "global":
                guard binding.adapter == nil else {
                    throw DistributionOperationStoreError.invalidRecord
                }
                scopeKey = "global"
            case "agent":
                guard let adapter = binding.adapter,
                      SkillPlatform.allCases.contains(where: { $0.storageKey == adapter }) else {
                    throw DistributionOperationStoreError.invalidRecord
                }
                scopeKey = "agent:\(adapter)"
            default:
                throw DistributionOperationStoreError.invalidRecord
            }
            guard scopes.insert(scopeKey).inserted else {
                throw DistributionOperationStoreError.invalidRecord
            }
        }
        guard !scopes.contains("global") || bindings.count == 1 else {
            throw DistributionOperationStoreError.invalidRecord
        }
    }

    private static func validatePlan(
        _ plan: DistributionPlanWire,
        skillID: SkillID,
        old: [DistributionBindingWire],
        new: [DistributionBindingWire]
    ) throws {
        guard plan.status == DistributionPlanStatus.executable.rawValue,
              plan.conflicts.isEmpty,
              plan.filesystemActions.count <= maximumActions,
              plan.bindingReplacement.count == new.count else {
            throw DistributionOperationStoreError.invalidRecord
        }
        let oldKeys = Set(old.map(bindingKey))
        let newKeys = Set(new.map(bindingKey))
        guard plan.bindingsChanged == (oldKeys != newKeys) else {
            throw DistributionOperationStoreError.invalidRecord
        }
        let replacementKeys = try Set(
            plan.bindingReplacement.map { try planBindingKey($0, skillID: skillID) }
        )
        guard replacementKeys == newKeys else {
            throw DistributionOperationStoreError.invalidRecord
        }
        var targets = Set<String>()
        var roots = Set<String>()
        var sawCreate = false
        for action in plan.filesystemActions {
            guard action.action == DistributionFilesystemActionKind.removeSymlink.rawValue
                    || action.action == DistributionFilesystemActionKind.createSymlink.rawValue,
                  let scope = scope(for: action.targetScopeKey),
                  let slug = slug(for: action.targetLocator, scope: scope),
                  action.ssotLocator == DistributionTargetCatalog.current.ssotLocator(for: skillID),
                  targets.insert("\(action.targetScopeKey):\(slug)").inserted else {
                throw DistributionOperationStoreError.invalidRecord
            }
            if action.action == DistributionFilesystemActionKind.createSymlink.rawValue {
                sawCreate = true
                guard new.contains(where: {
                    "\($0.scope == "global" ? "global" : "agent:\($0.adapter ?? "")"):\($0.slug)"
                        == "\(action.targetScopeKey):\(slug)"
                }), !old.contains(where: {
                    "\($0.scope == "global" ? "global" : "agent:\($0.adapter ?? "")"):\($0.slug)"
                        == "\(action.targetScopeKey):\(slug)"
                }) else {
                    throw DistributionOperationStoreError.invalidRecord
                }
            } else if sawCreate {
                throw DistributionOperationStoreError.invalidRecord
            } else {
                guard old.contains(where: {
                    "\($0.scope == "global" ? "global" : "agent:\($0.adapter ?? "")"):\($0.slug)"
                        == "\(action.targetScopeKey):\(slug)"
                }), !new.contains(where: {
                    "\($0.scope == "global" ? "global" : "agent:\($0.adapter ?? "")"):\($0.slug)"
                        == "\(action.targetScopeKey):\(slug)"
                }) else {
                    throw DistributionOperationStoreError.invalidRecord
                }
            }
            roots.insert(action.targetScopeKey)
        }
        guard roots.count <= maximumRoots else {
            throw DistributionOperationStoreError.invalidRecord
        }
    }

    private static func validatePreflight(
        _ preflight: [DistributionPreflightWire],
        plan: DistributionPlanWire,
        skillID: SkillID,
        operationID: SSOTOperationID
    ) throws {
        guard preflight.count == plan.filesystemActions.count else {
            throw DistributionOperationStoreError.invalidRecord
        }
        var ssotIdentity: Data?
        var absoluteTarget: String?
        for (index, value) in preflight.enumerated() {
            let action = plan.filesystemActions[index]
            guard value.kind == action.action,
                  value.targetScopeKey == action.targetScopeKey,
                  value.slug == slug(for: action.targetLocator, scope: scope(for: action.targetScopeKey)),
                  value.absoluteLinkTarget.hasPrefix("/"),
                  URL(fileURLWithPath: value.absoluteLinkTarget).standardizedFileURL.path
                    == value.absoluteLinkTarget,
                  value.absoluteLinkTarget.hasSuffix("/.SkillsManager/skills/\(skillID.directoryName)"),
                  value.temporaryName == temporaryName(operationID, index),
                  value.ssotIdentity.count == ManagedItemIdentityCodec.encodedByteCount,
                  (value.rootIdentity.isEmpty
                      || value.rootIdentity.count == ManagedItemIdentityCodec.encodedByteCount),
                  (value.entryIdentity == nil
                      || value.entryIdentity?.count == ManagedItemIdentityCodec.encodedByteCount)
            else {
                throw DistributionOperationStoreError.invalidRecord
            }
            try validateIdentity(value.ssotIdentity)
            if !value.rootIdentity.isEmpty { try validateIdentity(value.rootIdentity) }
            if let entry = value.entryIdentity { try validateIdentity(entry) }
            if value.kind == DistributionFilesystemActionKind.removeSymlink.rawValue {
                guard value.rootIdentity.count == ManagedItemIdentityCodec.encodedByteCount,
                      value.entryIdentity?.count == ManagedItemIdentityCodec.encodedByteCount else {
                    throw DistributionOperationStoreError.invalidRecord
                }
            } else {
                guard value.entryIdentity == nil else {
                    throw DistributionOperationStoreError.invalidRecord
                }
            }
            if let ssotIdentity, ssotIdentity != value.ssotIdentity {
                throw DistributionOperationStoreError.invalidRecord
            }
            ssotIdentity = value.ssotIdentity
            if let absoluteTarget, absoluteTarget != value.absoluteLinkTarget {
                throw DistributionOperationStoreError.invalidRecord
            }
            absoluteTarget = value.absoluteLinkTarget
        }
    }

    private static func validateRuntime(
        _ runtime: DistributionRuntimeWire,
        preflight: [DistributionPreflightWire],
        plan: DistributionPlanWire,
        forwardCursor: Int64,
        rollbackCursor: Int64,
        cleanupCursor: Int64,
        phase: DistributionOperationPhase
    ) throws {
        guard forwardCursor <= Int64(maximumActions),
              rollbackCursor <= Int64(maximumActions),
              cleanupCursor <= Int64(maximumActions),
              forwardCursor <= Int64(plan.filesystemActions.count),
              (phase == .filesystemApplied || phase == .databaseCommitted
                  || phase == .cleaning || phase == .completed
                  ? forwardCursor == Int64(plan.filesystemActions.count) : true)
        else {
            throw DistributionOperationStoreError.invalidRecord
        }
        var indices = Set<Int>()
        for value in runtime.created {
            guard indices.insert(value.actionIndex).inserted,
                  preflight.indices.contains(value.actionIndex),
                  value.actionIndex < Int(forwardCursor),
                  plan.filesystemActions[value.actionIndex].action
                    == DistributionFilesystemActionKind.createSymlink.rawValue,
                  value.rootIdentity.count == ManagedItemIdentityCodec.encodedByteCount,
                  value.entryIdentity.count == ManagedItemIdentityCodec.encodedByteCount,
                  value.absoluteLinkTarget == preflight[value.actionIndex].absoluteLinkTarget else {
                throw DistributionOperationStoreError.invalidRecord
            }
            try validateIdentity(value.rootIdentity)
            try validateIdentity(value.entryIdentity)
        }
        for value in runtime.removed {
            guard indices.insert(value.actionIndex).inserted,
                  preflight.indices.contains(value.actionIndex),
                  value.actionIndex < Int(forwardCursor),
                  plan.filesystemActions[value.actionIndex].action
                    == DistributionFilesystemActionKind.removeSymlink.rawValue,
                  value.rootIdentity.count == ManagedItemIdentityCodec.encodedByteCount,
                  value.entryIdentity.count == ManagedItemIdentityCodec.encodedByteCount,
                  value.temporaryName == preflight[value.actionIndex].temporaryName,
                  value.absoluteLinkTarget == preflight[value.actionIndex].absoluteLinkTarget else {
                throw DistributionOperationStoreError.invalidRecord
            }
            try validateIdentity(value.rootIdentity)
            try validateIdentity(value.entryIdentity)
        }
        guard indices == Set(0..<Int(forwardCursor)) else {
            throw DistributionOperationStoreError.invalidRecord
        }
    }

    private static func bindingKey(_ value: DistributionBindingWire) -> String {
        "\(value.scope):\(value.adapter ?? ""):\(value.slug):\(value.syncMode)"
    }

    private static func bindingScopeKey(_ value: DistributionBindingWire) -> String {
        value.scope == "global" ? "global" : "agent:\(value.adapter ?? "")"
    }

    private static func planBindingKey(
        _ value: DistributionPlanBindingWire,
        skillID: SkillID
    ) throws -> String {
        guard let slug = try? DefaultDistributionSlug(validating: value.distributionSlug),
              slug.collisionKey == value.slugKey,
              value.syncMode == DistributionSyncMode.symlink.rawValue,
              value.skillID == skillID.directoryName else {
            throw DistributionOperationStoreError.invalidRecord
        }
        switch value.scopeKind {
        case "global":
            guard value.adapterCode == nil, value.targetScopeKey == "global" else {
                throw DistributionOperationStoreError.invalidRecord
            }
        case "agent":
            guard let adapter = value.adapterCode,
                  SkillPlatform.allCases.contains(where: { $0.storageKey == adapter }),
                  value.targetScopeKey == "agent:\(adapter)" else {
                throw DistributionOperationStoreError.invalidRecord
            }
        default:
            throw DistributionOperationStoreError.invalidRecord
        }
        return "\(value.scopeKind):\(value.adapterCode ?? ""):\(slug.value):\(value.syncMode)"
    }

    private static func validateIdentity(_ data: Data) throws {
        do {
            _ = try ManagedItemIdentityCodec.decode(data)
        } catch {
            throw DistributionOperationStoreError.invalidRecord
        }
    }

    private static func scope(for key: String) -> DistributionBindingScope? {
        if key == "global" { return .global }
        guard let adapter = key.split(separator: ":", maxSplits: 1).last,
              let value = SkillPlatform.allCases.first(where: { $0.storageKey == adapter }) else {
            return nil
        }
        return .agent(value)
    }

    private static func slug(for locator: String, scope: DistributionBindingScope?) -> String? {
        guard let scope, let target = DistributionTargetCatalog.current.target(for: scope),
              locator.hasPrefix(target.rootLocator + "/") else { return nil }
        return String(locator.dropFirst(target.rootLocator.count + 1))
    }

    private static func temporaryName(_ operationID: SSOTOperationID, _ index: Int) -> String {
        ".skillsmanager-distribution-\(operationID.uuid.uuidString.lowercased())-\(index)"
    }
}

nonisolated struct DistributionOperationDraft: Sendable, Equatable {
    let operationID: SSOTOperationID
    let skillID: SkillID
    let oldBindings: Data
    let newBindings: Data
    let planPayload: Data
    let preflightPayload: Data
    let runtimePayload: Data
    let createdAtMilliseconds: Int64
    let updatedAtMilliseconds: Int64

    init(
        operationID: SSOTOperationID = SSOTOperationID(),
        skillID: SkillID,
        oldBindings: Data,
        newBindings: Data,
        planPayload: Data,
        preflightPayload: Data,
        runtimePayload: Data,
        createdAtMilliseconds: Int64,
        updatedAtMilliseconds: Int64? = nil
    ) throws {
        let updated = updatedAtMilliseconds ?? createdAtMilliseconds
        try DistributionOperationRecord.validate(
            oldBindings: oldBindings,
            newBindings: newBindings,
            planPayload: planPayload,
            preflightPayload: preflightPayload,
            runtimePayload: runtimePayload,
            forwardCursor: 0,
            rollbackCursor: 0,
            cleanupCursor: 0,
            attemptCount: 0,
            lastError: nil,
            createdAtMilliseconds: createdAtMilliseconds,
            updatedAtMilliseconds: updated,
            phase: .prepared,
            outcome: nil
        )
        try DistributionOperationPayloadValidator.validate(
            operationID: operationID,
            skillID: skillID,
            oldBindingsData: oldBindings,
            newBindingsData: newBindings,
            planData: planPayload,
            preflightData: preflightPayload,
            runtimeData: runtimePayload,
            phase: .prepared,
            forwardCursor: 0,
            rollbackCursor: 0,
            cleanupCursor: 0
        )
        self.operationID = operationID
        self.skillID = skillID
        self.oldBindings = oldBindings
        self.newBindings = newBindings
        self.planPayload = planPayload
        self.preflightPayload = preflightPayload
        self.runtimePayload = runtimePayload
        self.createdAtMilliseconds = createdAtMilliseconds
        self.updatedAtMilliseconds = updated
    }

    var record: DistributionOperationRecord {
        // Validation is performed by the initializer above.
        DistributionOperationRecord(
            operationID: operationID,
            skillID: skillID,
            phase: .prepared,
            outcome: nil,
            oldBindings: oldBindings,
            newBindings: newBindings,
            planPayload: planPayload,
            preflightPayload: preflightPayload,
            runtimePayload: runtimePayload,
            forwardCursor: 0,
            rollbackCursor: 0,
            cleanupCursor: 0,
            attemptCount: 0,
            lastError: nil,
            createdAtMilliseconds: createdAtMilliseconds,
            updatedAtMilliseconds: updatedAtMilliseconds
        )
    }
}

nonisolated struct DistributionOperationRecord: Sendable, Equatable {
    let operationID: SSOTOperationID
    let skillID: SkillID
    let phase: DistributionOperationPhase
    let outcome: DistributionOperationOutcome?
    let oldBindings: Data
    let newBindings: Data
    let planPayload: Data
    let preflightPayload: Data
    let runtimePayload: Data
    let forwardCursor: Int64
    let rollbackCursor: Int64
    let cleanupCursor: Int64
    let attemptCount: Int64
    let lastError: String?
    let createdAtMilliseconds: Int64
    let updatedAtMilliseconds: Int64

    init(
        operationID: SSOTOperationID,
        skillID: SkillID,
        phase: DistributionOperationPhase,
        outcome: DistributionOperationOutcome?,
        oldBindings: Data,
        newBindings: Data,
        planPayload: Data,
        preflightPayload: Data,
        runtimePayload: Data,
        forwardCursor: Int64,
        rollbackCursor: Int64,
        cleanupCursor: Int64,
        attemptCount: Int64,
        lastError: String?,
        createdAtMilliseconds: Int64,
        updatedAtMilliseconds: Int64
    ) {
        self.operationID = operationID
        self.skillID = skillID
        self.phase = phase
        self.outcome = outcome
        self.oldBindings = oldBindings
        self.newBindings = newBindings
        self.planPayload = planPayload
        self.preflightPayload = preflightPayload
        self.runtimePayload = runtimePayload
        self.forwardCursor = forwardCursor
        self.rollbackCursor = rollbackCursor
        self.cleanupCursor = cleanupCursor
        self.attemptCount = attemptCount
        self.lastError = lastError
        self.createdAtMilliseconds = createdAtMilliseconds
        self.updatedAtMilliseconds = updatedAtMilliseconds
    }

    fileprivate static func validate(
        oldBindings: Data,
        newBindings: Data,
        planPayload: Data,
        preflightPayload: Data,
        runtimePayload: Data,
        forwardCursor: Int64,
        rollbackCursor: Int64,
        cleanupCursor: Int64,
        attemptCount: Int64,
        lastError: String?,
        createdAtMilliseconds: Int64,
        updatedAtMilliseconds: Int64,
        phase: DistributionOperationPhase,
        outcome: DistributionOperationOutcome?
    ) throws {
        for payload in [oldBindings, newBindings, planPayload, preflightPayload, runtimePayload] {
            do { try DistributionOperationPayloadCodec.validate(payload) }
            catch { throw DistributionOperationStoreError.invalidRecord }
        }
        guard forwardCursor >= 0, rollbackCursor >= 0, cleanupCursor >= 0,
              attemptCount >= 0, createdAtMilliseconds >= 0,
              updatedAtMilliseconds >= createdAtMilliseconds,
              (lastError?.utf8.count ?? 0) <= 4_096 else {
            throw DistributionOperationStoreError.invalidRecord
        }
        if phase == .completed {
            guard outcome == .applied || outcome == .rolledBack || outcome == .needsRepair else {
                throw DistributionOperationStoreError.invalidRecord
            }
        } else if outcome == .applied || outcome == .rolledBack {
            throw DistributionOperationStoreError.invalidRecord
        }
    }
}

nonisolated enum DistributionOperationStoreError: Error, Equatable, LocalizedError {
    case invalidRecord
    case operationNotFound
    case conflict
    case corruptRecord

    var errorDescription: String? {
        switch self {
        case .invalidRecord: "The distribution operation record is invalid."
        case .operationNotFound: "The distribution operation was not found."
        case .conflict: "The distribution operation changed concurrently."
        case .corruptRecord: "The distribution operation record is corrupt."
        }
    }
}

nonisolated final class DistributionOperationStore {
    let connection: SQLiteConnection

    init(connection: SQLiteConnection) throws {
        guard connection.accessMode != .readOnly else {
            throw SQLiteStoreError.invalidState("the distribution operation store requires read-write access")
        }
        self.connection = connection
    }

    func insertPrepared(_ draft: DistributionOperationDraft) throws -> DistributionOperationRecord {
        let record = draft.record
        let statement = try connection.prepare(
            """
            INSERT INTO distribution_operations(
              operation_id, format_version, skill_id, phase, outcome,
              old_bindings, new_bindings, plan_payload, preflight_payload, runtime_payload,
              forward_cursor, rollback_cursor, cleanup_cursor, attempt_count, last_error,
              created_at_ms, updated_at_ms
            ) VALUES (?, 1, ?, 'prepared', NULL, ?, ?, ?, ?, ?, 0, 0, 0, 0, NULL, ?, ?)
            """
        )
        try statement.bind(record.operationID.bytes, at: 1)
        try statement.bind(record.skillID.bytes, at: 2)
        try statement.bind(record.oldBindings, at: 3)
        try statement.bind(record.newBindings, at: 4)
        try statement.bind(record.planPayload, at: 5)
        try statement.bind(record.preflightPayload, at: 6)
        try statement.bind(record.runtimePayload, at: 7)
        try statement.bind(record.createdAtMilliseconds, at: 8)
        try statement.bind(record.updatedAtMilliseconds, at: 9)
        do {
            guard try !statement.step() else { throw DistributionOperationStoreError.corruptRecord }
        } catch let error as DistributionOperationStoreError {
            throw error
        } catch {
            throw DistributionOperationStoreError.conflict
        }
        return record
    }

    func load(_ operationID: SSOTOperationID) throws -> DistributionOperationRecord {
        try loadOperation(operationID)
    }

    func loadOperation(_ operationID: SSOTOperationID) throws -> DistributionOperationRecord {
        let statement = try connection.prepare(Self.selectSQL + " AND operation_id = ?")
        try statement.bind(operationID.bytes, at: 1)
        guard try statement.step() else { throw DistributionOperationStoreError.operationNotFound }
        let record = try decode(statement)
        guard try !statement.step() else { throw DistributionOperationStoreError.corruptRecord }
        return record
    }

    func recoverableOperations() throws -> [DistributionOperationRecord] {
        try loadMany(
            "outcome IS NULL AND phase <> 'completed' ORDER BY created_at_ms, operation_id"
        )
    }

    func recoverableOperationIDs() throws -> [SSOTOperationID] {
        try recoverableOperations().map(\.operationID)
    }

    func repairRequiredOperations() throws -> [DistributionOperationRecord] {
        try loadMany("outcome = 'needsRepair' ORDER BY created_at_ms, operation_id")
    }

    func updateProgress(
        operationID: SSOTOperationID,
        phase: DistributionOperationPhase,
        forwardCursor: Int64,
        rollbackCursor: Int64,
        cleanupCursor: Int64,
        runtimePayload: Data,
        attemptCount: Int64,
        lastError: String?,
        updatedAtMilliseconds: Int64
    ) throws {
        let current = try loadOperation(operationID)
        guard phaseTransitionAllowed(from: current.phase, to: phase) else {
            throw DistributionOperationStoreError.conflict
        }
        let actionCount = try filesystemActionCount(in: current.planPayload)
        guard forwardCursor <= actionCount,
              rollbackCursor <= actionCount,
              cleanupCursor <= actionCount,
              forwardCursor >= current.forwardCursor,
              rollbackCursor >= current.rollbackCursor,
              cleanupCursor >= current.cleanupCursor,
              attemptCount >= current.attemptCount,
              updatedAtMilliseconds >= current.updatedAtMilliseconds else {
            throw DistributionOperationStoreError.invalidRecord
        }
        switch phase {
        case .applying, .rollingBack:
            guard cleanupCursor == 0 else {
                throw DistributionOperationStoreError.invalidRecord
            }
        case .filesystemApplied, .databaseCommitted:
            guard forwardCursor == actionCount, rollbackCursor == 0, cleanupCursor == 0 else {
                throw DistributionOperationStoreError.invalidRecord
            }
        case .cleaning:
            guard forwardCursor == actionCount, rollbackCursor == 0 else {
                throw DistributionOperationStoreError.invalidRecord
            }
        case .prepared, .completed:
            throw DistributionOperationStoreError.conflict
        }
        try DistributionOperationRecord.validate(
            oldBindings: Data("[]".utf8), newBindings: Data("[]".utf8), planPayload: Data("{}".utf8),
            preflightPayload: Data("[]".utf8), runtimePayload: runtimePayload,
            forwardCursor: forwardCursor, rollbackCursor: rollbackCursor,
            cleanupCursor: cleanupCursor, attemptCount: attemptCount, lastError: lastError,
            createdAtMilliseconds: 0, updatedAtMilliseconds: updatedAtMilliseconds,
            phase: phase, outcome: nil
        )
        try DistributionOperationPayloadValidator.validateRuntime(
            runtimePayload,
            planData: current.planPayload,
            preflightData: current.preflightPayload,
            forwardCursor: forwardCursor,
            rollbackCursor: rollbackCursor,
            cleanupCursor: cleanupCursor,
            phase: phase
        )
        let statement = try connection.prepare(
            """
            UPDATE distribution_operations
            SET phase = ?, runtime_payload = ?, forward_cursor = ?,
                rollback_cursor = ?, cleanup_cursor = ?, attempt_count = ?,
                last_error = ?, updated_at_ms = ?
            WHERE operation_id = ? AND outcome IS NULL AND phase <> 'completed'
            """
        )
        try statement.bind(phase.rawValue, at: 1)
        try statement.bind(runtimePayload, at: 2)
        try statement.bind(forwardCursor, at: 3)
        try statement.bind(rollbackCursor, at: 4)
        try statement.bind(cleanupCursor, at: 5)
        try statement.bind(attemptCount, at: 6)
        if let lastError { try statement.bind(lastError, at: 7) } else { try statement.bindNull(at: 7) }
        try statement.bind(updatedAtMilliseconds, at: 8)
        try statement.bind(operationID.bytes, at: 9)
        try finishMutation(statement)
    }

    private func phaseTransitionAllowed(
        from old: DistributionOperationPhase,
        to new: DistributionOperationPhase
    ) -> Bool {
        switch (old, new) {
        case (.prepared, .applying), (.prepared, .rollingBack),
             (.applying, .applying), (.applying, .filesystemApplied),
             (.applying, .rollingBack), (.filesystemApplied, .databaseCommitted),
             (.filesystemApplied, .rollingBack),
             (.databaseCommitted, .cleaning), (.cleaning, .cleaning),
             (.rollingBack, .rollingBack), (.rollingBack, .completed):
            true
        default:
            false
        }
    }

    private func filesystemActionCount(in payload: Data) throws -> Int64 {
        guard let object = try JSONSerialization.jsonObject(with: payload)
                as? [String: Any] else {
            throw DistributionOperationStoreError.corruptRecord
        }
        guard let actions = object["filesystem_actions"] as? [Any] else {
            return 0
        }
        return Int64(actions.count)
    }

    func markNeedsRepair(
        operationID: SSOTOperationID,
        detail: String,
        updatedAtMilliseconds: Int64
    ) throws {
        guard detail.utf8.count <= 4_096, updatedAtMilliseconds >= 0 else {
            throw DistributionOperationStoreError.invalidRecord
        }
        let statement = try connection.prepare(
            """
            UPDATE distribution_operations
            SET outcome = 'needsRepair', attempt_count = attempt_count + 1,
                last_error = ?, updated_at_ms = MAX(updated_at_ms, ?)
            WHERE operation_id = ? AND outcome IS NULL AND phase <> 'completed'
            """
        )
        try statement.bind(detail, at: 1)
        try statement.bind(updatedAtMilliseconds, at: 2)
        try statement.bind(operationID.bytes, at: 3)
        try finishMutation(statement)
    }

    func complete(
        operationID: SSOTOperationID,
        outcome: DistributionOperationOutcome,
        updatedAtMilliseconds: Int64
    ) throws {
        guard outcome == .applied || outcome == .rolledBack,
              updatedAtMilliseconds >= 0 else {
            throw DistributionOperationStoreError.invalidRecord
        }
        let current = try loadOperation(operationID)
        switch (outcome, current.phase) {
        case (.applied, .cleaning):
            break
        case (.rolledBack, .rollingBack):
            guard current.rollbackCursor >= current.forwardCursor else {
                throw DistributionOperationStoreError.conflict
            }
        default:
            throw DistributionOperationStoreError.conflict
        }
        let statement = try connection.prepare(
            """
            UPDATE distribution_operations
            SET phase = 'completed', outcome = ?, updated_at_ms = MAX(updated_at_ms, ?)
            WHERE operation_id = ? AND outcome IS NULL AND phase = ?
            """
        )
        try statement.bind(outcome.rawValue, at: 1)
        try statement.bind(updatedAtMilliseconds, at: 2)
        try statement.bind(operationID.bytes, at: 3)
        try statement.bind(current.phase.rawValue, at: 4)
        try finishMutation(statement)
    }

    func transaction<T>(_ body: () throws -> T) throws -> T {
        try connection.withImmediateTransaction(body)
    }

    private func loadMany(_ suffix: String) throws -> [DistributionOperationRecord] {
        let statement = try connection.prepare(Self.selectSQL + " AND " + suffix)
        var records: [DistributionOperationRecord] = []
        while try statement.step() { records.append(try decode(statement)) }
        return records
    }

    private func decode(_ statement: SQLiteStatement) throws -> DistributionOperationRecord {
        do {
            let phase = try distributionRequiredEnum(statement, 3, as: DistributionOperationPhase.self)
            let outcome = try distributionOptionalEnum(
                statement.text(at: 4), as: DistributionOperationOutcome.self
            )
            let record = DistributionOperationRecord(
                operationID: try SSOTOperationID(bytes: distributionRequiredBlob(statement, 0)),
                skillID: try SkillID(bytes: distributionRequiredBlob(statement, 2)),
                phase: phase,
                outcome: outcome,
                oldBindings: try distributionRequiredBlob(statement, 5),
                newBindings: try distributionRequiredBlob(statement, 6),
                planPayload: try distributionRequiredBlob(statement, 7),
                preflightPayload: try distributionRequiredBlob(statement, 8),
                runtimePayload: try distributionRequiredBlob(statement, 9),
                forwardCursor: statement.int64(at: 10),
                rollbackCursor: statement.int64(at: 11),
                cleanupCursor: statement.int64(at: 12),
                attemptCount: statement.int64(at: 13),
                lastError: statement.text(at: 14),
                createdAtMilliseconds: statement.int64(at: 15),
                updatedAtMilliseconds: statement.int64(at: 16)
            )
            try DistributionOperationRecord.validate(
                oldBindings: record.oldBindings, newBindings: record.newBindings,
                planPayload: record.planPayload, preflightPayload: record.preflightPayload,
                runtimePayload: record.runtimePayload, forwardCursor: record.forwardCursor,
                rollbackCursor: record.rollbackCursor, cleanupCursor: record.cleanupCursor,
                attemptCount: record.attemptCount, lastError: record.lastError,
                createdAtMilliseconds: record.createdAtMilliseconds,
                updatedAtMilliseconds: record.updatedAtMilliseconds,
                phase: record.phase, outcome: record.outcome
            )
            try DistributionOperationPayloadValidator.validate(
                operationID: record.operationID,
                skillID: record.skillID,
                oldBindingsData: record.oldBindings,
                newBindingsData: record.newBindings,
                planData: record.planPayload,
                preflightData: record.preflightPayload,
                runtimeData: record.runtimePayload,
                phase: record.phase,
                forwardCursor: record.forwardCursor,
                rollbackCursor: record.rollbackCursor,
                cleanupCursor: record.cleanupCursor
            )
            return record
        } catch let error as DistributionOperationStoreError {
            throw error
        } catch {
            throw DistributionOperationStoreError.corruptRecord
        }
    }

    private func finishMutation(_ statement: SQLiteStatement) throws {
        guard try !statement.step(),
              try connection.querySingleInt("SELECT changes()") == 1 else {
            throw DistributionOperationStoreError.conflict
        }
    }

    private static let selectSQL = """
    SELECT operation_id, format_version, skill_id, phase, outcome,
           old_bindings, new_bindings, plan_payload, preflight_payload, runtime_payload,
           forward_cursor, rollback_cursor, cleanup_cursor, attempt_count, last_error,
           created_at_ms, updated_at_ms
    FROM distribution_operations
    WHERE format_version = 1
    """
}

nonisolated func distributionRequiredBlob(
    _ statement: SQLiteStatement,
    _ column: Int32
) throws -> Data {
    guard let data = statement.blob(at: column) else {
        throw DistributionOperationStoreError.corruptRecord
    }
    return data
}

private nonisolated func distributionRequiredEnum<T: RawRepresentable>(
    _ statement: SQLiteStatement,
    _ column: Int32,
    as type: T.Type
) throws -> T where T.RawValue == String {
    guard let value = statement.text(at: column), let result = T(rawValue: value) else {
        throw DistributionOperationStoreError.corruptRecord
    }
    return result
}

private nonisolated func distributionOptionalEnum<T: RawRepresentable>(
    _ rawValue: String?,
    as type: T.Type
) throws -> T? where T.RawValue == String {
    guard let rawValue else { return nil }
    guard let result = T(rawValue: rawValue) else {
        throw DistributionOperationStoreError.corruptRecord
    }
    return result
}
