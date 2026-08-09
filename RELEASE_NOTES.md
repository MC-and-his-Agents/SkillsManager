# Skills Manager 0.4.0

中文

- 详情页顶部新增固定操作条：状态徽章、来源、Agent 启用 chips、更新（有可用版本时高亮）、批量更新、在 Finder 中显示与删除，两步内可达；工具栏精简为刷新/添加/批量导入/审计/备份并带文字标签。
- 筛选从隐藏菜单变为可见控件：Status 分段（⌘1-4 切换）、来源与 Agent chips、可折叠摘要（⇧⌘F 聚焦），当前激活值始终可见。
- 列表行统一：五种行（已管理/发现/ClawHub/skills.sh/仓库）收敛为单一行组件，行尾显示来源与 Agent 数量。
- 反馈体系：ClawHub 来源 Skill 在行内显示更新可用（绿）或需修复（黄）徽章；安装/更新/删除/分发结果统一为详情顶部结果条（成功绿/失败橙，自动消退）；空与错误状态视觉统一。
- 辅助功能：操作条与筛选控件合并 label/value，更新/删除提供键盘快捷键，状态表达不依赖颜色。

已知限制

- skills.sh 使用未文档化公共接口，可能临时或永久不可用；失败不会影响本地、ClawHub 或已管理 Skill。
- 行内更新徽章仅覆盖 ClawHub 来源；仓库与 skills.sh 来源的更新检测不在本版本。
- 本版本不通过 Mac App Store 分发。

English

- New fixed action bar atop the detail pane: status badge, source, Agent enablement chips, update (highlighted when available), batch updates, Reveal in Finder, and Delete — most daily operations within two steps; the toolbar is trimmed to refresh/add/batch import/audit/backup with text labels.
- Filters move out of the hidden menu into visible controls: Status segments (⌘1-4), source and Agent chips, and a collapsible summary (⇧⌘F focuses); the active value is always visible.
- Unified list rows: the five row kinds (managed/discovery/ClawHub/skills.sh/repository) converge into one row component with trailing source and Agent counts.
- Feedback system: ClawHub skills show an in-row update-available (green) or needs-repair (yellow) badge; install/update/delete/distribution results surface as a unified detail-pane result banner (green success / orange failure, auto-dismissing); empty and error states share a consistent look.
- Accessibility: action bar and filter controls combine label/value, update and delete gain keyboard shortcuts, and state is never expressed by color alone.

Known limitations

- skills.sh uses an undocumented public endpoint that may become temporarily or permanently unavailable; failures do not affect local, ClawHub, or managed skills.
- In-row update badges cover ClawHub sources only; repository and skills.sh update detection is not part of this version.
- This version is not distributed through the Mac App Store.

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
