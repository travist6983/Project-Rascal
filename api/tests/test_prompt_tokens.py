"""The token table, pinned cell by cell, and the one surface where the server renders.

**Two implementations of one table drifting apart is the failure mode**, so the table below is
written out longhand from `docs/decisions.md` rather than derived from the code it checks. A test
that reads `PRONOUN_FORMS` to build its own expectation asserts nothing.
"""

from __future__ import annotations

import logging

import pytest

from rascal.constants import PROMPT_TOKENS
from rascal.services.prompt_tokens import (
    NEUTRAL_ALERT_BODY,
    PRONOUN_FORMS,
    render,
    render_alert_body,
)

# docs/decisions.md, the pronoun token table, transcribed by hand:
# token -> (he/him, she/her, they/them)
DOCUMENTED: dict[str, tuple[str, str, str]] = {
    "they": ("he", "she", "they"),
    "them": ("him", "her", "them"),
    "their": ("his", "her", "their"),
    "theirs": ("his", "hers", "theirs"),
    "themself": ("himself", "herself", "themself"),
    "they_are": ("he is", "she is", "they are"),
    "they_were": ("he was", "she was", "they were"),
    "they_have": ("he has", "she has", "they have"),
    "they_do": ("he does", "she does", "they do"),
    "They": ("He", "She", "They"),
    "Them": ("Him", "Her", "Them"),
    "Their": ("His", "Her", "Their"),
}


class TestTheTableIsTheContract:
    def test_every_cell_matches_the_documented_table(self) -> None:
        assert PRONOUN_FORMS == DOCUMENTED

    def test_the_table_is_thirteen_tokens_not_fourteen(self) -> None:
        """The count is worth asserting because two prose lines get it wrong.

        `docs/decisions.md` and `docs/api-contract.md` both say "Fourteen tokens" above a table
        with thirteen rows. Five surfaces agree on thirteen: that table, the contract's own table,
        `constants.PROMPT_TOKENS`, the iOS renderer, and this. **Nobody should ever "fix" the
        count by inventing a fourteenth token** — this is the assertion that stops them.
        """
        assert len(PRONOUN_FORMS) == 12, "twelve pronoun forms"
        assert len(PROMPT_TOKENS) == 13, "plus {name} is thirteen tokens"

    def test_it_is_the_same_table_the_seed_loader_validates_against(self) -> None:
        """`PROMPT_TOKENS` gates what may be seeded; this renders what was. If they disagree, a
        body can be authored that no renderer knows, or known that nothing may author."""
        assert set(PRONOUN_FORMS) | {"name"} == set(PROMPT_TOKENS)

    def test_the_four_agreement_compounds_are_present(self) -> None:
        # Explicit compounds rather than conjugation: "usually correct" is not a property a
        # permanent archive gets to have.
        for token in ("they_are", "they_were", "they_have", "they_do"):
            assert token in PRONOUN_FORMS

    def test_the_three_capitals_are_present_and_are_not_positional(self) -> None:
        for token in ("They", "Them", "Their"):
            assert token in PRONOUN_FORMS
        # A prompt may legitimately begin mid-thought, so nothing capitalises by position.
        assert render("{they} ran", name="Ada", pronouns="he/him") == "he ran"


class TestInvariantsOneAndTwo:
    """Unchanged from the contract, on every surface including this one."""

    def test_token_free_text_passes_byte_identical(self) -> None:
        body = "Get on the floor for ten minutes."
        assert render(body, name="Ada", pronouns="he/him") is body

    def test_a_null_pronoun_renders_the_they_them_column(self) -> None:
        body = "Ask {them} what {they} did."
        assert render(body, name="Ada", pronouns=None) == "Ask them what they did."

    def test_an_unrecognised_pronoun_value_also_falls_to_they_them(self) -> None:
        assert render("{they} ran", name="Ada", pronouns="xe/xem") == "they ran"

    @pytest.mark.parametrize(
        ("pronouns", "expected"),
        [
            ("he/him", "Take a photo of him eating something he said he hated."),
            ("she/her", "Take a photo of her eating something she said she hated."),
            ("they/them", "Take a photo of them eating something they said they hated."),
            (None, "Take a photo of them eating something they said they hated."),
        ],
    )
    def test_the_reported_lock_screen_sentence(self, pronouns: str | None, expected: str) -> None:
        """The sentence from the report, in every column."""
        body = "Take a photo of {them} eating something {they} said {they} hated."
        assert render(body, name="Ada", pronouns=pronouns) == expected

    def test_name_renders_and_an_empty_name_leaves_the_token_standing(self) -> None:
        assert render("{name} did it", name="Ada", pronouns=None) == "Ada did it"
        # Deleting a word from the sentence would be worse than showing the token.
        assert render("{name} did it", name="", pronouns=None) == "{name} did it"


class TestInvariantThreeOnTheOrdinarySurface:
    """An unknown token stays visible, because a visible bug is one somebody can fix."""

    @pytest.mark.parametrize(
        "body",
        [
            "{foo}",
            "a {foo} b",
            "{thier} spelled wrong",
            "{}",
            "unclosed {they",
            "}{",
            "{{they}}",
        ],
    )
    def test_unknown_and_malformed_tokens_survive_without_raising(self, body: str) -> None:
        rendered = render(body, name="Ada", pronouns="he/him")
        assert isinstance(rendered, str)

    def test_an_unknown_token_keeps_its_braces(self) -> None:
        assert render("a {foo} b", name="Ada", pronouns="he/him") == "a {foo} b"

    def test_an_unclosed_brace_is_literal_from_the_brace_onwards(self) -> None:
        assert render("ask {they and {them}", name="Ada", pronouns="he/him") == (
            "ask {they and {them}"
        )

    def test_a_known_token_beside_an_unknown_one_still_renders(self) -> None:
        assert render("{they} and {foo}", name="Ada", pronouns="she/her") == "she and {foo}"


class TestTheScopedDivergenceForTheAlertBody:
    """**The one place the contract is deliberately broken, and why.**

    Invariant 3 exists so a visible `{foo}` is a bug somebody can see and fix. A lock screen has
    no fix affordance and no reader who can act — so here, and only here, an unrendered token is
    withheld rather than shown.
    """

    def test_a_fully_rendered_body_is_sent_as_is(self) -> None:
        body = "Take a photo of {them} eating something {they} said {they} hated."
        assert render_alert_body(body, name="Ada", pronouns="he/him", prompt_id="p1") == (
            "Take a photo of him eating something he said he hated."
        )

    def test_a_body_with_an_unknown_token_sends_neutral_copy_instead(self) -> None:
        assert (
            render_alert_body(
                "Ask {them} about {thier} day", name="Ada", pronouns="he/him", prompt_id="p1"
            )
            == NEUTRAL_ALERT_BODY
        )

    @pytest.mark.parametrize("body", ["{foo}", "a } b", "unclosed {they", "{}", "}{"])
    def test_it_fails_closed_on_any_brace_in_either_direction(self, body: str) -> None:
        rendered = render_alert_body(body, name="Ada", pronouns=None, prompt_id="p1")
        assert rendered == NEUTRAL_ALERT_BODY
        assert "{" not in rendered and "}" not in rendered

    def test_the_neutral_body_promises_nothing_about_the_mission(self) -> None:
        # A fallback that guessed at the mission would be worse than one that waits.
        assert NEUTRAL_ALERT_BODY == "Today's mission is ready."
        assert "{" not in NEUTRAL_ALERT_BODY

    def test_it_logs_a_warning_naming_the_prompt(self, caplog: pytest.LogCaptureFixture) -> None:
        """The prompt id is the whole point of the log line: it makes the body findable."""
        with caplog.at_level(logging.WARNING, logger="rascal.prompt_tokens"):
            render_alert_body("{foo}", name="Ada", pronouns=None, prompt_id="abc-123")
        assert len(caplog.records) == 1
        record = caplog.records[0]
        assert record.levelno == logging.WARNING
        assert record.prompt_id == "abc-123"

    def test_a_clean_body_logs_nothing(self, caplog: pytest.LogCaptureFixture) -> None:
        with caplog.at_level(logging.WARNING, logger="rascal.prompt_tokens"):
            render_alert_body("nothing to render", name="Ada", pronouns=None, prompt_id="p1")
        assert caplog.records == []


class TestItStoresNothingAndTruncatesNothing:
    def test_the_input_body_is_not_mutated(self) -> None:
        """Rendering is a copy. The archive keeps its tokens."""
        body = "Ask {them} about {their} day."
        before = str(body)
        render_alert_body(body, name="Ada", pronouns="she/her", prompt_id="p1")
        assert body == before

    def test_nothing_is_truncated(self) -> None:
        """The contract says the OS lays the alert out, so nothing here shortens it."""
        body = "Ask {them} " + ("about their very long day " * 40)
        rendered = render_alert_body(body, name="Ada", pronouns="he/him", prompt_id="p1")
        assert rendered.endswith("about their very long day ")
        assert len(rendered) > 900

    def test_rendering_is_pure_and_repeatable(self) -> None:
        body = "Ask {them} about {their} day."
        first = render_alert_body(body, name="Ada", pronouns=None, prompt_id="p1")
        second = render_alert_body(body, name="Ada", pronouns=None, prompt_id="p1")
        assert first == second == "Ask them about their day."
