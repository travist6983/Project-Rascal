"""Batch-generate mission candidates with a real model, for review in a pull request.

    uv run python scripts/generate_prompts.py --theme fears-comfort --count 20
    uv run python scripts/generate_prompts.py --thinnest 4

`docs/mission-library.md` is fed in as the style reference, along with a target theme and
age band, exactly as that file's "Expanding the library" section specifies. Candidates land
in `docs/prompt-candidates/<theme>-<date>.md` as a markdown table in the same shape as the
library, so an accepted row is a copy-paste away from being seeded.

**The review queue is a pull request.** That is the whole design. A branch with a diff is
already an accept/reject interface with a comment thread, an audit trail, and an undo — and
it needs no table, no admin UI, and no endpoint. See docs/decisions-log.md.

**What this script rejects, it rejects in code.** The library's four rejection rules are
implemented as named filters below and each one is tested, and a fifth filter rejects a bare
gendered pronoun: the seeded library is he/him and is being tokenised, so no new copy may
assume a child's gender. They are deliberately literal: they catch the failure modes that are
textually detectable and they do not pretend to judgment. A human still reads the candidates
in the PR — the filters exist so that the human is reading twelve plausible prompts rather
than twenty with eight obvious duds in them.

Nothing here touches the database. Seeding stays what it has always been: edit the markdown,
re-run `scripts/mission_library_to_yaml.py`, `make seed`.
"""

from __future__ import annotations

import argparse
import collections
import datetime as dt
import json
import os
import re
import sys
from dataclasses import dataclass, field
from pathlib import Path

import httpx
import yaml

API_DIR = Path(__file__).resolve().parents[1]
REPO = API_DIR.parent
LIBRARY = REPO / "docs" / "mission-library.md"
SEEDS = API_DIR / "seeds" / "prompts.yaml"
CANDIDATES = REPO / "docs" / "prompt-candidates"

API_URL = "https://api.anthropic.com/v1/messages"
API_VERSION = "2023-06-01"
# Overridable, because the right model for this changes faster than this file does.
# `or` rather than a `get` default: the workflow passes `${{ vars.ANTHROPIC_MODEL }}`, and an
# unset repository variable arrives as an empty string rather than as an absent one. A `get`
# default would hand the API `"model": ""` and take a 400 for it.
MODEL = os.environ.get("ANTHROPIC_MODEL", "").strip() or "claude-sonnet-5"
MAX_TOKENS = 8192

# What each kind's prompts have to look like, mirrored from the library's own headings.
KIND_SHAPES: dict[str, dict[str, str]] = {
    "question": {"cadence": "daily", "completion_mode": "text"},
    "photo": {"cadence": "daily", "completion_mode": "media"},
    "video": {"cadence": "daily", "completion_mode": "media"},
    "audio": {"cadence": "daily", "completion_mode": "media"},
    "activity": {"cadence": "daily", "completion_mode": "did_it"},
    "letter": {"cadence": "monthly", "completion_mode": "text"},
}
MISSION_KINDS = ("photo", "video", "audio", "activity")

MIN_LENGTH = 12
MAX_LENGTH = 200

# docs/mission-library.md writes age ranges with an en dash — "24\u2013216". Matching it
# exactly is what makes an accepted row paste straight into that file. Named rather than
# written inline so it does not read as a stray non-ASCII character.
DASH = "\u2013"


# --- The rejection rules -------------------------------------------------------------------
#
# docs/mission-library.md, "Expanding the library". Reject anything that:
#   - uses the words precious, cherish, treasure, or little moments
#   - describes a feeling instead of an action
#   - couldn't be done in the middle of an ordinary Tuesday
#   - assumes a two-parent household, a particular income, or a particular ability
#
# And one rule that is not from that section: no bare gendered pronoun. docs/mission-library.md,
# "Pronoun and name tokens" — new prompts refer to the child with the token table in
# docs/api-contract.md, never with he/him or she/her.


def _words(*terms: str) -> re.Pattern[str]:
    return re.compile(r"\b(?:" + "|".join(terms) + r")\b", re.IGNORECASE)


BANNED = _words(
    "precious",
    "cherish(?:ed|es|ing)?",
    "treasure[sd]?",
    "treasuring",
    "little moments?",
)

# The register the library exists to avoid. "Photograph the mess he made, don't clean it
# first" beats "capture a precious everyday moment", and this is the second one's vocabulary.
SENTIMENTAL = _words(
    "savou?r",
    "soak (?:it )?(?:up|in)",
    "bask",
    "take it all in",
    "be present",
    "mindful(?:ly)?",
    "magical",
    "magic of",
    "wonder of",
    "fleeting",
    "bittersweet",
    "heartwarming",
    "grow up so fast",
    "blink of an eye",
    "before you know it",
    "capture the (?:joy|magic|wonder|feeling)",
    "these days won'?t last",
)

# A mission is an instruction. This catches the ones that ask you to have a feeling and call
# it a task. Questions are exempt — "What is he afraid of right now?" is a question *about* a
# feeling, which is exactly the point of the question set.
FEELING_NOT_ACTION = re.compile(
    r"^\s*(?:feel|notice how you|remember how|think about how|imagine how|reflect|"
    r"appreciate|take a moment)\b|how (?:it|that|this) (?:feels|felt)|"
    r"\bthe feeling of\b",
    re.IGNORECASE,
)

# Assumes a household, an income, or an ability. Narrow on purpose: an aggressive rule here
# would reject "get on the floor for ten minutes", which is one of the best prompts in the
# library. This is a tripwire for the obvious cases, not a substitute for reading the PR.
ASSUMES_HOUSEHOLD = _words(
    "mom and dad",
    "mum and dad",
    "mother and father",
    "both parents",
    "your (?:partner|spouse|husband|wife)",
    "the other parent",
)
ASSUMES_INCOME = _words(
    "buy",
    "purchase",
    "afford",
    "expensive",
    "restaurant",
    "vacation",
    "toy store",
    "order online",
)
ASSUMES_ABILITY = _words("hike", "jog", "sprint", "swim", "bike ride", "cycle")

# Not an ordinary Tuesday: needs a plan, a destination, or an occasion. Skipped when the
# batch is explicitly seasonal, since the library's seasonal prompts are meant to be occasions.
NEEDS_AN_OCCASION = _words(
    "birthday",
    "party",
    "vacation",
    "zoo",
    "museum",
    "aquarium",
    "beach",
    "road trip",
    "day trip",
    "plan a",
    "arrange",
    "schedule a",
    "book a",
)

# The seeded 113 are written he/him and are being rewritten; nothing new may add to that pile.
# This is enforced here rather than only asked for in SYSTEM because the whole library goes into
# every request as the style reference, and a model imitates what it reads.
#
# `\b` on both sides is what keeps this honest. It does not fire on the tokens — none of {they},
# {them}, {their}, {theirs}, {themself}, {They}, {Them}, {Their} or the verb compounds contains
# he, him, his, she, her or hers as a whole word — and it does not fire on ordinary words that
# merely contain those letters: shed, history, others, treasurer.
GENDERED = _words("he", "him", "his", "himself", "she", "her", "hers", "herself")


@dataclass(frozen=True)
class Candidate:
    body: str
    theme: str
    kind: str
    min_age_months: int
    max_age_months: int
    rationale: str = ""


@dataclass
class Verdict:
    candidate: Candidate
    reasons: list[str] = field(default_factory=list)

    @property
    def accepted(self) -> bool:
        return not self.reasons


def _normalize(body: str) -> frozenset[str]:
    """A prompt reduced to its content words, for near-duplicate detection."""
    tokens = re.findall(r"[a-z']+", body.lower())
    stop = {
        "a",
        "an",
        "and",
        "are",
        "as",
        "at",
        "be",
        "but",
        "by",
        "did",
        "do",
        "does",
        "for",
        "from",
        "he",
        "her",
        "him",
        "his",
        "how",
        "in",
        "is",
        "it",
        "its",
        "of",
        "on",
        "or",
        "she",
        "that",
        "the",
        # The pronoun tokens reduce to these, and they sit here for the same reason "his" and
        # "her" do: which pronoun a prompt uses must not change how similar it looks to another.
        # A tokenised rewrite of a library prompt is still that prompt.
        "their",
        "theirs",
        "them",
        "themself",
        "they",
        "this",
        "to",
        "up",
        "was",
        "what",
        "when",
        "which",
        "who",
        "with",
        "you",
        "your",
    }
    return frozenset(token for token in tokens if token not in stop)


def _too_similar(body: str, existing: list[frozenset[str]]) -> bool:
    """Jaccard over content words. 0.6 catches a reworded duplicate without eating a variant."""
    tokens = _normalize(body)
    if not tokens:
        return False
    for other in existing:
        union = tokens | other
        if union and len(tokens & other) / len(union) >= 0.6:
            return True
    return False


def judge(
    candidate: Candidate, *, existing: list[frozenset[str]], seasonal: bool = False
) -> Verdict:
    """Every reason this candidate fails, not just the first. A reviewer wants the whole list."""
    verdict = Verdict(candidate)
    body = candidate.body.strip()

    if len(body) < MIN_LENGTH:
        verdict.reasons.append(f"shorter than {MIN_LENGTH} characters")
    if len(body) > MAX_LENGTH:
        verdict.reasons.append(f"longer than {MAX_LENGTH} characters")

    if candidate.kind not in KIND_SHAPES:
        verdict.reasons.append(f"unknown kind {candidate.kind!r}")
    elif candidate.kind == "question" and not body.endswith("?"):
        verdict.reasons.append("a question that is not a question")
    elif candidate.kind in MISSION_KINDS and body.endswith("?"):
        verdict.reasons.append("a mission phrased as a question")

    if found := BANNED.findall(body):
        verdict.reasons.append(f"banned vocabulary: {', '.join(sorted(set(found)))}")
    if found := SENTIMENTAL.findall(body):
        verdict.reasons.append(f"sentimental register: {', '.join(sorted(set(found)))}")

    if candidate.kind in MISSION_KINDS and FEELING_NOT_ACTION.search(body):
        verdict.reasons.append("describes a feeling instead of an action")

    if found := ASSUMES_HOUSEHOLD.findall(body):
        verdict.reasons.append(f"assumes a household shape: {', '.join(sorted(set(found)))}")
    if found := ASSUMES_INCOME.findall(body):
        verdict.reasons.append(f"assumes an income: {', '.join(sorted(set(found)))}")
    if found := ASSUMES_ABILITY.findall(body):
        verdict.reasons.append(f"assumes an ability: {', '.join(sorted(set(found)))}")

    if found := GENDERED.findall(body):
        words = ", ".join(sorted({word.lower() for word in found}))
        verdict.reasons.append(f"assumes a gender: {words} — use the pronoun tokens")

    if not seasonal and (found := NEEDS_AN_OCCASION.findall(body)):
        verdict.reasons.append(f"not an ordinary Tuesday: {', '.join(sorted(set(found)))}")

    if not (24 <= candidate.min_age_months < candidate.max_age_months <= 216):
        verdict.reasons.append(
            f"age band {candidate.min_age_months}{DASH}{candidate.max_age_months} "
            f"is outside 24{DASH}216"
        )

    if _too_similar(body, existing):
        verdict.reasons.append("too close to a prompt already in the library")

    return verdict


# --- The library ---------------------------------------------------------------------------


def load_library() -> list[dict]:
    return yaml.safe_load(SEEDS.read_text(encoding="utf-8"))


def thinnest_themes(library: list[dict], count: int) -> list[str]:
    """The themes with the fewest prompts — where a batch buys the most coverage."""
    counts = collections.Counter(row["theme"] for row in library)
    return [theme for theme, _ in sorted(counts.items(), key=lambda item: (item[1], item[0]))][
        :count
    ]


# --- The model call ------------------------------------------------------------------------

SYSTEM = """You write prompts for RASCAL, an app that archives a childhood one daily prompt \
at a time. A parent opens it once a day and answers one thing.

The attached mission library is the style reference and the standard. Match it exactly: \
specific over sentimental, second person, imperative for missions, never sanctimonious. \
"Photograph the mess he made, don't clean it first" beats "capture a precious everyday \
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
renders literally, braces and all.

**The library you are about to read is written "he" throughout. Do not match that.** It \
predates the tokens and is being rewritten. Copy its register, its specificity and its \
length — not its pronouns. A candidate containing a bare gendered pronoun is rejected \
automatically and never reaches a reviewer."""

TOOL = {
    "name": "emit_candidates",
    "description": "Return the batch of candidate prompts.",
    "input_schema": {
        "type": "object",
        "properties": {
            "candidates": {
                "type": "array",
                "items": {
                    "type": "object",
                    "properties": {
                        "body": {
                            "type": "string",
                            "description": "The prompt itself, exactly as a parent will read it.",
                        },
                        "min_age_months": {"type": "integer"},
                        "max_age_months": {"type": "integer"},
                        "rationale": {
                            "type": "string",
                            "description": "One short sentence: why this is worth keeping.",
                        },
                    },
                    "required": ["body", "min_age_months", "max_age_months", "rationale"],
                },
            }
        },
        "required": ["candidates"],
    },
}


def build_request(*, theme: str, kind: str, count: int, ages: tuple[int, int]) -> dict:
    library = LIBRARY.read_text(encoding="utf-8")
    shape = KIND_SHAPES[kind]
    instruction = (
        f"Here is the current mission library in full.\n\n<library>\n{library}\n</library>\n\n"
        # Repeated here, after the library rather than only before it: the model has just read
        # 113 prompts written he/him, and that is the text nearest to what it writes next.
        f"Every prompt you just read is written he/him. That is the old library, not the "
        f"standard — write the pronoun tokens instead, and no bare he, him, his, she, her "
        f"or hers.\n\n"
        f"Write {count} new candidates for theme `{theme}`, kind `{kind}` "
        f"(cadence `{shape['cadence']}`, completion mode `{shape['completion_mode']}`), "
        f"for children between {ages[0]} and {ages[1]} months old.\n\n"
        f"Give each candidate the narrowest age band that is actually true of it — a prompt "
        f"about mispronounced words does not belong to a fourteen-year-old. Vary the bands; "
        f"do not return {count} rows all reading {ages[0]}{DASH}{ages[1]}.\n\n"
        f"Do not repeat anything already in the library, in substance or in phrasing."
    )
    return {
        "model": MODEL,
        "max_tokens": MAX_TOKENS,
        "system": SYSTEM,
        "tools": [TOOL],
        # Forced, so the response is structured data rather than prose to be parsed out of.
        "tool_choice": {"type": "tool", "name": "emit_candidates"},
        "messages": [{"role": "user", "content": instruction}],
    }


def call_model(request: dict, api_key: str, *, timeout: float = 180.0) -> list[dict]:
    response = httpx.post(
        API_URL,
        json=request,
        headers={
            "x-api-key": api_key,
            "anthropic-version": API_VERSION,
            "content-type": "application/json",
        },
        timeout=timeout,
    )

    if response.status_code >= 400:
        # `raise_for_status()` throws away the body, and the body is the only place the API
        # says *why*. A bare "400 Bad Request" in a workflow log is not a diagnosis, and this
        # is the one code path with no test coverage — it has to explain itself.
        raise SystemExit(
            f"The Anthropic API returned {response.status_code} for model {request['model']!r}.\n"
            f"{_api_error(response)}\n"
            f"Request had {len(request['messages'][0]['content'])} characters of instruction, "
            f"max_tokens={request['max_tokens']}, tool_choice forced to {TOOL['name']!r}."
        )

    payload = response.json()

    if payload.get("stop_reason") == "refusal":
        # A safety classifier declined. Prompt-writing is benign, but the answer to a refusal
        # is never a retry of the same request, so say so rather than looping.
        raise SystemExit(
            "The model declined this request "
            f"(category: {(payload.get('stop_details') or {}).get('category')!r}). "
            "Rewrite the theme or instruction rather than retrying unchanged."
        )

    for block in payload.get("content", []):
        if block.get("type") == "tool_use" and block.get("name") == TOOL["name"]:
            return block["input"]["candidates"]

    raise SystemExit(
        f"The model returned no tool_use block. stop_reason: {payload.get('stop_reason')!r}, "
        f"block types: {[block.get('type') for block in payload.get('content', [])]}"
    )


def _api_error(response: httpx.Response) -> str:
    """The API's own explanation, however it chose to encode it."""
    try:
        body = response.json()
    except ValueError:
        return response.text[:2000]
    error = body.get("error") if isinstance(body, dict) else None
    if isinstance(error, dict):
        return f"{error.get('type', 'error')}: {error.get('message', body)}"
    return json.dumps(body)[:2000]


# --- Output ---------------------------------------------------------------------------------


def render(
    theme: str, kind: str, verdicts: list[Verdict], *, generated_on: dt.date, model: str
) -> str:
    accepted = [v for v in verdicts if v.accepted]
    rejected = [v for v in verdicts if not v.accepted]

    lines = [
        f"# Prompt candidates — `{theme}` · `{kind}`",
        "",
        f"Generated {generated_on.isoformat()} by `scripts/generate_prompts.py` using `{model}`.",
        "",
        f"{len(accepted)} of {len(verdicts)} candidates passed the automated filters. "
        "**Those filters are a spam trap, not an editor** — they catch the four rejection "
        "rules where the rule is textually detectable, and nothing else. Everything below "
        "still needs reading.",
        "",
        "## How to review this",
        "",
        "1. Delete the rows you do not want. Leave the ones you do.",
        "2. Move the survivors into the right table in `docs/mission-library.md`.",
        "3. `uv run python scripts/mission_library_to_yaml.py`, then `make seed`.",
        "4. `api/tests/test_seeding.py` asserts the coverage table in the library; update the "
        "numbers it gives you.",
        "5. Delete this file in the same commit. It is a worksheet, not a record.",
        "",
        "## Accepted",
        "",
    ]

    if accepted:
        lines += ["| Prompt | Theme | Ages | Why |", "|---|---|---|---|"]
        for verdict in accepted:
            row = verdict.candidate
            ages = f"{row.min_age_months}{DASH}{row.max_age_months}"
            body = row.body.replace("|", "\\|")
            why = row.rationale.replace("|", "\\|")
            lines.append(f"| {body} | {row.theme} | {ages} | {why} |")
    else:
        lines.append("_Nothing survived the filters. That is a signal about the run, not a bug._")

    lines += [
        "",
        "## Rejected",
        "",
    ]
    if rejected:
        lines += ["| Prompt | Rejected because |", "|---|---|"]
        for verdict in rejected:
            body = verdict.candidate.body.replace("|", "\\|")
            lines.append(f"| {body} | {'; '.join(verdict.reasons)} |")
        lines += [
            "",
            "Rejections are kept deliberately. A run where half the batch trips the same "
            "filter is telling you the instructions need work, and that is invisible if the "
            "failures are thrown away.",
        ]
    else:
        lines.append("_Nothing was rejected._")

    return "\n".join(lines) + "\n"


# --- CLI --------------------------------------------------------------------------------------


def generate(
    *,
    theme: str,
    kind: str,
    count: int,
    ages: tuple[int, int],
    api_key: str,
    seasonal: bool,
    existing: list[frozenset[str]],
) -> list[Verdict]:
    raw = call_model(build_request(theme=theme, kind=kind, count=count, ages=ages), api_key)

    verdicts: list[Verdict] = []
    seen = list(existing)
    for item in raw:
        candidate = Candidate(
            body=str(item.get("body", "")).strip(),
            theme=theme,
            kind=kind,
            min_age_months=int(item.get("min_age_months", ages[0])),
            max_age_months=int(item.get("max_age_months", ages[1])),
            rationale=str(item.get("rationale", "")).strip(),
        )
        verdict = judge(candidate, existing=seen, seasonal=seasonal)
        verdicts.append(verdict)
        # A batch must not duplicate itself either, so accepted rows join the comparison set.
        if verdict.accepted:
            seen.append(_normalize(candidate.body))
    return verdicts


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--theme", action="append", help="Theme to generate for. Repeatable.")
    parser.add_argument(
        "--thinnest",
        type=int,
        default=0,
        help="Instead of --theme, take the N themes with the fewest prompts.",
    )
    parser.add_argument("--kind", default="question", choices=sorted(KIND_SHAPES))
    parser.add_argument("--count", type=int, default=20, help="Candidates per theme.")
    parser.add_argument("--min-age", type=int, default=24)
    parser.add_argument("--max-age", type=int, default=216)
    parser.add_argument(
        "--seasonal",
        action="store_true",
        help="Allow prompts that need an occasion. Off by default.",
    )
    parser.add_argument("--out-dir", type=Path, default=CANDIDATES)
    args = parser.parse_args(argv)

    api_key = os.environ.get("ANTHROPIC_API_KEY", "").strip()
    if not api_key:
        # Skipped, not failed. This runs from a workflow where a missing key means "not
        # configured yet", and a red X there would say something untrue about the code.
        print(
            "ANTHROPIC_API_KEY is not set, so there is nothing to generate.\n"
            "Set it and re-run:\n"
            "    export ANTHROPIC_API_KEY=sk-ant-...\n"
            "    uv run python scripts/generate_prompts.py --thinnest 4\n"
            "Everything else in this script — the filters, the rendering — runs without it "
            "and is covered by tests/test_generate_prompts.py.",
            file=sys.stderr,
        )
        return 0

    library = load_library()
    existing = [_normalize(row["body"]) for row in library]

    themes = list(args.theme or [])
    if args.thinnest:
        themes += [t for t in thinnest_themes(library, args.thinnest) if t not in themes]
    if not themes:
        parser.error("give --theme at least once, or --thinnest N")

    args.out_dir.mkdir(parents=True, exist_ok=True)
    today = dt.date.today()
    written: list[Path] = []

    for theme in themes:
        verdicts = generate(
            theme=theme,
            kind=args.kind,
            count=args.count,
            ages=(args.min_age, args.max_age),
            api_key=api_key,
            seasonal=args.seasonal,
            existing=existing,
        )
        path = args.out_dir / f"{theme}-{today.isoformat()}.md"
        path.write_text(
            render(theme, args.kind, verdicts, generated_on=today, model=MODEL),
            encoding="utf-8",
        )
        written.append(path)
        kept = sum(1 for v in verdicts if v.accepted)
        print(f"{theme}: {kept}/{len(verdicts)} kept -> {path.relative_to(REPO)}")
        # Accepted rows join the comparison set across themes too, so two batches in one run
        # cannot hand you the same prompt twice.
        existing += [_normalize(v.candidate.body) for v in verdicts if v.accepted]

    if not written:
        print("nothing written")
    return 0


if __name__ == "__main__":
    sys.exit(main())
