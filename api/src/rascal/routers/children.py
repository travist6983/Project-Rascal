"""Children.

`POST /children/{id}/guardians` — the invite flow — is P2 and deliberately absent. See
docs/decisions-log.md.
"""

from __future__ import annotations

import uuid

from fastapi import APIRouter, Depends, status
from sqlalchemy import select

from rascal.deps import ChildAccess, CurrentUser, SessionDep, child_access
from rascal.models import Child, Guardian
from rascal.schemas.child import (
    ChildCreate,
    ChildOut,
    ChildUpdate,
    ChildWithRole,
    RecomputeAgesResult,
)
from rascal.services import entries as entries_service
from rascal.services.dates import age_in_months, today_in

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
    summary="Create a child and make the caller its parent",
)
async def create_child(
    payload: ChildCreate, session: SessionDep, user: CurrentUser
) -> ChildWithRole:
    child = Child(
        name=payload.name,
        birthdate=payload.birthdate,
        family_timezone=payload.family_timezone,
    )
    session.add(child)
    await session.flush()
    session.add(Guardian(user_id=user.id, child_id=child.id, role="parent"))
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
)
async def update_child(
    child_id: uuid.UUID,
    payload: ChildUpdate,
    session: SessionDep,
    access: ChildAccess = Depends(child_access("parent")),
) -> ChildOut:
    child = access.child
    # exclude_unset so a client can clear avatar_key with an explicit null without having to
    # resend every other field.
    for field, value in payload.model_dump(exclude_unset=True).items():
        setattr(child, field, value)
    await session.flush()
    await session.refresh(child)
    return ChildOut.model_validate(child)


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
