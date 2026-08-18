"""Conversion of docs/marketing/email-sequence.md into seeds/email_copy.yaml.

`docs/marketing/email-sequence.md` is the authoring surface and the owner edits it directly.
This script is the *only* thing that ever reads it, exactly as
`mission_library_to_yaml.py` is the only thing that reads `docs/mission-library.md`.

    uv run python scripts/email_sequence_to_yaml.py

Re-run it after the owner edits the markdown, and commit the regenerated YAML.

**Two reasons this exists rather than the runtime reading the markdown**, which is what story 4
asked for:

1. `CLAUDE.md` is explicit that runtime never parses markdown. The prompt library already works
   this way and a second convention for the same problem is how the two drift apart.
2. **The markdown is not in the image.** Fly builds from `api/` as its context and the
   `Dockerfile` copies `src`, `alembic` and `seeds` — `docs/` is a directory above the build
   context and Docker cannot reach it. A loader pointed at `../docs/marketing/email-sequence.md`
   passes every test on a developer's checkout and raises `FileNotFoundError` on the first
   scheduled run in production. `seeds/` is already copied in, so the generated YAML ships.

The generator is strict on purpose. A silently-empty pool would send blank emails on a
schedule, so every shape problem here is a non-zero exit and not a warning.
"""

from __future__ import annotations

import re
import sys
from pathlib import Path
from typing import Any

import yaml

API_DIR = Path(__file__).resolve().parents[1]
MARKDOWN = API_DIR.parent / "docs" / "marketing" / "email-sequence.md"
OUTPUT = API_DIR / "seeds" / "email_copy.yaml"

#: `### Email 1 — Day 0. Subject: `Your first question``
WELCOME_HEADING = re.compile(
    r"^###\s+Email\s+(?P<index>\d+)\s+—\s+Day\s+(?P<day>\d+)\.\s+Subject:\s+`(?P<subject>[^`]+)`"
)
#: `1. What did they say today that you want to remember?`
POOL_ITEM = re.compile(r"^(?P<number>\d+)\.\s+(?P<text>\S.*)$")

#: The five offsets the copy states. Asserted rather than trusted: an edit that renumbered the
#: emails without renumbering the days would otherwise ship a sequence nobody intended.
EXPECTED_WELCOME_DAYS = (0, 2, 5, 9, 16)
EXPECTED_POOL_SIZE = 30


class ShapeError(Exception):
    """The markdown is not what the loader expects. Always fatal."""


def _blockquote_after(lines: list[str], start: int) -> str:
    """The `> ` block following a heading, unwrapped into paragraphs.

    Blank quote lines (`>`) separate paragraphs; a quoted line that continues a sentence is
    joined with a space, because the markdown wraps at 100 columns and those wraps are not
    meaningful.
    """
    paragraphs: list[str] = []
    current: list[str] = []
    for raw in lines[start:]:
        line = raw.rstrip("\n")
        if line.startswith(">"):
            content = line[1:].strip()
            if content:
                current.append(content)
            elif current:
                paragraphs.append(" ".join(current))
                current = []
            continue
        if not line.strip():
            # A blank line inside the block is tolerated; two in a row end it.
            if paragraphs or current:
                continue
            continue
        break
    if current:
        paragraphs.append(" ".join(current))
    if not paragraphs:
        raise ShapeError(f"no blockquote body found after line {start}")
    return "\n\n".join(paragraphs)


def parse(markdown: str) -> dict[str, Any]:
    lines = markdown.splitlines()

    welcome: list[dict[str, Any]] = []
    pool: list[str] = []
    footer = ""
    in_pool = False

    for number, line in enumerate(lines):
        heading = WELCOME_HEADING.match(line)
        if heading:
            welcome.append(
                {
                    "index": int(heading["index"]),
                    "day": int(heading["day"]),
                    "subject": heading["subject"].strip(),
                    "body": _blockquote_after(lines, number + 1),
                }
            )
            continue

        if line.startswith("## Part 2"):
            in_pool = True
            continue
        if line.startswith("## The footer"):
            in_pool = False
            footer = _blockquote_after(lines, number + 1)
            continue
        if line.startswith("## "):
            in_pool = False
            continue

        if in_pool:
            item = POOL_ITEM.match(line)
            if item:
                expected = len(pool) + 1
                if int(item["number"]) != expected:
                    raise ShapeError(
                        f"pool is numbered out of order: saw {item['number']}, expected {expected}"
                    )
                pool.append(item["text"].strip())

    _validate(welcome, pool, footer)
    return {
        "_generated_by": "scripts/email_sequence_to_yaml.py",
        "_source": "docs/marketing/email-sequence.md",
        "_warning": (
            "Generated. Edit the markdown and re-run the script; never edit this file by hand."
        ),
        "welcome": welcome,
        "pool": pool,
        "footer": footer,
    }


def _validate(welcome: list[dict[str, Any]], pool: list[str], footer: str) -> None:
    if [item["index"] for item in welcome] != [1, 2, 3, 4, 5]:
        raise ShapeError(f"expected welcome emails 1-5, got {[i['index'] for i in welcome]}")
    days = tuple(item["day"] for item in welcome)
    if days != EXPECTED_WELCOME_DAYS:
        raise ShapeError(f"expected welcome days {EXPECTED_WELCOME_DAYS}, got {days}")
    if len(pool) != EXPECTED_POOL_SIZE:
        raise ShapeError(f"expected {EXPECTED_POOL_SIZE} pool prompts, found {len(pool)}")
    if not footer:
        raise ShapeError("no footer found — every email ends with it, so its absence is fatal")
    for item in welcome:
        if not item["subject"] or not item["body"]:
            raise ShapeError(f"welcome email {item['index']} is missing a subject or a body")


def main() -> int:
    if not MARKDOWN.exists():
        print(f"missing {MARKDOWN}", file=sys.stderr)
        return 1
    try:
        parsed = parse(MARKDOWN.read_text(encoding="utf-8"))
    except ShapeError as exc:
        print(f"email-sequence.md does not match the expected shape: {exc}", file=sys.stderr)
        return 1

    OUTPUT.write_text(
        yaml.safe_dump(parsed, sort_keys=False, allow_unicode=True, width=100),
        encoding="utf-8",
    )
    print(
        f"wrote {OUTPUT.relative_to(API_DIR)}: "
        f"{len(parsed['welcome'])} welcome emails, {len(parsed['pool'])} pool prompts"
    )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
