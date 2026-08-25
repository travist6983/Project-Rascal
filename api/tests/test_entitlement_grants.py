"""Phase 121. A household entitled by a grant an admin issued as well as by a receipt Apple signed.

The whole phase is one sentence — **the two never fight** — and most of this file is that
sentence pushed from both directions:

* a grant expiring or being revoked must not demote a household with a live receipt;
* a receipt lapsing must not demote a household with a live grant.

Everything else follows from where the union is computed. `services/guardians.access_for` is the
one authority phase 107 built and phase 121 gave a third term to, so the tests that matter are
the ones asserting nothing grew a *second* answer: `entitlements.tier` still has exactly one
writer, every call site of `access_for` supplies the new argument, and the two family routes
still agree with each other and with `GET /today`.

**Nothing here writes `tier`.** `tests/test_app_store.py::test_tier_has_exactly_one_writer` is the
guard and it passes unmodified; the fixtures below set the column directly the way
`docs/runbook-deploy.md` §7a does by hand, which is what `make_family` already does for every
other test in this suite.
"""

from __future__ import annotations

import ast
import datetime as dt
import pathlib
import uuid

import pytest
from httpx import AsyncClient
from sqlalchemy import delete, select
from sqlalchemy.ext.asyncio import AsyncSession

import app_store_stub as stub
from factories import make_family, make_user
from helpers import auth_headers
from rascal.models import Entitlement, EntitlementGrant, Family, User
from rascal.services.grants import active_grant_for, issue_grant, revoke_grant
from rascal.services.guardians import access_for_family, eligible_at

GRANTS = "/v1/admin/grants"
HOUSEHOLDS = "/v1/admin/households"

# The same fixed past instant `test_app_store.py` pins its notifications to, for the same
# reason: a `signedDate` is when Apple decided, and pinning it keeps certificate validity out
# of the runner's clock.
SIGNED_AT = dt.datetime(2026, 6, 1, 12, 0, tzinfo=dt.UTC)


def _hours(count: int) -> dt.datetime:
    """A moment `count` hours from now — negative for the past.

    Relative rather than a literal, because a literal future date rots into a literal past one
    and `tests/test_fixture_dates.py` refuses a fixture dated after today.
    """
    return dt.datetime.now(tz=dt.UTC) + dt.timedelta(hours=count)


async def _admin(session: AsyncSession) -> User:
    user = await make_user(session, display_name="Owner")
    user.is_admin = True
    await session.flush()
    return user


async def _household(
    session: AsyncSession, *, tier: str = "free", trial=None
) -> tuple[Family, User]:
    """A household with a member. **Trial cleared by default**, so `entitled` means the grant.

    `make_family` leaves every fixture household fourteen days into a trial, which is right for
    the hundred tests that predate the free tier and wrong for every test in this file: a
    household that is already entitled cannot demonstrate that a grant entitled it.
    """
    family = await make_family(session, tier=tier, trial_ends_at=trial)
    user = await make_user(session, family=family, display_name="A parent")
    return family, user


async def _grant(
    session: AsyncSession,
    family: Family,
    admin: User,
    *,
    reason: str = "founding tester",
    expires_at: dt.datetime | None = None,
) -> EntitlementGrant:
    grant = await issue_grant(
        session,
        family_id=family.id,
        granted_by=admin.id,
        reason=reason,
        expires_at=expires_at,
    )
    await session.commit()
    return grant


async def _entitlement_body(client: AsyncClient, user: User) -> dict:
    response = await client.get(
        f"/v1/families/{user.family_id}/entitlement", headers=auth_headers(user)
    )
    assert response.status_code == 200, response.text
    return response.json()


# --- Break-test 1 · a granted household is entitled, and may invite ----------------------------


async def test_a_granted_household_reads_entitled_and_passes_the_invite_gate(
    client: AsyncClient, session: AsyncSession
) -> None:
    """**The whole phase in one test.** `tier` says `free`; the household is entitled anyway.

    Before the fix `entitled` was `tier == "subscribed" or in_trial`, so this household read
    `entitled: false` and `POST /families/me/invites` answered `402 subscription_required` — a
    complimentary family hitting a paywall, which is the defect the phase exists to remove.

    **The invite gate is the one worth pinning rather than a cheaper gate**, because it is the
    one that had to move without dragging the trial with it: `Access.is_member` is *paid or
    granted* and deliberately not *entitled*, so a household inside its fourteen days still
    cannot mint an invite. `test_a_trialling_household_still_cannot_invite` below is that half.
    """
    admin = await _admin(session)
    family, user = await _household(session)
    await session.commit()

    before = await client.post("/v1/families/me/invites", json={}, headers=auth_headers(user))
    assert before.status_code == 402, before.text
    assert before.json()["error"]["code"] == "subscription_required"

    await _grant(session, family, admin)

    body = await _entitlement_body(client, user)
    assert body["tier"] == "free", "a grant must not touch the column Apple owns"
    assert body["entitled"] is True
    assert body["entitlement_source"] == "grant"
    assert body["access"] == "subscribed"
    assert body["grant_expires_at"] is None, "a perpetual grant reports no date, not a sentinel"

    after = await client.post("/v1/families/me/invites", json={}, headers=auth_headers(user))
    assert after.status_code == 201, after.text


async def test_a_trialling_household_still_cannot_invite(
    client: AsyncClient, session: AsyncSession
) -> None:
    """The half of the sweep that had to **not** move.

    D4 sells the second parent on a subscription and a trial does not add one — phase 107's
    settled rule. Repointing this gate at `entitled` rather than at `is_member` would have
    reversed it silently, which is the shape of change that gets noticed by a customer.
    """
    _, user = await _household(session, trial=_hours(24 * 14))
    await session.commit()

    body = await _entitlement_body(client, user)
    assert body["entitled"] is True, "a trial does entitle the board"
    assert body["entitlement_source"] == "trial"

    response = await client.post("/v1/families/me/invites", json={}, headers=auth_headers(user))
    assert response.status_code == 402, "a trial is not a membership and must not mint an invite"


# --- Break-test 2 · a grant ending does not demote a subscriber --------------------------------


async def test_a_grant_expiring_does_not_demote_a_subscribed_household(
    client: AsyncClient, session: AsyncSession
) -> None:
    """**Precedence, downward.** The two sources are independent terms of one `or`.

    The broken version computed the union as *"a grant decides, falling back to the tier"* —
    which reads fine and takes a paying household's archive away the day a complimentary grant
    somebody issued them alongside it runs out.
    """
    admin = await _admin(session)
    family, user = await _household(session, tier="subscribed")
    grant = await _grant(session, family, admin, expires_at=_hours(1))
    await session.commit()

    live = await _entitlement_body(client, user)
    assert live["entitled"] is True
    # **`receipt` wins the label while both hold**, because it is the one that can lapse.
    assert live["entitlement_source"] == "receipt"

    grant.expires_at = _hours(-1)
    await session.commit()

    after = await _entitlement_body(client, user)
    assert after["entitled"] is True, "an expired grant demoted a household Apple says is paying"
    assert after["tier"] == "subscribed"
    assert after["entitlement_source"] == "receipt"
    assert after["grant_expires_at"] is None, "an expired grant is not the grant holding the door"


async def test_a_grant_being_revoked_does_not_demote_a_subscribed_household(
    client: AsyncClient, session: AsyncSession
) -> None:
    """The same precedence, reached by the other route. Revoking is not expiring."""
    admin = await _admin(session)
    family, user = await _household(session, tier="subscribed")
    grant = await _grant(session, family, admin)
    await revoke_grant(session, grant.id, revoked_by=admin.id)
    await session.commit()

    body = await _entitlement_body(client, user)
    assert body["entitled"] is True
    assert body["entitlement_source"] == "receipt"


# --- Break-test 3 · a receipt lapsing does not demote a granted household ----------------------


async def test_a_receipt_lapsing_does_not_demote_a_granted_household(
    client: AsyncClient, session: AsyncSession
) -> None:
    """**Precedence, upward**, without going near Apple's signing chain.

    `tier` moving to `free` is the whole of what a lapse does to `entitlements`; the notification
    path that writes it is `test_app_store.py`'s business and is untouched by this phase.
    """
    admin = await _admin(session)
    family, user = await _household(session, tier="subscribed")
    await _grant(session, family, admin)

    entitlement = await session.get(Entitlement, family.id)
    entitlement.tier = "free"
    entitlement.lapsed_at = dt.datetime.now(tz=dt.UTC)
    await session.commit()

    body = await _entitlement_body(client, user)
    assert body["tier"] == "free"
    assert body["entitled"] is True, "a lapse demoted a household somebody had granted"
    assert body["entitlement_source"] == "grant"
    # **And no deletion clock.** This is the case the `granted` argument on `eligible_at` exists
    # for: a real `lapsed_at` on a household that is fully entitled. A countdown here is a
    # countdown on the photographs of somebody we just told was welcome.
    assert body["eligible_at"] is None


async def test_an_expired_notification_leaves_a_granted_household_entitled(
    app_store_client: AsyncClient, client: AsyncClient, session: AsyncSession, app_store_chain
) -> None:
    """The same thing through the **real webhook**, because that is where a lapse comes from.

    A `SUBSCRIBED` then an `EXPIRED` for a household that also holds a grant. The tier moves —
    the webhook is still the only writer and this phase did not touch it — and the household
    stays entitled, on the grant.
    """
    admin = await _admin(session)
    family, user = await _household(session)
    await session.commit()

    for notification_type, subtype, when in [
        ("SUBSCRIBED", "INITIAL_BUY", SIGNED_AT),
        ("EXPIRED", "VOLUNTARY", SIGNED_AT + dt.timedelta(days=365)),
    ]:
        if notification_type == "EXPIRED":
            # Issued between the two notifications, which is the realistic order: somebody
            # cancels, and the grant is the apology.
            await _grant(session, family, admin, reason="refund goodwill")
        response = await app_store_client.post(
            "/v1/webhooks/app-store",
            json={
                "signedPayload": stub.sign_notification(
                    app_store_chain,
                    notification_type=notification_type,
                    subtype=subtype,
                    signed_date=when,
                    app_account_token=family.id,
                )
            },
        )
        # 202: Apple's notifications are accepted rather than answered. The body names the
        # effect, and `test_app_store.py` is what pins that vocabulary.
        assert response.status_code == 202, response.text

    entitlement = await session.get(Entitlement, family.id)
    await session.refresh(entitlement)
    assert entitlement.tier == "free", "the webhook is still the writer and still wrote"

    body = await _entitlement_body(client, user)
    assert body["tier"] == "free"
    assert body["entitled"] is True
    assert body["entitlement_source"] == "grant"


# --- Break-test 4 · revocation is immediate, and idempotent ------------------------------------


async def test_a_revoked_grant_stops_entitling_immediately(
    client: AsyncClient, session: AsyncSession
) -> None:
    """No cache to invalidate and no job to wait for — every surface computes it per request."""
    admin = await _admin(session)
    family, user = await _household(session)
    grant = await _grant(session, family, admin)

    assert (await _entitlement_body(client, user))["entitled"] is True

    response = await client.post(f"{GRANTS}/{grant.id}/revoke", headers=auth_headers(admin))
    assert response.status_code == 200, response.text
    assert response.json()["status"] == "revoked"

    after = await _entitlement_body(client, user)
    assert after["entitled"] is False
    assert after["entitlement_source"] == "none"
    assert after["access"] == "free"


async def test_revoking_twice_succeeds_and_writes_nothing(
    client: AsyncClient, session: AsyncSession
) -> None:
    """A console click that times out and gets clicked again must not be an error.

    **"Writes nothing" is asserted rather than assumed**: the second call must not move
    `revoked_at`, or a support conversation about *when* somebody's access ended gets the time
    of the second click.
    """
    admin = await _admin(session)
    family, _ = await _household(session)
    grant = await _grant(session, family, admin)

    first = await client.post(f"{GRANTS}/{grant.id}/revoke", headers=auth_headers(admin))
    assert first.status_code == 200
    second = await client.post(f"{GRANTS}/{grant.id}/revoke", headers=auth_headers(admin))
    assert second.status_code == 200
    assert second.json()["revoked_at"] == first.json()["revoked_at"]


async def test_there_is_no_way_to_delete_a_grant() -> None:
    """Soft deletes on everything, and this is the table where it matters most.

    Asserted against the app's own `openapi()` rather than by reading the router, so a `DELETE`
    added later — on any path under `/v1/admin/grants` — fails here.
    """
    from rascal.config import get_settings
    from rascal.main import create_app

    paths = create_app(get_settings()).openapi()["paths"]
    offenders = [
        path
        for path, operations in paths.items()
        if path.startswith("/v1/admin/grants") and "delete" in operations
    ]
    assert offenders == [], f"a grant must be revoked, never deleted: {offenders}"


# --- Break-test 5 · `granted_by` cannot come from the body -------------------------------------


async def test_granted_by_cannot_be_set_from_the_request_body(
    client: AsyncClient, session: AsyncSession
) -> None:
    """**An audit column a caller can set says whatever the caller wanted it to.**

    The body below names somebody else. It is ignored — not honoured, and not a 422 either: the
    schema simply has no such field, so an extra key is dropped and the token's subject is
    written. Asserted on the row rather than on the response, because the response renders a
    display name and two different admins could share one.
    """
    admin = await _admin(session)
    other = await make_user(session, display_name="Somebody else")
    family, _ = await _household(session)
    await session.commit()

    response = await client.post(
        GRANTS,
        json={
            "family_id": str(family.id),
            "reason": "founding tester",
            "granted_by": str(other.id),
        },
        headers=auth_headers(admin),
    )
    assert response.status_code == 201, response.text

    grant = await session.scalar(
        select(EntitlementGrant).where(EntitlementGrant.family_id == family.id)
    )
    assert grant.granted_by == admin.id, "the body's `granted_by` was honoured"
    assert grant.granted_by != other.id


async def test_revoked_by_is_the_revoking_admin_not_the_issuing_one(
    client: AsyncClient, session: AsyncSession
) -> None:
    """Two columns, two people, and the ledger has to be able to say they differed."""
    issuer = await _admin(session)
    revoker = await _admin(session)
    family, _ = await _household(session)
    grant = await _grant(session, family, issuer)

    response = await client.post(f"{GRANTS}/{grant.id}/revoke", headers=auth_headers(revoker))
    assert response.status_code == 200, response.text

    await session.refresh(grant)
    assert grant.granted_by == issuer.id
    assert grant.revoked_by == revoker.id


# --- The predicate itself ----------------------------------------------------------------------


async def test_a_perpetual_grant_never_expires(session: AsyncSession) -> None:
    """`expires_at IS NULL` is *no end date*, not a missing value and not a sentinel."""
    admin = await _admin(session)
    family, _ = await _household(session)
    await _grant(session, family, admin)

    far = dt.datetime(2099, 1, 1, tzinfo=dt.UTC)  # future-date: the point is that it still holds
    assert await active_grant_for(session, family.id, now=far) is not None


async def test_a_grant_expires_at_its_expiry_and_not_a_moment_after(
    session: AsyncSession,
) -> None:
    """The boundary is strict, stated as a decision rather than left to `>` versus `>=`.

    The same edge `access_for` already takes for the trial, which is why they are written the
    same way round.
    """
    admin = await _admin(session)
    family, _ = await _household(session)
    ends = _hours(24)
    await _grant(session, family, admin, expires_at=ends)

    assert await active_grant_for(session, family.id, now=ends - dt.timedelta(seconds=1))
    assert await active_grant_for(session, family.id, now=ends) is None


async def test_the_longest_grant_is_the_one_reported(session: AsyncSession) -> None:
    """**Which grant, when a household holds several.** The one that keeps them entitled longest.

    Reporting the newest instead would put an expiry on the wire that the household sails
    straight past, because an older, longer grant is still holding — a date a Settings screen
    would render as the end of somebody's membership when it is not.
    """
    admin = await _admin(session)
    family, _ = await _household(session)
    await _grant(session, family, admin, expires_at=_hours(24), reason="first")
    await _grant(session, family, admin, expires_at=_hours(24 * 30), reason="extension")

    grant = await active_grant_for(session, family.id)
    assert grant.reason == "extension"

    # And a perpetual one outranks every date, however far out.
    await _grant(session, family, admin, reason="permanent")
    assert (await active_grant_for(session, family.id)).reason == "permanent"


async def test_extending_is_a_new_row_and_the_old_one_is_still_there(
    client: AsyncClient, session: AsyncSession
) -> None:
    """The ledger is the point. Two rows, both readable, and the history says what happened."""
    admin = await _admin(session)
    family, _ = await _household(session)
    await _grant(session, family, admin, expires_at=_hours(24), reason="first month")
    await _grant(session, family, admin, expires_at=_hours(24 * 60), reason="extended")

    body = (await client.get(f"{GRANTS}?family_id={family.id}", headers=auth_headers(admin))).json()
    assert [row["reason"] for row in body["grants"]] == ["extended", "first month"]
    assert all(row["status"] == "active" for row in body["grants"])


async def test_the_ledger_keeps_revoked_and_expired_rows(
    client: AsyncClient, session: AsyncSession
) -> None:
    """A ledger that hides what was withdrawn is not a ledger.

    `revoked` outranks `expired` on a row that is both: it is the thing somebody *did*, and
    reading it as an expiry loses the only part of the sentence with a person in it.
    """
    admin = await _admin(session)
    family, _ = await _household(session)
    live = await _grant(session, family, admin, reason="live")
    expired = await _grant(session, family, admin, expires_at=_hours(24), reason="ran out")
    both = await _grant(session, family, admin, expires_at=_hours(24), reason="revoked early")

    expired.expires_at = _hours(-1)
    both.expires_at = _hours(-1)
    await revoke_grant(session, both.id, revoked_by=admin.id)
    await session.commit()

    rows = (
        await client.get(f"{GRANTS}?family_id={family.id}", headers=auth_headers(admin))
    ).json()["grants"]
    status = {row["id"]: row["status"] for row in rows}
    assert status[str(live.id)] == "active"
    assert status[str(expired.id)] == "expired"
    assert status[str(both.id)] == "revoked"


# --- Issuing: what is refused ------------------------------------------------------------------


@pytest.mark.parametrize("reason", ["", "   "])
async def test_an_empty_reason_is_refused(
    client: AsyncClient, session: AsyncSession, reason: str
) -> None:
    """A blank reason is a ledger row that answers the only question the ledger exists for.

    Whitespace counts as blank on both sides — Pydantic's `min_length` catches the empty string
    and `issue_grant` trims before checking, which is what stops `"   "` reaching the CHECK and
    coming back as a rendered database complaint.
    """
    admin = await _admin(session)
    family, _ = await _household(session)
    await session.commit()

    response = await client.post(
        GRANTS,
        json={"family_id": str(family.id), "reason": reason},
        headers=auth_headers(admin),
    )
    assert response.status_code == 422, response.text
    assert response.json()["error"]["code"] == "validation_failed"


async def test_an_expiry_already_in_the_past_is_refused(
    client: AsyncClient, session: AsyncSession
) -> None:
    """It would be *legal*, which is exactly why it is refused.

    The row would simply be inactive from the moment it was written — a grant sitting in a
    ledger looking like a grant and entitling nobody.
    """
    admin = await _admin(session)
    family, _ = await _household(session)
    await session.commit()

    response = await client.post(
        GRANTS,
        json={
            "family_id": str(family.id),
            "reason": "founding tester",
            "expires_at": _hours(-1).isoformat(),
        },
        headers=auth_headers(admin),
    )
    assert response.status_code == 422, response.text
    assert response.json()["error"]["field"] == "expires_at"


async def test_an_offset_less_expiry_is_refused_rather_than_crashing(
    client: AsyncClient, session: AsyncSession
) -> None:
    """**422, not 500**, and not a UTC assumption either.

    Pydantic parses `"2099-01-01T00:00:00"` into a naive datetime, which would reach an
    ordering comparison against an aware `now` and raise `TypeError` — rendered by the catch-all
    as `internal_error` with no field to point at. Assuming UTC instead would be this service
    inventing a timezone for a value that decides which *day* somebody's entitlement ends.
    """
    admin = await _admin(session)
    family, _ = await _household(session)
    await session.commit()

    response = await client.post(
        GRANTS,
        # future-date: an offset-less *future* date is the shape under test; the point is the
        # missing offset, and a past one would be refused for the other reason first.
        json={
            "family_id": str(family.id),
            "reason": "founding tester",
            "expires_at": "2099-01-01T00:00:00",
        },
        headers=auth_headers(admin),
    )
    assert response.status_code == 422, response.text
    assert response.json()["error"]["field"] == "expires_at"


async def test_an_offset_bearing_expiry_in_any_zone_is_accepted(
    client: AsyncClient, session: AsyncSession
) -> None:
    """The guard is about the *offset*, not about UTC. A grant issued from Auckland is a grant."""
    admin = await _admin(session)
    family, _ = await _household(session)
    await session.commit()

    ends = _hours(24 * 30).astimezone(dt.timezone(dt.timedelta(hours=13)))
    response = await client.post(
        GRANTS,
        json={
            "family_id": str(family.id),
            "reason": "founding tester",
            "expires_at": ends.isoformat(),
        },
        headers=auth_headers(admin),
    )
    assert response.status_code == 201, response.text

    grant = await active_grant_for(session, family.id)
    # Stored as an instant, so the zone it was typed in does not survive and must not need to —
    # the column is `timestamptz` and the comparison is against a clock, not against a calendar.
    assert grant.expires_at == ends


async def test_a_household_that_does_not_exist_is_a_404(
    client: AsyncClient, session: AsyncSession
) -> None:
    """A UUID a human typed into a console is a typo, not an internal error."""
    admin = await _admin(session)
    await session.commit()

    response = await client.post(
        GRANTS,
        json={"family_id": str(uuid.uuid4()), "reason": "founding tester"},
        headers=auth_headers(admin),
    )
    assert response.status_code == 404, response.text


async def test_revoking_a_grant_that_does_not_exist_is_a_404(
    client: AsyncClient, session: AsyncSession
) -> None:
    admin = await _admin(session)
    await session.commit()
    response = await client.post(f"{GRANTS}/{uuid.uuid4()}/revoke", headers=auth_headers(admin))
    assert response.status_code == 404, response.text


# --- Authorization -----------------------------------------------------------------------------


@pytest.mark.parametrize("method,path", [("post", GRANTS), ("get", GRANTS), ("get", HOUSEHOLDS)])
async def test_a_non_admin_cannot_reach_the_grant_routes(
    client: AsyncClient, session: AsyncSession, method: str, path: str
) -> None:
    """`GET` is swept by `test_admin.py` too; the writes are swept only here, so both are.

    A route that can entitle a household is the one place where "guarded by one boolean" wants
    checking twice.
    """
    stranger = await make_user(session, display_name="Nobody")
    await session.commit()

    call = getattr(client, method)
    kwargs = {"json": {"family_id": str(uuid.uuid4()), "reason": "x"}} if method == "post" else {}
    response = await call(path, headers=auth_headers(stranger), **kwargs)
    assert response.status_code == 403, f"{method} {path} is reachable by a non-admin"


async def test_no_token_at_all_cannot_reach_the_write_routes(client: AsyncClient) -> None:
    response = await client.post(GRANTS, json={"family_id": str(uuid.uuid4()), "reason": "x"})
    assert response.status_code == 401
    response = await client.post(f"{GRANTS}/{uuid.uuid4()}/revoke")
    assert response.status_code == 401


# --- The household picker ----------------------------------------------------------------------


async def test_the_picker_finds_a_household_by_email_name_and_family_id(
    client: AsyncClient, session: AsyncSession
) -> None:
    """Account metadata, and the three strings a person actually has."""
    admin = await _admin(session)
    family, user = await _household(session)
    user.display_name = "Wilhelmina Featherstonehaugh"
    user.email = "wilhelmina@example.com"
    await session.commit()

    for query in ["wilhelmina@example", "Featherstonehaugh", str(family.id)[:8]]:
        body = (await client.get(f"{HOUSEHOLDS}?q={query}", headers=auth_headers(admin))).json()
        assert str(family.id) in {row["family_id"] for row in body["households"]}, query


async def test_the_picker_reports_the_entitlement_the_phone_would_get(
    client: AsyncClient, session: AsyncSession
) -> None:
    """A console that disagreed with `GET /today` about who is entitled is worse than no column."""
    admin = await _admin(session)
    family, user = await _household(session)
    await _grant(session, family, admin)

    body = (await client.get(f"{HOUSEHOLDS}?q={user.email}", headers=auth_headers(admin))).json()
    row = next(r for r in body["households"] if r["family_id"] == str(family.id))
    assert row["tier"] == "free"
    assert row["access"] == "subscribed"
    assert row["entitlement_source"] == "grant"
    assert row["grants"] == 1


async def test_an_empty_query_lists_recent_households_rather_than_erroring(
    client: AsyncClient, session: AsyncSession
) -> None:
    """What the picker wants on first paint. A control you must type into first is a control
    nobody uses."""
    admin = await _admin(session)
    await _household(session)
    await session.commit()

    body = (await client.get(HOUSEHOLDS, headers=auth_headers(admin))).json()
    assert len(body["households"]) >= 2


# --- The union, everywhere it is read ----------------------------------------------------------


async def test_the_two_family_routes_agree_about_a_granted_household(
    client: AsyncClient, session: AsyncSession
) -> None:
    """One authority, three shapes — the agreement phase 107 pinned, with a grant in it.

    `GET /today` reports `access` rather than `entitled`, which is why `access` moving to
    `subscribed` for a granted household matters: a board that locked half of itself while the
    subscription screen said "entitled" would be two answers.
    """
    admin = await _admin(session)
    family, user = await _household(session)
    await _grant(session, family, admin)
    from factories import make_child

    child = await make_child(session, name="Wren", parent=user)
    await session.commit()

    headers = auth_headers(user)
    me = (await client.get("/v1/families/me", headers=headers)).json()
    entitlement = await _entitlement_body(client, user)
    today = (await client.get(f"/v1/children/{child.id}/today", headers=headers)).json()

    assert me["access"] == entitlement["access"] == today["access"] == "subscribed"
    assert me["entitled"] is entitlement["entitled"] is True
    assert me["entitlement_source"] == entitlement["entitlement_source"] == "grant"
    assert me["tier"] == entitlement["tier"] == "free"
    assert today["locked"] == [], "a granted household must get the whole board"


async def test_a_granted_household_is_scheduled_the_whole_day(session: AsyncSession) -> None:
    """The scheduler reads the union too, and it is the one path that cannot be fixed by a read.

    A served prompt burns the 180-day cooldown against a 133-prompt pool, so filling only the
    free slot for a granted household would hand them repeats later — the same argument
    `_serve` makes for a subscriber.
    """
    from rascal.services.scheduler import ensure_day_filled, slots_for

    admin = await _admin(session)
    family, user = await _household(session)
    child = await _child_with_a_pool(session, user)
    await _grant(session, family, admin)

    day = dt.date(2026, 8, 22)  # a Saturday, which carries both missions
    await ensure_day_filled(session, child, day)
    await session.commit()

    from rascal.models import Assignment

    rows = (
        await session.execute(
            select(Assignment.slot).where(
                Assignment.child_id == child.id, Assignment.assigned_on == day
            )
        )
    ).scalars()
    assert set(rows) == set(slots_for(day)), "a granted household was served a free-tier day"


async def test_eligible_at_is_null_for_a_granted_household() -> None:
    """The unit, beside the route-level assertion above. Both clocks, one answer."""
    lapsed = dt.datetime(2026, 5, 1, tzinfo=dt.UTC)
    signed_in = dt.datetime(2026, 6, 1, tzinfo=dt.UTC)
    assert eligible_at("free", lapsed, signed_in) is not None
    assert eligible_at("free", lapsed, signed_in, granted=True) is None


# --- The guards that keep this from growing a second answer ------------------------------------


def test_every_access_for_call_site_passes_a_grant() -> None:
    """**The tripwire this phase needed and phase 107 did not.**

    `access_for` takes `granted` as a keyword with a `False` default, because the alternative —
    a required argument — breaks a pure-function sweep that has nothing to pass and buys nothing
    a test cannot buy. The default is therefore a hole a router could fall through: forget the
    argument and a granted household reads `free`, quietly, on one route out of four.

    So: **every call to `access_for` anywhere under `src/` must supply `granted=`.** Parsed
    rather than grepped, for the reason `test_entitlement_cadence.py` gives about the trial —
    a call the formatter split across four lines is the same defect and would not have tripped
    a regex.
    """
    src = pathlib.Path(__file__).resolve().parents[1] / "src" / "rascal"
    missing: list[str] = []
    for path in sorted(src.rglob("*.py")):
        tree = ast.parse(path.read_text(), filename=str(path))
        enclosing: dict[ast.AST, str] = {}
        for node in ast.walk(tree):
            if isinstance(node, ast.FunctionDef | ast.AsyncFunctionDef):
                for child in ast.walk(node):
                    enclosing.setdefault(child, node.name)
        for node in ast.walk(tree):
            if not isinstance(node, ast.Call):
                continue
            called = node.func
            name = called.attr if isinstance(called, ast.Attribute) else getattr(called, "id", "")
            if name != "access_for":
                continue
            if not any(keyword.arg == "granted" for keyword in node.keywords):
                where = enclosing.get(node, "<module>")
                missing.append(f"{path.relative_to(src)}::{where}:{node.lineno}")

    assert missing == [], (
        "every call to `access_for` must supply `granted=` — a call that forgets it reads a "
        "granted household as free, on one route while the others disagree. Found: "
        + ", ".join(missing)
    )


def test_the_call_site_walk_would_actually_catch_a_forgotten_grant() -> None:
    """**A test for the test.** A tripwire that cannot fire is worse than none.

    Exercised against the two shapes the real defect takes — a bare call, and one the formatter
    split — and against a correct call, so it is pinned in both directions.
    """
    import tempfile

    def offenders(source: str) -> list[str]:
        with tempfile.TemporaryDirectory() as tmp:
            root = pathlib.Path(tmp)
            (root / "candidate.py").write_text(source)
            found = []
            for path in root.rglob("*.py"):
                for node in ast.walk(ast.parse(path.read_text())):
                    if not isinstance(node, ast.Call):
                        continue
                    called = node.func
                    name = (
                        called.attr
                        if isinstance(called, ast.Attribute)
                        else getattr(called, "id", "")
                    )
                    if name == "access_for" and not any(
                        keyword.arg == "granted" for keyword in node.keywords
                    ):
                        found.append(str(node.lineno))
            return found

    assert offenders("def f(e):\n    return access_for(e).entitled\n")
    assert offenders(
        "def f(e, now):\n    return access_for(\n        e,\n        now=now,\n    )\n"
    )
    assert offenders("def f(e, now):\n    return guardians.access_for(e, now=now)\n")
    assert not offenders("def f(e, now):\n    return access_for(e, granted=True, now=now)\n")


def test_nothing_outside_the_grant_service_decides_when_a_grant_is_live() -> None:
    """The trial has one authority and so does this. **Same failure, same guard.**

    An ordering comparison against `EntitlementGrant.expires_at` anywhere but
    `services/grants.py` is a second opinion about when somebody's entitlement ended, and it is
    silent, because both answers look reasonable.

    `models/family.py::EntitlementGrant.status` is the one deliberate exception and it is
    allowed by name: it renders `active | expired | revoked` for the console from a row already
    in hand, and it must never become the gate. Everything that gates reads the SQL predicate.
    """
    src = pathlib.Path(__file__).resolve().parents[1] / "src" / "rascal"
    allowed = {("services/grants.py", "unexpired"), ("models/family.py", "EntitlementGrant.status")}
    assert sorted(_grant_expiry_comparisons(src)) == sorted(allowed), (
        "only `services/grants.unexpired` may decide when a grant is live, and only "
        "`EntitlementGrant.status` may render it. Found: "
        + ", ".join(
            f"{module}::{where}" for module, where in sorted(_grant_expiry_comparisons(src))
        )
    )


# --- The issuer's account, deleted -------------------------------------------------------------


async def test_deleting_the_issuing_admin_leaves_the_grant_standing(
    session: AsyncSession,
) -> None:
    """**The `ON DELETE` decision, pinned.** `SET NULL`, deliberately, and here is why.

    Account deletion hard-deletes `users` — the one exception to the soft-delete rule, phase 66
    — so `granted_by` needs an action and none of the other three works. `CASCADE` destroys the
    audit row, which is the opposite of an audit trail. `RESTRICT` makes an erasure request fail
    with an integrity error the deletion path has no branch for, in the one flow that must not
    raise. So the grant outlives the account that issued it, the household stays entitled, and
    the issuer reads as gone rather than as somebody else.
    """
    admin = await _admin(session)
    family, _ = await _household(session)
    grant = await _grant(session, family, admin)

    # The last statement `services/deletion.execute_deletion` runs, on its own. The FK action is
    # what is under test and it is a property of the schema rather than of that function — going
    # through the whole erasure would arrange a request row, a settings object and an S3 stub to
    # exercise one `ON DELETE`.
    await session.execute(delete(User).where(User.id == admin.id))
    await session.commit()

    await session.refresh(grant)
    assert grant.granted_by is None, "the issuer's id survived their erasure"
    assert await active_grant_for(session, family.id) is not None
    access = await access_for_family(session, family.id)
    assert access.entitled is True, "erasing an admin demoted a household they had granted"


async def _child_with_a_pool(session: AsyncSession, user: User):
    """A child and enough library that every slot a Saturday asks for has a candidate.

    Copied in shape from `test_entitlement_cadence.py::_pool` rather than imported, because a
    fixture shared between two files is a fixture one of them eventually changes for the other.
    More than one kind per slot on purpose: a pool holding only questions would let *"a granted
    household gets the whole day"* pass against an implementation that served nothing else.
    """
    from factories import make_child, make_prompt

    child = await make_child(session, name="Wren", parent=user)
    for kind, cadence, mode in [
        ("question", "daily", "text"),
        ("photo", "daily", "media"),
        ("audio", "daily", "media"),
        ("activity", "daily", "did_it"),
        ("activity", "weekly", "did_it"),
        ("measurement", "monthly", "text"),
        ("letter", "monthly", "text"),
    ]:
        await make_prompt(session, kind=kind, cadence=cadence, completion_mode=mode)
    await session.commit()
    return child


def _grant_expiry_comparisons(src: pathlib.Path) -> set[tuple[str, str]]:
    """Every ordering comparison under *src* that reads a grant's `expires_at`.

    **Class-aware, and it has to be.** `self.expires_at` appears in `GuardianInvite.is_open` and
    twice in `models/user.py` — three legitimate comparisons about entirely different rows — so a
    walk that matched on the attribute name alone would report them and be edited into silence
    the first time somebody read it. It resolves `self` to the enclosing class instead, and only
    `EntitlementGrant` counts.

    Returns `(module, qualified-name)` pairs so the assertion reads as *"exactly these two"*
    rather than as *"none"*, which is the stronger shape: a walk that stopped matching would
    otherwise pass by finding nothing.
    """
    found: set[tuple[str, str]] = set()
    for path in sorted(src.rglob("*.py")):
        tree = ast.parse(path.read_text(), filename=str(path))
        qualified: dict[ast.AST, str] = {}
        classes: dict[ast.AST, str] = {}
        for node in ast.walk(tree):
            if isinstance(node, ast.ClassDef):
                for member in ast.walk(node):
                    classes.setdefault(member, node.name)
        for node in ast.walk(tree):
            if isinstance(node, ast.FunctionDef | ast.AsyncFunctionDef):
                owner = classes.get(node)
                label = f"{owner}.{node.name}" if owner else node.name
                for member in ast.walk(node):
                    qualified.setdefault(member, label)
        for node in ast.walk(tree):
            if not isinstance(node, ast.Compare):
                continue
            if not any(isinstance(op, ast.Lt | ast.LtE | ast.Gt | ast.GtE) for op in node.ops):
                continue
            for operand in [node.left, *node.comparators]:
                for sub in ast.walk(operand):
                    if not (isinstance(sub, ast.Attribute) and sub.attr == "expires_at"):
                        continue
                    if not isinstance(sub.value, ast.Name):
                        continue
                    owner = sub.value.id
                    if owner == "self":
                        owner = classes.get(node, "")
                    if owner in {"EntitlementGrant", "grant"}:
                        found.add((str(path.relative_to(src)), qualified.get(node, "<module>")))
    return found


def test_the_grant_expiry_walk_would_actually_catch_a_second_authority(tmp_path) -> None:
    """**A test for the test**, in the shape `test_entitlement_cadence.py` established.

    Pinned in both directions, because the failure mode of a tripwire is passing forever: it has
    to fire on a real second opinion and stay quiet on the three legitimate `expires_at`
    comparisons this codebase already has about other rows.
    """
    (tmp_path / "impostor.py").write_text("def f(grant, now):\n    return grant.expires_at > now\n")
    assert _grant_expiry_comparisons(tmp_path)

    (tmp_path / "impostor.py").unlink()
    (tmp_path / "innocent.py").write_text(
        "class GuardianInvite:\n"
        "    def is_open(self, now):\n"
        "        return self.expires_at > now\n"
        "class Token:\n"
        "    def is_live(self, now):\n"
        "        return self.expires_at > now\n"
    )
    assert _grant_expiry_comparisons(tmp_path) == set(), (
        "the walk fires on somebody else's `expires_at` — it would be edited into silence"
    )
