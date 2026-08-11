# Skills Manager

[中文版](README.md)

![Skills Manager](image.png)

Skills Manager is a macOS SwiftUI app built with SwiftPM. The repository's Xcode project is only the host for Apple-native UI tests; it is not the product project. The app manages skills for multiple AI CLI tools from one source of truth (SSOT), with import, distribution, enable/disable, backup, and restore workflows.

This project started independent secondary development from commit [`3f2d809c`](https://github.com/Dimillian/CodexSkillManager/commit/3f2d809c19cd18f5b0d74997c3457760fd819035) of [Dimillian/CodexSkillManager](https://github.com/Dimillian/CodexSkillManager). The original project is distributed under the MIT License; its copyright and license notice remain in [LICENSE](LICENSE).

## Features

- Store managed skills in `~/.SkillsManager/skills/`
- Scan and import unmanaged skills from Codex, Claude Code, OpenCode, and GitHub Copilot directories
- Distribute with symlinks by default through compatible `~/.agents/skills/` readers, use copies, or enable only selected agents; preserve an externally edited copy as an independent fork
- Enable or disable a skill per agent without leaving duplicate global and dedicated copies
- Back up a managed skill before deletion, then inspect and restore backups
- Check and apply remote updates for one skill or a batch, with per-item results and failures
- Audit the SSOT, distribution directories, and historical skills before repairing or migrating them
- Render `SKILL.md` with Markdown, plus inline reference previews
- Import skills from a folder or ZIP archive
- Combine status, source, and Agent filters in one list; a filtered-out selection safely clears its detail
- Select multiple pending skills for batch takeover, then review per-item import results
- Review a multi-skill ZIP, import only the selected subset, and keep SSOT, database, and distribution unchanged on cancel
- Register a fixed GitHub repository, discover candidates, and install only after an immutable revision/subpath preview
- Browse ClawHub skills with search and latest drops
- Show ClawHub author information in the detail view
- Discover GitHub skills through the skills.sh search index and install only after resolving one unambiguous safe source

If skills.sh is unavailable, local skills, ClawHub, GitHub repositories, and other managed features remain available.

## Managed library startup troubleshooting

If the managed library cannot start, open “View diagnostics…” from the app banner and follow the first blocking diagnostic’s recovery suggestion before retrying. Repair the reported entry, permissions, or competing lock holder; do not delete the entire `~/.SkillsManager` directory.

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
- Remote skill catalog: [ClawHub](https://clawhub.ai/)
- Interaction contracts and attribution: [CC Switch](THIRD_PARTY_NOTICES.md#cc-switch)
