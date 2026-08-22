"""Putting a card on Instagram, and every way that is refused.

**The failure this file mostly exists to prevent is a duplicate on a public feed.** Every other
failure in the publish path is recoverable: a refused publish can be retried, a failed container
can be rebuilt, a wrong caption can be edited. A post that goes out twice is seen by strangers
and cannot be undone from here, so the tests that matter most are the ones about not posting —
the guard against an asset that already went out, the guard against two queued rows, the
pre-publish question asked of Instagram rather than of our own table, and the container id
written down *before* the irreversible call.

**No network.** Every test here replaces `services.social.instagram` with a fake. That is the
right seam: the real module is one `httpx` call shape repeated, and a test that stood up a
mock Graph API would be testing httpx. What is worth pinning is what this service *decides*.

One test does read the real module's source — the one asserting the access token never goes in
a query string. That leak was real for about twenty minutes while this was being built: httpx
logs the full request URL at INFO, so a `--account` run printed a live token into the
structured log three times.
"""

from __future__ import annotations

import datetime as dt
import uuid
from dataclasses import dataclass

import pytest
from sqlalchemy import select
from sqlalchemy.ext.asyncio import AsyncSession

from factories import make_user
from rascal.config import get_settings
from rascal.errors import ErrorCode, RascalError
from rascal.models import SocialAsset, SocialPublication
from rascal.services.social import instagram, publishing


@dataclass
class FakeGram:
    """Everything `publishing.run` asks of Instagram, with none of the internet.

    Records what it was asked so a test can assert the *order* — which matters here more than
    the values, because the whole design is that the irreversible call happens last.
    """

    already: instagram.Media | None = None
    blocked: str | None = None
    media_id: str = "17900000000000001"
    permalink: str | None = "https://www.instagram.com/p/Dc000000000/"
    fail_publish: bool = False

    def __post_init__(self) -> None:
        self.calls: list[str] = []

    def configured(self, settings) -> bool:
        return True

    async def find_published(self, settings, caption):
        self.calls.append("find_published")
        return self.already

    async def spacing(self, settings, *, now=None):
        self.calls.append("spacing")
        return instagram.Spacing(
            last_post_at=None, posts_in_last_24h=0, blocked_reason=self.blocked
        )

    async def create_container(self, settings, *, image_url, caption, alt_text, story=False):
        self.calls.append("create_container")
        self.image_url = image_url
        self.caption = caption
        self.alt_text = alt_text
        self.story = story
        return "CONTAINER-1"

    async def wait_for_container(self, settings, container_id):
        self.calls.append("wait_for_container")

    async def publish_container(self, settings, container_id):
        self.calls.append("publish_container")
        if self.fail_publish:
            raise RascalError(ErrorCode.PUBLISH_FAILED, "Instagram said no.")
        return self.media_id

    async def permalink_for(self, settings, media_id):
        self.calls.append("permalink_for")
        return self.permalink


@pytest.fixture
def gram(monkeypatch) -> FakeGram:
    fake = FakeGram()
    for name in (
        "configured",
        "find_published",
        "spacing",
        "create_container",
        "wait_for_container",
        "publish_container",
        "permalink_for",
    ):
        monkeypatch.setattr(publishing.instagram, name, getattr(fake, name))
    # The presigned URL is a boto3 round trip in a thread; the seam under test is what gets
    # handed to Meta, not how it was signed.
    monkeypatch.setattr(publishing, "presign_get", lambda key, settings: f"https://signed/{key}")
    return fake


@pytest.fixture
def live_settings():
    """Credentials present and publishing switched on — the state a real post needs."""
    return get_settings().model_copy(
        update={
            "ig_user_id": "38177304098550926",
            "ig_access_token": "a-token",
            "social_publish_enabled": True,
        }
    )


async def make_asset(session: AsyncSession, user, **overrides) -> SocialAsset:
    asset = SocialAsset(
        platform=overrides.pop("platform", "instagram"),
        headline=overrides.pop("headline", "What a camera roll can't do"),
        caption=overrides.pop("caption", "A long enough first line to be distinctive prose."),
        alt_text=overrides.pop("alt_text", "Dark type on a cream card."),
        hashtags=overrides.pop("hashtags", ["vellum", "childhoodarchive"]),
        render_key=overrides.pop("render_key", "social/2026/08/abc.jpg"),
        created_by_user_id=user.id,
        **overrides,
    )
    session.add(asset)
    await session.flush()
    return asset


# --- Refusals ---------------------------------------------------------------------------------


async def test_publishing_is_off_until_somebody_switches_it_on(session: AsyncSession) -> None:
    """**Credentials must not be the switch.** This is `marketing_email_enabled`'s rule, and it
    is here for the same reason: setting a secret should never, by itself, start reaching the
    public. The default of `social_publish_enabled` is the assertion."""
    settings = get_settings()
    assert settings.social_publish_enabled is False

    user = await make_user(session, display_name="Owner")
    asset = await make_asset(session, user)
    with pytest.raises(RascalError) as caught:
        await publishing.queue(session, settings, asset.id, user, scheduled_for=None)
    assert "SOCIAL_PUBLISH_ENABLED" in caught.value.message


async def test_a_post_with_no_alt_text_is_refused(session: AsyncSession, live_settings) -> None:
    """The rule `update_asset` applies at export, applied where it matters most. An image on a
    public feed with no alt text is a post a blind reader gets nothing from."""
    user = await make_user(session, display_name="Owner")
    asset = await make_asset(session, user, alt_text=None)
    with pytest.raises(RascalError) as caught:
        await publishing.queue(session, live_settings, asset.id, user, scheduled_for=None)
    assert caught.value.field == "alt_text"


async def test_a_post_with_no_image_is_refused(session: AsyncSession, live_settings) -> None:
    user = await make_user(session, display_name="Owner")
    asset = await make_asset(session, user, render_key=None)
    with pytest.raises(RascalError) as caught:
        await publishing.queue(session, live_settings, asset.id, user, scheduled_for=None)
    assert caught.value.field == "render_key"


async def test_a_platform_with_no_publisher_says_so_rather_than_failing(
    session: AsyncSession, live_settings
) -> None:
    """`SOCIAL_PLATFORMS` is longer than `PUBLISHABLE` on purpose — the owner asked for "all
    socials eventually, start with ONLY instagram". The gap has to be a sentence, not a 500."""
    user = await make_user(session, display_name="Owner")
    asset = await make_asset(session, user, platform="threads")
    with pytest.raises(RascalError) as caught:
        await publishing.queue(session, live_settings, asset.id, user, scheduled_for=None)
    assert "threads" in caught.value.message
    assert "by hand" in caught.value.message


async def test_an_asset_that_already_went_out_cannot_be_queued_again(
    session: AsyncSession, live_settings
) -> None:
    user = await make_user(session, display_name="Owner")
    asset = await make_asset(session, user)
    asset.published_at = dt.datetime.now(tz=dt.UTC)
    await session.flush()

    with pytest.raises(RascalError) as caught:
        await publishing.queue(session, live_settings, asset.id, user, scheduled_for=None)
    assert caught.value.code is ErrorCode.CONFLICT


async def test_one_asset_cannot_be_queued_twice(session: AsyncSession, live_settings) -> None:
    """Pressing publish twice must not produce two posts. Checked in Python here; the partial
    unique index below is what survives two processes."""
    user = await make_user(session, display_name="Owner")
    asset = await make_asset(session, user)
    await publishing.queue(session, live_settings, asset.id, user, scheduled_for=None)

    with pytest.raises(RascalError) as caught:
        await publishing.queue(session, live_settings, asset.id, user, scheduled_for=None)
    assert caught.value.code is ErrorCode.CONFLICT
    assert "already queued" in caught.value.message


async def test_the_database_refuses_a_second_live_row_for_one_asset(
    session: AsyncSession,
) -> None:
    """The guard that does not depend on one process having seen the other.

    `publishing.queue` checks first and raises a readable 409. This is the index underneath it,
    and it is the one that holds when the web machine and the scheduled machine both look at
    the same asset in the same second.
    """
    from sqlalchemy.exc import IntegrityError

    user = await make_user(session, display_name="Owner")
    asset = await make_asset(session, user)
    session.add(SocialPublication(asset_id=asset.id, platform="instagram", status="scheduled"))
    await session.flush()
    session.add(SocialPublication(asset_id=asset.id, platform="instagram", status="scheduled"))
    with pytest.raises(IntegrityError):
        await session.flush()
    await session.rollback()


# --- Publishing -------------------------------------------------------------------------------


async def test_a_publish_records_what_went_out_and_marks_the_asset(
    session: AsyncSession, live_settings, gram
) -> None:
    user = await make_user(session, display_name="Owner")
    asset = await make_asset(session, user)
    publication = await publishing.queue(session, live_settings, asset.id, user, scheduled_for=None)
    result = await publishing.run(session, live_settings, publication)

    assert result.status == "published"
    assert result.media_id == "17900000000000001"
    assert result.permalink == "https://www.instagram.com/p/Dc000000000/"
    assert result.published_at is not None
    assert result.container_id == "CONTAINER-1"

    await session.refresh(asset)
    assert asset.status == "published"
    assert asset.published_at is not None


async def test_the_irreversible_call_happens_last(
    session: AsyncSession, live_settings, gram
) -> None:
    """The order is the design: everything that can refuse gets to refuse first.

    Asked of Instagram before anything is built — *is this already up* — then *is it too soon*,
    then the container, and only then the publish. A regression that moved the publish earlier
    would still pass every other test in this file.
    """
    user = await make_user(session, display_name="Owner")
    asset = await make_asset(session, user)
    publication = await publishing.queue(session, live_settings, asset.id, user, scheduled_for=None)
    await publishing.run(session, live_settings, publication)

    assert gram.calls == [
        "find_published",
        "spacing",
        "create_container",
        "wait_for_container",
        "publish_container",
        "permalink_for",
    ]


async def test_the_container_id_is_written_before_the_publish_call(
    session: AsyncSession, live_settings, gram
) -> None:
    """**The gap between building a container and publishing it is the dangerous one.**

    If the publish call succeeds and nothing is written down, a post is on a public feed that no
    row here knows about. Recording the container first does not prevent that — nothing can —
    but it turns "did this post?" from a guess over prose into a question about a specific
    container. This test fails a publish and asserts the evidence survived.
    """
    user = await make_user(session, display_name="Owner")
    asset = await make_asset(session, user)
    gram.fail_publish = True
    publication = await publishing.queue(session, live_settings, asset.id, user, scheduled_for=None)

    with pytest.raises(RascalError):
        await publishing.run(session, live_settings, publication)

    await session.refresh(publication)
    assert publication.container_id == "CONTAINER-1"
    assert publication.status == "failed"
    assert publication.error == "Instagram said no."
    assert publication.attempts == 1


async def test_a_post_already_on_the_account_is_recorded_rather_than_sent_twice(
    session: AsyncSession, live_settings, gram
) -> None:
    """The duplicate guard, and the reason it asks Instagram rather than our own table.

    A previous attempt published and then failed to record. The row still says pending, so
    without this the next attempt posts the same card again — to a public feed, permanently.
    """
    user = await make_user(session, display_name="Owner")
    asset = await make_asset(session, user)
    when = dt.datetime(2026, 8, 19, 21, 29, tzinfo=dt.UTC)
    gram.already = instagram.Media(
        id="17899999999999999",
        timestamp=when,
        permalink="https://www.instagram.com/p/DcAlready/",
        caption="A long enough first line to be distinctive prose.\n\n#vellum",
    )
    publication = await publishing.queue(session, live_settings, asset.id, user, scheduled_for=None)
    result = await publishing.run(session, live_settings, publication)

    assert result.media_id == "17899999999999999"
    assert result.published_at == when
    assert "publish_container" not in gram.calls, "it posted a second copy"


async def test_too_soon_leaves_the_row_queued_rather_than_failing_it(
    session: AsyncSession, live_settings, gram
) -> None:
    """Spacing is a wait, not a failure — and it is read from the account because the marketing
    repository posts to the same feed and cannot see this database."""
    user = await make_user(session, display_name="Owner")
    asset = await make_asset(session, user)
    gram.blocked = "The last post on the account went out 12 minutes ago."
    publication = await publishing.queue(session, live_settings, asset.id, user, scheduled_for=None)

    with pytest.raises(publishing.TooSoon):
        await publishing.run(session, live_settings, publication)

    await session.refresh(publication)
    assert publication.status == "scheduled", "a wait must not burn the queued post"
    assert "create_container" not in gram.calls


async def test_a_story_sends_no_caption(session: AsyncSession, live_settings, gram) -> None:
    """There is nowhere on a story for a caption or alt text to appear. Sending them anyway is
    how you end up believing a caption went out when it did not."""
    user = await make_user(session, display_name="Owner")
    asset = await make_asset(session, user, platform="instagram_story")
    publication = await publishing.queue(session, live_settings, asset.id, user, scheduled_for=None)
    await publishing.run(session, live_settings, publication)

    assert gram.story is True
    assert "find_published" not in gram.calls, "a story has no caption to match on"


async def test_the_caption_that_goes_out_carries_the_hashtags(
    session: AsyncSession, live_settings, gram
) -> None:
    user = await make_user(session, display_name="Owner")
    asset = await make_asset(session, user, hashtags=["vellum", "#lettertochild"])
    publication = await publishing.queue(session, live_settings, asset.id, user, scheduled_for=None)
    await publishing.run(session, live_settings, publication)

    assert gram.caption.endswith("#vellum #lettertochild")
    # A hash already on the tag must not become "##".
    assert "##" not in gram.caption


async def test_what_was_published_is_a_snapshot_and_not_a_live_read(
    session: AsyncSession, live_settings, gram
) -> None:
    """An asset stays editable after a post goes out. A ledger that reads the current draft to
    tell you what was published is a ledger that rewrites history."""
    user = await make_user(session, display_name="Owner")
    asset = await make_asset(session, user)
    publication = await publishing.queue(session, live_settings, asset.id, user, scheduled_for=None)
    result = await publishing.run(session, live_settings, publication)
    original = result.caption

    asset.caption = "Rewritten the next morning."
    await session.flush()
    await session.refresh(result)
    assert result.caption == original


# --- The queue --------------------------------------------------------------------------------


async def test_due_returns_immediate_and_past_rows_but_not_future_ones(
    session: AsyncSession, live_settings
) -> None:
    """A NULL `scheduled_for` is due now — that is what an immediate publish writes, and it
    means a request that died between queueing and publishing gets picked up rather than
    sitting forever."""
    user = await make_user(session, display_name="Owner")
    now = dt.datetime.now(tz=dt.UTC)
    immediate = await make_asset(session, user)
    overdue = await make_asset(session, user)
    later = await make_asset(session, user)

    await publishing.queue(session, live_settings, immediate.id, user, scheduled_for=None)
    await publishing.queue(
        session, live_settings, overdue.id, user, scheduled_for=now + dt.timedelta(minutes=5)
    )
    await publishing.queue(
        session, live_settings, later.id, user, scheduled_for=now + dt.timedelta(hours=6)
    )
    # Backdate the middle one; the schema refuses a past time at the API edge, not here.
    rows = await session.execute(
        select(SocialPublication).where(SocialPublication.asset_id == overdue.id)
    )
    rows.scalars().one().scheduled_for = now - dt.timedelta(minutes=5)
    await session.flush()

    due = await publishing.due(session, now=now)
    assert {row.asset_id for row in due} == {immediate.id, overdue.id}


async def test_a_scheduled_post_can_be_cancelled_and_a_published_one_cannot(
    session: AsyncSession, live_settings, gram
) -> None:
    """A button that offers to unpublish would be a lie — that is the Instagram app's job."""
    user = await make_user(session, display_name="Owner")
    queued = await make_asset(session, user)
    posted = await make_asset(session, user)

    waiting = await publishing.queue(
        session,
        live_settings,
        queued.id,
        user,
        scheduled_for=dt.datetime.now(tz=dt.UTC) + dt.timedelta(hours=2),
    )
    cancelled = await publishing.cancel(session, waiting.id)
    assert cancelled.status == "cancelled"

    done = await publishing.run(
        session,
        live_settings,
        await publishing.queue(session, live_settings, posted.id, user, scheduled_for=None),
    )
    with pytest.raises(RascalError) as caught:
        await publishing.cancel(session, done.id)
    assert caught.value.code is ErrorCode.CONFLICT
    assert "Instagram app" in caught.value.message


async def test_cancelling_frees_the_asset_to_be_queued_again(
    session: AsyncSession, live_settings
) -> None:
    user = await make_user(session, display_name="Owner")
    asset = await make_asset(session, user)
    first = await publishing.queue(session, live_settings, asset.id, user, scheduled_for=None)
    await publishing.cancel(session, first.id)
    again = await publishing.queue(session, live_settings, asset.id, user, scheduled_for=None)
    assert again.id != first.id


# --- The credential ---------------------------------------------------------------------------


def test_the_access_token_never_goes_in_a_url() -> None:
    """A real leak, caught before it shipped and pinned here so it cannot come back.

    `httpx` logs the full request URL at INFO. The first version of this module followed Meta's
    own examples and put `access_token=` in the query string, so one `--account` run printed a
    live 185-character token into the structured log three times. Logs go to Fly, to a terminal,
    into a paste, into a screenshot.

    Verified against the live account: bearer auth answers 200 on this host.
    """
    from pathlib import Path

    source = Path(instagram.__file__).read_text()
    body = source.split("async def _call(")[1].split("\ndef ")[0]
    assert "Authorization" in body, "the token is no longer sent as a header"
    assert '"access_token"' not in body, "the access token is back in the request parameters"


async def test_an_instagram_error_becomes_a_readable_refusal(
    session: AsyncSession, live_settings, gram
) -> None:
    """Meta's message is more useful than its status code, and the console shows it. What it
    must never show is a stack trace, a raw payload, or the token."""
    user = await make_user(session, display_name="Owner")
    asset = await make_asset(session, user)
    gram.fail_publish = True
    publication = await publishing.queue(session, live_settings, asset.id, user, scheduled_for=None)
    with pytest.raises(RascalError) as caught:
        await publishing.run(session, live_settings, publication)

    assert caught.value.code is ErrorCode.PUBLISH_FAILED
    assert caught.value.status_code == 502, "this service worked; the thing it called did not"
    assert "a-token" not in caught.value.message


def test_the_publishable_platforms_are_a_subset_of_the_schemas() -> None:
    """A publisher for a platform the schema will not accept is a 500 waiting to happen."""
    from rascal.models.social import SOCIAL_PLATFORMS

    assert set(publishing.PUBLISHABLE) <= set(SOCIAL_PLATFORMS)


def test_the_console_encodes_jpeg_because_instagram_accepts_nothing_else() -> None:
    """Meta publishes JPEG only, and a PNG fails as a container in `ERROR` rather than as a
    message naming the format — so the browser has to get this right with no server to catch
    it. `toPngBlob` stays for the download button; the publish path uses the other one."""
    from pathlib import Path

    import rascal

    cards = (Path(rascal.__file__).parent / "admin/static/cards.js").read_text()
    assert "toJpegBlob" in cards
    assert 'toBlob(resolve, "image/jpeg"' in cards
    assert publishing._CONTENT_TYPE == "image/jpeg"


def test_a_publication_row_is_reachable_from_the_asset_it_belongs_to() -> None:
    """Guards against the table drifting into an orphan log nothing joins back."""
    assert SocialPublication.asset_id.property.columns[0].foreign_keys
    assert uuid.UUID  # the id type the console round-trips


# --- The one place bytes go through the API ---------------------------------------------------


async def test_only_a_real_jpeg_reaches_the_bucket(live_settings, monkeypatch) -> None:
    """`Content-Type` is whatever the caller typed; the magic number is not.

    Meta's failure for a non-JPEG is a container in `ERROR` with no message naming the format,
    so a PNG that got this far would fail much later and much less legibly.
    """
    stored: dict[str, bytes] = {}
    monkeypatch.setattr(publishing, "_put", lambda settings, key, data: stored.update({key: data}))
    asset_id = uuid.uuid4()

    key = await publishing.store_card(live_settings, asset_id, b"\xff\xd8\xff" + b"0" * 100)
    assert key.startswith("social/"), "marketing output must not land in the archive's prefix"
    assert key.endswith(".jpg")
    assert stored[key].startswith(b"\xff\xd8\xff")

    with pytest.raises(RascalError) as caught:
        await publishing.store_card(live_settings, asset_id, b"\x89PNG\r\n\x1a\n" + b"0" * 100)
    assert "not a JPEG" in caught.value.message


async def test_the_card_upload_is_capped(live_settings, monkeypatch) -> None:
    """The cap is what stops this route being a way to put arbitrary bytes into the bucket that
    holds the archive — which is the whole reason this is the one place bytes come through the
    API at all."""
    monkeypatch.setattr(publishing, "_put", lambda settings, key, data: None)
    oversized = b"\xff\xd8\xff" + b"0" * publishing.MAX_CARD_BYTES
    with pytest.raises(RascalError) as caught:
        await publishing.store_card(live_settings, uuid.uuid4(), oversized)
    assert "limit" in caught.value.message


async def test_uploading_a_card_actually_records_where_it_went(
    client, session: AsyncSession, monkeypatch
) -> None:
    """The regression this test exists for was silent, which is why it is a route test.

    The first version wrote the key through `studio.update_asset`, whose `EDITABLE` tuple
    excludes `render_key` — correctly, because a storage key must be written by the code that
    stored the bytes and never by a caller. So the change was filtered out and dropped without
    an error. The publish then refused for an unrelated reason and nothing ever said the image
    had not been recorded.
    """
    from helpers import auth_headers

    monkeypatch.setattr(publishing, "_put", lambda settings, key, data: None)
    admin = await make_user(session, display_name="Owner")
    admin.is_admin = True
    asset = await make_asset(session, admin, render_key=None)
    await session.commit()

    jpeg = b"\xff\xd8\xff" + b"0" * 512
    response = await client.post(
        f"/v1/social/assets/{asset.id}/image",
        content=jpeg,
        headers={**auth_headers(admin), "content-type": "image/jpeg"},
    )
    assert response.status_code == 200, response.text
    key = response.json()["key"]

    await session.refresh(asset)
    assert asset.render_key == key, "the upload did not record where the image went"
    assert asset.render_provider == "card"


async def test_a_png_is_refused_at_the_route(client, session: AsyncSession) -> None:
    from helpers import auth_headers

    admin = await make_user(session, display_name="Owner")
    admin.is_admin = True
    asset = await make_asset(session, admin, render_key=None)
    await session.commit()

    response = await client.post(
        f"/v1/social/assets/{asset.id}/image",
        content=b"\x89PNG\r\n\x1a\n" + b"0" * 512,
        headers={**auth_headers(admin), "content-type": "image/png"},
    )
    assert response.status_code == 422
    assert "not a JPEG" in response.json()["error"]["message"]


# --- Durability: the record has to outlive the request that failed ----------------------------


async def test_a_failed_publish_survives_the_rollback_that_follows_it(
    session: AsyncSession, live_settings, gram
) -> None:
    """**The defect this test exists for made the whole design a comment.**

    `db.get_session` gives one transaction per request and rolls it back on any exception. So a
    `failed` row written with `flush` alone — and the `container_id` written just before the
    irreversible call — were both erased by the very failure they existed to record. Everything
    the module docstring claims about evidence was true only in a unit test that never rolled
    back.

    This simulates what the request actually does: the service raises, and the caller's
    transaction is rolled back on the way out. What the service committed must still be there.
    """
    user = await make_user(session, display_name="Owner")
    asset = await make_asset(session, user)
    gram.fail_publish = True
    publication = await publishing.queue(session, live_settings, asset.id, user, scheduled_for=None)
    publication_id = publication.id

    with pytest.raises(RascalError):
        await publishing.run(session, live_settings, publication)

    # Exactly what `get_session` does when the handler raises.
    await session.rollback()
    session.expunge_all()

    survivor = await session.get(SocialPublication, publication_id)
    assert survivor is not None, "the whole attempt was rolled away"
    assert survivor.status == "failed"
    assert survivor.container_id == "CONTAINER-1", "the container id did not survive"
    assert survivor.error == "Instagram said no."


async def test_too_soon_leaves_a_row_that_really_is_queued(
    session: AsyncSession, live_settings, gram
) -> None:
    """The console says "posting resumes in about N minutes". Something has to make that true.

    Rolled back, the immediate publish's row vanished with the 409 and the sentence described
    nothing — the hourly runner had no row to find.
    """
    user = await make_user(session, display_name="Owner")
    asset = await make_asset(session, user)
    gram.blocked = "The last post on the account went out 12 minutes ago."
    publication = await publishing.queue(session, live_settings, asset.id, user, scheduled_for=None)
    with pytest.raises(publishing.TooSoon):
        await publishing.run(session, live_settings, publication)

    await session.rollback()
    session.expunge_all()

    due = await publishing.due(session)
    assert [row.asset_id for row in due] == [asset.id]
    assert due[0].status == "scheduled"


async def test_publishing_disabled_is_a_type_and_not_a_sentence(
    session: AsyncSession, gram
) -> None:
    """The hourly runner has to tell "switched off" from "broken" without matching on prose."""
    user = await make_user(session, display_name="Owner")
    asset = await make_asset(session, user)
    with pytest.raises(publishing.PublishingDisabled):
        await publishing.queue(session, get_settings(), asset.id, user, scheduled_for=None)


async def test_a_queued_row_whose_problem_is_permanent_fails_rather_than_retrying_forever(
    session: AsyncSession, live_settings, gram
) -> None:
    """Alt text deleted after queueing. Next hour it is still deleted, and the hour after that.

    Left `scheduled`, the machine goes red every hour with something nobody can act on from a
    log. Failing the row puts the reason in the console and stops the alarm.
    """
    user = await make_user(session, display_name="Owner")
    asset = await make_asset(session, user)
    publication = await publishing.queue(
        session,
        live_settings,
        asset.id,
        user,
        scheduled_for=dt.datetime.now(tz=dt.UTC) + dt.timedelta(hours=3),
    )
    asset.alt_text = None
    await session.flush()

    with pytest.raises(RascalError):
        await publishing.run(session, live_settings, publication)
    await session.rollback()
    session.expunge_all()

    settled = await session.get(SocialPublication, publication.id)
    assert settled.status == "failed"
    assert "alt text" in settled.error


async def test_an_asset_marked_published_by_hand_cancels_its_queued_attempt(
    session: AsyncSession, live_settings, gram
) -> None:
    """A scheduled row sits for hours, and `Mark exported`/`published` is a button next to it."""
    user = await make_user(session, display_name="Owner")
    asset = await make_asset(session, user)
    publication = await publishing.queue(
        session,
        live_settings,
        asset.id,
        user,
        scheduled_for=dt.datetime.now(tz=dt.UTC) + dt.timedelta(hours=3),
    )
    asset.published_at = dt.datetime.now(tz=dt.UTC)
    await session.flush()

    with pytest.raises(RascalError) as caught:
        await publishing.run(session, live_settings, publication)
    assert caught.value.code is ErrorCode.CONFLICT
    assert "publish_container" not in gram.calls

    await session.rollback()
    session.expunge_all()
    assert (await session.get(SocialPublication, publication.id)).status == "cancelled"


# --- Reclaiming an abandoned attempt ----------------------------------------------------------


async def _stall(session: AsyncSession, publication: SocialPublication) -> None:
    """Leave a row claimed and unresolved, exactly as a killed process would.

    **The row is not aged; the clock is moved instead**, and the first version of this helper
    got that wrong in a way worth recording. It backdated `updated_at` with raw SQL — and
    `set_updated_at()` is a BEFORE UPDATE trigger, so Postgres overwrote it with `now()` on the
    way in and `reclaim` correctly found nothing. CLAUDE.md's rule that application code never
    writes `updated_at` is not only about tidiness: the column cannot be written from here at
    all.
    """
    publication.status = "publishing"
    publication.container_id = "CONTAINER-STALE"
    await session.commit()
    session.expunge_all()


def _later(minutes: int) -> dt.datetime:
    return dt.datetime.now(tz=dt.UTC) + dt.timedelta(minutes=minutes)


async def test_a_row_abandoned_mid_publish_is_resolved_against_the_account(
    session: AsyncSession, live_settings, gram
) -> None:
    """The price of committing the claim, and the reason the container id is worth storing.

    A process that dies between the claim and the answer leaves `publishing` behind, and the
    partial unique index then refuses to queue anything else for that asset — forever, because
    `cancel()` rightly will not touch a row that might be mid-flight at Meta.
    """
    user = await make_user(session, display_name="Owner")
    asset = await make_asset(session, user)
    publication = await publishing.queue(session, live_settings, asset.id, user, scheduled_for=None)
    await _stall(session, publication)

    gram.already = instagram.Media(
        id="17811111111111111",
        timestamp=dt.datetime(2026, 8, 19, 12, 0, tzinfo=dt.UTC),
        permalink="https://www.instagram.com/p/DcStalled/",
        caption="A long enough first line to be distinctive prose.\n\n#vellum",
    )
    resolved = await publishing.reclaim(session, live_settings, now=_later(30))

    assert [row.status for row in resolved] == ["published"]
    assert resolved[0].media_id == "17811111111111111"
    assert "publish_container" not in gram.calls, "reclaim re-sent a post"


async def test_a_row_abandoned_before_it_posted_frees_its_asset(
    session: AsyncSession, live_settings, gram
) -> None:
    """Not on the account means it never went out. **Never republished** — a container that was
    built and not published is not a post, and re-sending it is the exact duplicate this whole
    service is built to avoid. A person queues the next attempt."""
    user = await make_user(session, display_name="Owner")
    asset = await make_asset(session, user)
    publication = await publishing.queue(session, live_settings, asset.id, user, scheduled_for=None)
    await _stall(session, publication)

    resolved = await publishing.reclaim(session, live_settings, now=_later(30))
    assert [row.status for row in resolved] == ["failed"]
    assert "CONTAINER-STALE" in resolved[0].error
    assert "publish_container" not in gram.calls

    # And the asset is free again, which is the whole point.
    fresh = await session.get(SocialAsset, asset.id)
    again = await publishing.queue(session, live_settings, fresh.id, user, scheduled_for=None)
    assert again.status == "scheduled"


async def test_a_fresh_attempt_is_not_reclaimed_out_from_under_itself(
    session: AsyncSession, live_settings, gram
) -> None:
    """`wait_for_container` can legitimately take half a minute. Reclaiming a row that is still
    in flight would fail a post that is about to succeed."""
    user = await make_user(session, display_name="Owner")
    asset = await make_asset(session, user)
    publication = await publishing.queue(session, live_settings, asset.id, user, scheduled_for=None)
    await _stall(session, publication)
    assert await publishing.reclaim(session, live_settings, now=_later(2)) == []


async def test_an_unreachable_instagram_leaves_a_stalled_row_alone(
    session: AsyncSession, live_settings, gram, monkeypatch
) -> None:
    """Silence is not evidence that nothing was posted. Failing a row we cannot check would
    invite a person to queue a duplicate of something already live."""
    user = await make_user(session, display_name="Owner")
    asset = await make_asset(session, user)
    publication = await publishing.queue(session, live_settings, asset.id, user, scheduled_for=None)
    await _stall(session, publication)

    async def unreachable(settings, caption):
        raise RascalError(ErrorCode.PUBLISH_FAILED, "Could not reach Instagram (ConnectError).")

    monkeypatch.setattr(publishing.instagram, "find_published", unreachable)
    assert await publishing.reclaim(session, live_settings, now=_later(30)) == []
    assert (await session.get(SocialPublication, publication.id)).status == "publishing"


# --- Races and clashes ------------------------------------------------------------------------


async def test_two_attempts_cannot_claim_one_instagram_post(
    session: AsyncSession, live_settings, gram
) -> None:
    """On a shared account `find_published` matches a caption's first line against the whole
    feed, so two assets opening the same way can resolve to one post. That used to raise
    `IntegrityError` and show the console `internal_error` for something entirely explicable."""
    user = await make_user(session, display_name="Owner")
    first = await make_asset(session, user)
    second = await make_asset(session, user)

    one = await publishing.queue(session, live_settings, first.id, user, scheduled_for=None)
    await publishing.run(session, live_settings, one)

    two = await publishing.queue(session, live_settings, second.id, user, scheduled_for=None)
    with pytest.raises(RascalError) as caught:
        await publishing.run(session, live_settings, two)
    assert caught.value.code is ErrorCode.CONFLICT
    assert "already recorded against another attempt" in caught.value.message


# --- Spacing, read from the account -----------------------------------------------------------


def _post(minutes_ago: int, index: int = 0) -> instagram.Media:
    return instagram.Media(
        id=f"1780000000000{index:04d}",
        timestamp=dt.datetime.now(tz=dt.UTC) - dt.timedelta(minutes=minutes_ago),
        permalink=None,
        caption=f"post {index}",
    )


async def test_the_daily_limit_guard_can_actually_fire(live_settings, monkeypatch) -> None:
    """It could not, and that is worse than not having it.

    `spacing` asked Instagram for 50 posts and compared the answer to a limit of 100, so the
    24-hour guard was arithmetically incapable of failing however many posts went out. A check
    that cannot fail still reads like cover in a code review.
    """
    settings = live_settings.model_copy(update={"social_daily_post_limit": 3})
    seen: dict[str, int] = {}

    async def feed(_settings, limit=25):
        seen["limit"] = limit
        return [_post(minutes_ago=60 * (i + 2), index=i) for i in range(3)]

    monkeypatch.setattr(instagram, "recent_media", feed)
    space = await instagram.spacing(settings)

    assert seen["limit"] >= settings.social_daily_post_limit, "it cannot see far enough to fail"
    assert space.posts_in_last_24h == 3
    assert space.blocked_reason is not None
    assert "limit" in space.blocked_reason


async def test_a_recent_post_by_anyone_holds_the_next_one_off(live_settings, monkeypatch) -> None:
    """The account is shared with the marketing repository, so "ours" is not a question this
    can answer — and the sentence says so rather than implying we posted it."""

    async def feed(_settings, limit=25):
        return [_post(minutes_ago=12)]

    monkeypatch.setattr(instagram, "recent_media", feed)
    space = await instagram.spacing(live_settings)
    assert not space.clear
    assert "may not have been ours" in space.blocked_reason


async def test_an_old_enough_last_post_is_clear(live_settings, monkeypatch) -> None:
    async def feed(_settings, limit=25):
        return [_post(minutes_ago=90)]

    monkeypatch.setattr(instagram, "recent_media", feed)
    assert (await instagram.spacing(live_settings)).clear


async def test_an_empty_account_is_clear(live_settings, monkeypatch) -> None:
    """The first post ever must not be held off by a gap measured against nothing."""

    async def feed(_settings, limit=25):
        return []

    monkeypatch.setattr(instagram, "recent_media", feed)
    space = await instagram.spacing(live_settings)
    assert space.clear
    assert space.last_post_at is None


# --- The upload route -------------------------------------------------------------------------


async def test_an_oversized_upload_is_refused_before_it_is_read(
    client, session: AsyncSession, monkeypatch
) -> None:
    """`request.body()` buffers the whole upload first, so a cap checked afterwards has already
    paid for the request it was meant to refuse. The header is what gets checked."""
    from helpers import auth_headers

    admin = await make_user(session, display_name="Owner")
    admin.is_admin = True
    asset = await make_asset(session, admin, render_key=None)
    await session.commit()

    read: list[int] = []
    monkeypatch.setattr(
        publishing, "store_card", lambda *a, **k: read.append(1) or "never/reached.jpg"
    )
    response = await client.post(
        f"/v1/social/assets/{asset.id}/image",
        content=b"\xff\xd8\xff" + b"0" * 32,
        headers={
            **auth_headers(admin),
            "content-type": "image/jpeg",
            "content-length": str(publishing.MAX_CARD_BYTES + 1),
        },
    )
    assert response.status_code == 422
    assert not read, "the body was processed despite an oversized declaration"


async def test_a_lost_race_to_queue_is_a_conflict_not_a_crash(
    session: AsyncSession, live_settings, monkeypatch
) -> None:
    """Two requests, or the web machine and the scheduled one, in the same instant.

    The readable refusal is the Python check; this is the partial unique index underneath it,
    and without the translation a double-click showed the console `internal_error`.
    """
    user = await make_user(session, display_name="Owner")
    asset = await make_asset(session, user)
    await publishing.queue(session, live_settings, asset.id, user, scheduled_for=None)

    # The other request got there between our check and our insert.
    async def blind(_session, _asset_id):
        return None

    monkeypatch.setattr(publishing, "_live_publication", blind)
    with pytest.raises(RascalError) as caught:
        await publishing.queue(session, live_settings, asset.id, user, scheduled_for=None)
    assert caught.value.code is ErrorCode.CONFLICT


# --- The caption is built twice and the two must agree ----------------------------------------


@pytest.mark.parametrize(
    ("tags", "expected"),
    [
        (["vellum"], "#vellum"),
        (["#vellum"], "#vellum"),
        # `lstrip("#")` and the console's old `replace(/^#/, "")` disagreed on this one.
        (["##vellum"], "#vellum"),
        # Untrimmed, this went out as "# vellum " while the confirmation showed "#vellum".
        ([" vellum "], "#vellum"),
        (["", "  ", "#"], ""),
        (["a", "b"], "#a #b"),
    ],
)
async def test_the_hashtags_that_go_out_are_the_ones_the_console_showed(
    session: AsyncSession, tags, expected
) -> None:
    """`admin.js::captionPreview` composes this same string to confirm the post.

    They are two implementations of one rule — strip whitespace, strip any leading hashes, add
    exactly one — and a confirmation that does not match what goes out is worse than none.
    """
    user = await make_user(session, display_name="Owner")
    asset = await make_asset(session, user, caption="Body.", hashtags=tags)
    composed = publishing._full_caption(asset)
    assert composed == (f"Body.\n\n{expected}" if expected else "Body.")


def test_the_console_composes_hashtags_the_same_way() -> None:
    """Read out of `admin.js`, because the rule living in two files is the risk itself."""
    from pathlib import Path

    import rascal

    source = (Path(rascal.__file__).parent / "admin/static/admin.js").read_text()
    preview = source.split("function captionPreview()")[1].split("\n}")[0]
    assert 'replace(/^#+/, "")' in preview, "the console strips only one leading hash"
    assert ".trim()" in preview


async def test_a_cancelled_attempt_cannot_be_resurrected(
    session: AsyncSession, live_settings, gram
) -> None:
    """Somebody decided this should not go out. A stale reference must not undo that."""
    user = await make_user(session, display_name="Owner")
    asset = await make_asset(session, user)
    publication = await publishing.queue(
        session,
        live_settings,
        asset.id,
        user,
        scheduled_for=dt.datetime.now(tz=dt.UTC) + dt.timedelta(hours=2),
    )
    await publishing.cancel(session, publication.id)

    with pytest.raises(RascalError) as caught:
        await publishing.run(session, live_settings, publication)
    assert caught.value.code is ErrorCode.CONFLICT
    assert "publish_container" not in gram.calls


def test_an_error_from_instagram_can_never_carry_the_token() -> None:
    """Belt and braces on a credential.

    The token travels in a header now, so Meta has no obvious reason to echo it — but this
    string is rendered in a console, logged, and pasted into messages, and *"it should not be
    in there"* is not a property worth betting a credential on.
    """
    payload = {"error": {"code": 190, "message": "Invalid token IGAA-secret-value"}}
    detail = instagram._detail(payload, "fallback", "IGAA-secret-value")
    assert "IGAA-secret-value" not in detail
    assert "<redacted>" in detail
    assert "Instagram error 190" in detail


def test_the_console_and_the_service_agree_on_which_platforms_can_publish() -> None:
    """`admin.js` names the publishable platforms a second time, to decide whether to draw the
    section at all — which it must do before there is anything to ask the server.

    Written twice, so asserted, the same way `test_social.py` asserts `cards.js`'s platform
    sizes against `brand.PLATFORM_SIZES`. Adding a publisher server-side and forgetting the
    console would produce a post nobody can send from the screen it was written on.
    """
    from pathlib import Path

    import rascal

    source = (Path(rascal.__file__).parent / "admin/static/admin.js").read_text()
    listed = source.split("function canPublish()")[1].split("\n}")[0]
    for platform in publishing.PUBLISHABLE:
        assert f'"{platform}"' in listed, f"{platform} can publish but the console hides it"
    for platform in ("x", "threads", "facebook", "linkedin", "generic"):
        assert f'"{platform}"' not in listed, f"the console offers {platform} with no publisher"


# --- Two runners, one row ---------------------------------------------------------------------


async def test_two_runners_cannot_both_publish_one_queued_post(
    session: AsyncSession, live_settings, gram
) -> None:
    """**Reading `scheduled` and writing `publishing` are not the same thing.**

    The hourly machine and a hand-run — which the runbook actively encourages — can both
    `SELECT` a due row before either writes anything, then both build a container and both
    publish. Nothing else catches it: the partial unique index guards two *rows* for one asset
    and this is one row twice, and `find_published` is asked by both before either has posted.

    Simulated the way it actually happens: two callers holding the same row, the first winning
    the claim.
    """
    user = await make_user(session, display_name="Owner")
    asset = await make_asset(session, user)
    publication = await publishing.queue(session, live_settings, asset.id, user, scheduled_for=None)
    await publishing.run(session, live_settings, publication)
    assert gram.calls.count("publish_container") == 1

    # The second runner still holds its own read of the row, from before the claim landed.
    stale = await session.get(SocialPublication, publication.id)
    session.expunge(stale)
    stale.status = "scheduled"

    with pytest.raises(RascalError) as caught:
        await publishing.run(session, live_settings, stale)
    assert caught.value.code is ErrorCode.CONFLICT
    assert gram.calls.count("publish_container") == 1, "the second runner posted it again"


async def test_the_claim_is_lost_rather_than_shared(
    session: AsyncSession, live_settings, gram
) -> None:
    """`rowcount` is the whole mechanism, so it is worth asserting directly."""
    user = await make_user(session, display_name="Owner")
    asset = await make_asset(session, user)
    publication = await publishing.queue(session, live_settings, asset.id, user, scheduled_for=None)

    assert await publishing._claim(session, publication) is True
    assert publication.status == "publishing"
    assert publication.attempts == 1
    # A second claim on a row that is no longer `scheduled` must fail rather than re-take it.
    assert await publishing._claim(session, publication) is False
    assert publication.attempts == 1, "a lost claim still counted an attempt"


async def test_no_database_transaction_is_open_while_meta_is_being_called(
    session: AsyncSession, live_settings, gram, monkeypatch
) -> None:
    """A publish can take the better part of a minute — Meta fetches the image on its own time.

    Holding a transaction across that would pin a pooled connection for the whole exchange, and
    on a two-machine deploy with a small pool that is how a slow Instagram becomes a slow
    archive for somebody's phone. The commits that make the attempt durable are also what ends
    the transaction before every network call; this asserts the second property, which is
    otherwise invisible and easy to lose in a refactor.
    """
    open_during: list[str] = []

    async def watched(settings, *, image_url, caption, alt_text, story=False):
        if session.in_transaction():
            open_during.append("create_container")
        return "CONTAINER-1"

    async def watched_publish(settings, container_id):
        if session.in_transaction():
            open_during.append("publish_container")
        return "17900000000000009"

    monkeypatch.setattr(publishing.instagram, "create_container", watched)
    monkeypatch.setattr(publishing.instagram, "publish_container", watched_publish)

    user = await make_user(session, display_name="Owner")
    asset = await make_asset(session, user)
    publication = await publishing.queue(session, live_settings, asset.id, user, scheduled_for=None)
    await publishing.run(session, live_settings, publication)
    assert open_during == [], f"a transaction was open across {open_during}"


async def test_the_upload_route_holds_no_transaction_while_it_waits(
    app, client, session: AsyncSession, engine, monkeypatch
) -> None:
    """A transaction must not be open across the browser upload or the PUT to Tigris.

    The existence check autobegins the request transaction and checks a connection out, and
    `get_session` holds it until the handler returns — so the naive shape keeps it for the whole
    upload. The browser half runs at the *client's* speed: a phone on a train would hold a Neon
    connection for as long as it takes them, and connections are the scarce thing.

    Asserted against the request's own session rather than the pool, because the suite's engine
    uses `NullPool` and has no `checkedout()` to ask — and because an open transaction is the
    property that matters, whatever the pool does with it.
    """
    from sqlalchemy.ext.asyncio import async_sessionmaker

    from helpers import auth_headers
    from rascal import db as db_module

    admin = await make_user(session, display_name="Owner")
    admin.is_admin = True
    asset = await make_asset(session, admin, render_key=None)
    await session.commit()

    factory = async_sessionmaker(bind=engine, expire_on_commit=False, autoflush=False)
    seen: dict[str, AsyncSession] = {}

    async def _capturing():
        async with factory() as request_session:
            seen["session"] = request_session
            try:
                yield request_session
                await request_session.commit()
            except Exception:
                await request_session.rollback()
                raise

    app.dependency_overrides[db_module.get_session] = _capturing

    open_during: list[str] = []

    async def store_card(settings, asset_id, data):
        if seen["session"].in_transaction():
            open_during.append("store_card")
        return "social/2026/08/measured.jpg"

    monkeypatch.setattr(publishing, "store_card", store_card)
    response = await client.post(
        f"/v1/social/assets/{asset.id}/image",
        content=b"\xff\xd8\xff" + b"0" * 64,
        headers={**auth_headers(admin), "content-type": "image/jpeg"},
    )
    assert response.status_code == 200, response.text
    assert open_during == [], "a transaction was open across the upload and the store"

    # And the key still lands, which is the thing the extra commit could have broken.
    await session.refresh(asset)
    assert asset.render_key == "social/2026/08/measured.jpg"


# --- "We could not look" is not "nothing was posted" -------------------------------------------


async def test_a_caption_too_short_to_search_never_reaches_the_account(monkeypatch) -> None:
    """`None` from `find_published` means **searched and absent**, and nothing else.

    The short-circuit used to `return None` before any network call, so a caption whose first
    line was under 25 characters gave the same answer as a completed search that found nothing.
    Those two lead to opposite actions and the return type could not tell them apart.

    **The assertion that matters is that Meta was not asked**, not the return value — the return
    value was `None` either way, which is precisely why the bug survived a review. So the fake
    records whether the account was ever read.
    """
    asked: list[int] = []

    async def feed(_settings, limit=25):
        asked.append(limit)
        return []

    monkeypatch.setattr(instagram, "recent_media", feed)
    with pytest.raises(instagram.NotSearchable):
        await instagram.find_published(get_settings(), "Short hook.\n\nBody follows.")
    assert asked == [], "it asked Instagram and then discarded the answer"

    # A caption that can be searched does reach the account, or the guard above proves nothing.
    assert await instagram.find_published(get_settings(), "A" * 25) is None
    assert asked == [25]


@pytest.mark.parametrize(
    ("first_line", "expected"),
    [
        ("A" * 24, False),
        ("A" * 25, True),
        ("A" * 26, True),
        ("", False),
        ("   " + "A" * 24 + "   ", False),
        ("A" * 25 + "\n\nmore body", True),
    ],
)
def test_the_searchable_threshold_at_its_boundary(first_line: str, expected: bool) -> None:
    """25 is a magic number and the next person to tune it will move it.

    The trigger for the critical was *a caption whose first line is under 25 characters* — an
    ordinary short hook, not an edge case anybody would think to put in a fixture. Which is why
    the boundary is pinned rather than left to a comfortably long caption in another test.
    """
    assert instagram.searchable(first_line) is expected


async def test_an_unsearchable_claim_is_left_standing_rather_than_failed(
    session: AsyncSession, live_settings, gram
) -> None:
    """**The critical this file was extended for.**

    Reclaim's not-published branch prints *"queue it again"*. Reached for a claim nobody could
    check, that sentence is an instruction to duplicate a live post on a public feed — and a
    one-word hook under 25 characters is good caption writing, not an exotic input.

    This is the same invariant `test_an_unreachable_instagram_leaves_a_stalled_row_alone`
    already stated: silence is not evidence. It was enforced for the network-down path and not
    for the cannot-be-asked path.
    """
    user = await make_user(session, display_name="Owner")
    asset = await make_asset(session, user, caption="Short hook.", hashtags=[])
    publication = await publishing.queue(session, live_settings, asset.id, user, scheduled_for=None)
    await _stall(session, publication)

    assert await publishing.reclaim(session, live_settings, now=_later(30)) == []

    settled = await session.get(SocialPublication, publication.id)
    assert settled.status == "publishing", "a claim nobody could check was failed anyway"
    assert "Look at the account" in settled.error
    assert "queue it again when you are ready" not in (settled.error or "").lower()


async def test_a_story_is_never_reported_as_not_published(
    session: AsyncSession, live_settings, gram
) -> None:
    """A story carries no caption at all, so there is no question to ask Instagram about it."""
    user = await make_user(session, display_name="Owner")
    asset = await make_asset(session, user, platform="instagram_story", caption="", hashtags=[])
    publication = await publishing.queue(session, live_settings, asset.id, user, scheduled_for=None)
    await _stall(session, publication)

    assert await publishing.reclaim(session, live_settings, now=_later(30)) == []
    assert (await session.get(SocialPublication, publication.id)).status == "publishing"


async def test_the_failure_message_says_what_was_checked(
    session: AsyncSession, live_settings, gram
) -> None:
    """It used to assert *"the post is not on the account"* — a stronger claim than looking at
    the last 25 posts supports."""
    user = await make_user(session, display_name="Owner")
    asset = await make_asset(session, user)
    publication = await publishing.queue(session, live_settings, asset.id, user, scheduled_for=None)
    await _stall(session, publication)

    resolved = await publishing.reclaim(session, live_settings, now=_later(30))
    assert "most recent posts do not carry this caption" in resolved[0].error


async def test_a_stale_unresolvable_claim_can_be_cancelled_by_a_person(
    session: AsyncSession, live_settings, gram
) -> None:
    """The way out, and without it the partial unique index blocks the asset permanently.

    A fresh claim is genuinely mid-flight and cancelling it would be a guess. A stale one is the
    opposite: nothing is running, `reclaim` could not settle it, and the person pressing cancel
    has the one thing no code here has — they can look at the account.
    """
    user = await make_user(session, display_name="Owner")
    asset = await make_asset(session, user, caption="Short hook.", hashtags=[])
    publication = await publishing.queue(session, live_settings, asset.id, user, scheduled_for=None)

    # Fresh: refused, because it might really be in flight.
    await publishing._claim(session, publication)
    with pytest.raises(RascalError) as caught:
        await publishing.cancel(session, publication.id)
    assert "mid-publish" in caught.value.message

    # Stale: the person decides.
    from sqlalchemy import text as sql

    await session.execute(
        sql("UPDATE social_publications SET status = 'publishing' WHERE id = :i"),
        {"i": publication.id},
    )
    await session.commit()
    session.expunge_all()
    monkey = await session.get(SocialPublication, publication.id)
    # Age the claim by moving the threshold rather than the row: `updated_at` is written by the
    # `set_updated_at()` trigger and cannot be backdated from here.
    original = publishing.STALE_AFTER
    publishing.STALE_AFTER = dt.timedelta(seconds=0)
    try:
        cancelled = await publishing.cancel(session, monkey.id)
    finally:
        publishing.STALE_AFTER = original
    assert cancelled.status == "cancelled"

    # And the asset is free again.
    again = await publishing.queue(session, live_settings, asset.id, user, scheduled_for=None)
    assert again.status == "scheduled"


async def test_an_unsearchable_caption_still_publishes_on_a_first_attempt(
    session: AsyncSession, live_settings, gram
) -> None:
    """Skipping the duplicate lookup is right on a first attempt — there is nothing to be a
    duplicate of yet — and must not become skipping the publish."""
    user = await make_user(session, display_name="Owner")
    asset = await make_asset(session, user, caption="Short hook.", hashtags=[])
    publication = await publishing.queue(session, live_settings, asset.id, user, scheduled_for=None)
    result = await publishing.run(session, live_settings, publication)
    assert result.status == "published"
    assert "find_published" not in gram.calls


# --- The scheduled runner, which is the flag's second entry point -------------------------------
#
# Nothing imported `jobs/social.py` before these. The route was covered and the job was not, and
# they are two different ways to reach the same irreversible call.


@pytest.fixture
def job(monkeypatch, gram):
    """`jobs.social` reads settings and opens its own session, so both are pointed at the test
    database and the fake Instagram before it runs."""
    from rascal.jobs import social as job_module

    def settings_for(enabled: bool):
        return get_settings().model_copy(
            update={
                "ig_user_id": "38177304098550926",
                "ig_access_token": "a-token",
                "social_publish_enabled": enabled,
            }
        )

    def arm(enabled: bool) -> None:
        monkeypatch.setattr(job_module, "get_settings", lambda: settings_for(enabled))

    return type("Job", (), {"module": job_module, "arm": staticmethod(arm)})


async def test_the_job_publishes_nothing_when_the_flag_is_off(
    session: AsyncSession, live_settings, gram, job, capsys
) -> None:
    """**The property the whole design rests on, at the entry point that had no test.**

    The route was covered and the job was not, and a queued row plus a false flag reaches this
    code without going near a request.
    """
    user = await make_user(session, display_name="Owner")
    asset = await make_asset(session, user)
    await publishing.queue(session, live_settings, asset.id, user, scheduled_for=None)
    await session.commit()

    job.arm(False)
    assert await job.module._run(dry_run=False) == 0, "a deliberate off must not go red"
    assert "publish_container" not in gram.calls
    assert "switched off" in capsys.readouterr().out


async def test_the_job_publishes_what_is_due_when_it_is_armed(
    session: AsyncSession, live_settings, gram, job, capsys
) -> None:
    user = await make_user(session, display_name="Owner")
    asset = await make_asset(session, user)
    await publishing.queue(session, live_settings, asset.id, user, scheduled_for=None)
    await session.commit()

    job.arm(True)
    assert await job.module._run(dry_run=False) == 0
    assert gram.calls.count("publish_container") == 1
    assert "published" in capsys.readouterr().out

    session.expunge_all()
    assert (await session.get(SocialAsset, asset.id)).published_at is not None


async def test_a_dry_run_reaches_meta_for_nothing(
    session: AsyncSession, live_settings, gram, job, capsys
) -> None:
    """The rehearsal, and it is flag-independent — which is the correction this phase had to
    make to three places that claimed the flag itself rehearsed."""
    user = await make_user(session, display_name="Owner")
    asset = await make_asset(session, user)
    await publishing.queue(session, live_settings, asset.id, user, scheduled_for=None)
    await session.commit()

    job.arm(True)
    assert await job.module._run(dry_run=True) == 0
    assert gram.calls == [], "a dry run called Instagram"
    assert "would publish" in capsys.readouterr().out


async def test_the_job_holds_off_rather_than_failing_when_it_is_too_soon(
    session: AsyncSession, live_settings, gram, job, capsys
) -> None:
    """A wait is not a fault. Red every hour is how a real alarm stops being read."""
    user = await make_user(session, display_name="Owner")
    asset = await make_asset(session, user)
    await publishing.queue(session, live_settings, asset.id, user, scheduled_for=None)
    await session.commit()
    gram.blocked = "The last post on the account went out 12 minutes ago."

    job.arm(True)
    assert await job.module._run(dry_run=False) == 0
    assert "holding off" in capsys.readouterr().out
    session.expunge_all()
    assert len(await publishing.due(session)) == 1, "the deferred post left the queue"


async def test_an_empty_queue_says_so_rather_than_exiting_silently(gram, job, capsys) -> None:
    """A green tick and an empty log is indistinguishable from a broken schedule — which is how
    a marketing run printing "nothing due" was read as "posted successfully" for hours."""
    job.arm(True)
    assert await job.module._run(dry_run=False) == 0
    assert "nothing due" in capsys.readouterr().out


# --- The routes, through the client -----------------------------------------------------------
#
# Every other assertion in this file calls `publishing.*` directly, which leaves the FastAPI
# wiring unproven: the admin dependency, the read-only guard, the request schema, the shape that
# comes back. These two routes are the ones that reach a public feed.


@pytest.fixture
async def admin_user(session: AsyncSession):
    user = await make_user(session, display_name="Owner")
    user.is_admin = True
    await session.commit()
    return user


async def test_a_stranger_cannot_reach_the_publish_route(client, session: AsyncSession) -> None:
    stranger = await make_user(session, display_name="Nobody")
    asset = await make_asset(session, stranger)
    await session.commit()
    from helpers import auth_headers

    for method, path, body in (
        ("POST", f"/v1/social/assets/{asset.id}/publish", {}),
        ("POST", f"/v1/social/publications/{uuid.uuid4()}/cancel", None),
    ):
        signed_in = await client.request(method, path, json=body, headers=auth_headers(stranger))
        assert signed_in.status_code == 403, f"{path} is reachable by a non-admin"
        anonymous = await client.request(method, path, json=body)
        assert anonymous.status_code == 401, f"{path} is reachable with no token"


async def test_publishing_through_the_route_returns_the_publication(
    app, client, session: AsyncSession, admin_user, live_settings, gram
) -> None:
    """The armed route, end to end through FastAPI — the dependency, the schema, the response.

    Settings are swapped at the dependency rather than on the class: `Settings` is a pydantic
    model and its fields are not class attributes to patch.
    """
    from helpers import auth_headers
    from rascal.config import get_settings as real_settings

    app.dependency_overrides[real_settings] = lambda: live_settings

    asset = await make_asset(session, admin_user)
    await session.commit()

    response = await client.post(
        f"/v1/social/assets/{asset.id}/publish", json={}, headers=auth_headers(admin_user)
    )
    assert response.status_code == 200, response.text
    body = response.json()
    assert body["status"] == "published"
    assert body["media_id"] == "17900000000000001"
    assert body["asset_id"] == str(asset.id)


async def test_a_scheduled_time_in_the_past_is_refused_by_the_schema(
    client, session: AsyncSession, admin_user
) -> None:
    """`PublishIn`'s validator, which nothing exercised through a request. A past time usually
    means somebody got a timezone wrong, and treating it as *now* would post immediately."""
    from helpers import auth_headers

    asset = await make_asset(session, admin_user)
    await session.commit()
    past = (dt.datetime.now(tz=dt.UTC) - dt.timedelta(hours=1)).isoformat()

    response = await client.post(
        f"/v1/social/assets/{asset.id}/publish",
        json={"scheduled_for": past},
        headers=auth_headers(admin_user),
    )
    assert response.status_code == 422
    assert response.json()["error"]["field"] == "scheduled_for"


async def test_cancelling_through_the_route(
    client, session: AsyncSession, admin_user, live_settings, gram
) -> None:
    from helpers import auth_headers

    asset = await make_asset(session, admin_user)
    publication = await publishing.queue(
        session,
        live_settings,
        asset.id,
        admin_user,
        scheduled_for=dt.datetime.now(tz=dt.UTC) + dt.timedelta(hours=2),
    )
    await session.commit()

    response = await client.post(
        f"/v1/social/publications/{publication.id}/cancel", headers=auth_headers(admin_user)
    )
    assert response.status_code == 200, response.text
    assert response.json()["status"] == "cancelled"


# --- Two callers, two transactions, one row ----------------------------------------------------


async def test_two_independent_sessions_cannot_both_claim_one_row(
    session: AsyncSession, engine, live_settings, gram
) -> None:
    """The sequential test above simulates the race with a stale object. This one runs it for
    real: two sessions, two transactions, both holding the same row, both claiming."""
    from sqlalchemy.ext.asyncio import async_sessionmaker

    user = await make_user(session, display_name="Owner")
    asset = await make_asset(session, user)
    publication = await publishing.queue(session, live_settings, asset.id, user, scheduled_for=None)
    await session.commit()

    factory = async_sessionmaker(bind=engine, expire_on_commit=False, autoflush=False)
    async with factory() as one, factory() as two:
        first = await one.get(SocialPublication, publication.id)
        second = await two.get(SocialPublication, publication.id)
        assert first.status == "scheduled" and second.status == "scheduled"

        won = [
            await publishing._claim(one, first),
            await publishing._claim(two, second),
        ]
    assert won == [True, False], "both runners took the same row"
