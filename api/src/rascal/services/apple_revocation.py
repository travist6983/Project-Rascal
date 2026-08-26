"""Sign in with Apple, in the outbound direction: telling Apple the link is over.

`apple.py` verifies what Apple signs and `apple_events.py` applies what Apple sends. This is the
third and only outgoing half — the REST calls Guideline 5.1.1(v) requires an app offering Sign in
with Apple to make when somebody deletes their account. Nothing here reads or writes a family's
archive.

**Two calls, and the first exists only to make the second possible.** Apple's revocation endpoint
takes a refresh token; sign-in hands us an authorization code. So the code is exchanged for a
refresh token at sign-in (`capture_refresh_token`) and the token is spent seven days later, when
the erasure actually runs (`revoke`). The code cannot be stored and used later instead — it is
single-use and expires in minutes.

**Both calls are non-fatal by construction, and they fail in opposite directions on purpose.**

- A failed *exchange* must not break sign-in. A parent whose phone is in their hand, trying to
  get into their own archive, is not going to be turned away because Apple's token endpoint was
  slow. The cost of failing is one credential that cannot be revoked until the next sign-in.
- A failed *revocation* must not abort the erasure. Somebody asked to be deleted; Apple
  returning a 500 is not a reason to still be holding their child's photographs tomorrow. The
  failure is logged at ERROR with the credential id, which is what makes it findable and
  retryable, and the deletion proceeds.

**Every log line here names the credential and never the token.** `instagram.py` learned that
lesson the expensive way — httpx logs a full request URL at INFO — so the token travels in a form
body, never a query string, and no error path interpolates it.
"""

from __future__ import annotations

import datetime as dt
import logging
import uuid
from collections.abc import Callable

import httpx
import jwt
from sqlalchemy.exc import SQLAlchemyError
from sqlalchemy.ext.asyncio import AsyncSession

from rascal.config import Settings
from rascal.services.auth import find_credential, subject_hint

log = logging.getLogger("rascal.apple.revocation")

#: How long a `client_secret` is good for. Apple's ceiling is six months; this is minted per
#: call and used within seconds, so it is short on purpose. Unlike the APNs provider token there
#: is nothing to cache — these calls happen once per sign-in and once per erasure, not per
#: notification, so a cache would be state to get wrong for no saved round trip.
CLIENT_SECRET_TTL = dt.timedelta(minutes=5)

#: Apple's documented audience for both `/auth/token` and `/auth/revoke`.
CLIENT_SECRET_AUDIENCE = "https://appleid.apple.com"


def configured(settings: Settings) -> bool:
    """Whether a `client_secret` can be signed and addressed. See `apple_siwa_configured`."""
    return settings.apple_siwa_configured


def client_secret(settings: Settings, *, now: dt.datetime | None = None) -> str:
    """The ES256 JWT Apple's token endpoints take in place of a password.

    Same algorithm and the same shape of `.p8` as the APNs provider token in `push.py`, and a
    deliberately different key: this one is a Sign in with Apple key, and APNs cannot sign for
    it. `sub` is the client id — the audience the identity token was issued to — and `iss` is
    the team, which is the one part of this that is not secret.

    Callers must check :func:`configured` first; the assert only narrows `str | None`.
    """
    assert settings.apple_siwa_key_id and settings.apple_siwa_private_key  # by `configured`
    client_id = settings.resolved_apple_siwa_client_id
    assert client_id  # by `configured`

    issued = now or dt.datetime.now(tz=dt.UTC)
    return jwt.encode(
        {
            "iss": settings.apple_team_id,
            "iat": int(issued.timestamp()),
            "exp": int((issued + CLIENT_SECRET_TTL).timestamp()),
            "aud": CLIENT_SECRET_AUDIENCE,
            "sub": client_id,
        },
        settings.apple_siwa_private_key,
        algorithm="ES256",
        headers={"kid": settings.apple_siwa_key_id, "alg": "ES256"},
    )


async def capture_refresh_token(
    session: AsyncSession,
    subject_id: str,
    authorization_code: str | None,
    settings: Settings,
    *,
    client: httpx.AsyncClient | None = None,
    now: Callable[[], dt.datetime] | None = None,
) -> bool:
    """Exchange a fresh authorization code for a refresh token and remember it.

    Returns whether a token was stored. **Never raises**: every failure mode here — no code sent,
    no key configured, Apple unreachable, Apple refusing — leaves the credential exactly as it
    was and lets the sign-in continue. See the module docstring for why that asymmetry is
    deliberate.

    An existing token is replaced rather than kept. Apple invalidates the old one when it issues
    a new one, so keeping the first would mean holding a string that no longer revokes anything.
    """
    if not authorization_code:
        # Older clients, and every non-Apple caller. Not worth a log line per sign-in.
        return False
    if not configured(settings):
        log.warning(
            "no sign in with apple key, so this credential cannot be revoked later; "
            "see docs/blocked.md section 24",
            extra={"subject_hint": subject_hint("apple", subject_id)},
        )
        return False

    # **Apple first, the database second, and the order is the whole point.** Reading the
    # credential first opens a transaction and checks a connection out of the same pool every
    # request uses, and it would then sit idle-in-transaction for the whole round trip to
    # Apple — up to the connect plus read timeouts. That is the exact failure the caller moved
    # this into a background task to avoid, and doing it here would simply have carried the
    # held connection along with it. Nothing is read from the database until there is a value
    # worth writing.
    token = await _exchange(authorization_code, settings, client=client, now=now)
    if token is None:
        return False

    credential = await find_credential(session, "apple", subject_id)
    if credential is None:  # pragma: no cover — the caller just created or found it
        return False

    credential.apple_refresh_token = token
    # **Read before the flush, and that is not a style choice.** A failed flush rolls the
    # transaction back, and the rollback expires every object in the identity map — the primary
    # key included. Reading `credential.id` afterwards is then an implicit SELECT issued from a
    # sync Session inside async code, which raises `MissingGreenlet` *from inside the handler
    # below* — so the warning would never be logged, `return False` would never run, and the
    # traceback this guard exists to prevent would escape after all.
    credential_id = str(credential.id)
    try:
        await session.flush()
    except SQLAlchemyError:
        # **Caught so the token cannot escape inside a traceback.** A `DBAPIError` renders the
        # failing statement *and its bound parameters* into `str(exc)`, and this is the one
        # statement in the service that binds a live credential — so letting it propagate would
        # put the token into a structured log line, under a message saying it had not been
        # stored. `hide_parameters=True` on the engine is the structural half of this; the guard
        # is here as well because the module's docstring promises **never raises**, and a
        # promise that depends on a setting three files away is not one worth making.
        #
        # The rollback is not optional: without it the caller's `commit()` raises
        # `PendingRollbackError`, whose message quotes the original exception — the same leak
        # through a longer pipe.
        await session.rollback()
        log.warning(
            "apple refresh token could not be stored; this credential is not revocable "
            "until the next sign-in",
            extra={"credential_id": credential_id},
        )
        return False
    log.info("apple refresh token stored", extra={"credential_id": credential_id})
    return True


async def revoke(
    token: str,
    settings: Settings,
    *,
    credential_id: uuid.UUID | None = None,
    client: httpx.AsyncClient | None = None,
    now: Callable[[], dt.datetime] | None = None,
) -> bool:
    """Tell Apple this app's access is over. Returns whether Apple confirmed it.

    **Never raises.** A deletion that stops because a vendor was unavailable is a compliance
    failure with better logging, so every failure returns `False` and is recorded at ERROR with
    the credential id — enough to prove revocation was attempted for any given account, and
    enough to retry by hand.

    Apple answers 200 with an empty body on success, and answers 200 for a token it has already
    revoked, which is what makes a retry safe.
    """
    if not configured(settings):
        log.error(
            "cannot revoke a sign in with apple credential: no key is configured. "
            "The account is still being deleted. See docs/blocked.md section 24.",
            extra={"credential_id": str(credential_id) if credential_id else None},
        )
        return False

    try:
        secret = client_secret(settings, now=now() if now else None)
    except Exception as exc:
        # Deliberately broad, exactly as `push.py` is around the same operation: cryptography
        # and PyJWT raise several unrelated types when a `.p8` arrives with its newlines eaten,
        # and none of them may take down a deletion run.
        log.error(
            "sign in with apple client secret could not be signed; the account is still "
            "being deleted",
            extra={
                "credential_id": str(credential_id) if credential_id else None,
                "error": str(exc),
            },
        )
        return False

    form = {
        "client_id": settings.resolved_apple_siwa_client_id,
        "client_secret": secret,
        "token": token,
        "token_type_hint": "refresh_token",
    }
    response = await _post(settings.apple_revoke_url, form, settings, client=client)

    if response is None:
        log.error(
            "apple revocation could not be delivered; the account is still being deleted",
            extra={"credential_id": str(credential_id) if credential_id else None},
        )
        return False
    if response.status_code >= 300:
        log.error(
            "apple refused a revocation; the account is still being deleted",
            extra={
                "credential_id": str(credential_id) if credential_id else None,
                "status": response.status_code,
                # Apple's body here is `{"error": "invalid_client"}` shaped and carries no
                # token. Truncated anyway: this is written to a log somebody will paste.
                "detail": response.text[:200],
            },
        )
        return False

    log.info(
        "apple sign-in revoked",
        extra={"credential_id": str(credential_id) if credential_id else None},
    )
    return True


async def _exchange(
    authorization_code: str,
    settings: Settings,
    *,
    client: httpx.AsyncClient | None = None,
    now: Callable[[], dt.datetime] | None = None,
) -> str | None:
    """`/auth/token`, returning the refresh token or `None`. Never raises."""
    try:
        secret = client_secret(settings, now=now() if now else None)
    except Exception as exc:  # see `revoke` for why this is broad
        log.warning(
            "sign in with apple client secret could not be signed; the sign-in continues "
            "and this credential will not be revocable until the next one",
            extra={"error": str(exc)},
        )
        return None

    form = {
        "client_id": settings.resolved_apple_siwa_client_id,
        "client_secret": secret,
        "code": authorization_code,
        "grant_type": "authorization_code",
    }
    response = await _post(settings.apple_token_url, form, settings, client=client)

    if response is None:
        return None
    if response.status_code >= 300:
        # The ordinary cause is a code this server has already spent, or one that expired while
        # a phone was on a bad connection. Neither is worth an ERROR on a path that works.
        log.warning(
            "apple would not exchange an authorization code; the sign-in continues",
            extra={"status": response.status_code, "detail": response.text[:200]},
        )
        return None

    try:
        token = response.json().get("refresh_token")
    except ValueError:
        log.warning("apple's token response was not json; the sign-in continues")
        return None
    if not isinstance(token, str) or not token:
        # A well-formed response with no refresh token means Apple issued only an access token,
        # which happens for a code that was already exchanged. There is nothing to store.
        log.warning("apple's token response carried no refresh token; the sign-in continues")
        return None
    return token


async def _post(
    url: str,
    form: dict[str, str | None],
    settings: Settings,
    *,
    client: httpx.AsyncClient | None = None,
) -> httpx.Response | None:
    """One form POST to Apple, or `None` if it could not be delivered. Never raises.

    `client` is injectable so the tests drive both calls through a `MockTransport` and never
    touch the network. Built per call when it is not supplied, like `turnstile.py`: these are
    rare, and a module-level client would hold a socket open against Apple for the life of the
    machine to serve a handful of requests a day.
    """
    body = {key: value for key, value in form.items() if value is not None}
    try:
        if client is not None:
            return await client.post(url, data=body)
        # **Per component, not one number.** A bare `timeout=10.0` sets connect, read, write and
        # pool to ten seconds *each*, so an Apple that accepts the connection and then goes
        # quiet costs far more than the ten seconds the setting appears to promise. Both callers
        # run off the request path — a background task and the deletion job — so this is about
        # bounding a stall rather than about latency somebody feels.
        timeout = httpx.Timeout(
            connect=min(2.0, settings.apple_siwa_timeout_seconds),
            read=settings.apple_siwa_timeout_seconds,
            write=settings.apple_siwa_timeout_seconds,
            pool=min(2.0, settings.apple_siwa_timeout_seconds),
        )
        async with httpx.AsyncClient(timeout=timeout) as owned:
            return await owned.post(url, data=body)
    except httpx.HTTPError as exc:
        log.warning("apple token endpoint unreachable", extra={"reason": str(exc)})
        return None
