"""The batch-review CLI: it flags, and it never rejects."""

from __future__ import annotations

import uuid

from scripts.review_candidates import BANNED_WORDS, flags_for, parse_decisions


def test_a_banned_word_is_flagged_and_not_rejected() -> None:
    """**Flag automatically, reject never.** The model does not get to reject its own peers."""
    flags = flags_for("Write down a precious memory of him.")

    assert [flag.rule for flag in flags] == ["banned-word"]
    assert "precious" in flags[0].detail
    # The function's whole contract: it returns reasons to look, never a verdict.
    assert not hasattr(flags[0], "verdict")
    assert not hasattr(flags[0], "rejected")


def test_every_banned_word_is_caught() -> None:
    for word in BANNED_WORDS:
        assert flags_for(f"Something {word} here."), word


def test_a_feeling_rather_than_an_action_is_flagged() -> None:
    flags = flags_for("Notice how much you love watching him draw.")
    assert any(flag.rule == "feeling-not-action" for flag in flags)


def test_a_clean_action_prompt_is_not_flagged() -> None:
    assert flags_for("Film him telling you about his day. Don't prompt him.") == []


def test_a_word_inside_another_word_is_not_a_match() -> None:
    """`treasure` must not fire on `treasurer`, or the flags become noise to scroll past."""
    assert flags_for("Ask him what a treasurer does.") == []


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
