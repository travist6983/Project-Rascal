"""Writing mission candidates with a model, and putting the kept ones in the queue.

**The queue this fills has existed and been empty since it was written.**
`scripts/review_candidates.py` defines a pending candidate as a `prompts` row with
`source = "llm"` and `active = false`, and says plainly that nothing in the repo writes one,
so every command it offers reads an empty queue. `docs/decisions-log.md` recorded the missing
piece as a decision rather than a defect — *"deciding whether candidates become rows is a
product call"* — and the owner made it on Aug 20, 2026. This module is that call implemented.

**What was already settled and still is.** The batch path is unchanged:
`scripts/generate_prompts.py` writes markdown worksheets to `docs/prompt-candidates/` and its
review queue is a pull request, which is the right interface for a theme sweep somebody reads
in a diff. This is the interactive path — one theme, up to twenty-five, judged on the spot —
and both run the same filters out of `services/candidates.py`, so a rule changed in one place
changes both.

**Two things this deliberately does not do.**

It does not activate anything. A committed candidate is `active=False` and no serving path can
see it: `services/scheduler.py` filters `Prompt.active.is_(True)`. Approving one is the
existing `PUT /prompts/{id}/active`, which is a person clicking a button after reading it.

It does not let the model judge its own output. `judge` flags; a human decides. The console
shows every rejection with its reason and **lets you keep one anyway** — the filters are a
spam trap rather than an editor, they are lossy by construction (`ASSUMES_INCOME` fires on the
bare word "buy"), and a rule that cannot be overridden by the person reading the prompt would
make a regex the final editor of the library.
"""

from __future__ import annotations

import dataclasses
import uuid
from typing import Any

from sqlalchemy import func, select
from sqlalchemy.exc import IntegrityError
from sqlalchemy.ext.asyncio import AsyncSession

from rascal.config import Settings
from rascal.errors import ErrorCode, RascalError
from rascal.models import Prompt
from rascal.services import candidates as rules
from rascal.services.seeding import content_hash
from rascal.services.social import director

#: Room for twenty-five bodies plus a rationale each, with margin. Well under any streaming
#: threshold. Sized so the reply is not truncated in the first place: `director.structured`
#: reads the text block and parses it, so a batch cut off mid-JSON surfaces as "the model
#: returned something that was not JSON" — true, unhelpful, and not obviously about length.
MAX_TOKENS = 16000

#: How many library prompts go into the style reference. The reference exists to set register
#: and length rather than to be exhaustive, and the duplicate check reads every active body
#: regardless — so a sample costs nothing in accuracy and leaves room for the instruction.
#:
#: **This kind first, then the rest, in theme order.** Not stratified across themes and not
#: random: `Math.random`-style variation would make one caller's batch unreproducible from
#: another's, and ordering by theme means a photo brief is shown mostly photographs while still
#: seeing the register the question set sets.
REFERENCE_SAMPLE = 60

#: What the model may be asked for in one turn. Mirrors `PromptGenerateIn.count`.
ALLOWED_COUNTS = (1, 5, 10, 25)


SYSTEM = """You write prompts for Vellum, an app that archives a childhood one daily prompt \
at a time. A parent opens it once a day and answers one thing.

The attached mission library is the style reference and the standard. Match it exactly: \
specific over sentimental, second person, imperative for missions, never sanctimonious. \
"Photograph the mess {they} made, don't clean it first" beats "capture a precious everyday \
moment."

Hard rules. A prompt that breaks any of these is worthless:
- Never use the words precious, cherish, treasure, or "little moments".
- Describe an action, not a feeling. A mission is something you do in four minutes.
- It must be doable in the middle of an ordinary Tuesday. No outings, no planning, no \
occasions, nothing that needs to be bought.
- Assume nothing about the household: not two parents, not an income, not a particular \
physical ability. One tired adult and a child in an ordinary home.
- Do not restate a prompt that is already in the library.
- Never write "he", "him", "his", "she", "her" or "hers". Refer to the child with the \
pronoun tokens instead.

The tokens are {they}, {them}, {their}, {theirs}, {themself}, the verb compounds {they_are}, \
{they_were}, {they_have}, {they_do}, the capitalised {They}, {Them}, {Their}, and {name}. \
Each renders to the reading parent's answer, so "What is {they} afraid of right now?" is \
grammatical for every child. Capitalisation is explicit: write {They} at the start of a \
sentence, never {they}. Use {name} at most once in a prompt, and only where a parent would \
say the name aloud — usually the opening. Do not invent tokens; anything outside that list \
renders literally, braces and all, in the app, in an export and in a printed book.

The library you are about to read is already written in these tokens. Match it. A candidate \
containing a bare gendered pronoun, or a token outside the list above, is rejected \
automatically and never reaches a reviewer."""


def candidate_schema(*, theme_is_fixed: bool) -> dict[str, Any]:
    """The reply shape, enforced server-side by `output_config.format`.

    `theme` is asked for only when the caller did not supply one. That is the whole mechanism
    behind "a theme **or** an age range": `prompts.theme` is NOT NULL, so an age-band-only run
    still has to put something in that column, and the model naming it per candidate is the
    only source for it that is not a made-up constant.
    """
    properties: dict[str, Any] = {
        "body": {
            "type": "string",
            "description": "The prompt itself, exactly as a parent will read it.",
        },
        "min_age_months": {
            "type": "integer",
            "description": "The narrowest lower bound that is actually true of this prompt.",
        },
        "max_age_months": {
            "type": "integer",
            "description": "The narrowest upper bound that is actually true of this prompt.",
        },
        "rationale": {
            "type": "string",
            "description": "One short sentence: why this is worth keeping.",
        },
    }
    required = ["body", "min_age_months", "max_age_months", "rationale"]

    if not theme_is_fixed:
        properties["theme"] = {
            "type": "string",
            "description": (
                "A short kebab-case theme for this prompt, chosen from the themes you can "
                "see in the library where one fits, and a new one only where none does."
            ),
        }
        required.append("theme")

    return {
        "type": "object",
        "properties": {
            "candidates": {
                "type": "array",
                "items": {
                    "type": "object",
                    "properties": properties,
                    "required": required,
                    "additionalProperties": False,
                },
            }
        },
        "required": ["candidates"],
        "additionalProperties": False,
    }


@dataclasses.dataclass(frozen=True)
class GenerationResult:
    theme: str | None
    kind: str
    cadence: str
    completion_mode: str
    model: str
    verdicts: list[rules.Verdict]
    #: Stamped on every candidate in the batch rather than chosen per candidate. They are
    #: properties of the brief — *these* months, *this* unlock age — and the model is not asked
    #: for either. They ride the response so the console can echo them back on commit; without
    #: that, a seasonal batch would queue rows with no months and never be served in the month
    #: it was written for.
    month_tags: list[int] = dataclasses.field(default_factory=list)
    default_unlock_age: int | None = None

    def as_dict(self) -> dict[str, Any]:
        return {
            "theme": self.theme,
            "kind": self.kind,
            "cadence": self.cadence,
            "completion_mode": self.completion_mode,
            "model": self.model,
            "accepted": sum(1 for verdict in self.verdicts if verdict.accepted),
            "rejected": sum(1 for verdict in self.verdicts if not verdict.accepted),
            "candidates": [
                {
                    "body": verdict.candidate.body,
                    "theme": verdict.candidate.theme,
                    "kind": verdict.candidate.kind,
                    "cadence": self.cadence,
                    "completion_mode": self.completion_mode,
                    "min_age_months": verdict.candidate.min_age_months,
                    "max_age_months": verdict.candidate.max_age_months,
                    "month_tags": list(self.month_tags),
                    "default_unlock_age": self.default_unlock_age,
                    "rationale": verdict.candidate.rationale,
                    "content_hash": content_hash(
                        verdict.candidate.kind, self.cadence, verdict.candidate.body
                    ),
                    "accepted": verdict.accepted,
                    "reasons": list(verdict.reasons),
                }
                for verdict in self.verdicts
            ],
        }


async def style_reference(session: AsyncSession, *, kind: str) -> tuple[str, list[frozenset[str]]]:
    """The library as the model sees it, and as the duplicate check sees it.

    Built from the `prompts` table rather than from `docs/mission-library.md`, which the batch
    script reads: `api/Dockerfile` does not copy `docs/`, so the markdown does not exist inside
    the running service at all. The two references describe the same library and will disagree
    the moment somebody edits the markdown without re-seeding — which is already the state
    `make seed` exists to correct, and the table is the one that is actually being served.

    Returns the prose block and the normalised token sets for `judge`'s duplicate check. The
    duplicate check sees **every** active body, not the sample: a candidate that restates a
    prompt the sample happened to omit is still a restatement.
    """
    rows = (
        await session.execute(
            select(
                Prompt.body, Prompt.theme, Prompt.kind, Prompt.min_age_months, Prompt.max_age_months
            )
            .where(Prompt.active.is_(True))
            .order_by(Prompt.theme, Prompt.kind)
        )
    ).all()

    existing = [rules._normalize(row.body) for row in rows]

    # Prefer this kind, then fill from the rest, so a photo brief is mostly shown photographs
    # without losing the register the question set sets.
    same_kind = [row for row in rows if row.kind == kind]
    others = [row for row in rows if row.kind != kind]
    sample = (same_kind + others)[:REFERENCE_SAMPLE]

    lines = [
        f"- `{row.theme}` · `{row.kind}` · {row.min_age_months}{rules.DASH}"
        f"{row.max_age_months} months — {row.body}"
        for row in sample
    ]
    reference = "\n".join(lines) if lines else "(The library is empty.)"
    return reference, existing


def build_instruction(
    *,
    reference: str,
    theme: str | None,
    kind: str,
    count: int,
    ages: tuple[int, int],
    seasonal: bool,
    guidance: str | None,
) -> str:
    """The user turn. The system prompt is the standard; this is the job."""
    shape = rules.KIND_SHAPES[kind]
    parts = [
        "Here is a sample of the mission library as it is being served right now.\n\n"
        f"<library>\n{reference}\n</library>\n",
    ]

    if theme:
        parts.append(
            f"Write {count} new candidates for theme `{theme}`, kind `{kind}` "
            f"(cadence `{shape['cadence']}`, completion mode `{shape['completion_mode']}`), "
            f"for children between {ages[0]} and {ages[1]} months old."
        )
    else:
        # The "or" in "a theme or an age range". No theme was given, so the age band is the
        # whole brief and the model chooses a theme per candidate.
        parts.append(
            f"Write {count} new candidates of kind `{kind}` "
            f"(cadence `{shape['cadence']}`, completion mode `{shape['completion_mode']}`), "
            f"for children between {ages[0]} and {ages[1]} months old. "
            "No theme is fixed for this batch: choose the theme for each candidate yourself, "
            "and spread them across several themes rather than writing one theme's worth. "
            "Prefer a theme already visible in the library above; invent one only where "
            "nothing fits, and keep it short and kebab-case."
        )

    parts.append(
        f"Give each candidate the narrowest age band that is actually true of it — a prompt "
        f"about mispronounced words does not belong to a fourteen-year-old. Vary the bands; "
        f"do not return {count} rows all reading {ages[0]}{rules.DASH}{ages[1]}."
    )

    if seasonal:
        parts.append(
            "This batch is seasonal, so an occasion is allowed and expected. Write for the "
            "months given rather than for an ordinary Tuesday."
        )

    if guidance:
        # The owner's own words, last and clearly fenced, so an instruction here cannot be
        # mistaken for part of the standard above.
        parts.append(
            "Additional direction from the person who will read these, which narrows the "
            f"brief but does not relax any hard rule:\n\n<direction>\n{guidance}\n</direction>"
        )

    parts.append("Do not repeat anything already in the library, in substance or in phrasing.")
    return "\n\n".join(parts)


async def generate(
    session: AsyncSession,
    settings: Settings,
    *,
    theme: str | None,
    kind: str,
    count: int,
    min_age_months: int,
    max_age_months: int,
    month_tags: list[int],
    default_unlock_age: int | None,
    guidance: str | None,
) -> GenerationResult:
    """One batch, judged. Rejected candidates come back with their reasons, never dropped.

    Keeping the failures is the same argument `scripts/generate_prompts.py` makes about its
    worksheets: a run where half the batch trips one filter is telling you the instruction
    needs work, and that signal is invisible if the failures are thrown away.
    """
    if kind not in rules.KIND_SHAPES:
        raise RascalError(
            ErrorCode.VALIDATION_FAILED,
            f"There is no candidate shape for kind {kind!r}. "
            f"Generatable kinds are {', '.join(sorted(rules.KIND_SHAPES))}.",
            field="kind",
        )
    if count not in ALLOWED_COUNTS:
        raise RascalError(
            ErrorCode.VALIDATION_FAILED,
            f"Count must be one of {', '.join(str(value) for value in ALLOWED_COUNTS)}.",
            field="count",
        )

    shape = rules.KIND_SHAPES[kind]
    reference, existing = await style_reference(session, kind=kind)
    seasonal = bool(month_tags)

    instruction = build_instruction(
        reference=reference,
        theme=theme,
        kind=kind,
        count=count,
        ages=(min_age_months, max_age_months),
        seasonal=seasonal,
        guidance=guidance,
    )

    # **Let the connection go before the model call.** Everything this needs from Postgres has
    # been read; what follows is a network round trip to Anthropic that routinely runs tens of
    # seconds and, at count=25, longer. Holding the request's session open across it leaves a
    # connection idle-in-transaction for that whole time, pinning a snapshot and occupying one
    # of a small pool — and the console's reads run against Neon, where connections are the
    # scarce thing. A rollback is the right verb: this session has read and written nothing.
    await session.rollback()

    model = settings.anthropic_candidates_model
    reply = await director.structured(
        settings,
        instruction,
        candidate_schema(theme_is_fixed=bool(theme)),
        system=SYSTEM,
        max_tokens=MAX_TOKENS,
        model=model,
    )

    verdicts: list[rules.Verdict] = []
    # Grows as the batch is judged, so two accepted candidates in one reply that restate each
    # other are caught — the second one is the duplicate.
    seen = list(existing)
    for row in reply.get("candidates", []):
        candidate = rules.Candidate(
            body=str(row.get("body", "")).strip(),
            theme=str(row.get("theme") or theme or "").strip(),
            kind=kind,
            min_age_months=int(row.get("min_age_months", min_age_months)),
            max_age_months=int(row.get("max_age_months", max_age_months)),
            rationale=str(row.get("rationale", "")).strip(),
        )
        verdict = rules.judge(candidate, existing=seen, seasonal=seasonal)
        if not candidate.theme:
            verdict.reasons.append("no theme, and none was given for the batch")
        verdicts.append(verdict)
        # **Only an accepted body joins the duplicate set.** A rejected one is not going into
        # the library, so nothing can duplicate it — and a model that writes a candidate, has
        # it rejected for a bare pronoun, and then writes the corrected version would otherwise
        # have the correction rejected as "too close to a prompt already in the library". The
        # rewrite is the one the reader wants and it is the one that would have been lost.
        if verdict.accepted:
            seen.append(rules._normalize(candidate.body))

    return GenerationResult(
        theme=theme,
        kind=kind,
        cadence=shape["cadence"],
        completion_mode=shape["completion_mode"],
        model=model,
        verdicts=verdicts,
        month_tags=list(month_tags),
        default_unlock_age=default_unlock_age,
    )


@dataclasses.dataclass(frozen=True)
class CommitResult:
    inserted: list[Prompt]
    skipped: list[dict[str, Any]]
    queued_total: int


#: Re-checked on the way in, whatever the console believed. `generate` is not the only way to
#: reach `commit` — the wire is — and these two rules are the ones whose failure is permanent
#: and invisible: a bare pronoun misgenders a real child, and an unknown token renders as
#: literal braces in the app, in an export and in a printed book for as long as the archive
#: exists. The other filters stay advisory, because the owner is allowed to keep a prompt the
#: regexes disliked and that is the point of showing the reasons.
def _hard_reasons(body: str) -> list[str]:
    reasons = []
    if found := rules.GENDERED.findall(body):
        words = ", ".join(sorted({word.lower() for word in found}))
        reasons.append(f"assumes a gender: {words} — use the pronoun tokens")
    if unknown := rules.validate_tokens(body):
        reasons.append(
            "unknown token"
            + ("s" if len(unknown) > 1 else "")
            + ": "
            + ", ".join("{" + token + "}" for token in sorted(set(unknown)))
        )
    return reasons


async def commit(
    session: AsyncSession,
    picked: list[dict[str, Any]],
) -> CommitResult:
    """Write the kept candidates into the queue.

    `active=False` is passed explicitly and it is load-bearing: `Prompt.active` has a
    `server_default` of `true` and **no Python-side default**, so a row that omits it is
    written live and is in the day's pool for every child in the age band within the minute.

    A duplicate `content_hash` is a skip rather than an error. One repeated body must not cost
    the other twenty-four, and the skip names the row it collided with so the reviewer can go
    and look at it.
    """
    inserted: list[Prompt] = []
    skipped: list[dict[str, Any]] = []
    # Hashes claimed inside this request, so two identical bodies in one commit do not both
    # pass the pre-check and then fail on the unique index.
    claimed: set[str] = set()

    # **One query for the whole batch, not one per candidate.** Every hash is computable before
    # anything is written, and the pre-check reads a single indexed column — so the loop below
    # does no reads at all. At twenty-five candidates this is the difference between one round
    # trip and twenty-five sequential ones, each of them holding the write transaction open.
    digests = [
        content_hash(
            str(row["kind"]),
            rules.KIND_SHAPES[str(row["kind"])]["cadence"],
            str(row["body"]).strip(),
        )
        for row in picked
        if str(row["kind"]) in rules.KIND_SHAPES
    ]
    clashes: dict[str, uuid.UUID] = (
        {
            digest: prompt_id
            for prompt_id, digest in (
                await session.execute(
                    select(Prompt.id, Prompt.content_hash).where(Prompt.content_hash.in_(digests))
                )
            ).all()
        }
        if digests
        else {}
    )

    for row in picked:
        kind = str(row["kind"])
        if kind not in rules.KIND_SHAPES:
            raise RascalError(
                ErrorCode.VALIDATION_FAILED,
                f"There is no candidate shape for kind {kind!r}.",
                field="kind",
            )
        shape = rules.KIND_SHAPES[kind]
        body = str(row["body"]).strip()

        if hard := _hard_reasons(body):
            raise RascalError(
                ErrorCode.VALIDATION_FAILED,
                "This body cannot be queued: " + "; ".join(hard) + ".",
                field="body",
            )

        digest = content_hash(kind, shape["cadence"], body)
        if digest in claimed:
            skipped.append({"body": body, "reason": "Sent twice in this batch.", "prompt_id": None})
            continue

        clash = clashes.get(digest)
        if clash is not None:
            skipped.append(
                {
                    "body": body,
                    "reason": (
                        "The library already has this exact kind, cadence and body. "
                        "That is true of a retired prompt too — the index does not look at "
                        "`active`."
                    ),
                    "prompt_id": str(clash),
                }
            )
            continue

        prompt = Prompt(
            kind=kind,
            cadence=shape["cadence"],
            completion_mode=shape["completion_mode"],
            body=body,
            theme=str(row["theme"]).strip(),
            min_age_months=int(row["min_age_months"]),
            max_age_months=int(row["max_age_months"]),
            month_tags=list(row.get("month_tags") or []),
            default_unlock_age=row.get("default_unlock_age"),
            source="llm",
            # Explicit. See the docstring — the column's default is `true`.
            active=False,
            content_hash=digest,
        )
        try:
            # A savepoint per row. The SELECT above is a pre-check, not a lock: between it and
            # the flush another writer can take the same hash, and without this the resulting
            # IntegrityError poisons the transaction and the whole batch becomes a generic 500
            # — the exact outcome this function's docstring promises will not happen. Same
            # shape as `services/email_sign_in.py` and `services/auth.py`.
            async with session.begin_nested():
                session.add(prompt)
                await session.flush()
        except IntegrityError:
            skipped.append(
                {
                    "body": body,
                    "reason": (
                        "Another writer queued this exact body a moment ago. "
                        "Nothing was lost — it is in the library already."
                    ),
                    "prompt_id": None,
                }
            )
            continue
        claimed.add(digest)
        inserted.append(prompt)

    await session.flush()
    queued_total = await pending_count(session)
    return CommitResult(inserted=inserted, skipped=skipped, queued_total=queued_total)


async def pending_count(session: AsyncSession) -> int:
    """How many candidates are waiting. The same query `scripts/review_candidates.py` runs."""
    return int(
        await session.scalar(
            select(func.count())
            .select_from(Prompt)
            .where(Prompt.source == "llm", Prompt.active.is_(False))
        )
        or 0
    )
