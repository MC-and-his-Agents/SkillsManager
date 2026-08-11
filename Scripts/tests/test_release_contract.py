import importlib.util
import sys
import tempfile
import unittest
from argparse import Namespace
from pathlib import Path


SCRIPT = Path(__file__).parents[1] / "release_contract.py"
SPEC = importlib.util.spec_from_file_location("release_contract", SCRIPT)
contract = importlib.util.module_from_spec(SPEC)
assert SPEC.loader is not None
sys.modules[SPEC.name] = contract
SPEC.loader.exec_module(contract)


class ReleaseContractTests(unittest.TestCase):
    def test_release_impact_requires_one_exact_declaration(self):
        self.assertEqual(contract.parse_impact("release_impact: none\n")["impact"], "none")
        self.assertEqual(contract.parse_impact("release_impact: patch\r\n")["impact"], "patch")
        self.assertEqual(contract.parse_impact("release_impact: minor\n")["impact"], "minor")
        self.assertEqual(
            contract.parse_impact("release_impact: bundled #152\n"),
            {"impact": "bundled", "issue": 152},
        )
        hostile = "release_impact: patch $(touch /tmp/never)\n"
        for body in ("", hostile, "release_impact: patch\nrelease_impact: none\n"):
            with self.assertRaises(contract.ContractError):
                contract.parse_impact(body)

    def test_version_env_is_data_not_shell(self):
        with tempfile.TemporaryDirectory() as directory:
            version_file = Path(directory) / "version.env"
            version_file.write_text("MARKETING_VERSION=0.2.1\nBUILD_NUMBER=3\n")
            parsed = contract.parse_version_env(str(version_file))
            self.assertEqual((parsed.marketing_text, parsed.build), ("0.2.1", 3))
            invalid = [
                "MARKETING_VERSION=$(touch /tmp/never)\nBUILD_NUMBER=3\n",
                "MARKETING_VERSION=0.2.1\r\nBUILD_NUMBER=3\r\n",
                "MARKETING_VERSION=0.2.1\nBUILD_NUMBER=3\nEXTRA=value\n",
                "MARKETING_VERSION=0.2.1\nMARKETING_VERSION=0.2.2\n",
                "MARKETING_VERSION=0.2.1-beta\nBUILD_NUMBER=3\n",
            ]
            for contents in invalid:
                version_file.write_bytes(contents.encode())
                with self.assertRaises(contract.ContractError):
                    contract.parse_version_env(str(version_file))

    def test_stable_release_ignores_orphan_draft_and_prerelease_tags(self):
        releases = [
            {"tagName": "v0.2.0", "isDraft": False, "isPrerelease": False},
            {"tagName": "v9.0.0", "isDraft": True, "isPrerelease": False},
            {"tagName": "v1.0.0-beta", "isDraft": False, "isPrerelease": True},
            {"tagName": "v0.1.9", "isDraft": False, "isPrerelease": False},
        ]
        self.assertEqual(contract.select_stable_release(releases)["tag"], "v0.2.0")
        for malformed in (
            [{"tagName": "v0.2.0", "isPrerelease": False}],
            [{"tagName": "v0.2.0", "isDraft": "false", "isPrerelease": False}],
        ):
            with self.assertRaises(contract.ContractError):
                contract.select_stable_release(malformed)

    def test_release_plan_enforces_paths_version_build_and_issue(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            files = {
                "current": "MARKETING_VERSION=0.2.1\nBUILD_NUMBER=3\n",
                "previous": "MARKETING_VERSION=0.2.0\nBUILD_NUMBER=2\n",
                "paths": "RELEASE_NOTES.md\nversion.env\n",
                "pr": "release_impact: bundled #152\n",
                "issue": "release_impact: patch\n",
                "notes": "# Skills Manager 0.2.1\n\n- Fix.\n",
            }
            paths = {}
            for name, contents in files.items():
                paths[name] = root / name
                paths[name].write_text(contents)
            args = Namespace(
                current_version=str(paths["current"]),
                previous_version=str(paths["previous"]),
                changed_paths=str(paths["paths"]),
                pr_body=str(paths["pr"]),
                issue_body=str(paths["issue"]),
                release_notes=str(paths["notes"]),
            )
            self.assertEqual(contract.validate_release_plan(args)["tag"], "v0.2.1")
            paths["paths"].write_text("Sources/App.swift\nversion.env\n")
            with self.assertRaises(contract.ContractError):
                contract.validate_release_plan(args)

    def test_dispatch_state_is_bounded_and_never_implicitly_retries(self):
        self.assertEqual(contract.dispatch_action("", []), "dispatch")
        self.assertEqual(
            contract.dispatch_action("pending", [{"status": "in_progress", "conclusion": None}]),
            "observe",
        )
        self.assertEqual(
            contract.dispatch_action("success", [{"status": "completed", "conclusion": "success"}]),
            "published",
        )
        self.assertEqual(
            contract.dispatch_action("failure", [{"status": "completed", "conclusion": "failure"}]),
            "rerun",
        )
        for marker, runs in (("pending", []), ("", [{}, {}])):
            with self.assertRaises(contract.ContractError):
                contract.dispatch_action(marker, runs)

    def test_ci_reuse_requires_exact_main_run_and_real_test_step(self):
        sha = "a" * 40
        run = {
            "id": 123,
            "run_attempt": 2,
            "html_url": "https://github.com/example/repo/actions/runs/123",
            "event": "push",
            "head_branch": "main",
            "head_sha": sha,
            "status": "completed",
            "conclusion": "success",
        }
        jobs = [
            {
                "id": 455,
                "name": "build",
                "conclusion": "success",
                "steps": [
                    {"name": "Build", "conclusion": "success"},
                    {"name": "Skip Swift build", "conclusion": "skipped"},
                ],
            },
            {
                "id": 456,
                "name": "test",
                "conclusion": "success",
                "steps": [
                    {"name": "Test", "conclusion": "success"},
                    {"name": "Skip Swift tests", "conclusion": "skipped"},
                ],
            }
        ]
        proof = contract.validate_ci_reuse(sha, run, jobs)
        self.assertEqual(proof["run_attempt"], 2)
        self.assertEqual(proof["test_job_url"], f"{run['html_url']}/job/456")

        invalid = [
            ({**run, "head_sha": "b" * 40}, jobs),
            ({**run, "event": "pull_request"}, jobs),
            ({**run, "conclusion": "failure"}, jobs),
            (run, [{**jobs[0], "conclusion": "failure"}, jobs[1]]),
            (
                run,
                [
                    jobs[0],
                    {
                        **jobs[1],
                        "steps": [
                            {"name": "Test", "conclusion": "skipped"},
                            {"name": "Skip Swift tests", "conclusion": "success"},
                        ],
                    }
                ],
            ),
        ]
        for bad_run, bad_jobs in invalid:
            with self.assertRaises(contract.ContractError):
                contract.validate_ci_reuse(sha, bad_run, bad_jobs)

    def test_existing_release_must_be_complete_and_byte_comparison_ready(self):
        metadata = {
            "tagName": "v0.2.1",
            "isDraft": False,
            "isPrerelease": False,
            "body": "notes\n",
            "assets": [{"name": "SkillsManager-0.2.1.zip"}, {"name": "appcast.xml"}],
        }
        contract.validate_existing_release(
            metadata,
            "v0.2.1",
            "notes\n",
            ["SkillsManager-0.2.1.zip", "appcast.xml"],
        )
        metadata["assets"] = [{"name": "appcast.xml"}]
        with self.assertRaises(contract.ContractError):
            contract.validate_existing_release(
                metadata,
                "v0.2.1",
                "notes\n",
                ["SkillsManager-0.2.1.zip", "appcast.xml"],
            )


if __name__ == "__main__":
    unittest.main()
