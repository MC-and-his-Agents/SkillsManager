# Skills Manager

![Skills Manager](image.png)

[English](README.en.md)

Skills Manager 是一款基于 SwiftPM 构建的 macOS SwiftUI 应用（不使用 Xcode 工程）。它将多个 AI CLI 工具使用的 Skills 统一纳入单一事实来源（SSOT），并提供导入、分发、启用/停用、备份与恢复。

本项目基于 [Dimillian/CodexSkillManager](https://github.com/Dimillian/CodexSkillManager) 的提交 [`3f2d809c`](https://github.com/Dimillian/CodexSkillManager/commit/3f2d809c19cd18f5b0d74997c3457760fd819035) 开始独立二次开发。原项目采用 MIT License；本项目保留原作者的版权和许可声明，详见 [LICENSE](LICENSE)。

### 功能

- 将受管理的 Skills 统一存放在 `~/.SkillsManager/skills/`
- 扫描并导入 Codex、Claude Code、OpenCode 和 GitHub Copilot 目录中尚未管理的 Skill
- 默认通过 Symlink 分发到兼容的 `~/.agents/skills/`，也可只对指定 Agent 启用
- 按 Agent 启用或停用 Skill，避免全局目录和专属目录出现同名副本
- 删除 Skill 本体前自动备份，并支持查看和恢复备份
- 使用 Markdown 渲染 `SKILL.md`，并预览行内引用
- 从文件夹或 ZIP 文件导入 Skill
- 搜索 Clawdhub 技能并浏览最新发布内容
- 在详情页显示 Clawdhub 作者信息

当前版本仅支持 Symlink 分发；Copy/Fork、skills.sh 和批量更新尚未提供。

### 环境要求

- 运行环境：macOS 15 及以上
- 开发环境：Swift 6.2 及以上、Xcode 26 及以上

### 构建与运行

```bash
swift build
swift run SkillsManager
```

### 打包本地应用

```bash
./Scripts/compile_and_run.sh
```

### 致谢

- Markdown 渲染：[swift-markdown-ui](https://github.com/gonzalezreal/swift-markdown-ui)
- 远程技能目录：[Clawdhub](https://clawdhub.com)
