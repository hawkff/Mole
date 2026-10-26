"""The incident ledger's checker and the risk tiers (scripts/check_incidents.py, scripts/risk_tier.py), each proved
able to fail on a known-bad sample before its pass on the real ledger counts."""
import importlib.util
from pathlib import Path
import sys
import unittest

# A __pycache__ under scripts/ or tests/ is an unknown file to the install inventory test in Install.Tests.ps1.
sys.dont_write_bytecode = True

SCRIPTS = Path(__file__).resolve().parents[1] / "scripts"


def load(name):
    spec = importlib.util.spec_from_file_location(name, SCRIPTS / f"{name}.py")
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


incidents = load("check_incidents")
risk = load("risk_tier")

HEADER = ("## Incidents\n\n| ID | Reported | Symptom | Introduced | Fixed | Layer | Caught by |\n"
          "|---|---|---|---|---|---|---|\n")
GOOD = "| I-01 | 2026-10-26 | A crash | unknown | a56c6a40 | unit | `Known catcher, with a comma` |\n"


class IncidentLedgerTests(unittest.TestCase):

    def check(self, rows, check_commits=False):
        return incidents.problems(HEADER + rows, {"Known catcher, with a comma"}, check_commits)

    def test_a_complete_row_passes(self):
        self.assertEqual(self.check(GOOD), [])

    def test_each_broken_cell_is_named(self):
        cases = {
            "layer x is not one of": GOOD.replace("| unit |", "| x |"),
            "catcher Missing catcher is not defined": GOOD.replace("Known catcher, with a comma", "Missing catcher"),
            "no catcher named": GOOD.replace("`Known catcher, with a comma`", "a test"),
            "Fixed is not a commit": GOOD.replace("a56c6a40", "later"),
            "Introduced is not a commit": GOOD.replace("unknown", "soon"),
            "Reported is not a date": GOOD.replace("2026-10-26", "Oct 26"),
            "I-01 repeats": GOOD + GOOD,
            "expected 7 cells": GOOD.replace(" unit |", ""),
        }
        for message, rows in cases.items():
            with self.subTest(message):
                found = self.check(rows)
                self.assertEqual(len(found), 1, found)
                self.assertIn(message, found[0])

    def test_a_commit_that_does_not_resolve_fails_in_a_full_clone(self):
        if incidents.is_shallow():
            self.skipTest("commits are not resolvable in a shallow clone")
        found = self.check(GOOD.replace("a56c6a40", "0000000"), check_commits=True)
        self.assertEqual(["docs/incidents.md:5: Fixed 0000000 does not resolve"], found)

    def test_rows_outside_the_incidents_section_are_not_read(self):
        found = list(incidents.rows("## Layers\n| a | b |\n" + HEADER + GOOD))
        self.assertEqual([(7, ["I-01", "2026-10-26", "A crash", "unknown", "a56c6a40", "unit",
                               "`Known catcher, with a comma`"])], found)

    def test_catchers_are_read_from_each_kind_of_test(self):
        defined = incidents.defined_names()
        for name in ("selects the only app a search matches",              # Pester It, single quotes
                     "Verifies the checksum without Get-FileHash (#1744)",  # Pester It, double quotes
                     "Never offers <_>",                                     # Pester template name
                     "TestRunPowerShellFallsBackWhenTheFirstHostCannotStart",  # Go test
                     "test_catchers_are_read_from_each_kind_of_test",        # Python test
                     "Test-ProtectedPath"):                                  # PowerShell function
            with self.subTest(name):
                self.assertIn(name, defined)
        for name in ("selects the only app a search", "Never offers Zoom\\data", "No such test anywhere"):
            with self.subTest(name):
                self.assertNotIn(name, defined)

    def test_the_real_ledger_passes(self):
        text = incidents.LEDGER.read_text("utf-8")
        self.assertGreater(sum(1 for _ in incidents.rows(text)), 0)
        self.assertEqual(incidents.problems(text, incidents.defined_names(), not incidents.is_shallow()), [])


class RiskTierTests(unittest.TestCase):

    def names(self, *paths):
        return [name for name, _, _ in risk.tiers_for(list(paths))]

    def test_a_path_takes_every_tier_it_matches_highest_first(self):
        self.assertEqual(["release", "install", "deletion"],
                         self.names("lib/clean/user.ps1", ".github/workflows/test.yml", "bin/update.ps1"))

    def test_the_sensitive_surfaces_are_never_default(self):
        for path, tier in {"scripts/sign-release.ps1": "release", "packaging/winget/tw93.MoleCLI.yaml": "release",
                           ".github/workflows/release-windows.yml": "release", "lib/core/version.ps1": "release",
                           "bin/update.ps1": "install", "install.ps1": "install", "cmd/mo/main.go": "install",
                           "lib/core/file_ops.ps1": "deletion", "bin/uninstall.ps1": "deletion",
                           "cmd/analyze/delete.go": "deletion", "lib\\core\\base.ps1": "deletion"}.items():
            with self.subTest(path):
                self.assertIn(tier, self.names(path))

    def test_docs_tests_and_read_only_code_need_only_the_default_gate(self):
        self.assertEqual([], self.names("docs/incidents.md", "AGENTS.md", "tests/Clean.Tests.ps1",
                                        "cmd/status/view.go", "cmd/analyze/view.go", "bin/status.ps1"))

    def test_every_tier_pattern_matches_a_real_path(self):
        # A pattern that matches nothing protects nothing: a rename would silently drop a file to the default tier.
        tracked = risk.git("ls-files")
        self.assertGreater(len(tracked), 100)
        for name, _, patterns in risk.TIERS:
            for pattern in patterns:
                with self.subTest(f"{name}: {pattern}"):
                    self.assertTrue(any(risk.fnmatch.fnmatchcase(p, pattern) for p in tracked))


if __name__ == "__main__":
    unittest.main()
