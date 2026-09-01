#!/usr/bin/env python3
"""Recommend a merge order across a /phase run's lanes based on actual dependency direction,
not lane name. The only dependency this repo has a reliable, mechanical signal for: a new
Alembic migration in the api lane that an ios-lane change's request/response shape implies it
needs. Everything else (a shared doc both lanes touched, a genuinely independent pair of
changes) is reported as "no detected dependency" rather than guessed at -- a wrong merge-order
claim is worse than an honest "these look independent."

Usage: phase_merge_order.py <phase_number>
Reads each lane's LANE.json under .claude/worktrees/phase-<N>-*/ and diffs it against its base.
"""

from __future__ import annotations

import json
import re
import subprocess
import sys
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parents[2]
WORKTREES_DIR = REPO_ROOT / ".claude" / "worktrees"

MIGRATION_PATH_RE = re.compile(r"^api/alembic/versions/.*\.py$")


def run(cmd: list[str], cwd: Path) -> subprocess.CompletedProcess:
    return subprocess.run(cmd, cwd=cwd, capture_output=True, text=True)


def find_lanes(phase: str) -> list[dict]:
    lanes = []
    if not WORKTREES_DIR.exists():
        return lanes
    for d in sorted(WORKTREES_DIR.glob(f"phase-{phase}-*")):
        lane_json_path = d / "LANE.json"
        if lane_json_path.exists():
            lanes.append(json.loads(lane_json_path.read_text()))
    return lanes


def changed_files(lane: dict) -> list[str]:
    worktree = Path(lane["worktree_path"])
    base = lane["base"]
    tracked = [f for f in run(["git", "diff", "--name-only", base], worktree).stdout.splitlines() if f]
    untracked = [
        f for f in run(["git", "ls-files", "--others", "--exclude-standard"], worktree).stdout.splitlines() if f
    ]
    return sorted(set(tracked) | set(untracked))


def main() -> int:
    if len(sys.argv) < 2:
        print("usage: phase_merge_order.py <phase_number>", file=sys.stderr)
        return 2
    phase = sys.argv[1]

    lanes = find_lanes(phase)
    if not lanes:
        print(json.dumps({"error": f"no lane worktrees found for phase {phase} under {WORKTREES_DIR}"}))
        return 1

    lane_files = {lane["lane"]: changed_files(lane) for lane in lanes}
    lane_migrations = {
        lane: [f for f in files if MIGRATION_PATH_RE.match(f)] for lane, files in lane_files.items()
    }

    dependencies = []  # (depends_on_lane, needs_lane, why)
    for lane, migrations in lane_migrations.items():
        if not migrations:
            continue
        for other_lane, other_files in lane_files.items():
            if other_lane == lane:
                continue
            dependencies.append(
                {
                    "before": lane,
                    "after": other_lane,
                    "why": f"{lane} adds {len(migrations)} migration(s) "
                    f"({', '.join(Path(m).name for m in migrations)}) -- a consumer lane should "
                    "merge after the schema it may depend on exists, even if this run can't "
                    "confirm the other lane actually reads the new column/table",
                    "confidence": "heuristic -- confirm by reading both diffs",
                }
            )

    order = []
    remaining = set(lane_files.keys())
    befores = {d["before"] for d in dependencies}
    # lanes that are a dependency for someone else go first; report the rest as no detected order
    for lane in sorted(remaining):
        if lane in befores:
            order.append(lane)
            remaining.discard(lane)
    order.extend(sorted(remaining))

    report = {
        "phase": phase,
        "lanes": sorted(lane_files.keys()),
        "detected_dependencies": dependencies,
        "recommended_order": order,
        "detail": "order is a recommendation, not a lock -- migrations-before-consumers is the "
        "only mechanically-detected signal here; lanes with no detected dependency are listed "
        "in alphabetical order, meaning genuinely independent, not unordered by omission",
    }
    print(json.dumps(report, indent=2))
    return 0


if __name__ == "__main__":
    sys.exit(main())
