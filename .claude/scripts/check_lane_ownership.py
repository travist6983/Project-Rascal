#!/usr/bin/env python3
"""Run from inside a /phase lane's worktree before any commit. Reads that worktree's own
LANE.json, diffs the working tree against its base, and fails if anything changed that isn't
under an owned path. This is the mechanism, not the prompt -- a lane agent is told to run this
and treat a non-zero exit as "write a CONTRACT_REQUEST instead," but the check itself doesn't
trust that instruction, it trusts the diff.

Exit 0: every changed file is under an owned path (or the file is genuinely new and not yet
tracked -- still checked, an out-of-lane new file is exactly what this exists to catch).
Exit 1: something outside the lane's owned paths changed. Prints exactly what and why.
"""

from __future__ import annotations

import json
import subprocess
import sys
from pathlib import Path


def run(cmd: list[str], cwd: Path) -> subprocess.CompletedProcess:
    return subprocess.run(cmd, cwd=cwd, capture_output=True, text=True)


def owns(path: str, owned_paths: list[str]) -> bool:
    for owned in owned_paths:
        if owned.endswith("/"):
            if path.startswith(owned):
                return True
        elif path == owned:
            return True
    return False


def main() -> int:
    cwd = Path.cwd()
    lane_json_path = cwd / "LANE.json"
    if not lane_json_path.exists():
        # allow pointing at a specific worktree explicitly, for when this is invoked from the
        # main repo rather than from inside the worktree itself
        if len(sys.argv) > 1:
            lane_json_path = Path(sys.argv[1]) / "LANE.json"
        if not lane_json_path.exists():
            print(json.dumps({"error": f"no LANE.json at {lane_json_path} -- not a phase lane worktree"}))
            return 2

    lane = json.loads(lane_json_path.read_text())
    worktree = Path(lane["worktree_path"])
    owned_paths = lane["owned_paths"]
    base = lane["base"]

    tracked = [f for f in run(["git", "diff", "--name-only", base], worktree).stdout.splitlines() if f]
    untracked = [
        f for f in run(["git", "ls-files", "--others", "--exclude-standard"], worktree).stdout.splitlines() if f
    ]
    changed = sorted(set(tracked) | set(untracked))

    # LANE.json is orchestrator infrastructure written by phase_lane_setup.py, never a lane
    # deliverable -- it should never itself count as an ownership violation.
    checkable = [f for f in changed if f != "LANE.json"]
    out_of_lane = [f for f in checkable if not owns(f, owned_paths)]

    result = {
        "lane": lane["lane"],
        "phase": lane["phase"],
        "owned_paths": owned_paths,
        "changed_files": changed,
        "out_of_lane": out_of_lane,
        "status": "fail" if out_of_lane else "pass",
    }
    if out_of_lane:
        result["detail"] = (
            "these files are outside what this lane owns -- do not commit them. Write "
            f"{lane['coordination_dir']}/CONTRACT_REQUEST-{lane['lane']}-<timestamp>.md instead, "
            "describing what you need and why, and stop -- the orchestrator resolves it."
        )
    print(json.dumps(result, indent=2))
    return 1 if out_of_lane else 0


if __name__ == "__main__":
    sys.exit(main())
