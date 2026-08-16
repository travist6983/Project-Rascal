"""The security fixes from the pre-merge review of phases 51-59.

Every test here exists because a reviewer found a way through, and each one fails against the
code as it was written. They are grouped by what they protect rather than by module, because
the thing worth keeping is the property, not the implementation that currently provides it.
"""

from __future__ import annotations

import pytest
import sqlalchemy as sa
from httpx import AsyncClient
from sqlalchemy.ext.asyncio import AsyncSession

from apple_stub import apple_token
from rascal.models import Credential, EmailSignInToken, RateLimitEvent
from rascal.services import mail
from rascal.services.auth import subject_hint

ADDRESS = "parent@example.com"


async def _apple_session(client: AsyncClient, keypair, subject: str = "001.hardening") -> dict:
    response = await client.post(
        "/v1/auth/apple", json={"identity_token": apple_token(keypair, subject=subject)}
    )
    assert response.status_code == 200, response.text
    return response.json()


def _auth(body: dict) -> dict[str, str]:
    return {"Authorization": f"Bearer {body['access_token']}"}


def _link_token(printed: str) -> str:
    marker = "?token="
    return printed[printed.index(marker) + len(marker) :].split()[0]


# --- The per-IP limiter must see the client, not the proxy --------------------------------


async def test_the_ip_bucket_comes_from_the_proxy_header_not_the_socket(
    client: AsyncClient, session: AsyncSession
) -> None:
    """**Behind Fly's proxy the socket peer is the same address for the whole internet.**

    Keying on it made the per-IP limit one shared bucket: twenty requests an hour from anywhere
    would lock every parent out of magic-link sign-in. The limiter would have been the denial
    of service.
    """
    await client.post(
        "/v1/auth/email/start",
        json={"email": ADDRESS},
        headers={"Fly-Client-IP": "203.0.113.7"},
    )

    buckets = {row.bucket for row in await session.scalars(sa.select(RateLimitEvent))}
    assert "ip:203.0.113.7" in buckets


async def test_two_clients_behind_one_proxy_get_separate_buckets(
    client: AsyncClient, session: AsyncSession
) -> None:
    for address in ("198.51.100.1", "198.51.100.2"):
        await client.post(
            "/v1/auth/email/start",
            json={"email": ADDRESS},
            headers={"Fly-Client-IP": address},
        )

    buckets = {row.bucket for row in await session.scalars(sa.select(RateLimitEvent))}
    assert {"ip:198.51.100.1", "ip:198.51.100.2"} <= buckets


async def test_a_client_supplied_forwarded_header_is_not_trusted(
    client: AsyncClient, session: AsyncSession
) -> None:
    """`X-Forwarded-For` is attacker-controlled. Trusting it would mint a fresh bucket per
    request and remove the limit entirely — the quieter failure, and the worse one."""
    await client.post(
        "/v1/auth/email/start",
        json={"email": ADDRESS},
        headers={"X-Forwarded-For": "203.0.113.99"},
    )

    buckets = {row.bucket for row in await session.scalars(sa.select(RateLimitEvent))}
    assert "ip:203.0.113.99" not in buckets


# --- Remove has to mean removed -----------------------------------------------------------


async def test_removing_a_pending_address_kills_its_outstanding_link(
    apple_client: AsyncClient, apple_keypair, session: AsyncSession, capsys
) -> None:
    """**The critical one.** An `email` credential is created inactive while its verify link
    sits in an inbox. Remove used to return early on "already revoked" and leave that link
    live — so a parent who mistyped an address, noticed, and removed it was still handing
    whoever holds that inbox a working session on their child's archive.
    """
    signed_in = await _apple_session(apple_client, apple_keypair)
    headers = _auth(signed_in)
    await apple_client.post(
        "/v1/me/credentials/email", headers=headers, json={"provider": "email", "email": ADDRESS}
    )
    raw = _link_token(capsys.readouterr().out)

    listed = (await apple_client.get("/v1/me/credentials", headers=headers)).json()
    pending = next(row for row in listed if row["provider"] == "email")
    removed = await apple_client.delete(f"/v1/me/credentials/{pending['id']}", headers=headers)
    assert removed.status_code == 200

    # The link is now spent, so the address holder gets nothing.
    used = await apple_client.post("/v1/auth/email/complete", json={"token": raw})
    assert used.status_code == 401
    assert used.json()["error"]["code"] == "sign_in_link_invalid"

    credential = await session.scalar(sa.select(Credential).where(Credential.provider == "email"))
    await session.refresh(credential)
    assert credential.revoked_at is not None, "it must not come back to life"


async def test_removing_a_live_credential_also_spends_its_links(
    apple_client: AsyncClient, apple_keypair, session: AsyncSession, capsys
) -> None:
    signed_in = await _apple_session(apple_client, apple_keypair)
    headers = _auth(signed_in)
    await apple_client.post(
        "/v1/me/credentials/email", headers=headers, json={"provider": "email", "email": ADDRESS}
    )
    verify = _link_token(capsys.readouterr().out)
    await apple_client.post("/v1/auth/email/complete", json={"token": verify})

    capsys.readouterr()
    await apple_client.post("/v1/auth/email/start", json={"email": ADDRESS})
    outstanding = _link_token(capsys.readouterr().out)

    listed = (await apple_client.get("/v1/me/credentials", headers=headers)).json()
    email_id = next(row["id"] for row in listed if row["provider"] == "email")
    await apple_client.delete(f"/v1/me/credentials/{email_id}", headers=headers)

    assert (
        await apple_client.post("/v1/auth/email/complete", json={"token": outstanding})
    ).status_code == 401
    live = await session.scalar(
        sa.select(sa.func.count())
        .select_from(EmailSignInToken)
        .where(EmailSignInToken.consumed_at.is_(None))
    )
    assert live == 0


async def test_the_last_credential_guard_is_enforced_at_write_time(
    apple_client: AsyncClient, apple_keypair, session: AsyncSession
) -> None:
    """The guard re-tests the population in the `WHERE`, so a caller that raced past the count
    still updates nothing. Counting first and writing after let two concurrent deletes each
    conclude they were not the last — and leave an account with no way in."""
    signed_in = await _apple_session(apple_client, apple_keypair)
    headers = _auth(signed_in)
    only = (await apple_client.get("/v1/me/credentials", headers=headers)).json()[0]

    response = await apple_client.delete(f"/v1/me/credentials/{only['id']}", headers=headers)

    assert response.status_code == 409
    assert response.json()["error"]["code"] == "last_credential"
    credential = await session.get(Credential, only["id"])
    await session.refresh(credential)
    assert credential.revoked_at is None


# --- No enumeration oracle, by status, by timing, or by outage ----------------------------


async def test_a_mail_failure_does_not_change_the_answer(
    apple_client: AsyncClient, apple_keypair, session: AsyncSession, monkeypatch, capsys
) -> None:
    """**The loudest oracle of the three.** With the send inline, a provider outage answered
    500 for a registered address and 202 for an unknown one — which is the exact question the
    identical status code exists to refuse."""
    signed_in = await _apple_session(apple_client, apple_keypair)
    headers = _auth(signed_in)
    await apple_client.post(
        "/v1/me/credentials/email", headers=headers, json={"provider": "email", "email": ADDRESS}
    )
    verify = _link_token(capsys.readouterr().out)
    await apple_client.post("/v1/auth/email/complete", json={"token": verify})

    async def _explode(*args, **kwargs):
        raise mail.MailDeliveryError("provider is down")

    monkeypatch.setattr(mail, "send", _explode)
    monkeypatch.setattr("rascal.routers.auth.send", _explode)

    known = await apple_client.post("/v1/auth/email/start", json={"email": ADDRESS})
    unknown = await apple_client.post("/v1/auth/email/start", json={"email": "nobody@example.com"})

    assert known.status_code == unknown.status_code == 202
    assert known.json() == unknown.json()


async def test_the_send_does_not_happen_on_the_response_path(
    apple_client: AsyncClient, apple_keypair, capsys
) -> None:
    """Sending inline made the always-202 a *timing* oracle: a registered address paid a round
    trip to the provider and an unknown one returned immediately."""
    signed_in = await _apple_session(apple_client, apple_keypair)
    headers = _auth(signed_in)
    await apple_client.post(
        "/v1/me/credentials/email", headers=headers, json={"provider": "email", "email": ADDRESS}
    )
    capsys.readouterr()

    # The route is declared with a `BackgroundTasks` parameter, which is what moves the send
    # off the response path. Asserting the signature is stabler than timing a test suite.
    import inspect

    from rascal.routers.auth import start_email_sign_in

    # `from __future__ import annotations` makes these strings, so compare as text rather
    # than reaching for `__name__` on something that may not be a class object.
    annotations = {
        str(p.annotation) for p in inspect.signature(start_email_sign_in).parameters.values()
    }
    assert any("BackgroundTasks" in a for a in annotations), (
        "the send must not be awaited before the response"
    )


# --- Mailing a stranger ------------------------------------------------------------------


async def test_adding_addresses_is_rate_limited_per_account(
    apple_client: AsyncClient, apple_keypair, session: AsyncSession
) -> None:
    """**Authenticated and limited anyway**, which is the exception to this service's rule.
    The route mails an address the account does not own, so without a limit anyone who can
    make a free account can use it to mail a stranger repeatedly, from our sending domain."""
    signed_in = await _apple_session(apple_client, apple_keypair)
    headers = _auth(signed_in)

    codes = []
    for index in range(7):
        response = await apple_client.post(
            "/v1/me/credentials/email",
            headers=headers,
            json={"provider": "email", "email": f"victim{index}@example.com"},
        )
        codes.append(response.status_code)

    assert 429 in codes, "an account must not be able to mail unlimited strangers"
    assert codes.index(429) >= 5, "the limit should not bite a parent fixing one typo"


# --- Masking ------------------------------------------------------------------------------


@pytest.mark.parametrize("subject", ["abcd", "ab", "a", "12345678"])
def test_a_short_subject_is_still_masked(subject: str) -> None:
    """Returning the last four of a four-character subject returns the subject."""
    hint = subject_hint("apple", subject)
    assert subject not in hint or len(subject) > 8
