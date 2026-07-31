import Darwin
import Testing

@testable import SkillsManager

extension SkillConsistencyAuditTests {
    @Test("canonical discovery evidence distinguishes a direct directory from a link")
    func symlinkIdentityChangesCanonicalEvidence() throws {
        let workspace = try WriterWorkspace()
        let verified = try ManagedRootReference.capture(at: workspace.root).verifiedRoot()
        let root = SkillDiscoveryRoot(scope: .global, url: workspace.root)
        let direct = auditSymlinkObservation(
            root: root,
            identity: verified.identity,
            symbolicLinkIdentity: nil
        )
        let link = auditSymlinkObservation(
            root: root,
            identity: verified.identity,
            symbolicLinkIdentity: ManagedItemIdentity(
                persistedComponents: .init(
                    device: 1,
                    inode: 9,
                    fileType: UInt32(S_IFLNK),
                    generation: 0
                )
            )
        )

        let directBytes = try SkillConsistencyAuditManifestCodec.encode(
            SkillConsistencyAuditWire.discoveryObservation(direct)
        )
        let linkBytes = try SkillConsistencyAuditManifestCodec.encode(
            SkillConsistencyAuditWire.discoveryObservation(link)
        )

        #expect(directBytes != linkBytes)
    }
}

private func auditSymlinkObservation(
    root: SkillDiscoveryRoot,
    identity: ManagedItemIdentity,
    symbolicLinkIdentity: ManagedItemIdentity?
) -> SkillDiscoveryObservation {
    SkillDiscoveryObservation(
        roots: [root],
        rootIdentity: identity,
        rawRelativeLocator: "demo",
        relativeLocator: "demo",
        relativeLocatorKey: "demo",
        candidateIdentity: identity,
        symbolicLinkIdentity: symbolicLinkIdentity,
        fingerprint: nil,
        providerAliases: [],
        status: .conflict,
        reason: .scopeSlugConflict,
        matchedSkillID: nil,
        matchedSourceKey: nil
    )
}
