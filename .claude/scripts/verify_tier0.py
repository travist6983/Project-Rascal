#!/usr/bin/env python3
"""Tier 0 of /verify: deterministic, no-LLM checks over the working-tree diff against a base
branch. Prints a machine-readable JSON report to stdout and a short human summary to stderr.
Exit code 0 means "no hard failures" (formatter/linter/test failures) -- invariant flags and
"not configured" tooling are reported but never fail the run; they're what Tier 1 reads to
decide what needs a human-grade look.

Never invents a result for tooling that isn't installed (no pytest-cov, no mypy/pyright in
this repo as of when this script was written) -- reports "not_configured" instead. A skipped
check is not a passed check.
"""

from __future__ import annotations

import json
import re
import subprocess
import sys
import time
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parents[2]
API_DIR = REPO_ROOT / "api"
LOCK_DIR = REPO_ROOT / ".claude" / ".verify-pytest.lock"
LOCK_TIMEOUT_S = 300
LOCK_POLL_S = 2

ACCESS_DEP_NAMES = {
    "child_access",
    "child_access_from_query",
    "child_access_from_body",
    "entry_access",
    "entry_access_from_body",
    "media_access",
    "assignment_access",
    "family_access",
    "ReadAccess",
    "WriteAccess",
    "require_child_access",
    "require_family_access",
}
PATH_PARAM_RE = re.compile(r"\{(child_id|entry_id|media_id|assignment_id|family_id)\}")
ROUTE_DECORATOR_RE = re.compile(r"^\s*@router\.(get|post|patch|put|delete)\(")
TEST_DEF_RE = re.compile(r"^\s*(async\s+)?def\s+test_", re.M)

SWIFT_TEST_ATTR_RE = re.compile(r"^\s*@Test\b", re.M)
SWIFT_MODEL_RE = re.compile(r"^\s*@Model\b")
SWIFT_CLASS_RE = re.compile(r"^\s*(final\s+)?class\s+\w+")
# A stored, non-optional property with no default at the declaration -- SwiftData migration
# rewrites existing rows without calling init, so this is the exact shape that crashes the
# store on open (ios/CLAUDE.md rule 6). Excludes anything with `?`/`=`/a trailing `{` (computed
# properties) on the same line.
SWIFT_RISKY_PROPERTY_RE = re.compile(
    r"^\s*(public |private |internal |fileprivate )?var\s+\w+\s*:\s*[\w.\[\]<>]+\s*$"
)
SWIFT_HARDCODED_URL_RE = re.compile(r'"https?://[^"]+"')
# `!` force-unwrap/force-cast/force-try, heuristic: excludes `!=` and `!` used as boolean not
# (`!foo`) by requiring it directly after an identifier char or `)`/`]`.
SWIFT_FORCE_UNWRAP_RE = re.compile(r"(?<![=!])\b\w+!(?=[.\s)\],;]|$)|\bas!\s|\btry!\s")
PBXPROJ_SPM_RE = re.compile(r"XCRemoteSwiftPackageReference")


def run(cmd: list[str], cwd: Path | None = None) -> subprocess.CompletedProcess:
    return subprocess.run(cmd, cwd=cwd, capture_output=True, text=True)


def git(*args: str) -> str:
    result = run(["git", *args], cwd=REPO_ROOT)
    return result.stdout.strip()


def show_at_ref(ref: str, path: str) -> str | None:
    result = run(["git", "show", f"{ref}:{path}"], cwd=REPO_ROOT)
    if result.returncode != 0:
        return None
    return result.stdout


def classify_lane(path: str) -> str:
    if path.startswith("api/"):
        return "api"
    if path.startswith("ios/"):
        return "ios"
    if path.startswith("docs/") or path == "CLAUDE.md" or path.startswith(".claude/"):
        return "shared"
    return "other"


def acquire_lock() -> bool:
    """Atomic mkdir-based lock so at most one pytest run touches the test DB at a time."""
    deadline = time.monotonic() + LOCK_TIMEOUT_S
    while time.monotonic() < deadline:
        try:
            LOCK_DIR.mkdir()
            return True
        except FileExistsError:
            time.sleep(LOCK_POLL_S)
    return False


def release_lock() -> None:
    try:
        LOCK_DIR.rmdir()
    except FileNotFoundError:
        pass


def check_formatter(api_changed: bool) -> dict:
    if not api_changed:
        return {"status": "skipped", "detail": "no api/ files changed"}
    result = run(["uv", "run", "ruff", "format", "--check", ".", "../.github"], cwd=API_DIR)
    return {
        "status": "pass" if result.returncode == 0 else "fail",
        "detail": (result.stdout + result.stderr).strip()[-4000:],
    }


def check_linter(api_changed: bool) -> dict:
    if not api_changed:
        return {"status": "skipped", "detail": "no api/ files changed"}
    result = run(["uv", "run", "ruff", "check", ".", "../.github"], cwd=API_DIR)
    return {
        "status": "pass" if result.returncode == 0 else "fail",
        "detail": (result.stdout + result.stderr).strip()[-4000:],
    }


def check_type_checker(api_changed: bool) -> dict:
    return {
        "status": "not_configured",
        "detail": "no mypy/pyright config in api/pyproject.toml -- ruff's UP/F rules catch "
        "some type-adjacent issues but this is not a full type checker",
    }


def check_tests(api_changed: bool) -> dict:
    if not api_changed:
        return {"status": "skipped", "detail": "no api/ files changed"}
    if not acquire_lock():
        return {
            "status": "error",
            "detail": f"could not acquire {LOCK_DIR} within {LOCK_TIMEOUT_S}s -- "
            "another pytest run is holding it",
        }
    try:
        result = run(["uv", "run", "pytest", "-q"], cwd=API_DIR)
    finally:
        release_lock()
    return {
        "status": "pass" if result.returncode == 0 else "fail",
        "detail": (result.stdout + result.stderr).strip()[-6000:],
    }


def check_ios_build(ios_changed: bool) -> dict:
    if not ios_changed:
        return {"status": "skipped", "detail": "no ios/ files changed"}
    return {
        "status": "not_run_here",
        "detail": "a cold xcodebuild (DerivedData deleted first) is the only reliable warning "
        "count -- a warm build under-reports, per this repo's own gotcha -- and a cold build "
        "is minutes, not seconds, which would break Tier 0's fast/cheap design. Not run "
        "automatically; run it yourself before trusting a 'zero warnings' claim.",
    }


def check_coverage_diff(api_changed: bool) -> dict:
    return {
        "status": "not_configured",
        "detail": "pytest-cov is not in api/pyproject.toml's dev dependency group -- "
        "no coverage baseline exists to diff against. 'uncovered by tests' below is a "
        "same-diff heuristic (changed source file with no corresponding test file touched), "
        "not a real coverage measurement.",
    }


def added_line_numbers(base: str, head: str | None, path: str, is_untracked: bool) -> set[int]:
    """Line numbers (1-indexed, in the CURRENT file) that are new vs base.

    A whole untracked file counts as entirely added. Otherwise parsed from a zero-context
    unified diff, which is precise about which lines are additions vs unchanged context.
    """
    full_path = REPO_ROOT / path
    if is_untracked:
        if not full_path.exists():
            return set()
        return set(range(1, len(full_path.read_text().splitlines()) + 1))
    diff_args = ["diff", "-U0", base] + ([head] if head else []) + ["--", path]
    output = run(["git", *diff_args], cwd=REPO_ROOT).stdout
    added = set()
    current_line = None
    for line in output.splitlines():
        if line.startswith("@@"):
            m = re.search(r"\+(\d+)(?:,(\d+))?", line)
            if m:
                current_line = int(m.group(1))
        elif line.startswith("+") and not line.startswith("+++"):
            if current_line is not None:
                added.add(current_line)
                current_line += 1
        elif line.startswith("-") and not line.startswith("---"):
            pass  # deletions don't consume a line number in the current file
        elif current_line is not None and not line.startswith("\\"):
            current_line += 1
    return added


def invariant_swiftdata_migration_defaults(
    changed_files: list[str], base: str, head: str | None, untracked: set[str]
) -> dict:
    flags = []
    for f in changed_files:
        if not (f.startswith("ios/") and f.endswith(".swift")) or "Tests" in f:
            continue
        path = REPO_ROOT / f
        if not path.exists():
            continue
        lines = path.read_text().splitlines()
        added = added_line_numbers(base, head, f, f in untracked)

        state = "outside"  # outside -> saw_model -> in_body
        depth = 0
        body_start_depth = 0
        for i, line in enumerate(lines, start=1):
            if state == "outside" and SWIFT_MODEL_RE.match(line):
                state = "saw_model"
            elif state == "saw_model" and SWIFT_CLASS_RE.match(line):
                body_start_depth = depth  # depth just BEFORE this line's own braces
                state = "in_body"
            elif state == "in_body":
                if i in added and SWIFT_RISKY_PROPERTY_RE.match(line):
                    flags.append(
                        {
                            "file": f,
                            "line": i,
                            "snippet": line.strip(),
                            "detail": "new non-optional @Model property with no default at "
                            "the declaration -- migration rewrites existing rows without "
                            "calling init, so this crashes the store on open",
                        }
                    )

            depth += line.count("{") - line.count("}")

            if state == "in_body" and depth <= body_start_depth:
                state = "outside"  # class body closed
    return {
        "status": "flag" if flags else "pass",
        "flags": flags,
        "detail": "heuristic brace-tracking, not a real parser -- a flag means look, "
        "confirm against ios/CLAUDE.md rule 6" if flags else "ok",
    }


def invariant_hardcoded_config(
    changed_files: list[str], base: str, head: str | None, untracked: set[str]
) -> dict:
    flags = []
    for f in changed_files:
        if not (f.startswith("ios/") and f.endswith(".swift")):
            continue
        if "Tests" in f or "Fixtures" in f or f.endswith(".xcconfig.example"):
            continue
        path = REPO_ROOT / f
        if not path.exists():
            continue
        lines = path.read_text().splitlines()
        added = added_line_numbers(base, head, f, f in untracked)
        for i, line in enumerate(lines, start=1):
            if i not in added:
                continue
            stripped = line.strip()
            if stripped.startswith("//"):
                continue
            if SWIFT_HARDCODED_URL_RE.search(line):
                flags.append({"file": f, "line": i, "snippet": stripped})
    return {
        "status": "flag" if flags else "pass",
        "flags": flags,
        "detail": "new literal http(s):// string outside Config.xcconfig -- ios/CLAUDE.md rule "
        "5 says base URL comes from Info.plist via API_BASE_URL, never a hardcoded string"
        if flags else "ok",
    }


def invariant_force_unwraps(
    changed_files: list[str], base: str, head: str | None, untracked: set[str]
) -> dict:
    flags = []
    for f in changed_files:
        if not (f.startswith("ios/") and f.endswith(".swift")) or "Tests" in f:
            continue
        path = REPO_ROOT / f
        if not path.exists():
            continue
        lines = path.read_text().splitlines()
        added = added_line_numbers(base, head, f, f in untracked)
        for i, line in enumerate(lines, start=1):
            if i not in added:
                continue
            if SWIFT_FORCE_UNWRAP_RE.search(line):
                flags.append({"file": f, "line": i, "snippet": line.strip()})
    return {
        "status": "flag" if flags else "pass",
        "flags": flags,
        "detail": "new force-unwrap/force-cast/force-try in the diff -- not automatically wrong, "
        "but this is the crash-prone pattern the ios-reviewer agent specifically looks for; "
        "heuristic regex, expect some false positives" if flags else "ok",
    }


def invariant_third_party_deps(changed_files: list[str], base: str) -> dict:
    flags = []
    if any(f in ("ios/Package.swift", "ios/Podfile") for f in changed_files):
        flags.append({"detail": "Package.swift or Podfile touched -- ios/CLAUDE.md rule 4: no "
                      "SPM packages, no CocoaPods"})
    pbx = "ios/Rascal/Rascal.xcodeproj/project.pbxproj"
    if pbx in changed_files:
        base_content = show_at_ref(base, pbx) or ""
        current_content = (REPO_ROOT / pbx).read_text() if (REPO_ROOT / pbx).exists() else ""
        base_n = len(PBXPROJ_SPM_RE.findall(base_content))
        current_n = len(PBXPROJ_SPM_RE.findall(current_content))
        if current_n > base_n:
            flags.append(
                {
                    "detail": f"project.pbxproj gained an XCRemoteSwiftPackageReference "
                    f"({base_n} -> {current_n}) -- ios/CLAUDE.md rule 4: no SPM packages",
                }
            )
    return {"status": "flag" if flags else "pass", "flags": flags, "detail": "ok" if not flags else "see flags"}


def invariant_lane_boundary(changed_files: list[str]) -> dict:
    lanes = {classify_lane(f) for f in changed_files}
    violation = "api" in lanes and "ios" in lanes
    return {
        "status": "fail" if violation else "pass",
        "lanes_touched": sorted(lanes),
        "detail": "api/ and ios/ are both touched in this diff -- CLAUDE.md's Two Lanes rule "
        "says an agent working in one lane never edits the other" if violation else "ok",
    }


def invariant_test_deletions(changed_files: list[str], base: str) -> dict:
    violations = []
    for f in changed_files:
        is_py_test = f.startswith("api/tests/") and f.endswith(".py")
        is_swift_test = f.startswith("ios/") and f.endswith(".swift") and "Tests" in f
        if not (is_py_test or is_swift_test):
            continue
        current_path = REPO_ROOT / f
        if not current_path.exists():
            continue  # deleted file entirely -- worth its own eyeball, not this check
        base_content = show_at_ref(base, f)
        if base_content is None:
            continue  # new test file, nothing to compare against
        pattern = TEST_DEF_RE if is_py_test else SWIFT_TEST_ATTR_RE
        base_count = len(pattern.findall(base_content))
        current_count = len(pattern.findall(current_path.read_text()))
        if current_count < base_count:
            violations.append(
                {"file": f, "base_test_count": base_count, "current_test_count": current_count}
            )
    return {
        "status": "flag" if violations else "pass",
        "violations": violations,
        "detail": "fewer `def test_*` (Python) or `@Test` (Swift) in a changed test file than "
        "the base branch had -- could be a legitimate consolidation, could be a silent "
        "deletion" if violations else "ok",
    }


def invariant_gitignore_additions(base: str) -> dict:
    base_content = show_at_ref(base, ".gitignore") or ""
    current_path = REPO_ROOT / ".gitignore"
    current_content = current_path.read_text() if current_path.exists() else ""
    base_lines = {ln.strip() for ln in base_content.splitlines() if ln.strip()}
    current_lines = {ln.strip() for ln in current_content.splitlines() if ln.strip()}
    added = sorted(current_lines - base_lines)
    return {
        "status": "flag" if added else "pass",
        "added_patterns": added,
        "detail": "new .gitignore patterns -- confirm none of these hide build output that "
        "should be reviewable" if added else "ok",
    }


def invariant_auth_scoping(changed_files: list[str], base: str) -> dict:
    flags = []
    router_files = [f for f in changed_files if f.startswith("api/src/rascal/routers/")]
    for f in router_files:
        path = REPO_ROOT / f
        if not path.exists():
            continue
        lines = path.read_text().splitlines()
        for i, line in enumerate(lines):
            if not ROUTE_DECORATOR_RE.match(line):
                continue
            if not PATH_PARAM_RE.search(line):
                continue
            # scan forward to the next @router. decorator or EOF for the function body
            j = i + 1
            block = []
            while j < len(lines) and not ROUTE_DECORATOR_RE.match(lines[j]):
                block.append(lines[j])
                j += 1
            body = "\n".join(block)
            if not any(name in body for name in ACCESS_DEP_NAMES):
                flags.append(
                    {
                        "file": f,
                        "line": i + 1,
                        "route": line.strip(),
                        "detail": "path names a scoped id but no access-dependency name from "
                        "deps.py appears in the handler",
                    }
                )
    deps_file = "api/src/rascal/deps.py"
    if deps_file in changed_files:
        base_content = show_at_ref(base, deps_file) or ""
        current_content = (REPO_ROOT / deps_file).read_text()
        for name in ACCESS_DEP_NAMES:
            base_match = re.search(rf"^(async )?def {name}\(([^)]*)\)", base_content, re.M)
            current_match = re.search(rf"^(async )?def {name}\(([^)]*)\)", current_content, re.M)
            if base_match and current_match:
                base_args = [a.strip().split(":")[0].split("=")[0] for a in base_match.group(2).split(",") if a.strip()]
                current_args = [a.strip().split(":")[0].split("=")[0] for a in current_match.group(2).split(",") if a.strip()]
                dropped = set(base_args) - set(current_args)
                if dropped:
                    flags.append(
                        {
                            "file": deps_file,
                            "function": name,
                            "dropped_params": sorted(dropped),
                            "detail": "this access-dependency function dropped a parameter "
                            "compared to base -- confirm scoping wasn't narrowed",
                        }
                    )
    return {
        "status": "flag" if flags else "pass",
        "flags": flags,
        "detail": "heuristic grep, not a proof -- a flag here means look, not necessarily a "
        "real defect" if flags else "ok",
    }


def build_flagged_hunks(
    changed_files: list[str],
    test_del: dict,
    auth: dict,
    swiftdata: dict,
    hardcoded: dict,
    force_unwrap: dict,
    third_party: dict,
) -> list[dict]:
    flagged = []
    py_tested_stems = {Path(f).stem.removeprefix("test_") for f in changed_files if "/tests/" in f}
    swift_tested_stems = {
        Path(f).stem.removesuffix("Tests") for f in changed_files if "Tests" in f and f.endswith(".swift")
    }
    for f in changed_files:
        if f.startswith("api/src/") and f.endswith(".py"):
            if Path(f).stem not in py_tested_stems:
                flagged.append({"file": f, "reason": "uncovered_by_tests"})
        elif f.startswith("ios/") and f.endswith(".swift") and "Tests" not in f:
            if Path(f).stem not in swift_tested_stems:
                flagged.append({"file": f, "reason": "uncovered_by_tests"})

    invariant_adjacent_files = (
        {v["file"] for v in test_del["violations"]}
        | {fl["file"] for fl in auth["flags"]}
        | {fl["file"] for fl in swiftdata["flags"]}
        | {fl["file"] for fl in hardcoded["flags"]}
        | {fl["file"] for fl in force_unwrap["flags"]}
    )
    if third_party["flags"]:
        invariant_adjacent_files.add("ios/Rascal/Rascal.xcodeproj/project.pbxproj")
    for f in invariant_adjacent_files:
        if not any(h["file"] == f for h in flagged):
            flagged.append({"file": f, "reason": "invariant_adjacent"})
    return flagged


def main() -> int:
    # Normal use: `verify_tier0.py [base]` diffs the working tree (commits + uncommitted) vs
    # base. Replay mode: `verify_tier0.py [base] [head]` diffs two fixed commits, e.g. to run
    # this against an already-merged PR's exact range for validation.
    base = sys.argv[1] if len(sys.argv) > 1 else "origin/main"
    head = sys.argv[2] if len(sys.argv) > 2 else None

    fetch = run(["git", "fetch", "origin"], cwd=REPO_ROOT)
    if fetch.returncode != 0:
        print(f"warning: git fetch origin failed: {fetch.stderr.strip()}", file=sys.stderr)

    if head:
        tracked_changed = [f for f in git("diff", "--name-only", base, head).splitlines() if f]
        untracked_list: list[str] = []
    else:
        tracked_changed = [f for f in git("diff", "--name-only", base).splitlines() if f]
        untracked_list = [f for f in git("ls-files", "--others", "--exclude-standard").splitlines() if f]
    changed_files = sorted(set(tracked_changed) | set(untracked_list))
    untracked = set(untracked_list)
    api_changed = any(f.startswith("api/") for f in changed_files)
    ios_changed = any(f.startswith("ios/") for f in changed_files)

    if not changed_files:
        report = {"base": base, "changed_files": [], "overall": "pass", "detail": "no changes vs base"}
        print(json.dumps(report, indent=2))
        print("verify tier0: nothing to check (no diff vs base)", file=sys.stderr)
        return 0

    formatter = check_formatter(api_changed)
    linter = check_linter(api_changed)
    type_checker = check_type_checker(api_changed)
    tests = check_tests(api_changed)
    coverage = check_coverage_diff(api_changed)
    ios_build = check_ios_build(ios_changed)

    lane = invariant_lane_boundary(changed_files)
    test_del = invariant_test_deletions(changed_files, base)
    gitignore = invariant_gitignore_additions(base)
    auth = invariant_auth_scoping(changed_files, base)
    swiftdata = invariant_swiftdata_migration_defaults(changed_files, base, head, untracked)
    hardcoded = invariant_hardcoded_config(changed_files, base, head, untracked)
    force_unwrap = invariant_force_unwraps(changed_files, base, head, untracked)
    third_party = invariant_third_party_deps(changed_files, base)

    flagged_hunks = build_flagged_hunks(
        changed_files, test_del, auth, swiftdata, hardcoded, force_unwrap, third_party
    )

    # swiftdata migration-default and third-party-dependency violations are hard fails -- both
    # are named, specific crash/policy risks in ios/CLAUDE.md, not judgment calls. Force-unwraps
    # and hardcoded-config stay flag-only: real, but too common and too context-dependent to
    # block a run on without human/Tier-1 judgment.
    hard_fail = (
        any(c["status"] == "fail" for c in (formatter, linter, tests))
        or lane["status"] == "fail"
        or swiftdata["status"] == "flag"
        or third_party["status"] == "flag"
    )

    report = {
        "base": base,
        "changed_files": changed_files,
        "checks": {
            "formatter": formatter,
            "linter": linter,
            "type_checker": type_checker,
            "tests": tests,
            "coverage_diff": coverage,
            "ios_build": ios_build,
        },
        "invariants": {
            "lane_boundary": lane,
            "test_deletions": test_del,
            "gitignore_additions": gitignore,
            "auth_scoping": auth,
            "swiftdata_migration_defaults": swiftdata,
            "hardcoded_config": hardcoded,
            "force_unwraps": force_unwrap,
            "third_party_deps": third_party,
        },
        "flagged_hunks": flagged_hunks,
        "overall": "fail" if hard_fail else "pass",
    }
    print(json.dumps(report, indent=2))

    summary = [
        f"verify tier0: {len(changed_files)} files vs {base}",
        f"  formatter={formatter['status']} linter={linter['status']} "
        f"type_checker={type_checker['status']} tests={tests['status']} "
        f"coverage_diff={coverage['status']} ios_build={ios_build['status']}",
        f"  invariants: lane_boundary={lane['status']} test_deletions={test_del['status']} "
        f"gitignore={gitignore['status']} auth_scoping={auth['status']}",
        f"  ios invariants: swiftdata_migration_defaults={swiftdata['status']} "
        f"hardcoded_config={hardcoded['status']} force_unwraps={force_unwrap['status']} "
        f"third_party_deps={third_party['status']}",
        f"  flagged for tier1: {len(flagged_hunks)} hunk(s)",
        f"  overall: {report['overall']}",
    ]
    print("\n".join(summary), file=sys.stderr)

    return 1 if hard_fail else 0


if __name__ == "__main__":
    sys.exit(main())
