#!/usr/bin/env python3
"""Validate release-impact and version transitions without executing input."""

from __future__ import annotations

import argparse
import json
import re
from dataclasses import dataclass
from pathlib import Path


SEMVER = re.compile(r"^(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)$")
IMPACT_LINE = re.compile(
    r"^[ \t]*release_impact:[ \t]*(none|patch|minor|bundled[ \t]+#([1-9][0-9]*))[ \t]*$"
)


class ContractError(ValueError):
    pass


@dataclass(frozen=True)
class Version:
    marketing: tuple[int, int, int]
    build: int

    @property
    def marketing_text(self) -> str:
        return ".".join(str(part) for part in self.marketing)


def read_text(path: str) -> str:
    return Path(path).read_text(encoding="utf-8")


def parse_impact(body: str) -> dict[str, object]:
    declarations = [
        line for line in body.splitlines() if re.match(r"^[ \t]*release_impact[ \t]*:", line)
    ]
    if len(declarations) != 1:
        raise ContractError("PR body must contain exactly one release_impact declaration.")
    match = IMPACT_LINE.fullmatch(declarations[0])
    if match is None:
        raise ContractError("release_impact must be none, patch, minor, or bundled #<issue>.")
    raw = match.group(1)
    if raw.startswith("bundled"):
        return {"impact": "bundled", "issue": int(match.group(2))}
    return {"impact": raw, "issue": None}


def parse_version_env(path: str) -> Version:
    raw = Path(path).read_bytes()
    if b"\r" in raw:
        raise ContractError("version.env must use LF line endings.")
    try:
        text = raw.decode("utf-8")
    except UnicodeDecodeError as error:
        raise ContractError("version.env must be UTF-8.") from error
    lines = text.split("\n")
    if lines and lines[-1] == "":
        lines.pop()
    if len(lines) != 2 or any(not line for line in lines):
        raise ContractError("version.env must contain exactly two non-empty entries.")

    values: dict[str, str] = {}
    for line in lines:
        if "=" not in line:
            raise ContractError("version.env contains a malformed entry.")
        key, value = line.split("=", 1)
        if key not in {"MARKETING_VERSION", "BUILD_NUMBER"} or key in values:
            raise ContractError("version.env contains an unknown or duplicate entry.")
        values[key] = value

    if set(values) != {"MARKETING_VERSION", "BUILD_NUMBER"}:
        raise ContractError("version.env is missing a required entry.")
    match = SEMVER.fullmatch(values["MARKETING_VERSION"])
    if match is None:
        raise ContractError("MARKETING_VERSION must be a stable numeric SemVer.")
    if re.fullmatch(r"[1-9][0-9]*", values["BUILD_NUMBER"]) is None:
        raise ContractError("BUILD_NUMBER must be a positive integer.")
    return Version(tuple(int(part) for part in match.groups()), int(values["BUILD_NUMBER"]))


def select_stable_release(releases: list[dict[str, object]]) -> dict[str, object]:
    candidates: list[tuple[tuple[int, int, int], str]] = []
    for release in releases:
        if release.get("isDraft") is True or release.get("isPrerelease") is True:
            continue
        tag = release.get("tagName")
        if not isinstance(tag, str) or not tag.startswith("v"):
            continue
        match = SEMVER.fullmatch(tag[1:])
        if match is not None:
            candidates.append((tuple(int(part) for part in match.groups()), tag))
    if not candidates:
        raise ContractError("No public stable SemVer release exists.")
    version, tag = max(candidates, key=lambda candidate: candidate[0])
    return {"tag": tag, "version": ".".join(str(part) for part in version)}


def validate_release_plan(args: argparse.Namespace) -> dict[str, object]:
    changed_paths = [line for line in read_text(args.changed_paths).splitlines() if line]
    if sorted(set(changed_paths)) != ["RELEASE_NOTES.md", "version.env"] or len(changed_paths) != 2:
        raise ContractError("A release commit must change only version.env and RELEASE_NOTES.md.")

    pr_impact = parse_impact(read_text(args.pr_body))
    if pr_impact["impact"] != "bundled":
        raise ContractError("A release PR must be bundled into its Release Issue.")
    issue_impact = parse_impact(read_text(args.issue_body))
    if issue_impact["impact"] not in {"patch", "minor"}:
        raise ContractError("A Release Issue must declare patch or minor impact.")

    previous = parse_version_env(args.previous_version)
    current = parse_version_env(args.current_version)
    major, minor, patch = previous.marketing
    expected = (major, minor, patch + 1)
    if issue_impact["impact"] == "minor":
        expected = (major, minor + 1, 0)
    if current.marketing != expected:
        raise ContractError(
            f"Expected {issue_impact['impact']} version {'.'.join(map(str, expected))}, "
            f"found {current.marketing_text}."
        )
    if current.build != previous.build + 1:
        raise ContractError("BUILD_NUMBER must increase by exactly one.")
    notes = read_text(args.release_notes)
    if not notes.strip() or f"# Skills Manager {current.marketing_text}" not in notes.splitlines():
        raise ContractError("RELEASE_NOTES.md must contain the target version heading.")
    return {
        "tag": f"v{current.marketing_text}",
        "version": current.marketing_text,
        "build": current.build,
        "issue": pr_impact["issue"],
        "impact": issue_impact["impact"],
    }


def dispatch_action(marker: str, runs: list[dict[str, object]]) -> str:
    if len(runs) > 1:
        raise ContractError("Multiple Release runs exist for one tag and head.")
    if not runs:
        if marker:
            raise ContractError("A dispatch marker exists without a visible Release run.")
        return "dispatch"
    run = runs[0]
    status = run.get("status")
    conclusion = run.get("conclusion")
    if status in {"queued", "in_progress", "waiting", "pending", "requested"}:
        return "observe"
    if status == "completed" and conclusion == "success":
        return "published"
    if status == "completed" and conclusion in {"failure", "cancelled"}:
        return "rerun"
    raise ContractError("Release run has an unsupported state.")


def validate_existing_release(
    metadata: dict[str, object], tag: str, notes: str, expected_assets: list[str]
) -> None:
    if (
        metadata.get("tagName") != tag
        or metadata.get("isDraft") is not False
        or metadata.get("isPrerelease") is not False
        or metadata.get("body") != notes
    ):
        raise ContractError("Existing Release metadata conflicts with the verified payload.")
    assets = metadata.get("assets")
    if not isinstance(assets, list):
        raise ContractError("Existing Release assets are malformed.")
    names = sorted(asset.get("name") for asset in assets if isinstance(asset, dict))
    if names != sorted(expected_assets):
        raise ContractError("Existing Release assets are partial or conflicting.")


def main() -> None:
    parser = argparse.ArgumentParser()
    subparsers = parser.add_subparsers(dest="command", required=True)

    impact = subparsers.add_parser("impact")
    impact.add_argument("--body", required=True)

    version = subparsers.add_parser("version")
    version.add_argument("--file", required=True)

    stable = subparsers.add_parser("stable-release")
    stable.add_argument("--releases", required=True)

    plan = subparsers.add_parser("plan")
    plan.add_argument("--current-version", required=True)
    plan.add_argument("--previous-version", required=True)
    plan.add_argument("--changed-paths", required=True)
    plan.add_argument("--pr-body", required=True)
    plan.add_argument("--issue-body", required=True)
    plan.add_argument("--release-notes", required=True)

    dispatch = subparsers.add_parser("dispatch")
    dispatch.add_argument("--marker", default="")
    dispatch.add_argument("--runs", required=True)

    existing = subparsers.add_parser("existing-release")
    existing.add_argument("--metadata", required=True)
    existing.add_argument("--tag", required=True)
    existing.add_argument("--notes", required=True)
    existing.add_argument("--asset", action="append", required=True)

    args = parser.parse_args()
    try:
        if args.command == "impact":
            result = parse_impact(read_text(args.body))
        elif args.command == "version":
            parsed = parse_version_env(args.file)
            result = {"version": parsed.marketing_text, "build": parsed.build}
        elif args.command == "stable-release":
            result = select_stable_release(json.loads(read_text(args.releases)))
        elif args.command == "plan":
            result = validate_release_plan(args)
        elif args.command == "dispatch":
            result = {"action": dispatch_action(args.marker, json.loads(read_text(args.runs)))}
        else:
            validate_existing_release(
                json.loads(read_text(args.metadata)),
                args.tag,
                read_text(args.notes),
                args.asset,
            )
            result = {"valid": True}
    except (ContractError, json.JSONDecodeError) as error:
        parser.error(str(error))
    print(json.dumps(result, separators=(",", ":"), sort_keys=True))


if __name__ == "__main__":
    main()
