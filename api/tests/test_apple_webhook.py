"""Apple's server-to-server notifications (phase 53).

**The sharpest test in here is `test_a_forged_notification_is_refused`.** This route has no
bearer token, so the signature is the entire authorization story: if it can be skipped, anyone
who knows an Apple `sub` can revoke a stranger's session. It is the same class of defect as an
`aud` check that does not check, and it is invisible until somebody tries it.

**The second sharpest is `test_account_delete_never_touches_the_archive`.** Apple saying an
Apple ID was deleted is not a parent asking for a child's archive to be deleted, and the
handling being *identical* to `consent-revoked` is a decision rather than a copy-paste — see
`docs/decisions.md` and `services/apple_events.py`.
"""

from __future__ import annotations

import datetime as dt
import json
import uuid

import jwt
import pytest
import sqlalchemy as sa
from cryptography.hazmat.primitives.asymmetric import rsa
from httpx import AsyncClient
from sqlalchemy.ext.asyncio import AsyncSession

from apple_stub import KEY_ID, apple_token
from rascal.config import get_settings
from rascal.models import Child, Credential, Entry, RefreshToken, User

SUBJECT = "001.notification-subject"


def notification(
    apple_keypair,
    *,
    event_type: str = "consent-revoked",
    subject: str = SUBJECT,
    email: str | None = None,
    audience: str | None = None,
    issuer: str = "https://appleid.apple.com",
    event_time: int | None = None,
    kid: str = KEY_ID,
    key: rsa.RSAPrivateKey | None = None,
    events_as_object: bool = False,
) -> str:
    """One notification, signed the way Apple signs them.

    `events` is a JSON **string** inside the claims, not an object. That is genuinely how
    Apple sends it, and `events_as_object=True` exists only so a test can prove the decoder
    does not silently accept the shape somebody would assume from reading the docs quickly.
    """
    private, _ = apple_keypair
    now = dt.datetime.now(tz=dt.UTC)
    event = {
        "type": event_type,
        "sub": subject,
        # Milliseconds. Apple's own field, and the trap in it.
        "event_time": event_time if event_time is not None else int(now.timestamp() * 1000),
    }
    if email is not None:
        event["email"] = email
    claims = {
        "iss": issuer,
        "aud": audience or get_settings().apple_bundle_id[0],
        "iat": int(now.timestamp()),
        "jti": str(uuid.uuid4()),
        "events": event if events_as_object else json.dumps(event),
    }
    return jwt.encode(claims, key or private, algorithm="RS256", headers={"kid": kid})


async def _sign_in(client: AsyncClient, keypair, subject: str = SUBJECT) -> dict:
    response = await client.post(
        "/v1/auth/apple", json={"identity_token": apple_token(keypair, subject=subject)}
    )
    assert response.status_code == 200, response.text
    return response.json()


async def _post(client: AsyncClient, payload: str):
    return await client.post("/v1/webhooks/apple-signin", json={"payload": payload})


# --- The signature is the whole authorization story ---------------------------------------


async def test_a_forged_notification_is_refused(
    apple_client: AsyncClient, apple_keypair, session: AsyncSession
) -> None:
    """Same `kid`, different key. Without a real signature check this route is a way to
    revoke any session belonging to anyone whose Apple `sub` you can guess or observe."""
    await _sign_in(apple_client, apple_keypair)
    impostor = rsa.generate_private_key(public_exponent=65537, key_size=2048)

    response = await _post(apple_client, notification(apple_keypair, key=impostor))

    assert response.status_code == 401
    assert response.json()["error"]["code"] == "unauthenticated"
    credential = await session.scalar(sa.select(Credential))
    await session.refresh(credential)
    assert credential.revoked_at is None, "a forged notification must change nothing"


async def test_a_notification_for_another_audience_is_refused(
    apple_client: AsyncClient, apple_keypair
) -> None:
    response = await _post(apple_client, notification(apple_keypair, audience="com.someone.else"))
    assert response.status_code == 401


async def test_a_notification_from_another_issuer_is_refused(
    apple_client: AsyncClient, apple_keypair
) -> None:
    response = await _post(apple_client, notification(apple_keypair, issuer="https://evil.test"))
    assert response.status_code == 401


async def test_an_unknown_key_id_is_refused(apple_client: AsyncClient, apple_keypair) -> None:
    response = await _post(apple_client, notification(apple_keypair, kid="not-a-real-kid"))
    assert response.status_code == 401


async def test_a_malformed_payload_is_refused(apple_client: AsyncClient) -> None:
    response = await _post(apple_client, "not-a-jwt")
    assert response.status_code == 401


async def test_the_route_takes_no_bearer_token(apple_client: AsyncClient, apple_keypair) -> None:
    """Authenticated by signature, so an absent Authorization header is the normal case."""
    await _sign_in(apple_client, apple_keypair)
    await _post(apple_client, notification(apple_keypair, event_type="email-disabled"))
    # It is not merely tolerated — no request here has ever sent one, and they all worked.
    assert True


# --- Revocation -----------------------------------------------------------------------------


@pytest.mark.parametrize("event_type", ["consent-revoked", "account-delete"])
async def test_revocation_events_revoke_the_credential_and_every_session(
    apple_client: AsyncClient, apple_keypair, session: AsyncSession, event_type: str
) -> None:
    signed_in = await _sign_in(apple_client, apple_keypair)

    response = await _post(apple_client, notification(apple_keypair, event_type=event_type))
    assert response.status_code == 202
    assert response.json()["status"] == "revoked"

    credential = await session.scalar(sa.select(Credential))
    await session.refresh(credential)
    assert credential.revoked_at is not None

    # Every refresh token is dead, so the session does not outlive the credential. Without
    # this, revoking while the app is closed leaves it signed in for up to thirty days.
    live = await session.scalars(sa.select(RefreshToken).where(RefreshToken.revoked_at.is_(None)))
    assert list(live) == []
    refused = await apple_client.post(
        "/v1/auth/refresh", json={"refresh_token": signed_in["refresh_token"]}
    )
    assert refused.status_code == 401


async def test_account_delete_never_touches_the_archive(
    apple_client: AsyncClient, apple_keypair, session: AsyncSession
) -> None:
    """**The decision this phase exists to encode.** Apple is telling us an Apple ID is gone.
    It is not telling us a childhood is, and it has no standing to."""
    signed_in = await _sign_in(apple_client, apple_keypair)
    headers = {"Authorization": f"Bearer {signed_in['access_token']}"}
    created = await apple_client.post(
        "/v1/children",
        headers=headers,
        json={"name": "Rascal", "birthdate": "2022-08-01", "family_timezone": "America/Detroit"},
    )
    assert created.status_code == 201
    child_id = created.json()["id"]
    entry = await apple_client.post(
        "/v1/entries",
        headers=headers,
        json={
            "id": str(uuid.uuid4()),
            "child_id": child_id,
            "completion_mode": "did_it",
            "occurred_at": "2026-08-01T12:00:00Z",
        },
    )
    assert entry.status_code == 201

    await _post(apple_client, notification(apple_keypair, event_type="account-delete"))

    assert await session.scalar(sa.select(sa.func.count()).select_from(User)) == 1
    assert await session.scalar(sa.select(sa.func.count()).select_from(Child)) == 1
    assert (
        await session.scalar(
            sa.select(sa.func.count()).select_from(Entry).where(Entry.deleted_at.is_(None))
        )
        == 1
    )


async def test_a_revoked_account_signs_back_in_to_the_same_archive(
    apple_client: AsyncClient, apple_keypair, session: AsyncSession
) -> None:
    """Recoverability is what makes treating `account-delete` as credential-gone safe."""
    signed_in = await _sign_in(apple_client, apple_keypair)
    await _post(apple_client, notification(apple_keypair, event_type="consent-revoked"))

    returned = await _sign_in(apple_client, apple_keypair)

    assert returned["user"]["id"] == signed_in["user"]["id"]
    assert await session.scalar(sa.select(sa.func.count()).select_from(User)) == 1
    credential = await session.scalar(sa.select(Credential))
    await session.refresh(credential)
    assert credential.revoked_at is None


async def test_a_repeated_revocation_keeps_the_first_timestamp(
    apple_client: AsyncClient, apple_keypair, session: AsyncSession
) -> None:
    """Apple retries. A retry must not move a revocation forward in time."""
    await _sign_in(apple_client, apple_keypair)
    await _post(apple_client, notification(apple_keypair, event_type="consent-revoked"))
    credential = await session.scalar(sa.select(Credential))
    await session.refresh(credential)
    first = credential.revoked_at

    await _post(apple_client, notification(apple_keypair, event_type="consent-revoked"))
    await session.refresh(credential)
    assert credential.revoked_at == first


# --- Email deliverability -------------------------------------------------------------------


async def test_email_disabled_and_enabled_move_the_interlock(
    apple_client: AsyncClient, apple_keypair, session: AsyncSession
) -> None:
    """`email_deliverable` is what makes a silently-dead relay audible to phase 38."""
    await _sign_in(apple_client, apple_keypair)
    user = await session.scalar(sa.select(User))
    await session.refresh(user)
    assert user.email_deliverable is True, "an existing account is deliverable until told otherwise"

    disabled = await _post(apple_client, notification(apple_keypair, event_type="email-disabled"))
    assert disabled.status_code == 202
    await session.refresh(user)
    assert user.email_deliverable is False

    enabled = await _post(apple_client, notification(apple_keypair, event_type="email-enabled"))
    assert enabled.status_code == 202
    await session.refresh(user)
    assert user.email_deliverable is True


async def test_email_events_never_revoke_anything(
    apple_client: AsyncClient, apple_keypair, session: AsyncSession
) -> None:
    """A relay being switched off is not a withdrawal of consent, and must not read as one."""
    signed_in = await _sign_in(apple_client, apple_keypair)
    await _post(apple_client, notification(apple_keypair, event_type="email-disabled"))

    credential = await session.scalar(sa.select(Credential))
    await session.refresh(credential)
    assert credential.revoked_at is None
    still_good = await apple_client.post(
        "/v1/auth/refresh", json={"refresh_token": signed_in["refresh_token"]}
    )
    assert still_good.status_code == 200


async def test_email_deliverable_is_not_exposed_or_settable_through_the_api(
    apple_client: AsyncClient, apple_keypair, session: AsyncSession
) -> None:
    """Apple owns this column. A client that could set it could silence its own warnings."""
    signed_in = await _sign_in(apple_client, apple_keypair)
    headers = {"Authorization": f"Bearer {signed_in['access_token']}"}
    assert "email_deliverable" not in signed_in["user"]

    response = await apple_client.patch(
        "/v1/me", headers=headers, json={"email_deliverable": False}
    )
    user = await session.scalar(sa.select(User))
    await session.refresh(user)
    assert user.email_deliverable is True
    assert response.status_code in {200, 422}


# --- What a webhook has to tolerate ---------------------------------------------------------


async def test_an_unknown_subject_is_acknowledged_rather_than_404(
    apple_client: AsyncClient, apple_keypair
) -> None:
    """Apple retries anything that is not 2xx, and a 404 here would tell an unauthenticated
    caller which Apple IDs have accounts."""
    response = await _post(apple_client, notification(apple_keypair, subject="001.nobody"))
    assert response.status_code == 202
    assert response.json()["status"] == "ignored:unknown-subject"


async def test_an_unhandled_event_type_is_acknowledged(
    apple_client: AsyncClient, apple_keypair
) -> None:
    """Apple may add types. Refusing one would have it retried forever."""
    await _sign_in(apple_client, apple_keypair)
    response = await _post(apple_client, notification(apple_keypair, event_type="something-new"))
    assert response.status_code == 202
    assert response.json()["status"] == "ignored:unhandled-type"


async def test_the_event_time_is_read_as_milliseconds(
    apple_client: AsyncClient, apple_keypair, session: AsyncSession
) -> None:
    """Read as seconds this lands in the year 56000, and every comparison against it is wrong."""
    await _sign_in(apple_client, apple_keypair)
    moment = dt.datetime(2026, 8, 1, 12, 0, tzinfo=dt.UTC)

    await _post(
        apple_client,
        notification(
            apple_keypair,
            event_type="consent-revoked",
            event_time=int(moment.timestamp() * 1000),
        ),
    )

    credential = await session.scalar(sa.select(Credential))
    await session.refresh(credential)
    assert credential.revoked_at == moment


async def test_an_events_object_rather_than_a_json_string_is_still_read(
    apple_client: AsyncClient, apple_keypair, session: AsyncSession
) -> None:
    """Apple sends `events` as a JSON string. Accepting an object too costs one isinstance and
    means a change at Apple's end is not an outage here."""
    await _sign_in(apple_client, apple_keypair)
    response = await _post(
        apple_client,
        notification(apple_keypair, event_type="email-disabled", events_as_object=True),
    )
    assert response.status_code == 202
    user = await session.scalar(sa.select(User))
    await session.refresh(user)
    assert user.email_deliverable is False


async def test_an_unreadable_event_is_refused(apple_client: AsyncClient, apple_keypair) -> None:
    private, _ = apple_keypair
    now = dt.datetime.now(tz=dt.UTC)
    payload = jwt.encode(
        {
            "iss": "https://appleid.apple.com",
            "aud": get_settings().apple_bundle_id[0],
            "iat": int(now.timestamp()),
            "events": "not json at all",
        },
        private,
        algorithm="RS256",
        headers={"kid": KEY_ID},
    )
    response = await _post(apple_client, payload)
    assert response.status_code == 401


# --- Phase 93: the assumption underneath all of the above ----------------------------------


async def test_a_changed_subject_after_a_revoke_is_a_second_account(
    apple_client: AsyncClient, apple_keypair, session: AsyncSession
) -> None:
    """**The failure mode, pinned. This test asserts what breaks, not what works.**

    Every recoverability claim on this route rests on one unobserved assumption: that Apple's `sub`
    is the *same value* after a user revokes the app and signs back in. `blocked.md` §11 records
    that nobody has ever run that experiment against a real Apple ID, and no test can settle it —
    the suite signs its own tokens, so it can only ever assert the behaviour it chose to simulate.

    What a test *can* do is make the consequence executable rather than a paragraph. If the
    assumption is wrong, the parent does not get an error: they get a **second, empty archive**, and
    the first one becomes unreachable through the only credential they have. That is not a bug in
    this code — the server deliberately never links accounts by email address, and `ios/CLAUDE.md`
    says so of the client too — it is the cost of the design, and it should be visible in the suite
    next to the tests that assume it away.

    Sibling to `test_a_revoked_account_signs_back_in_to_the_same_archive`, which asserts the same
    sequence with a stable subject and is the happy path this one is the shadow of.
    """
    first = await _sign_in(apple_client, apple_keypair, subject="001.before-revoke")
    created = await apple_client.post(
        "/v1/children",
        json={"name": "Ada", "birthdate": "2022-03-04", "family_timezone": "America/New_York"},
        headers={"Authorization": f"Bearer {first['access_token']}"},
    )
    assert created.status_code in (200, 201), created.text

    await _post(
        apple_client,
        notification(apple_keypair, event_type="consent-revoked", subject="001.before-revoke"),
    )

    # The same human, the same device, a different `sub`. This is the branch nobody has observed.
    second = await _sign_in(apple_client, apple_keypair, subject="001.after-revoke")

    assert second["user"]["id"] != first["user"]["id"], (
        "a changed subject is a different person as far as this server is concerned"
    )
    assert await session.scalar(sa.select(sa.func.count()).select_from(User)) == 2
    assert await session.scalar(sa.select(sa.func.count()).select_from(Credential)) == 2

    # The consequence, stated as the parent would meet it: the archive is still there, and the
    # only credential they have cannot see it.
    visible = await apple_client.get(
        "/v1/children", headers={"Authorization": f"Bearer {second['access_token']}"}
    )
    assert visible.status_code == 200
    assert visible.json() == [], "the second account is empty"
    assert await session.scalar(sa.select(sa.func.count()).select_from(Child)) == 1, (
        "and the first child still exists, owned by a user nobody can sign in as"
    )


async def test_nothing_links_the_two_accounts_by_email(
    apple_client: AsyncClient, apple_keypair, session: AsyncSession
) -> None:
    """The obvious repair is the one that must not exist.

    Linking by email would silently join two accounts on a value the user can change and Apple can
    relay privately, which is why `POST /me/credentials` requires somebody to be signed in and ask.
    This asserts the absence, so that "just match on email" fails a test rather than a review.
    """
    first = await _sign_in(apple_client, apple_keypair, subject="001.first-sub")
    second = await _sign_in(apple_client, apple_keypair, subject="001.second-sub")

    assert first["user"]["id"] != second["user"]["id"]
    assert await session.scalar(sa.select(sa.func.count()).select_from(User)) == 2
