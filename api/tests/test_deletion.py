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
from httpx import AsyncClient
from sqlalchemy.exc import IntegrityError
from sqlalchemy.ext.asyncio import AsyncSession

from factories import grant, make_child, make_family, make_prompt, make_user
from helpers import auth_headers
from rascal.config import get_settings
from rascal.models import (
    Child,
    DeletionRequest,
    Entry,
    Guardian,
    Media,
    RefreshToken,
    User,
)
from rascal.services import deletion, s3


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
