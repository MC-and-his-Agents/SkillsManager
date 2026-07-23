import Darwin
import Foundation

nonisolated struct SkillDiscoveryFileRevision: Equatable {
    let identity: ManagedItemIdentity
    let modification: timespec
    let statusChange: timespec

    init(_ metadata: stat) {
        identity = ManagedItemIdentity(metadata)
        modification = metadata.st_mtimespec
        statusChange = metadata.st_ctimespec
    }

    init?(descriptor: Int32) {
        var metadata = stat()
        guard Darwin.fstat(descriptor, &metadata) == 0 else { return nil }
        self.init(metadata)
    }

    init?(named name: String, in directoryDescriptor: Int32) {
        var metadata = stat()
        guard Darwin.fstatat(
            directoryDescriptor,
            name,
            &metadata,
            AT_SYMLINK_NOFOLLOW
        ) == 0 else {
            return nil
        }
        self.init(metadata)
    }

    static func == (lhs: SkillDiscoveryFileRevision, rhs: SkillDiscoveryFileRevision) -> Bool {
        lhs.identity == rhs.identity
            && lhs.modification.tv_sec == rhs.modification.tv_sec
            && lhs.modification.tv_nsec == rhs.modification.tv_nsec
            && lhs.statusChange.tv_sec == rhs.statusChange.tv_sec
            && lhs.statusChange.tv_nsec == rhs.statusChange.tv_nsec
    }
}

nonisolated struct SkillDiscoveryProviderMetadataReader {
    func aliases(
        in candidateDescriptor: Int32,
        expectedCandidate: SkillDiscoveryFileRevision,
        checkpoint: SkillCancellationCheckpoint
    ) throws -> Set<ProviderAliasIdentity> {
        try checkpoint()
        let data = boundedMetadata(
            directory: ".clawdhub",
            file: "origin.json",
            in: candidateDescriptor,
            maximumBytes: 64 * 1_024
        )
        guard SkillDiscoveryFileRevision(descriptor: candidateDescriptor) == expectedCandidate else {
            throw SkillContentSnapshotError.fileChanged(path: ".clawdhub/origin.json")
        }
        guard let data,
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
        object["source"] as? String == "clawdhub",
        let slug = object["slug"] as? String,
        let alias = try? ProviderAliasIdentity(provider: "clawdhub", identifier: slug) else {
            return []
        }
        return [alias]
    }

    private func boundedMetadata(
        directory: String,
        file: String,
        in candidateDescriptor: Int32,
        maximumBytes: Int
    ) -> Data? {
        let directoryDescriptor = Darwin.openat(
            candidateDescriptor,
            directory,
            O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC
        )
        guard directoryDescriptor >= 0 else { return nil }
        defer { Darwin.close(directoryDescriptor) }
        let fileDescriptor = Darwin.openat(
            directoryDescriptor,
            file,
            O_RDONLY | O_NOFOLLOW | O_CLOEXEC
        )
        guard fileDescriptor >= 0 else { return nil }
        defer { Darwin.close(fileDescriptor) }

        var before = stat()
        guard Darwin.fstat(fileDescriptor, &before) == 0,
              before.st_mode & mode_t(S_IFMT) == S_IFREG,
              before.st_size >= 0,
              before.st_size <= maximumBytes,
              let data = readExactly(Int(before.st_size), from: fileDescriptor) else {
            return nil
        }
        var after = stat()
        guard Darwin.fstat(fileDescriptor, &after) == 0,
              SkillDiscoveryFileRevision(before) == SkillDiscoveryFileRevision(after) else {
            return nil
        }
        return data
    }

    private func readExactly(_ byteCount: Int, from descriptor: Int32) -> Data? {
        var data = Data(count: byteCount)
        var offset = 0
        while offset < byteCount {
            let count = data.withUnsafeMutableBytes { buffer in
                Darwin.pread(
                    descriptor,
                    buffer.baseAddress?.advanced(by: offset),
                    byteCount - offset,
                    off_t(offset)
                )
            }
            if count < 0 {
                if errno == EINTR { continue }
                return nil
            }
            if count == 0 { return nil }
            offset += count
        }
        return data
    }
}
