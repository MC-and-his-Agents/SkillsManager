# Skills Manager

[中文版](README.md)

![Skills Manager](image.png)

Skills Manager is a macOS SwiftUI app built with SwiftPM (no Xcode project). It manages skills for multiple AI CLI tools from one source of truth (SSOT), with import, distribution, enable/disable, backup, and restore workflows.

This project started independent secondary development from commit [`3f2d809c`](https://github.com/Dimillian/CodexSkillManager/commit/3f2d809c19cd18f5b0d74997c3457760fd819035) of [Dimillian/CodexSkillManager](https://github.com/Dimillian/CodexSkillManager). The original project is distributed under the MIT License; its copyright and license notice remain in [LICENSE](LICENSE).

## Features

- Store managed skills in `~/.SkillsManager/skills/`
- Scan and import unmanaged skills from Codex, Claude Code, OpenCode, and GitHub Copilot directories
- Distribute with symlinks by default through compatible `~/.agents/skills/` readers, or enable only selected agents
- Enable or disable a skill per agent without leaving duplicate global and dedicated copies
- Back up a managed skill before deletion, then inspect and restore backups
- Render `SKILL.md` with Markdown, plus inline reference previews
- Import skills from a folder or ZIP archive
- Browse Clawdhub skills with search and latest drops
- Show Clawdhub author information in the detail view

This release supports symlink distribution only. Copy/Fork, skills.sh, and batch updates are not available yet.

## Requirements

- Runtime: macOS 15+
- Development: Swift 6.2+ and Xcode 26+

## Build and run

```bash
swift build
swift run SkillsManager
```

## Package a local app

```bash
./Scripts/compile_and_run.sh
```

## Credits

- Markdown rendering: [swift-markdown-ui](https://github.com/gonzalezreal/swift-markdown-ui)
- Remote skill catalog: [Clawdhub](https://clawdhub.com)
