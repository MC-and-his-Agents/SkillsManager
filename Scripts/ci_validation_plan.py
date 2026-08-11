#!/usr/bin/env python3
"""Build an explainable CI plan from repository-relative changed paths."""

from __future__ import annotations

import argparse
import json
from pathlib import Path


class PlanError(ValueError):
    pass


UI_GROUP_ORDER = (
    "core-smoke",
    "local-skill",
    "remote-install",
    "update-distribution",
    "localization-accessibility",
)

FULL_PRODUCT_PREFIXES = (
    "Sources/SkillsManager/App/",
    "Sources/SkillsManager/Library/",
    "Sources/SkillsManager/Persistence/",
    "Sources/SkillsManager/Workers/",
    "Sources/SkillsManager/Skills/Catalog/",
    "Sources/SkillsManager/Skills/Shared/",
    "Sources/SkillsManager/Skills/Sidebar/",
    "Sources/SkillsManager/Skills/SSOT/",
)

JOURNEY_PREFIXES = (
    ("Sources/SkillsManager/Skills/Remote/", ("remote-install",)),
    ("Sources/SkillsManager/Skills/Update/", ("update-distribution",)),
    ("Sources/SkillsManager/Skills/Distribution/", ("update-distribution",)),
    ("Sources/SkillsManager/Skills/Settings/", ("core-smoke", "local-skill")),
    ("Sources/SkillsManager/Skills/Backup/", ("local-skill",)),
    ("Sources/SkillsManager/Skills/Consistency/", ("local-skill",)),
    ("Sources/SkillsManager/Skills/Discovery/", ("local-skill",)),
    ("Sources/SkillsManager/Skills/Import/", ("local-skill",)),
    ("Sources/SkillsManager/Skills/Local/", ("local-skill",)),
)

LOGIC_PREFIXES = tuple(prefix for prefix, _ in JOURNEY_PREFIXES) + (
    "Sources/SkillsManager/Skills/Files/",
    "Sources/SkillsManager/Skills/Fork/",
    "Sources/SkillsManager/Skills/Migration/",
)

UI_COMPONENT_SUFFIXES = (
    "View.swift",
    "Row.swift",
    "Sheet.swift",
    "Banner.swift",
    "ActionBar.swift",
    "FilterBar.swift",
    "SectionHeader.swift",
    "Presentation.swift",
)

FULL_CI_PATHS = {
    ".github/workflows/ci.yml",
    "Scripts/ci_validation_plan.py",
    "Scripts/release_contract.py",
    "Scripts/run_ui_tests.sh",
    "Scripts/ui_test_selection.sh",
    "Scripts/tests/test_ci_validation_plan.py",
    "Scripts/tests/test_release_contract.py",
    "Scripts/tests/test_run_ui_tests.sh",
    "Scripts/tests/test_ui_test_selection.sh",
}


def result(module: str, risk: str, checks: list[str], **extra: object) -> dict[str, object]:
    return {"module": module, "risk": risk, "checks": checks, **extra}


def source_rule(path: str) -> dict[str, object]:
    if path.startswith("Sources/SkillsManager/Resources/"):
        return result(
            "localization",
            "localized-ui",
            ["swift-build", "swift-tests", "ui-localization-accessibility"],
            swift=True,
            groups=("localization-accessibility",),
        )
    if path in {
        "Sources/SkillsManager/Skills/SkillSplitView.swift",
        "Sources/SkillsManager/Skills/SkillSplitLifecycleModifier.swift",
        "Sources/SkillsManager/Skills/ManagedSkillSelection.swift",
    } or path.startswith(FULL_PRODUCT_PREFIXES):
        return result(
            "shared-product-state",
            "cross-journey-state",
            ["swift-build", "swift-tests", "ui-full"],
            swift=True,
            full_ui=True,
        )
    if path == "Sources/SkillsManager/Skills/Import/ManagedInstallPresentation.swift":
        groups = ("local-skill", "remote-install")
        return result(
            "import",
            "journey-ui",
            ["swift-build", "swift-tests", *(f"ui-{group}" for group in groups)],
            swift=True,
            groups=groups,
        )
    for prefix, groups in JOURNEY_PREFIXES:
        if path.startswith(prefix) and path.endswith(UI_COMPONENT_SUFFIXES):
            module = prefix.rstrip("/").rsplit("/", 1)[-1].lower()
            checks = ["swift-build", "swift-tests", *(f"ui-{group}" for group in groups)]
            return result(module, "journey-ui", checks, swift=True, groups=groups)
    if path.endswith(".swift") and path.startswith(LOGIC_PREFIXES):
        module = path.split("/")[3].lower()
        return result(module, "product-logic", ["swift-build", "swift-tests"], swift=True)
    raise PlanError(f"Changed product path has no CI impact mapping: {path}")


def path_rule(path: str) -> dict[str, object]:
    if path.endswith(".md") or path in {".gitignore", "LICENSE", "image.png"}:
        return result("documentation", "documentation", ["ci-plan"])
    if path.startswith(".vscode/"):
        return result("development-config", "developer-tooling", ["ci-plan"])
    if path in {"Package.swift", "Package.resolved"}:
        return result(
            "package",
            "application-startup",
            ["swift-build", "swift-tests", "ui-full"],
            swift=True,
            full_ui=True,
        )
    if path in {"version.env", "Icon.icns", "Icon.png"} or path.startswith("Icon.iconset/"):
        return result(
            "packaging", "packaged-metadata", ["swift-build", "swift-tests"], swift=True
        )
    if path == "appcast.xml":
        return result("release-metadata", "update-feed", ["ci-plan"])
    if path.startswith("Sources/SkillsManager/"):
        return source_rule(path)
    if path.startswith("Tests/SkillsManagerTests/") and path.endswith(".swift"):
        return result("swift-tests", "test-contract", ["swift-build", "swift-tests"], swift=True)
    if path.startswith("UITests/"):
        return result(
            "ui-runner",
            "cross-journey-test-infrastructure",
            ["swift-build", "swift-tests", "ui-full"],
            swift=True,
            full_ui=True,
        )
    if path in FULL_CI_PATHS:
        return result(
            "ci-validation",
            "cross-journey-test-infrastructure",
            ["ci-contracts", "swift-build", "swift-tests", "ui-full"],
            swift=True,
            full_ui=True,
        )
    if path.startswith("Scripts/"):
        return result(
            "scripts",
            "script-contract",
            ["ci-contracts", "swift-build", "swift-tests"],
            swift=True,
        )
    if path.startswith(".github/"):
        return result(
            "automation",
            "workflow-contract",
            ["ci-plan", "swift-build", "swift-tests"],
            swift=True,
        )
    raise PlanError(f"Changed path has no CI impact mapping: {path}")


def release_only_plan(paths: list[str]) -> dict[str, object]:
    return {
        "changed_paths": paths,
        "modules": ["release-metadata"],
        "risks": ["release-contract"],
        "checks": ["release-contract", "exact-main-ci-reuse", "fallback-full-macos"],
        "uncovered_risks": [],
        "escalation_conditions": ["exact main CI evidence is unavailable"],
        "release_only": True,
        "swift": True,
        "ui_scope": "full",
        "ui_groups": "full",
    }


def plan_validation(paths: list[str]) -> dict[str, object]:
    changed_paths = sorted(set(paths))
    if not changed_paths:
        raise PlanError("CI validation requires at least one changed path.")
    if changed_paths == ["RELEASE_NOTES.md", "version.env"]:
        return release_only_plan(changed_paths)

    rules = [path_rule(path) for path in changed_paths]
    modules = sorted({str(rule["module"]) for rule in rules})
    risks = sorted({str(rule["risk"]) for rule in rules})
    checks = sorted({str(check) for rule in rules for check in rule["checks"]})
    full_ui = any(bool(rule.get("full_ui")) for rule in rules)
    selected = {str(group) for rule in rules for group in rule.get("groups", ())}
    groups = [group for group in UI_GROUP_ORDER if group in selected]
    ui_scope = "full" if full_ui else "targeted" if groups else "none"
    return {
        "changed_paths": changed_paths,
        "modules": modules,
        "risks": risks,
        "checks": checks,
        "uncovered_risks": [],
        "escalation_conditions": [
            "an unmapped path is introduced",
            "targeted evidence reveals cross-journey impact",
        ],
        "release_only": False,
        "swift": any(bool(rule.get("swift")) for rule in rules),
        "ui_scope": ui_scope,
        "ui_groups": "full" if full_ui else ",".join(groups),
    }


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--changed-paths", required=True)
    args = parser.parse_args()
    paths = [line for line in Path(args.changed_paths).read_text().splitlines() if line]
    try:
        plan = plan_validation(paths)
    except PlanError as error:
        parser.error(str(error))
    print(json.dumps(plan, separators=(",", ":"), sort_keys=True))


if __name__ == "__main__":
    main()
