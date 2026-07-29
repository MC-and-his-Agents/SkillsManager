import Darwin
import Foundation
import ZIPFoundation

nonisolated extension SafeSkillArchive {
    struct RepositoryBlobExpectation: Hashable, Sendable {
        let relativePath: String
        let mode: String
        let byteCount: UInt64
        let gitBlobSHA: String

        init(
            relativePath: String,
            mode: String,
            byteCount: UInt64,
            gitBlobSHA: String
        ) throws {
            let path = try RepositorySubpath(relativePath)
            guard !path.value.isEmpty,
                  path.value == relativePath,
                  path.value.split(separator: "/").allSatisfy({
                      SafeSkillArchive.isSafeRepositoryComponent(String($0))
                  }),
                  mode == "100644" || mode == "100755",
                  gitBlobSHA.count == 40,
                  gitBlobSHA.utf8.allSatisfy({
                      (UInt8(ascii: "0")...UInt8(ascii: "9")).contains($0)
                          || (UInt8(ascii: "a")...UInt8(ascii: "f")).contains($0)
                  }) else {
                throw SafeSkillArchiveError.invalidRepositorySubtree
            }
            self.relativePath = relativePath
            self.mode = mode
            self.byteCount = byteCount
            self.gitBlobSHA = gitBlobSHA
        }
    }

    @discardableResult
    func extractRepositorySubtree(
        archiveAt archiveURL: URL,
        expectedArchiveIdentity: ManagedItemIdentity? = nil,
        repositorySubpath: RepositorySubpath,
        expectedBlobs: [RepositoryBlobExpectation],
        toDirectoryDescriptor destinationDescriptor: Int32,
        checkpoint: SkillCancellationCheckpoint = {}
    ) throws -> [String] {
        let rootDescriptor = try duplicateEmptyDestination(destinationDescriptor)
        defer { Darwin.close(rootDescriptor) }
        let rollbackJournal = try SafeSkillArchiveRollbackJournal(rootDescriptor: rootDescriptor)
        do {
            let snapshot = try ZIPArchiveSnapshot(
                copying: archiveURL,
                expectedSourceIdentity: expectedArchiveIdentity,
                into: rootDescriptor,
                maximumByteCount: limits.maximumArchiveByteCount,
                checkpoint: checkpoint
            )
            let rawKinds = try ZIPCentralDirectory.entryKinds(
                in: snapshot.handle,
                maximumEntryCount: limits.maximumEntryCount,
                checkpoint: checkpoint
            )
            let archive = try Archive(url: snapshot.descriptorURL, accessMode: .read)
            let entries = try validate(
                entries: Array(archive),
                rawKinds: rawKinds,
                checkpoint: checkpoint,
                enforceContentLimits: false
            )
            let selected = try repositoryFiles(
                in: entries,
                repositorySubpath: repositorySubpath,
                expectedBlobs: expectedBlobs
            )
            var actualTotalSize: UInt64 = 0
            for (item, expectation, outputComponents) in selected {
                try checkpoint()
                try extractFile(
                    item,
                    from: archive,
                    rollbackJournal: rollbackJournal,
                    actualTotalSize: &actualTotalSize,
                    checkpoint: checkpoint,
                    outputComponents: outputComponents,
                    expectedGitBlobSHA: expectation.gitBlobSHA
                )
            }
            return selected.map { $0.outputComponents.joined(separator: "/") }
        } catch {
            rollbackJournal.rollback()
            throw error
        }
    }

    private func repositoryFiles(
        in entries: [ValidatedEntry],
        repositorySubpath: RepositorySubpath,
        expectedBlobs: [RepositoryBlobExpectation]
    ) throws -> [(
        item: ValidatedEntry,
        expectation: RepositoryBlobExpectation,
        outputComponents: [String]
    )] {
        let subtree = repositorySubpath.value.split(separator: "/").map(String.init)
        guard !subtree.isEmpty,
              subtree.allSatisfy(Self.isSafeRepositoryComponent),
              let wrapper = entries.first?.components.first,
              entries.allSatisfy({
                  $0.components.first == wrapper
                      && $0.components.allSatisfy(Self.isSafeRepositoryComponent)
              }) else {
            throw SafeSkillArchiveError.invalidRepositorySubtree
        }
        let expectations = try validatedExpectations(expectedBlobs)
        let prefix = [wrapper] + subtree
        var selected: [(
            item: ValidatedEntry,
            expectation: RepositoryBlobExpectation,
            outputComponents: [String]
        )] = []
        var actualPaths: Set<String> = []
        for item in entries where item.components.starts(with: prefix) {
            let outputComponents = Array(item.components.dropFirst(prefix.count))
            if outputComponents.isEmpty {
                guard item.kind == .directory else {
                    throw SafeSkillArchiveError.repositorySubtreeMismatch(item.entry.path)
                }
                continue
            }
            guard item.kind == .file else { continue }
            let relativePath = outputComponents.joined(separator: "/")
            guard let expectation = expectations[relativePath],
                  actualPaths.insert(relativePath).inserted,
                  item.entry.uncompressedSize == expectation.byteCount,
                  archiveMode(of: item.entry) == expectation.mode else {
                throw SafeSkillArchiveError.repositorySubtreeMismatch(item.entry.path)
            }
            selected.append((item, expectation, outputComponents))
        }
        guard actualPaths == Set(expectations.keys) else {
            throw SafeSkillArchiveError.repositorySubtreeMismatch(repositorySubpath.value)
        }
        return selected
    }

    private func validatedExpectations(
        _ expectations: [RepositoryBlobExpectation]
    ) throws -> [String: RepositoryBlobExpectation] {
        guard !expectations.isEmpty,
              expectations.contains(where: { $0.relativePath == "SKILL.md" }),
              expectations.count <= limits.content.maximumFileCount else {
            throw SafeSkillArchiveError.invalidRepositorySubtree
        }
        var paths: [String: RepositoryBlobExpectation] = [:]
        var collisionPaths: [String: String] = [:]
        var directoryKeys: Set<String> = []
        var total: UInt64 = 0
        for expectation in expectations {
            let components = expectation.relativePath.split(separator: "/").map(String.init)
            guard components.count <= limits.content.maximumPathDepth,
                  expectation.byteCount <= limits.content.maximumFileByteCount else {
                throw SafeSkillArchiveError.invalidRepositorySubtree
            }
            let collisionKey = components
                .map(SkillContentPath.collisionKey(for:))
                .joined(separator: "/")
            guard paths.updateValue(expectation, forKey: expectation.relativePath) == nil,
                  collisionPaths.updateValue(expectation.relativePath, forKey: collisionKey) == nil else {
                throw SafeSkillArchiveError.invalidRepositorySubtree
            }
            for end in 1..<components.count {
                directoryKeys.insert(
                    components[..<end].map(SkillContentPath.collisionKey(for:)).joined(separator: "/")
                )
            }
            let (newTotal, overflow) = total.addingReportingOverflow(expectation.byteCount)
            guard !overflow, newTotal <= limits.content.maximumTotalByteCount else {
                throw SafeSkillArchiveError.invalidRepositorySubtree
            }
            total = newTotal
        }
        guard directoryKeys.count <= limits.content.maximumDirectoryCount else {
            throw SafeSkillArchiveError.invalidRepositorySubtree
        }
        for path in paths.keys {
            var components = path.split(separator: "/").map(String.init)
            while components.count > 1 {
                components.removeLast()
                guard paths[components.joined(separator: "/")] == nil else {
                    throw SafeSkillArchiveError.invalidRepositorySubtree
                }
            }
        }
        return paths
    }

    private func archiveMode(of entry: Entry) -> String? {
        guard let raw = entry.fileAttributes[.posixPermissions] as? NSNumber else { return nil }
        switch raw.uint16Value & 0o777 {
        case 0o644: return "100644"
        case 0o755: return "100755"
        default: return nil
        }
    }

    private static func isSafeRepositoryComponent(_ component: String) -> Bool {
        !component.contains("%")
            && !component.unicodeScalars.contains(where: {
                CharacterSet.controlCharacters.contains($0)
            })
    }
}
