"""Credential linking: `/me/credentials`, and the revocation state behind it (phase 52).

The assertion this whole design turns on is
`test_a_revoked_subject_signing_in_again_lands_on_the_same_user`. Everything else here is a
guard around it. If a revoked credential stopped matching its own subject, a parent who
removed the app from their Apple ID and came back would be handed a brand-new, empty account,
and eighteen years of their child's life would sit behind a `users` row nothing could reach.

The Apple JWKS scaffolding is shared with `test_auth.py` rather than rebuilt, the same way
`test_export_viewer.py` borrows from `test_export.py`.
"""

from __future__ import annotations

import sqlalchemy as sa
from httpx import AsyncClient
from sqlalchemy.ext.asyncio import AsyncSession

from apple_stub import apple_token
from rascal.models import Credential, User

FIRST = "001.first-apple-subject"
SECOND = "001.second-apple-subject"


async def _sign_in(client: AsyncClient, keypair, subject: str, **kwargs) -> dict:
    response = await client.post(
        "/v1/auth/apple",
        json={"identity_token": apple_token(keypair, subject=subject, **kwargs)},
    )
    assert response.status_code == 200, response.text
    return response.json()


def _auth(session_body: dict) -> dict[str, str]:
    return {"Authorization": f"Bearer {session_body['access_token']}"}


async def _attach(client: AsyncClient, headers: dict, keypair, subject: str, **kwargs):
    return await client.post(
        "/v1/me/credentials",
        headers=headers,
        json={
            "provider": "apple",
            "identity_token": apple_token(keypair, subject=subject, **kwargs),
        },
    )


# --- Listing ------------------------------------------------------------------------------


async def test_a_fresh_account_lists_the_one_credential_it_signed_in_with(
    apple_client: AsyncClient, apple_keypair
) -> None:
    signed_in = await _sign_in(apple_client, apple_keypair, FIRST)

    listed = await apple_client.get("/v1/me/credentials", headers=_auth(signed_in))
    assert listed.status_code == 200
    body = listed.json()
    assert len(body) == 1
    assert body[0]["provider"] == "apple"
    assert body[0]["revoked_at"] is None


async def test_the_list_never_returns_a_raw_subject_id(
    apple_client: AsyncClient, apple_keypair
) -> None:
    """A `subject_id` identifies the account to Apple. Listing sign-in methods is not a reason
    to hand it back, and the hint has to be useful without being the thing itself."""
    signed_in = await _sign_in(apple_client, apple_keypair, FIRST)
    listed = await apple_client.get("/v1/me/credentials", headers=_auth(signed_in))

    row = listed.json()[0]
    assert "subject_id" not in row
    assert FIRST not in listed.text
    # Still enough to tell two Apple credentials apart.
    assert row["subject_hint"].endswith(FIRST[-4:])


async def test_the_list_never_returns_the_stored_apple_refresh_token(
    apple_client: AsyncClient, apple_keypair, session: AsyncSession
) -> None:
    """**Stricter than the rule above it, and for a bigger reason.** A `subject_id` identifies
    the account to Apple; the refresh token phase 127 stores is a live credential Apple will
    *act* on. `CredentialOut` is an allowlist rather than an exclusion, which is what makes the
    absence structural — this asserts it anyway, because the cost of being wrong is a working
    key in a response body."""
    signed_in = await _sign_in(apple_client, apple_keypair, FIRST)
    credential = await session.scalar(sa.select(Credential))
    credential.apple_refresh_token = "s3cret-refresh-token"
    await session.commit()

    listed = await apple_client.get("/v1/me/credentials", headers=_auth(signed_in))

    assert listed.status_code == 200
    assert "apple_refresh_token" not in listed.text
    assert "s3cret-refresh-token" not in listed.text


async def test_credentials_require_a_bearer_token(apple_client: AsyncClient) -> None:
    for method, path in (
        ("get", "/v1/me/credentials"),
        ("post", "/v1/me/credentials"),
        ("delete", "/v1/me/credentials/00000000-0000-0000-0000-000000000000"),
    ):
        response = await getattr(apple_client, method)(path)
        assert response.status_code == 401, f"{method} {path}"
        assert response.json()["error"]["code"] == "unauthenticated"


# --- Attaching ----------------------------------------------------------------------------


async def test_attaching_a_second_credential_shows_two_in_the_list(
    apple_client: AsyncClient, apple_keypair, session: AsyncSession
) -> None:
    signed_in = await _sign_in(apple_client, apple_keypair, FIRST)
    headers = _auth(signed_in)

    attached = await _attach(apple_client, headers, apple_keypair, SECOND)
    assert attached.status_code == 200, attached.text

    listed = await apple_client.get("/v1/me/credentials", headers=headers)
    assert len(listed.json()) == 2
    # Two credentials, still one account. Attaching is not a way to make a second user.
    assert await session.scalar(sa.select(sa.func.count()).select_from(User)) == 1


async def test_attaching_a_subject_bound_elsewhere_is_a_409_and_writes_nothing(
    apple_client: AsyncClient, apple_keypair, session: AsyncSession
) -> None:
    """Never merged, never reassigned. Two archives with one key between them has no answer."""
    first = await _sign_in(apple_client, apple_keypair, FIRST)
    await _sign_in(apple_client, apple_keypair, SECOND)

    before = await session.scalar(sa.select(sa.func.count()).select_from(Credential))
    assert before == 2

    response = await _attach(apple_client, _auth(first), apple_keypair, SECOND)
    assert response.status_code == 409
    assert response.json()["error"]["code"] == "credential_in_use"

    after = await session.scalar(sa.select(sa.func.count()).select_from(Credential))
    assert after == 2, "a refused attach must not leave a row behind"
    # And the credential still belongs to the account it belonged to before.
    owner = await session.scalar(
        sa.select(Credential.user_id).where(Credential.subject_id == SECOND)
    )
    assert owner != first["user"]["id"]


async def test_attaching_a_subject_already_on_this_account_is_an_idempotent_200(
    apple_client: AsyncClient, apple_keypair, session: AsyncSession
) -> None:
    """A client retrying a request it never saw the answer to must not be punished for it."""
    signed_in = await _sign_in(apple_client, apple_keypair, FIRST)
    headers = _auth(signed_in)

    again = await _attach(apple_client, headers, apple_keypair, FIRST)
    assert again.status_code == 200

    assert await session.scalar(sa.select(sa.func.count()).select_from(Credential)) == 1


async def test_a_provider_with_no_verifier_yet_is_refused_by_the_schema(
    apple_client: AsyncClient, apple_keypair
) -> None:
    """A provider the schema does not yet permit is a 422 naming the field.

    **This asked about `google` until phase 54 built a verifier for it**, which is the rule
    working rather than the test weakening: the schema widens beside the thing that can verify
    the token, never ahead of it. `email` is the one still waiting, and it waits on phase 57 —
    where an address is proved by a clicked link rather than by a token at all.
    """
    signed_in = await _sign_in(apple_client, apple_keypair, FIRST)
    response = await apple_client.post(
        "/v1/me/credentials",
        headers=_auth(signed_in),
        json={"provider": "email", "identity_token": apple_token(apple_keypair, subject=SECOND)},
    )
    assert response.status_code == 422
    assert response.json()["error"]["field"] == "provider"


async def test_attaching_an_unverifiable_token_is_a_401_and_writes_nothing(
    apple_client: AsyncClient, apple_keypair, session: AsyncSession
) -> None:
    """Attaching verifies exactly as signing in does — the field is a token, not a claim."""
    signed_in = await _sign_in(apple_client, apple_keypair, FIRST)
    response = await _attach(
        apple_client, _auth(signed_in), apple_keypair, SECOND, audience="com.someone.else"
    )
    assert response.status_code == 401
    assert await session.scalar(sa.select(sa.func.count()).select_from(Credential)) == 1


async def test_attaching_fills_a_null_name_and_never_overwrites_one(
    apple_client: AsyncClient, apple_keypair, session: AsyncSession
) -> None:
    """Gap-fill is first-non-null-wins, and phase 52 states it rather than inheriting it."""
    signed_in = await _sign_in(apple_client, apple_keypair, FIRST)
    headers = _auth(signed_in)
    assert signed_in["user"]["display_name"] is None

    filled = await _attach(
        apple_client,
        headers,
        apple_keypair,
        SECOND,
    )
    assert filled.status_code == 200

    # A name arriving with a *third* credential fills the gap...
    third = await apple_client.post(
        "/v1/me/credentials",
        headers=headers,
        json={
            "provider": "apple",
            "identity_token": apple_token(apple_keypair, subject="001.third"),
            "display_name": "Travis",
        },
    )
    assert third.status_code == 200
    user = await session.scalar(sa.select(User))
    await session.refresh(user)
    assert user.display_name == "Travis"

    # ...and a fourth carrying a different name does not overwrite it.
    await apple_client.post(
        "/v1/me/credentials",
        headers=headers,
        json={
            "provider": "apple",
            "identity_token": apple_token(apple_keypair, subject="001.fourth"),
            "display_name": "Somebody Else",
        },
    )
    await session.refresh(user)
    assert user.display_name == "Travis"


# --- Revoking -----------------------------------------------------------------------------


async def test_revoking_the_last_credential_is_refused_and_the_row_is_untouched(
    apple_client: AsyncClient, apple_keypair, session: AsyncSession
) -> None:
    """Bricking an archive must not be reachable through an API call."""
    signed_in = await _sign_in(apple_client, apple_keypair, FIRST)
    headers = _auth(signed_in)
    only = (await apple_client.get("/v1/me/credentials", headers=headers)).json()[0]

    response = await apple_client.delete(f"/v1/me/credentials/{only['id']}", headers=headers)
    assert response.status_code == 409
    assert response.json()["error"]["code"] == "last_credential"

    row = await session.get(Credential, only["id"])
    await session.refresh(row)
    assert row.revoked_at is None, "a refused revocation must not half-apply"


async def test_revoking_one_of_two_succeeds_and_the_other_still_signs_in(
    apple_client: AsyncClient, apple_keypair, session: AsyncSession
) -> None:
    signed_in = await _sign_in(apple_client, apple_keypair, FIRST)
    headers = _auth(signed_in)
    await _attach(apple_client, headers, apple_keypair, SECOND)

    listed = (await apple_client.get("/v1/me/credentials", headers=headers)).json()
    first_id = next(row["id"] for row in listed if row["subject_hint"].endswith(FIRST[-4:]))

    revoked = await apple_client.delete(f"/v1/me/credentials/{first_id}", headers=headers)
    assert revoked.status_code == 200
    assert revoked.json()["revoked_at"] is not None

    # The other one is still a way in, and it is the same account.
    again = await _sign_in(apple_client, apple_keypair, SECOND)
    assert again["user"]["id"] == signed_in["user"]["id"]
    assert await session.scalar(sa.select(sa.func.count()).select_from(User)) == 1


async def test_revoking_an_already_revoked_credential_is_a_no_op(
    apple_client: AsyncClient, apple_keypair
) -> None:
    """The state the caller asked for is the state that holds, so this is not an error."""
    signed_in = await _sign_in(apple_client, apple_keypair, FIRST)
    headers = _auth(signed_in)
    await _attach(apple_client, headers, apple_keypair, SECOND)
    listed = (await apple_client.get("/v1/me/credentials", headers=headers)).json()
    target = listed[0]["id"]

    first = await apple_client.delete(f"/v1/me/credentials/{target}", headers=headers)
    second = await apple_client.delete(f"/v1/me/credentials/{target}", headers=headers)
    assert first.status_code == 200
    assert second.status_code == 200
    assert second.json()["revoked_at"] == first.json()["revoked_at"]


async def test_revoking_a_credential_on_another_account_is_a_404(
    apple_client: AsyncClient, apple_keypair
) -> None:
    """Naming somebody else's credential id must not confirm that it exists."""
    first = await _sign_in(apple_client, apple_keypair, FIRST)
    second = await _sign_in(apple_client, apple_keypair, SECOND)
    theirs = (await apple_client.get("/v1/me/credentials", headers=_auth(second))).json()[0]

    response = await apple_client.delete(f"/v1/me/credentials/{theirs['id']}", headers=_auth(first))
    assert response.status_code == 404


async def test_a_revocation_moves_updated_at(
    apple_client: AsyncClient, apple_keypair, session: AsyncSession
) -> None:
    """`updated_at` is the cursor a client syncs on, and the trigger owns it."""
    signed_in = await _sign_in(apple_client, apple_keypair, FIRST)
    headers = _auth(signed_in)
    await _attach(apple_client, headers, apple_keypair, SECOND)
    target = (await apple_client.get("/v1/me/credentials", headers=headers)).json()[0]["id"]

    row = await session.get(Credential, target)
    await session.refresh(row)
    before = row.updated_at

    await apple_client.delete(f"/v1/me/credentials/{target}", headers=headers)
    await session.refresh(row)
    assert row.updated_at > before


# --- The assertion the design turns on ----------------------------------------------------


async def test_a_revoked_subject_signing_in_again_lands_on_the_same_user(
    apple_client: AsyncClient, apple_keypair, session: AsyncSession
) -> None:
    """**Revocation is recoverable, and this is the test that says so.**

    A revoked credential keeps its `(provider, subject_id)` claim, so the lookup on the next
    sign-in finds *this* row rather than falling through to the create path. If it fell
    through, the parent would get a second, empty account and the archive behind the first
    would be unreachable — by them, and by anyone.
    """
    signed_in = await _sign_in(apple_client, apple_keypair, FIRST)
    headers = _auth(signed_in)
    original_user_id = signed_in["user"]["id"]
    await _attach(apple_client, headers, apple_keypair, SECOND)

    listed = (await apple_client.get("/v1/me/credentials", headers=headers)).json()
    first_id = next(row["id"] for row in listed if row["subject_hint"].endswith(FIRST[-4:]))
    await apple_client.delete(f"/v1/me/credentials/{first_id}", headers=headers)

    revoked = await session.get(Credential, first_id)
    await session.refresh(revoked)
    assert revoked.revoked_at is not None

    returned = await _sign_in(apple_client, apple_keypair, FIRST)

    assert returned["user"]["id"] == original_user_id, "a revoked subject must not mint a user"
    assert await session.scalar(sa.select(sa.func.count()).select_from(User)) == 1
    await session.refresh(revoked)
    assert revoked.revoked_at is None, "signing in again puts the key back"


async def test_reattaching_a_revoked_credential_reactivates_it(
    apple_client: AsyncClient, apple_keypair, session: AsyncSession
) -> None:
    """Attaching is a deliberate act that means *make this key work*."""
    signed_in = await _sign_in(apple_client, apple_keypair, FIRST)
    headers = _auth(signed_in)
    await _attach(apple_client, headers, apple_keypair, SECOND)
    listed = (await apple_client.get("/v1/me/credentials", headers=headers)).json()
    target = listed[0]["id"]
    await apple_client.delete(f"/v1/me/credentials/{target}", headers=headers)

    subject = FIRST if listed[0]["subject_hint"].endswith(FIRST[-4:]) else SECOND
    again = await _attach(apple_client, headers, apple_keypair, subject)

    assert again.status_code == 200
    assert again.json()["revoked_at"] is None
    assert await session.scalar(sa.select(sa.func.count()).select_from(Credential)) == 2
