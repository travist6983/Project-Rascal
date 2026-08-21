"""Turning a shot list into a video: the job, its guards, and what it refuses to start.

Seven shots are seven generations and a concatenation, and the whole thing takes minutes. That
shapes everything here.

**Every guard runs before a single clip is generated.** A treatment is real money — roughly ten
cents a second — and the expensive failure is not a job that refuses, it is a job that renders
six clips and then discovers there is no ffmpeg to join them with. So the configuration check,
the ffmpeg check, the shot-list check and the already-running check all happen while the
request is still open, and the caller is told which one failed.

**A row is written before the work starts.** The console polls it; a machine that restarts
mid-job leaves a row saying `running` with four of seven clips rather than leaving nothing at
all, which is the difference between a job that visibly died and a button that did nothing.

**Clips are stored as they land, and the cost is recorded with them.** The money is spent at
generation, so a job that fails on the seventh shot has still bought six clips and the ledger
says so. They stay in the bucket: assembling six clips by hand is a worse afternoon than
assembling seven, and it is a great deal better than paying twice.

**Sequential, not concurrent.** Google's published limit is a rolling ten-minute *spend* cap —
$10 on tier 1 — rather than a request rate, so seven clips fired at once is the shape most
likely to hit it, and hitting it halfway costs money for nothing. One at a time also means the
progress the console shows is real.
"""

from __future__ import annotations

import asyncio
import datetime as dt
import logging
import uuid
from typing import Any

import httpx
from anyio import to_thread
from sqlalchemy import select
from sqlalchemy.ext.asyncio import AsyncSession

from rascal.config import Settings
from rascal.db import get_sessionmaker
from rascal.errors import ErrorCode, RascalError
from rascal.models import SocialAsset, SocialRender
from rascal.services.social import gemini, stitch
from rascal.services.social.renderers import store

log = logging.getLogger("rascal.social.renders")

PROVIDER = "gemini_video"

#: A single generation is documented as taking anywhere from seconds to several minutes, and
#: seven of them run one after another. The client timeout is per request, not for the job.
_PER_CLIP_TIMEOUT = httpx.Timeout(600.0, connect=10.0)

#: Added on top of the whole job's theoretical worst case before a live row is called dead.
#: Generous deliberately: cancelling a job that is merely slow starts a second one beside it,
#: and two jobs rendering the same treatment is the expensive mistake.
_STALE_GRACE = dt.timedelta(minutes=10)


def shots_of(asset: SocialAsset) -> list[dict[str, Any]]:
    return list((asset.shot_list or {}).get("shots") or [])


def estimate_cents(settings: Settings, shots: list[dict[str, Any]]) -> int:
    """What a treatment will cost to render, before rendering it.

    Returned on the asset's render status so the console can price a treatment beside the
    button rather than after the invoice. A figure derived from a price somebody typed into the
    environment, like every other estimate in this service, and the console says so.
    """
    seconds = sum(int(shot.get("seconds") or 0) for shot in shots)
    return seconds * settings.gemini_video_cents_per_second


async def preflight(
    session: AsyncSession, settings: Settings, asset: SocialAsset
) -> list[dict[str, Any]]:
    """Every reason not to start, checked before anything is spent. Returns the shots."""
    shots = shots_of(asset)
    if not shots:
        raise RascalError(
            ErrorCode.VALIDATION_FAILED,
            "This post has no shot list to render. Write one in the Studio first.",
            field="shot_list",
        )
    if not settings.gemini_api_key:
        raise RascalError(
            ErrorCode.VALIDATION_FAILED,
            "Set GEMINI_API_KEY to render video. Note the Gemini video models have a "
            "free-tier quota of zero, so billing must be enabled on the project as well — a "
            "key that answers text requests will still refuse video until it is.",
            field="gemini_api_key",
        )
    if not stitch.available():
        # Checked here rather than after seven generations, which is the version of this
        # failure that costs three dollars to discover.
        raise RascalError(
            ErrorCode.VALIDATION_FAILED,
            "ffmpeg is not installed on this machine, so the clips could be generated and "
            "then not joined. Refusing before spending anything.",
            field="ffmpeg",
        )
    running = await session.scalar(
        select(SocialRender)
        .where(SocialRender.asset_id == asset.id)
        .where(SocialRender.status.in_(("queued", "running")))
        .limit(1)
    )
    if running is not None:
        # **A live row may be a dead job.** `run()` is a detached background task, so a deploy
        # or a crash takes it with the process — and `asyncio.CancelledError` is a
        # `BaseException`, so even the broad handler in `run` may not get to write a terminal
        # status. Without this, one interrupted render makes a post permanently unrenderable
        # from the console, recoverable only by hand-editing the database.
        if _is_stale(running):
            running.status = "cancelled"
            running.error = (
                "Abandoned — the process running it went away, most likely a deploy or a "
                "restart. Any clips it had already paid for are still on this row."
            )
            running.finished_at = dt.datetime.now(tz=dt.UTC)
            await session.commit()
        else:
            raise RascalError(
                ErrorCode.VALIDATION_FAILED,
                "A render for this post is already running. Wait for it or let it fail — "
                "starting a second would pay for the same seven clips twice.",
                field="status",
            )
    return shots


def _is_stale(render: SocialRender) -> bool:
    """Has this render been live longer than it could possibly legitimately take?

    The bound is generous on purpose — a clip is documented at up to six minutes and they run
    one after another — because cancelling a job that is merely slow would start a second one
    beside it and pay twice. Being an hour late is not the failure this is for; being gone is.
    """
    started = render.started_at or render.created_at
    if started is None:
        return False
    budget = dt.timedelta(seconds=_PER_CLIP_TIMEOUT.read or 600) * max(render.shots_total, 1)
    return dt.datetime.now(tz=dt.UTC) - started > budget + _STALE_GRACE


async def create(
    session: AsyncSession, settings: Settings, asset: SocialAsset, shots: list[dict[str, Any]]
) -> SocialRender:
    """The row the console polls. Written and committed before the work begins."""
    render = SocialRender(
        asset_id=asset.id,
        status="queued",
        provider=PROVIDER,
        model=settings.gemini_video_model,
        shots_total=len(shots),
    )
    session.add(render)
    await session.flush()
    await session.commit()
    return render


async def run(render_id: uuid.UUID) -> None:
    """The job. Owns its own session because the request that started it is long gone.

    Never raises: this runs detached, so an exception here would land in a log nobody is
    reading. Everything that goes wrong is written to the row as a sentence instead.
    """
    async with get_sessionmaker()() as session:
        render = await session.get(SocialRender, render_id)
        if render is None:
            return
        asset = await session.get(SocialAsset, render.asset_id)
        if asset is None:
            await _finish(session, render_id, "failed", error="The post was deleted mid-render.")
            return

        from rascal.config import get_settings

        settings = get_settings()
        shots = shots_of(asset)
        render.status = "running"
        render.started_at = dt.datetime.now(tz=dt.UTC)
        await session.commit()

        clips: list[bytes] = []
        try:
            async with httpx.AsyncClient(timeout=_PER_CLIP_TIMEOUT) as client:
                for index, shot in enumerate(shots):
                    blob = await gemini.render_shot(client, settings, shot)
                    clips.append(blob)
                    key = await to_thread.run_sync(
                        lambda data=blob: store(
                            settings, data, suffix=".mp4", content_type="video/mp4"
                        )
                    )
                    # Written per clip rather than at the end: a job killed on shot five must
                    # still leave behind what shots one to four already paid for.
                    render.clip_keys = [*render.clip_keys, key]
                    render.cost_cents += (
                        int(shot.get("seconds") or 0) * settings.gemini_video_cents_per_second
                    )
                    await session.commit()
                    log.info(
                        "social clip rendered",
                        extra={"render": str(render_id), "shot": index + 1, "of": len(shots)},
                    )

            joined = await to_thread.run_sync(stitch.concat, clips)
            key = await to_thread.run_sync(
                lambda: store(settings, joined, suffix=".mp4", content_type="video/mp4")
            )
            render.render_key = key
            # The post points at the finished film. The clips stay addressable on the render
            # row, which is the record of how it was made.
            asset.render_provider = PROVIDER
            asset.render_key = key
            await _finish(session, render_id, "succeeded")
        except asyncio.CancelledError:
            # **A `BaseException`, so the broad handler below never sees it.** This is what a
            # deploy looks like from inside the job: uvicorn cancels the task on SIGTERM. Write
            # a terminal status before re-raising, or the row stays `running` and `preflight`
            # refuses this post forever.
            await _finish(
                session,
                render_id,
                "cancelled",
                error="The process was shut down mid-render, most likely a deploy.",
            )
            raise
        except LookupError as error:
            # Narrow on purpose: `LookupError` is also `KeyError` and `IndexError`, either of
            # which can come out of the parsing below and would otherwise be reported to the
            # operator as a missing API key, sending them to fix something that is not wrong.
            message = (
                "GEMINI_API_KEY is no longer configured."
                if str(error) == "gemini_video"
                else _sentence(error)
            )
            await _finish(session, render_id, "failed", error=message)
        except (RuntimeError, httpx.HTTPError) as error:
            # `gemini` and `stitch` both raise `RuntimeError` carrying a sentence written for
            # a person; anything else is summarised rather than pasted.
            await _finish(session, render_id, "failed", error=_sentence(error))
        except Exception as error:
            # Detached: nothing above this catches, so a bare except is the net rather
            # than a shrug. It still ends as a sentence on the row.
            log.exception("social render failed", extra={"render": str(render_id)})
            await _finish(session, render_id, "failed", error=_sentence(error))


async def _finish(
    session: AsyncSession, render_id: uuid.UUID, status: str, *, error: str | None = None
) -> None:
    """Write the terminal status, and never raise while doing it.

    **This runs from inside `except` handlers, where the session may already be poisoned.** If
    the failure being handled *was* a failed `commit` — a dropped Neon connection between two
    ten-minute generations, a lock timeout, an integer overflow — SQLAlchemy has deactivated
    the transaction and every further write raises `PendingRollbackError` until somebody rolls
    back. Committing straight into that raises out of a detached background task, and the row
    is left `running` forever, which `preflight` then refuses on until somebody edits the
    database by hand. Verified by injecting all three failures against a real Postgres.

    So: roll back first, re-fetch the row the rollback just expired, and swallow whatever is
    left. A render whose terminal status could not be written is a log line, not an exception
    nobody is positioned to catch.
    """
    finished = dt.datetime.now(tz=dt.UTC)
    try:
        # The ordinary path, and it must stay ordinary: on success there are unflushed changes
        # here that matter — the render's key and the post pointed at it — and a pre-emptive
        # rollback would throw them away.
        render = await session.get(SocialRender, render_id)
        if render is None:
            return
        render.status = status
        render.error = error
        render.finished_at = finished
        await session.commit()
        return
    except Exception:
        log.warning(
            "the render's outcome did not commit; retrying after a rollback",
            extra={"render": str(render_id)},
        )

    # The session was poisoned — the failure being handled was itself a failed commit, so the
    # transaction is deactivated and every write raises until somebody rolls back. Recover and
    # write the terminal status alone; whatever else was pending is already lost.
    try:
        await session.rollback()
        render = await session.get(SocialRender, render_id)
        if render is None:
            return
        render.status = status
        render.error = error
        render.finished_at = finished
        await session.commit()
    except Exception:
        log.exception("could not record the render's outcome", extra={"render": str(render_id)})


def _sentence(error: BaseException) -> str:
    """One sentence, never a stack trace and never a URL that might carry a key.

    An httpx error stringifies to the URL it was fetching, and this service's Gemini requests
    put the key in a header rather than the query — but the rule is the same one `billing/base`
    keeps, and it is cheaper to hold than to re-derive.
    """
    if isinstance(error, stitch.StitchError | RuntimeError):
        return str(error)[:400]
    if isinstance(error, TimeoutError | httpx.TimeoutException):
        return "The provider did not answer in time."
    return f"{type(error).__name__} while rendering."


def as_dict(render: SocialRender) -> dict[str, object]:
    return {
        "id": str(render.id),
        "asset_id": str(render.asset_id),
        "status": render.status,
        "provider": render.provider,
        "model": render.model,
        "shots_total": render.shots_total,
        "shots_done": len(render.clip_keys),
        "render_key": render.render_key,
        "error": render.error,
        "cost_cents": render.cost_cents,
        "started_at": render.started_at.isoformat() if render.started_at else None,
        "finished_at": render.finished_at.isoformat() if render.finished_at else None,
        "created_at": render.created_at.isoformat(),
    }


async def latest_for(session: AsyncSession, asset_id: uuid.UUID) -> SocialRender | None:
    return await session.scalar(
        select(SocialRender)
        .where(SocialRender.asset_id == asset_id)
        .order_by(SocialRender.created_at.desc())
        .limit(1)
    )


__all__ = [
    "PROVIDER",
    "as_dict",
    "create",
    "estimate_cents",
    "latest_for",
    "preflight",
    "run",
    "shots_of",
]
