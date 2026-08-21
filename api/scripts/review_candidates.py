"""Read the pending prompt candidates in the database and accept or reject them in bulk.

A pending candidate is a `prompts` row with `source = 'llm'` and `active = false`. Reviewing them
is a solo admin task run occasionally, so this is a CLI rather than a web UI.

    uv run python scripts/review_candidates.py list
    uv run python scripts/review_candidates.py list --flagged-only
    uv run python scripts/review_candidates.py template > decisions.txt
    uv run python scripts/review_candidates.py apply decisions.txt

**Where candidates come from, and where they do not.** `scripts/generate_prompts.py` still does
not feed this tool: it writes markdown worksheets to `docs/prompt-candidates/`, its review queue is
a pull request, and nothing in it touches the database. **What does feed it, as of phase 103 (Aug
20, 2026), is the admin console**: `POST /v1/prompts/candidates` writes the picked candidates from
the Library tab as `source='llm'`, `active=false` rows — exactly the queue described above.

This docstring used to end by saying every command here reads an empty queue and reports nothing
pending, and that this was the honest state of the tool rather than a failing query. That was true
for as long as it was written and is not any more. **The tool needed no change to read them**,
which is the strongest thing that can be said for the shape it was given before it had a writer.

**The model flags and never rejects.** A candidate using a banned word, or describing a feeling
instead of an action, is surfaced with the rule it tripped so that a rejection is a judgment
rather than a guess. Nothing here decides: the model does not get to reject its own peers and it
certainly does not get to approve them. Every accept and every reject in the decisions file was
typed by a person.

**Nothing here generates prompts, and nothing here approves one.** Authoring stays server-side
with a real model plus review — settled, and not up for reinterpretation. Approving is a person
reading a candidate and calling `PUT /prompts/{id}/active`, or writing `accept` on a line of a
decisions file and applying it. There is still no bulk approve that skips the reading.
"""

from __future__ import annotations

import argparse
import asyncio
import sys
import uuid
from dataclasses import dataclass
from typing import Final

from sqlalchemy import select

from rascal.constants import PROMPT_SOURCES, PromptSource
from rascal.db import get_sessionmaker
from rascal.models import Prompt
from rascal.services import candidates

# The `source` a generated candidate carries. `ck_prompts_source` admits `seeded`, `user` and
# `llm` and nothing else, so a query for a value outside that set matches no row it can ever
# see — which is what this tool did for as long as it asked for `generated`. Typed as
# `PromptSource` and checked against the constrained set at import so the same drift cannot
# happen quietly a second time: a rename in rascal.constants stops the CLI dead instead of
# emptying its queue.
CANDIDATE_SOURCE: Final[PromptSource] = "llm"
if CANDIDATE_SOURCE not in PROMPT_SOURCES:
    raise RuntimeError(
        f"{CANDIDATE_SOURCE!r} is not one of {PROMPT_SOURCES}. No prompts row can hold it, so "
        "every candidate would look reviewed."
    )

# --- The tone rules ------------------------------------------------------------------------
#
# **Rewired in phase 103, and it was a real divergence rather than tidying.** This file used to
# carry its own copy of the library's tone rules — its own `BANNED_WORDS`, its own
# `FEELING_OPENERS`, and a 180-character length rule — written when nothing could put a row in
# this queue, so the copy could not disagree with anything in practice.
#
# Phase 103 fills the queue, and at that moment the two copies were looking at the same rows
# and did not agree. `judge` rejects at 200 characters and this flagged at 180, so a body the
# console accepted arrived here flagged for length with nothing to say it had already been
# judged. And the private copy was missing every rule that matters most: a bare gendered
# pronoun, an unknown token, an assumed household, an assumed income.
#
# **A rejected body can still be a row, which is exactly why this tool has to know the rules.**
# The console shows every rejection with its reason and lets a person keep the candidate anyway
# — the filters are a spam trap, not an editor. So a banned word or a feeling-not-action body
# does reach this queue, deliberately, carrying a human decision. Re-showing the flag here is
# not second-guessing that decision: it is the second read, on a different day, that the whole
# accept/reject file exists for.
#
# So the rules come from `rascal.services.candidates` now, the same module the console route
# and `scripts/generate_prompts.py` read. One rule set, three callers.
#
# **What has not changed is the important part: this still flags and never rejects.** `judge`
# returns reasons and this presents every one of them as something to look at. Nothing here
# decides — the model does not get to reject its own peers and it certainly does not get to
# approve them.


@dataclass(frozen=True)
class Flag:
    rule: str
    detail: str


def flags_for(prompt: Prompt) -> list[Flag]:
    """Every rule this candidate trips. Never a verdict — only a reason to look.

    Takes the whole row rather than the body, because `judge` reads the kind and the age band
    too and a body-only check was throwing that away.

    `existing=[]` on purpose: the duplicate rule asks whether a body restates something already
    in the library, and this row *is* in the library. Running it here would flag every
    candidate against itself.
    """
    candidate = candidates.Candidate(
        body=prompt.body,
        theme=prompt.theme,
        kind=prompt.kind,
        min_age_months=prompt.min_age_months,
        max_age_months=prompt.max_age_months,
    )
    verdict = candidates.judge(candidate, existing=[], seasonal=bool(prompt.month_tags))
    return [
        Flag(_rule_name(reason), reason)
        for reason in verdict.reasons
        # `measurement` is a real prompt kind that the generator has no shape for, so `judge`
        # calls it unknown. True of the generator, misleading as a flag on a row that a person
        # may have hand-written — and the kind is on screen anyway.
        if not (reason.startswith("unknown kind") and prompt.kind not in candidates.KIND_SHAPES)
    ]


def _rule_name(reason: str) -> str:
    """A short slug for the reason, so the template's FLAG lines stay greppable."""
    for prefix, name in (
        ("banned vocabulary", "banned-word"),
        ("sentimental register", "sentimental"),
        ("describes a feeling", "feeling-not-action"),
        ("assumes a household", "household"),
        ("assumes an income", "income"),
        ("assumes an ability", "ability"),
        ("assumes a gender", "gendered-pronoun"),
        ("unknown token", "unknown-token"),
        ("not an ordinary Tuesday", "needs-an-occasion"),
        ("age band", "age-band"),
        ("longer than", "length"),
        ("shorter than", "length"),
        ("a question that is not", "shape"),
        ("a mission phrased as", "shape"),
    ):
        if reason.startswith(prefix):
            return name
    return "flagged"


# --- Reading ---------------------------------------------------------------------------------


async def _pending(limit: int | None) -> list[Prompt]:
    async with get_sessionmaker()() as session:
        statement = (
            select(Prompt)
            .where(Prompt.source == CANDIDATE_SOURCE, Prompt.active.is_(False))
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
        flags = flags_for(prompt)
        if args.flagged_only and not flags:
            continue
        print(_render(prompt, flags))
        print()
        shown += 1
    flagged = sum(1 for p in prompts if flags_for(p))
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
        for flag in flags_for(prompt):
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
        # **Nothing is applied from a file with a bad line in it.** A partial apply over a batch
        # leaves you unable to tell which half landed.
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
