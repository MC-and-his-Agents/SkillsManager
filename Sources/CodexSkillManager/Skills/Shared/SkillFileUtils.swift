import Foundation

struct SkillMetadata {
    let name: String?
    let description: String?
}

func parseMetadata(from markdown: String) -> SkillMetadata {
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

func stripFrontmatter(from markdown: String) -> String {
    let lines = markdown.split(omittingEmptySubsequences: false, whereSeparator: \.isNewline)
    guard lines.first?.trimmingCharacters(in: CharacterSet.whitespacesAndNewlines) == "---" else {
        return markdown
    }

    var index = 1
    while index < lines.count {
        let line = lines[index].trimmingCharacters(in: CharacterSet.whitespacesAndNewlines)
        if line == "---" {
            let remaining = lines[(index + 1)...].map(String.init).joined(separator: "\n")
            return remaining.trimmingCharacters(in: CharacterSet.newlines)
        }
        index += 1
    }

    return markdown
}

func formatTitle(_ title: String) -> String {
    let normalized = title
        .replacingOccurrences(of: "-", with: " ")
        .replacingOccurrences(of: "_", with: " ")
    return normalized
        .split(separator: " ")
        .map { $0.capitalized }
        .joined(separator: " ")
}

func countEntries(in url: URL) -> Int {
    guard let items = try? FileManager.default.contentsOfDirectory(
        at: url,
        includingPropertiesForKeys: nil,
        options: [.skipsHiddenFiles]
    ) else {
        return 0
    }
    return items.count
}

func referenceFiles(in url: URL) -> [SkillReference] {
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
