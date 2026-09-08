"""Phase 147, Sep 6, 2026. **Adding new media is part of membership. Having it is not.**

The owner's call of Sep 6, 2026 reverses the storage half of D2 — a free household's *"100
photos lifetime"* and *"audio unlimited at two minutes a recording"* are gone, and neither was
ever implemented, so this reverses a promise the code never kept. It aligns with D3, which has
said since Aug 15 that on lapse *"text continues, new photo and video uploads stop"*; audio is
the word D3 did not say and this phase says it.

**Two halves, and the second is the one a gate gets wrong.** The refusing half is
`test_a_free_household_is_refused_new_media_of_every_kind` and the three tests that pin who is
*not* refused. The other half is D3's operative test, unchanged and binding:

    If a change would make an existing entry unreadable, unexportable or unsearchable on a free
    tier, it is wrong.

so `test_a_free_households_existing_media_stays_readable_exportable_searchable_and_syncable`
walks six read paths against a household that has just gone free, and
`test_a_free_household_may_finish_an_upload_it_began_while_entitled` walks the seventh.

**`entitled`, not `is_member`** — see `test_a_household_inside_its_trial_may_add_media`.

S3 is `moto`. Nothing here talks to AWS.
"""

from __future__ import annotations

import datetime as dt
import io
import json
import uuid
import zipfile
from collections.abc import Iterator

import pytest
import sqlalchemy as sa
from httpx import AsyncClient
from moto import mock_aws
from sqlalchemy.ext.asyncio import AsyncSession

from factories import grant, make_child, make_family, make_user
from helpers import auth_headers
from rascal.config import get_settings
from rascal.models import Child, Entitlement, Entry, Family, Media, User
from rascal.schemas.entry import EntryCreate
from rascal.services import s3
from rascal.services.grants import issue_grant
from rascal.services.media import MEDIA_REQUIRES_MEMBERSHIP

UPLOAD_URL = "/v1/media/upload-url"

# What a phone sends for one photo. Small enough for the single-PUT path, so no test here
# depends on the multipart machinery — that is `test_media.py`'s subject, not this file's.
PHOTO = {"kind": "photo", "filename": "IMG_0042.HEIC", "bytes": 2 * 1024 * 1024}
CONTENT_TYPES = {"photo": "image/heic", "video": "video/quicktime", "audio": "audio/mp4"}


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


def _hours(count: int) -> dt.datetime:
    """A moment `count` hours from now — negative for the past.

    Relative rather than a literal, for the reason `test_entitlement_grants.py` gives: a
    literal future date rots into a literal past one, and `test_fixture_dates.py` refuses a
    fixture dated after today.
    """
    return dt.datetime.now(tz=dt.UTC) + dt.timedelta(hours=count)


async def _world(session: AsyncSession, family: Family) -> tuple[User, Child, Entry]:
    """A parent in *family*, a child they guard, and one entry to hang media on.

    The entry is `did_it` — the completion shape with no artifact at all — so every test below
    starts from the thing D2 and D3 both promise stays free, and the media is what is added to
    it.
    """
    user = await make_user(session, family=family, display_name="A parent")
    child = await make_child(session)
    await grant(session, user, child, "parent")
    entry = Entry(
        id=uuid.uuid4(),
        child_id=child.id,
        author_id=user.id,
        occurred_at=dt.datetime(2026, 8, 4, tzinfo=dt.UTC),
        child_age_months=50,
        entry_type="did_it",
    )
    session.add(entry)
    await session.commit()
    return user, child, entry


async def _free(session: AsyncSession) -> Family:
    """`tier="free"` **and no trial**, which takes both explicitly.

    `make_family` leaves the column to its default, and the default is fourteen days of trial —
    exactly where production puts a new household. A test that wrote `tier="free"` alone would
    build an entitled household and then assert a refusal that never came.
    """
    return await make_family(session, tier="free", trial_ends_at=None)


async def _lapse(session: AsyncSession, family: Family) -> None:
    """Take the subscription away, leaving everything already captured where it is."""
    entitlement = await session.get(Entitlement, family.id)
    assert entitlement is not None
    entitlement.tier = "free"
    await session.commit()


async def _upload(client: AsyncClient, user: User, entry: Entry, *, kind: str = "photo"):
    return await client.post(
        UPLOAD_URL,
        json={
            "entry_id": str(entry.id),
            "kind": kind,
            "filename": PHOTO["filename"] if kind == "photo" else f"clip.{kind}",
            "bytes": PHOTO["bytes"],
            "content_type": CONTENT_TYPES[kind],
        },
        headers=auth_headers(user),
    )


# --- Who is refused ---------------------------------------------------------------------------


@pytest.mark.parametrize("kind", ["photo", "video", "audio"])
async def test_a_free_household_is_refused_new_media_of_every_kind(
    client: AsyncClient, session: AsyncSession, bucket: str, kind: str
) -> None:
    """**The decision, asserted.** Photo, video *and* audio — audio is the one D3 never named.

    Parametrised rather than written once for `photo`, because the sentence being implemented
    is *"media of any kind"* and a single-kind test would pass against a gate that reads
    `kind == "photo"` — which is exactly what a reader of D2's *"no video"* and *"audio
    unlimited"* might write.
    """
    user, _, entry = await _world(session, await _free(session))

    response = await _upload(client, user, entry, kind=kind)

    assert response.status_code == 402, response.text
    error = response.json()["error"]
    assert error["code"] == "subscription_required"
    assert error["message"] == MEDIA_REQUIRES_MEMBERSHIP
    assert error["field"] is None


async def test_the_refusal_writes_no_media_row_and_reaches_no_storage(
    client: AsyncClient, session: AsyncSession, bucket: str
) -> None:
    """A 402 that had already minted the row would be a gate in name only.

    `plan_upload` is the one place in `src/` that constructs a `Media`, and the refusal is the
    first statement in it — before the entry lookup, before the id collision check, and before
    the multipart `create_multipart_upload` round trip. This is what pins that ordering.
    """
    user, child, entry = await _world(session, await _free(session))

    assert (await _upload(client, user, entry)).status_code == 402

    rows = await session.scalar(
        sa.select(sa.func.count()).select_from(Media).where(Media.entry_id == entry.id)
    )
    assert rows == 0, "a refused upload still wrote a media row"
    listing = s3.get_s3_client().list_objects_v2(Bucket=bucket, Prefix=f"children/{child.id}/")
    assert listing.get("KeyCount", 0) == 0, "a refused upload still touched storage"


async def test_authorization_is_answered_before_the_gate_and_the_402_is_never_an_oracle(
    client: AsyncClient, session: AsyncSession, bucket: str
) -> None:
    """A stranger reads `403`, whatever their own household has paid.

    `entry_access_from_body` resolves the owning child and refuses before the handler runs, so
    the gate cannot be used to learn that an entry exists — which is the property
    `test_authorization_sweep.py` protects across every child-scoped route and which the
    contract now states for this one. Written here because the sweep's own households are all
    inside the factory's default trial, so it can never have exercised a free stranger.
    """
    _, _, entry = await _world(session, await _free(session))
    stranger, _, _ = await _world(session, await _free(session))
    subscriber, _, _ = await _world(
        session, await make_family(session, tier="subscribed", trial_ends_at=None)
    )

    assert (await _upload(client, stranger, entry)).status_code == 403
    assert (await _upload(client, subscriber, entry)).status_code == 403


async def test_the_refusal_obeys_the_membership_copy_rules(
    client: AsyncClient, session: AsyncSession, bucket: str
) -> None:
    """`docs/design/free-tier-copy.md` rule 2: the word is **membership**; a person **joins**.

    Asserted on the wire rather than on the constant, because the string a household reads is
    the one the response carries. Rule 3 is the other half — the archive is never the thing
    being sold — so the sentence must not mention keeping, losing or restoring anything.
    """
    user, _, entry = await _world(session, await _free(session))

    message = (await _upload(client, user, entry)).json()["error"]["message"]

    assert "membership" in message.lower()
    for forbidden in ("upgrade", "unlock", "premium", "pro plan", "!"):
        assert forbidden not in message.lower(), f"the refusal says {forbidden!r}"
    for archive_word in ("lose", "lost", "delete", "restore", "expire"):
        assert archive_word not in message.lower(), (
            f"the refusal implies something about the archive: {archive_word!r}"
        )


# --- Who is not ------------------------------------------------------------------------------


async def test_a_subscribed_household_may_add_media(
    client: AsyncClient, session: AsyncSession, bucket: str
) -> None:
    family = await make_family(session, tier="subscribed", trial_ends_at=None)
    user, _, entry = await _world(session, family)

    response = await _upload(client, user, entry)

    assert response.status_code == 200, response.text
    assert response.json()["upload_url"].startswith("https://")


async def test_a_granted_household_may_add_media(
    client: AsyncClient, session: AsyncSession, bucket: str
) -> None:
    """A complimentary household is on the paying side of this line, as it is of the invite gate.

    `tier` stays `free` — a grant never writes the column Apple owns — so this also pins that
    the gate reads the computed union rather than the column.
    """
    family = await _free(session)
    admin = await make_user(session, display_name="Owner")
    admin.is_admin = True
    await session.flush()
    await issue_grant(session, family_id=family.id, granted_by=admin.id, reason="founding tester")
    user, _, entry = await _world(session, family)

    response = await _upload(client, user, entry)

    assert response.status_code == 200, response.text
    household = (
        await client.get(f"/v1/families/{family.id}/entitlement", headers=auth_headers(user))
    ).json()
    assert household["tier"] == "free", "a grant must not touch the column Apple owns"
    assert household["entitlement_source"] == "grant"


async def test_a_household_inside_its_trial_may_add_media(
    client: AsyncClient, session: AsyncSession, bucket: str
) -> None:
    """**The one judgment this phase made, pinned so it cannot drift silently.**

    A household inside its fourteen days is `entitled` and is deliberately **not** a member:
    `Access.is_member` is `source in ("receipt", "grant")`, which is what the guardian-invite
    paywall asks and what `docs/api-contract.md`'s 402 row for `POST /families/me/invites`
    describes. This gate asks the *other* question.

    The two are different on purpose. D4 sells the second parent on a subscription and a
    fortnight's free look does not add one — so the invite stays behind `is_member`. A trial
    that cannot photograph a child is not a trial of *this* product, whose whole subject is
    capturing one, so media sits behind `entitled`. Flipping this test to expect 402 and
    changing one identifier in `services/media.plan_upload` is the whole of the other reading;
    the point of writing it down here is that it would be a decision rather than a refactor.
    """
    family = await make_family(session, tier="free", trial_ends_at=_hours(24 * 7))
    user, child, entry = await _world(session, family)

    response = await _upload(client, user, entry)

    assert response.status_code == 200, response.text
    board = (await client.get(f"/v1/children/{child.id}/today", headers=auth_headers(user))).json()
    assert board["access"] == "trial", "the fixture must actually be inside a trial"


# --- What the gate must not touch: the free tier's own two entry shapes ------------------------


@pytest.mark.parametrize(
    ("label", "payload"),
    [
        ("text", {"title": "The lighthouse", "body": "A wobbling tower of blocks."}),
        ("did_it", {}),
    ],
)
async def test_text_and_did_it_entries_are_unaffected_on_the_free_tier(
    client: AsyncClient, session: AsyncSession, label: str, payload: dict
) -> None:
    """Unlimited and free, which is the half of D2 that did **not** move.

    `did_it` carries no artifact at all — *"get on the floor for ten minutes"* is a complete
    entry — and a gate that reached the entry path would take the free tier's only two shapes
    away with it.
    """
    user, child, _ = await _world(session, await _free(session))

    created = await client.post(
        "/v1/entries",
        headers={**auth_headers(user), "Idempotency-Key": str(uuid.uuid4())},
        json={
            "id": str(uuid.uuid4()),
            "child_id": str(child.id),
            "occurred_at": "2026-08-14T18:22:00Z",
            **payload,
        },
    )

    assert created.status_code == 201, created.text
    body = created.json()
    assert body["entry_type"] == label
    assert body["media"] == []

    edited = await client.patch(
        f"/v1/entries/{body['id']}", json={"title": "Renamed"}, headers=auth_headers(user)
    )
    assert edited.status_code == 200, "a free household could not edit its own text entry"


async def test_an_entry_cannot_carry_media_in_the_first_place(
    client: AsyncClient, session: AsyncSession
) -> None:
    """`POST /entries` is not a second media-creation path, and this is why it needs no gate.

    `EntryCreate` has no media field, so an entry cannot arrive with an artifact attached — the
    row is minted only by `POST /media/upload-url`. Asserted on the schema *and* over the wire,
    because `ApiModel` ignores unknown keys rather than rejecting them: a client that sent
    `media` would get a 201 and no media, which is silent rather than wrong, and this is what
    would catch the field being added later without the gate following it.
    """
    assert "media" not in EntryCreate.model_fields
    user, child, _ = await _world(session, await _free(session))

    created = await client.post(
        "/v1/entries",
        headers=auth_headers(user),
        json={
            "id": str(uuid.uuid4()),
            "child_id": str(child.id),
            "occurred_at": "2026-08-14T18:22:00Z",
            "media": [{"kind": "photo", "s3_key": "children/x/smuggled.jpg", "bytes": 10}],
        },
    )

    assert created.status_code == 201, created.text
    assert created.json()["media"] == []
    rows = await session.scalar(sa.select(sa.func.count()).select_from(Media))
    assert rows == 0, "POST /entries created a media row"


async def test_sync_push_cannot_create_media_and_so_needs_no_gate(
    client: AsyncClient, session: AsyncSession
) -> None:
    """The offline queue is metadata only, which is the whole answer to the queued-entry case.

    A client draining a queue built while the household was still a member is a real case, and
    it is safe without a gate here for a structural reason rather than a lenient one:
    `PushMedia` carries no `kind`, no `bytes` and no `s3_key`, and `_apply_media` answers
    `conflict` for an id it has never seen. Every media row in the archive therefore passed
    through `POST /media/upload-url` and was gated there — including the queued one, which was
    gated on the day it was captured, when the household was entitled. **`/sync/push` is
    deliberately let through**: refusing it would strand metadata for bytes that are already in
    storage under a row the server itself approved, and that is D3's forbidden outcome.
    """
    user, child, entry = await _world(session, await _free(session))
    invented = str(uuid.uuid4())

    response = await client.post(
        "/v1/sync/push",
        headers=auth_headers(user),
        json={
            "child_id": str(child.id),
            "entries": [],
            "media": [{"id": invented, "entry_id": str(entry.id), "transcript": "smuggled"}],
        },
    )

    assert response.status_code == 200, response.text
    result = response.json()["media"][0]
    assert result["status"] == "conflict"
    assert "upload-url" in result["reason"]
    assert await session.get(Media, uuid.UUID(invented)) is None


# --- D3's operative test, on media -------------------------------------------------------------


async def _existing_media(session: AsyncSession, entry: Entry, bucket: str) -> Media:
    """One finished photo with a transcript, and its bytes actually in storage.

    Written through the ORM rather than through `POST /media/upload-url`, which is the point:
    this is media the household captured while it was entitled, and the fixture must be able to
    build it after the gate exists.
    """
    media = Media(
        id=uuid.uuid4(),
        entry_id=entry.id,
        s3_key=f"children/{entry.child_id}/entries/{entry.id}/{uuid.uuid4()}.heic",
        kind="photo",
        bytes=11,
        upload_status="complete",
        transcript="he called it a lighthouse",
    )
    session.add(media)
    entry.entry_type = "photo"
    await session.commit()
    s3.get_s3_client().put_object(Bucket=bucket, Key=media.s3_key, Body=b"hello world")
    return media


async def test_a_free_households_existing_media_stays_readable_exportable_searchable_and_syncable(
    client: AsyncClient, session: AsyncSession, bucket: str
) -> None:
    """**The sentence this phase is built under, asserted end to end.**

    D3's operative test is unchanged by the reversal: *if a change would make an existing entry
    unreadable, unexportable or unsearchable on a free tier, it is wrong.* Everything else in
    this file checks that something is withheld. This checks that nothing else is — six read
    paths, because "the archive is fine" is a claim about all of them and any one of them could
    have grown an entitlement check.

    The household starts entitled, captures the photo, and *then* goes free, which is the
    shape D3 is about: a lapse, not a household that never paid.
    """
    family = await make_family(session, tier="subscribed", trial_ends_at=None)
    user, child, entry = await _world(session, family)
    media = await _existing_media(session, entry, bucket)
    headers = auth_headers(user)

    # Now take membership away. The column rather than a webhook, the way `make_family` and
    # `runbook-deploy.md` §7a both set it; `test_tier_has_exactly_one_writer` scopes its rule
    # to `src/`, which is where a second writer would actually be a defect.
    await _lapse(session, family)
    board = (await client.get(f"/v1/children/{child.id}/today", headers=headers)).json()
    assert board["access"] == "free", "the fixture must actually be on the free tier"

    # The gate is live for *new* media on this same household, so nothing below passes because
    # the gate quietly failed to apply.
    assert (await _upload(client, user, entry)).status_code == 402

    # 1. The bytes are still reachable. The bucket is private; this is the only way in.
    presigned = await client.get(f"/v1/media/{media.id}/url", headers=headers)
    assert presigned.status_code == 200, presigned.text
    assert presigned.json()["url"].startswith("https://")

    # 2. The timeline still carries it, inline, with its key.
    listed = (await client.get(f"/v1/entries?child_id={child.id}", headers=headers)).json()
    row = next(item for item in listed["entries"] if item["id"] == str(entry.id))
    assert [item["id"] for item in row["media"]] == [str(media.id)]

    # 3. Full-text search still reaches the transcript the phone wrote back.
    found = (
        await client.get(f"/v1/entries?child_id={child.id}&q=lighthouse", headers=headers)
    ).json()
    assert str(entry.id) in {item["id"] for item in found["entries"]}, "search stopped at the gate"
    missed = (
        await client.get(f"/v1/entries?child_id={child.id}&q=zzzznotaword", headers=headers)
    ).json()
    assert missed["entries"] == [], "`q` is not filtering, so the assertion above is vacuous"

    # 4. Sync still delivers the media row.
    pulled = (await client.get(f"/v1/sync?child_id={child.id}", headers=headers)).json()
    assert str(media.id) in {item["id"] for item in pulled["media"]}

    # 5. Sync still accepts metadata for it — a caption written on the phone after the lapse.
    pushed = await client.post(
        "/v1/sync/push",
        headers=headers,
        json={
            "child_id": str(child.id),
            "entries": [],
            "media": [{"id": str(media.id), "entry_id": str(entry.id), "caption": "the tower"}],
        },
    )
    assert pushed.json()["media"][0]["status"] == "accepted"

    # 6. Export is whole, and it is a claim about the bytes rather than about a status code.
    dump = await client.get(f"/v1/children/{child.id}/export", headers=headers)
    assert dump.status_code == 200, dump.text
    archive = zipfile.ZipFile(io.BytesIO(dump.content))
    manifest = json.loads(archive.read("manifest.json"))
    assert manifest["missing_media"] == []
    path = next(name for name in archive.namelist() if str(media.id) in name)
    assert archive.read(path) == b"hello world", "export dropped the bytes on the free tier"


async def test_a_free_household_can_still_write_back_what_the_phone_transcribed(
    client: AsyncClient, session: AsyncSession, bucket: str
) -> None:
    """`PATCH /media/{id}/derived` is untouched, and it has to be.

    On-device AI output is durable data the server never regenerates. Refusing it on the free
    tier would make an existing recording permanently unsearchable — the exact outcome D3
    forbids — and it creates nothing: the media row it writes to already exists.
    """
    user, _, entry = await _world(session, await _free(session))
    media = await _existing_media(session, entry, bucket)

    response = await client.patch(
        f"/v1/media/{media.id}/derived",
        json={"transcript": "and then the brachiosaurus ate the whole tree", "tags": ["dinosaur"]},
        headers=auth_headers(user),
    )

    assert response.status_code == 200, response.text
    assert response.json()["media"]["transcript"].startswith("and then the brachiosaurus")
    assert [tag["name"] for tag in response.json()["tags"]] == ["dinosaur"]


async def test_a_free_household_may_finish_an_upload_it_began_while_entitled(
    client: AsyncClient, session: AsyncSession, bucket: str
) -> None:
    """**`POST /media/{id}/complete` is deliberately not gated**, and this pins the choice.

    A client can hold a presigned URL across a lapse, so `complete` was considered as a belt.
    It is not one. The row and the URLs were minted by an `upload-url` call the server already
    approved, and by the time `complete` is called the bytes are in storage — refusing here
    would leave them under a `pending` row that `GET /media/{id}/url` refuses to presign and no
    client can retry, which is an object the household already captured made permanently
    unreadable. The exposure it would buy is bounded by the presign TTL in any case.
    """
    family = await make_family(session, tier="subscribed", trial_ends_at=None)
    user, _, entry = await _world(session, family)
    planned = await _upload(client, user, entry)
    assert planned.status_code == 200, planned.text
    media_id = planned.json()["media_id"]

    await _lapse(session, family)

    finished = await client.post(
        f"/v1/media/{media_id}/complete",
        json={"captured_at": "2026-08-04T12:00:00Z"},
        headers=auth_headers(user),
    )

    assert finished.status_code == 200, finished.text
    assert finished.json()["upload_status"] == "complete"
