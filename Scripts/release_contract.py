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
        if not isinstance(release, dict):
            raise ContractError("Release metadata must contain objects.")
        if not isinstance(release.get("isDraft"), bool) or not isinstance(
            release.get("isPrerelease"), bool
        ):
            raise ContractError("Release draft and prerelease flags must be booleans.")
        if release["isDraft"] or release["isPrerelease"]:
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


def validate_ci_reuse(
    proof_sha: str, run: dict[str, object], jobs: list[dict[str, object]]
) -> dict[str, object]:
    if not re.fullmatch(r"[0-9a-f]{40}", proof_sha):
        raise ContractError("CI reuse proof SHA must be a full lowercase commit SHA.")
    if (
        run.get("event") != "push"
        or run.get("head_branch") != "main"
        or run.get("head_sha") != proof_sha
        or run.get("status") != "completed"
        or run.get("conclusion") != "success"
    ):
        raise ContractError("CI reuse requires a successful main push run for the exact SHA.")
    run_id = run.get("id")
    run_attempt = run.get("run_attempt")
    run_url = run.get("html_url")
    if (
        not isinstance(run_id, int)
        or run_id < 1
        or not isinstance(run_attempt, int)
        or run_attempt < 1
        or not isinstance(run_url, str)
        or not run_url.startswith("https://github.com/")
    ):
        raise ContractError("CI reuse run metadata is malformed.")

    build_job, test_job = validate_real_ci_jobs(jobs)
    return {
        "proof_sha": proof_sha,
        "run_id": run_id,
        "run_attempt": run_attempt,
        "run_url": run_url,
        "build_job_url": f"{run_url}/job/{build_job['id']}",
        "test_job_url": f"{run_url}/job/{test_job['id']}",
    }


def validate_real_ci_jobs(
    jobs: list[dict[str, object]],
) -> tuple[dict[str, object], dict[str, object]]:
    build_jobs = [job for job in jobs if isinstance(job, dict) and job.get("name") == "build"]
    if len(build_jobs) != 1 or build_jobs[0].get("conclusion") != "success":
        raise ContractError("CI reuse requires one successful build job.")
    build_steps = build_jobs[0].get("steps")
    if not isinstance(build_steps, list):
        raise ContractError("CI reuse build steps are missing.")
    build_results = {
        step.get("name"): step.get("conclusion")
        for step in build_steps
        if isinstance(step, dict)
    }
    if (
        build_results.get("Build") != "success"
        or build_results.get("Skip Swift build") != "skipped"
        or build_results.get("Reuse verified product build") not in {None, "skipped"}
    ):
        raise ContractError("CI reuse requires the real Build step and rejects skipped builds.")

    test_jobs = [job for job in jobs if isinstance(job, dict) and job.get("name") == "test"]
    if len(test_jobs) != 1 or test_jobs[0].get("conclusion") != "success":
        raise ContractError("CI reuse requires one successful test job.")
    steps = test_jobs[0].get("steps")
    if not isinstance(steps, list):
        raise ContractError("CI reuse test steps are missing.")
    step_results = {
        step.get("name"): step.get("conclusion") for step in steps if isinstance(step, dict)
    }
    if (
        step_results.get("Test") != "success"
        or step_results.get("Skip Swift tests") != "skipped"
        or step_results.get("Reuse verified product tests") not in {None, "skipped"}
    ):
        raise ContractError("CI reuse requires the real Test step and rejects skipped tests.")
    build_job_id = build_jobs[0].get("id")
    test_job_id = test_jobs[0].get("id")
    if (
        not isinstance(build_job_id, int)
        or build_job_id < 1
        or not isinstance(test_job_id, int)
        or test_job_id < 1
    ):
        raise ContractError("CI reuse job metadata is malformed.")
    return build_jobs[0], test_jobs[0]


def validate_pr_ci_reuse(
    repository: str,
    current_sha: str,
    current_parent: str,
    current_tree: str,
    plan_sha: str,
    pull: dict[str, object],
    run: dict[str, object],
    jobs: list[dict[str, object]],
    evidence: dict[str, object],
) -> dict[str, object]:
    commit_values = (current_sha, current_parent, current_tree)
    if any(re.fullmatch(r"[0-9a-f]{40}", value) is None for value in commit_values):
        raise ContractError("PR CI reuse requires full lowercase commit and tree SHAs.")
    if re.fullmatch(r"[0-9a-f]{64}", plan_sha) is None:
        raise ContractError("PR CI reuse requires a SHA-256 validation plan digest.")

    pr_number, base_sha, head_sha = merged_pull_identity(current_sha, current_parent, pull)
    run_id, run_attempt, run_url = successful_pr_run_identity(head_sha, run)
    expected_evidence = {
        "schema": 1,
        "event": "pull_request",
        "repository": repository,
        "run_id": run_id,
        "run_attempt": run_attempt,
        "pr_number": pr_number,
        "pr_base_sha": base_sha,
        "pr_head_sha": head_sha,
        "product_tree": current_tree,
        "plan_sha": plan_sha,
    }
    if evidence != expected_evidence:
        raise ContractError("PR CI reuse evidence is stale or does not match the merged product tree.")

    validate_evidence_job(jobs)
    build_job, test_job = validate_real_ci_jobs(jobs)
    return {
        "proof_sha": head_sha,
        "proof_base_sha": base_sha,
        "proof_tree": current_tree,
        "proof_plan_sha": plan_sha,
        "pr_number": pr_number,
        "run_id": run_id,
        "run_attempt": run_attempt,
        "run_url": run_url,
        "build_job_url": f"{run_url}/job/{build_job['id']}",
        "test_job_url": f"{run_url}/job/{test_job['id']}",
    }


def merged_pull_identity(
    current_sha: str, current_parent: str, pull: dict[str, object]
) -> tuple[int, str, str]:
    base = pull.get("base")
    head = pull.get("head")
    if not isinstance(base, dict) or not isinstance(head, dict):
        raise ContractError("PR CI reuse pull metadata is malformed.")
    pr_number = pull.get("number")
    base_sha = base.get("sha")
    head_sha = head.get("sha")
    if (
        not isinstance(pr_number, int)
        or pr_number < 1
        or base.get("ref") != "main"
        or base_sha != current_parent
        or not isinstance(head_sha, str)
        or pull.get("merge_commit_sha") != current_sha
        or not isinstance(pull.get("merged_at"), str)
    ):
        raise ContractError("PR CI reuse requires the exact merged PR and protected-main base.")
    return pr_number, base_sha, head_sha


def successful_pr_run_identity(
    head_sha: str, run: dict[str, object]
) -> tuple[int, int, str]:
    run_id = run.get("id")
    run_attempt = run.get("run_attempt")
    run_url = run.get("html_url")
    if (
        run.get("event") != "pull_request"
        or run.get("head_sha") != head_sha
        or run.get("status") != "completed"
        or run.get("conclusion") != "success"
        or not isinstance(run_id, int)
        or run_id < 1
        or not isinstance(run_attempt, int)
        or run_attempt < 1
        or not isinstance(run_url, str)
        or not run_url.startswith("https://github.com/")
    ):
        raise ContractError("PR CI reuse requires a successful exact-head pull_request run.")
    return run_id, run_attempt, run_url


def validate_evidence_job(jobs: list[dict[str, object]]) -> None:
    changes_jobs = [job for job in jobs if isinstance(job, dict) and job.get("name") == "changes"]
    if len(changes_jobs) != 1 or changes_jobs[0].get("conclusion") != "success":
        raise ContractError("PR CI reuse requires one successful changes job.")
    changes_steps = changes_jobs[0].get("steps")
    if not isinstance(changes_steps, list):
        raise ContractError("PR CI reuse changes steps are missing.")
    changes_results = {
        step.get("name"): step.get("conclusion")
        for step in changes_steps
        if isinstance(step, dict)
    }
    if (
        changes_results.get("Archive PR validation evidence") != "success"
        or changes_results.get("Upload PR validation evidence") != "success"
    ):
        raise ContractError("PR CI reuse requires the exact archived validation evidence.")


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


def build_parser() -> argparse.ArgumentParser:
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

    reuse = subparsers.add_parser("ci-reuse")
    reuse.add_argument("--proof-sha", required=True)
    reuse.add_argument("--run", required=True)
    reuse.add_argument("--jobs", required=True)

    pr_reuse = subparsers.add_parser("pr-ci-reuse")
    pr_reuse.add_argument("--repository", required=True)
    pr_reuse.add_argument("--current-sha", required=True)
    pr_reuse.add_argument("--current-parent", required=True)
    pr_reuse.add_argument("--current-tree", required=True)
    pr_reuse.add_argument("--plan-sha", required=True)
    pr_reuse.add_argument("--pull", required=True)
    pr_reuse.add_argument("--run", required=True)
    pr_reuse.add_argument("--jobs", required=True)
    pr_reuse.add_argument("--evidence", required=True)

    dispatch = subparsers.add_parser("dispatch")
    dispatch.add_argument("--marker", default="")
    dispatch.add_argument("--runs", required=True)

    existing = subparsers.add_parser("existing-release")
    existing.add_argument("--metadata", required=True)
    existing.add_argument("--tag", required=True)
    existing.add_argument("--notes", required=True)
    existing.add_argument("--asset", action="append", required=True)
    return parser


def run_command(args: argparse.Namespace) -> dict[str, object]:
    if args.command == "impact":
        return parse_impact(read_text(args.body))
    if args.command == "version":
        parsed = parse_version_env(args.file)
        return {"version": parsed.marketing_text, "build": parsed.build}
    if args.command == "stable-release":
        return select_stable_release(json.loads(read_text(args.releases)))
    if args.command == "plan":
        return validate_release_plan(args)
    if args.command == "ci-reuse":
        run = json.loads(read_text(args.run))
        jobs = json.loads(read_text(args.jobs))
        if not isinstance(run, dict) or not isinstance(jobs, list):
            raise ContractError("CI reuse metadata has an invalid shape.")
        return validate_ci_reuse(args.proof_sha, run, jobs)
    if args.command == "pr-ci-reuse":
        pull = json.loads(read_text(args.pull))
        run = json.loads(read_text(args.run))
        jobs = json.loads(read_text(args.jobs))
        evidence = json.loads(read_text(args.evidence))
        if not all(isinstance(value, dict) for value in (pull, run, evidence)) or not isinstance(
            jobs, list
        ):
            raise ContractError("PR CI reuse metadata has an invalid shape.")
        return validate_pr_ci_reuse(
            args.repository,
            args.current_sha,
            args.current_parent,
            args.current_tree,
            args.plan_sha,
            pull,
            run,
            jobs,
            evidence,
        )
    if args.command == "dispatch":
        return {"action": dispatch_action(args.marker, json.loads(read_text(args.runs)))}
    validate_existing_release(
        json.loads(read_text(args.metadata)), args.tag, read_text(args.notes), args.asset
    )
    return {"valid": True}


def main() -> None:
    parser = build_parser()
    try:
        result = run_command(parser.parse_args())
    except (ContractError, json.JSONDecodeError) as error:
        parser.error(str(error))
    print(json.dumps(result, separators=(",", ":"), sort_keys=True))


if __name__ == "__main__":
    main()
