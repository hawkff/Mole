#!/usr/bin/env python3
"""Every row of docs/incidents.md names real commits, a known layer and a catcher the code defines.

    python scripts/check_incidents.py [--verbose]

The incident table is the eval set for the review layers (docs/incidents.md says why). A row fails when its ID
repeats, its Fixed commit is missing or does not resolve, its Introduced commit is neither `unknown` nor a commit,
its layer is not one of LAYERS, or a backticked catcher is not a Pester `It` name, Go test, Python test or
PowerShell function in the code. In a shallow clone (CI checks out one commit) the commits cannot be resolved and
are only shape-checked, which the output says. Standard library only, so it runs on the Mac and the Windows runner.
"""
import re
import subprocess
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
LEDGER = ROOT / "docs" / "incidents.md"
LAYERS = ("write-time", "unit", "lint", "review", "e2e", "release", "field")
COLUMNS = ["ID", "Reported", "Symptom", "Introduced", "Fixed", "Layer", "Caught by"]
SHA = re.compile(r"^[0-9a-f]{7,40}$")

# Pester names are the first string after `It`: single quotes double '' inside, double quotes escape with a backtick.
PESTER_IT = re.compile(r"""^\s*It\s+(?:-Name\s+)?(?:'((?:[^']|'')*)'|"((?:[^"`]|`.)*)")""", re.MULTILINE)
PS_FUNCTION = re.compile(r"^\s*function\s+([A-Za-z][\w-]*)", re.MULTILINE | re.IGNORECASE)
GO_TEST = re.compile(r"^func\s+(Test\w+)\s*\(", re.MULTILINE)
PY_TEST = re.compile(r"^\s*def\s+(test_\w+)\s*\(", re.MULTILINE)


def defined_names() -> set[str]:
    names: set[str] = set()
    for path in sorted(ROOT.glob("tests/**/*.ps1")):
        text = path.read_text("utf-8-sig", errors="replace")
        for single, double in PESTER_IT.findall(text):
            names.add(single.replace("''", "'") if single else re.sub(r"`(.)", r"\1", double))
    for path in [*ROOT.glob("*.ps1"), *ROOT.glob("bin/*.ps1"), *ROOT.glob("lib/**/*.ps1"), *ROOT.glob("scripts/*.ps1")]:
        names.update(PS_FUNCTION.findall(path.read_text("utf-8-sig", errors="replace")))
    for path in ROOT.glob("cmd/**/*_test.go"):
        names.update(GO_TEST.findall(path.read_text("utf-8", errors="replace")))
    for path in ROOT.glob("tests/**/*.py"):
        names.update(PY_TEST.findall(path.read_text("utf-8", errors="replace")))
    return names


def rows(text: str):
    """The table under '## Incidents' as (line number, cells), header and rule excluded."""
    section = False
    for number, line in enumerate(text.splitlines(), 1):
        if line.startswith("## "):
            section = line.strip() == "## Incidents"
            continue
        if section and line.startswith("|"):
            cells = [cell.strip() for cell in line.strip().strip("|").split("|")]
            if cells == COLUMNS or set("".join(cells)) <= set("-: "):
                continue
            yield number, cells


def git(*args: str) -> subprocess.CompletedProcess:
    return subprocess.run(["git", "-C", str(ROOT), *args], capture_output=True, text=True)


def is_shallow() -> bool:
    return git("rev-parse", "--is-shallow-repository").stdout.strip() == "true"


def resolves(sha: str) -> bool:
    return git("cat-file", "-e", sha + "^{commit}").returncode == 0


def problems(text: str, defined: set[str], check_commits: bool) -> list[str]:
    found, seen = [], set()
    for number, cells in rows(text):
        where = f"docs/incidents.md:{number}"
        if len(cells) != len(COLUMNS):
            found.append(f"{where}: expected {len(COLUMNS)} cells, found {len(cells)}")
            continue
        row = dict(zip(COLUMNS, cells))
        if row["ID"] in seen:
            found.append(f"{where}: {row['ID']} repeats")
        seen.add(row["ID"])
        if not re.fullmatch(r"\d{4}-\d{2}-\d{2}", row["Reported"]):
            found.append(f"{where}: Reported is not a date: {row['Reported']}")
        for column, optional in (("Fixed", False), ("Introduced", True)):
            value = row[column]
            if optional and value == "unknown":
                continue
            if not SHA.match(value):
                found.append(f"{where}: {column} is not a commit: {value}")
            elif check_commits and not resolves(value):
                found.append(f"{where}: {column} {value} does not resolve")
        if row["Layer"] not in LAYERS:
            found.append(f"{where}: layer {row['Layer']} is not one of {', '.join(LAYERS)}")
        catchers = re.findall(r"`([^`]+)`", row["Caught by"])
        if not catchers:
            found.append(f"{where}: no catcher named")
        found.extend(f"{where}: catcher {name} is not defined in the code" for name in catchers if name not in defined)
    return found


def main() -> int:
    shallow = is_shallow()
    text = LEDGER.read_text("utf-8")
    found = problems(text, defined_names(), check_commits=not shallow)
    for row in found:
        print(row)
    if "--verbose" in sys.argv or found or shallow:
        note = ", commits shape-checked only (shallow clone)" if shallow else ""
        print(f"checked {sum(1 for _ in rows(text))} incidents, {len(found)} problems{note}", file=sys.stderr)
    return 1 if found else 0


if __name__ == "__main__":
    sys.exit(main())
