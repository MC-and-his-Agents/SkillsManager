import Foundation

nonisolated extension CopyForkOperationStore {
    func requiredBaseline(_ binding: DistributionBinding) throws
        -> DistributionCopyBaseline
    {
        guard binding.syncMode == .copy, let baseline = binding.copyBaseline else {
            throw CopyForkOperationStoreError.corruptRecord
        }
        return baseline
    }

    func bindProvenance(
        _ provenance: DistributionCopyBaseline.Provenance,
        to statement: SQLiteStatement,
        kindAt index: Int32
    ) throws {
        switch provenance {
        case .distribution(let operationID):
            try statement.bind("distribution", at: index)
            try statement.bind(operationID.bytes, at: index + 1)
        case .copyFork(let operationID):
            try statement.bind("copyFork", at: index)
            try statement.bind(operationID.bytes, at: index + 1)
        }
    }

    func bindBaseline(
        _ baseline: DistributionCopyBaseline,
        to statement: SQLiteStatement,
        startingAt index: Int32
    ) throws {
        try statement.bind(Int64(baseline.contentFingerprint.algorithmVersion), at: index)
        try statement.bind(baseline.contentFingerprint.digest, at: index + 1)
        try statement.bind(Int64(baseline.physicalTreeDigest.algorithmVersion), at: index + 2)
        try statement.bind(baseline.physicalTreeDigest.digest, at: index + 3)
        try statement.bind(ManagedItemIdentityCodec.encode(baseline.rootIdentity), at: index + 4)
        try statement.bind(ManagedItemIdentityCodec.encode(baseline.entryIdentity), at: index + 5)
        try statement.bind(baseline.verifiedAtMilliseconds, at: index + 6)
    }

    func bindEvidence(
        _ evidence: DistributionCopyEvidence,
        to statement: SQLiteStatement,
        startingAt index: Int32
    ) throws {
        try statement.bind(Int64(evidence.contentFingerprint.algorithmVersion), at: index)
        try statement.bind(evidence.contentFingerprint.digest, at: index + 1)
        try statement.bind(Int64(evidence.physicalTreeDigest.algorithmVersion), at: index + 2)
        try statement.bind(evidence.physicalTreeDigest.digest, at: index + 3)
        try statement.bind(ManagedItemIdentityCodec.encode(evidence.rootIdentity), at: index + 4)
        try statement.bind(ManagedItemIdentityCodec.encode(evidence.entryIdentity), at: index + 5)
    }

    func decodeScope(
        _ statement: SQLiteStatement,
        kindAt kindIndex: Int32,
        adapterAt adapterIndex: Int32,
        keyAt keyIndex: Int32
    ) throws -> DistributionBindingScope {
        let scope: DistributionBindingScope
        switch try requiredText(statement, kindIndex) {
        case "global":
            guard statement.isNull(at: adapterIndex) else {
                throw CopyForkOperationStoreError.corruptRecord
            }
            scope = .global
        case "agent":
            guard let code = statement.text(at: adapterIndex),
                  let adapter = SkillPlatform.allCases.first(where: {
                      $0.storageKey == code
                  }) else {
                throw CopyForkOperationStoreError.corruptRecord
            }
            scope = .agent(adapter)
        default:
            throw CopyForkOperationStoreError.corruptRecord
        }
        guard scope.targetScopeKey == (try requiredText(statement, keyIndex)) else {
            throw CopyForkOperationStoreError.corruptRecord
        }
        return scope
    }

    func decodeProvenance(
        _ statement: SQLiteStatement,
        kindAt kindIndex: Int32,
        idAt idIndex: Int32
    ) throws -> DistributionCopyBaseline.Provenance {
        let operationID = try SSOTOperationID(bytes: requiredBlob(statement, idIndex))
        return switch try requiredText(statement, kindIndex) {
        case "distribution": .distribution(operationID)
        case "copyFork": .copyFork(operationID)
        default: throw CopyForkOperationStoreError.corruptRecord
        }
    }

    func requiredBlob(_ statement: SQLiteStatement, _ index: Int32) throws -> Data {
        guard let value = statement.blob(at: index) else {
            throw CopyForkOperationStoreError.corruptRecord
        }
        return value
    }

    func requiredText(_ statement: SQLiteStatement, _ index: Int32) throws -> String {
        guard let value = statement.text(at: index) else {
            throw CopyForkOperationStoreError.corruptRecord
        }
        return value
    }

    func requiredEnum<T: RawRepresentable>(
        _ statement: SQLiteStatement,
        _ index: Int32,
        as type: T.Type
    ) throws -> T where T.RawValue == String {
        guard let value = T(rawValue: try requiredText(statement, index)) else {
            throw CopyForkOperationStoreError.corruptRecord
        }
        return value
    }

    func optionalEnum<T: RawRepresentable>(
        _ statement: SQLiteStatement,
        _ index: Int32,
        as type: T.Type
    ) throws -> T? where T.RawValue == String {
        guard let raw = statement.text(at: index) else { return nil }
        guard let value = T(rawValue: raw) else {
            throw CopyForkOperationStoreError.corruptRecord
        }
        return value
    }

    func finishExactlyOne(_ statement: SQLiteStatement) throws {
        do {
            guard try !statement.step(),
                  try connection.querySingleInt("SELECT changes()") == 1 else {
                throw CopyForkOperationStoreError.conflict
            }
        } catch let error as CopyForkOperationStoreError {
            throw error
        } catch {
            throw CopyForkOperationStoreError.conflict
        }
    }
}
