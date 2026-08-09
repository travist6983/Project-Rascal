"""One-time (and re-runnable) conversion of docs/mission-library.md into seeds/prompts.yaml.

`docs/mission-library.md` is the authoring surface. This script is the *only* thing that
ever reads it. The seed loader reads YAML and nothing else — runtime never parses a markdown
table.

    uv run python scripts/mission_library_to_yaml.py

Re-run it after editing the markdown, commit the regenerated YAML, then `make seed`.
"""

from __future__ import annotations

import re
import sys
from dataclasses import dataclass
from pathlib import Path
from typing import Any

import yaml

API_DIR = Path(__file__).resolve().parents[1]
MARKDOWN = API_DIR.parent / "docs" / "mission-library.md"
OUTPUT = API_DIR / "seeds" / "prompts.yaml"

# `all` means 24 to 216 months, per the header of docs/mission-library.md.
AGE_ALL = (24, 216)


@dataclass(frozen=True)
class Section:
    """How to read one markdown table: its heading, its columns, and its fixed fields."""

    heading: str
    columns: tuple[str, ...]
    fixed: dict[str, str]


# Kinds no client can complete yet. Video left when multipart shipped; audio stays until the
# recorder does. Deleting a name from this set is the whole of re-enabling a kind.
UNCOMPLETABLE_KINDS = frozenset({"audio"})

SECTIONS: tuple[Section, ...] = (
    Section(
        "## Questions",
        ("body", "theme", "ages"),
        {"kind": "question", "cadence": "daily", "completion_mode": "text"},
    ),
    Section(
        "## Photo missions",
        ("body", "theme", "ages", "months"),
        {"kind": "photo", "cadence": "daily", "completion_mode": "media"},
    ),
    Section(
        "## Video missions",
        ("body", "theme", "ages", "months"),
        {"kind": "video", "cadence": "daily", "completion_mode": "media"},
    ),
    Section(
        "## Audio missions",
        ("body", "theme", "ages"),
        {"kind": "audio", "cadence": "daily", "completion_mode": "media"},
    ),
    Section(
        "## Activity missions",
        ("body", "theme", "ages"),
        {"kind": "activity", "cadence": "daily", "completion_mode": "did_it"},
    ),
    # The weekly and monthly tables carry their own Kind and Mode columns.
    Section(
        "## Weekly missions",
        ("body", "kind", "theme", "completion_mode", "ages"),
        {"cadence": "weekly"},
    ),
    Section(
        "## Monthly missions",
        ("body", "kind", "theme", "completion_mode", "ages"),
        {"cadence": "monthly"},
    ),
    Section(
        "## Letters",
        ("body", "theme", "unlock", "ages"),
        {"kind": "letter", "cadence": "monthly", "completion_mode": "text"},
    ),
)


def _rows(markdown: str, heading: str) -> list[list[str]]:
    """Every data row of the first pipe table under `heading`, cells already stripped."""
    start = markdown.index(heading)
    body = markdown[start + len(heading) :]
    rows: list[list[str]] = []
    seen_table = False
    for line in body.splitlines():
        stripped = line.strip()
        if stripped.startswith("## ") or stripped == "---":
            break
        if not stripped.startswith("|"):
            continue
        cells = [cell.strip() for cell in stripped.strip("|").split("|")]
        if not seen_table:
            seen_table = True  # the header row
            continue
        if all(set(cell) <= {"-", ":"} for cell in cells):
            continue  # the separator row
        rows.append(cells)
    return rows


def _ages(value: str) -> tuple[int, int]:
    if value.strip().lower() == "all":
        return AGE_ALL
    # The markdown uses en dashes; accept a hyphen too so a hand edit does not break the build.
    match = re.fullmatch(r"(\d+)\s*[\u2013-]\s*(\d+)", value.strip())
    if not match:
        raise ValueError(f"unparseable age range: {value!r}")
    return int(match.group(1)), int(match.group(2))


def _months(value: str) -> list[int]:
    if not value.strip():
        return []
    return [int(part) for part in value.split(",") if part.strip()]


def _prompt(section: Section, cells: list[str]) -> dict[str, Any]:
    if len(cells) < len(section.columns):
        raise ValueError(f"{section.heading}: expected {len(section.columns)} cells, got {cells}")
    fields = dict(zip(section.columns, cells, strict=False))
    minimum, maximum = _ages(fields["ages"])
    return {
        "kind": section.fixed.get("kind", fields.get("kind", "")),
        "cadence": section.fixed["cadence"],
        "completion_mode": section.fixed.get("completion_mode", fields.get("completion_mode", "")),
        "body": fields["body"],
        "theme": fields["theme"],
        "min_age_months": minimum,
        "max_age_months": maximum,
        "month_tags": _months(fields.get("months", "")),
        # Letters are sealed until the child reaches this age; everything else stays null.
        "default_unlock_age": int(fields["unlock"]) if fields.get("unlock") else None,
        "source": "seeded",
        # A prompt the client cannot complete is a dead end, not a mission. Video needs
        # multipart upload and audio needs a recorder; neither exists yet, so the scheduler
        # must not serve them — a device session hit exactly this, and the composer offered
        # a still camera on a prompt that said to film.
        #
        # Deliberately here rather than hand-edited into the yaml: the markdown is the
        # authoring surface and the yaml is generated from it, so an edit made only in the
        # yaml is erased by the next regeneration and drifts silently until then.
        #
        # One line to reverse when the capability lands.
        "active": section.fixed.get("kind", fields.get("kind", "")) not in UNCOMPLETABLE_KINDS,
    }


def convert(markdown_path: Path = MARKDOWN) -> list[dict[str, Any]]:
    markdown = markdown_path.read_text(encoding="utf-8")
    prompts: list[dict[str, Any]] = []
    for section in SECTIONS:
        for cells in _rows(markdown, section.heading):
            prompts.append(_prompt(section, cells))
    return prompts


def main() -> int:
    prompts = convert()
    OUTPUT.parent.mkdir(parents=True, exist_ok=True)
    header = (
        "# Generated from docs/mission-library.md by scripts/mission_library_to_yaml.py.\n"
        "# The markdown is the authoring surface; this file is what the seed loader reads.\n"
        "# Edit the markdown, re-run the script, commit both, then `make seed`.\n"
    )
    OUTPUT.write_text(
        header + yaml.safe_dump(prompts, sort_keys=False, allow_unicode=True, width=100),
        encoding="utf-8",
    )
    by_kind: dict[str, int] = {}
    for prompt in prompts:
        by_kind[prompt["kind"]] = by_kind.get(prompt["kind"], 0) + 1
    print(f"wrote {len(prompts)} prompts to {OUTPUT.relative_to(API_DIR.parent)}")
    for kind, count in sorted(by_kind.items()):
        print(f"  {kind:<12} {count}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
