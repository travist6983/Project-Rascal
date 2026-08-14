"""`GET /children/{id}/stats` — the counts a paged client cannot do for itself.

`docs/settings-v2-inventory.md` dropped the hero's stats strip (D1) and its
"First entry — 21 Jun 2022" line (D12) on the same grounds: the timeline is a partial cache, so
the app would be asserting the size of an archive it has only seen part of. These assert the
answer the server gives instead.
"""

from __future__ import annotations

import datetime as dt
import uuid

from httpx import AsyncClient
from sqlalchemy.ext.asyncio import AsyncSession

from factories import grant, make_child, make_user
from helpers import auth_headers
from rascal.models import Entry, Media


async def _world(session: AsyncSession, timezone: str = "America/Detroit"):
    user = await make_user(session)
    child = await make_child(session, birthdate=dt.date(2022, 6, 14), timezone=timezone)
    await grant(session, user, child, "parent")
    return user, child


async def _entry(
    session: AsyncSession,
    child,
    author,
    *,
    occurred_at: dt.datetime,
    unlock_at_age: int | None = None,
    deleted: bool = False,
) -> Entry:
    entry = Entry(
        id=uuid.uuid4(),
        child_id=child.id,
        author_id=author.id,
        occurred_at=occurred_at,
        child_age_months=50,
        entry_type="text",
        body="something",
        unlock_at_age=unlock_at_age,
        deleted_at=dt.datetime(2026, 8, 14, tzinfo=dt.UTC) if deleted else None,
    )
    session.add(entry)
    await session.flush()
    return entry


async def _media(session: AsyncSession, entry, kind: str, *, deleted: bool = False) -> None:
    session.add(
        Media(
            id=uuid.uuid4(),
            entry_id=entry.id,
            s3_key=f"children/x/{uuid.uuid4()}",
            kind=kind,
            bytes=1024,
            upload_status="complete",
            deleted_at=dt.datetime(2026, 8, 14, tzinfo=dt.UTC) if deleted else None,
        )
    )


async def _stats(client: AsyncClient, user, child) -> dict:
    response = await client.get(f"/v1/children/{child.id}/stats", headers=auth_headers(user))
    assert response.status_code == 200
    return response.json()


async def test_an_empty_archive_counts_zero_and_dates_nothing(
    client: AsyncClient, session: AsyncSession
) -> None:
    """**`null`, not today.** A first-entry date standing in for "there is no first entry" is
    the kind of stand-in that renders as a real day on somebody's screen."""
    user, child = await _world(session)
    await session.commit()

    body = await _stats(client, user, child)

    assert body["entries"] == 0
    assert body["sealed"] == 0
    assert body["media"] == {"photo": 0, "video": 0, "audio": 0}
    assert body["first_entry_on"] is None
    assert body["last_entry_on"] is None


async def test_counts_entries_seals_and_media_by_kind(
    client: AsyncClient, session: AsyncSession
) -> None:
    user, child = await _world(session)
    first = await _entry(session, child, user, occurred_at=dt.datetime(2024, 3, 2, tzinfo=dt.UTC))
    sealed = await _entry(
        session,
        child,
        user,
        occurred_at=dt.datetime(2025, 1, 5, tzinfo=dt.UTC),
        unlock_at_age=18,
    )
    await _media(session, first, "photo")
    await _media(session, first, "photo")
    await _media(session, sealed, "audio")
    await session.commit()

    body = await _stats(client, user, child)

    assert body["entries"] == 2
    # A subset of `entries`, never a separate population — 2 entries, one of which is sealed.
    assert body["sealed"] == 1
    assert body["media"] == {"photo": 2, "video": 0, "audio": 1}


async def test_every_media_kind_is_present_even_at_zero(
    client: AsyncClient, session: AsyncSession
) -> None:
    """A key that appears only once a child has recorded audio is a key the client has to
    guard. `0` is a true statement about the archive; an absent key is a crash."""
    user, child = await _world(session)
    entry = await _entry(session, child, user, occurred_at=dt.datetime(2024, 3, 2, tzinfo=dt.UTC))
    await _media(session, entry, "photo")
    await session.commit()

    assert set((await _stats(client, user, child))["media"]) == {"photo", "video", "audio"}


async def test_deleted_entries_and_their_media_are_not_in_the_archive(
    client: AsyncClient, session: AsyncSession
) -> None:
    """Two exclusions, and the second is the one that is easy to miss.

    A soft-deleted entry is not counted. Neither is media hanging off it — the contract says a
    delete takes the media with it, so counting media on its own `deleted_at` would report
    files belonging to an entry that is gone.
    """
    user, child = await _world(session)
    live = await _entry(
        session, child, user, occurred_at=dt.datetime(2024, 3, 2, 17, tzinfo=dt.UTC)
    )
    await _media(session, live, "photo")
    await _media(session, live, "video", deleted=True)

    gone = await _entry(
        session,
        child,
        user,
        occurred_at=dt.datetime(2023, 1, 1, tzinfo=dt.UTC),
        unlock_at_age=18,
        deleted=True,
    )
    # Not deleted in its own right. It is still not in the archive, because its entry is not.
    await _media(session, gone, "photo")
    await session.commit()

    body = await _stats(client, user, child)

    assert body["entries"] == 1
    assert body["sealed"] == 0, "the only sealed entry was deleted"
    assert body["media"] == {"photo": 1, "video": 0, "audio": 0}
    assert body["first_entry_on"] == "2024-03-02", "the deleted 2023 entry is not the first one"


async def test_another_childs_archive_is_not_counted(
    client: AsyncClient, session: AsyncSession
) -> None:
    user, child = await _world(session)
    sibling = await make_child(session, birthdate=dt.date(2024, 1, 1))
    await grant(session, user, sibling, "parent")
    theirs = await _entry(
        session, sibling, user, occurred_at=dt.datetime(2024, 3, 2, tzinfo=dt.UTC)
    )
    await _media(session, theirs, "photo")
    await session.commit()

    body = await _stats(client, user, child)

    assert body["entries"] == 0
    assert body["media"]["photo"] == 0
    assert body["first_entry_on"] is None


async def test_the_first_and_last_days_are_the_childs_days_not_utcs(
    client: AsyncClient, session: AsyncSession
) -> None:
    """**The one that a UTC `date()` gets wrong.**

    9pm in Detroit is the next day in UTC. An archive whose first entry was written on a
    March evening must not report the 3rd because the server stores an instant — the date the
    parent sees has to be the day they lived.
    """
    user, child = await _world(session)
    # 2024-03-02 21:30 in Detroit is 2024-03-03 02:30Z.
    await _entry(session, child, user, occurred_at=dt.datetime(2024, 3, 3, 2, 30, tzinfo=dt.UTC))
    # And 2024-06-10 23:10 Detroit is 2024-06-11 03:10Z.
    await _entry(session, child, user, occurred_at=dt.datetime(2024, 6, 11, 3, 10, tzinfo=dt.UTC))
    await session.commit()

    body = await _stats(client, user, child)

    assert body["first_entry_on"] == "2024-03-02"
    assert body["last_entry_on"] == "2024-06-10"


async def test_as_of_is_the_childs_day(client: AsyncClient, session: AsyncSession) -> None:
    """Every other date this API returns is in the family timezone; this one is no exception."""
    user, child = await _world(session, timezone="Pacific/Kiritimati")
    await session.commit()

    body = await _stats(client, user, child)

    from rascal.services.dates import today_in

    assert body["as_of"] == today_in("Pacific/Kiritimati").isoformat()


async def test_a_zone_postgres_does_not_know_is_still_counted(
    client: AsyncClient, session: AsyncSession
) -> None:
    """**The zone must never reach SQL.** `family_timezone` is validated against Python's
    `zoneinfo`, whose name set is larger than Postgres's: `Asia/Calcutta` is accepted by
    `ChildCreate` and rejected by `timezone()` with `time zone "Asia/Calcutta" not recognized`.
    The first version of this endpoint interpolated the stored zone into the query, so a
    household spelled a way the API itself allows got a 500 on a read.
    """
    user, child = await _world(session, timezone="Asia/Calcutta")
    # 2024-03-02 23:40 UTC is already 2024-03-03 in Calcutta (+05:30) — so this also pins that
    # the conversion still happens, rather than the fix having quietly dropped it.
    await _entry(session, child, user, occurred_at=dt.datetime(2024, 3, 2, 23, 40, tzinfo=dt.UTC))
    await session.commit()

    body = await _stats(client, user, child)

    assert body["entries"] == 1
    assert body["first_entry_on"] == "2024-03-03"


async def test_a_stranger_cannot_count_somebody_elses_archive(
    client: AsyncClient, session: AsyncSession
) -> None:
    """`child_access` and nothing hand-rolled — the same dependency every other route uses."""
    _, child = await _world(session)
    stranger = await make_user(session, display_name="Nobody")
    await session.commit()

    response = await client.get(f"/v1/children/{child.id}/stats", headers=auth_headers(stranger))
    assert response.status_code == 403
