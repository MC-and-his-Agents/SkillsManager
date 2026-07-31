import Darwin
import Foundation

nonisolated struct SkillDiscoveryFileRevision: Hashable, Sendable {
    let identity: ManagedItemIdentity
    let modificationSeconds: Int64
    let modificationNanoseconds: Int64
    let statusChangeSeconds: Int64
    let statusChangeNanoseconds: Int64

    init(_ metadata: stat) {
        identity = ManagedItemIdentity(metadata)
        modificationSeconds = Int64(metadata.st_mtimespec.tv_sec)
        modificationNanoseconds = Int64(metadata.st_mtimespec.tv_nsec)
        statusChangeSeconds = Int64(metadata.st_ctimespec.tv_sec)
        statusChangeNanoseconds = Int64(metadata.st_ctimespec.tv_nsec)
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

}

nonisolated struct SkillDiscoveryLocationRevision: Hashable, Sendable {
    let root: SkillDiscoveryFileRevision
    let container: SkillDiscoveryFileRevision?
    let candidate: SkillDiscoveryFileRevision?
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
