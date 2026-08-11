"""Read the pending prompt candidates and accept or reject them in bulk.

79 generated candidates are waiting on a human read. This is the terminal-side of that: a solo
admin task run occasionally, so a CLI rather than a web UI.

    uv run python scripts/review_candidates.py list
    uv run python scripts/review_candidates.py list --flagged-only
    uv run python scripts/review_candidates.py template > decisions.txt
    uv run python scripts/review_candidates.py apply decisions.txt

**The model flags and never rejects.** A candidate using a banned word, or describing a feeling
instead of an action, is surfaced with the rule it tripped so that a rejection is a judgment
rather than a guess. Nothing here decides: the model does not get to reject its own peers and it
certainly does not get to approve them. Every accept and every reject in the decisions file was
typed by a person.

**Nothing here generates prompts.** Authoring stays server-side with a real model plus review —
settled, and not up for reinterpretation.
"""

from __future__ import annotations

import argparse
import asyncio
import re
import sys
import uuid
from dataclasses import dataclass

from sqlalchemy import select

from rascal.db import get_sessionmaker
from rascal.models import Prompt

# --- The tone rules, from docs/mission-library.md -------------------------------------------

# Words the library does not use. From the library's own tone section: the writing names an
# action and gets out of the way, and these are the words that show up when it stops doing that.
BANNED_WORDS: tuple[str, ...] = (
    "precious",
    "cherish",
    "cherished",
    "treasure",
    "treasured",
    "little moments",
)

# A prompt asks for something you can go and do. "Notice how much you love watching him draw"
# is a feeling; "Film him drawing for two minutes" is an action. The first is not rejected
# here — it is flagged, because the line between the two is a judgment call and the whole point
# of this tool is that a human makes it.
FEELING_OPENERS: tuple[str, ...] = (
    "notice how",
    "remember how",
    "think about how",
    "reflect on",
    "savor",
    "savour",
    "appreciate",
)


@dataclass(frozen=True)
class Flag:
    rule: str
    detail: str


def flags_for(body: str) -> list[Flag]:
    """Every tone rule this candidate trips. Never a verdict — only a reason to look."""
    found: list[Flag] = []
    lowered = body.lower()

    for word in BANNED_WORDS:
        if re.search(rf"\b{re.escape(word)}\b", lowered):
            found.append(Flag("banned-word", f"uses {word!r}"))

    for opener in FEELING_OPENERS:
        if lowered.startswith(opener) or f". {opener}" in lowered:
            found.append(Flag("feeling-not-action", f"opens with {opener!r}"))

    # A prompt a parent has to parse twice is one they skip. The library's own entries run
    # short; this is a soft signal and deliberately generous.
    if len(body) > 180:
        found.append(Flag("length", f"{len(body)} characters"))

    return found


# --- Reading ---------------------------------------------------------------------------------


async def _pending(limit: int | None) -> list[Prompt]:
    async with get_sessionmaker()() as session:
        statement = (
            select(Prompt)
            .where(Prompt.source == "generated", Prompt.active.is_(False))
            .order_by(Prompt.created_at)
        )
        if limit is not None:
            statement = statement.limit(limit)
        return list((await session.execute(statement)).scalars().all())


def _render(prompt: Prompt, flags: list[Flag]) -> str:
    lines = [
        f"{prompt.id}",
        f"  {prompt.kind}/{prompt.cadence}  theme={prompt.theme}  "
        f"ages={prompt.min_age_months}-{prompt.max_age_months}mo",
        f"  {prompt.body}",
    ]
    for flag in flags:
        lines.append(f"  FLAG {flag.rule}: {flag.detail}")
    return "\n".join(lines)


async def cmd_list(args: argparse.Namespace) -> int:
    prompts = await _pending(args.limit)
    shown = 0
    for prompt in prompts:
        flags = flags_for(prompt.body)
        if args.flagged_only and not flags:
            continue
        print(_render(prompt, flags))
        print()
        shown += 1
    flagged = sum(1 for p in prompts if flags_for(p.body))
    print(f"{shown} shown, {len(prompts)} pending, {flagged} flagged for a closer read.")
    print("Nothing above has been accepted or rejected. That is your call, in a decisions file.")
    return 0


async def cmd_template(args: argparse.Namespace) -> int:
    """A decisions file with every candidate pre-filled as `skip`.

    Deliberately `skip` and not `accept`: a file you can apply without reading anything must
    not be the path of least resistance.
    """
    prompts = await _pending(args.limit)
    print("# One decision per line: accept | reject | skip, then the prompt id.")
    print("# Everything starts as skip. Change the ones you have actually read.")
    for prompt in prompts:
        for flag in flags_for(prompt.body):
            print(f"#   FLAG {flag.rule}: {flag.detail}")
        print(f"#   {prompt.body}")
        print(f"skip {prompt.id}")
        print()
    return 0


# --- Applying --------------------------------------------------------------------------------


def parse_decisions(text: str) -> tuple[list[tuple[str, uuid.UUID]], list[str]]:
    decisions: list[tuple[str, uuid.UUID]] = []
    problems: list[str] = []
    for number, raw in enumerate(text.splitlines(), start=1):
        line = raw.split("#", 1)[0].strip()
        if not line:
            continue
        parts = line.split()
        if len(parts) != 2:
            problems.append(f"line {number}: expected '<accept|reject|skip> <id>', got {raw!r}")
            continue
        verdict, identifier = parts
        if verdict not in {"accept", "reject", "skip"}:
            problems.append(f"line {number}: unknown verdict {verdict!r}")
            continue
        try:
            decisions.append((verdict, uuid.UUID(identifier)))
        except ValueError:
            problems.append(f"line {number}: {identifier!r} is not a uuid")
    return decisions, problems


async def cmd_apply(args: argparse.Namespace) -> int:
    text = args.file.read_text()
    decisions, problems = parse_decisions(text)
    if problems:
        # **Nothing is applied from a file with a bad line in it.** A partial apply over 79
        # candidates leaves you unable to tell which half landed.
        for problem in problems:
            print(problem, file=sys.stderr)
        print(f"{len(problems)} problem(s). Nothing applied.", file=sys.stderr)
        return 1

    accepted = rejected = skipped = 0
    async with get_sessionmaker()() as session:
        for verdict, prompt_id in decisions:
            if verdict == "skip":
                skipped += 1
                continue
            prompt = await session.get(Prompt, prompt_id)
            if prompt is None:
                print(f"{prompt_id}: not found, skipping", file=sys.stderr)
                continue
            if verdict == "accept":
                prompt.active = True
                accepted += 1
            else:
                # Rejection deactivates rather than deletes. The candidate stays readable, so
                # a rejected batch can be re-read later and a mistake is recoverable.
                prompt.active = False
                rejected += 1
        await session.commit()

    print(f"accepted {accepted}, rejected {rejected}, skipped {skipped}")
    return 0


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    sub = parser.add_subparsers(dest="command", required=True)

    listing = sub.add_parser("list", help="Show pending candidates with their tone flags")
    listing.add_argument("--limit", type=int, default=None)
    listing.add_argument("--flagged-only", action="store_true")
    listing.set_defaults(run=cmd_list)

    template = sub.add_parser("template", help="Emit a decisions file, everything set to skip")
    template.add_argument("--limit", type=int, default=None)
    template.set_defaults(run=cmd_template)

    apply_cmd = sub.add_parser("apply", help="Apply a decisions file")
    apply_cmd.add_argument("file", type=__import__("pathlib").Path)
    apply_cmd.set_defaults(run=cmd_apply)

    return parser


def main(argv: list[str] | None = None) -> int:
    args = build_parser().parse_args(argv)
    return asyncio.run(args.run(args))


if __name__ == "__main__":
    raise SystemExit(main())
