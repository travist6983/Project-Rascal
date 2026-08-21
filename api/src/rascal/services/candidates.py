"""The mission library's rejection rules, in the one place both callers can reach them.

**Why this module exists rather than an import from `scripts/`.** These filters were written
for `scripts/generate_prompts.py` in phase 46 and lived there happily while a batch job was
the only thing that ran them. `api/Dockerfile` copies `src`, `alembic.ini`, `alembic` and
`seeds` — and nothing else — so a running service cannot import `scripts.generate_prompts` at
all. Phase 103 gives the console a generate button, which makes these rules something the API
enforces at request time, so they move to where the API can see them.

**Moved, with three deliberate changes.** Every threshold and `judge`'s reason wording are the
ones the batch script has used since phase 46 and that `tests/test_generate_prompts.py` pins.
`scripts/generate_prompts.py` imports them back from here, which is what keeps one rule set
rather than two drifting copies — and its unchanged test suite passing is the proof the lift
was clean.

**Three deliberate changes, all recorded in `docs/decisions-log.md`:**

1. `judge` now rejects a body carrying a `{token}` outside `constants.PROMPT_TOKENS`. It is
   the same check `services.library.validate_tokens` runs over a hand-typed body and
   `services.seeding` runs over the YAML, and it was the one authoring path without it. A
   misspelled token renders as literal braces on a card, in an export and in a printed book
   for as long as the archive exists, and `judge` is the only gate a generated body passes.
2. `FEELING_NOT_ACTION` opens on `notice how` rather than `notice how you`.
   `scripts/review_candidates.py` carried the broader opener, and its canonical example —
   "Notice how much you love watching {them} draw" — matched there and not here. Narrowing on
   merge would have lost exactly the coverage the consolidation existed to protect.
3. What the script called `MISSION_KINDS` is `IMPERATIVE_KINDS` here.
   `services/scheduler.py:52` already defines `MISSION_KINDS` in this package with a
   different meaning — *which kinds may fill the monthly measurement slot* — and two
   constants with one name and two meanings drift the first time either changes. The name
   here describes what it is actually used for: the kinds whose bodies are instructions, so
   a trailing question mark is a defect.

**These filters are a spam trap, not an editor.** They catch the four rejection rules from
`docs/mission-library.md` where the rule is textually detectable, and nothing else. A human
reads every candidate that survives them, and — since phase 103 — may keep one they reject.
"""

from __future__ import annotations

import re
from dataclasses import dataclass, field

from rascal.services.library import validate_tokens

#: What each kind's prompts have to look like, mirrored from the library's own headings.
KIND_SHAPES: dict[str, dict[str, str]] = {
    "question": {"cadence": "daily", "completion_mode": "text"},
    "photo": {"cadence": "daily", "completion_mode": "media"},
    "video": {"cadence": "daily", "completion_mode": "media"},
    "audio": {"cadence": "daily", "completion_mode": "media"},
    "activity": {"cadence": "daily", "completion_mode": "did_it"},
    "letter": {"cadence": "monthly", "completion_mode": "text"},
}

#: The kinds whose bodies are instructions rather than questions. Named for that rather than
#: for "mission", which `services/scheduler.py` already uses for a different set.
IMPERATIVE_KINDS = ("photo", "video", "audio", "activity")

MIN_LENGTH = 12
MAX_LENGTH = 200

# docs/mission-library.md writes age ranges with an en dash — "24\u2013216". Matching it
# exactly is what makes an accepted row paste straight into that file. Named, and written
# as an escape, so it does not read as a stray non-ASCII character — same as the script it
# came from, whose own ruff run rejects a literal one here.
DASH = "\u2013"

#: The band the whole library lives in. A candidate outside it cannot be served to anybody.
LIBRARY_MIN_AGE = 24
LIBRARY_MAX_AGE = 216


# --- The rejection rules -------------------------------------------------------------------
#
# docs/mission-library.md, "Expanding the library". Reject anything that:
#   - uses the words precious, cherish, treasure, or little moments
#   - describes a feeling instead of an action
#   - couldn't be done in the middle of an ordinary Tuesday
#   - assumes a two-parent household, a particular income, or a particular ability
#
# And two rules that are not from that section: no bare gendered pronoun, and no token outside
# the table. docs/mission-library.md, "Pronoun and name tokens" — new prompts refer to the
# child with the token table in docs/api-contract.md, never with he/him or she/her.


def _words(*terms: str) -> re.Pattern[str]:
    return re.compile(r"\b(?:" + "|".join(terms) + r")\b", re.IGNORECASE)


BANNED = _words(
    "precious",
    "cherish(?:ed|es|ing)?",
    "treasure[sd]?",
    "treasuring",
    "little moments?",
)

# The register the library exists to avoid. "Photograph the mess {they} made, don't clean it
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
# it a task. Questions are exempt — "What is {they} afraid of right now?" is a question *about*
# a feeling, which is exactly the point of the question set.
# `notice how` rather than `notice how you`, widened in phase 103. `scripts/review_candidates.py`
# carried its own broader opener list until this module became the single rule set, and
# "Notice how much you love watching {them} draw" — the canonical example, and the one its test
# pins — matched there and not here. Narrowing on merge would have quietly lost the coverage the
# consolidation was supposed to protect.
FEELING_NOT_ACTION = re.compile(
    r"^\s*(?:feel|notice how|remember how|think about how|imagine how|reflect|"
    r"appreciate|take a moment)\b|how (?:it|that|this) (?:feels|felt)|"
    r"\bthe feeling of\b",
    re.IGNORECASE,
)

# Assumes a household, an income, or an ability. Narrow on purpose: an aggressive rule here
# would reject "get on the floor for ten minutes", which is one of the best prompts in the
# library. This is a tripwire for the obvious cases, not a substitute for reading the batch.
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

# Nothing new may assume a child's gender. This is enforced here rather than only asked for in
# the system prompt because the library goes into every request as the style reference, and a
# model imitates what it reads.
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
    elif candidate.kind in IMPERATIVE_KINDS and body.endswith("?"):
        verdict.reasons.append("a mission phrased as a question")

    if found := BANNED.findall(body):
        verdict.reasons.append(f"banned vocabulary: {', '.join(sorted(set(found)))}")
    if found := SENTIMENTAL.findall(body):
        verdict.reasons.append(f"sentimental register: {', '.join(sorted(set(found)))}")

    if candidate.kind in IMPERATIVE_KINDS and FEELING_NOT_ACTION.search(body):
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

    # Added in phase 103. `services.library.validate_tokens` is the same check a hand-typed
    # body gets; this was the one authoring path without it.
    if unknown := validate_tokens(body):
        verdict.reasons.append(
            f"unknown token{'s' if len(unknown) > 1 else ''}: "
            f"{', '.join('{' + token + '}' for token in sorted(set(unknown)))} — "
            "renders as literal braces"
        )

    if not seasonal and (found := NEEDS_AN_OCCASION.findall(body)):
        verdict.reasons.append(f"not an ordinary Tuesday: {', '.join(sorted(set(found)))}")

    if not (
        LIBRARY_MIN_AGE <= candidate.min_age_months < candidate.max_age_months <= LIBRARY_MAX_AGE
    ):
        verdict.reasons.append(
            f"age band {candidate.min_age_months}{DASH}{candidate.max_age_months} "
            f"is outside {LIBRARY_MIN_AGE}{DASH}{LIBRARY_MAX_AGE}"
        )

    if _too_similar(body, existing):
        verdict.reasons.append("too close to a prompt already in the library")

    return verdict
