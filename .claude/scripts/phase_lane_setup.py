#!/usr/bin/env python3
"""Cut worktrees for a /phase run, one per confirmed lane, each from a freshly-fetched
origin/main (never local main -- this repo has been burned by stale bases before), and write
a LANE.json into each declaring what it owns.

Usage:
    phase_lane_setup.py <phase_number> <lane>:<owned_path>[,<owned_path>...] [<lane>:... ...]

Example:
    phase_lane_setup.py 140 api:api/,docs/roadmap-status.md ios:ios/

Prints one JSON object per lane to stdout, each with worktree_path/branch/lane_json_path, so
the orchestrator can read them back without re-deriving anything.
"""

from __future__ import annotations

import json
import re
import subprocess
import sys
from datetime import datetime, timezone
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parents[2]
WORKTREES_DIR = REPO_ROOT / ".claude" / "worktrees"
COORDINATION_ROOT = REPO_ROOT / ".claude" / "coordination"


def run(cmd: list[str], cwd: Path | None = None) -> subprocess.CompletedProcess:
    return subprocess.run(cmd, cwd=cwd or REPO_ROOT, capture_output=True, text=True)


def slugify(text: str) -> str:
    slug = re.sub(r"[^a-z0-9]+", "-", text.lower()).strip("-")
    return slug or "lane"


def main() -> int:
    if len(sys.argv) < 3:
        print("usage: phase_lane_setup.py <phase_number> <lane>:<paths> [...]", file=sys.stderr)
        return 2

    phase = sys.argv[1]
    lane_specs = sys.argv[2:]

    fetch = run(["git", "fetch", "origin"])
    if fetch.returncode != 0:
        print(json.dumps({"error": f"git fetch origin failed: {fetch.stderr.strip()}"}))
        return 1

    coord_dir = COORDINATION_ROOT / f"phase-{phase}"
    coord_dir.mkdir(parents=True, exist_ok=True)

    results = []
    for spec in lane_specs:
        if ":" not in spec:
            print(json.dumps({"error": f"bad lane spec (want lane:paths): {spec}"}))
            return 2
        lane, paths_str = spec.split(":", 1)
        owned_paths = [p.strip() for p in paths_str.split(",") if p.strip()]

        worktree_name = f"phase-{phase}-{slugify(lane)}"
        worktree_path = WORKTREES_DIR / worktree_name
        branch = f"{lane}/phase-{phase}-{slugify(lane)}"

        if worktree_path.exists():
            results.append(
                {
                    "lane": lane,
                    "error": f"worktree already exists at {worktree_path} -- "
                    "reuse it or remove it first (git worktree remove), never overwrite blind",
                }
            )
            continue

        add = run(
            ["git", "worktree", "add", "-b", branch, str(worktree_path), "origin/main"]
        )
        if add.returncode != 0:
            results.append(
                {"lane": lane, "error": f"git worktree add failed: {add.stderr.strip()}"}
            )
            continue

        lane_json_path = worktree_path / "LANE.json"
        lane_json = {
            "phase": phase,
            "lane": lane,
            "owned_paths": owned_paths,
            "worktree_path": str(worktree_path),
            "branch": branch,
            "base": "origin/main",
            "coordination_dir": str(coord_dir),
            "created_at": datetime.now(timezone.utc).isoformat(),
        }
        lane_json_path.write_text(json.dumps(lane_json, indent=2) + "\n")

        results.append(
            {
                "lane": lane,
                "worktree_path": str(worktree_path),
                "branch": branch,
                "lane_json_path": str(lane_json_path),
                "owned_paths": owned_paths,
            }
        )

    print(json.dumps({"phase": phase, "coordination_dir": str(coord_dir), "lanes": results}, indent=2))
    return 0 if all("error" not in r for r in results) else 1


if __name__ == "__main__":
    sys.exit(main())
