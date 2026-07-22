# Skills Manager

## Repository scope

Skills Manager is a macOS SwiftUI app built with SwiftPM. The repository does not use an Xcode project.

This file contains stable instructions for working in the repository. Do not duplicate product features, UI structure, supported skill platforms, source-file inventories, or release implementation details here; those facts change with the product.

## Sources of truth

- Product description and user-facing requirements: `README.md`
- Supported macOS version, Swift tools version, targets, and dependencies: `Package.swift`
- Marketing version and build number: `version.env`
- Application behavior and architecture: `Sources/` and `Tests/`
- CI and automated release behavior: `.github/workflows/`
- Local build, packaging, signing, and appcast implementation: `Scripts/`

Read the relevant source of truth before changing behavior. Update the owning file instead of copying its details into this file.

## Build and validation

- Build: `swift build`
- Test: `swift test`
- Run the executable during development: `swift run CodexSkillManager`
- Package and launch an ad-hoc signed app: `./Scripts/compile_and_run.sh`

After every code change, run `swift build` and fix compilation errors before continuing. Run `swift test` for behavior, model, parsing, filesystem, import, or platform-discovery changes. Documentation-only changes do not require a Swift build.

When changing packaging or release automation, also run the applicable checks:

- Shell syntax: `bash -n Scripts/*.sh`
- GitHub Actions syntax: `actionlint .github/workflows/*.yml` when `actionlint` is available
- Packaged app: verify its bundle metadata, code signature, and bundled resources affected by the change

## Packaging and release

Official GitHub releases are defined by `.github/workflows/release.yml`. A release tag must match `MARKETING_VERSION` in `version.env`; consult the workflow for the current trigger and exact steps.

Use the existing scripts instead of recreating packaging logic. Keep certificates, private keys, API credentials, and machine-specific release configuration outside the repository. Never commit `release.env`, `.p8`, `.p12`, Sparkle private keys, or temporary signing keychains.

## Change discipline

- Keep changes scoped to the current issue or task.
- Preserve the SwiftPM-first structure unless a task explicitly requires an Xcode project.
- Add or update tests when behavior changes.
- Do not commit generated build products, packaged apps, archives, or temporary files.
- Use a feature branch and pull request; do not implement changes directly on `main`.
