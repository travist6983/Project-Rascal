"""The candidate filters.

`scripts/generate_prompts.py` is the only thing in this repo that calls a model, and the
model call is the one part of it that cannot be tested here. Everything else — the four
rejection rules from `docs/mission-library.md`, the duplicate check, the rendering — is
ordinary code and is tested as such.

The fixtures below are written to be recognisable: the accepted ones are real prompts from
the library, and the rejected ones are the specific failures the library warns about.
"""

from __future__ import annotations

import datetime as dt
import importlib

import httpx as export_httpx
import pytest
from scripts.generate_prompts import (
    Candidate,
    _normalize,
    build_request,
    call_model,
    judge,
    render,
    thinnest_themes,
)


def _candidate(
    body: str, *, kind: str = "question", ages: tuple[int, int] = (24, 216)
) -> Candidate:
    return Candidate(
        body=body,
        theme="everyday-ordinary",
        kind=kind,
        min_age_months=ages[0],
        max_age_months=ages[1],
        rationale="because",
    )


def _judge(body: str, *, kind: str = "question", existing=None, **kwargs):
    return judge(_candidate(body, kind=kind), existing=existing or [], **kwargs)


# --- The four rules -------------------------------------------------------------------------------


@pytest.mark.parametrize(
    "body",
    [
        "Photograph a precious everyday moment.",
        "Write down the things you cherish about him right now.",
        "Record a memory you will treasure.",
        "Take a picture of one of the little moments.",
    ],
)
def test_the_banned_vocabulary_is_banned(body: str) -> None:
    verdict = _judge(body, kind="photo")
    assert not verdict.accepted
    assert any("banned vocabulary" in reason for reason in verdict.reasons)


def test_the_sentimental_register_is_caught_even_without_the_banned_words() -> None:
    """ "capture the magic of these fleeting days" uses none of the four words and is exactly
    the thing the four words are a proxy for."""
    verdict = _judge("Take a moment to soak up the magic of these fleeting days.", kind="photo")
    assert not verdict.accepted
    assert any("sentimental register" in reason for reason in verdict.reasons)


def test_a_mission_that_asks_for_a_feeling_is_not_a_mission() -> None:
    verdict = _judge("Notice how you feel watching him sleep tonight.", kind="activity")
    assert not verdict.accepted
    assert "describes a feeling instead of an action" in verdict.reasons


def test_a_question_may_ask_about_a_feeling() -> None:
    """ "What is he afraid of right now?" is in the library. The feeling rule is for missions.

    Written with `{name}` rather than the library's "he": the fixture is here for the feeling
    rule, and a gendered one would now be rejected for an unrelated reason.
    """
    assert _judge("What is {name} afraid of right now?").accepted
    assert _judge("How did that feel to you, honestly?").accepted


@pytest.mark.parametrize(
    ("body", "expected"),
    [
        ("Get a photo of him with mom and dad.", "assumes a household shape"),
        ("Ask your partner what they noticed about him this week.", "assumes a household shape"),
        ("Buy him the toy he keeps asking about and photograph his face.", "assumes an income"),
        ("Take him to a restaurant and record what he orders.", "assumes an income"),
        ("Go for a hike with him and photograph where you stopped.", "assumes an ability"),
    ],
)
def test_assumptions_about_the_household_are_rejected(body: str, expected: str) -> None:
    verdict = _judge(body, kind="photo")
    assert not verdict.accepted
    assert any(reason.startswith(expected) for reason in verdict.reasons)


@pytest.mark.parametrize(
    "body",
    [
        "Take him to the zoo and photograph what he stares at longest.",
        "Plan a day trip and record the conversation in the car.",
        "Photograph his birthday party from the back of the room.",
    ],
)
def test_anything_that_needs_an_occasion_is_rejected(body: str) -> None:
    verdict = _judge(body, kind="photo")
    assert not verdict.accepted
    assert any(reason.startswith("not an ordinary Tuesday") for reason in verdict.reasons)


def test_a_seasonal_batch_is_allowed_to_need_an_occasion() -> None:
    """The library has month-tagged prompts. An occasion is the point of those."""
    verdict = _judge(
        "Photograph {their} birthday party from the back of the room.", kind="photo", seasonal=True
    )
    assert verdict.accepted, verdict.reasons


@pytest.mark.parametrize(
    ("body", "kind"),
    [
        ("Photograph the mess he made. Do not clean it first.", "photo"),
        ("Record her telling you a story. Do not correct anything.", "audio"),
        ("What does his laugh sound like right now?", "question"),
        ("Get on the floor and play whatever she is playing for ten minutes.", "activity"),
    ],
)
def test_new_copy_may_not_assume_a_gender(body: str, kind: str) -> None:
    """The seeded 113 are he/him and are being rewritten; nothing new may add to that pile."""
    verdict = _judge(body, kind=kind)
    assert not verdict.accepted
    assert any(reason.startswith("assumes a gender") for reason in verdict.reasons)


@pytest.mark.parametrize(
    ("body", "kind"),
    [
        ("Photograph the mess {they} made. Do not clean it first.", "photo"),
        ("Record {them} telling you a story. Do not correct anything.", "audio"),
        ("What does {their} laugh sound like right now?", "question"),
        ("Get on the floor and play whatever {they_are} playing for ten minutes.", "activity"),
        ("What made {name} laugh today?", "question"),
    ],
)
def test_the_pronoun_tokens_are_not_mistaken_for_a_gender(body: str, kind: str) -> None:
    """The rule is word-boundary anchored, so no token trips it.

    This is the half that would fail silently: a rule that rejected `{them}` for containing
    "hem", or `{their}` for "heir", would reject exactly the copy it is asking for. These are
    the tokenised forms of four real library prompts, which is what the generator must now
    produce instead of the he/him it reads in its own style reference.
    """
    verdict = _judge(body, kind=kind)
    assert verdict.accepted, verdict.reasons


def test_ordinary_words_that_merely_contain_those_letters_are_left_alone() -> None:
    """shed, history, others, treasurer — the reason the rule is `\\b`-anchored."""
    verdict = _judge("Photograph the shed and whatever history is stacked in it.", kind="photo")
    assert verdict.accepted, verdict.reasons


# --- The prompts that must survive ----------------------------------------------------------------


@pytest.mark.parametrize(
    ("body", "kind"),
    [
        ("What did {they} say this week that you want to remember exactly?", "question"),
        ("Photograph the mess {they} made. Do not clean it first.", "photo"),
        ("Get on the floor and play whatever {they_are} playing for ten minutes.", "activity"),
        ("Record {them} telling you a story. Do not correct anything.", "audio"),
        ("What word does {name} mispronounce that you don't want to correct?", "question"),
    ],
)
def test_the_library_would_pass_its_own_filters(body: str, kind: str) -> None:
    """A filter that would reject the hand-authored library is calibrated wrong.

    "Get on the floor for ten minutes" in particular: an aggressive physical-ability rule
    would eat one of the best prompts in the file.

    **The gender rule used to be a deliberate exception here and no longer is.** These
    bodies were quoted verbatim from a library that was literal he/him, so the rule fired on
    all five and this asserted around it. Phase 24 tokenised all 113, the fixtures came with
    them, and the assertion is what the docstring always said it would become: bare
    `accepted`. Nothing in the library is exempt from the library's own filters now.
    """
    verdict = _judge(body, kind=kind)
    assert verdict.accepted, verdict.reasons


# --- Shape ----------------------------------------------------------------------------------------


def test_a_question_has_to_be_a_question_and_a_mission_has_to_not_be() -> None:
    assert "a question that is not a question" in _judge("Describe his laugh.").reasons
    assert (
        "a mission phrased as a question"
        in _judge("Can you photograph his hands?", kind="photo").reasons
    )


def test_an_impossible_age_band_is_rejected() -> None:
    verdict = judge(
        Candidate(
            body="What is he obsessed with right now?",
            theme="t",
            kind="question",
            min_age_months=120,
            max_age_months=36,
        ),
        existing=[],
    )
    assert any("age band" in reason for reason in verdict.reasons)


def test_something_far_too_long_is_rejected() -> None:
    verdict = _judge("What " + "very " * 60 + "long?")
    assert any("longer than" in reason for reason in verdict.reasons)


def test_every_reason_is_reported_not_just_the_first() -> None:
    """A reviewer tuning the instructions wants the whole list, not the first tripwire."""
    verdict = _judge("Buy him something precious at the zoo with mom and dad?", kind="photo")
    assert len(verdict.reasons) >= 4


# --- Duplicates -----------------------------------------------------------------------------------


def test_a_reworded_duplicate_is_caught() -> None:
    existing = [_normalize("What word does he mispronounce that you don't want to correct?")]
    verdict = _judge(
        "What word does he mispronounce that you do not want to correct?", existing=existing
    )
    assert "too close to a prompt already in the library" in verdict.reasons


def test_a_genuine_variant_survives() -> None:
    """Near-duplicate detection that eats variants is worse than none — the library is full
    of deliberately adjacent prompts."""
    existing = [_normalize("What did he say this week that you want to remember exactly?")]
    verdict = _judge(
        "What is the last thing {they} asked that you could not answer?", existing=existing
    )
    assert verdict.accepted, verdict.reasons


# --- Library helpers ------------------------------------------------------------------------------


def test_the_thinnest_themes_are_the_ones_with_the_fewest_prompts() -> None:
    library = [
        {"theme": "everyday-ordinary", "body": "a"},
        {"theme": "everyday-ordinary", "body": "b"},
        {"theme": "everyday-ordinary", "body": "c"},
        {"theme": "food", "body": "d"},
        {"theme": "food", "body": "e"},
        {"theme": "outdoors", "body": "f"},
    ]
    assert thinnest_themes(library, 2) == ["outdoors", "food"]


def test_the_real_library_is_what_the_generator_is_pointed_at() -> None:
    """The request carries the whole library as the style reference, per the library's own
    'Expanding the library' section. If that ever stops being true the output drifts."""
    request = build_request(theme="fears-comfort", kind="question", count=20, ages=(24, 144))
    text = request["messages"][0]["content"]
    assert "Photograph the mess {they} made" in text  # i.e. the actual file, not a summary
    assert "fears-comfort" in text
    assert "24 and 144 months" in text
    # Structured output, so nothing has to be parsed back out of prose.
    assert request["tool_choice"]["name"] == "emit_candidates"


# --- Rendering ------------------------------------------------------------------------------------


def test_the_worksheet_shows_the_rejections_and_why() -> None:
    verdicts = [
        _judge("What is he obsessed with right now?"),
        _judge("Photograph a precious moment.", kind="photo"),
    ]
    page = render(
        "everyday-ordinary", "question", verdicts, generated_on=dt.date(2026, 8, 4), model="m"
    )

    assert "## Accepted" in page
    assert "What is he obsessed with right now?" in page
    assert "## Rejected" in page
    assert "banned vocabulary" in page
    # The reviewer is told what to do with the file, including deleting it.
    assert "mission_library_to_yaml.py" in page
    assert "Delete this file" in page


def test_a_pipe_in_a_prompt_does_not_break_the_table() -> None:
    # Accepted, so it renders in the four-cell table this is measuring. A gendered body would
    # be routed to the two-cell rejected table and the delimiter count would mean nothing.
    verdicts = [_judge("What does {name} call you | every version?")]
    page = render("t", "question", verdicts, generated_on=dt.date(2026, 8, 4), model="m")
    body_row = next(line for line in page.splitlines() if "every version" in line)
    assert "\\|" in body_row
    # Only the cell delimiters count as delimiters: four cells, not five.
    assert body_row.replace("\\|", "").count("|") == 5


# --- Configuration ---------------------------------------------------------------------


@pytest.mark.parametrize(
    ("value", "expected"),
    [
        (None, "claude-sonnet-5"),
        # The one that matters: `${{ vars.ANTHROPIC_MODEL }}` on an unset repository variable
        # arrives as an empty string, not as an absent one. A `get` default would sail past
        # this and hand the API `"model": ""`.
        ("", "claude-sonnet-5"),
        ("   ", "claude-sonnet-5"),
        ("some-other-model", "some-other-model"),
    ],
)
def test_an_unset_model_variable_falls_back_rather_than_sending_an_empty_string(
    value: str | None, expected: str, monkeypatch: pytest.MonkeyPatch
) -> None:
    if value is None:
        monkeypatch.delenv("ANTHROPIC_MODEL", raising=False)
    else:
        monkeypatch.setenv("ANTHROPIC_MODEL", value)

    module = importlib.reload(importlib.import_module("scripts.generate_prompts"))
    try:
        resolved = module.MODEL
        assert resolved == expected
    finally:
        # Leave the module as the rest of the suite imported it.
        monkeypatch.delenv("ANTHROPIC_MODEL", raising=False)
        importlib.reload(module)


# --- Talking to the API --------------------------------------------------------------


class _Response:
    """The parts of httpx.Response that call_model touches."""

    def __init__(self, status_code: int, payload=None, text: str = "") -> None:
        self.status_code = status_code
        self._payload = payload
        self.text = text

    def json(self):
        if self._payload is None:
            raise ValueError("not json")
        return self._payload


def _call(monkeypatch: pytest.MonkeyPatch, response: _Response):
    monkeypatch.setattr(export_httpx, "post", lambda *a, **k: response)
    request = build_request(theme="t", kind="question", count=1, ages=(24, 216))
    with pytest.raises(SystemExit) as caught:
        call_model(request, "sk-ant-fake")
    return str(caught.value)


def test_an_api_error_reports_what_the_api_actually_said(
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    """The failure this exists to prevent: a workflow log that says only "400 Bad Request".

    httpx's raise_for_status throws the body away, and the body is the only place the API
    explains itself.
    """
    message = _call(
        monkeypatch,
        _Response(
            400,
            {"error": {"type": "invalid_request_error", "message": "model: nonesuch"}},
        ),
    )
    assert "invalid_request_error" in message
    assert "model: nonesuch" in message
    # And enough request context to tell which call failed without a re-run.
    assert "max_tokens" in message


def test_a_non_json_error_body_still_reaches_the_log(
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    """A gateway 502 is HTML, not JSON. Losing it to a decode error helps nobody."""
    message = _call(monkeypatch, _Response(502, None, text="<html>bad gateway</html>"))
    assert "502" in message
    assert "bad gateway" in message


def test_a_refusal_says_so_instead_of_looking_like_an_empty_batch(
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    message = _call(
        monkeypatch,
        _Response(
            200,
            {"stop_reason": "refusal", "stop_details": {"category": "bio"}, "content": []},
        ),
    )
    assert "declined" in message
    assert "bio" in message
    # Retrying an identical refused request is never the answer.
    assert "retrying unchanged" in message


def test_a_missing_tool_block_names_what_did_come_back(
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    message = _call(
        monkeypatch,
        _Response(200, {"stop_reason": "max_tokens", "content": [{"type": "text"}]}),
    )
    assert "max_tokens" in message
    assert "text" in message


def test_a_good_response_yields_the_candidates(monkeypatch: pytest.MonkeyPatch) -> None:
    monkeypatch.setattr(
        export_httpx,
        "post",
        lambda *a, **k: _Response(
            200,
            {
                "stop_reason": "tool_use",
                "content": [
                    {
                        "type": "tool_use",
                        "name": "emit_candidates",
                        "input": {"candidates": [{"body": "What did he say?"}]},
                    }
                ],
            },
        ),
    )
    request = build_request(theme="t", kind="question", count=1, ages=(24, 216))
    assert call_model(request, "sk-ant-fake") == [{"body": "What did he say?"}]
