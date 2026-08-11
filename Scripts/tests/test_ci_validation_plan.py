import importlib.util
import sys
import unittest
from pathlib import Path


SCRIPT = Path(__file__).parents[1] / "ci_validation_plan.py"
SPEC = importlib.util.spec_from_file_location("ci_validation_plan", SCRIPT)
planner = importlib.util.module_from_spec(SPEC)
assert SPEC.loader is not None
sys.modules[SPEC.name] = planner
SPEC.loader.exec_module(planner)


class CIValidationPlanTests(unittest.TestCase):
    def assert_plan(self, paths, *, swift, ui_scope, ui_groups, modules, risks):
        plan = planner.plan_validation(paths)
        self.assertEqual(plan["swift"], swift)
        self.assertEqual(plan["ui_scope"], ui_scope)
        self.assertEqual(plan["ui_groups"], ui_groups)
        self.assertEqual(plan["modules"], modules)
        self.assertEqual(plan["risks"], risks)
        self.assertEqual(plan["uncovered_risks"], [])
        self.assertTrue(plan["checks"])
        self.assertTrue(plan["escalation_conditions"])
        return plan

    def test_documentation_uses_the_quick_plan(self):
        self.assert_plan(
            ["README.md"],
            swift=False,
            ui_scope="none",
            ui_groups="",
            modules=["documentation"],
            risks=["documentation"],
        )

    def test_product_logic_runs_build_and_swift_tests_without_ui(self):
        plan = self.assert_plan(
            ["Sources/SkillsManager/Skills/Remote/RemoteSkill.swift"],
            swift=True,
            ui_scope="none",
            ui_groups="",
            modules=["remote"],
            risks=["product-logic"],
        )
        self.assertEqual(plan["checks"], ["swift-build", "swift-tests"])

    def test_leaf_ui_selects_only_its_journey(self):
        self.assert_plan(
            ["Sources/SkillsManager/Skills/Remote/RemoteSkillDetailView.swift"],
            swift=True,
            ui_scope="targeted",
            ui_groups="remote-install",
            modules=["remote"],
            risks=["journey-ui"],
        )

    def test_shared_state_and_runner_require_full_ui(self):
        for path, module in (
            ("Sources/SkillsManager/Skills/Shared/SkillResultCenter.swift", "shared-product-state"),
            ("Scripts/run_ui_tests.sh", "ci-validation"),
            (".github/workflows/full-regression.yml", "ci-validation"),
        ):
            with self.subTest(path=path):
                self.assert_plan(
                    [path],
                    swift=True,
                    ui_scope="full",
                    ui_groups="full",
                    modules=[module],
                    risks=[
                        "cross-journey-state"
                        if module == "shared-product-state"
                        else "cross-journey-test-infrastructure"
                    ],
                )

    def test_release_only_keeps_exact_reuse_and_full_fallback(self):
        plan = self.assert_plan(
            ["version.env", "RELEASE_NOTES.md"],
            swift=True,
            ui_scope="full",
            ui_groups="full",
            modules=["release-metadata"],
            risks=["release-contract"],
        )
        self.assertTrue(plan["release_only"])
        self.assertIn("exact-main-ci-reuse", plan["checks"])
        self.assertIn("fallback-full-macos", plan["checks"])

    def test_mixed_leaf_ui_unions_groups_in_stable_order(self):
        self.assert_plan(
            [
                "Sources/SkillsManager/Skills/Update/SkillUpdateCheckView.swift",
                "Sources/SkillsManager/Skills/Remote/RemoteSkillDetailView.swift",
            ],
            swift=True,
            ui_scope="targeted",
            ui_groups="remote-install,update-distribution",
            modules=["remote", "update"],
            risks=["journey-ui"],
        )

    def test_unknown_product_path_fails_instead_of_guessing(self):
        for paths in (
            ["Sources/SkillsManager/Skills/Future/schema.json"],
            ["README.md", "Unknown.product"],
            [],
        ):
            with self.subTest(paths=paths), self.assertRaises(planner.PlanError):
                planner.plan_validation(paths)


if __name__ == "__main__":
    unittest.main()
