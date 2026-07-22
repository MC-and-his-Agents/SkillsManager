import Foundation

actor SkillFileWorker {
    struct InstallDestination: Sendable {
        let rootURL: URL
        let storageKey: String
        let managedRoot: ManagedRootReference?

        init(
            rootURL: URL,
            storageKey: String,
            managedRoot: ManagedRootReference? = nil
        ) {
            self.rootURL = rootURL
            self.storageKey = storageKey
            self.managedRoot = managedRoot
        }
    }

    struct ScannedSkillData: Sendable {
        let id: String
        let name: String
        let displayName: String
        let description: String
        let managedRoot: ManagedRootReference
        let folderURL: URL
        let skillMarkdownURL: URL
        let references: [SkillReference]
        let stats: SkillStats
    }

    struct ClawdhubOrigin: Sendable {
        let slug: String
        let version: String?
    }

    func loadRawMarkdown(from zipURL: URL) throws -> String {
        let temporaryRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("skillsmanager-preview-\(UUID().uuidString)", isDirectory: true)
        defer {
            try? FileManager.default.removeItem(at: temporaryRoot)
            try? FileManager.default.removeItem(at: zipURL)
        }

        try FileManager.default.createDirectory(at: temporaryRoot, withIntermediateDirectories: true)
        do {
            try SafeSkillArchive().extract(
                archiveAt: zipURL,
                to: temporaryRoot,
                checkpoint: { try Task.checkCancellation() }
            )
        } catch let error as SafeSkillArchiveError {
            throw SkillImportValidationError.archiveRejected(error.localizedDescription)
        }
        let skillRoot = try SkillPackageLocator().locateSkillRoot(in: temporaryRoot)
        do {
            _ = try SkillContentSnapshot.capture(
                at: skillRoot,
                checkpoint: { try Task.checkCancellation() }
            )
        } catch let error as SkillContentSnapshotError {
            throw SkillImportValidationError.contentRejected(error.localizedDescription)
        }
        let skillFileURL = skillRoot.appendingPathComponent("SKILL.md")
        return try String(contentsOf: skillFileURL, encoding: .utf8)
    }

    func loadMarkdown(at url: URL) throws -> String {
        try String(contentsOf: url, encoding: .utf8)
    }

    func installRemoteSkill(
        zipURL: URL,
        slug: String,
        version: String?,
        destinations: [InstallDestination]
    ) throws -> String? {
        let temporaryRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("skillsmanager-remote-\(UUID().uuidString)", isDirectory: true)
        defer {
            try? FileManager.default.removeItem(at: temporaryRoot)
            try? FileManager.default.removeItem(at: zipURL)
        }

        try FileManager.default.createDirectory(at: temporaryRoot, withIntermediateDirectories: true)
        do {
            try SafeSkillArchive().extract(
                archiveAt: zipURL,
                to: temporaryRoot,
                checkpoint: { try Task.checkCancellation() }
            )
        } catch let error as SafeSkillArchiveError {
            throw SkillImportValidationError.archiveRejected(error.localizedDescription)
        }
        let skillRoot = try SkillPackageLocator().locateSkillRoot(in: temporaryRoot)
        let snapshot: SkillContentSnapshot
        do {
            snapshot = try SkillContentSnapshot.capture(
                at: skillRoot,
                checkpoint: { try Task.checkCancellation() }
            )
        } catch let error as SkillContentSnapshotError {
            throw SkillImportValidationError.contentRejected(error.localizedDescription)
        }

        let stager = SafeSkillStager()
        var installedStorageKeys: [String] = []
        for destination in destinations {
            do {
                _ = try stager.installArchive(
                    archiveAt: zipURL,
                    expectedFingerprint: snapshot.fingerprint,
                    destinationRoot: destination.rootURL,
                    preferredName: slug,
                    conflictPolicy: .replaceExisting,
                    managedRoot: destination.managedRoot,
                    checkpoint: { try Task.checkCancellation() }
                ) { stagedURL in
                    try Self.writeClawdhubOrigin(at: stagedURL, slug: slug, version: version)
                }
                installedStorageKeys.append(destination.storageKey)
            } catch {
                guard !installedStorageKeys.isEmpty else { throw error }
                throw PartialSkillInstallError(
                    installedStorageKeys: installedStorageKeys,
                    failedStorageKey: destination.storageKey,
                    reason: error.localizedDescription
                )
            }
        }

        guard let preferred = destinations.first else { return nil }
        return "\(preferred.storageKey)-\(slug)"
    }

    func scanSkills(at baseURL: URL, storageKey: String) throws -> [ScannedSkillData] {
        let fileManager = FileManager.default

        guard fileManager.fileExists(atPath: baseURL.path) else {
            return []
        }
        let managedRoot = try ManagedRootReference.capture(at: baseURL)
        let directoryURL = try managedRoot.verifiedRootURL()

        let items = try fileManager.contentsOfDirectory(
            at: directoryURL,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        )

        return items.compactMap { url -> ScannedSkillData? in
            let values = try? url.resourceValues(forKeys: [.isDirectoryKey])
            guard values?.isDirectory == true else { return nil }

            let name = url.lastPathComponent
            let skillFileURL = url.appendingPathComponent("SKILL.md")
            guard fileManager.fileExists(atPath: skillFileURL.path) else { return nil }

            let markdown = (try? String(contentsOf: skillFileURL, encoding: .utf8)) ?? ""
            let metadata = parseMetadata(from: markdown)

            let references = referenceFiles(in: url.appendingPathComponent("references"))
            let stats = SkillStats(
                references: references.count,
                assets: countEntries(in: url.appendingPathComponent("assets")),
                scripts: countEntries(in: url.appendingPathComponent("scripts")),
                templates: countEntries(in: url.appendingPathComponent("templates"))
            )

            return ScannedSkillData(
                id: "\(storageKey)-\(name)",
                name: name,
                displayName: formatTitle(metadata.name ?? name),
                description: metadata.description ?? "No description available.",
                managedRoot: managedRoot,
                folderURL: url,
                skillMarkdownURL: skillFileURL,
                references: references,
                stats: stats
            )
        }
    }

    func computeSkillHash(for rootURL: URL) throws -> String {
        try SkillContentSnapshot.capture(
            at: rootURL,
            checkpoint: { try Task.checkCancellation() }
        ).fingerprint
    }

    func readClawdhubOrigin(from skillRoot: URL) -> ClawdhubOrigin? {
        let originURL = skillRoot
            .appendingPathComponent(".clawdhub", isDirectory: true)
            .appendingPathComponent("origin.json")
        guard let data = try? Data(contentsOf: originURL),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let slug = json["slug"] as? String else {
            return nil
        }

        let version = json["version"] as? String
        return ClawdhubOrigin(slug: slug, version: version)
    }

    nonisolated private static func writeClawdhubOrigin(
        at skillRoot: URL,
        slug: String,
        version: String?
    ) throws {
        let originDir = skillRoot
            .appendingPathComponent(".clawdhub", isDirectory: true)
        try FileManager.default.createDirectory(at: originDir, withIntermediateDirectories: true)

        let originURL = originDir.appendingPathComponent("origin.json")
        let payload: [String: Any] = [
            "slug": slug,
            "version": version ?? "latest",
            "source": "clawdhub",
            "installedAt": Int(Date().timeIntervalSince1970)
        ]
        let data = try JSONSerialization.data(withJSONObject: payload, options: [.prettyPrinted])
        try data.write(to: originURL, options: [.atomic])
    }

    private func parseMetadata(from markdown: String) -> SkillMetadata {
        let lines = markdown.split(omittingEmptySubsequences: false, whereSeparator: \.isNewline)
        var name: String?
        var description: String?

        if lines.first?.trimmingCharacters(in: CharacterSet.whitespacesAndNewlines) == "---" {
            var index = 1
            while index < lines.count {
                let line = String(lines[index])
                if line.trimmingCharacters(in: CharacterSet.whitespacesAndNewlines) == "---" {
                    break
                }
                if let (key, value) = parseFrontmatterLine(line) {
                    if key == "name" {
                        name = value
                    } else if key == "description" {
                        description = value
                    }
                }
                index += 1
            }
        }

        if name == nil || description == nil {
            let fallback = parseMarkdownFallback(from: lines)
            name = name ?? fallback.name
            description = description ?? fallback.description
        }

        return SkillMetadata(name: name, description: description)
    }

    private func parseFrontmatterLine(_ line: String) -> (String, String)? {
        let parts = line.split(separator: ":", maxSplits: 1, omittingEmptySubsequences: false)
        guard parts.count == 2 else { return nil }
        let key = parts[0].trimmingCharacters(in: .whitespacesAndNewlines)
        let rawValue = parts[1].trimmingCharacters(in: .whitespacesAndNewlines)
        let value = rawValue.trimmingCharacters(in: CharacterSet(charactersIn: "\"'"))
        return (key, value)
    }

    private func parseMarkdownFallback(from lines: [Substring]) -> SkillMetadata {
        var title: String?
        var description: String?

        var index = 0
        while index < lines.count {
            let line = lines[index].trimmingCharacters(in: .whitespacesAndNewlines)
            if title == nil, line.hasPrefix("# ") {
                title = String(line.dropFirst(2)).trimmingCharacters(in: .whitespacesAndNewlines)
            } else if description == nil, !line.isEmpty, !line.hasPrefix("#") {
                description = String(line)
                break
            }
            index += 1
        }

        return SkillMetadata(name: title, description: description)
    }

    private func formatTitle(_ title: String) -> String {
        let normalized = title
            .replacingOccurrences(of: "-", with: " ")
            .replacingOccurrences(of: "_", with: " ")
        return normalized
            .split(separator: " ")
            .map { $0.capitalized }
            .joined(separator: " ")
    }

    private func countEntries(in url: URL) -> Int {
        guard let items = try? FileManager.default.contentsOfDirectory(
            at: url,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        ) else {
            return 0
        }
        return items.count
    }

    private func referenceFiles(in url: URL) -> [SkillReference] {
        guard let items = try? FileManager.default.contentsOfDirectory(
            at: url,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles]
        ) else {
            return []
        }

        let references = items.compactMap { fileURL -> SkillReference? in
            let values = try? fileURL.resourceValues(forKeys: [.isRegularFileKey])
            guard values?.isRegularFile == true else { return nil }
            guard fileURL.pathExtension.lowercased() == "md" else { return nil }

            let filename = fileURL.deletingPathExtension().lastPathComponent
            return SkillReference(
                id: fileURL.path,
                name: formatTitle(filename),
                url: fileURL
            )
        }

        return references.sorted {
            $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending
        }
    }
}
