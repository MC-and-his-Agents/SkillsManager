# Skills Manager 0.3.0

中文

- 统一 Skill 列表：已管理 Skill、本机发现候选、ClawHub、skills.sh 与自定义 GitHub 仓库候选收敛到同一列表，并在行内显示状态、来源与 Agent 数量。
- 支持按状态、来源与 Agent 组合筛选；当前选择被筛掉时详情自动回到空状态，清除筛选后恢复。
- 支持批量接管本机发现的待导入 Skill，逐项预览导入结果。
- 支持导入包含多个 Skill 的 ZIP 归档，可选择子集后确认导入。
- 支持登记自定义 GitHub 仓库并发现其中的 Skill，在 immutable revision/subpath 预览后安全安装。
- 改进远程结果的分页与错误隔离；单个 Provider 不可用不影响本地 Skill 或其他来源。
- 改善辅助功能：列表行可读出名称、状态、来源与 Agent 数量，主要文本对比度与键盘/焦点行为收敛。

已知限制

- skills.sh 使用未文档化公共接口，可能临时或永久不可用；失败不会影响本地、ClawHub 或已管理 Skill。
- 本版本不通过 Mac App Store 分发。

English

- Unified Skill list: managed skills, on-device discoveries, ClawHub, skills.sh, and custom GitHub repository candidates converge into one list, with status, source, and Agent count shown in each row.
- Filter by status, source, and Agent together; filtering out the current selection returns the detail pane to its empty state and clearing filters restores it.
- Batch-take over discovered local Skills awaiting import, reviewing each import result.
- Import ZIP archives containing multiple Skills, selecting a subset before confirming.
- Register custom GitHub repositories, discover their Skills, and install only after reviewing an immutable revision/subpath preview.
- Improved remote pagination and failure isolation; one unavailable provider does not hide local skills or other sources.
- Accessibility improvements: rows read out name, status, source, and Agent count; primary text contrast and keyboard/focus behavior converged.

Known limitations

- skills.sh uses an undocumented public endpoint that may become temporarily or permanently unavailable; failures do not affect local, ClawHub, or managed skills.
- This release is not distributed through the Mac App Store.
