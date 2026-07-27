# Skills Manager MVP

中文

- 将受管理的 Skills 统一存放在 `~/.SkillsManager/skills/`。
- 默认通过 Symlink 分发到兼容的全局目录，也可只对指定 Agent 启用。
- 支持导入已有的未管理 Skill，以及从文件夹、ZIP 或 Clawdhub 安装。
- 支持按 Agent 启用/停用、删除前自动备份、备份恢复和冲突提示。
- 管理操作经过统一的 SSOT 写入、SQLite 状态记录和失败恢复流程。

已知限制

- 当前只支持 Symlink 分发；Copy/Fork 尚未提供。
- skills.sh、批量更新和 Mac App Store 发布不在本版本范围内。

English

- Stores managed skills in the single source of truth at `~/.SkillsManager/skills/`.
- Distributes with symlinks by default, globally where compatible or only to selected agents.
- Imports unmanaged skills and installs from folders, ZIP archives, or Clawdhub.
- Supports per-agent enable/disable, automatic backup before deletion, restore, and conflict feedback.
- Routes managed writes through the SSOT, SQLite state, and recoverable operations.

Known limitations

- Symlink is the only distribution mode in this release; Copy/Fork is not available yet.
- skills.sh, batch updates, and Mac App Store distribution are outside this release.
