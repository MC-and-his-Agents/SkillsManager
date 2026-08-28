import SwiftUI

/// 状态颜色语义 token（#252，Epic D1）。
///
/// 全应用同一语义状态必须同色：
/// - `healthy`：绿色，正常/已同步，无需操作。
/// - `actionAvailable`：accent 色，存在可执行的行动（如可用更新）。
///   禁止用 `healthy` 表达"有更新"，避免与"无需操作"混淆。
/// - `warning`：橙色，需要注意/修复。同一概念不得再用黄色表达。
/// - `blocking`：红色，仅用于阻塞级诊断（库不可用、权限拒绝等）。
enum SkillStatusPalette {
    static let healthy = Color.green
    static let actionAvailable = Color.accentColor
    static let warning = Color.orange
    static let blocking = Color.red
}
