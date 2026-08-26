"""Deleting an account, seven days after somebody asks.

Settled in `decisions.md` open item 14 on Aug 17, 2026, and the two answers that shape every
line below:

**The account always; the archive only when no other guardian remains.** A shared archive is not
one parent's to destroy, and the other parent did not ask for anything. Leaving a household
therefore revokes your access and removes your credentials, and the children stay exactly where
they are — until the last guardian goes, and then the archive goes with them. This is also open
item 13's answer, arriving from the other direction.

**Seven days, signed out immediately, and any sign-in cancels it.** The cancel is D3's precedent
rather than a new rule: somebody who signs back in has changed their mind. Revoking every refresh
token at request time is what makes that safe to hook where it is hooked — after revocation, the
only way to reach `touch_last_sign_in` again is a deliberate sign-in.

---

**This is the one place in the service that hard-deletes user data, and that is a deliberate
exception to `CLAUDE.md` rule 5.** Soft deletes exist so a client can learn that a row went away;
there is no client left to tell, and a `deleted_at` on an erasure request would be the service
keeping exactly what it was asked to stop keeping. The rule is right everywhere else and wrong
here, which is worth stating rather than leaving somebody to wonder whether it was forgotten.

**What is never deleted:** another guardian's archive, and any child somebody else still guards.
The tests assert what survives, not only what goes — a deletion test that only checks rows are
gone passes just as happily while the feature destroys the wrong household.
"""

from __future__ import annotations

import datetime as dt
import logging
import uuid
from dataclasses import dataclass

from sqlalchemy import delete, select
from sqlalchemy.ext.asyncio import AsyncSession
from sqlalchemy.orm import aliased

from rascal.config import Settings
from rascal.errors import ErrorCode, RascalError
from rascal.models import (
    Assignment,
    Child,
    Credential,
    DeletionRequest,
    Entry,
    EntryTag,
    Guardian,
    GuardianInvite,
    Media,
    NotificationSend,
    PromptSuppression,
    RefreshToken,
    Tag,
    User,
)
from rascal.services import apple_revocation, s3

log = logging.getLogger("rascal.deletion")

#: How long between asking and it happening. Settled by the owner, Aug 17, 2026.
#:
#: Stored on the row at request time rather than read here at execution time, so a request made
#: under this policy runs on the terms it was made under however this constant moves later.
GRACE_PERIOD = dt.timedelta(days=7)


async def pending_for(session: AsyncSession, user_id: uuid.UUID) -> DeletionRequest | None:
    return await session.scalar(
        select(DeletionRequest).where(
            DeletionRequest.user_id == user_id,
            DeletionRequest.cancelled_at.is_(None),
        )
    )


async def request_deletion(
    session: AsyncSession, user: User, *, now: dt.datetime | None = None
) -> DeletionRequest:
    """Start the clock, and sign them out of everywhere.

    **Idempotent.** Asking twice returns the first request rather than restarting the clock —
    a second tap must not quietly buy another seven days, and it must not create a second row
    the job would run twice.

    Every refresh token is revoked here, which does two things: it honours "signed out
    immediately", and it makes `cancel_on_sign_in` safe to hook into `touch_last_sign_in`,
    because after this only a deliberate sign-in can reach that function.
    """
    now = now or dt.datetime.now(tz=dt.UTC)

    existing = await pending_for(session, user.id)
    if existing is not None:
        return existing

    # **Both timestamps from one clock.** `requested_at` would otherwise default to the
    # database's `now()` while `execute_after` came from Python's, leaving a row whose own two
    # dates disagree about when the grace period started — harmless in effect and confusing in
    # every log line and support conversation that ever reads it.
    request = DeletionRequest(user_id=user.id, requested_at=now, execute_after=now + GRACE_PERIOD)
    session.add(request)
    await session.execute(delete(RefreshToken).where(RefreshToken.user_id == user.id))
    await session.flush()
    log.info(
        "deletion requested",
        extra={"user_id": str(user.id), "execute_after": request.execute_after.isoformat()},
    )
    return request


async def cancel_deletion(
    session: AsyncSession, user_id: uuid.UUID, *, now: dt.datetime | None = None
) -> DeletionRequest | None:
    """Withdraw a pending request. Idempotent; returns None when there was nothing to cancel."""
    now = now or dt.datetime.now(tz=dt.UTC)
    request = await pending_for(session, user_id)
    if request is None:
        return None
    request.cancelled_at = now
    await session.flush()
    log.info("deletion cancelled", extra={"user_id": str(user_id)})
    return request


async def cancel_on_sign_in(
    session: AsyncSession, user_id: uuid.UUID, *, now: dt.datetime | None = None
) -> None:
    """D3's rule, applied here: signing in cancels an outstanding deletion outright.

    Called from `auth.touch_last_sign_in`, which is the one function every path that proves the
    app ran on a device somebody has already calls — its own docstring makes that argument for
    the inactivity clock, and it is the same set of paths this needs. Hooking it there means a
    new sign-in route cannot forget to cancel.

    **Safe there only because `request_deletion` revokes every refresh token.** Without that, a
    phone in a drawer rotating its token in the background would cancel a deletion its owner
    still wanted.
    """
    await cancel_deletion(session, user_id, now=now)


# --- The destructive half --------------------------------------------------------------------


async def _sole_guardian_children(session: AsyncSession, user_id: uuid.UUID) -> list[uuid.UUID]:
    """Children this user guards that **nobody else does.**

    The whole cascade rests on this query, so it is written to be read: for each child the user
    has a live `guardians` row for, count the live rows belonging to anybody else. Zero means
    the archive leaves with them.

    A revoked guardian does not count as somebody else — a revoked row is not access, and
    treating it as a reason to keep an archive would strand it behind nobody.
    """
    # **An alias, and `NOT EXISTS` rather than `count() == 0`.** The outer query already joins
    # `guardians`, so an unaliased inner reference correlates to *that* row and SQLAlchemy
    # drops the subquery's FROM entirely — it raises rather than silently returning nonsense,
    # which is the one mercy in this class of bug. `NOT EXISTS` also stops at the first other
    # guardian instead of counting all of them.
    other = aliased(Guardian)
    someone_else_guards = (
        select(other.user_id)
        .where(
            other.child_id == Child.id,
            other.user_id != user_id,
            other.revoked_at.is_(None),
        )
        .correlate(Child)
        .exists()
    )
    rows = await session.execute(
        select(Child.id)
        .join(Guardian, Guardian.child_id == Child.id)
        .where(
            Guardian.user_id == user_id,
            Guardian.revoked_at.is_(None),
            ~someone_else_guards,
        )
    )
    return list(rows.scalars().all())


async def _media_keys(session: AsyncSession, child_ids: list[uuid.UUID]) -> list[str]:
    """Every object key belonging to these children — media, thumbnails, and avatars.

    Read **before** the rows go. Deleting the rows first would leave the bytes in the bucket
    with nothing left pointing at them — an orphan nobody could find to remove, which is the
    worst possible outcome for a feature whose entire promise is that the data is gone.

    **`children.avatar_key` is collected here, and was not until phase 127.** It is not reached
    through `entries`, so the media join below never saw it, and a child's face survived their
    own erasure in the bucket indefinitely. `media.thumb_key` is in the same select for the same
    reason; it is NULL for every row today, so that half is latent rather than live.

    **This removes the *current* avatar, not every avatar ever set.** `build_avatar_key` mints a
    fresh UUID per upload, so a replaced avatar is already an orphan that no column points at
    and no query here could find. Clearing the whole `children/{id}/avatar/` prefix would need a
    listing call that `s3.py` does not have; that is a real remaining gap and it is named in the
    phase 127 PR rather than papered over.
    """
    if not child_ids:
        return []
    media_rows = await session.execute(
        select(Media.s3_key, Media.thumb_key)
        .join(Entry, Entry.id == Media.entry_id)
        .where(Entry.child_id.in_(child_ids))
    )
    keys = [key for row in media_rows.all() for key in row if key]

    avatar_rows = await session.execute(select(Child.avatar_key).where(Child.id.in_(child_ids)))
    keys.extend(key for key in avatar_rows.scalars().all() if key)
    return keys


async def _incomplete_uploads(
    session: AsyncSession, child_ids: list[uuid.UUID]
) -> list[tuple[str, str]]:
    """Multipart uploads that were started and never finished, as `(key, upload_id)`.

    **Parts are not objects, so `_media_keys` cannot reach them.** A video a parent started
    uploading when the app was killed leaves `media.s3_upload_id` set and no object at
    `s3_key` — `delete_objects` against that key succeeds and removes nothing, and after the
    erasure the `media` row that named the upload has cascaded away, so the parts are
    unreachable bytes of a child's video that outlive the request to destroy them.

    **The `s3_upload_id IS NOT NULL` filter is an efficiency measure, not a safety interlock**,
    and an earlier draft of this docstring said the opposite — that aborting a completed upload
    "would destroy a real photograph". That is false, and `s3.abort_multipart_uploads` says so
    three files away: an upload id stops existing when the upload completes, so aborting one is a
    `NoSuchUpload` and a no-op. **The correction matters because the false version reads as a
    reason not to widen this query**, and widening it is exactly what a future reader might need
    to do. It is also what makes the post-commit ordering below safe: `complete_upload` commits
    before it nulls the id (`services/media.py:193-195`), so a crash in that window leaves the
    column set on a finished object — harmless, precisely because the abort does nothing.

    Same read-before-the-rows-go rule as everything else here.
    """
    if not child_ids:
        return []
    rows = await session.execute(
        select(Media.s3_key, Media.s3_upload_id)
        .join(Entry, Entry.id == Media.entry_id)
        .where(Entry.child_id.in_(child_ids), Media.s3_upload_id.is_not(None))
    )
    return [(key, upload_id) for key, upload_id in rows.all() if key and upload_id]


async def _apple_credentials(
    session: AsyncSession, user_id: uuid.UUID
) -> list[tuple[uuid.UUID, str]]:
    """The Apple credentials that can still be revoked, as `(credential id, refresh token)`.

    Read **before** the rows go, for the same reason the object keys are: `credentials` is
    `ON DELETE CASCADE` from `users`, so after the user delete there is nothing left to ask.

    A credential with no stored token is skipped rather than reported. That is the state of
    every Apple credential written before phase 127 and of every one written since on a
    deployment with no Sign in with Apple key — there is nothing to send Apple, and a warning
    per erasure would be noise about a gap `docs/blocked.md` §24 already owns.
    """
    rows = await session.execute(
        select(Credential.id, Credential.apple_refresh_token).where(
            Credential.user_id == user_id,
            Credential.provider == "apple",
            Credential.apple_refresh_token.is_not(None),
        )
    )
    return [(cid, token) for cid, token in rows.all() if token]


@dataclass(frozen=True)
class Erasure:
    """What one deletion removed from the database, and what is still owed outside it.

    The two lists exist because neither can be done inside the transaction. Destroying bytes or
    calling a vendor before the commit means a rollback leaves the database describing a world
    that no longer exists — see `execute_deletion`.
    """

    children: int
    #: Object keys to remove once the rows are committed gone.
    object_keys: list[str]
    #: `(key, upload_id)` for uploads that were never completed, whose parts must be aborted.
    incomplete_uploads: list[tuple[str, str]]
    #: `(credential id, refresh token)` for each Apple sign-in still owed a revocation.
    apple_credentials: list[tuple[uuid.UUID, str]]

    @property
    def counts(self) -> dict[str, int]:
        return {"children": self.children, "objects": len(self.object_keys)}


async def execute_deletion(
    session: AsyncSession,
    request: DeletionRequest,
    settings: Settings,
    *,
    now: dt.datetime | None = None,
) -> Erasure:
    """Carry out the database half of one request. **Commits nothing and touches no network.**

    **Order matters and is not cosmetic.** Object keys and Apple credentials are read first,
    because the rows are what point at them and both cascade away with the user. Then the
    children that leave with this user, then the user's own rows, then the user.

    **What this function deliberately no longer does is delete the objects.** It used to, right
    here, under a comment claiming the database work had succeeded — but the only `commit()` on
    the path is in `run_due_deletions`, *after* this returns, so the bytes were being destroyed
    while the transaction that removed their rows could still roll back. Between those two
    points, surviving `media` rows pointed at objects that were gone and `presign_get` would
    mint URLs that 404. Both the bucket and Apple are now the caller's business, once the commit
    has actually held. Corrected in phase 127; the ordering the old docstring described is the
    ordering that now happens.
    """
    now = now or dt.datetime.now(tz=dt.UTC)
    user_id = request.user_id

    departing = await _sole_guardian_children(session, user_id)
    keys = await _media_keys(session, departing)
    uploads = await _incomplete_uploads(session, departing)
    apple = await _apple_credentials(session, user_id)

    if departing:
        # `entries` and `assignments` cascade from `children` in the schema; `media` and
        # `entry_tags` cascade from `entries`. These are stated rather than relied upon for the
        # tables whose FK is not `ON DELETE CASCADE`, and the child delete carries the rest.
        await session.execute(
            delete(NotificationSend).where(NotificationSend.child_id.in_(departing))
        )
        await session.execute(
            delete(PromptSuppression).where(PromptSuppression.child_id.in_(departing))
        )
        await session.execute(
            delete(EntryTag).where(
                EntryTag.tag_id.in_(select(Tag.id).where(Tag.child_id.in_(departing)))
            )
        )
        await session.execute(delete(Tag).where(Tag.child_id.in_(departing)))
        await session.execute(delete(Assignment).where(Assignment.child_id.in_(departing)))
        await session.execute(delete(Child).where(Child.id.in_(departing)))

    # Their access to everything else — the children somebody *else* still guards. Those
    # archives are untouched; this is the row that made them reachable.
    await session.execute(delete(Guardian).where(Guardian.user_id == user_id))
    await session.execute(
        delete(GuardianInvite).where(GuardianInvite.invited_by_user_id == user_id)
    )

    # `credentials`, `devices`, `refresh_tokens`, `idempotency_keys` and the request row itself
    # are all `ON DELETE CASCADE` from `users`, so the user delete carries them.
    await session.execute(delete(User).where(User.id == user_id))
    await session.flush()

    log.info("deletion executed", extra={"children": len(departing), "objects": len(keys)})
    return Erasure(
        children=len(departing),
        object_keys=keys,
        incomplete_uploads=uploads,
        apple_credentials=apple,
    )


async def run_due_deletions(
    session: AsyncSession, settings: Settings, *, now: dt.datetime | None = None
) -> dict[str, int]:
    """Every request whose grace period has elapsed. The job's entry point.

    **One transaction per request**, committed as it goes: a batch that rolled back on the tenth
    account would undo nine deletions somebody had already been told were done, and "we deleted
    your account" is not a thing to take back.
    """
    now = now or dt.datetime.now(tz=dt.UTC)
    # **Ids, not instances.** Both a commit and a rollback expire everything the session is
    # holding, so a list of `DeletionRequest` objects carried across the loop goes stale on the
    # first iteration: reading `request.user_id` on the second is then a lazy load on an async
    # session, which raises `MissingGreenlet` rather than reloading. Each row is re-read inside
    # the loop, on the transaction that is about to act on it.
    due = list(
        (
            await session.execute(
                select(DeletionRequest.id).where(
                    DeletionRequest.cancelled_at.is_(None),
                    DeletionRequest.execute_after <= now,
                )
            )
        )
        .scalars()
        .all()
    )

    totals = {"accounts": 0, "children": 0, "objects": 0}
    for request_id in due:
        try:
            # **`FOR UPDATE`, not a plain read.** An unlocked `SELECT` under READ COMMITTED
            # leaves a window: `cancel_on_sign_in` can commit `cancelled_at` after this row is
            # read and before the six deletes below commit, and the cascade takes the request
            # row away regardless — so a parent who was told their cancellation worked would
            # lose the archive anyway. The window is narrow (a cancel needs a sign-in, and the
            # only way to reach one is a deliberate sign-in) and the lock closes it. Same idiom
            # as `guardians.lock_household`.
            request = await session.scalar(
                select(DeletionRequest).where(DeletionRequest.id == request_id).with_for_update()
            )
            if request is None or request.cancelled_at is not None:
                # Cancelled, or already carried out, between the select above and its turn.
                # Re-reading is what makes this observable at all; the old code held an
                # instance from before the run and could not have seen it.
                continue
            erasure = await execute_deletion(session, request, settings, now=now)
            await session.commit()
        except Exception:
            # **One account's failure must not cost the rest of the run.** Without this, a
            # deadlock or a bad row on the tenth account discarded the totals for the nine
            # already committed and left every later request unattempted until somebody
            # noticed. The rollback is not optional: after a database error the session raises
            # `PendingRollbackError` on every subsequent statement, so a bare `continue` would
            # turn one failure into all of them.
            log.exception(
                "deletion failed; the rest of the run continues",
                extra={"deletion_request_id": str(request_id)},
            )
            await session.rollback()
            continue

        totals["accounts"] += 1
        totals["children"] += erasure.counts["children"]
        totals["objects"] += erasure.counts["objects"]

        # **Everything past this line happens after the commit, and none of it can be undone.**
        # That is the point: the rows are gone for certain before a byte is destroyed or a
        # vendor is told anything. Each step is independently non-fatal, because the account is
        # already deleted and there is nothing left to abort.
        await _revoke_apple(erasure.apple_credentials, settings)
        try:
            await s3.delete_objects(erasure.object_keys, settings)
            # After the deletes and in the same guard: an upload that completed between the
            # read and here is already an object the line above removed, and one that did not
            # still has parts to discard. `abort_multipart_uploads` treats an unknown upload as
            # success, so doing both is safe in either order — this one is second because it is
            # the rarer case.
            await s3.abort_multipart_uploads(erasure.incomplete_uploads, settings)
        except Exception:
            # The rows are already committed gone, so raising here would abort the *rest of the
            # run* over bytes that are now unreachable anyway. Logged at ERROR with the keys,
            # which is the only thing that makes them findable — nothing else points at them.
            log.exception(
                "objects survived a completed deletion and must be removed by hand",
                extra={"keys": erasure.object_keys},
            )

    if due:
        log.info("deletion run", extra=totals)
    return totals


async def _revoke_apple(credentials: list[tuple[uuid.UUID, str]], settings: Settings) -> None:
    """Tell Apple every Sign in with Apple link on this account is over.

    **After the commit, and never able to stop the deletion.** Guideline 5.1.1(v) wants the
    revocation call made; it does not want a vendor's 500 to mean somebody who asked to be
    erased still has an archive tomorrow. `apple_revocation.revoke` returns a bool and raises
    nothing, and this adds a belt around it because "never raises" is a promise in a docstring
    and the erasure is already irreversible by the time we get here.
    """
    for credential_id, token in credentials:
        try:
            await apple_revocation.revoke(token, settings, credential_id=credential_id)
        except Exception:  # pragma: no cover — `revoke` is written not to raise
            log.exception(
                "apple revocation raised; the account is still deleted",
                extra={"credential_id": str(credential_id)},
            )


def not_pending() -> RascalError:
    return RascalError(ErrorCode.NOT_FOUND, "No deletion is scheduled for this account.")
