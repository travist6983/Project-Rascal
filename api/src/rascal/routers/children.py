"""Children.

`POST /children/{id}/guardians` — the invite flow — is P2 and deliberately absent. See
docs/decisions-log.md.
"""

from __future__ import annotations

import datetime as dt
import uuid
from typing import Annotated

from fastapi import APIRouter, Depends, Response, status
from sqlalchemy import select

from rascal.deps import ChildAccess, CurrentUser, SessionDep, SettingsDep, child_access
from rascal.errors import not_found, validation_failed
from rascal.models import Child, Guardian, Prompt, PromptSuppression
from rascal.schemas.child import (
    AvatarUploadUrlRequest,
    AvatarUploadUrlResponse,
    AvatarUrlResponse,
    ChildCreate,
    ChildOut,
    ChildStatsOut,
    ChildUpdate,
    ChildWithRole,
    RecomputeAgesResult,
)
from rascal.schemas.prompt import (
    PoolHealthOut,
    PromptOut,
    PromptSuppressionCreate,
    PromptSuppressionOut,
    SlotHealthOut,
)
from rascal.services import avatars
from rascal.services import entries as entries_service
from rascal.services.dates import age_in_months, today_in
from rascal.services.guardians import family_members
from rascal.services.pool_health import pool_health
from rascal.services.stats import child_stats

router = APIRouter(prefix="/children", tags=["children"])


@router.get(
    "",
    response_model=list[ChildWithRole],
    summary="Children the caller can see, with their role on each",
)
async def list_children(session: SessionDep, user: CurrentUser) -> list[ChildWithRole]:
    rows = (
        await session.execute(
            select(Child, Guardian.role)
            .join(Guardian, Guardian.child_id == Child.id)
            .where(Guardian.user_id == user.id, Guardian.revoked_at.is_(None))
            .order_by(Child.created_at)
        )
    ).all()
    return [
        ChildWithRole(
            **ChildOut.model_validate(child).model_dump(),
            role=role,
            age_months=age_in_months(child.birthdate, today_in(child.family_timezone)),
        )
        for child, role in rows
    ]


@router.post(
    "",
    response_model=ChildWithRole,
    status_code=status.HTTP_201_CREATED,
    summary="Create a child and make every parent in the household its guardian",
)
async def create_child(
    payload: ChildCreate, session: SessionDep, user: CurrentUser
) -> ChildWithRole:
    """**Every adult in the household becomes a guardian, not just the creator.**

    Phase 36 made "one household, one set of children" a promise the product is sold on. A
    child granted only to whoever happened to tap Add would be invisible to the other parent
    — and invisibly so, because a child nobody told you about looks exactly like a child that
    does not exist. The failure would appear days later as "why can't I see Nora", which is
    the worst shape a sharing bug can have.
    """
    child = Child(
        name=payload.name,
        birthdate=payload.birthdate,
        pronouns=payload.pronouns,
        family_timezone=payload.family_timezone,
    )
    session.add(child)
    await session.flush()
    for member in await family_members(session, user.family_id):
        session.add(Guardian(user_id=member.id, child_id=child.id, role="parent"))
    await session.flush()
    await session.refresh(child)
    return ChildWithRole(
        **ChildOut.model_validate(child).model_dump(),
        role="parent",
        age_months=age_in_months(child.birthdate, today_in(child.family_timezone)),
    )


@router.patch(
    "/{child_id}",
    response_model=ChildOut,
    summary="Update a child's name, birthdate, timezone, or avatar",
    description=(
        "Every field is optional and an omitted field is left alone. An explicit `null` "
        "clears `pronouns` and `avatar_key` and is `422` on the other three, whose columns "
        "are NOT NULL.\n\n"
        "`avatar_key` must be a key this child's `avatar-upload-url` minted. Any other key is "
        "`422`: `GET /children/{child_id}/avatar-url` presigns whatever is stored, so a child "
        "record accepting an arbitrary key would be a way to read any object in a private "
        "bucket — including another child's media."
    ),
)
async def update_child(
    child_id: uuid.UUID,
    payload: ChildUpdate,
    session: SessionDep,
    access: ChildAccess = Depends(child_access("parent")),
) -> ChildOut:
    child = access.child
    # exclude_unset so a client can clear avatar_key or pronouns with an explicit null without
    # having to resend every other field. The schema refuses a null aimed at a NOT NULL column.
    fields = payload.model_dump(exclude_unset=True)

    # The shape `avatars.build_avatar_key` mints. Checked here rather than in the schema
    # because it is the *path's* child that has to own the key, and only the resolved access
    # knows which child that is. A null still clears the avatar.
    avatar_key = fields.get("avatar_key")
    if avatar_key is not None and not avatar_key.startswith(f"children/{child.id}/avatar/"):
        raise validation_failed(
            "avatar_key must be a key returned by this child's avatar-upload-url.",
            field="avatar_key",
        )

    for field, value in fields.items():
        setattr(child, field, value)
    await session.flush()
    await session.refresh(child)
    return ChildOut.model_validate(child)


@router.post(
    "/{child_id}/avatar-upload-url",
    response_model=AvatarUploadUrlResponse,
    summary="Presign a single PUT for the child's avatar",
    description=(
        "One presigned PUT — never multipart, because an avatar is a small square and the "
        "multipart machinery exists for video. Accepts JPEG, PNG, or HEIC.\n\n"
        "**This stores nothing.** It returns a key; `PATCH /children/{child_id}` with "
        "`avatar_key` is what commits it, and only after the PUT succeeds. An upload the "
        "client abandons therefore leaves an orphaned object rather than a child record "
        "pointing at bytes that never arrived — of the two, only the second is visible to a "
        "parent.\n\n"
        "Read it back with `GET /children/{child_id}/avatar-url`; the bucket is private, so "
        "the key alone is not fetchable."
    ),
)
async def avatar_upload_url(
    payload: AvatarUploadUrlRequest,
    settings: SettingsDep,
    access: ChildAccess = Depends(child_access("parent")),
) -> AvatarUploadUrlResponse:
    upload_url, avatar_key = avatars.plan_avatar_upload(
        access.child_id,
        content_type=payload.content_type,
        size=payload.bytes,
        settings=settings,
    )
    return AvatarUploadUrlResponse(
        upload_url=upload_url,
        avatar_key=avatar_key,
        expires_in=settings.presign_ttl_seconds,
    )


@router.get(
    "/{child_id}/avatar-url",
    response_model=AvatarUrlResponse,
    summary="A short-lived read URL for the child's avatar",
    description=(
        "`viewer` is enough: anyone who can see the child can see their face.\n\n"
        '404 when the child has no avatar. That is deliberately not a null URL — "this '
        'child has no avatar" and "here is a URL that will not resolve" are different '
        "answers, and only the first lets a client fall back to initials without a round "
        "trip that fails."
    ),
)
async def avatar_url(
    settings: SettingsDep,
    access: ChildAccess = Depends(child_access("viewer")),
) -> AvatarUrlResponse:
    return AvatarUrlResponse(
        url=avatars.presign_avatar_read(access.child, settings),
        expires_in=settings.presign_ttl_seconds,
    )


@router.post(
    "/{child_id}/recompute-ages",
    response_model=RecomputeAgesResult,
    summary="Correct every stored child_age_months from the current birthdate",
    description=(
        "`entries.child_age_months` is computed at write and stored, so fixing a birthdate "
        "typo does not silently reshape the archive. This is the escape hatch that makes "
        "the correction happen, deliberately and on request. Every entry is recomputed from "
        "its own `occurred_at`, soft-deleted ones included, in a single transaction. Only "
        "the rows that actually change are written, so `GET /sync` carries the correction "
        "without carrying the whole archive with it. `entries_updated` counts rows changed, "
        "not rows examined, and a second call immediately after returns `0`."
    ),
)
async def recompute_ages(
    session: SessionDep,
    access: ChildAccess = Depends(child_access("parent")),
) -> RecomputeAgesResult:
    child = access.child
    return RecomputeAgesResult(
        child_id=child.id,
        entries_updated=await entries_service.recompute_child_ages(session, child),
        birthdate=child.birthdate,
    )


# --- Prompt suppression ----------------------------------------------------------------------


@router.post(
    "/{child_id}/prompt-suppressions",
    response_model=PromptSuppressionOut,
    status_code=status.HTTP_201_CREATED,
    summary="Never show this prompt to this child again",
    description=(
        "Idempotent. Suppressing an already-suppressed prompt returns the existing row rather "
        "than failing, and re-suppressing one that was undone revives that row rather than "
        "creating a second.\n\n"
        "**This outranks every relaxation rule**, including an empty candidate pool. A "
        "suppressed prompt is removed from the pool before selection begins, so the relaxed "
        "90-day cooldown, the dropped theme rotation and the final 'anything at all' fallback "
        "each fall back to a list it was never in.\n\n"
        "Distinct from dismissing an assignment, which still means 'not today'. See "
        "`docs/decisions.md` — whether the client's single dismiss action should offer this is "
        "an open product question that this endpoint deliberately does not answer."
    ),
)
async def suppress_prompt(
    payload: PromptSuppressionCreate,
    session: SessionDep,
    access: Annotated[ChildAccess, Depends(child_access("parent"))],
) -> PromptSuppressionOut:
    prompt = await session.get(Prompt, payload.prompt_id)
    if prompt is None:
        raise not_found("Prompt")

    existing = await session.get(PromptSuppression, (access.child.id, payload.prompt_id))
    if existing is None:
        existing = PromptSuppression(
            child_id=access.child.id, prompt_id=payload.prompt_id, reason=payload.reason
        )
        session.add(existing)
    else:
        # Idempotent revival. `updated_at` is the trigger's, never set here.
        existing.revoked_at = None
        if payload.reason is not None:
            existing.reason = payload.reason
    await session.flush()
    await session.refresh(existing)
    return PromptSuppressionOut.model_validate(
        {**existing.__dict__, "prompt": PromptOut.model_validate(prompt)}
    )


@router.delete(
    "/{child_id}/prompt-suppressions/{prompt_id}",
    status_code=status.HTTP_204_NO_CONTENT,
    summary="Undo a suppression",
    description=(
        "Soft delete — `revoked_at` is set and the row stays, so the prompt becomes eligible "
        "again and the change syncs as a row rather than as an absence. **A permanent decision "
        "a parent cannot undo is worse than no decision.** Idempotent: revoking twice is still "
        "`204`. A prompt this child never suppressed is `404`."
    ),
)
async def unsuppress_prompt(
    prompt_id: uuid.UUID,
    session: SessionDep,
    access: Annotated[ChildAccess, Depends(child_access("parent"))],
) -> Response:
    existing = await session.get(PromptSuppression, (access.child.id, prompt_id))
    if existing is None:
        raise not_found("Suppression")
    existing.revoked_at = existing.revoked_at or dt.datetime.now(tz=dt.UTC)
    await session.flush()
    return Response(status_code=status.HTTP_204_NO_CONTENT)


@router.get(
    "/{child_id}/prompt-suppressions",
    response_model=list[PromptSuppressionOut],
    summary="What this child has been told to stop asking",
    description=(
        "So a client can show what has been suppressed and offer to restore it. Live rows "
        "only by default — pass `include_revoked=true` to see undone ones too."
    ),
)
async def list_prompt_suppressions(
    session: SessionDep,
    access: Annotated[ChildAccess, Depends(child_access("viewer"))],
    include_revoked: bool = False,
) -> list[PromptSuppressionOut]:
    clauses = [PromptSuppression.child_id == access.child.id]
    if not include_revoked:
        clauses.append(PromptSuppression.revoked_at.is_(None))
    rows = (
        await session.execute(
            select(PromptSuppression, Prompt)
            .join(Prompt, Prompt.id == PromptSuppression.prompt_id)
            .where(*clauses)
            .order_by(PromptSuppression.created_at.desc())
        )
    ).all()
    return [
        PromptSuppressionOut.model_validate(
            {**suppression.__dict__, "prompt": PromptOut.model_validate(prompt)}
        )
        for suppression, prompt in rows
    ]


@router.get(
    "/{child_id}/pool-health",
    response_model=PoolHealthOut,
    summary="How close this child's prompt pool is to repeating itself",
    description=(
        "Computed on every call, never cached — an admin-grade read, not a hot path.\n\n"
        "**It reports and nothing else.** The scheduler decides; a health check that quietly "
        "reshaped selection would make the number it returns a description of itself.\n\n"
        "`estimated_days_until_first_repeat` is an estimate and the name says so — and it is "
        "derived from the rate this slot is **observed** to be served, never from the "
        "cadence it is nominally on. A null carries `estimate_basis` to say which kind "
        "of null it is."
    ),
)
async def child_pool_health(
    session: SessionDep,
    access: Annotated[ChildAccess, Depends(child_access("viewer"))],
) -> PoolHealthOut:
    as_of = today_in(access.child.family_timezone)
    slots = await pool_health(session, access.child, as_of=as_of)
    return PoolHealthOut(
        child_id=access.child.id,
        as_of=as_of,
        age_months=age_in_months(access.child.birthdate, as_of),
        slots=[SlotHealthOut.model_validate(slot.__dict__) for slot in slots],
    )


@router.get(
    "/{child_id}/stats",
    response_model=ChildStatsOut,
    summary="How much is in this child's archive",
    description=(
        "Counted on every call, never cached — the same admin-grade read `pool-health` is, "
        "and for the same reason: a cached count of a growing archive is a number that is "
        "wrong for exactly as long as the cache lives.\n\n"
        "**This exists because the client cannot answer it.** The timeline is a paged, "
        "partial cache, so Settings dropped its stats strip and its first-entry line rather "
        "than let the app assert the size of an archive it has only seen part of.\n\n"
        "`first_entry_on` and `last_entry_on` are calendar days in the child's "
        "`family_timezone`, and are `null` on an empty archive."
    ),
)
async def child_stats_route(
    session: SessionDep,
    access: Annotated[ChildAccess, Depends(child_access("viewer"))],
) -> ChildStatsOut:
    stats = await child_stats(session, access.child)
    return ChildStatsOut(
        child_id=access.child.id,
        # The child's day, not the server's — every other date this API returns is in the
        # family timezone and this one has no reason to be the exception.
        as_of=today_in(access.child.family_timezone),
        entries=stats.entries,
        sealed=stats.sealed,
        media=stats.media,
        first_entry_on=stats.first_entry_on,
        last_entry_on=stats.last_entry_on,
    )
