"""Editing the mission library from the admin console, without losing the edit on deploy.

Everything here exists because of one line in `services/seeding.py`: the loader's idempotency
key is `sha256(kind, cadence, body)`. Editing a body is therefore **not an update** — the row
you wrote is a row the seed file does not contain, and the next `fly deploy` retires it and
re-inserts the original. Phase 24 relied on exactly that behaviour to retokenise 113 bodies at
once; it is correct, and it is also the reason a naive `UPDATE prompts SET body = …` from a
web console is a change that silently reverts within the hour.

So an edit to a **seeded** prompt is modelled as what it actually is: a fork.

    1. Insert a new prompt carrying the new body, `source="user"`.
       `seed_prompts` never touches a non-seeded row, so the fork survives every deploy.
    2. Write a `prompt_library_overrides` row retiring the *original's* hash.
       `_apply_overrides` runs last in the seed transaction, so the retirement survives too.
    3. Deactivate the original now, so the change is visible before the next deploy rather
       than only after one.

Steps 1 and 2 are both required and neither is sufficient. Step 1 alone leaves the old body
serving beside the new one — two versions of the same question in one archive. Step 2 alone
leaves a retired prompt and nothing in its place.

A `user` or `llm` prompt was never in the seed file, so it has none of this to worry about and
is edited in place, hash recomputed.
"""

from __future__ import annotations

import dataclasses
import uuid
from typing import Any

from sqlalchemy import delete, select
from sqlalchemy.ext.asyncio import AsyncSession

from rascal.constants import PROMPT_TOKENS
from rascal.errors import ErrorCode, RascalError, not_found
from rascal.models import Prompt, PromptLibraryOverride, User
from rascal.services.prompt_tokens import render
from rascal.services.seeding import TOKEN_PATTERN, content_hash

#: What may be changed on a prompt. `source` and `content_hash` are not editable: one records
#: where a body came from and the other is derived, and letting a console write either would
#: let it lie to the seed loader about which rows the file owns.
EDITABLE = (
    "kind",
    "cadence",
    "completion_mode",
    "body",
    "theme",
    "min_age_months",
    "max_age_months",
    "month_tags",
    "default_unlock_age",
    "active",
)

#: Changing any of these moves the prompt's identity, because they are what `content_hash` is
#: computed from. An edit touching one of them forks a seeded prompt rather than updating it.
IDENTITY = ("kind", "cadence", "body")


@dataclasses.dataclass(frozen=True)
class EditResult:
    prompt: Prompt
    #: `updated` — edited in place. `superseded` — a new prompt now carries the words and the
    #: old one is retired. The console shows a different sentence for each, because the second
    #: leaves a row behind and the reader should know that.
    action: str
    superseded_prompt_id: uuid.UUID | None = None


def validate_tokens(body: str) -> list[str]:
    """Every `{token}` in a body that no client can render. Returns the bad ones.

    The same check `seeding._validate` runs over the YAML, applied here because the console is
    the *other* way a body enters the library and the failure is identical: a misspelled token
    renders as literal braces on a card, in an export, and in a printed book, permanently.

    Deliberately a list rather than a raise, so the console can mark the offending token in a
    field the author is still typing in rather than rejecting the whole save.
    """
    return [token for token in TOKEN_PATTERN.findall(body) if token not in PROMPT_TOKENS]


def preview(body: str, name: str) -> dict[str, str]:
    """One body as all three pronoun columns read it.

    The point of showing all three at once is that a body can be grammatical in one column and
    broken in another — `{they_have}` versus a hand-written "has" is the classic — and the
    author is usually picturing only one child while writing.
    """
    return {
        "he_him": render(body, name=name, pronouns="he/him"),
        "she_her": render(body, name=name, pronouns="she/her"),
        "they_them": render(body, name=name, pronouns="they/them"),
        # What a child with no pronoun on file gets: the they/them column, which is
        # grammatical for every child and is not a guess at an answer nobody gave.
        "unset": render(body, name=name, pronouns=None),
    }


async def _load(session: AsyncSession, prompt_id: uuid.UUID) -> Prompt:
    prompt = await session.get(Prompt, prompt_id)
    if prompt is None:
        raise not_found("Prompt")
    return prompt


async def _hash_is_free(session: AsyncSession, digest: str, *, excluding: uuid.UUID) -> bool:
    existing = await session.scalar(
        select(Prompt.id).where(Prompt.content_hash == digest, Prompt.id != excluding)
    )
    return existing is None


async def edit_prompt(
    session: AsyncSession,
    prompt_id: uuid.UUID,
    changes: dict[str, Any],
    editor: User,
) -> EditResult:
    """Apply an edit, forking the prompt when the edit moves its identity."""
    prompt = await _load(session, prompt_id)
    changes = {key: value for key, value in changes.items() if key in EDITABLE}
    if not changes:
        return EditResult(prompt=prompt, action="updated")

    if "body" in changes:
        bad = validate_tokens(changes["body"])
        if bad:
            raise RascalError(
                ErrorCode.VALIDATION_FAILED,
                f"{{{bad[0]}}} is not one of the prompt tokens. Every client would render it "
                "as literal braces.",
                field="body",
            )
    if changes.get("min_age_months", prompt.min_age_months) > changes.get(
        "max_age_months", prompt.max_age_months
    ):
        raise RascalError(
            ErrorCode.VALIDATION_FAILED,
            "min_age_months cannot exceed max_age_months.",
            field="min_age_months",
        )

    moves_identity = any(
        key in changes and changes[key] != getattr(prompt, key) for key in IDENTITY
    )
    if not moves_identity:
        for key, value in changes.items():
            setattr(prompt, key, value)
        await session.flush()
        await session.refresh(prompt)
        return EditResult(prompt=prompt, action="updated")

    new = {key: getattr(prompt, key) for key in EDITABLE}
    new.update(changes)
    digest = content_hash(new["kind"], new["cadence"], new["body"])

    if prompt.source != "seeded":
        # Never in the seed file, so nothing downstream will contest the change. Edit in place
        # and move the hash with the body — the unique index is the only thing to respect.
        if not await _hash_is_free(session, digest, excluding=prompt.id):
            raise RascalError(
                ErrorCode.CONFLICT,
                "Another prompt already has this exact kind, cadence and body.",
                field="body",
            )
        for key, value in changes.items():
            setattr(prompt, key, value)
        prompt.content_hash = digest
        await session.flush()
        await session.refresh(prompt)
        return EditResult(prompt=prompt, action="updated")

    if not await _hash_is_free(session, digest, excluding=prompt.id):
        raise RascalError(
            ErrorCode.CONFLICT,
            "Another prompt already has this exact kind, cadence and body.",
            field="body",
        )

    replacement = Prompt(**new, source="user", content_hash=digest)
    session.add(replacement)
    await session.flush()

    # The original is retired twice over, and both are load-bearing: the column so the change
    # is live now, the override so the next re-seed does not put it back.
    prompt.active = False
    await _write_override(
        session,
        content_hash_value=prompt.content_hash,
        active=False,
        note=f"Superseded by {replacement.id} from the admin console.",
        editor=editor,
    )
    await session.flush()
    await session.refresh(replacement)
    return EditResult(prompt=replacement, action="superseded", superseded_prompt_id=prompt.id)


async def set_active(
    session: AsyncSession, prompt_id: uuid.UUID, active: bool, editor: User, note: str | None
) -> Prompt:
    """Retire or revive a prompt, durably.

    For a seeded prompt the column alone is not enough — the next deploy writes the file's
    `active` back over it. The override row is what makes the decision stick, and deleting it
    is what hands the decision back to `mission-library.md`.
    """
    prompt = await _load(session, prompt_id)
    prompt.active = active

    if prompt.source == "seeded":
        await _write_override(
            session,
            content_hash_value=prompt.content_hash,
            active=active,
            note=note,
            editor=editor,
        )
    await session.flush()
    await session.refresh(prompt)
    return prompt


async def clear_override(session: AsyncSession, prompt_id: uuid.UUID) -> Prompt:
    """Give the seed file its opinion of this prompt back.

    A real DELETE rather than a soft one: the library is content, not user data, nothing syncs
    it, and the *absence* of a row is precisely what "the file decides" means. The column is
    left where it is until the next seed run, which is the honest state — the console has
    stopped overriding, and the file has not been consulted yet.
    """
    prompt = await _load(session, prompt_id)
    await session.execute(
        delete(PromptLibraryOverride).where(
            PromptLibraryOverride.content_hash == prompt.content_hash
        )
    )
    await session.flush()
    return prompt


async def _write_override(
    session: AsyncSession,
    *,
    content_hash_value: str,
    active: bool,
    note: str | None,
    editor: User,
) -> None:
    existing = await session.get(PromptLibraryOverride, content_hash_value)
    if existing is None:
        session.add(
            PromptLibraryOverride(
                content_hash=content_hash_value,
                active=active,
                note=note,
                created_by_user_id=editor.id,
            )
        )
        return
    existing.active = active
    existing.note = note
    existing.created_by_user_id = editor.id
