# Skills Manager

![image](image.png)

Skills Manager is a macOS SwiftUI app built with SwiftPM (no Xcode project). It manages local skills for Codex and Claude Code, renders each `SKILL.md`, and lets you browse remote skills from Clawdhub.

This project began as a fork and secondary development of [Dimillian/CodexSkillManager](https://github.com/Dimillian/CodexSkillManager). The original project is distributed under the MIT License; its copyright and license notice remain in [LICENSE](LICENSE).

## Features
- Browse local skills from `~/.codex/skills`, `~/.codex/skills/public`, and `~/.claude/skills`
- Render `SKILL.md` with Markdown, plus inline reference previews
- Import skills from a folder or zip
- Delete skills from the sidebar
- Browse Clawdhub skills with search + latest drops
- Download remote skills into Codex and/or Claude Code
- Show Clawdhub author info in the detail view
- Visual tags for installed status (Codex/Claude) and versions

## Requirements
- Runtime: macOS 15+
- Development: Swift 6.2+ and Xcode 26+

## Build and run
```
swift build
swift run CodexSkillManager
```

## Package a local app
```
./Scripts/compile_and_run.sh
```

## Credits
- Markdown rendering via https://github.com/gonzalezreal/swift-markdown-ui
- Remote skill catalog via https://clawdhub.com
