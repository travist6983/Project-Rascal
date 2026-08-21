"""The batch-review CLI: it flags, and it never rejects.

**Rewired by phase 103 and the change is visible in these fixtures.** `flags_for` used to carry
its own copy of the tone rules and take a bare string. It now takes the row and delegates to
`rascal.services.candidates.judge`, the same rule set the console route and
`scripts/generate_prompts.py` run — because phase 103 made this queue fillable, and at that
moment two rule sets were looking at the same rows and disagreeing.

The fixtures below moved with it. Several used to read "him" and "his", which the old copy had
no rule about and `judge` rejects outright; they are tokenised now, like the library they
describe. **What has not moved is the contract this file exists to pin: flag automatically,
reject never.**
"""

from __future__ import annotations

import uuid

from scripts.review_candidates import flags_for, parse_decisions

from rascal.models import Prompt

#: The library's banned vocabulary, spelled out rather than imported. `candidates.BANNED` is one
#: compiled alternation and a test that iterates it would be asserting the regex against itself.
BANNED_WORDS = ("precious", "cherish", "cherished", "treasure", "treasured", "little moments")


def _prompt(body: str, *, kind: str = "activity") -> Prompt:
    """A candidate row, unsaved. `flags_for` reads the kind and age band as well as the body."""
    return Prompt(
        body=body,
        theme="everyday-ordinary",
        kind=kind,
        cadence="daily",
        completion_mode="did_it",
        min_age_months=24,
        max_age_months=216,
        month_tags=[],
    )


def test_a_banned_word_is_flagged_and_not_rejected() -> None:
    """**Flag automatically, reject never.** The model does not get to reject its own peers."""
    flags = flags_for(_prompt("Write down a precious memory of {them}."))

    assert [flag.rule for flag in flags] == ["banned-word"]
    assert "precious" in flags[0].detail
    # The function's whole contract: it returns reasons to look, never a verdict.
    assert not hasattr(flags[0], "verdict")
    assert not hasattr(flags[0], "rejected")


def test_every_banned_word_is_caught() -> None:
    for word in BANNED_WORDS:
        assert flags_for(_prompt(f"Something {word} here.")), word


def test_a_feeling_rather_than_an_action_is_flagged() -> None:
    flags = flags_for(_prompt("Notice how much you love watching {them} draw."))
    assert any(flag.rule == "feeling-not-action" for flag in flags)


def test_a_clean_action_prompt_is_not_flagged() -> None:
    assert (
        flags_for(_prompt("Film {them} telling you about {their} day. Don't prompt {them}.")) == []
    )


def test_a_word_inside_another_word_is_not_a_match() -> None:
    """`treasure` must not fire on `treasurer`, or the flags become noise to scroll past."""
    assert flags_for(_prompt("Ask {them} what a treasurer does.")) == []


# --- What the rewire added, and why it was worth the churn -----------------------------------


def test_a_gendered_pronoun_is_flagged_now() -> None:
    """The rule this file had no way to express, on the failure that misgenders a real child.

    The old copy checked banned words, feeling-openers and length, and nothing else — so the
    single most consequential thing a candidate can get wrong reached a reviewer unmarked.
    """
    flags = flags_for(_prompt("Film him telling you about his day."))
    assert any(flag.rule == "gendered-pronoun" for flag in flags)


def test_an_unknown_token_is_flagged_now() -> None:
    """`{thier}` renders as literal braces in the app, in an export, and in a printed book."""
    flags = flags_for(_prompt("Ask {them} about {thier} favourite toy."))
    assert any(flag.rule == "unknown-token" for flag in flags)
    assert "{thier}" in next(f for f in flags if f.rule == "unknown-token").detail


def test_the_cli_and_the_console_agree_about_length() -> None:
    """They did not, and the queue this file reads was empty for the whole time they didn't.

    `judge` rejects over 200 characters; this file used to flag over 180. A body the console
    accepted therefore arrived here flagged, with nothing to say it had already been judged.
    """
    assert flags_for(_prompt("Ask {them} to " + "explain it again and " * 8 + "then stop.")) == []


def test_a_kind_the_generator_cannot_write_is_not_flagged_as_unknown() -> None:
    """`measurement` is a real prompt kind with no generator shape. It is not a defect in a row."""
    row = _prompt("Measure how tall {they} are against the door frame.", kind="measurement")
    assert not any("unknown kind" in flag.detail for flag in flags_for(row))


# --- The decisions file -----------------------------------------------------------------------


def test_decisions_parse_into_verdicts() -> None:
    identifier = uuid.uuid4()
    text = f"# a comment\naccept {identifier}\n\nskip {uuid.uuid4()}\n"
    decisions, problems = parse_decisions(text)

    assert problems == []
    assert decisions[0] == ("accept", identifier)


def test_a_bad_line_is_reported_rather_than_skipped() -> None:
    """Nothing is applied from a file with a bad line — a partial apply over 79 candidates
    leaves you unable to tell which half landed."""
    _, problems = parse_decisions("accept not-a-uuid\nmaybe " + str(uuid.uuid4()))

    assert len(problems) == 2
