"""The household invite actually leaves the building (phase 136).

**The defect this phase closes was silent by construction.** `POST /families/me/invites` took an
`email`, wrote it to a column, and returned `201`. Nothing sent it — the contract said so, the
schema said so, and the iOS row told a parent they would "get a link to send" — so a parent who
typed their partner's address got a share sheet and their partner got nothing. Every test in the
suite passed throughout, because there was no assertion anywhere that mail was sent.

These are that assertion. They run against the `console` provider, which prints the whole message
instead of opening a socket, so *what was rendered* is testable without a network or a key —
`MAIL_PROVIDER=resend` swaps one adapter underneath and changes nothing here.
"""

from __future__ import annotations

import datetime as dt

import sqlalchemy as sa
from httpx import AsyncClient
from sqlalchemy.ext.asyncio import AsyncSession

from factories import make_child, make_family, make_user
from helpers import auth_headers
from rascal.config import get_settings
from rascal.models import RateLimitEvent, User
from rascal.services import invite_email


async def _subscribed_parent(session: AsyncSession, *, children: list[str] | None = None) -> User:
    family = await make_family(session, tier="subscribed")
    user = await make_user(session, family=family, display_name="Travis")
    # **Distinct birthdates, because the order of the names in the copy is the order
    # `invited_children` returns and that is `ORDER BY birthdate, id`.** Two children sharing
    # the factory's default date fall through to a UUID tiebreak, which made an earlier draft
    # of this file pass alone and fail in a full run — oldest first is the household's order.
    for offset, name in enumerate(children if children is not None else ["Miles"]):
        await make_child(
            session,
            parent=user,
            name=name,
            birthdate=dt.date(2022, 6, 14) + dt.timedelta(days=offset),
        )
    await session.commit()
    return user


def _mail(capsys) -> str:
    """Everything the console provider printed during this test."""
    return capsys.readouterr().out


# --- The send ------------------------------------------------------------------------------


async def test_an_invite_with_an_address_is_mailed(
    client: AsyncClient, session: AsyncSession, capsys
) -> None:
    """The whole point of the phase, stated once: an address in, a message out."""
    user = await _subscribed_parent(session)

    response = await client.post(
        "/v1/families/me/invites",
        json={"email": "Anna@Example.com"},
        headers=auth_headers(user),
    )
    printed = _mail(capsys)

    assert response.status_code == 201
    assert response.json()["email_queued"] is True
    # Lowercased on the way into the column, and that is the address it went to.
    assert "to:       anna@example.com" in printed
    assert "stream:   transactional" in printed


async def test_the_emailed_link_carries_the_raw_token(
    client: AsyncClient, session: AsyncSession, capsys
) -> None:
    """**The link in the inbox has to be the link that works.** A message that arrives with a
    truncated, re-encoded or stale token is a worse failure than no message: it looks delivered.
    """
    user = await _subscribed_parent(session)

    token = (
        await client.post(
            "/v1/families/me/invites",
            json={"email": "anna@example.com"},
            headers=auth_headers(user),
        )
    ).json()["token"]
    printed = _mail(capsys)

    settings = get_settings()
    assert f"{settings.invite_link_base}/{token}" in printed


async def test_no_address_sends_nothing(client: AsyncClient, session: AsyncSession, capsys) -> None:
    """The in-person case stays first-class: a bare link, handed over, no mail at all."""
    user = await _subscribed_parent(session)

    response = await client.post("/v1/families/me/invites", json={}, headers=auth_headers(user))

    assert response.status_code == 201
    assert response.json()["email_queued"] is False
    assert "--- mail" not in _mail(capsys)


async def test_a_refused_invite_mails_nobody(
    client: AsyncClient, session: AsyncSession, capsys
) -> None:
    """A free household meets the paywall, and nothing is sent on the way to it.

    The rate-limit row is written before `issue_invite` runs, so this also asserts the
    transaction rolls that row back rather than charging a household for an invite it was
    refused.
    """
    user = await make_user(session)  # free, no grant
    await session.commit()

    response = await client.post(
        "/v1/families/me/invites",
        json={"email": "anna@example.com"},
        headers=auth_headers(user),
    )

    assert response.status_code == 402
    assert "--- mail" not in _mail(capsys)
    assert await session.scalar(sa.select(sa.func.count()).select_from(RateLimitEvent)) == 0


# --- What the email says -------------------------------------------------------------------


async def test_the_body_names_the_children_and_the_subject_does_not(
    client: AsyncClient, session: AsyncSession, capsys
) -> None:
    """**A subject line shows up on a lock screen; a body does not.**

    The body discloses no more than `GET /invites/{token}` already discloses to whoever is
    holding this link — first names — and the subject stays free of them, because an address
    typed by hand can be mistyped.
    """
    user = await _subscribed_parent(session, children=["Miles", "Nora"])

    await client.post(
        "/v1/families/me/invites",
        json={"email": "anna@example.com"},
        headers=auth_headers(user),
    )
    printed = _mail(capsys)

    subject = next(line for line in printed.splitlines() if line.startswith("subject:"))
    assert "Travis" in subject
    assert "Miles" not in subject and "Nora" not in subject
    assert "Miles and Nora" in printed


async def test_both_a_text_and_an_html_part_are_sent(
    client: AsyncClient, session: AsyncSession, capsys
) -> None:
    """A text alternative is a deliverability signal before it is a courtesy — an HTML-only
    message reads as bulk to the filters that decide whether this arrives at all."""
    user = await _subscribed_parent(session)

    await client.post(
        "/v1/families/me/invites",
        json={"email": "anna@example.com"},
        headers=auth_headers(user),
    )
    printed = _mail(capsys)

    assert "(html alternative)" in printed
    assert "<!doctype html>" in printed


def test_the_copy_keeps_the_products_tone() -> None:
    """No countdown, no scolding, nothing red. `docs/design-system.md` is binding on copy."""
    subject, text, html = invite_email.render(
        inviter="Travis",
        children=["Miles"],
        link="https://example.test/invite/tok",
        site_url="https://pocketchronicle.app",
    )

    for forbidden in ("Hurry", "expires soon", "Don't miss", "!", "Act now"):
        assert forbidden not in subject and forbidden not in text
    # The one option a stranger who was mistyped into this needs.
    assert "you can ignore it" in text
    assert "#C05A2B" in html  # terracotta, the palette's primary action


def test_an_unknown_inviter_and_an_empty_household_still_read_as_sentences() -> None:
    """Both are reachable — a private-relay account that never set a name, and a household that
    subscribed before adding anybody — and a template that assumes either produces the kind of
    copy that only the one person who hits it ever sees."""
    subject, text, _ = invite_email.render(
        inviter=None, children=[], link="https://example.test/invite/tok", site_url="s"
    )

    assert subject == "Someone shared a child's archive with you"
    assert "Someone keeps a record of a childhood" in text
    assert "'s childhood" not in text


def test_three_children_are_joined_the_way_a_person_would() -> None:
    assert invite_email._household(["Miles"]) == "Miles"
    assert invite_email._household(["Miles", "Nora"]) == "Miles and Nora"
    assert invite_email._household(["Miles", "Nora", "Sam"]) == "Miles, Nora and Sam"


def test_a_name_with_markup_in_it_cannot_break_out_of_the_html() -> None:
    """Display names and children's first names are typed by a parent and land in a document.

    The realistic case is an apostrophe in a possessive; the one that matters is an angle
    bracket. The text part takes them raw, because there is no markup there to break out of.
    """
    _, text, markup = invite_email.render(
        inviter="<script>alert(1)</script>",
        children=["Nora & Miles"],
        link="https://example.test/invite/tok",
        site_url="https://pocketchronicle.app",
    )

    assert "<script>" not in markup
    assert "&lt;script&gt;" in markup
    assert "Nora &amp; Miles" in markup
    # The plain part is not a document and is not mangled into one.
    assert "<script>alert(1)</script>" in text


def test_the_link_is_the_path_form_the_app_claims() -> None:
    """`/invite/{token}` in the path, not a query parameter: that is what the association file
    claims (`routers/wellknown.py`) and what the client already builds. A trailing slash in the
    configured base must not produce a double one."""
    settings = get_settings().model_copy(update={"invite_link_base": "https://x.test/invite/"})

    assert invite_email.invite_link(settings, "tok") == "https://x.test/invite/tok"


# --- The limit that has to exist the moment this sends -------------------------------------


async def test_mailing_invites_is_rate_limited(
    client: AsyncClient, session: AsyncSession, capsys
) -> None:
    """**`CLAUDE.md`'s rule, applied the moment the route qualified for it.** This is
    authenticated, and it mails an address the account does not own and has proved nothing
    about — so without a limit, anyone holding a subscription can point our sending reputation
    at a stranger's inbox on repeat.
    """
    user = await _subscribed_parent(session)
    settings = get_settings()

    for _ in range(settings.email_sign_in_per_email_limit):
        allowed = await client.post(
            "/v1/families/me/invites",
            json={"email": "anna@example.com"},
            headers=auth_headers(user),
        )
        assert allowed.status_code == 201

    refused = await client.post(
        "/v1/families/me/invites",
        json={"email": "anna@example.com"},
        headers=auth_headers(user),
    )

    assert refused.status_code == 429
    assert refused.json()["error"]["code"] == "rate_limited"


async def test_a_link_only_invite_is_not_rate_limited(
    client: AsyncClient, session: AsyncSession, capsys
) -> None:
    """The limit is on the mail, not on minting links. Nothing leaves the building without an
    address, so there is nobody to protect from a parent re-issuing one."""
    user = await _subscribed_parent(session)
    settings = get_settings()

    for _ in range(settings.email_sign_in_per_email_limit + 2):
        response = await client.post("/v1/families/me/invites", json={}, headers=auth_headers(user))
        assert response.status_code == 201
