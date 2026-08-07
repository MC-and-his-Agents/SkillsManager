import Foundation

/// 语义版本比较（`SkillStore.isNewerVersion` 的纯函数来源）。
nonisolated enum SkillVersionComparison {
    static func isNewer(_ latest: String, than installed: String) -> Bool {
        let latestParts = latest.split(separator: ".").compactMap { Int($0) }
        let installedParts = installed.split(separator: ".").compactMap { Int($0) }
        guard latestParts.count == 3, installedParts.count == 3 else { return false }
        for index in 0..<3 {
            if latestParts[index] != installedParts[index] {
                return latestParts[index] > installedParts[index]
            }
        }
        return false
    }
}
