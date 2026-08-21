"""Reading and writing social assets, and the one guard that matters.

`featured_body_ledger` is the guard. `docs/decisions.md` D7 keeps the mission library out of
anything public *"whole or in generated slices"* and calls it the one asset in this project a
competitor would actually want. A studio that can put a prompt on a card is a machine for
producing those slices — publicly, permanently, and one at a time, which is the shape of leak
nobody notices until it is complete.

Three things hold it, and none of them is "remember not to":

1. **Claude never sees the library.** No tool, no context, and the brief tells it not to
   invent lines that read like one. See `brand.py`.
2. **Featuring a body is an explicit act.** The owner picks one prompt in the Library tab; the
   API takes a `featured_prompt_id` and reads the body itself rather than accepting one.
3. **Every body that reaches a post is counted against a cap.** Cumulative, visible in the
   Studio, and enforced here rather than in the browser.
"""

from __future__ import annotations

import datetime as dt
import uuid
from dataclasses import dataclass
from typing import Any

from sqlalchemy import func, select
from sqlalchemy.ext.asyncio import AsyncSession

from rascal.config import Settings
from rascal.errors import ErrorCode, RascalError, not_found
from rascal.models import Prompt, SocialAsset, User

#: Statuses that mean the words left the building, or are about to. A discarded draft never
#: went anywhere and does not count against the library.
COUNTS_AS_PUBLISHED = ("draft", "approved", "exported", "published")


@dataclass(frozen=True)
class Ledger:
    featured: int
    library_size: int
    cap: int

    @property
    def remaining(self) -> int:
        return max(0, self.cap - self.featured)

    def as_dict(self) -> dict[str, Any]:
        return {
            "featured": self.featured,
            "library_size": self.library_size,
            "cap": self.cap,
            "remaining": self.remaining,
            "why": (
                "D7 keeps the mission library out of anything public, whole or in generated "
                "slices. Posting prompts one at a time is how that happens without anybody "
                "deciding to, so they are counted. Raise SOCIAL_FEATURED_PROMPT_CAP "
                "deliberately, having looked at this number."
            ),
        }


async def featured_body_ledger(session: AsyncSession, settings: Settings) -> Ledger:
    """How much of the library has been put on a card, against how much there is."""
    featured = (
        await session.scalar(
            select(func.count(func.distinct(SocialAsset.featured_prompt_id))).where(
                SocialAsset.featured_prompt_id.is_not(None),
                SocialAsset.status.in_(COUNTS_AS_PUBLISHED),
            )
        )
        or 0
    )
    library = (
        await session.scalar(
            select(func.count()).select_from(Prompt).where(Prompt.active.is_(True))
        )
        or 0
    )
    return Ledger(
        featured=int(featured),
        library_size=int(library),
        cap=settings.social_featured_prompt_cap,
    )


async def resolve_featured(
    session: AsyncSession,
    settings: Settings,
    prompt_id: uuid.UUID | None,
) -> tuple[uuid.UUID, str] | None:
    """Look up the body for a prompt the owner chose, refusing past the cap.

    **The body is read here rather than accepted from the caller.** A client that could send
    its own `featured_body` could put any text on a card and label it a library prompt, and
    the ledger would be counting something other than what it claims to count.

    A prompt already featured does not consume another unit of the cap — the budget is about
    how much of the library has been shown, not how many posts were made.
    """
    if prompt_id is None:
        return None

    prompt = await session.get(Prompt, prompt_id)
    if prompt is None:
        raise not_found("Prompt")

    already = await session.scalar(
        select(func.count())
        .select_from(SocialAsset)
        .where(
            SocialAsset.featured_prompt_id == prompt_id,
            SocialAsset.status.in_(COUNTS_AS_PUBLISHED),
        )
    )
    if not already:
        ledger = await featured_body_ledger(session, settings)
        if ledger.remaining <= 0:
            raise RascalError(
                ErrorCode.VALIDATION_FAILED,
                f"{ledger.featured} of {ledger.library_size} library prompts have already been "
                f"put into posts, which is the cap. The library is the one asset a competitor "
                f"would want and D7 keeps it out of public view — raise "
                f"SOCIAL_FEATURED_PROMPT_CAP if that is the call you want to make.",
                field="featured_prompt_id",
            )
    return prompt.id, prompt.body


async def create_asset(
    session: AsyncSession,
    settings: Settings,
    payload: dict[str, Any],
    author: User,
) -> SocialAsset:
    featured = await resolve_featured(session, settings, payload.get("featured_prompt_id"))
    asset = SocialAsset(
        platform=payload.get("platform") or "generic",
        format=payload.get("format") or "card",
        angle=payload.get("angle"),
        template=payload.get("template"),
        palette=payload.get("palette"),
        headline=payload.get("headline"),
        subhead=payload.get("subhead"),
        caption=payload.get("caption"),
        alt_text=payload.get("alt_text"),
        hashtags=payload.get("hashtags") or [],
        image_prompt=payload.get("image_prompt"),
        shot_list=payload.get("shot_list"),
        caption_track=payload.get("caption_track"),
        duration_seconds=payload.get("duration_seconds"),
        featured_prompt_id=featured[0] if featured else None,
        featured_body=featured[1] if featured else None,
        model=payload.get("model"),
        created_by_user_id=author.id,
    )
    session.add(asset)
    await session.flush()
    await session.refresh(asset)
    return asset


#: Fields a PATCH may touch. `featured_prompt_id` is deliberately absent: attaching a library
#: body to an existing asset would slip past `resolve_featured` and its cap, so it is a
#: property of creation only.
EDITABLE = (
    "platform",
    "format",
    "status",
    "angle",
    "template",
    "palette",
    "headline",
    "subhead",
    "caption",
    "alt_text",
    "hashtags",
    "image_prompt",
    "shot_list",
    "caption_track",
    "duration_seconds",
)


async def get_asset(session: AsyncSession, asset_id: uuid.UUID) -> SocialAsset:
    """One post, or the 404 every caller would otherwise hand-roll."""
    asset = await session.get(SocialAsset, asset_id)
    if asset is None:
        raise not_found("Social asset")
    return asset


async def update_asset(
    session: AsyncSession, asset_id: uuid.UUID, changes: dict[str, Any]
) -> SocialAsset:
    asset = await get_asset(session, asset_id)

    changes = {key: value for key, value in changes.items() if key in EDITABLE}

    # **Alt text is required to leave the building.** Insisting at the moment the file is
    # about to be used, rather than while somebody is still typing, is the only version of
    # this rule that does not just get switched off.
    going_out = changes.get("status") in ("exported", "published")
    if going_out and not (changes.get("alt_text") or asset.alt_text):
        raise RascalError(
            ErrorCode.VALIDATION_FAILED,
            "This post has no alt text. An image posted without it is a post a blind reader "
            "gets nothing from — write one sentence describing what is visibly in it.",
            field="alt_text",
        )

    for key, value in changes.items():
        setattr(asset, key, value)
    if changes.get("status") == "published" and asset.published_at is None:
        asset.published_at = dt.datetime.now(tz=dt.UTC)
    await session.flush()
    await session.refresh(asset)
    return asset


async def list_assets(
    session: AsyncSession, *, status: str | None, limit: int
) -> list[SocialAsset]:
    clauses = [SocialAsset.status == status] if status else []
    rows = await session.execute(
        select(SocialAsset).where(*clauses).order_by(SocialAsset.created_at.desc()).limit(limit)
    )
    return list(rows.scalars().all())


def as_dict(asset: SocialAsset) -> dict[str, Any]:
    return {
        "id": str(asset.id),
        "platform": asset.platform,
        "status": asset.status,
        "format": asset.format,
        "angle": asset.angle,
        "template": asset.template,
        "palette": asset.palette,
        "headline": asset.headline,
        "subhead": asset.subhead,
        "caption": asset.caption,
        "alt_text": asset.alt_text,
        "hashtags": list(asset.hashtags or []),
        "image_prompt": asset.image_prompt,
        "shot_list": asset.shot_list,
        "caption_track": asset.caption_track,
        "duration_seconds": asset.duration_seconds,
        "render_provider": asset.render_provider,
        "render_key": asset.render_key,
        "featured_prompt_id": str(asset.featured_prompt_id) if asset.featured_prompt_id else None,
        "featured_body": asset.featured_body,
        "model": asset.model,
        "published_at": asset.published_at.isoformat() if asset.published_at else None,
        "created_at": asset.created_at.isoformat(),
        "updated_at": asset.updated_at.isoformat(),
    }
