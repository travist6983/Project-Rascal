"""The mission library.

`POST /prompts/batch-review` is not absent pending a decision — it is cut. The review queue
it would have approved candidates from is a pull request: `scripts/generate_prompts.py`
writes batches into `docs/prompt-candidates/` and the Prompt candidates workflow opens the
PR. A branch with a diff is already an accept/reject interface with a comment thread, an
audit trail, and an undo. See docs/decisions-log.md.
"""

from __future__ import annotations

import uuid

from fastapi import APIRouter, Query, status
from sqlalchemy import func, select

from rascal.constants import Cadence, PromptKind, PromptSource
from rascal.deps import AdminUser, CurrentUser, SessionDep
from rascal.errors import ErrorCode, RascalError
from rascal.models import Prompt
from rascal.schemas.admin import (
    PromptActiveIn,
    PromptEditOut,
    PromptPreviewIn,
    PromptPreviewOut,
    PromptUpdate,
)
from rascal.schemas.prompt import PromptCreate, PromptOut, PromptPage
from rascal.services.library import (
    clear_override,
    edit_prompt,
    preview,
    set_active,
    validate_tokens,
)
from rascal.services.seeding import content_hash

router = APIRouter(prefix="/prompts", tags=["prompts"])


@router.get(
    "",
    response_model=PromptPage,
    summary="Browse the library",
    description="Filterable by kind, theme, age band, and source.",
)
async def list_prompts(
    session: SessionDep,
    user: CurrentUser,
    kind: PromptKind | None = Query(default=None),
    cadence: Cadence | None = Query(default=None),
    theme: str | None = Query(default=None),
    source: PromptSource | None = Query(default=None),
    active: bool | None = Query(default=None),
    age_months: int | None = Query(
        default=None, ge=0, le=300, description="Only prompts whose age window covers this."
    ),
    limit: int = Query(default=100, ge=1, le=500),
    offset: int = Query(default=0, ge=0),
) -> PromptPage:
    clauses = []
    if kind:
        clauses.append(Prompt.kind == kind)
    if cadence:
        clauses.append(Prompt.cadence == cadence)
    if theme:
        clauses.append(Prompt.theme == theme)
    if source:
        clauses.append(Prompt.source == source)
    if active is not None:
        clauses.append(Prompt.active.is_(active))
    if age_months is not None:
        clauses.append(Prompt.min_age_months <= age_months)
        clauses.append(Prompt.max_age_months >= age_months)

    total = await session.scalar(select(func.count()).select_from(Prompt).where(*clauses)) or 0
    rows = (
        (
            await session.execute(
                select(Prompt)
                .where(*clauses)
                .order_by(Prompt.kind, Prompt.body)
                .limit(limit)
                .offset(offset)
            )
        )
        .scalars()
        .all()
    )
    # The library is content, not user data, and it is small and stable — offset paging is
    # fine here in a way it never is for the timeline.
    return PromptPage(prompts=[PromptOut.model_validate(row) for row in rows], total=total)


@router.post(
    "",
    response_model=PromptOut,
    status_code=status.HTTP_201_CREATED,
    summary="Hand-author a prompt",
    description=(
        "The library is authored and reviewed server-side, never generated at request time "
        "and never authored on-device."
    ),
)
async def create_prompt(payload: PromptCreate, session: SessionDep, user: AdminUser) -> PromptOut:
    # The same token check `seeding._validate` runs over the YAML. The console is the other
    # way a body enters the library, and a `{thier}` typed here renders as literal braces on a
    # card, in an export, and in a printed book, for as long as the archive exists.
    bad = validate_tokens(payload.body)
    if bad:
        raise RascalError(
            ErrorCode.VALIDATION_FAILED,
            f"{{{bad[0]}}} is not one of the prompt tokens in docs/api-contract.md.",
            field="body",
        )
    if payload.min_age_months > payload.max_age_months:
        raise RascalError(
            ErrorCode.VALIDATION_FAILED,
            "min_age_months cannot exceed max_age_months.",
            field="min_age_months",
        )
    digest = content_hash(payload.kind, payload.cadence, payload.body)
    if await session.scalar(select(Prompt.id).where(Prompt.content_hash == digest)):
        raise RascalError(
            ErrorCode.CONFLICT,
            "The library already has this exact kind, cadence and body.",
            field="body",
        )
    prompt = Prompt(**payload.model_dump(), source="user", content_hash=digest)
    session.add(prompt)
    await session.flush()
    await session.refresh(prompt)
    return PromptOut.model_validate(prompt)


@router.post(
    "/preview",
    response_model=PromptPreviewOut,
    summary="Render one body as all three pronoun columns",
    description=(
        "The server renders nothing at serving time — bodies go out with tokens intact and "
        "every client substitutes at the last moment. This route is an authoring tool and "
        "the deliberate exception: a body can be grammatical in one column and broken in "
        "another, and the author is usually picturing one child while writing."
    ),
)
async def preview_prompt(payload: PromptPreviewIn, user: AdminUser) -> PromptPreviewOut:
    return PromptPreviewOut(
        **preview(payload.body, payload.name),
        unknown_tokens=validate_tokens(payload.body),
    )


@router.patch(
    "/{prompt_id}",
    response_model=PromptEditOut,
    summary="Edit a prompt, forking it when the edit moves its identity",
    description=(
        "**An edited body is a new prompt, not an update.** `content_hash` is "
        "`sha256(kind, cadence, body)` and the seed loader keys on it, so editing a seeded "
        "body in place would be undone by the next deploy — the row would be retired as "
        "absent from the file and the original re-inserted. Editing one of those three "
        'fields therefore inserts a `source="user"` prompt carrying the new words and '
        "retires the original through `prompt_library_overrides`, which is the one thing a "
        "re-seed will not overwrite. Everything else is edited in place."
    ),
)
async def patch_prompt(
    prompt_id: uuid.UUID, payload: PromptUpdate, session: SessionDep, user: AdminUser
) -> PromptEditOut:
    result = await edit_prompt(session, prompt_id, payload.model_dump(exclude_unset=True), user)
    return PromptEditOut(
        prompt=PromptOut.model_validate(result.prompt),
        action=result.action,
        superseded_prompt_id=result.superseded_prompt_id,
    )


@router.put(
    "/{prompt_id}/active",
    response_model=PromptOut,
    summary="Retire or revive a prompt, durably",
    description=(
        "For a seeded prompt this writes a `prompt_library_overrides` row as well as the "
        "column. The column alone is not enough: the next `fly deploy` runs the seed as its "
        "release command and writes the file's `active` back over it within minutes."
    ),
)
async def set_prompt_active(
    prompt_id: uuid.UUID, payload: PromptActiveIn, session: SessionDep, user: AdminUser
) -> PromptOut:
    prompt = await set_active(session, prompt_id, payload.active, user, payload.note)
    return PromptOut.model_validate(prompt)


@router.delete(
    "/{prompt_id}/override",
    response_model=PromptOut,
    summary="Hand this prompt back to the seed file",
    description=(
        "Deletes the override row, so the next re-seed restores whatever "
        "`docs/mission-library.md` says about this prompt. The `active` column is left where "
        "it is until then, which is the honest state: the console has stopped overriding and "
        "the file has not been consulted yet."
    ),
)
async def delete_prompt_override(
    prompt_id: uuid.UUID, session: SessionDep, user: AdminUser
) -> PromptOut:
    return PromptOut.model_validate(await clear_override(session, prompt_id))
