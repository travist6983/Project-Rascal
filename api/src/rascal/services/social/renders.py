"""Recording a scene graph into a video: what the server does with the bytes, and what it refuses.

**The shape of this module is the phase 120 change in miniature.** What stood here was a
detached background task: seven paid generations one after another, clips written to the bucket
as they landed, a `running` row for the console to poll, a staleness reaper for the job a deploy
killed mid-flight, and a session-poisoning recovery path for a commit that failed between two
ten-minute vendor calls. Every line of that machinery existed because the work took minutes and
cost money.

None of it is here now, because neither of those is true. The browser draws the cards and
records them; the server receives a WebM, re-encodes it, and stores it. That is a few seconds of
CPU on one machine, so it happens **inside the request** and the response is the finished row.
A poll loop for a ten-second job is machinery for its own sake.

**A render is still a row, and that has not changed.** It is one row per *attempt*: it outlives
an edit to the post, it records what was produced and what went wrong, and `SocialAsset.render_key`
holds only the artifact a post currently shows. What changed is the reasoning underneath —
clips-as-they-land and sequential generation are gone with the vendor. One row per attempt and
a cost recorded on failure as well as success stay.

**`cost_cents` is written and it is zero.** Zero is the finding this phase exists to produce.
A ledger that stops recording when the number becomes zero is a ledger that cannot show you it
went to zero, and the column is what a future generated-footage path would need back.

**Only terminal statuses are written now.** `queued`, `running` and `cancelled` stay in the
CHECK constraint and `uq_social_renders_one_live_per_asset` stays on the table, unwritten, for
the same reason `cost_cents` stays: they are the shape an asynchronous path needs, and removing
them would be a decision to reverse rather than a tidy-up. Nothing here can leave a row live,
which is what retires the reaper and the "already running" refusal along with it.
"""

from __future__ import annotations

import datetime as dt
import logging
import uuid
from typing import Any

from anyio import to_thread
from sqlalchemy import select
from sqlalchemy.ext.asyncio import AsyncSession

from rascal.config import Settings
from rascal.errors import ErrorCode, RascalError
from rascal.models import SocialAsset, SocialRender
from rascal.services.social import scenes as scene_graph
from rascal.services.social import transcode
from rascal.services.social.renderers import store

log = logging.getLogger("rascal.social.renders")

#: Not a vendor. The pixels come from `admin/static/cards.js` in the operator's own browser,
#: and this column has always meant "what made these bytes" rather than "who was paid".
PROVIDER = "canvas"

#: The renderer's version, in the column that used to hold a model id. **Bump it when the
#: templates change enough that an old render no longer matches a new one** — a render from
#: last month should still be able to say what drew it, and "cards.js as of some deploy" is not
#: an answer anybody can act on.
RENDERER_VERSION = "cards-v1"

#: What a canvas render costs. Zero, written down. See the module docstring.
COST_CENTS = 0

#: How far the finished film may fall short of the scene graph before it is refused, in seconds.
#:
#: **This is the server half of the backgrounded-tab guard, and it is the half that cannot be
#: bypassed.** `cards.js` refuses to record in a hidden tab because `requestAnimationFrame` does
#: not fire in one and the result is a file that is *silently short* — right container, right
#: codec, playable, missing however many seconds the tab spent behind something else. That guard
#: is the browser promising; this is the server checking, and it holds against a tab the browser
#: mis-detected, a `MediaRecorder` that dropped frames under load, and anything at all posting to
#: this route.
#:
#: A quarter of a second: a correct recording measures one frame long, by design — the extra
#: `requestAnimationFrame` after the final draw — and 33ms at 30fps is well inside this, while a
#: tab that lost even half a second is well outside it.
DURATION_TOLERANCE_SECONDS = 0.25


def scenes_of(asset: SocialAsset) -> list[dict[str, Any]]:
    return list((asset.treatment or {}).get("scenes") or [])


def preflight(asset: SocialAsset) -> list[dict[str, Any]]:
    """Every reason to refuse, checked before the browser is asked for bytes. Returns the scenes.

    Two of them, where there used to be four. No key, because there is no vendor; and no
    "already running", because nothing can be running — the work is inside the request.

    **Takes no `Settings` and no session.** It used to take a `Settings` it never read, left over
    from the version that checked `gemini_api_key` — an argument nobody passes for a reason is
    the kind of thing that gets a value threaded to it later to justify itself. Both remaining
    checks are properties of the asset and the machine, which is why `GET /social/studio` can
    answer the same two questions for the console before anything is pressed.
    """
    scenes = scenes_of(asset)
    if not scenes:
        raise RascalError(
            ErrorCode.VALIDATION_FAILED,
            "This post has no treatment to record. Write one in the Studio first.",
            field="treatment",
        )
    if not transcode.available():
        raise RascalError(
            ErrorCode.VALIDATION_FAILED,
            "ffmpeg is not installed on this machine, so a recording could be made and then "
            "not converted to the H.264 MP4 a platform will accept. Refusing before asking "
            "the browser to record.",
            field="ffmpeg",
        )
    return scenes


async def record(
    session: AsyncSession,
    settings: Settings,
    asset: SocialAsset,
    recording: bytes,
) -> SocialRender:
    """Transcode the browser's recording, store it, and write the row that says what happened.

    Returns the row either way. A transcode that fails is an attempt that happened and is
    recorded as one — the alternative is a button that reports an error and leaves no trace of
    having been pressed, which is how "it did nothing" and "it failed" become the same event.

    `RascalError` is raised on failure *as well as* writing the row, because the caller is a
    person waiting on a request: a 200 carrying a `failed` row would make every client check a
    field to find out whether the thing it asked for happened.
    """
    scenes = scenes_of(asset)
    started = dt.datetime.now(tz=dt.UTC)
    render = SocialRender(
        asset_id=asset.id,
        status="succeeded",
        provider=PROVIDER,
        model=RENDERER_VERSION,
        scene_count=len(scenes),
        cost_cents=COST_CENTS,
        started_at=started,
    )

    try:
        # **All three of these block, so all three go to a thread.** ffmpeg and ffprobe are
        # subprocesses and boto3 is not async; a `subprocess.run` or a socket write on the event
        # loop stalls every other request on the machine for as long as it takes. Same
        # discipline the card upload keeps.
        mp4 = await to_thread.run_sync(transcode.to_mp4, recording)
        _check_length(await to_thread.run_sync(transcode.probe, mp4), scenes)
        key = await to_thread.run_sync(
            lambda: store(settings, mp4, suffix=".mp4", content_type="video/mp4")
        )
    except Exception as error:
        # **Broad on purpose, and it is the docstring above that makes it necessary.** This
        # said `except transcode.TranscodeError`, and only one of the three calls in the `try`
        # raises that. The bucket write raises boto3's `ClientError` or a connection error and
        # went straight past this handler: the row was never added, the request rolled back, and
        # the operator got a 500 for a storage outage — from a function whose docstring promises
        # the attempt is recorded either way.
        render.status = "failed"
        render.error = _sentence(error)
        render.finished_at = dt.datetime.now(tz=dt.UTC)
        session.add(render)
        # **`commit`, not `flush`, and this line is the whole reason the failure path works.**
        # `get_session` rolls the request transaction back on any exception out of the handler,
        # so a flushed-but-uncommitted row is destroyed by the very error it exists to record —
        # and the route would then return a correct 422 having left no trace of the attempt.
        # Committing here puts the row beyond that rollback. Nothing else is pending: the route
        # commits before it reads the body, so this transaction holds one INSERT.
        #
        # Found by the test below rather than by reading, which is the point of asserting on
        # the row through a fresh session instead of on the response.
        await session.commit()
        # **No `refresh` here, and the success path's is not the same case.** `get_sessionmaker`
        # sets `expire_on_commit=False`, so `render.error` below is still the value set four
        # lines up, and nothing reads this row again — the function raises. A `SELECT` that can
        # add nothing is the one statement on this path that could fail, and failing would
        # replace a carefully worded 422 with a generic 500 *after* the row was committed.
        #
        # **Unexpected failures carry their traceback; expected ones do not.** A
        # `TranscodeError` is a sentence somebody wrote for this moment and a stack adds
        # nothing. An `AttributeError` out of `store` is a defect being reported to an operator
        # as a validation failure, and without `exc_info` the stack would exist nowhere at all.
        unexpected = not isinstance(error, transcode.TranscodeError)
        log.log(
            logging.ERROR if unexpected else logging.WARNING,
            "social render failed",
            extra={"asset": str(asset.id), "why": render.error},
            exc_info=error if unexpected else None,
        )
        # A 422 rather than a 500: every one of these is a sentence the operator can act on —
        # the wrong format, an ffmpeg that is not installed, a recording that came back empty,
        # or a bucket that would not take the bytes.
        raise RascalError(ErrorCode.VALIDATION_FAILED, render.error, field="recording") from error

    render.render_key = key
    render.finished_at = dt.datetime.now(tz=dt.UTC)
    # The post points at the finished film. Set on the row directly and never through
    # `studio.update_asset`, whose editable tuple deliberately excludes storage keys: a key is
    # written by the code that stored the bytes and must never be settable by a caller.
    asset.render_provider = PROVIDER
    asset.render_key = key
    session.add(render)
    await session.flush()
    await session.refresh(render)
    log.info(
        "social render stored",
        extra={"asset": str(asset.id), "scenes": len(scenes), "bytes": len(mp4)},
    )
    return render


def _check_length(probed: dict[str, object], scenes: list[dict[str, Any]]) -> None:
    """Refuse a film that is not as long as the graph says it should be.

    **Raises `TranscodeError` so it lands on the row like any other refusal** — the attempt
    happened, it produced bytes, and they were wrong; that is worth recording, and the operator
    gets the same 422-with-a-sentence they get for a body that was not a WebM.

    The duration is read from the *output*, which is the only place it is knowable:
    `MediaRecorder` writes an unknown duration into the WebM header, so the input reports `N/A`
    and the re-encode is what recomputes it from the frames.

    **An unreadable duration is not a refusal.** `probe` returns `{}` when ffprobe cannot answer
    and `None` when the container carries no duration; refusing on that would turn a diagnostic
    gap into a failed render, and the file may be perfectly good. A short file that this cannot
    measure is the residual risk, and it is smaller than the one this closes.
    """
    expected = scene_graph.total_ms(scenes) / 1000
    if not expected:
        return
    seen = probed.get("duration_seconds")
    if seen is None:
        log.warning("could not read a duration back from the render", extra={"expected": expected})
        return
    if expected - float(seen) > DURATION_TOLERANCE_SECONDS:
        raise transcode.TranscodeError(
            f"The recording is {float(seen):.1f}s and the treatment is {expected:.1f}s, so "
            "frames were lost — most likely the tab went to the background part way through. "
            "Nothing was stored. Keep the tab in front and record it again."
        )


def _sentence(error: BaseException) -> str:
    """One sentence for the row, never a stack trace and never a URL that might carry a key.

    `TranscodeError` already carries a sentence written for a person, so it passes through.
    Anything else is summarised by type: a boto3 `ClientError` stringifies to the whole request
    context including the bucket and the endpoint, and `errors.py` forbids putting that on a
    row for the same reason it forbids a raw SQL error.

    **"while producing the file", not "while storing it."** The `try` this serves covers the
    encode as well as the bucket write — an `OSError` writing the temp file lands here too — so
    naming the storage step would put a confidently wrong location on a row somebody reads at
    2am.
    """
    if isinstance(error, transcode.TranscodeError):
        return str(error)[:400]
    return f"{type(error).__name__} while producing the file."


def as_dict(render: SocialRender) -> dict[str, object]:
    return {
        "id": str(render.id),
        "asset_id": str(render.asset_id),
        "status": render.status,
        "provider": render.provider,
        "model": render.model,
        "scene_count": render.scene_count,
        "render_key": render.render_key,
        "error": render.error,
        # Zero, and reported rather than omitted. See the module docstring.
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


async def get(session: AsyncSession, render_id: uuid.UUID) -> SocialRender:
    render = await session.get(SocialRender, render_id)
    if render is None:
        raise RascalError(ErrorCode.NOT_FOUND, "No such render.")
    return render


__all__ = [
    "COST_CENTS",
    "PROVIDER",
    "RENDERER_VERSION",
    "as_dict",
    "get",
    "latest_for",
    "preflight",
    "record",
    "scenes_of",
]
