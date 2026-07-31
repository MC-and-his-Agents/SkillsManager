# Skills Manager 0.2.0

中文

- 新增 Copy 分发和 drift 保护，可丢弃外部修改或将其保留为独立本地 Fork。
- 新增实验性的 skills.sh 搜索与安全 GitHub 来源解析；只有唯一 `SKILL.md` 路径和不可变 revision 才允许安装。
- 新增单个与批量远程更新，支持内容指纹检查、逐项结果、停止、失败重试和更新前备份。
- 新增一致性审计、Symlink 修复和历史 Skill 迁移，所有写入前均提供稳定预览并在冲突时 fail closed。
- 收敛 Copy/Fork、来源身份、批量进度、Provider 不可用状态以及键盘和 VoiceOver 体验。
- 保留 v0.1.0 的 SSOT、导入、按 Agent 分发、删除前备份与恢复能力，并支持从其数据库安全升级。

已知限制

- skills.sh 使用未文档化公共接口，可能临时或永久不可用；失败不会影响本地、ClawHub 或已管理 Skill。
- Fork 是独立本地 Skill；本版本不提供自动三方合并或 Fork rebase。
- 本版本不通过 Mac App Store 分发。

English

- Adds copy distribution with drift protection: discard external edits or preserve them as an independent local fork.
- Adds experimental skills.sh search with safe GitHub source resolution; installation requires one unique `SKILL.md` path and an immutable revision.
- Adds single and batch remote updates with content fingerprint checks, per-item results, stop, retry, and pre-update backups.
- Adds consistency audits, symlink repair, and historical skill migration with stable previews and fail-closed conflicts.
- Converges Copy/Fork identity, source identity, batch progress, Provider unavailable states, keyboard access, and VoiceOver semantics.
- Keeps the v0.1.0 SSOT, import, per-agent distribution, backup, and restore workflows, with a safe database upgrade path.

Known limitations

- skills.sh uses an undocumented public endpoint that may become temporarily or permanently unavailable; failures do not affect local, ClawHub, or managed skills.
- A fork is an independent local skill; automatic three-way merge and fork rebase are not included.
- This release is not distributed through the Mac App Store.
