"""The full export.

The thing being proved here is not "the endpoint returns 200". It is that a zip pulled off
this API in 2044 still contains the childhood: every entry type, the sealed letter that has
not opened yet, the rows somebody deleted, the transcripts the phone wrote back, and the
actual bytes of every photo — foldered by when the moment happened, not by when it uploaded.

S3 is `moto`. Nothing here talks to AWS.
"""

from __future__ import annotations

import datetime as dt
import io
import json
import tempfile
import uuid
import zipfile
from collections.abc import Iterator
from pathlib import Path

import pytest
from httpx import AsyncClient
from moto import mock_aws
from sqlalchemy.ext.asyncio import AsyncSession

from factories import grant, make_assignment, make_child, make_prompt, make_user
from helpers import auth_headers
from rascal.config import get_settings
from rascal.models import Entry, EntryTag, Media, Tag
from rascal.services import export as export_service
from rascal.services import s3


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


def _put(key: str, payload: bytes) -> None:
    s3.get_s3_client().put_object(Bucket=get_settings().s3_bucket, Key=key, Body=payload)


async def _archive(session: AsyncSession) -> dict:
    """One of every entry shape, plus a sealed letter, plus a deleted row.

    Deliberately not built through the API: this test is about what comes *out*, and
    arranging the world through the ORM means it cannot be made to pass by the same bug
    that would make the write path wrong.
    """
    user = await make_user(session)
    child = await make_child(session, name="Miles")
    await grant(session, user, child, "parent")

    prompt = await make_prompt(
        session,
        kind="activity",
        completion_mode="did_it",
        body="Get on the floor for ten minutes. No phone.",
        theme="everyday-ordinary",
    )
    assignment = await make_assignment(session, child, prompt, slot="mission", status="done")

    tag = Tag(child_id=child.id, name="bath time")
    session.add(tag)
    await session.flush()

    made: dict[str, Entry] = {}

    def _entry(
        key: str,
        *,
        entry_type: str,
        occurred_at: dt.datetime,
        title: str | None = None,
        body: str | None = None,
        unlock_at_age: int | None = None,
        deleted: bool = False,
        assignment_id: uuid.UUID | None = None,
    ) -> Entry:
        entry = Entry(
            id=uuid.uuid4(),
            child_id=child.id,
            author_id=user.id,
            assignment_id=assignment_id,
            occurred_at=occurred_at,
            child_age_months=50,
            title=title,
            body=body,
            entry_type=entry_type,
            unlock_at_age=unlock_at_age,
            deleted_at=dt.datetime.now(tz=dt.UTC) if deleted else None,
        )
        session.add(entry)
        made[key] = entry
        return entry

    _entry(
        "did_it",
        entry_type="did_it",
        occurred_at=dt.datetime(2026, 1, 9, 18, 0, tzinfo=dt.UTC),
        assignment_id=assignment.id,
    )
    _entry(
        "text",
        entry_type="text",
        occurred_at=dt.datetime(2026, 2, 14, 9, 30, tzinfo=dt.UTC),
        title="Hangaburger",
        body="He has called it a hangaburger for four months and nobody has corrected him.",
    )
    photo_entry = _entry(
        "photo",
        entry_type="photo",
        occurred_at=dt.datetime(2026, 3, 2, 17, 15, tzinfo=dt.UTC),
    )
    audio_entry = _entry(
        "audio",
        entry_type="audio",
        occurred_at=dt.datetime(2026, 4, 21, 20, 5, tzinfo=dt.UTC),
    )
    video_entry = _entry(
        "video",
        entry_type="video",
        occurred_at=dt.datetime(2026, 5, 30, 11, 45, tzinfo=dt.UTC),
    )
    _entry(
        "letter",
        entry_type="text",
        occurred_at=dt.datetime(2026, 6, 14, 7, 0, tzinfo=dt.UTC),
        title="For your eighteenth",
        body="You were four and you told me the moon was following the car.",
        unlock_at_age=18,
    )
    _entry(
        "deleted",
        entry_type="text",
        occurred_at=dt.datetime(2026, 7, 4, 22, 0, tzinfo=dt.UTC),
        body="Deleted by mistake in 2026. Still has to come out in the export.",
        deleted=True,
    )
    await session.flush()

    session.add(EntryTag(entry_id=photo_entry.id, tag_id=tag.id, source="device_ai"))

    objects = {
        "photo": ("children/miles/2026/03/pumpkin.heic", b"\x89PNG-pretend-photo" * 64),
        "audio": ("children/miles/2026/04/story.m4a", b"pretend-audio-frames" * 128),
        "video": ("children/miles/2026/05/first-swing.mov", b"pretend-video-atoms" * 256),
    }
    media_ids: dict[str, uuid.UUID] = {}
    for key, entry in (("photo", photo_entry), ("audio", audio_entry), ("video", video_entry)):
        s3_key, payload = objects[key]
        _put(s3_key, payload)
        media = Media(
            id=uuid.uuid4(),
            entry_id=entry.id,
            s3_key=s3_key,
            kind=key,
            bytes=len(payload),
            upload_status="complete",
            transcript=("once upon a time there was a dinosaur" if key == "audio" else None),
            caption=("A boy holding a pumpkin twice his size." if key == "photo" else None),
            duration_seconds=(41 if key in {"audio", "video"} else None),
        )
        session.add(media)
        media_ids[key] = media.id

    # A row S3 has never heard of: an upload that died mid-flight. The export has to survive
    # it rather than 500.
    ghost = Media(
        id=uuid.uuid4(),
        entry_id=video_entry.id,
        s3_key="children/miles/2026/05/never-finished.mov",
        kind="video",
        bytes=9_000_000,
        upload_status="pending",
    )
    session.add(ghost)
    await session.commit()

    return {
        "user": user,
        "child": child,
        "entries": made,
        "media_ids": media_ids,
        "ghost": ghost,
        "objects": objects,
        "prompt": prompt,
    }


async def _download(client: AsyncClient, world: dict):
    response = await client.get(
        f"/v1/children/{world['child'].id}/export", headers=auth_headers(world["user"])
    )
    assert response.status_code == 200, response.text
    assert response.headers["content-type"] == "application/zip"
    return response


async def test_the_export_contains_every_entry_including_the_deleted_one(
    client: AsyncClient, session: AsyncSession, bucket: str
) -> None:
    world = await _archive(session)
    response = await _download(client, world)

    archive = zipfile.ZipFile(io.BytesIO(response.content))
    entries = json.loads(archive.read("entries.json"))
    assert len(entries) == 7

    by_type = {}
    for record in entries:
        by_type.setdefault(record["entry_type"], []).append(record)
    # All three completion shapes, and every media kind, survive the round trip.
    assert set(by_type) == {"did_it", "text", "photo", "audio", "video"}

    deleted = [record for record in entries if record["is_deleted"]]
    assert len(deleted) == 1
    assert deleted[0]["deleted_at"] is not None
    assert "Deleted by mistake" in deleted[0]["body"]

    # Oldest first, so reading the file top to bottom is reading the childhood in order.
    occurred = [record["occurred_at"] for record in entries]
    assert occurred == sorted(occurred)


async def test_a_sealed_letter_exports_in_the_clear_with_its_unlock_age(
    client: AsyncClient, session: AsyncSession, bucket: str
) -> None:
    """The letter is sealed *in the app*. An export you cannot read is not a backup."""
    world = await _archive(session)
    response = await _download(client, world)

    entries = json.loads(zipfile.ZipFile(io.BytesIO(response.content)).read("entries.json"))
    letter = next(record for record in entries if record["unlock_at_age"] is not None)
    assert letter["unlock_at_age"] == 18
    assert "the moon was following the car" in letter["body"]
    assert letter["title"] == "For your eighteenth"


async def test_media_lands_under_the_month_it_happened_with_its_bytes_intact(
    client: AsyncClient, session: AsyncSession, bucket: str
) -> None:
    world = await _archive(session)
    response = await _download(client, world)
    archive = zipfile.ZipFile(io.BytesIO(response.content))

    names = set(archive.namelist())
    expected = {
        "photo": f"media/2026/03/{world['media_ids']['photo']}.heic",
        "audio": f"media/2026/04/{world['media_ids']['audio']}.m4a",
        "video": f"media/2026/05/{world['media_ids']['video']}.mov",
    }
    assert expected["photo"] in names
    assert expected["audio"] in names
    assert expected["video"] in names

    # Foldered by occurred_at, not by upload time — a backdated photo files under the month
    # the moment happened.
    for kind, path in expected.items():
        assert archive.read(path) == world["objects"][kind][1]

    entries = json.loads(archive.read("entries.json"))
    paths = {item["id"]: item["path"] for record in entries for item in record["media"]}
    for kind, path in expected.items():
        assert paths[str(world["media_ids"][kind])] == path


async def test_transcripts_captions_and_tags_travel_with_the_entry(
    client: AsyncClient, session: AsyncSession, bucket: str
) -> None:
    """Rule 7: on-device AI output is durable data, so it belongs in the export."""
    world = await _archive(session)
    response = await _download(client, world)

    entries = json.loads(zipfile.ZipFile(io.BytesIO(response.content)).read("entries.json"))
    media = [item for record in entries for item in record["media"]]
    assert "once upon a time there was a dinosaur" in {item["transcript"] for item in media}
    assert "A boy holding a pumpkin twice his size." in {item["caption"] for item in media}

    tagged = next(record for record in entries if record["tags"])
    assert tagged["tags"][0]["name"] == "bath time"
    assert tagged["tags"][0]["source"] == "device_ai"


async def test_the_originating_prompt_is_exported_next_to_the_answer(
    client: AsyncClient, session: AsyncSession, bucket: str
) -> None:
    """A `did_it` entry with no artifact is meaningless without the mission it completed."""
    world = await _archive(session)
    response = await _download(client, world)

    entries = json.loads(zipfile.ZipFile(io.BytesIO(response.content)).read("entries.json"))
    did_it = next(record for record in entries if record["entry_type"] == "did_it")
    assert did_it["body"] is None
    assert did_it["media"] == []
    assert did_it["prompt"]["body"] == "Get on the floor for ten minutes. No phone."
    assert did_it["prompt"]["completion_mode"] == "did_it"


async def test_a_media_row_whose_bytes_are_gone_is_named_not_fatal(
    client: AsyncClient, session: AsyncSession, bucket: str
) -> None:
    """One dead upload must not cost you the other seventeen years."""
    world = await _archive(session)
    response = await _download(client, world)
    archive = zipfile.ZipFile(io.BytesIO(response.content))

    manifest = json.loads(archive.read("manifest.json"))
    assert manifest["missing_media"] == [world["ghost"].s3_key]
    assert manifest["counts"]["media"] == 3
    assert response.headers["x-rascal-export-missing-media"] == "1"

    # Its metadata is still there; only the path is null, so nothing in the manifest points
    # at a file that is not in the archive.
    entries = json.loads(archive.read("entries.json"))
    ghost = next(
        item
        for record in entries
        for item in record["media"]
        if item["id"] == str(world["ghost"].id)
    )
    assert ghost["path"] is None
    assert ghost["upload_status"] == "pending"


async def test_the_manifest_says_what_is_in_the_box(
    client: AsyncClient, session: AsyncSession, bucket: str
) -> None:
    world = await _archive(session)
    response = await _download(client, world)

    manifest = json.loads(zipfile.ZipFile(io.BytesIO(response.content)).read("manifest.json"))
    # **Stays `rascal-export` through the Dogear rename, on purpose.** This is the identifier
    # the viewer checks; renaming it would make every archive exported before the rename fail
    # to open in a newer viewer. The download filename is decoration and did move — below.
    assert manifest["format"] == "rascal-export"
    assert manifest["format_version"] == 1
    assert manifest["child"]["name"] == "Miles"
    assert manifest["child"]["family_timezone"] == "America/Detroit"
    # The key must be present even when unanswered, and null is the answer the viewer's
    # table reads as they/them. Absent and null are the same thing to `||` in JavaScript,
    # so this is pinned here rather than left to the viewer to be lenient about.
    assert "pronouns" in manifest["child"]
    assert manifest["child"]["pronouns"] is None
    assert manifest["counts"] == {
        "entries": 7,
        "deleted_entries": 1,
        "media": 3,
        "media_bytes": sum(len(payload) for _, payload in world["objects"].values()),
    }
    # Whoever opens this in 2044 gets told what the shape means without this repo.
    assert any("soft-deleted" in note for note in manifest["notes"])

    assert response.headers["x-rascal-export-entries"] == "7"
    assert response.headers["content-length"] == str(len(response.content))
    assert "dogear-miles-" in response.headers["content-disposition"]


async def test_a_name_that_is_not_ascii_still_downloads(
    client: AsyncClient, session: AsyncSession, bucket: str
) -> None:
    """Content-Disposition is encoded latin-1. A name in Japanese must not raise mid-response,
    after the whole zip has already been built. The real name is in the manifest in full."""
    user = await make_user(session)
    child = await make_child(session, name="ミロ")
    await grant(session, user, child, "parent")
    await session.commit()

    response = await client.get(f"/v1/children/{child.id}/export", headers=auth_headers(user))
    assert response.status_code == 200
    assert response.headers["content-disposition"].isascii()
    assert "dogear-child-" in response.headers["content-disposition"]

    manifest = json.loads(zipfile.ZipFile(io.BytesIO(response.content)).read("manifest.json"))
    assert manifest["child"]["name"] == "ミロ"


async def test_a_viewer_cannot_walk_off_with_the_whole_archive(
    client: AsyncClient, session: AsyncSession, bucket: str
) -> None:
    """Read-only guardians read the timeline. The copy of the childhood is the parent's."""
    world = await _archive(session)
    viewer = await make_user(session, display_name="Grandma")
    await grant(session, viewer, world["child"], "viewer")
    await session.commit()

    response = await client.get(
        f"/v1/children/{world['child'].id}/export", headers=auth_headers(viewer)
    )
    assert response.status_code == 403
    assert response.json()["error"]["code"] == "not_authorized"


async def test_a_stranger_gets_nothing(
    client: AsyncClient, session: AsyncSession, bucket: str
) -> None:
    world = await _archive(session)
    stranger = await make_user(session, display_name="Nobody")
    await session.commit()

    response = await client.get(
        f"/v1/children/{world['child'].id}/export", headers=auth_headers(stranger)
    )
    assert response.status_code == 403


async def test_an_empty_archive_still_produces_a_valid_zip(
    client: AsyncClient, session: AsyncSession, bucket: str
) -> None:
    """A family that signed up yesterday can still export. Zero entries is not an error."""
    user = await make_user(session)
    child = await make_child(session, name="New")
    await grant(session, user, child, "parent")
    await session.commit()

    response = await client.get(f"/v1/children/{child.id}/export", headers=auth_headers(user))
    assert response.status_code == 200

    archive = zipfile.ZipFile(io.BytesIO(response.content))
    assert json.loads(archive.read("entries.json")) == []
    assert json.loads(archive.read("manifest.json"))["counts"]["entries"] == 0


def _staged() -> set[Path]:
    return set(Path(tempfile.gettempdir()).glob("rascal-export-*"))


async def test_the_staged_zip_does_not_outlive_the_download(
    client: AsyncClient, session: AsyncSession, bucket: str
) -> None:
    """The zip is written to disk. If it is never cleaned up, the machine fills."""
    world = await _archive(session)

    # Prove the glob actually matches what staging_path produces, so a pass below means the
    # file was cleaned up rather than that this test was looking in the wrong place.
    probe = export_service.staging_path(world["child"].id)
    assert probe in _staged()
    probe.unlink()

    before = _staged()
    await _download(client, world)
    assert _staged() == before


async def test_a_failed_build_does_not_leave_a_half_written_zip_behind(
    client: AsyncClient, session: AsyncSession, bucket: str, monkeypatch: pytest.MonkeyPatch
) -> None:
    """The success path unlinks on the way out; the failure path has to as well."""
    world = await _archive(session)

    def _explode(*args: object, **kwargs: object) -> None:
        raise RuntimeError("disk gave out halfway through")

    monkeypatch.setattr(export_service, "write_export", _explode)

    before = _staged()
    with pytest.raises(RuntimeError):
        await client.get(
            f"/v1/children/{world['child'].id}/export", headers=auth_headers(world["user"])
        )
    assert _staged() == before
