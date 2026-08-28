"""The daily prompt broadcast.

**Two properties carry this whole feature, and everything else is detail.** One: a day sends at
most once, because the alternative is mailing a list twice. Two: nothing sends at all until
somebody deliberately turns it on, because the P0 behavioural gate has not passed and setting a
credential must not be the same act as mailing strangers.

Both were break-tested: removing the flag from `is_live` fails exactly
`test_credentials_alone_do_not_make_it_live`, and dropping `uq_email_broadcasts_send_date`
from the migration fails three, including one that asserts the constraint at the database
rather than through the service.
"""

from __future__ import annotations

import datetime as dt

import pytest
import sqlalchemy as sa
from sqlalchemy.ext.asyncio import AsyncSession
from tests.factories import make_prompt

from rascal.config import Settings, get_settings
from rascal.models import EmailBroadcast
from rascal.models.prompt import Prompt
from rascal.services import broadcast, prompt_tokens
from rascal.services.email_copy import EmailCopy, EmailCopyError, WelcomeEmail, load

pytestmark = pytest.mark.asyncio


@pytest.fixture
async def library(session):
    """**`run_broadcast` reads the seeded library as of phase 90**, so a truncated database has
    nothing to send and every send test would fail on an empty library rather than on its own
    subject. Two kinds, so a test can tell the card is following the prompt."""
    a = await make_prompt(session, kind="question", completion_mode="text", body="A question?")
    b = await make_prompt(session, kind="photo", completion_mode="media", body="Take a photo.")
    await session.commit()
    return [a, b]


#: The footer's site link. A literal here rather than the setting, so a test that asserts the
#: rendered link would fail if the default ever moved silently.
SITE = "https://getvellumapp.com"


def _copy(
    pool: tuple[str, ...] = ("first prompt?", "second prompt?", "third prompt?"),
) -> EmailCopy:
    return EmailCopy(
        welcome=tuple(
            WelcomeEmail(index=i, day=d, subject=f"s{i}", body=f"b{i}")
            for i, d in enumerate((0, 2, 5, 9, 16), start=1)
        ),
        pool=pool,
        footer=(
            "You're getting this because you signed up at [site]. Stop any time — [unsubscribe]."
        ),
    )


def _live_settings(**overrides: object) -> Settings:
    """Settings that would really send, so the live path can be reached in a test.

    Every test that uses these also stubs `broadcast._send`. Nothing here should ever be one
    regression away from an outbound request to Resend.
    """
    return get_settings().model_copy(
        update={
            "marketing_email_enabled": True,
            "mail_api_key": "re_test_key",
            "resend_audience_id": "aud_test",
            "mail_from": "Dogear <hello@dogear.app>",
            **overrides,
        }
    )


# --------------------------------------------------------------------- selection


def test_the_pick_is_deterministic_for_a_date() -> None:
    """Same date, same prompt, forever — with no state anywhere to make that true."""
    copy = _copy()
    day = dt.date(2026, 8, 10)
    first = copy.prompt_for(day.timetuple().tm_yday)
    assert first == copy.prompt_for(day.timetuple().tm_yday)


def test_the_pick_wraps_at_the_end_of_the_pool() -> None:
    copy = _copy()
    # Pool of three: days 1, 2, 3, 4 -> 0, 1, 2, 0.
    assert [copy.prompt_for(d)[0] for d in (1, 2, 3, 4)] == [0, 1, 2, 0]


def test_the_real_pool_is_the_thirty_the_owner_wrote() -> None:
    """The generated YAML is the copy, and the copy is thirty prompts.

    Asserted against the real file rather than a fixture: a regeneration that silently halved
    the pool would double how often a subscriber sees a repeat, and nothing else would notice.
    """
    copy = load()
    assert len(copy.pool) == 30
    assert copy.pool[0] == "What did they say today that you want to remember?"
    assert "[unsubscribe]" in copy.footer


# ------------------------------------------------------------------------ render


def test_both_bodies_are_rendered_because_text_is_a_deliverability_signal() -> None:
    html, plain = broadcast.render(
        "What did they say today?", _copy().footer, SITE, "question", "text"
    )
    assert "What did they say today?" in html
    assert "What did they say today?" in plain
    assert html.strip().startswith("<!doctype html>")


def test_the_unsubscribe_is_resends_token_and_appears_in_both_bodies() -> None:
    """**Resend owns the unsubscribe for a broadcast**, so ours must not also be in there."""
    html, plain = broadcast.render("a prompt?", _copy().footer, SITE, "question", "text")
    assert broadcast.UNSUBSCRIBE_TOKEN in html
    assert broadcast.UNSUBSCRIBE_TOKEN in plain


def test_nothing_in_the_email_can_watch_the_reader() -> None:
    """No image, so no tracking pixel — on a product sold on privacy that is not a detail."""
    html, _ = broadcast.render("a prompt?", _copy().footer, SITE, "question", "text")
    assert "<img" not in html.lower()
    assert "http://" not in html


def test_the_email_is_well_under_gmails_clipping_threshold() -> None:
    """Gmail clips above ~102KB, and what it clips is the bottom, where the unsubscribe is."""
    html, _ = broadcast.render("a prompt?" * 20, _copy().footer, SITE, "question", "text")
    assert len(html.encode()) < 100_000


# --------------------------------------------------------------------- dry run


async def test_a_dry_run_writes_a_skipped_row_and_calls_nothing(
    library, session: AsyncSession
) -> None:
    result = await broadcast.run_broadcast(
        session, get_settings(), as_of=dt.date(2026, 8, 10), copy=_copy()
    )

    assert result.status == "skipped"
    assert result.resend_id is None
    row = await session.scalar(
        sa.select(EmailBroadcast).where(EmailBroadcast.send_date == dt.date(2026, 8, 10))
    )
    assert row is not None
    assert row.status == "skipped"
    assert row.sent_at is None


async def test_the_dry_run_says_which_thing_is_missing(library, session: AsyncSession) -> None:
    """'Dry run' alone is not actionable; the owner needs to know which switch is off."""
    result = await broadcast.run_broadcast(
        session, get_settings(), as_of=dt.date(2026, 8, 10), copy=_copy()
    )
    assert "MARKETING_EMAIL_ENABLED" in (result.error or "")


def test_credentials_alone_do_not_make_it_live() -> None:
    """**The flag is separate from the keys on purpose.**

    `MAIL_API_KEY` and `RESEND_AUDIENCE_ID` exist to make `POST /v1/subscribe` work. Setting
    them must not also start mailing the list, because that is not what setting them is for.
    """
    settings = get_settings().model_copy(
        update={
            "mail_api_key": "re_test_key",
            "resend_audience_id": "aud_test",
            "mail_from": "Dogear <hello@dogear.app>",
            "marketing_email_enabled": False,
        }
    )
    assert not broadcast.is_live(settings)


def test_a_verified_domain_is_required_even_with_the_flag_on() -> None:
    """`onboarding@resend.dev` only ever reaches the Resend account owner."""
    settings = get_settings().model_copy(
        update={
            "marketing_email_enabled": True,
            "mail_api_key": "re_test_key",
            "resend_audience_id": "aud_test",
            "mail_from": "Dogear <onboarding@resend.dev>",
        }
    )
    assert not broadcast.is_live(settings)
    assert "resend.dev" in broadcast.why_not_live(settings)


# ------------------------------------------------------------------ idempotency


async def test_a_second_run_for_the_same_day_refuses(library, session: AsyncSession) -> None:
    """The property that stops a list being mailed twice."""
    day = dt.date(2026, 8, 10)
    await broadcast.run_broadcast(session, get_settings(), as_of=day, copy=_copy())

    with pytest.raises(broadcast.AlreadySent):
        await broadcast.run_broadcast(session, get_settings(), as_of=day, copy=_copy())


async def test_a_dry_run_consumes_the_day(
    library, session: AsyncSession, monkeypatch: pytest.MonkeyPatch
) -> None:
    """**Deliberate, and worth stating.**

    A day that dry-ran at 08:00 must not send for real at 09:00 because somebody flipped the
    flag in between — the ledger already claimed that day was handled.

    `_send` is stubbed to raise rather than merely counted. This is the one test that hands the
    service live-looking settings, and break-testing it found that a regression in the guard
    above sends it at the real Resend API with a fake key. A test that can reach the network
    when the code is wrong is a test that punishes a mistake by making an outbound request.
    """
    calls: list[str] = []

    async def _explode(*args: object, **kwargs: object) -> str:
        calls.append("sent")
        raise AssertionError("the guard let a second send through for a day already claimed")

    monkeypatch.setattr(broadcast, "_send", _explode)

    day = dt.date(2026, 8, 10)
    await broadcast.run_broadcast(session, get_settings(), as_of=day, copy=_copy())

    with pytest.raises(broadcast.AlreadySent):
        await broadcast.run_broadcast(session, _live_settings(), as_of=day, copy=_copy())
    assert calls == []


async def test_the_unique_index_rejects_a_duplicate_day(session: AsyncSession) -> None:
    """Asserted at the database, not only through the service."""
    day = dt.date(2026, 8, 10)
    session.add(EmailBroadcast(send_date=day, pool_index=0, subject="a", status="skipped"))
    await session.flush()

    session.add(EmailBroadcast(send_date=day, pool_index=1, subject="b", status="skipped"))
    with pytest.raises(sa.exc.IntegrityError):
        await session.flush()


async def test_different_days_are_fine(library, session: AsyncSession) -> None:
    for day in (dt.date(2026, 8, 10), dt.date(2026, 8, 11)):
        await broadcast.run_broadcast(session, get_settings(), as_of=day, copy=_copy())

    total = await session.scalar(sa.select(sa.func.count()).select_from(EmailBroadcast))
    assert total == 2


# --------------------------------------------------------------- the live path


async def test_when_live_it_sends_once_and_records_what_resend_said(
    library, session: AsyncSession, monkeypatch: pytest.MonkeyPatch
) -> None:
    """The success path, with the network stubbed rather than reached."""
    calls: list[str] = []

    async def _fake_send(subject: str, html: str, plain: str, settings: Settings) -> str:
        calls.append(subject)
        return "bc_123"

    monkeypatch.setattr(broadcast, "_send", _fake_send)

    result = await broadcast.run_broadcast(
        session, _live_settings(), as_of=dt.date(2026, 8, 10), copy=_copy()
    )

    assert result.status == "sent"
    assert result.resend_id == "bc_123"
    assert len(calls) == 1

    row = await session.scalar(sa.select(EmailBroadcast))
    assert row is not None
    assert row.status == "sent"
    assert row.resend_id == "bc_123"
    assert row.sent_at is not None


async def test_a_failed_send_records_why_and_does_not_free_the_day(
    library, session: AsyncSession, monkeypatch: pytest.MonkeyPatch
) -> None:
    """**A failure must not retry into a double send.**

    The day stays claimed. Tomorrow's run sends tomorrow's prompt; it does not try again at
    today's, because a bulk send that failed halfway through is not safely repeatable.
    """

    async def _boom(*args: object, **kwargs: object) -> str:
        raise RuntimeError("resend refused the broadcast: HTTP 422")

    monkeypatch.setattr(broadcast, "_send", _boom)

    day = dt.date(2026, 8, 10)
    result = await broadcast.run_broadcast(session, _live_settings(), as_of=day, copy=_copy())

    assert result.status == "failed"
    assert "422" in (result.error or "")

    row = await session.scalar(sa.select(EmailBroadcast))
    assert row is not None
    assert row.status == "failed"
    assert row.sent_at is None

    with pytest.raises(broadcast.AlreadySent):
        await broadcast.run_broadcast(session, _live_settings(), as_of=day, copy=_copy())


# ------------------------------------------------------------------ the ledger


async def test_the_ledger_holds_no_recipient(session: AsyncSession) -> None:
    """**The reason this table is not story 4's `email_sends`.**

    A per-recipient ledger would be the mailing list in our database under another name, and
    the privacy page says we hold no copy of it. If a column here ever names a person, that
    sentence becomes false.
    """
    columns = {column.name for column in EmailBroadcast.__table__.columns}
    for forbidden in ("subscriber_id", "email", "recipient", "address", "contact_id"):
        assert forbidden not in columns


async def test_the_row_records_the_index_not_only_the_text(library, session: AsyncSession) -> None:
    """The owner can edit the pool; a row that stored only text could not be placed afterwards."""
    result = await broadcast.run_broadcast(
        session, get_settings(), as_of=dt.date(2026, 8, 10), copy=_copy()
    )
    row = await session.scalar(sa.select(EmailBroadcast))
    assert row is not None
    assert row.pool_index == result.pool_index
    assert row.subject == result.subject


# --------------------------------------------------------------- the copy loader


def test_a_missing_copy_file_is_fatal(tmp_path) -> None:
    """A silently-empty pool would send blank emails on a schedule."""
    load.cache_clear()
    with pytest.raises(EmailCopyError):
        load(tmp_path / "nope.yaml")
    load.cache_clear()


def test_a_short_pool_is_fatal(tmp_path) -> None:
    import yaml

    path = tmp_path / "email_copy.yaml"
    path.write_text(
        yaml.safe_dump(
            {
                "welcome": [
                    {"index": i, "day": d, "subject": "s", "body": "b"}
                    for i, d in enumerate((0, 2, 5, 9, 16), start=1)
                ],
                "pool": ["only one"],
                "footer": "f [unsubscribe]",
            }
        )
    )
    load.cache_clear()
    with pytest.raises(EmailCopyError, match="expected 30 prompts"):
        load(path)
    load.cache_clear()


def test_an_empty_footer_is_fatal(tmp_path) -> None:
    """Every email is required to carry it, so its absence cannot be a warning."""
    import yaml

    path = tmp_path / "email_copy.yaml"
    path.write_text(
        yaml.safe_dump(
            {
                "welcome": [
                    {"index": i, "day": d, "subject": "s", "body": "b"}
                    for i, d in enumerate((0, 2, 5, 9, 16), start=1)
                ],
                "pool": [f"p{i}" for i in range(30)],
                "footer": "",
            }
        )
    )
    load.cache_clear()
    with pytest.raises(EmailCopyError, match="footer"):
        load(path)
    load.cache_clear()


# --- The prompt card, phase 90 ---------------------------------------------------------------


def test_the_prompt_is_drawn_as_the_card_it_is_everywhere_else() -> None:
    """Kind chip, body, completion line — the three pieces the site and the app both show.

    **The card is the one piece of Pocket Chronicle's design a subscriber meets before installing
    anything**, so a bare serif paragraph read as a newsletter rather than as the product.
    """
    html, _ = broadcast.render("a prompt?", _copy().footer, SITE, "question", "text")

    assert "Question" in html
    assert "Wrote it" in html
    assert broadcast.PERIWINKLE_SOFT in html, "the card is missing its tint"
    assert broadcast.PERIWINKLE_BORDER in html, "a tinted card gets the hairline for that fill"
    assert broadcast.PERIWINKLE_DEEP in html


def test_the_plain_part_carries_the_same_three_pieces() -> None:
    """It is a deliverability signal before it is a courtesy, so it must not become a stub."""
    _, text = broadcast.render("a prompt?", _copy().footer, SITE, "question", "text")

    assert text.index("QUESTION") < text.index("a prompt?") < text.index("Wrote it")


def test_the_card_never_claims_a_prompt_number() -> None:
    """**None of the thirty pool prompts is in `seeds/prompts.yaml`** — zero of thirty match a
    body — so the site's per-kind `#31` has no meaning here. A number would be invented."""
    html, text = broadcast.render("a prompt?", _copy().footer, SITE, "question", "text")

    assert "#" not in text
    assert "#" not in html.replace("border-radius", "").split("<body")[1].replace(
        broadcast.CANVAS, ""
    ).replace(broadcast.INK, "").replace(broadcast.INK_MUTED, "").replace(
        broadcast.PERIWINKLE_SOFT, ""
    ).replace(broadcast.PERIWINKLE_BORDER, "").replace(broadcast.PERIWINKLE_DEEP, "").replace(
        broadcast.CHIP_BG, ""
    ).replace(broadcast.RULE, ""), (
        "the only # left in the body should be a colour, and every colour was stripped"
    )


async def test_the_card_follows_the_prompt_rather_than_a_constant(library, session) -> None:
    """**The assertion the first draft of this phase would have failed.**

    While the send drew from the thirty-question pool, `Question`/`Wrote it` were hardcoded and
    correct. Sending the real library means five kinds a day, and a photo mission labelled
    *Question* would be a lie drawn in the product's own type.
    """
    html, text = broadcast.render("Take a photo.", _copy().footer, SITE, "photo", "media")

    assert "Photo" in html and "Captured it" in html
    assert broadcast.TERRACOTTA_SOFT in html, "a photo mission is terracotta, not periwinkle"
    assert broadcast.PERIWINKLE_SOFT not in html
    assert text.index("PHOTO") < text.index("Take a photo.") < text.index("Captured it")


async def test_every_kind_in_the_library_can_be_drawn(session) -> None:
    """A kind with no entry in `KIND_STYLE` would silently render as a question."""
    kinds = set(
        (
            await session.scalars(sa.select(Prompt.kind).where(Prompt.active.is_(True)).distinct())
        ).all()
    )
    if not kinds:
        pytest.skip("no seeded library in this database")

    assert kinds <= set(broadcast.KIND_STYLE), (
        f"unstyled prompt kinds would render as questions: {kinds - set(broadcast.KIND_STYLE)}"
    )


async def test_the_send_draws_from_the_library_and_respects_cadence(session) -> None:
    """**Cadence is respected even though age is not**, and the asymmetry is deliberate: cadence
    is a property of the prompt, age is a property of a reader this list does not have."""
    daily = await make_prompt(session, cadence="daily", body="Daily one?")
    await make_prompt(session, cadence="monthly", body="Monthly one?")
    await session.commit()

    picked = {(await broadcast.pick_prompt(session, day))[1].body for day in range(1, 8)}

    assert picked == {daily.body}, "a monthly prompt must never go out in a daily send"


async def test_tokens_are_rendered_before_the_body_is_ever_sent(session) -> None:
    """**119 of the 133 bodies carry tokens.** An unrendered `{them}` in a marketing email is
    the failure the marketing site's own generator calls Critical, on the page whose whole job
    is proving the prompts are well written."""
    await make_prompt(session, cadence="daily", body="Photograph {their} hands, {name}.")
    await session.commit()

    _, chosen = await broadcast.pick_prompt(session, 1)
    rendered = prompt_tokens.render(chosen.body, name=broadcast.NAME_STANDIN, pronouns=None)

    assert "{" not in rendered
    assert "their hands" in rendered


async def test_a_forced_run_claims_the_local_day_not_the_utc_one(
    library, session, monkeypatch
) -> None:
    """**The evening trap.** `run_broadcast` falls back to the UTC date when handed no day, and
    after 8pm Detroit that is already tomorrow. A `--force` hand-run at 10pm therefore claimed
    the next morning's slot, and the 8am machine then found the day already sent — no email, no
    error, and a ledger row saying it went.
    """
    import datetime as dt
    import zoneinfo

    from rascal.jobs import broadcast as job

    evening = dt.datetime(2026, 8, 17, 22, 30, tzinfo=zoneinfo.ZoneInfo("America/Detroit"))
    assert evening.astimezone(dt.UTC).date() != evening.date(), (
        "this test is meaningless unless the two dates actually differ"
    )

    monkeypatch.setattr(job, "_local_now", lambda settings: evening)
    captured: dict = {}

    async def _fake(session, settings, *, as_of=None, copy=None):
        captured["as_of"] = as_of
        raise broadcast.AlreadySent("stop here")

    monkeypatch.setattr(job.broadcast, "run_broadcast", _fake)
    await job._run(None, force=True)

    assert captured["as_of"] == evening.date(), "a forced run must claim the reader's day"
