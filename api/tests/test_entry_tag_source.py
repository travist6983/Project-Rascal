"""Writing a tag and saying who decided it.

`entry_tags.source` exists so a tag a parent typed can be told apart from one the on-device model
extracted, and so extraction can be re-run without eating the parent's own. Until this landed,
nothing on the wire could express it — every tag written through the entry endpoints was recorded
as `user`, which made on-device extraction impossible to build without destroying the distinction
permanently.
"""

from __future__ import annotations

import datetime as dt
import uuid

from httpx import AsyncClient
from sqlalchemy import select
from sqlalchemy.ext.asyncio import AsyncSession

from factories import grant, make_child, make_user
from helpers import auth_headers
from rascal.models import EntryTag

TODAY = dt.datetime(2026, 8, 14, 15, 0, tzinfo=dt.UTC)


async def _world(session: AsyncSession):
    user = await make_user(session)
    child = await make_child(session, birthdate=dt.date(2022, 6, 14))
    await grant(session, user, child, "parent")
    await session.commit()
    return user, child


async def _create(client: AsyncClient, user, child, tags: list) -> uuid.UUID:
    entry_id = uuid.uuid4()
    response = await client.post(
        "/v1/entries",
        json={
            "id": str(entry_id),
            "child_id": str(child.id),
            "occurred_at": TODAY.isoformat(),
            "body": "A day at the shore.",
            "tags": tags,
        },
        headers=auth_headers(user),
    )
    assert response.status_code == 201, response.text
    return entry_id


async def _sources(session: AsyncSession, entry_id: uuid.UUID) -> dict[str, str]:
    rows = (
        (
            await session.execute(
                select(EntryTag).where(EntryTag.entry_id == entry_id, EntryTag.deleted_at.is_(None))
            )
        )
        .scalars()
        .all()
    )
    out = {}
    for link in rows:
        await session.refresh(link, ["tag"])
        out[link.tag.name] = link.source
    return out


# --- Backwards compatibility ------------------------------------------------------------------


async def test_a_bare_string_still_means_user(client: AsyncClient, session: AsyncSession) -> None:
    """**Every existing client is unaffected.** A list of plain strings behaves as it always did."""
    user, child = await _world(session)
    entry_id = await _create(client, user, child, ["beach", "sand"])

    assert await _sources(session, entry_id) == {"beach": "user", "sand": "user"}


# --- The new shape ----------------------------------------------------------------------------


async def test_a_tag_can_declare_itself_device_ai(
    client: AsyncClient, session: AsyncSession
) -> None:
    user, child = await _world(session)
    entry_id = await _create(client, user, child, [{"name": "seaside", "source": "device_ai"}])

    assert await _sources(session, entry_id) == {"seaside": "device_ai"}


async def test_a_mixed_write_keeps_both_sources(client: AsyncClient, session: AsyncSession) -> None:
    user, child = await _world(session)
    entry_id = await _create(
        client, user, child, ["beach", {"name": "seaside", "source": "device_ai"}]
    )

    assert await _sources(session, entry_id) == {"beach": "user", "seaside": "device_ai"}


async def test_an_explicit_user_source_is_the_same_as_a_bare_string(
    client: AsyncClient, session: AsyncSession
) -> None:
    user, child = await _world(session)
    entry_id = await _create(client, user, child, [{"name": "beach", "source": "user"}])

    assert await _sources(session, entry_id) == {"beach": "user"}


# --- The protection extraction depends on -----------------------------------------------------


async def test_a_device_ai_write_never_eats_a_tag_a_human_chose(
    client: AsyncClient, session: AsyncSession
) -> None:
    """**The whole reason `source` exists.** Re-running extraction must be free."""
    user, child = await _world(session)
    entry_id = await _create(client, user, child, ["beach"])

    response = await client.patch(
        f"/v1/entries/{entry_id}",
        json={"tags": [{"name": "seaside", "source": "device_ai"}]},
        headers=auth_headers(user),
    )
    assert response.status_code == 200, response.text

    assert await _sources(session, entry_id) == {"beach": "user", "seaside": "device_ai"}


async def test_re_running_extraction_replaces_only_its_own_tags(
    client: AsyncClient, session: AsyncSession
) -> None:
    user, child = await _world(session)
    entry_id = await _create(
        client, user, child, ["beach", {"name": "seaside", "source": "device_ai"}]
    )

    # A second extraction pass produces a different set.
    await client.patch(
        f"/v1/entries/{entry_id}",
        json={"tags": [{"name": "shoreline", "source": "device_ai"}]},
        headers=auth_headers(user),
    )

    assert await _sources(session, entry_id) == {"beach": "user", "shoreline": "device_ai"}


async def test_user_is_applied_before_device_ai(client: AsyncClient, session: AsyncSession) -> None:
    """The ordering inside `apply_tag_writes`, asserted rather than trusted.

    `apply_tags` protects `user` rows from a `device_ai` write and not the reverse, so applying
    `device_ai` first would have the `user` pass delete everything the model just wrote. This
    fails if the order is ever flipped.
    """
    user, child = await _world(session)
    entry_id = await _create(
        client,
        user,
        child,
        [{"name": "seaside", "source": "device_ai"}, "beach"],
    )

    # Both survive regardless of the order they appear in the payload.
    assert await _sources(session, entry_id) == {"beach": "user", "seaside": "device_ai"}


async def test_a_human_retyping_a_model_tag_promotes_it(
    client: AsyncClient, session: AsyncSession
) -> None:
    """Existing `apply_tags` behaviour, confirmed to survive the new grouping."""
    user, child = await _world(session)
    entry_id = await _create(client, user, child, [{"name": "seaside", "source": "device_ai"}])

    await client.patch(
        f"/v1/entries/{entry_id}", json={"tags": ["seaside"]}, headers=auth_headers(user)
    )

    assert await _sources(session, entry_id) == {"seaside": "user"}


async def test_an_unknown_source_is_refused(client: AsyncClient, session: AsyncSession) -> None:
    user, child = await _world(session)
    response = await client.post(
        "/v1/entries",
        json={
            "id": str(uuid.uuid4()),
            "child_id": str(child.id),
            "occurred_at": TODAY.isoformat(),
            "tags": [{"name": "beach", "source": "guessed"}],
        },
        headers=auth_headers(user),
    )
    assert response.status_code == 422
