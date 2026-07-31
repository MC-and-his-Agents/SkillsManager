import Darwin
import Foundation

extension ManagedSkillImportService {
    func captureSnapshot(_ pending: Pending) throws -> SkillContentSnapshot {
        do {
            guard let firstRoot = pending.roots.first else {
                throw ManagedSkillImportError.invalidObservation
            }
            let verifiedRoots = try pending.roots.map { try $0.reference.verifiedRoot() }
            guard verifiedRoots.allSatisfy({ $0.identity == pending.rootIdentity }) else {
                throw ManagedSkillImportError.sourceChanged
            }

            let rootDescriptor = Darwin.open(
                firstRoot.reference.canonicalURL.path,
                O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC
            )
            guard rootDescriptor >= 0 else {
                throw ManagedSkillImportError.sourceChanged
            }
            defer { Darwin.close(rootDescriptor) }
            guard SkillDiscoveryFileRevision(descriptor: rootDescriptor)
                    == pending.locationRevision.root else {
                throw ManagedSkillImportError.sourceChanged
            }

            let candidateDescriptor = try openCandidate(pending, in: rootDescriptor)
            defer { Darwin.close(candidateDescriptor) }
            let snapshot = try SkillContentSnapshot.capture(
                directoryDescriptor: candidateDescriptor,
                displayPath: pending.locator.normalizedValue,
                limits: limits,
                checkpoint: { try Task.checkCancellation() }
            )
            _ = try snapshot.readUTF8File(
                relativePath: "SKILL.md",
                checkpoint: { try Task.checkCancellation() }
            )
            guard SkillDiscoveryFileRevision(descriptor: candidateDescriptor)
                    == pending.locationRevision.candidate,
                  try SkillContentFingerprint(currentDigest: snapshot.fingerprintDigest)
                    == pending.fingerprint else {
                throw ManagedSkillImportError.sourceChanged
            }
            try revalidateLocation(pending, rootDescriptor: rootDescriptor)
            return snapshot
        } catch is CancellationError {
            throw CancellationError()
        } catch let error as ManagedSkillImportError {
            throw error
        } catch {
            throw ManagedSkillImportError.sourceChanged
        }
    }

    private func openCandidate(_ pending: Pending, in rootDescriptor: Int32) throws -> Int32 {
        if let candidateReference = pending.candidateReference {
            guard pending.locator.rawComponents.count == 1,
                  let expectedLink = pending.symbolicLinkIdentity,
                  try namedIdentity(
                    pending.locator.rawComponents[0],
                    in: rootDescriptor
                  ) == expectedLink else {
                throw ManagedSkillImportError.sourceChanged
            }
            let verified = try candidateReference.verifiedRoot()
            guard verified.identity == pending.candidateIdentity else {
                throw ManagedSkillImportError.sourceChanged
            }
            return try openDirectory(at: verified.url.path)
        }

        let components = pending.locator.rawComponents
        try requireUniqueEntry(
            rawName: components[0],
            collisionKey: pending.locator.collisionKeys[0],
            in: rootDescriptor
        )
        if components.count == 1 {
            return try openDirectory(named: components[0], in: rootDescriptor)
        }

        guard let expectedContainer = pending.locationRevision.container else {
            throw ManagedSkillImportError.invalidObservation
        }
        let containerDescriptor = try openDirectory(named: components[0], in: rootDescriptor)
        defer { Darwin.close(containerDescriptor) }
        guard SkillDiscoveryFileRevision(descriptor: containerDescriptor) == expectedContainer else {
            throw ManagedSkillImportError.sourceChanged
        }
        try requireUniqueEntry(
            rawName: components[1],
            collisionKey: pending.locator.collisionKeys[1],
            in: containerDescriptor
        )
        return try openDirectory(named: components[1], in: containerDescriptor)
    }

    private func revalidateLocation(
        _ pending: Pending,
        rootDescriptor: Int32
    ) throws {
        guard SkillDiscoveryFileRevision(descriptor: rootDescriptor)
                == pending.locationRevision.root,
              try pending.roots.allSatisfy({
                  try $0.reference.verifiedRoot().identity == pending.rootIdentity
              }) else {
            throw ManagedSkillImportError.sourceChanged
        }
        let candidateDescriptor = try openCandidate(pending, in: rootDescriptor)
        defer { Darwin.close(candidateDescriptor) }
        guard SkillDiscoveryFileRevision(descriptor: candidateDescriptor)
                == pending.locationRevision.candidate else {
            throw ManagedSkillImportError.sourceChanged
        }
    }

    private func requireUniqueEntry(
        rawName: String,
        collisionKey: String,
        in descriptor: Int32
    ) throws {
        let matches = try SafeSourceTree.names(in: descriptor, displayPath: rawName).filter {
            guard let normalized = SkillContentPath.visibleDirectoryName($0) else {
                return false
            }
            return SkillContentPath.collisionKey(for: normalized) == collisionKey
        }
        guard matches.count == 1, matches[0] == rawName else {
            throw ManagedSkillImportError.conflict
        }
    }

    private func openDirectory(named name: String, in descriptor: Int32) throws -> Int32 {
        let opened = Darwin.openat(
            descriptor,
            name,
            O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC
        )
        guard opened >= 0 else {
            throw ManagedSkillImportError.sourceChanged
        }
        return opened
    }

    private func openDirectory(at path: String) throws -> Int32 {
        let opened = Darwin.open(
            path,
            O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC
        )
        guard opened >= 0 else {
            throw ManagedSkillImportError.sourceChanged
        }
        return opened
    }

    func namedIdentity(at url: URL) throws -> ManagedItemIdentity {
        var metadata = stat()
        guard Darwin.lstat(url.path, &metadata) == 0 else {
            throw ManagedSkillImportError.sourceChanged
        }
        return ManagedItemIdentity(metadata)
    }

    private func namedIdentity(
        _ name: String,
        in descriptor: Int32
    ) throws -> ManagedItemIdentity {
        var metadata = stat()
        guard Darwin.fstatat(descriptor, name, &metadata, AT_SYMLINK_NOFOLLOW) == 0 else {
            throw ManagedSkillImportError.sourceChanged
        }
        return ManagedItemIdentity(metadata)
    }
}
