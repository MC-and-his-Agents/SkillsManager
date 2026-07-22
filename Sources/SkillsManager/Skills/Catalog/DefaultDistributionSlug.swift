import Foundation

nonisolated enum SkillPresentationError: Error, Equatable {
    case invalidDisplayName
    case invalidDistributionSlug
    case distributionSlugKeyTooLong
}

nonisolated struct SkillDisplayName: Hashable, Sendable {
    let value: String

    init(_ rawValue: String) throws {
        let normalized = rawValue.precomposedStringWithCanonicalMapping
        guard 1...512 ~= normalized.utf8.count else {
            throw SkillPresentationError.invalidDisplayName
        }
        value = normalized
    }
}

nonisolated struct DefaultDistributionSlug: Hashable, Sendable {
    let value: String
    let collisionKey: String

    init(candidateFrom displayName: SkillDisplayName) throws {
        try self.init(validating: Self.candidate(from: displayName.value))
    }

    init(validating rawValue: String) throws {
        let normalized = rawValue.precomposedStringWithCanonicalMapping
        guard !normalized.isEmpty,
              normalized.utf8.count <= 200,
              normalized != ".",
              normalized != "..",
              !normalized.hasPrefix("."),
              !normalized.contains("/"),
              !normalized.contains("\\"),
              !normalized.contains("\0") else {
            throw SkillPresentationError.invalidDistributionSlug
        }

        let key = SkillContentPath.collisionKey(for: normalized)
        guard !key.isEmpty, key.utf8.count <= 800 else {
            throw SkillPresentationError.distributionSlugKeyTooLong
        }
        value = normalized
        collisionKey = key
    }

    private static func candidate(from displayName: String) -> String {
        var mapped = ""
        var lastWasHyphen = false

        for scalar in displayName.unicodeScalars {
            let shouldMap = CharacterSet.whitespacesAndNewlines.contains(scalar)
                || CharacterSet.controlCharacters.contains(scalar)
                || scalar == "/" || scalar == "\\" || scalar == ":"
                || scalar == "-"
            if shouldMap {
                if !lastWasHyphen {
                    mapped.append("-")
                    lastWasHyphen = true
                }
            } else {
                mapped.unicodeScalars.append(scalar)
                lastWasHyphen = false
            }
        }

        var candidate = mapped.trimmingCharacters(in: CharacterSet(charactersIn: ".-"))
        if candidate.isEmpty { candidate = "skill" }

        var truncated = ""
        var byteCount = 0
        for character in candidate {
            let characterByteCount = String(character).utf8.count
            guard byteCount + characterByteCount <= 200 else { break }
            truncated.append(character)
            byteCount += characterByteCount
        }

        while truncated.last == "." || truncated.last == "-" {
            truncated.removeLast()
        }
        return truncated.isEmpty ? "skill" : truncated
    }
}
