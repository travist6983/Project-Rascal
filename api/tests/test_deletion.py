"""Deleting an account: the grace period, the cancel, and what must not go with it.

**The tests that matter here are the ones asserting what survives.** A deletion suite that only
checks rows are gone passes just as happily while the feature destroys the wrong household — and
this is the one operation in the service with no undo.
"""

from __future__ import annotations

import datetime as dt
import uuid

import pytest
import sqlalchemy as sa
from botocore.exceptions import ClientError, ReadTimeoutError
from httpx import AsyncClient
from sqlalchemy.exc import IntegrityError
from sqlalchemy.ext.asyncio import AsyncSession

from factories import grant, make_child, make_family, make_prompt, make_user
from helpers import auth_headers
from rascal.config import get_settings
from rascal.models import (
    Child,
    Credential,
    DeletionRequest,
    Entry,
    Guardian,
    Media,
    RefreshToken,
    User,
)
from rascal.services import apple_revocation, deletion, s3


@pytest.fixture
def no_object_store(monkeypatch):
    """Capture the keys a deletion would remove instead of reaching Tigris."""
    removed: list[str] = []

    async def _delete(keys, settings):
        removed.extend(keys)
        return len(keys)

    monkeypatch.setattr(s3, "delete_objects", _delete)
    return removed


async def _entry(session: AsyncSession, child: Child, author: User, body: str) -> Entry:
    entry = Entry(
        id=uuid.uuid4(),
        child_id=child.id,
        author_id=author.id,
        occurred_at=dt.datetime(2026, 8, 4, tzinfo=dt.UTC),
        child_age_months=50,
        entry_type="text",
        body=body,
    )
    session.add(entry)
    await session.flush()
    return entry


# --- Asking, and changing your mind ----------------------------------------------------------


async def test_requesting_starts_a_seven_day_clock(
    client: AsyncClient, session: AsyncSession
) -> None:
    user = await make_user(session)
    await session.commit()

    response = await client.post("/v1/me/deletion", headers=auth_headers(user))

    assert response.status_code == 202
    body = response.json()
    gap = dt.datetime.fromisoformat(body["execute_after"]) - dt.datetime.fromisoformat(
        body["requested_at"]
    )
    assert gap == dt.timedelta(days=7)


async def test_asking_twice_does_not_buy_another_seven_days(
    client: AsyncClient, session: AsyncSession
) -> None:
    """A second tap must not restart the clock, and must not create a second row to run twice."""
    user = await make_user(session)
    await session.commit()

    first = (await client.post("/v1/me/deletion", headers=auth_headers(user))).json()
    second = (await client.post("/v1/me/deletion", headers=auth_headers(user))).json()

    assert first == second
    rows = await session.scalar(sa.select(sa.func.count()).select_from(DeletionRequest))
    assert rows == 1


async def test_requesting_signs_them_out_of_every_device(
    client: AsyncClient, session: AsyncSession
) -> None:
    """Immediate sign-out is half the promise — and it is what makes cancel-on-sign-in safe."""
    user = await make_user(session)
    session.add(
        RefreshToken(
            user_id=user.id,
            token_hash="a" * 64,
            expires_at=dt.datetime.now(tz=dt.UTC) + dt.timedelta(days=30),
        )
    )
    await session.commit()

    await client.post("/v1/me/deletion", headers=auth_headers(user))

    left = await session.scalar(
        sa.select(sa.func.count()).select_from(RefreshToken).where(RefreshToken.user_id == user.id)
    )
    assert left == 0


async def test_cancelling_is_idempotent_and_never_reports_a_problem(
    client: AsyncClient, session: AsyncSession
) -> None:
    """A 404 here would alarm somebody who has already been reassured, about nothing."""
    user = await make_user(session)
    await session.commit()

    await client.post("/v1/me/deletion", headers=auth_headers(user))
    first = await client.delete("/v1/me/deletion", headers=auth_headers(user))
    second = await client.delete("/v1/me/deletion", headers=auth_headers(user))

    assert first.status_code == 204
    assert second.status_code == 204


async def test_signing_in_cancels_an_outstanding_deletion(session: AsyncSession) -> None:
    """D3's rule: somebody who signs back in has changed their mind."""
    from rascal.services.auth import touch_last_sign_in

    user = await make_user(session)
    await deletion.request_deletion(session, user)
    await session.commit()
    assert await deletion.pending_for(session, user.id) is not None

    await touch_last_sign_in(session, user.id)
    await session.commit()

    assert await deletion.pending_for(session, user.id) is None


async def test_a_cancelled_request_does_not_block_asking_again(
    session: AsyncSession,
) -> None:
    """Ask, change your mind, ask again a year later — a state a parent can genuinely reach."""
    user = await make_user(session)
    await deletion.request_deletion(session, user)
    await deletion.cancel_deletion(session, user.id)
    await deletion.request_deletion(session, user)
    await session.commit()

    total = await session.scalar(sa.select(sa.func.count()).select_from(DeletionRequest))
    pending = await deletion.pending_for(session, user.id)
    assert total == 2
    assert pending is not None


async def test_two_pending_requests_for_one_user_are_refused_by_the_schema(
    session: AsyncSession,
) -> None:
    """The partial unique index, not the service, is what makes this impossible."""
    user = await make_user(session)
    await session.commit()
    now = dt.datetime.now(tz=dt.UTC)
    session.add_all(
        [
            DeletionRequest(user_id=user.id, execute_after=now),
            DeletionRequest(user_id=user.id, execute_after=now),
        ]
    )
    with pytest.raises(IntegrityError) as caught:
        await session.commit()
    assert "uq_deletion_requests_pending" in str(caught.value)


# --- The clock -------------------------------------------------------------------------------


async def test_nothing_happens_before_the_grace_period_elapses(
    session: AsyncSession, no_object_store
) -> None:
    user = await make_user(session)
    child = await make_child(session, parent=user)
    await deletion.request_deletion(session, user)
    await session.commit()

    totals = await deletion.run_due_deletions(session, get_settings())

    assert totals["accounts"] == 0
    assert await session.get(User, user.id) is not None
    assert await session.get(Child, child.id) is not None


# --- What goes, and what must not -------------------------------------------------------------


async def test_a_sole_guardians_archive_goes_with_them(
    session: AsyncSession, no_object_store
) -> None:
    user = await make_user(session)
    child = await make_child(session, parent=user)
    prompt = await make_prompt(session)
    entry = await _entry(session, child, user, "his laugh")
    session.add(
        Media(
            id=uuid.uuid4(),
            entry_id=entry.id,
            s3_key="children/x/photo.jpg",
            kind="photo",
            bytes=1024,
            upload_status="complete",
        )
    )
    await deletion.request_deletion(session, user)
    await session.commit()

    totals = await deletion.run_due_deletions(
        session, get_settings(), now=dt.datetime.now(tz=dt.UTC) + dt.timedelta(days=8)
    )

    assert totals == {"accounts": 1, "children": 1, "objects": 1}
    assert await session.get(User, user.id) is None
    assert await session.get(Child, child.id) is None
    # The bytes go too. A row deleted while the object stays is the failure this feature exists
    # to avoid, and it is invisible from the database.
    assert no_object_store == ["children/x/photo.jpg"]
    assert prompt is not None  # the library is content, not user data


async def test_the_other_parents_archive_survives_untouched(
    session: AsyncSession, no_object_store
) -> None:
    """**The most important test in this file.**

    One parent leaving must not destroy a household somebody else is still in. A suite that
    only asserted the leaver's rows were gone would pass while this was catastrophically wrong.
    """
    family = await make_family(session, tier="subscribed")
    leaving = await make_user(session, family=family, display_name="Leaving")
    staying = await make_user(session, family=family, display_name="Staying")
    child = await make_child(session, parent=leaving)
    await grant(session, staying, child)
    theirs = await _entry(session, child, leaving, "written by the one who left")
    session.add(
        Media(
            id=uuid.uuid4(),
            entry_id=theirs.id,
            s3_key="children/x/keepme.jpg",
            kind="photo",
            bytes=1024,
            upload_status="complete",
        )
    )
    await deletion.request_deletion(session, leaving)
    await session.commit()

    totals = await deletion.run_due_deletions(
        session, get_settings(), now=dt.datetime.now(tz=dt.UTC) + dt.timedelta(days=8)
    )

    # **Every assertion below is an explicit SELECT, not an identity-map read.** `author_id`
    # was set to null by the database rather than by this session, so a cached instance would
    # answer with what we remembered instead of what happened — which is the exact failure mode
    # a deletion test cannot afford.
    async def _scalar(stmt):
        return await session.scalar(stmt)

    # The person is gone.
    assert await _scalar(sa.select(User.id).where(User.id == leaving.id)) is None
    assert totals["children"] == 0
    # The child, the other parent, the entry and the bytes are not.
    assert await _scalar(sa.select(Child.id).where(Child.id == child.id)) is not None
    assert await _scalar(sa.select(User.id).where(User.id == staying.id)) is not None
    assert no_object_store == []
    assert (
        await _scalar(sa.select(Entry.body).where(Entry.id == theirs.id))
        == "written by the one who left"
    )
    # **The attribution goes null rather than being reassigned.** Null is "somebody no longer
    # here", which is true; naming the remaining parent would be a false claim about who wrote
    # a sentence in an archive whose whole worth is that it is accurate.
    assert await _scalar(sa.select(Entry.author_id).where(Entry.id == theirs.id)) is None
    # And the guardian row that made it reachable to the leaver is gone.
    left = await session.scalar(
        sa.select(sa.func.count()).select_from(Guardian).where(Guardian.user_id == leaving.id)
    )
    assert left == 0


async def test_a_revoked_guardian_does_not_keep_an_archive_alive(
    session: AsyncSession, no_object_store
) -> None:
    """A revoked row is not access. Treating it as somebody else would strand the archive."""
    family = await make_family(session, tier="subscribed")
    leaving = await make_user(session, family=family)
    revoked = await make_user(session, family=family, display_name="Revoked")
    child = await make_child(session, parent=leaving)
    await grant(session, revoked, child, revoked=True)
    await deletion.request_deletion(session, leaving)
    await session.commit()

    await deletion.run_due_deletions(
        session, get_settings(), now=dt.datetime.now(tz=dt.UTC) + dt.timedelta(days=8)
    )

    assert await session.get(Child, child.id) is None


async def test_a_cancelled_request_is_never_executed(
    session: AsyncSession, no_object_store
) -> None:
    user = await make_user(session)
    child = await make_child(session, parent=user)
    await deletion.request_deletion(session, user)
    await deletion.cancel_deletion(session, user.id)
    await session.commit()

    totals = await deletion.run_due_deletions(
        session, get_settings(), now=dt.datetime.now(tz=dt.UTC) + dt.timedelta(days=30)
    )

    assert totals["accounts"] == 0
    assert await session.get(User, user.id) is not None
    assert await session.get(Child, child.id) is not None


# --- What the erasure still owes Apple and the bucket, phase 127 -----------------------------
#
# Everything below runs *after* the commit in `run_due_deletions`, which is the ordering fix
# phase 127 made: the rows are certainly gone before a byte is destroyed or a vendor is told
# anything. These tests are mostly about failure, because a revocation that works is one line
# and a revocation that fails without abandoning the person who asked to be deleted is the
# feature.


@pytest.fixture
def apple_calls(monkeypatch):
    """Capture the revocations a deletion would send instead of reaching Apple."""
    calls: list[uuid.UUID | None] = []

    async def _revoke(token, settings, *, credential_id=None, **kwargs):
        calls.append(credential_id)
        return True

    monkeypatch.setattr(apple_revocation, "revoke", _revoke)
    return calls


async def _apple_credential(session: AsyncSession, user: User, token: str | None) -> Credential:
    credential = Credential(
        user_id=user.id,
        provider="apple",
        subject_id=f"001.{uuid.uuid4().hex[:8]}",
        apple_refresh_token=token,
    )
    session.add(credential)
    await session.flush()
    return credential


async def _erase(session: AsyncSession, user: User) -> dict[str, int]:
    await deletion.request_deletion(session, user)
    await session.commit()
    return await deletion.run_due_deletions(
        session, get_settings(), now=dt.datetime.now(tz=dt.UTC) + dt.timedelta(days=8)
    )


async def test_deleting_an_account_revokes_its_sign_in_with_apple(
    session: AsyncSession, no_object_store, apple_calls
) -> None:
    """Guideline 5.1.1(v): the link Apple knows about has to end with the account."""
    user = await make_user(session)
    credential = await _apple_credential(session, user, "r3fresh")

    await _erase(session, user)

    assert apple_calls == [credential.id]
    assert await session.get(User, user.id) is None


async def test_a_credential_with_no_stored_token_is_skipped_not_attempted(
    session: AsyncSession, no_object_store, apple_calls
) -> None:
    """Every Apple credential written before phase 127 is in this state, and there is nothing
    to send Apple. It is a gap `docs/blocked.md` §24 owns, not a per-erasure warning."""
    user = await make_user(session)
    await _apple_credential(session, user, None)

    await _erase(session, user)

    assert apple_calls == []
    assert await session.get(User, user.id) is None


async def test_a_failed_revocation_does_not_abort_the_deletion(
    session: AsyncSession, no_object_store, monkeypatch
) -> None:
    """**The assertion this whole path exists for.** A user who asked to be deleted and was
    not, because Apple returned a 500, is a compliance failure — so Apple's answer may not
    decide whether the archive is destroyed."""
    user = await make_user(session)
    child = await make_child(session, parent=user)
    await _apple_credential(session, user, "r3fresh")

    async def _fails(token, settings, *, credential_id=None, **kwargs):
        return False

    monkeypatch.setattr(apple_revocation, "revoke", _fails)

    totals = await _erase(session, user)

    assert totals["accounts"] == 1
    assert await session.get(User, user.id) is None
    assert await session.get(Child, child.id) is None


async def test_a_revocation_that_raises_does_not_abort_the_deletion(
    session: AsyncSession, no_object_store, monkeypatch
) -> None:
    """`revoke` is written not to raise. This asserts the belt around it anyway, because by
    the time it is called the erasure is already irreversible."""
    user = await make_user(session)
    await _apple_credential(session, user, "r3fresh")

    async def _explodes(token, settings, *, credential_id=None, **kwargs):
        raise RuntimeError("apple fell over")

    monkeypatch.setattr(apple_revocation, "revoke", _explodes)

    totals = await _erase(session, user)

    assert totals["accounts"] == 1
    assert await session.get(User, user.id) is None


async def test_a_childs_avatar_goes_with_them(
    session: AsyncSession, no_object_store, apple_calls
) -> None:
    """**Not reached through `entries`**, so the media join never saw it and a child's face
    survived their own erasure in the bucket until phase 127."""
    user = await make_user(session)
    child = await make_child(session, parent=user)
    child.avatar_key = f"children/{child.id}/avatar/abc.jpg"
    await session.flush()

    totals = await _erase(session, user)

    assert no_object_store == [f"children/{child.id}/avatar/abc.jpg"]
    assert totals["objects"] == 1


async def test_a_media_thumbnail_goes_with_the_media(
    session: AsyncSession, no_object_store, apple_calls
) -> None:
    """`thumb_key` is NULL for every row today, so this is latent rather than live — which is
    exactly why it needs a test that sets the column itself."""
    user = await make_user(session)
    child = await make_child(session, parent=user)
    entry = await _entry(session, child, user, "the swing")
    session.add(
        Media(
            id=uuid.uuid4(),
            entry_id=entry.id,
            s3_key="children/x/photo.jpg",
            thumb_key="children/x/photo-thumb.jpg",
            kind="photo",
            bytes=1024,
            upload_status="complete",
        )
    )

    await _erase(session, user)

    assert sorted(no_object_store) == [
        "children/x/photo-thumb.jpg",
        "children/x/photo.jpg",
    ]


async def test_the_rows_are_gone_even_when_the_bucket_refuses(
    session: AsyncSession, monkeypatch, apple_calls
) -> None:
    """**The ordering, asserted from the only side that can see it.** Objects are removed after
    the commit, so a bucket failure cannot roll back an erasure somebody was already told had
    happened. Before phase 127 the delete ran pre-commit and this raised straight out of the
    run, leaving the rows behind."""
    user = await make_user(session)
    child = await make_child(session, parent=user)
    entry = await _entry(session, child, user, "the slide")
    session.add(
        Media(
            id=uuid.uuid4(),
            entry_id=entry.id,
            s3_key="children/x/photo.jpg",
            kind="photo",
            bytes=1024,
            upload_status="complete",
        )
    )

    async def _refuses(keys, settings):
        raise RuntimeError("tigris is down")

    monkeypatch.setattr(s3, "delete_objects", _refuses)

    totals = await _erase(session, user)

    assert totals["accounts"] == 1
    assert await session.get(User, user.id) is None
    assert await session.get(Child, child.id) is None


async def test_one_accounts_failure_does_not_cost_the_rest_of_the_run(
    session: AsyncSession, no_object_store, monkeypatch, apple_calls
) -> None:
    """A batch that abandoned the run on the tenth account left nine deletions committed,
    their totals discarded, and every later request unattempted until somebody noticed."""
    first = await make_user(session)
    second = await make_user(session)
    await deletion.request_deletion(session, first)
    await deletion.request_deletion(session, second)
    await session.commit()
    # Read before the run. The rollback in the middle of it expires the identity map, so
    # touching `first.id` afterwards is a lazy load on an async session — a `MissingGreenlet`
    # inside the assertion rather than the failure this test is actually about.
    both = {first.id, second.id}

    real = deletion.execute_deletion
    seen: list[uuid.UUID] = []

    async def _fails_once(inner_session, request, settings, **kwargs):
        seen.append(request.user_id)
        if len(seen) == 1:
            raise RuntimeError("that one went wrong")
        return await real(inner_session, request, settings, **kwargs)

    monkeypatch.setattr(deletion, "execute_deletion", _fails_once)

    totals = await deletion.run_due_deletions(
        session, get_settings(), now=dt.datetime.now(tz=dt.UTC) + dt.timedelta(days=8)
    )

    # Both were attempted — the run did not stop at the first failure — and exactly the one
    # that failed is still standing.
    assert set(seen) == both
    assert totals["accounts"] == 1
    survivors = set()
    for user_id in both:
        if await session.get(User, user_id) is not None:
            survivors.add(user_id)
    assert survivors == {seen[0]}


async def test_an_upload_that_never_finished_is_aborted_not_left_behind(
    session: AsyncSession, no_object_store, apple_calls, monkeypatch
) -> None:
    """**Parts are not objects**, so `delete_objects` against the key they will become removes
    nothing and reports success. Without the abort, a video a parent started uploading when the
    app was killed outlives the erasure — invisibly, because the `media` row that named the
    upload has cascaded away and no object listing shows the parts."""
    aborted: list[tuple[str, str]] = []

    async def _abort(uploads, settings):
        aborted.extend(uploads)
        return len(uploads)

    monkeypatch.setattr(s3, "abort_multipart_uploads", _abort)

    user = await make_user(session)
    child = await make_child(session, parent=user)
    entry = await _entry(session, child, user, "the first steps")
    session.add(
        Media(
            id=uuid.uuid4(),
            entry_id=entry.id,
            s3_key="children/x/video.mp4",
            s3_upload_id="upload-abc",
            kind="video",
            bytes=99999,
            upload_status="pending",
        )
    )

    await _erase(session, user)

    assert aborted == [("children/x/video.mp4", "upload-abc")]


async def test_a_completed_upload_is_not_aborted(
    session: AsyncSession, no_object_store, apple_calls, monkeypatch
) -> None:
    """`s3_upload_id` is cleared on completion, and a finished upload is an object the delete
    above already removed. Aborting one would be a wasted call at best."""
    aborted: list[tuple[str, str]] = []

    async def _abort(uploads, settings):
        aborted.extend(uploads)
        return len(uploads)

    monkeypatch.setattr(s3, "abort_multipart_uploads", _abort)

    user = await make_user(session)
    child = await make_child(session, parent=user)
    entry = await _entry(session, child, user, "the swing again")
    session.add(
        Media(
            id=uuid.uuid4(),
            entry_id=entry.id,
            s3_key="children/x/done.jpg",
            kind="photo",
            bytes=1024,
            upload_status="complete",
        )
    )

    await _erase(session, user)

    assert aborted == []
    assert no_object_store == ["children/x/done.jpg"]


async def test_the_due_request_is_re_read_under_a_row_lock(
    session: AsyncSession, no_object_store, apple_calls
) -> None:
    """**The window this closes.** `cancel_on_sign_in` can commit `cancelled_at` after the row
    is read and before the deletes commit, and the cascade takes the request row away either
    way — so a parent who was told their cancellation worked would lose the archive anyway.

    Asserted on the compiled statement rather than by racing two transactions: a genuine race
    would either deadlock the suite or pass by luck, and what is being pinned here is that the
    read takes the lock at all."""
    statements: list[str] = []
    original = session.scalar

    async def _record(statement, *args, **kwargs):
        statements.append(str(statement))
        return await original(statement, *args, **kwargs)

    user = await make_user(session)
    await deletion.request_deletion(session, user)
    await session.commit()

    with pytest.MonkeyPatch.context() as mp:
        mp.setattr(session, "scalar", _record)
        await deletion.run_due_deletions(
            session, get_settings(), now=dt.datetime.now(tz=dt.UTC) + dt.timedelta(days=8)
        )

    locked = [s for s in statements if "deletion_requests" in s and "FOR UPDATE" in s]
    assert locked, f"the due request was re-read without a row lock; saw: {statements}"


async def test_one_unreachable_upload_does_not_strand_the_ones_behind_it() -> None:
    """**The guard has to catch both botocore bases, because they are siblings.**

    `ClientError` is a refusal S3 has an opinion about; every transport failure — a read
    timeout, an unreachable endpoint — is a `BotoCoreError` and is *not* a `ClientError`.
    Catching only the first meant one timed-out upload escaped the loop and every upload behind
    it was never attempted, which is the opposite of what the function promises.

    Driven against the real loop with a stubbed client: both existing callers monkeypatch the
    whole function away, so the loop, the guard and the counter had no coverage at all.
    """
    attempted: list[str] = []

    class _Client:
        def abort_multipart_upload(self, *, Bucket, Key, UploadId):
            attempted.append(UploadId)
            if UploadId == "upload-2":
                raise ReadTimeoutError(endpoint_url="https://tigris.test")
            if UploadId == "upload-3":
                raise ClientError({"Error": {"Code": "NoSuchUpload"}}, "AbortMultipartUpload")

    with pytest.MonkeyPatch.context() as mp:
        mp.setattr(s3, "get_s3_client", lambda: _Client())
        aborted = await s3.abort_multipart_uploads(
            [(f"children/x/{n}.mp4", f"upload-{n}") for n in (1, 2, 3, 4)],
            get_settings(),
        )

    assert attempted == ["upload-1", "upload-2", "upload-3", "upload-4"], (
        "a failure stranded the uploads behind it"
    )
    # Two succeeded; the timeout and the NoSuchUpload are both counted as not-aborted.
    assert aborted == 2


async def test_nothing_to_abort_makes_no_call_at_all() -> None:
    """The common case by far — most erasures have no upload in flight."""

    def _explodes():
        raise AssertionError("the client must not be built when there is nothing to abort")

    with pytest.MonkeyPatch.context() as mp:
        mp.setattr(s3, "get_s3_client", _explodes)
        assert await s3.abort_multipart_uploads([], get_settings()) == 0
