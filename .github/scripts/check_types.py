"""Checks that wrong code fails to type-check.

Every file in tests/types/fail is analyzed on its own with luau-lsp. Each
declares the error it must produce on one or more lines like

    -- expect: Expected this to be 'number', but got 'string'

A file passes when luau-lsp reports, for that file only, exactly as many
diagnostics as it has expect lines and every expected text appears in the
output. A file that type-checks cleanly, reports errors elsewhere (in the
library, say) or reports extra errors fails the run. (tests/types/pass is
part of the normal type check: it must be clean.)

    python .github/scripts/check_types.py --luau-lsp luau-lsp \\
        --sourcemap sourcemap.json --definitions globalTypes.d.luau

Exit status: 0 if every file behaved, 1 otherwise.
"""

import argparse
import re
import subprocess
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
FAIL_DIR = ROOT / "tests" / "types" / "fail"
# A diagnostic header: path(line,col): Kind: message
DIAGNOSTIC = re.compile(r"^(?P<path>.+?\.luau)\((?P<line>\d+),(?P<col>\d+)\): (?P<kind>\w+): ")
EXPECT = re.compile(r"^--\s*expect:\s*(?P<text>.+?)\s*$")


def analyze(luau_lsp: str, sourcemap: str, definitions: str, path: Path) -> str:
    command = [
        luau_lsp,
        "analyze",
        "--platform=roblox",
        f"--sourcemap={sourcemap}",
        f"--definitions=@roblox={definitions}",
        f"--base-luaurc={ROOT / '.luaurc'}",
        str(path.relative_to(ROOT)),
    ]
    result = subprocess.run(command, cwd=ROOT, capture_output=True, text=True, encoding="utf-8", errors="replace")
    return result.stdout + result.stderr


def check(luau_lsp: str, sourcemap: str, definitions: str, path: Path) -> list[str]:
    expected = [m.group("text") for line in path.read_text(encoding="utf-8").splitlines() if (m := EXPECT.match(line))]
    if not expected:
        return ["has no '-- expect:' line"]
    output = analyze(luau_lsp, sourcemap, definitions, path)
    own = path.relative_to(ROOT).as_posix()
    # luau-lsp can print the same diagnostic more than once.
    diagnostics: set[tuple[str, str, str, str]] = set()
    foreign: set[str] = set()
    for line in output.splitlines():
        match = DIAGNOSTIC.match(line)
        if not match:
            continue
        reported = match.group("path").replace("\\", "/")
        if reported.endswith(own):
            diagnostics.add((match.group("line"), match.group("col"), match.group("kind"), line))
        else:
            foreign.add(line)
    problems = []
    if foreign:
        problems.append("errors outside this file:\n    " + "\n    ".join(sorted(foreign)))
    if not diagnostics:
        problems.append("type-checked cleanly, but it must not")
    elif len(diagnostics) != len(expected):
        found = "\n    ".join(entry[3] for entry in sorted(diagnostics))
        problems.append(f"expected {len(expected)} diagnostic(s), got {len(diagnostics)}:\n    {found}")
    for text in expected:
        if text not in output:
            problems.append(f"missing expected text: {text}")
    if problems:
        problems.append("luau-lsp output:\n" + "\n".join("    " + line for line in output.splitlines() if line.strip()))
    return problems


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--luau-lsp", default="luau-lsp")
    parser.add_argument("--sourcemap", default="sourcemap.json")
    parser.add_argument("--definitions", required=True, help="Roblox globalTypes.d.luau")
    args = parser.parse_args()
    # A relative path to the executable is resolved here: subprocess doesn't
    # resolve it against cwd on Windows.
    if Path(args.luau_lsp).exists():
        args.luau_lsp = str(Path(args.luau_lsp).resolve())

    files = sorted(FAIL_DIR.glob("*.luau"))
    if not files:
        print(f"No type tests found in {FAIL_DIR}")
        return 1
    failed = 0
    for path in files:
        problems = check(args.luau_lsp, args.sourcemap, args.definitions, path)
        name = path.relative_to(ROOT).as_posix()
        if problems:
            failed += 1
            print(f"FAIL {name}")
            for problem in problems:
                print("  " + problem)
        else:
            print(f"ok   {name}")
    print(f"{len(files) - failed} of {len(files)} type tests behaved")
    return 1 if failed else 0


if __name__ == "__main__":
    sys.exit(main())
