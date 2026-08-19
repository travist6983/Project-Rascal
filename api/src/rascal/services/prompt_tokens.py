"""Rendering prompt tokens, for the one surface where the server is the last reader.

`docs/decisions.md` settles that bodies are stored with tokens intact, that **every client
renders**, and that **the server never does**. That rule is kept everywhere except here, and the
exception is scoped to a single caller for a single reason: the rule's own stated justification is
that rendering happens *at the last moment before a human sees the sentence*. For an APNs alert
body the server **is** that last moment — there is no client between it and the lock screen, and
`docs/api-contract.md` defines the payload as carrying today's mission in `aps.alert.body`.

So a parent currently reads `Take a photo of {them} eating something {they} said {they} hated.`
Both documents are being obeyed exactly; the gap is in the contract, not in an implementation.

This is the same exception, for the same reason, that `docs/decisions.md` already grants the
widget: the widget renders before storing because the extension does no work of its own.

**This module is one dictionary and one pass. No grammar, no conjugation, no positional rules.**
It is a port of `ios/Rascal/Rascal/Models/PromptTokens.swift`, and the two are meant to be one
table — `test_prompt_tokens.py` asserts every cell against the documented contract so that they
cannot drift apart quietly.
"""

from __future__ import annotations

import logging
from typing import Final

log = logging.getLogger("rascal.prompt_tokens")

# The three pronoun columns, in the order the tuples below are written.
_HE, _SHE, _THEY = 0, 1, 2

_COLUMN: Final[dict[str, int]] = {
    "he/him": _HE,
    "she/her": _SHE,
    "they/them": _THEY,
}

#: The table, and the whole of the logic. Twelve entries plus ``{name}``, handled separately,
#: is the thirteen tokens ``constants.PROMPT_TOKENS`` lists.
#:
#: **They-forms are the keys because they/them is the only English pronoun set whose five slots
#: are five distinct words.** ``{his}`` as a key would be ambiguous between the determiner ("his
#: favourite") and the possessive pronoun ("that one is his"), which they/them splits into
#: "their" and "theirs" — so a he-keyed table cannot be substituted correctly, and the bug would
#: stay invisible until somebody set she/her.
#:
#: **Verb agreement is four explicit compound tokens, never conjugation.** A conjugator that
#: inflected the word after ``{they}`` would be correct usually, and "usually" is not a property a
#: permanent archive gets to have.
#:
#: **Capitalisation is explicit, never positional.** Nothing here capitalises a token because it
#: begins a sentence: a prompt may legitimately start mid-thought, and a positional rule would be
#: wrong somewhere across eighteen years with nobody watching.
PRONOUN_FORMS: Final[dict[str, tuple[str, str, str]]] = {
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

#: What goes to the lock screen when a rendered body still contains a brace. Deliberately says
#: nothing about the mission: a fallback that guessed would be worse than one that waits.
NEUTRAL_ALERT_BODY: Final = "Today's mission is ready."


def render(body: str, *, name: str, pronouns: str | None) -> str:
    """Substitute every known token. One pass, no regex.

    Three properties, each pinned in ``test_prompt_tokens.py``:

    1. **Text containing no tokens comes back byte-identical**, structurally rather than
       incidentally — a body with no ``{`` returns without a scan. This is what protects the
       seeded library.
    2. **A null pronoun renders the they/them column.** Unanswered degrades to correct English
       rather than to a placeholder or a guess at an answer nobody gave.
    3. **An unknown token renders literally, braces included, and never raises.** ``{foo}`` stays
       ``{foo}``. In an archive meant to outlive the app, a visible ``{foo}`` is a bug somebody can
       see and fix; a silently dropped one is a sentence that lost a word and nobody will ever know
       which word it was.

    ``render_alert_body`` deliberately diverges from property 3 — see its own note.
    """
    # Property 1 and the fast path are the same line, so "unchanged" is not a behaviour that has
    # to be maintained by anything below.
    if "{" not in body:
        return body

    column = _COLUMN.get(pronouns or "they/them", _THEY)

    out: list[str] = []
    cursor = 0
    while (open_at := body.find("{", cursor)) != -1:
        out.append(body[cursor:open_at])

        close_at = body.find("}", open_at + 1)
        if close_at == -1:
            # An unclosed brace is not an error and not a token. The rest of the body, from the
            # brace onwards, is literal text — the same answer property 3 gives for `{foo}`.
            cursor = open_at
            break

        token = body[open_at + 1 : close_at]
        value = _substitution(token, name=name, column=column)
        # Property 3: the braces go back on, because they are part of what is wrong.
        out.append(value if value is not None else body[open_at : close_at + 1])
        cursor = close_at + 1

    out.append(body[cursor:])
    return "".join(out)


def _substitution(token: str, *, name: str, column: int) -> str | None:
    """``None`` means "not a token this build knows", which the caller renders literally."""
    if token == "name":
        # An empty name leaves `{name}` standing rather than deleting a word from the sentence.
        # The schema requires a name, so this is only reachable if one is somehow blank.
        return name or None
    forms = PRONOUN_FORMS.get(token)
    return None if forms is None else forms[column]


def render_alert_body(
    body: str,
    *,
    name: str,
    pronouns: str | None,
    prompt_id: object = None,
) -> str:
    """The alert body, rendered — and withheld rather than sent with a brace still in it.

    **This is a deliberate, scoped divergence from property 3, and the only one.** Property 3
    exists so that a visible ``{foo}`` is a bug somebody can see and fix. A lock screen has no fix
    affordance and no reader who can act on it: the parent cannot edit the prompt, cannot report
    it, and cannot even scroll it. So on this surface an unrendered token is not a helpful
    signal — it is the only place where showing the bug costs more than hiding it.

    The check is on the *output*, not on the input, so it catches a token this build does not know
    as well as a body somebody wrote with a stray brace. It fails closed: any brace at all, in
    either direction, and the neutral body goes instead.

    Nothing is stored. The returned string exists for the duration of the send, and nothing is
    truncated — ``docs/api-contract.md`` already says the OS lays the alert out.
    """
    rendered = render(body, name=name, pronouns=pronouns)
    if "{" in rendered or "}" in rendered:
        # Warning rather than error: the notification still goes, and the archive is untouched.
        # The prompt id is the whole point of the log line — it is what makes the body findable.
        log.warning(
            "prompt body still contains a brace after rendering; sending neutral copy instead",
            extra={"prompt_id": str(prompt_id), "pronouns": pronouns or "they/them"},
        )
        return NEUTRAL_ALERT_BODY
    return rendered
