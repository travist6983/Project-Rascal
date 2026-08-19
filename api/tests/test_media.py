"""Media: presigned upload, completion, and the on-device AI write-back.

S3 is `moto`. Nothing here talks to AWS.
"""

from __future__ import annotations

import datetime as dt
import math
import uuid
from collections.abc import Iterator

import pytest
import sqlalchemy as sa
from httpx import AsyncClient
from moto import mock_aws
from sqlalchemy.ext.asyncio import AsyncSession

from factories import grant, make_assignment, make_child, make_prompt, make_user
from helpers import auth_headers
from rascal.config import get_settings
from rascal.models import Entry, EntryTag, Media
from rascal.services import s3
from rascal.services.entries import refresh_entry_type


@pytest.fixture
def bucket() -> Iterator[str]:
    """A moto-backed S3 with the configured bucket already created."""
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


async def _entry(session: AsyncSession) -> tuple:
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
    await session.commit()
    return user, child, entry


async def test_a_small_photo_gets_a_single_presigned_put(
    client: AsyncClient, session: AsyncSession, bucket: str
) -> None:
    user, child, entry = await _entry(session)

    response = await client.post(
        "/v1/media/upload-url",
        json={
            "entry_id": str(entry.id),
            "kind": "photo",
            "filename": "IMG_0042.HEIC",
            "bytes": 2 * 1024 * 1024,
            "content_type": "image/heic",
        },
        headers=auth_headers(user),
    )

    assert response.status_code == 200
    body = response.json()
    assert body["multipart"] is False
    assert body["parts"] is None
    assert body["upload_url"].startswith("https://")
    assert body["s3_key"].startswith(f"children/{child.id}/entries/{entry.id}/")
    assert body["s3_key"].endswith(".heic")


async def test_a_large_photo_crosses_over_to_multipart(
    client: AsyncClient, session: AsyncSession, bucket: str
) -> None:
    user, _, entry = await _entry(session)
    settings = get_settings()

    response = await client.post(
        "/v1/media/upload-url",
        json={
            "entry_id": str(entry.id),
            "kind": "photo",
            "filename": "huge.jpg",
            "bytes": settings.multipart_threshold_bytes + 1,
            "content_type": "image/jpeg",
        },
        headers=auth_headers(user),
    )

    body = response.json()
    assert body["multipart"] is True
    assert body["upload_url"] is None
    assert len(body["parts"]) >= 2
    assert [part["part_number"] for part in body["parts"]] == list(range(1, len(body["parts"]) + 1))


async def test_a_small_video_takes_the_single_put_path(
    client: AsyncClient, session: AsyncSession, bucket: str
) -> None:
    """**Reversed in phase 87.** This test asserted the opposite, under the name
    `test_video_always_assumes_multipart_however_small`, and the old rule was `kind == "video" or
    size > threshold`.

    A two-second clip is a few hundred kilobytes. Multipart earns its overhead on a large file,
    where per-part retry is worth an initiate round trip plus a presign and a complete call. It buys
    nothing on a file that fits in one request.
    """
    user, _, entry = await _entry(session)

    response = await client.post(
        "/v1/media/upload-url",
        json={
            "entry_id": str(entry.id),
            "kind": "video",
            "filename": "clip.mov",
            "bytes": 1024,
            "content_type": "video/quicktime",
        },
        headers=auth_headers(user),
    )
    body = response.json()
    assert body["multipart"] is False
    assert body["parts"] is None
    assert body["upload_url"].startswith("https://")
    # Null on the single-PUT path is normal, and the client stores it without reading it.
    assert body["chunk_bytes"] is None


async def test_a_large_video_still_goes_multipart(
    client: AsyncClient, session: AsyncSession, bucket: str
) -> None:
    """The half of the old rule that was right. Size is now the only thing that decides, so this
    is the same predicate a large photo meets."""
    user, _, entry = await _entry(session)

    response = await client.post(
        "/v1/media/upload-url",
        json={
            "entry_id": str(entry.id),
            "kind": "video",
            "filename": "long.mov",
            "bytes": 64 * 1024 * 1024,
            "content_type": "video/quicktime",
        },
        headers=auth_headers(user),
    )
    body = response.json()
    assert body["multipart"] is True
    assert body["upload_url"] is None
    assert len(body["parts"]) == 8, "64MB at the 8MB chunk size"


async def test_the_threshold_is_the_only_rule_and_it_does_not_care_about_kind(
    client: AsyncClient, session: AsyncSession, bucket: str
) -> None:
    """One predicate for every kind. A rule that special-cased one kind is how a two-second clip
    ended up doing four round trips."""
    user, _, entry = await _entry(session)
    settings = get_settings()

    for kind, filename, content_type in [
        ("photo", "a.heic", "image/heic"),
        ("audio", "a.m4a", "audio/m4a"),
        ("video", "a.mov", "video/quicktime"),
    ]:
        under = await client.post(
            "/v1/media/upload-url",
            json={
                "entry_id": str(entry.id),
                "media_id": str(uuid.uuid4()),
                "kind": kind,
                "filename": filename,
                "bytes": settings.multipart_threshold_bytes,
                "content_type": content_type,
            },
            headers=auth_headers(user),
        )
        assert under.json()["multipart"] is False, f"{kind} at exactly the threshold"

        over = await client.post(
            "/v1/media/upload-url",
            json={
                "entry_id": str(entry.id),
                "media_id": str(uuid.uuid4()),
                "kind": kind,
                "filename": filename,
                "bytes": settings.multipart_threshold_bytes + 1,
                "content_type": content_type,
            },
            headers=auth_headers(user),
        )
        assert over.json()["multipart"] is True, f"{kind} one byte over"


async def test_completing_a_single_put_marks_the_row(
    client: AsyncClient, session: AsyncSession, bucket: str
) -> None:
    user, _, entry = await _entry(session)
    created = (
        await client.post(
            "/v1/media/upload-url",
            json={
                "entry_id": str(entry.id),
                "kind": "audio",
                "filename": "story.m4a",
                "bytes": 900_000,
                "content_type": "audio/mp4",
            },
            headers=auth_headers(user),
        )
    ).json()

    response = await client.post(
        f"/v1/media/{created['media_id']}/complete",
        json={"captured_at": "2026-08-14T18:00:00Z", "duration_seconds": 94},
        headers=auth_headers(user),
    )

    assert response.status_code == 200
    body = response.json()
    assert body["upload_status"] == "complete"
    assert body["duration_seconds"] == 94
    # Thumbnail and poster-frame generation is out of P0 scope.
    assert body["thumb_key"] is None


async def test_completing_a_multipart_upload_without_etags_is_a_409(
    client: AsyncClient, session: AsyncSession, bucket: str
) -> None:
    user, _, entry = await _entry(session)
    # **Sized over the threshold deliberately.** This test needs a genuinely multipart row, and
    # before phase 87 it got one from a 1KB video because video always assumed multipart. Size is
    # now the only rule, so asking for multipart means asking for a large file — otherwise this
    # silently became a test about the single-PUT path, which cannot 409 for missing etags.
    created = (
        await client.post(
            "/v1/media/upload-url",
            json={
                "entry_id": str(entry.id),
                "kind": "video",
                "filename": "clip.mov",
                "bytes": 32 * 1024 * 1024,
                "content_type": "video/quicktime",
            },
            headers=auth_headers(user),
        )
    ).json()
    assert created["multipart"] is True, "precondition: this test is about the multipart path"

    response = await client.post(
        f"/v1/media/{created['media_id']}/complete", json={}, headers=auth_headers(user)
    )
    assert response.status_code == 409
    assert response.json()["error"]["code"] == "upload_incomplete"


async def test_upload_url_for_an_entry_of_another_child_is_refused(
    client: AsyncClient, session: AsyncSession, bucket: str
) -> None:
    _, _, entry = await _entry(session)
    stranger = await make_user(session, display_name="Nobody")
    await session.commit()

    response = await client.post(
        "/v1/media/upload-url",
        json={
            "entry_id": str(entry.id),
            "kind": "photo",
            "filename": "x.jpg",
            "bytes": 100,
            "content_type": "image/jpeg",
        },
        headers=auth_headers(stranger),
    )
    assert response.status_code == 403


# --- The on-device AI write-back ---------------------------------------------------------


async def _media_for(
    client: AsyncClient, user, entry, *, kind: str = "audio", filename: str = "story.m4a"
) -> str:
    created = (
        await client.post(
            "/v1/media/upload-url",
            json={
                "entry_id": str(entry.id),
                "kind": kind,
                "filename": filename,
                "bytes": 900_000,
                "content_type": "audio/mp4" if kind == "audio" else "image/jpeg",
            },
            headers=auth_headers(user),
        )
    ).json()
    return created["media_id"]


async def test_derived_persists_the_transcript_and_caption(
    client: AsyncClient, session: AsyncSession, bucket: str
) -> None:
    user, _, entry = await _entry(session)
    media_id = await _media_for(client, user, entry)

    response = await client.patch(
        f"/v1/media/{media_id}/derived",
        json={"transcript": "once upon a time there was a dinosaur", "caption": "telling a story"},
        headers=auth_headers(user),
    )

    assert response.status_code == 200
    assert response.json()["media"]["transcript"].startswith("once upon a time")
    assert response.json()["media"]["caption"] == "telling a story"


async def test_derived_is_idempotent(
    client: AsyncClient, session: AsyncSession, bucket: str
) -> None:
    """Sending the same transcript twice changes nothing."""
    user, _, entry = await _entry(session)
    media_id = await _media_for(client, user, entry)
    payload = {"transcript": "same words", "tags": ["voice"]}

    first = await client.patch(
        f"/v1/media/{media_id}/derived", json=payload, headers=auth_headers(user)
    )
    second = await client.patch(
        f"/v1/media/{media_id}/derived", json=payload, headers=auth_headers(user)
    )

    assert first.json()["media"]["transcript"] == second.json()["media"]["transcript"]
    assert [t["name"] for t in second.json()["tags"]] == ["voice"]
    links = (
        (await session.execute(sa.select(EntryTag).where(EntryTag.entry_id == entry.id)))
        .scalars()
        .all()
    )
    assert len(links) == 1


async def test_device_ai_tags_are_marked_as_such(
    client: AsyncClient, session: AsyncSession, bucket: str
) -> None:
    user, _, entry = await _entry(session)
    media_id = await _media_for(client, user, entry)

    response = await client.patch(
        f"/v1/media/{media_id}/derived",
        json={"tags": ["dinosaurs", "bedtime"]},
        headers=auth_headers(user),
    )
    assert {t["source"] for t in response.json()["tags"]} == {"device_ai"}


async def test_a_device_ai_write_never_eats_a_tag_a_human_typed(
    client: AsyncClient, session: AsyncSession, bucket: str
) -> None:
    """Re-running extraction has to be free, and it must never delete a tag I chose."""
    user, _, entry = await _entry(session)
    media_id = await _media_for(client, user, entry)

    await client.patch(
        f"/v1/entries/{entry.id}", json={"tags": ["their-words"]}, headers=auth_headers(user)
    )
    response = await client.patch(
        f"/v1/media/{media_id}/derived",
        json={"tags": ["dinosaurs"]},
        headers=auth_headers(user),
    )

    by_name = {tag["name"]: tag["source"] for tag in response.json()["tags"]}
    assert by_name == {"their-words": "user", "dinosaurs": "device_ai"}


async def test_a_user_edit_can_drop_a_device_ai_tag(
    client: AsyncClient, session: AsyncSession, bucket: str
) -> None:
    """The protection runs one way. A human is always allowed to overrule the model."""
    user, _, entry = await _entry(session)
    media_id = await _media_for(client, user, entry)
    await client.patch(
        f"/v1/media/{media_id}/derived",
        json={"tags": ["dinosaurs"]},
        headers=auth_headers(user),
    )

    patched = await client.patch(
        f"/v1/entries/{entry.id}", json={"tags": ["bedtime"]}, headers=auth_headers(user)
    )
    assert [tag["name"] for tag in patched.json()["tags"]] == ["bedtime"]


async def test_derived_on_someone_elses_media_is_403(
    client: AsyncClient, session: AsyncSession, bucket: str
) -> None:
    user, _, entry = await _entry(session)
    media_id = await _media_for(client, user, entry)
    stranger = await make_user(session, display_name="Nobody")
    await session.commit()

    response = await client.patch(
        f"/v1/media/{media_id}/derived",
        json={"transcript": "mine now"},
        headers=auth_headers(stranger),
    )
    assert response.status_code == 403
    stored = await session.get(Media, uuid.UUID(media_id))
    await session.refresh(stored)
    assert stored.transcript is None


# --- A2/A3/A5: artifact type, chunk size, and a fresh updated_at --------------------------


async def test_completing_an_upload_turns_a_did_it_entry_into_a_media_entry(
    client: AsyncClient, session: AsyncSession, bucket: str
) -> None:
    """Media arrives after the entry exists, so the type assigned at creation is provisional."""
    user, child, entry = await _entry(session)
    entry.entry_type = "did_it"
    entry.body = None
    await session.commit()

    media_id = await _media_for(client, user, entry)
    await client.post(
        f"/v1/media/{media_id}/complete",
        json={"captured_at": "2026-08-14T18:00:00Z"},
        headers=auth_headers(user),
    )

    await session.refresh(entry)
    assert entry.entry_type == "audio"

    listed = await client.get(
        "/v1/entries",
        params={"child_id": str(child.id), "type": "audio"},
        headers=auth_headers(user),
    )
    assert [e["id"] for e in listed.json()["entries"]] == [str(entry.id)]


async def test_completing_an_upload_moves_the_entrys_sync_cursor(
    client: AsyncClient, session: AsyncSession, bucket: str
) -> None:
    """A recomputed entry_type has to reach the other device, so updated_at must move."""
    user, _, entry = await _entry(session)
    entry.entry_type = "did_it"
    entry.body = None
    await session.commit()
    before = entry.updated_at

    media_id = await _media_for(client, user, entry)
    await client.post(f"/v1/media/{media_id}/complete", json={}, headers=auth_headers(user))

    await session.refresh(entry)
    assert entry.updated_at > before


async def test_a_multipart_plan_tells_the_client_where_to_split(
    client: AsyncClient, session: AsyncSession, bucket: str
) -> None:
    """Without chunk_bytes the uploader has to guess, and a wrong guess mismatches the parts."""
    user, _, entry = await _entry(session)
    settings = get_settings()
    size = settings.multipart_threshold_bytes + 1

    response = await client.post(
        "/v1/media/upload-url",
        json={
            "entry_id": str(entry.id),
            "kind": "photo",
            "filename": "huge.jpg",
            "bytes": size,
            "content_type": "image/jpeg",
        },
        headers=auth_headers(user),
    )

    body = response.json()
    assert body["chunk_bytes"] == settings.multipart_chunk_bytes
    # The part count the server presigned is exactly what that chunk size produces.
    assert len(body["parts"]) == math.ceil(size / body["chunk_bytes"])


async def test_a_single_put_has_no_chunk_size(
    client: AsyncClient, session: AsyncSession, bucket: str
) -> None:
    user, _, entry = await _entry(session)
    response = await client.post(
        "/v1/media/upload-url",
        json={
            "entry_id": str(entry.id),
            "kind": "photo",
            "filename": "small.jpg",
            "bytes": 1024,
            "content_type": "image/jpeg",
        },
        headers=auth_headers(user),
    )
    assert response.json()["multipart"] is False
    assert response.json()["chunk_bytes"] is None


async def test_complete_returns_the_updated_at_the_trigger_wrote(
    client: AsyncClient, session: AsyncSession, bucket: str
) -> None:
    """A stale updated_at in a write response disagrees with what /sync will report."""
    user, _, entry = await _entry(session)
    media_id = await _media_for(client, user, entry)

    response = await client.post(
        f"/v1/media/{media_id}/complete", json={}, headers=auth_headers(user)
    )

    stored = await session.scalar(
        sa.select(Media.updated_at).where(Media.id == uuid.UUID(media_id))
    )
    assert dt.datetime.fromisoformat(response.json()["updated_at"]) == stored


async def test_derived_returns_the_updated_at_the_trigger_wrote(
    client: AsyncClient, session: AsyncSession, bucket: str
) -> None:
    user, _, entry = await _entry(session)
    media_id = await _media_for(client, user, entry)

    response = await client.patch(
        f"/v1/media/{media_id}/derived",
        json={"transcript": "once upon a time"},
        headers=auth_headers(user),
    )

    stored = await session.scalar(
        sa.select(Media.updated_at).where(Media.id == uuid.UUID(media_id))
    )
    assert dt.datetime.fromisoformat(response.json()["media"]["updated_at"]) == stored


async def test_media_beats_the_prompts_completion_mode(
    client: AsyncClient, session: AsyncSession, bucket: str
) -> None:
    """Rule (a) outranks rule (b): what is attached wins over what was asked.

    A did-it mission someone photographed anyway is a photo entry — the artifact exists, so
    the Photos filter has to find it.
    """
    user, child, entry = await _entry(session)
    prompt = await make_prompt(
        session,
        kind="activity",
        completion_mode="did_it",
        body="Get on the floor for ten minutes.",
    )
    assignment = await make_assignment(session, child, prompt, slot="mission")
    entry.assignment_id = assignment.id
    entry.body = None
    await session.commit()

    await refresh_entry_type(session, entry)
    await session.commit()
    assert entry.entry_type == "did_it"  # nothing attached yet

    media_id = await _media_for(client, user, entry, kind="photo", filename="floor.jpg")
    await client.post(f"/v1/media/{media_id}/complete", json={}, headers=auth_headers(user))

    await session.refresh(entry)
    assert entry.entry_type == "photo"


async def test_a_media_mission_completed_without_an_artifact_derives_from_the_media_later(
    client: AsyncClient, session: AsyncSession, bucket: str
) -> None:
    """The audio mission answered as a did-it, then actually recorded."""
    user, child, entry = await _entry(session)
    prompt = await make_prompt(
        session,
        kind="audio",
        completion_mode="media",
        body="Record him telling you a story.",
    )
    assignment = await make_assignment(session, child, prompt, slot="mission")
    entry.assignment_id = assignment.id
    entry.body = None
    await session.commit()

    # completion_mode is `media`, not `did_it`, so rule (b) does not fire and the empty
    # entry falls to rule (d).
    await refresh_entry_type(session, entry)
    await session.commit()
    assert entry.entry_type == "did_it"

    media_id = await _media_for(client, user, entry)
    await client.post(f"/v1/media/{media_id}/complete", json={}, headers=auth_headers(user))

    await session.refresh(entry)
    assert entry.entry_type == "audio"


# --- Phase 86: entry_type follows the media, not the bytes -----------------------------------


async def test_planning_an_upload_types_the_entry_immediately(
    client: AsyncClient, session: AsyncSession, bucket: str
) -> None:
    """**The §14 hole, closed.** An upload that never completes never calls
    `POST /media/{id}/complete` — so before this the entry kept whatever type it was created with,
    permanently, and fell out of the Voice and Photos filters forever.

    `entry_type` describes the media a parent attached, not the bytes storage happens to hold yet.
    """
    user, _, entry = await _entry(session)
    entry.entry_type = "did_it"
    await session.commit()

    response = await client.post(
        "/v1/media/upload-url",
        json={
            "entry_id": str(entry.id),
            "kind": "audio",
            "filename": "take.m4a",
            "bytes": 2048,
            "content_type": "audio/m4a",
        },
        headers=auth_headers(user),
    )
    assert response.status_code == 200

    await session.refresh(entry)
    assert entry.entry_type == "audio", "typed before a single byte reaches storage"
    # And the bytes genuinely are not there: the row is still `pending`, and nothing has called
    # `POST /media/{id}/complete`. That combination is the whole point — the type describes the
    # media a parent attached, not what storage holds.
    status = await session.scalar(sa.select(Media.upload_status).where(Media.entry_id == entry.id))
    assert status == "pending"


async def test_a_multipart_plan_types_the_entry_too(
    client: AsyncClient, session: AsyncSession, bucket: str
) -> None:
    """Two branches return from `plan_upload`, so the recompute has to be on both. A video-only
    fix would have left every large photo mistyped."""
    user, _, entry = await _entry(session)
    entry.entry_type = "did_it"
    await session.commit()

    response = await client.post(
        "/v1/media/upload-url",
        json={
            "entry_id": str(entry.id),
            "kind": "video",
            "filename": "clip.mov",
            "bytes": 64 * 1024 * 1024,
            "content_type": "video/quicktime",
        },
        headers=auth_headers(user),
    )
    assert response.json()["multipart"] is True

    await session.refresh(entry)
    assert entry.entry_type == "video"


async def test_deleting_the_only_media_through_sync_retypes_the_entry(
    client: AsyncClient, session: AsyncSession, bucket: str
) -> None:
    """**A bug §14 did not mention.** There is no `DELETE /media`, so a `/sync/push` carrying
    `deleted_at` is the only way a parent's deletion reaches the server — and it never recomputed.
    Deleting an entry's only photo left the entry filed under Photos with nothing attached.
    """
    user, child, entry = await _entry(session)
    media_id = uuid.uuid4()
    plan = await client.post(
        "/v1/media/upload-url",
        json={
            "entry_id": str(entry.id),
            "media_id": str(media_id),
            "kind": "photo",
            "filename": "IMG_1.HEIC",
            "bytes": 2048,
            "content_type": "image/heic",
        },
        headers=auth_headers(user),
    )
    assert plan.status_code == 200
    await session.refresh(entry)
    assert entry.entry_type == "photo"

    pushed = await client.post(
        "/v1/sync/push",
        json={
            "child_id": str(child.id),
            "entries": [],
            "media": [
                {
                    "id": str(media_id),
                    "entry_id": str(entry.id),
                    "deleted_at": "2026-08-18T13:00:00Z",
                }
            ],
        },
        headers=auth_headers(user),
    )
    assert pushed.status_code == 200
    assert pushed.json()["media"][0]["status"] == "accepted"

    await session.refresh(entry)
    assert entry.entry_type != "photo", "an entry with nothing attached is not a photo entry"
    assert entry.entry_type == "did_it"
