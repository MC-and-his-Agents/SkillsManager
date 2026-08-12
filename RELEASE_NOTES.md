# Skills Manager 0.5.2

中文

- 支持确认并持久化 Codex 等 Harness 的真实 Skill 根目录，包括外置卷与符号链接；环境变量只作为待确认提示，避免将临时环境静默用作写入目标。
- 添加自定义路径时可明确选择“项目根”或指定 Harness 的“直接 Skill 集合根”，预览并扫描真实绝对路径，不再重复拼接 `.codex/skills` 等后缀。
- 一致性审计可识别全局与 Harness 专属目录中的重复入口；仅在身份和内容证据一致、用户确认且已有备份时可恢复地收敛，同名、内容分叉、证据缺失或自定义只读根均保持零覆盖并提示决策。
- 托管目录中的普通 `.DS_Store` 不再阻塞启动；其他未知、符号链接或特殊条目继续 fail closed，并显示具体、可操作且不泄露私有路径的诊断。

已知限制

- Harness 环境变量不会自动成为持久写入目标，首次使用外置根时需要在设置中确认。
- skills.sh 使用未文档化公共接口，可能临时或永久不可用；失败不会影响本地、ClawHub 或已管理 Skill。
- 行内更新徽章仅覆盖 ClawHub 来源；仓库与 skills.sh 来源的更新检测不在本版本。
- 本版本不通过 Mac App Store 分发。

English

- Added confirmation and persistence for the actual Skill roots used by Codex and other harnesses, including external volumes and symlinks. Environment variables remain confirmation-only hints instead of silently becoming write targets.
- Custom paths can now be added explicitly as project roots or direct Skill collection roots for a selected harness, with previews and scans using the actual absolute path instead of appending `.codex/skills` or similar suffixes twice.
- Consistency audits now detect duplicate entries across global and harness-specific roots. Convergence is recoverable and allowed only after explicit confirmation, backup, and matching identity/content evidence; name-only matches, content forks, incomplete evidence, and read-only custom roots remain untouched and require a decision.
- A regular `.DS_Store` no longer blocks managed-library startup. Other unknown, symlink, or special entries continue to fail closed with specific, actionable diagnostics that do not expose private paths.

Known limitations

- Harness environment variables do not automatically become persistent write targets; external roots must be confirmed in Settings before first use.
- skills.sh uses an undocumented public endpoint that may become temporarily or permanently unavailable; failures do not affect local, ClawHub, or managed skills.
- In-row update badges cover ClawHub sources only; repository and skills.sh update detection is not part of this version.
- This release is not distributed through the Mac App Store.

# Skills Manager 0.5.1

中文

- 修复从 GitHub Release 下载并解压的正式 App 无法加载 SwiftPM 资源 bundle、启动即退出的问题。
- 发布验证现在会在上传前确认本地化资源 bundle 已封装，并在公开 ZIP 下载后从独立目录验证签名、公证、Gatekeeper 与启动。

已知限制

- skills.sh 使用未文档化公共接口，可能临时或永久不可用；失败不会影响本地、ClawHub 或已管理 Skill。
- 行内更新徽章仅覆盖 ClawHub 来源；仓库与 skills.sh 来源的更新检测不在本版本。
- 本版本不通过 Mac App Store 分发。

English

- Fixed a launch failure in the signed App downloaded and extracted from GitHub Release when its SwiftPM resource bundle could not be loaded.
- Release verification now requires the packaged localization bundle before upload and validates signing, notarization, Gatekeeper, and launch from a separately downloaded public ZIP.

Known limitations

- skills.sh uses an undocumented public endpoint that may become temporarily or permanently unavailable; failures do not affect local, ClawHub, or managed skills.
- In-row update badges cover ClawHub sources only; repository and skills.sh update detection is not part of this version.
- This release is not distributed through the Mac App Store.

# Skills Manager 0.5.0

中文

- 新增原生简体中文与英文界面：首次启动默认简体中文，可在 macOS“应用语言”中切换英文；核心流程、错误状态、辅助功能与权限说明均使用应用内资源并支持系统回退。
- 更新徽章改为仅在可见的已管理 Skill 行按需检查，避免列表刷新触发批量网络请求，并阻止旧请求覆盖当前结果。
- 安装、更新、删除与分发结果使用带唯一操作身份的详情页结果条；支持手动关闭与自动消退，旧计时器不会隐藏新结果，ClawHub、skills.sh 与 GitHub 仓库安装结果均可见。
- 本地构建与启动默认强制 ad-hoc 签名并清理继承的签名环境，不再访问钥匙串或反复请求密码；Developer ID 仅用于显式选择的正式签名流程。

已知限制

- skills.sh 使用未文档化公共接口，可能临时或永久不可用；失败不会影响本地、ClawHub 或已管理 Skill。
- 行内更新徽章仅覆盖 ClawHub 来源；仓库与 skills.sh 来源的更新检测不在本版本。
- 本版本不通过 Mac App Store 分发。

English

- Added native Simplified Chinese and English interfaces: first launch defaults to Simplified Chinese, while English is selectable through macOS App Language. Core journeys, errors, accessibility copy, permission descriptions, and system fallback are localized from app resources.
- Update badges now check only visible managed-skill rows on demand, avoiding bulk network requests during list refresh and rejecting stale responses.
- Install, update, delete, and distribution results use a detail-pane banner with unique operation identity, manual close, and safe auto-dismiss. ClawHub, skills.sh, and GitHub repository install results are all surfaced without an old timer hiding a newer result.
- Local build-and-run now forces ad-hoc signing and scrubs inherited signing settings, avoiding keychain access and repeated password prompts. Developer ID remains limited to explicitly selected release signing.

Known limitations

- skills.sh uses an undocumented public endpoint that may become temporarily or permanently unavailable; failures do not affect local, ClawHub, or managed skills.
- In-row update badges cover ClawHub sources only; repository and skills.sh update detection is not part of this version.
- This release is not distributed through the Mac App Store.

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
