# Skills Manager

[中文版](README.md)

![Skills Manager](image.png)

Skills Manager is a macOS SwiftUI app built with SwiftPM (no Xcode project). It manages local skills for Codex and Claude Code, renders each `SKILL.md`, and lets you browse remote skills from Clawdhub.

This project started independent secondary development from commit [`3f2d809c`](https://github.com/Dimillian/CodexSkillManager/commit/3f2d809c19cd18f5b0d74997c3457760fd819035) of [Dimillian/CodexSkillManager](https://github.com/Dimillian/CodexSkillManager). The original project is distributed under the MIT License; its copyright and license notice remain in [LICENSE](LICENSE).

## Features

- Browse local skills from `~/.codex/skills`, `~/.codex/skills/public`, and `~/.claude/skills`
- Render `SKILL.md` with Markdown, plus inline reference previews
- Import skills from a folder or zip
- Delete skills from the sidebar
- Browse Clawdhub skills with search and latest drops
- Download remote skills into Codex and/or Claude Code
- Show Clawdhub author information in the detail view
- Display visual tags for installed platforms (Codex/Claude) and versions

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
