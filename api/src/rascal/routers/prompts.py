"""The mission library.

`POST /prompts/batch-review` is not absent pending a decision — it is cut. The review queue
it would have approved candidates from is a pull request: `scripts/generate_prompts.py`
writes batches into `docs/prompt-candidates/` and the Prompt candidates workflow opens the
PR. A branch with a diff is already an accept/reject interface with a comment thread, an
audit trail, and an undo. See docs/decisions-log.md.
"""

from __future__ import annotations

from fastapi import APIRouter, Query, status
from sqlalchemy import func, select

from rascal.constants import Cadence, PromptKind, PromptSource
from rascal.deps import AdminUser, CurrentUser, SessionDep
from rascal.models import Prompt
from rascal.schemas.prompt import PromptCreate, PromptOut, PromptPage
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
    prompt = Prompt(
        **payload.model_dump(),
        source="user",
        content_hash=content_hash(payload.kind, payload.cadence, payload.body),
    )
    session.add(prompt)
    await session.flush()
    await session.refresh(prompt)
    return PromptOut.model_validate(prompt)
