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
from rascal.services.social import scenes

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
        eyebrow=payload.get("eyebrow"),
        headline=payload.get("headline"),
        subhead=payload.get("subhead"),
        caption=payload.get("caption"),
        alt_text=payload.get("alt_text"),
        hashtags=payload.get("hashtags") or [],
        image_prompt=payload.get("image_prompt"),
        featured_prompt_id=featured[0] if featured else None,
        featured_body=featured[1] if featured else None,
        model=payload.get("model"),
        created_by_user_id=author.id,
    )
    _apply_treatment(asset, payload.get("treatment", _ABSENT))
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
    "eyebrow",
    "headline",
    "subhead",
    "caption",
    "alt_text",
    "hashtags",
    "image_prompt",
    # `treatment` is here; `caption_track` and `duration_seconds` deliberately are not. Both
    # are derived from the scene graph by `_apply_treatment` below, and a PATCH that could set
    # them is a PATCH that can make the captions disagree with the cards. That divergence was
    # possible until phase 120 and nothing detected it.
    "treatment",
)


#: Distinguishes *absent* from *explicitly null*. `changes.pop("treatment", None)` cannot:
#: `SocialAssetUpdate` is partial, so a PATCH that omits the field and one that sends
#: `"treatment": null` both arrive as `None` under `exclude_unset`, and the second silently did
#: nothing while answering 200.
_ABSENT = object()


def _apply_treatment(asset: SocialAsset, treatment: object) -> None:
    """Set the scene graph and re-derive everything that hangs off it.

    **One function, called from both write paths**, because the invariant is not "the captions
    are derived on creation" — it is that a `caption_track` on a row is always the one these
    scenes produce. An edit that changed the scenes and left the old track would be the same
    defect arriving by a different door.

    Clearing is a real operation: `"treatment": null` empties the graph **and** everything
    derived from it, because a caption track left standing beside no scenes is the divergence
    this function exists to prevent, arriving by the one door a partial update leaves open.

    `duration_seconds` is a display figure and the exact runtime is the sum of `duration_ms` in
    the graph itself, which is what the caption stamps and the browser's clock both read. It
    rounds **up**, not to nearest: `round()` in Python is round-half-to-even, so a 6500ms
    treatment would come back as 6 and a 7500ms one as 8, which is a surprise nobody wants in a
    number on a screen. Ceiling is also the honest reading — a 6.5 second video occupies seven
    seconds of anybody's feed.
    """
    if treatment is _ABSENT:
        return
    if treatment is None:
        asset.treatment = None
        asset.caption_track = None
        asset.duration_seconds = None
        return
    asset.treatment = treatment
    scene_list = list(treatment.get("scenes") or [])
    asset.caption_track = scenes.caption_track(scene_list)
    asset.duration_seconds = -(-scenes.total_ms(scene_list) // 1000)


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

    treatment = changes.pop("treatment", _ABSENT)
    for key, value in changes.items():
        setattr(asset, key, value)
    _apply_treatment(asset, treatment)
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
        "eyebrow": asset.eyebrow,
        "headline": asset.headline,
        "subhead": asset.subhead,
        "caption": asset.caption,
        "alt_text": asset.alt_text,
        "hashtags": list(asset.hashtags or []),
        "image_prompt": asset.image_prompt,
        "treatment": asset.treatment,
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
