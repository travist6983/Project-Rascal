"""`GET /media/{id}/url` — the read path.

The bucket is private, so this endpoint is the only thing that makes uploaded media viewable.
Without it the capture path produces write-only data: the bytes survive in storage and nothing
can render them.

S3 is `moto`. Nothing here talks to real storage.
"""

from __future__ import annotations

import datetime as dt
import uuid
from collections.abc import Iterator
from urllib.parse import urlparse

import pytest
from httpx import AsyncClient
from moto import mock_aws
from sqlalchemy.ext.asyncio import AsyncSession

from factories import grant, make_child, make_user
from helpers import auth_headers
from rascal.config import get_settings
from rascal.models import Entry, Media
from rascal.services import s3


@pytest.fixture
def bucket() -> Iterator[str]:
    settings = get_settings()
    s3.get_s3_client.cache_clear()
    with mock_aws():
        client = s3.get_s3_client()
        client.create_bucket(
            Bucket=settings.s3_bucket,
            CreateBucketConfiguration={"LocationConstraint": settings.s3_region},
        )
        yield settings.s3_bucket
    s3.get_s3_client.cache_clear()


async def _media(session: AsyncSession, *, status: str = "complete") -> tuple:
    user = await make_user(session)
    child = await make_child(session)
    await grant(session, user, child, "parent")
    entry = Entry(
        id=uuid.uuid4(),
        child_id=child.id,
        author_id=user.id,
        occurred_at=dt.datetime(2026, 8, 4, tzinfo=dt.UTC),
        child_age_months=50,
        entry_type="photo",
    )
    session.add(entry)
    await session.flush()
    media = Media(
        id=uuid.uuid4(),
        entry_id=entry.id,
        kind="photo",
        s3_key=f"children/{child.id}/entries/{entry.id}/photo.jpg",
        bytes=1024,
        upload_status=status,
    )
    session.add(media)
    await session.flush()
    return user, child, entry, media


async def test_a_finished_upload_gets_a_readable_url(
    client: AsyncClient, session: AsyncSession, bucket: str
) -> None:
    user, _, _, media = await _media(session)
    await session.commit()

    response = await client.get(f"/v1/media/{media.id}/url", headers=auth_headers(user))
    assert response.status_code == 200

    body = response.json()
    assert body["media_id"] == str(media.id)
    assert body["expires_in"] == get_settings().presign_ttl_seconds

    url = urlparse(body["url"])
    assert url.scheme == "https"
    assert media.s3_key in body["url"]
    assert "X-Amz-Signature=" in body["url"], "an unsigned URL against a private bucket is a 403"


async def test_an_unfinished_upload_is_refused_rather_than_signed(
    client: AsyncClient, session: AsyncSession, bucket: str
) -> None:
    """A pending row has no bytes at the key, so a signed URL for it would 404 from storage —
    which reads to a client like the archive lost the photo."""
    user, _, _, media = await _media(session, status="pending")
    await session.commit()

    response = await client.get(f"/v1/media/{media.id}/url", headers=auth_headers(user))
    assert response.status_code == 409
    assert response.json()["error"]["code"] == "upload_incomplete"


async def test_a_deleted_media_row_is_not_readable(
    client: AsyncClient, session: AsyncSession, bucket: str
) -> None:
    """Every read path filters `deleted_at IS NULL`. A soft delete that still hands out a
    working URL is not a delete."""
    user, _, _, media = await _media(session)
    media.deleted_at = dt.datetime.now(dt.UTC)
    await session.commit()

    response = await client.get(f"/v1/media/{media.id}/url", headers=auth_headers(user))
    assert response.status_code == 404


async def test_a_stranger_cannot_read_the_media(
    client: AsyncClient, session: AsyncSession, bucket: str
) -> None:
    """Authorization runs through the same dependency as every other child-scoped route."""
    _, _, _, media = await _media(session)
    stranger = await make_user(session, display_name="Stranger")
    await session.commit()

    response = await client.get(f"/v1/media/{media.id}/url", headers=auth_headers(stranger))
    assert response.status_code == 403
    assert response.json()["error"]["code"] == "not_authorized"


async def test_a_viewer_may_read(client: AsyncClient, session: AsyncSession, bucket: str) -> None:
    """Reading is not a write. A grandparent with `viewer` can see the photos."""
    _, child, _, media = await _media(session)
    viewer = await make_user(session, display_name="Grandma")
    await grant(session, viewer, child, "viewer")
    await session.commit()

    response = await client.get(f"/v1/media/{media.id}/url", headers=auth_headers(viewer))
    assert response.status_code == 200


async def test_an_unknown_media_id_is_a_404(
    client: AsyncClient, session: AsyncSession, bucket: str
) -> None:
    user = await make_user(session)
    await session.commit()

    response = await client.get(f"/v1/media/{uuid.uuid4()}/url", headers=auth_headers(user))
    assert response.status_code == 404


async def test_the_url_is_not_stored_on_the_row(
    client: AsyncClient, session: AsyncSession, bucket: str
) -> None:
    """Two calls produce independently signed URLs, because nothing is persisted. A stored URL
    outlives its signature and then fails looking like the bytes are gone."""
    user, _, _, media = await _media(session)
    await session.commit()

    first = await client.get(f"/v1/media/{media.id}/url", headers=auth_headers(user))
    second = await client.get(f"/v1/media/{media.id}/url", headers=auth_headers(user))
    assert first.status_code == second.status_code == 200
    assert "X-Amz-Signature=" in first.json()["url"]
    assert "X-Amz-Signature=" in second.json()["url"]
