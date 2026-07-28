import Darwin
import Foundation
import Testing

@testable import SkillsManager

@Suite("Distribution operation payload v3")
struct DistributionOperationPayloadV3Tests {
    @Test("v2 rejects Copy Fork provenance while v3 preserves it canonically")
    func provenanceVersionBoundary() throws {
        let operationID = SSOTOperationID()
        let baseline = try distributionV3Baseline(
            provenance: .copyFork(operationID)
        )

        #expect(throws: DistributionOperationStoreError.invalidRecord) {
            _ = try DistributionCopyBaselineWireV2(baseline)
        }

        let binding = try DistributionBinding(
            skillID: SkillID(),
            scope: .global,
            distributionSlug: DefaultDistributionSlug(validating: "fork"),
            syncMode: .copy,
            copyBaseline: baseline,
            createdAtMilliseconds: 1,
            updatedAtMilliseconds: 1
        )
        let wire = try DistributionBindingWireV3(binding)
        let encoded = try DistributionOperationPayloadCodec.encode(wire)
        let decoded = try DistributionOperationPayloadCodec.decode(
            DistributionBindingWireV3.self,
            from: encoded
        )
        let readback = try decoded.binding(expectedSkillID: binding.skillID)

        #expect(readback == binding)
        #expect(readback.copyBaseline?.provenance == .copyFork(operationID))
        #expect(try DistributionOperationPayloadCodec.encode(decoded) == encoded)
    }

    @Test("v3 rejects missing, unknown and malformed provenance")
    func rejectsInvalidProvenance() throws {
        let binding = try DistributionBinding(
            skillID: SkillID(),
            scope: .global,
            distributionSlug: DefaultDistributionSlug(validating: "fork"),
            syncMode: .copy,
            copyBaseline: distributionV3Baseline(
                provenance: .copyFork(SSOTOperationID())
            ),
            createdAtMilliseconds: 1,
            updatedAtMilliseconds: 1
        )
        let data = try DistributionOperationPayloadCodec.encode(
            DistributionBindingWireV3(binding)
        )
        var object = try #require(
            JSONSerialization.jsonObject(with: data) as? [String: Any]
        )
        var baseline = try #require(object["copyBaseline"] as? [String: Any])
        var provenance = try #require(baseline["provenance"] as? [String: Any])
        provenance["kind"] = "unknown"
        baseline["provenance"] = provenance
        object["copyBaseline"] = baseline
        let unknown = try JSONSerialization.data(
            withJSONObject: object,
            options: [.sortedKeys, .withoutEscapingSlashes]
        )
        let unknownWire = try DistributionOperationPayloadCodec.decode(
            DistributionBindingWireV3.self,
            from: unknown
        )
        #expect(throws: DistributionOperationStoreError.invalidRecord) {
            _ = try unknownWire.binding(expectedSkillID: binding.skillID)
        }

        baseline.removeValue(forKey: "provenance")
        object["copyBaseline"] = baseline
        let missing = try JSONSerialization.data(
            withJSONObject: object,
            options: [.sortedKeys, .withoutEscapingSlashes]
        )
        #expect(throws: DecodingError.self) {
            _ = try DistributionOperationPayloadCodec.decode(
                DistributionBindingWireV3.self,
                from: missing
            )
        }
    }
}

private func distributionV3Baseline(
    provenance: DistributionCopyBaseline.Provenance
) throws -> DistributionCopyBaseline {
    var metadata = stat()
    metadata.st_mode = mode_t(S_IFDIR | 0o700)
    let identity = ManagedItemIdentity(metadata)
    return try DistributionCopyBaseline(
        contentFingerprint: SkillContentFingerprint(
            currentDigest: Data(repeating: 0x11, count: 32)
        ),
        physicalTreeDigest: CopyPhysicalTreeDigest(
            digest: Data(repeating: 0x22, count: 32)
        ),
        rootIdentity: identity,
        entryIdentity: identity,
        provenance: provenance,
        verifiedAtMilliseconds: 1
    )
}
