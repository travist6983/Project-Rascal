"""`POST /families/me/transactions` — the app hands the server the receipt it already holds.

Phase 140, Sep 3, 2026. The evening before, the owner bought Monthly on a Sandbox Apple ID that
already held the annual: StoreKit said success, Apple sent `DID_CHANGE_RENEWAL_PREF` (no tier
effect), and the paywall polled `GET /families/me` for a `subscribed` that nothing was ever going
to write — because the app had no way to *tell* the server about a transaction it could see.
This route is that way. Every test here goes through Apple's real verifier against a locally
minted root, so what is proved is that the route verifies a signature, not that it parses JSON.

**The property that matters most is the one about what this route must NOT do**: never demote,
and never move a ledger row's `latest_signed_date` — a submission that advanced guard 1's
high-water mark would make a delayed `EXPIRED` look stale, and a paying household would stay
subscribed on a cancelled card.
"""

from __future__ import annotations

import datetime as dt
import logging
import uuid

import pytest
from httpx import ASGITransport, AsyncClient
from sqlalchemy import select

import app_store_stub as stub
from factories import make_child, make_family, make_user
from helpers import auth_headers
from rascal.config import get_settings
from rascal.deps import get_app_store_verifier
from rascal.models import AppStoreTransaction, Entitlement, Family, User
from rascal.services import deletion
from rascal.services.app_store import AppStoreVerifier

ROUTE = "/v1/families/me/transactions"
WEBHOOK = "/v1/webhooks/app-store"

SIGNED_AT = dt.datetime(2026, 6, 1, 12, 0, tzinfo=dt.UTC)
EXPIRES = dt.datetime(2036, 9, 3, 0, 0, tzinfo=dt.UTC)  # future-date: an active subscription
LAPSED = dt.datetime(2026, 1, 3, 0, 0, tzinfo=dt.UTC)  # past-date: one that has ended


async def _submit(client, user, signed: str):
    return await client.post(ROUTE, json={"signed_transaction": signed}, headers=auth_headers(user))


async def _notify(client, signed_payload: str):
    return await client.post(WEBHOOK, json={"signedPayload": signed_payload})


async def _entitlement(session, family_id) -> Entitlement:
    return await session.scalar(
        select(Entitlement)
        .where(Entitlement.family_id == family_id)
        .execution_options(populate_existing=True)
    )


async def _transaction(session, original_transaction_id: str) -> AppStoreTransaction | None:
    return await session.scalar(
        select(AppStoreTransaction)
        .where(AppStoreTransaction.original_transaction_id == original_transaction_id)
        .execution_options(populate_existing=True)
    )


async def _rows(session) -> int:
    return len((await session.execute(select(AppStoreTransaction.original_transaction_id))).all())


@pytest.fixture
async def production_client(app, app_store_settings):
    """The route as deployed: `ENVIRONMENT = "prod"`, so Sandbox is not simply honoured."""
    prod_settings = app_store_settings.model_copy(update={"environment": "prod"})
    app.dependency_overrides[get_app_store_verifier] = lambda: AppStoreVerifier(prod_settings)
    app.dependency_overrides[get_settings] = lambda: prod_settings
    transport = ASGITransport(app=app)
    async with AsyncClient(transport=transport, base_url="http://test") as client:
        yield client


# --- The purchase that motivated the route -------------------------------------------------------


async def test_a_fresh_purchase_is_subscribed_in_one_round_trip(
    app_store_client, session, app_store_chain
):
    """The ordinary case, with no notification in sight: the app posts the JWS and the answer is
    the household, already subscribed. No poll, no webhook, no waiting."""
    family = await make_family(session)
    parent = await make_user(session, family=family)
    await session.commit()

    response = await _submit(
        app_store_client,
        parent,
        stub.sign_transaction(
            app_store_chain,
            signed_date=SIGNED_AT,
            app_account_token=family.id,
            expires_date=EXPIRES,
        ),
    )

    assert response.status_code == 200, response.text
    body = response.json()
    assert body["status"] == "tier:subscribed"
    # The exact `GET /families/me` document, so the client renders it without a second read.
    assert body["family"]["family_id"] == str(family.id)
    assert body["family"]["tier"] == "subscribed"
    assert body["family"]["access"] == "subscribed"
    assert body["family"]["plan"] == "annual"

    entitlement = await _entitlement(session, family.id)
    assert entitlement.tier == "subscribed"
    assert entitlement.lapsed_at is None
    assert entitlement.payer_user_id == parent.id

    row = await _transaction(session, "2000000000000001")
    assert row is not None
    assert row.family_id == family.id
    assert row.environment == "Production"
    assert row.latest_notification_type == "SUBMITTED"
    assert row.latest_notification_subtype is None
    assert row.latest_signed_date == SIGNED_AT
    assert row.expires_date == EXPIRES
    assert row.product_id == stub.ANNUAL_PRODUCT_ID
    # The decoded claims, not the JWS — the same rule the notification ledger follows.
    assert row.raw_payload["originalTransactionId"] == "2000000000000001"
    assert row.raw_payload["environment"] == "Production"


async def test_submitting_twice_is_one_row_and_one_answer(
    app_store_client, session, app_store_chain
):
    family = await make_family(session)
    parent = await make_user(session, family=family)
    await session.commit()
    signed = stub.sign_transaction(
        app_store_chain, signed_date=SIGNED_AT, app_account_token=family.id, expires_date=EXPIRES
    )

    first = await _submit(app_store_client, parent, signed)
    second = await _submit(app_store_client, parent, signed)

    assert first.json()["status"] == "tier:subscribed"
    assert second.json()["status"] == "tier:subscribed"
    assert await _rows(session) == 1


async def test_the_sandbox_annual_the_owner_actually_held(
    app_store_client, session, app_store_chain
):
    """Sep 2, 2026, replayed: an active Sandbox annual on the Apple ID, a household reading `free`
    because every notification about it had been discarded, and a Monthly tap that produced no
    `SUBSCRIBED`. Under `ENVIRONMENT=local` (this client) Sandbox is honoured outright; the
    production rule is tested below."""
    family = await make_family(session)
    parent = await make_user(session, family=family)
    await session.commit()

    response = await _submit(
        app_store_client,
        parent,
        stub.sign_transaction(
            app_store_chain,
            signed_date=SIGNED_AT,
            environment="Sandbox",
            original_transaction_id="2000001226887447",
            app_account_token=family.id,
            expires_date=EXPIRES,
        ),
    )

    assert response.json()["status"] == "tier:subscribed"
    assert (await _entitlement(session, family.id)).tier == "subscribed"
    assert (await _transaction(session, "2000001226887447")).environment == "Sandbox"


# --- What the route refuses, and that it records nothing when it does ----------------------------


async def test_a_transaction_for_another_household_is_a_409_and_writes_nothing(
    app_store_client, session, app_store_chain
):
    """The token inside Apple's signature names the household the purchase was for. A caller
    presenting somebody else's receipt — a second account on the same phone, say — gets told so
    and nothing moves for either household."""
    mine = await make_family(session)
    me = await make_user(session, family=mine)
    theirs = await make_family(session)
    await make_user(session, family=theirs, display_name="Somebody")
    await session.commit()

    response = await _submit(
        app_store_client,
        me,
        stub.sign_transaction(
            app_store_chain,
            signed_date=SIGNED_AT,
            app_account_token=theirs.id,
            expires_date=EXPIRES,
        ),
    )

    assert response.status_code == 409
    assert response.json()["error"]["code"] == "conflict"
    assert (await _entitlement(session, mine.id)).tier == "free"
    assert (await _entitlement(session, theirs.id)).tier == "free"
    assert await _rows(session) == 0


# --- A receipt with no household tag follows the phone that holds it (phase 145) ------------------
#
# Until Sep 5, 2026 the test here was `test_a_transaction_with_no_token_is_a_409`: *"No
# `appAccountToken` means no proof of whose purchase it is, and the caller's word is not proof."*
# App Store Connect has Streamlined Purchasing on, and an offer code redeemed in the App Store app
# has the same shape — a subscription bought with this app not running carries no token, ever — so
# that rule locked out exactly the customer Apple was charging, from their own signed-in device.
# Owner-authorised the same day: a token-less receipt nobody holds follows the caller; one another
# household holds, empty or not, is still `409`.


async def test_a_receipt_with_no_token_follows_the_caller_when_nobody_holds_it(
    app_store_client, session, app_store_chain
):
    """The Streamlined Purchasing shape: no ledger row at all, because Apple's notification is
    still in flight or came and went unattributed and was never recorded (a `TEST`-era outage,
    say). The bearer token proves a member, the JWS proves an active subscription, and the phone
    presenting it is the one it was delivered to."""
    family = await make_family(session)
    parent = await make_user(session, family=family)
    await session.commit()

    response = await _submit(
        app_store_client,
        parent,
        stub.sign_transaction(app_store_chain, signed_date=SIGNED_AT, expires_date=EXPIRES),
    )

    assert response.status_code == 200, response.text
    assert response.json()["status"] == "tier:subscribed"
    row = await _transaction(session, "2000000000000001")
    assert row.family_id == family.id
    assert row.latest_notification_type == "SUBMITTED"
    entitlement = await _entitlement(session, family.id)
    assert entitlement.tier == "subscribed"
    assert entitlement.payer_user_id == parent.id, "one guardian, so the payer is not a guess"


async def test_a_receipt_with_no_token_claims_a_row_a_notification_left_orphaned(
    app_store_client, session, app_store_chain
):
    """The other Streamlined Purchasing shape, and the likelier one: Apple's `SUBSCRIBED` arrived
    first with no token, the webhook recorded it unattributed (correctly — a notification has no
    caller), and the phone launches afterwards. The row is claimed, its ordering key untouched."""
    family = await make_family(session)
    parent = await make_user(session, family=family)
    await session.commit()

    orphan = await _notify(
        app_store_client,
        stub.sign_notification(
            app_store_chain,
            notification_type="SUBSCRIBED",
            subtype="INITIAL_BUY",
            signed_date=SIGNED_AT,
            expires_date=EXPIRES,
        ),
    )
    assert orphan.json()["status"] == "recorded:unattributed"
    assert (await _transaction(session, "2000000000000001")).family_id is None

    response = await _submit(
        app_store_client,
        parent,
        stub.sign_transaction(
            app_store_chain, signed_date=SIGNED_AT + dt.timedelta(minutes=5), expires_date=EXPIRES
        ),
    )

    assert response.json()["status"] == "tier:subscribed"
    row = await _transaction(session, "2000000000000001")
    assert row.family_id == family.id
    assert row.latest_signed_date == SIGNED_AT, "a submission never moves the high-water mark"
    assert row.latest_notification_type == "SUBSCRIBED"
    assert (await _entitlement(session, family.id)).tier == "subscribed"


async def test_a_receipt_with_no_token_never_takes_a_row_another_household_holds(
    app_store_client, session, app_store_chain
):
    """A missing token names nobody, so it cannot outrank a ledger that names somebody. The
    stranger-with-the-bytes case, after the owner has already been attributed: `409`, and nothing
    moves for either household."""
    mine = await make_family(session)
    me = await make_user(session, family=mine)
    theirs = await make_family(session)
    await make_user(session, family=theirs, display_name="Somebody")
    await session.commit()
    bought = await _notify(
        app_store_client,
        stub.sign_notification(
            app_store_chain,
            notification_type="SUBSCRIBED",
            subtype="INITIAL_BUY",
            signed_date=SIGNED_AT,
            app_account_token=theirs.id,
            expires_date=EXPIRES,
        ),
    )
    assert bought.json()["status"] == "tier:subscribed"

    response = await _submit(
        app_store_client,
        me,
        stub.sign_transaction(
            app_store_chain, signed_date=SIGNED_AT + dt.timedelta(minutes=5), expires_date=EXPIRES
        ),
    )

    assert response.status_code == 409
    assert response.json()["error"]["code"] == "conflict"
    assert (await _entitlement(session, mine.id)).tier == "free"
    assert (await _entitlement(session, theirs.id)).tier == "subscribed"
    assert (await _transaction(session, "2000000000000001")).family_id == theirs.id


async def test_a_receipt_with_no_token_does_not_follow_the_caller_out_of_an_empty_household(
    app_store_client, session, app_store_chain
):
    """**Phase 143's move is deliberately not extended to token-less receipts**, and this pins it.
    A stale token names its ghost — the ledger and Apple agree where the receipt came from, and
    that place is empty. A missing token names nobody: there is no agreement to check and nothing
    to follow, so a row the ghost holds is a row somebody holds, and the answer is `409`."""
    ghost = await _household_whose_only_member_left(session, app_store_client, app_store_chain)
    mine = await make_family(session)
    me = await make_user(session, family=mine)
    await session.commit()

    response = await _submit(
        app_store_client,
        me,
        stub.sign_transaction(
            app_store_chain,
            signed_date=SIGNED_AT + dt.timedelta(days=1),
            environment="Sandbox",
            original_transaction_id=GHOST_TRANSACTION,
            expires_date=EXPIRES,
        ),
    )

    assert response.status_code == 409
    assert response.json()["error"]["code"] == "conflict"
    assert (await _transaction(session, GHOST_TRANSACTION)).family_id == ghost
    assert (await _entitlement(session, mine.id)).tier == "free"
    assert (await _entitlement(session, ghost)).tier == "subscribed"


async def test_a_receipt_with_no_token_that_has_expired_is_not_active(
    app_store_client, session, app_store_chain
):
    """The active rule is not relaxed for a token-less receipt: an ended period is Apple's to
    report through the door that may demote, and nothing is recorded here."""
    family = await make_family(session)
    parent = await make_user(session, family=family)
    await session.commit()

    response = await _submit(
        app_store_client,
        parent,
        stub.sign_transaction(app_store_chain, signed_date=SIGNED_AT, expires_date=LAPSED),
    )

    assert response.status_code == 200
    assert response.json()["status"] == "ignored:not-active"
    assert (await _entitlement(session, family.id)).tier == "free"
    assert await _rows(session) == 0


async def test_after_a_token_less_claim_apples_notifications_follow_the_ledger(
    app_store_client, session, app_store_chain
):
    """Apple will never attach a token to this subscription, so every later notification about it
    is an orphan to `_resolve_family` — and `apply_notification` falls back to the ledger row the
    claim wrote (`family_id = token_family_id or existing.family_id`). The renewal promotes the
    same household and the eventual `EXPIRED` demotes it, exactly as for a tagged receipt."""
    family = await make_family(session)
    parent = await make_user(session, family=family)
    await session.commit()
    claimed = await _submit(
        app_store_client,
        parent,
        stub.sign_transaction(app_store_chain, signed_date=SIGNED_AT, expires_date=EXPIRES),
    )
    assert claimed.json()["status"] == "tier:subscribed"

    renewed = await _notify(
        app_store_client,
        stub.sign_notification(
            app_store_chain,
            notification_type="DID_RENEW",
            signed_date=SIGNED_AT + dt.timedelta(days=30),
            expires_date=EXPIRES,
        ),
    )
    assert renewed.json()["status"] == "tier:subscribed", renewed.text
    row = await _transaction(session, "2000000000000001")
    assert row.family_id == family.id
    assert row.latest_notification_type == "DID_RENEW"
    assert (await _entitlement(session, family.id)).tier == "subscribed"

    expired = await _notify(
        app_store_client,
        stub.sign_notification(
            app_store_chain,
            notification_type="EXPIRED",
            subtype="VOLUNTARY",
            signed_date=SIGNED_AT + dt.timedelta(days=60),
            expires_date=SIGNED_AT + dt.timedelta(days=60),
        ),
    )
    assert expired.json()["status"] == "tier:free", expired.text
    entitlement = await _entitlement(session, family.id)
    assert entitlement.tier == "free"
    assert entitlement.lapsed_at == SIGNED_AT + dt.timedelta(days=60)


async def test_a_tampered_transaction_is_a_422_and_writes_nothing(
    app_store_client, session, app_store_chain
):
    family = await make_family(session)
    parent = await make_user(session, family=family)
    await session.commit()
    signed = stub.sign_transaction(
        app_store_chain, signed_date=SIGNED_AT, app_account_token=family.id, expires_date=EXPIRES
    )

    response = await _submit(app_store_client, parent, stub.tamper(signed))

    assert response.status_code == 422
    assert response.json()["error"]["code"] == "validation_failed"
    assert response.json()["error"]["field"] == "signed_transaction"
    assert (await _entitlement(session, family.id)).tier == "free"
    assert await _rows(session) == 0


async def test_garbage_is_a_422_not_a_500(app_store_client, session):
    family = await make_family(session)
    parent = await make_user(session, family=family)
    await session.commit()

    response = await _submit(app_store_client, parent, "not.a.jws")

    assert response.status_code == 422


async def test_a_transaction_for_another_app_is_a_422(app_store_client, session, app_store_chain):
    """`bundleId` is inside the signature and the verifier pins it, so a transaction Apple signed
    for some other app on the same developer account is refused, not applied."""
    family = await make_family(session)
    parent = await make_user(session, family=family)
    await session.commit()

    response = await _submit(
        app_store_client,
        parent,
        stub.sign_transaction(
            app_store_chain,
            signed_date=SIGNED_AT,
            app_account_token=family.id,
            expires_date=EXPIRES,
            bundle_id="com.travisterry.somethingelse",
        ),
    )

    assert response.status_code == 422
    assert (await _entitlement(session, family.id)).tier == "free"


async def test_an_anonymous_caller_is_a_401(app_store_client, app_store_chain):
    response = await app_store_client.post(
        ROUTE,
        json={
            "signed_transaction": stub.sign_transaction(
                app_store_chain, signed_date=SIGNED_AT, expires_date=EXPIRES
            )
        },
    )
    assert response.status_code == 401


async def test_an_empty_body_is_a_422(app_store_client, session):
    family = await make_family(session)
    parent = await make_user(session, family=family)
    await session.commit()

    response = await app_store_client.post(
        ROUTE, json={"signed_transaction": ""}, headers=auth_headers(parent)
    )
    assert response.status_code == 422


# --- This door only promotes ----------------------------------------------------------------------


async def test_an_expired_transaction_does_nothing(app_store_client, session, app_store_chain):
    """A lapse is Apple's to report. A client that could write its own `lapsed_at` by restoring
    an old receipt would be a client deciding entitlement, which D5 forbids in both directions."""
    family = await make_family(session)
    parent = await make_user(session, family=family)
    await session.commit()

    response = await _submit(
        app_store_client,
        parent,
        stub.sign_transaction(
            app_store_chain, signed_date=SIGNED_AT, app_account_token=family.id, expires_date=LAPSED
        ),
    )

    assert response.status_code == 200
    assert response.json()["status"] == "ignored:not-active"
    assert response.json()["family"]["tier"] == "free"
    assert (await _entitlement(session, family.id)).tier == "free"
    assert await _rows(session) == 0


async def test_a_revoked_transaction_does_nothing(app_store_client, session, app_store_chain):
    family = await make_family(session)
    parent = await make_user(session, family=family)
    await session.commit()

    response = await _submit(
        app_store_client,
        parent,
        stub.sign_transaction(
            app_store_chain,
            signed_date=SIGNED_AT,
            app_account_token=family.id,
            expires_date=EXPIRES,
            revocation_date=SIGNED_AT,
        ),
    )

    assert response.json()["status"] == "ignored:not-active"
    assert (await _entitlement(session, family.id)).tier == "free"
    assert await _rows(session) == 0


async def test_an_expired_transaction_never_demotes_a_subscribed_household(
    app_store_client, session, app_store_chain
):
    """The other half of "only promotes": a household the server calls subscribed stays so
    whatever old receipt the phone sends up."""
    family = await make_family(session, tier="subscribed")
    parent = await make_user(session, family=family)
    await session.commit()

    response = await _submit(
        app_store_client,
        parent,
        stub.sign_transaction(
            app_store_chain, signed_date=SIGNED_AT, app_account_token=family.id, expires_date=LAPSED
        ),
    )

    assert response.json()["status"] == "ignored:not-active"
    assert (await _entitlement(session, family.id)).tier == "subscribed"


async def test_a_subscription_with_no_expiry_is_not_active(
    app_store_client, session, app_store_chain
):
    """Apple always sends `expiresDate` on a subscription transaction. One without it is not
    "active until further notice" — this door never invents an entitlement from a claim the
    payload omitted, any more than the webhook does. Found by review; the first version promoted."""
    family = await make_family(session)
    parent = await make_user(session, family=family)
    await session.commit()

    response = await _submit(
        app_store_client,
        parent,
        stub.sign_transaction(app_store_chain, signed_date=SIGNED_AT, app_account_token=family.id),
    )

    assert response.json()["status"] == "ignored:not-active"
    assert (await _entitlement(session, family.id)).tier == "free"
    assert await _rows(session) == 0


async def test_a_receipt_from_before_a_refund_cannot_resurrect_it(
    app_store_client, session, app_store_chain
):
    """**The hazard review found in the first version.** Apple signs `SUBSCRIBED` at T and a
    `REFUND` at T+1h; the household is `free` with `lapsed_at = T+1h`. The phone still holds the
    JWS StoreKit fetched at T — facially active, `expiresDate` a year out, no `revocationDate`,
    because the refund happened after it was signed. Submitting it must not flip the household
    back: a receipt is Apple's word *as of its signedDate*, and the refund is a newer word."""
    family = await make_family(session)
    parent = await make_user(session, family=family)
    await session.commit()

    bought = await _notify(
        app_store_client,
        stub.sign_notification(
            app_store_chain,
            notification_type="SUBSCRIBED",
            subtype="INITIAL_BUY",
            signed_date=SIGNED_AT,
            app_account_token=family.id,
            expires_date=EXPIRES,
        ),
    )
    assert bought.json()["status"] == "tier:subscribed"
    refunded = await _notify(
        app_store_client,
        stub.sign_notification(
            app_store_chain,
            notification_type="REFUND",
            signed_date=SIGNED_AT + dt.timedelta(hours=1),
            app_account_token=family.id,
            expires_date=EXPIRES,
        ),
    )
    assert refunded.json()["status"] == "tier:free"
    assert (await _entitlement(session, family.id)).tier == "free"

    stale = await _submit(
        app_store_client,
        parent,
        stub.sign_transaction(
            app_store_chain,
            signed_date=SIGNED_AT,
            app_account_token=family.id,
            expires_date=EXPIRES,
        ),
    )

    assert stale.status_code == 200
    assert stale.json()["status"] == "ignored:out-of-order"
    assert stale.json()["family"]["tier"] == "free"
    entitlement = await _entitlement(session, family.id)
    assert entitlement.tier == "free"
    assert entitlement.lapsed_at == SIGNED_AT + dt.timedelta(hours=1)
    row = await _transaction(session, "2000000000000001")
    assert row.latest_notification_type == "REFUND"


async def test_a_lapse_recorded_on_the_row_but_not_the_household_still_blocks_a_stale_receipt(
    app_store_client, session, app_store_chain
):
    """The row's own latest word is a demotion, newer than the receipt — refused even when the
    household's `lapsed_at` says nothing (a demotion guard 4 refused, or a household that has
    since been promoted on another subscription and then hand-reset)."""
    family = await make_family(session)
    parent = await make_user(session, family=family)
    await session.commit()

    # An EXPIRED for a transaction this household never linked: guard 4 refuses the demotion
    # and records the row unattributed, so `lapsed_at` stays NULL and the row says EXPIRED.
    expired = await _notify(
        app_store_client,
        stub.sign_notification(
            app_store_chain,
            notification_type="EXPIRED",
            subtype="VOLUNTARY",
            signed_date=SIGNED_AT + dt.timedelta(hours=1),
            app_account_token=family.id,
            expires_date=SIGNED_AT + dt.timedelta(hours=1),
        ),
    )
    assert expired.json()["status"] == "recorded:demotion-refused"
    assert (await _entitlement(session, family.id)).lapsed_at is None

    stale = await _submit(
        app_store_client,
        parent,
        stub.sign_transaction(
            app_store_chain,
            signed_date=SIGNED_AT,
            app_account_token=family.id,
            expires_date=EXPIRES,
        ),
    )

    assert stale.json()["status"] == "ignored:out-of-order"
    assert (await _entitlement(session, family.id)).tier == "free"
    assert (await _transaction(session, "2000000000000001")).family_id is None


async def test_a_receipt_from_after_the_lapse_promotes_again(
    app_store_client, session, app_store_chain
):
    """The guard is about ordering, not about lapsed households: a parent who lapsed and then
    bought again holds a receipt signed *after* `lapsed_at`, and that one counts — the same shape
    as Apple's own `SUBSCRIBED / RESUBSCRIBE`, which may well still be in flight."""
    family = await make_family(session)
    parent = await make_user(session, family=family)
    await session.commit()

    await _notify(
        app_store_client,
        stub.sign_notification(
            app_store_chain,
            notification_type="SUBSCRIBED",
            subtype="INITIAL_BUY",
            signed_date=SIGNED_AT,
            app_account_token=family.id,
            expires_date=SIGNED_AT + dt.timedelta(days=30),
        ),
    )
    lapsed = await _notify(
        app_store_client,
        stub.sign_notification(
            app_store_chain,
            notification_type="EXPIRED",
            subtype="VOLUNTARY",
            signed_date=SIGNED_AT + dt.timedelta(days=30),
            app_account_token=family.id,
            expires_date=SIGNED_AT + dt.timedelta(days=30),
        ),
    )
    assert lapsed.json()["status"] == "tier:free"

    resubscribed = await _submit(
        app_store_client,
        parent,
        stub.sign_transaction(
            app_store_chain,
            signed_date=SIGNED_AT + dt.timedelta(days=45),
            app_account_token=family.id,
            expires_date=EXPIRES,
        ),
    )

    assert resubscribed.json()["status"] == "tier:subscribed"
    entitlement = await _entitlement(session, family.id)
    assert entitlement.tier == "subscribed"
    assert entitlement.lapsed_at is None
    # The row keeps the notification stream's word — the ordering key is not the submission's.
    row = await _transaction(session, "2000000000000001")
    assert row.latest_notification_type == "EXPIRED"
    assert row.latest_signed_date == SIGNED_AT + dt.timedelta(days=30)


async def test_a_non_subscription_product_does_nothing(app_store_client, session, app_store_chain):
    family = await make_family(session)
    parent = await make_user(session, family=family)
    await session.commit()

    response = await _submit(
        app_store_client,
        parent,
        stub.sign_transaction(
            app_store_chain,
            signed_date=SIGNED_AT,
            app_account_token=family.id,
            product_id=stub.UNKNOWN_PRODUCT_ID,
            transaction_type="Non-Consumable",
        ),
    )

    assert response.json()["status"] == "ignored:not-a-subscription"
    assert (await _entitlement(session, family.id)).tier == "free"
    assert await _rows(session) == 0


# --- The ledger: a submission never outranks a notification --------------------------------------


async def test_a_submission_never_advances_the_high_water_mark(
    app_store_client, session, app_store_chain
):
    """The defect this route could have introduced, pinned.

    Apple signs a `SUBSCRIBED` at T. The parent taps Restore two hours later and the phone sends
    a JWS StoreKit signed at T+2h. Apple's `EXPIRED`, signed at T+1h, arrives *after* that — a
    retry, an outage, an ordinary afternoon. If the submission had moved `latest_signed_date` to
    T+2h, guard 1 would call the `EXPIRED` stale and the household would keep `subscribed` on a
    subscription that has ended. It must be recorded and it must demote."""
    family = await make_family(session)
    parent = await make_user(session, family=family)
    await session.commit()
    t0 = SIGNED_AT

    subscribed = await _notify(
        app_store_client,
        stub.sign_notification(
            app_store_chain,
            notification_type="SUBSCRIBED",
            subtype="INITIAL_BUY",
            signed_date=t0,
            app_account_token=family.id,
            expires_date=EXPIRES,
        ),
    )
    assert subscribed.json()["status"] == "tier:subscribed"

    restored = await _submit(
        app_store_client,
        parent,
        stub.sign_transaction(
            app_store_chain,
            signed_date=t0 + dt.timedelta(hours=2),
            app_account_token=family.id,
            expires_date=EXPIRES,
        ),
    )
    assert restored.json()["status"] == "tier:subscribed"

    row = await _transaction(session, "2000000000000001")
    assert row.latest_signed_date == t0, "the submission moved guard 1's high-water mark"
    assert row.latest_notification_type == "SUBSCRIBED"
    assert row.latest_notification_subtype == "INITIAL_BUY"
    assert row.raw_payload["notificationType"] == "SUBSCRIBED"

    expired = await _notify(
        app_store_client,
        stub.sign_notification(
            app_store_chain,
            notification_type="EXPIRED",
            subtype="VOLUNTARY",
            signed_date=t0 + dt.timedelta(hours=1),
            app_account_token=family.id,
            expires_date=t0 + dt.timedelta(hours=1),
        ),
    )
    assert expired.json()["status"] == "tier:free", expired.text
    assert (await _entitlement(session, family.id)).tier == "free"


async def test_a_submission_attributes_a_row_a_notification_left_orphaned(
    app_store_client, session, app_store_chain
):
    """The pre-phase-139 shape of App Review's row: recorded, `family_id` NULL, tier untouched.
    The app can now close that on its own — and the notification's own ordering key stays."""
    family = await make_family(session)
    parent = await make_user(session, family=family)
    await session.commit()

    orphan = await _notify(
        app_store_client,
        stub.sign_notification(
            app_store_chain,
            notification_type="SUBSCRIBED",
            subtype="INITIAL_BUY",
            signed_date=SIGNED_AT,
            expires_date=EXPIRES,
        ),
    )
    assert orphan.json()["status"] == "recorded:unattributed"
    assert (await _transaction(session, "2000000000000001")).family_id is None

    response = await _submit(
        app_store_client,
        parent,
        stub.sign_transaction(
            app_store_chain,
            signed_date=SIGNED_AT + dt.timedelta(minutes=5),
            app_account_token=family.id,
            expires_date=EXPIRES,
        ),
    )

    assert response.json()["status"] == "tier:subscribed"
    row = await _transaction(session, "2000000000000001")
    assert row.family_id == family.id
    assert row.latest_signed_date == SIGNED_AT
    assert row.latest_notification_type == "SUBSCRIBED"
    assert (await _entitlement(session, family.id)).tier == "subscribed"


async def test_a_row_the_ledger_attributes_elsewhere_is_a_409(
    app_store_client, session, app_store_chain
):
    """Apple's token says the caller; the ledger says another household. Nobody here can settle
    that, so nothing moves — the notification path logs the same disagreement and proceeds on
    Apple's word because that is Apple speaking; a client is not."""
    mine = await make_family(session)
    me = await make_user(session, family=mine)
    theirs = await make_family(session)
    await make_user(session, family=theirs, display_name="Somebody")
    await session.commit()

    await _notify(
        app_store_client,
        stub.sign_notification(
            app_store_chain,
            notification_type="SUBSCRIBED",
            subtype="INITIAL_BUY",
            signed_date=SIGNED_AT,
            app_account_token=theirs.id,
            expires_date=EXPIRES,
        ),
    )

    response = await _submit(
        app_store_client,
        me,
        stub.sign_transaction(
            app_store_chain,
            signed_date=SIGNED_AT + dt.timedelta(minutes=5),
            app_account_token=mine.id,
            expires_date=EXPIRES,
        ),
    )

    assert response.status_code == 409
    assert (await _entitlement(session, mine.id)).tier == "free"
    assert (await _transaction(session, "2000000000000001")).family_id == theirs.id


async def test_one_transaction_id_belongs_to_one_environment(
    app_store_client, session, app_store_chain
):
    family = await make_family(session)
    parent = await make_user(session, family=family)
    await session.commit()

    await _notify(
        app_store_client,
        stub.sign_notification(
            app_store_chain,
            notification_type="SUBSCRIBED",
            subtype="INITIAL_BUY",
            signed_date=SIGNED_AT,
            environment="Production",
            app_account_token=family.id,
            expires_date=EXPIRES,
        ),
    )

    response = await _submit(
        app_store_client,
        parent,
        stub.sign_transaction(
            app_store_chain,
            signed_date=SIGNED_AT + dt.timedelta(minutes=5),
            environment="Sandbox",
            app_account_token=family.id,
            expires_date=EXPIRES,
        ),
    )

    assert response.json()["status"] == "ignored:environment-mismatch"
    assert (await _transaction(session, "2000000000000001")).environment == "Production"


# --- Production wins, and Sandbox only ever promotes — the same rule as the webhook ---------------


async def test_app_review_submits_in_sandbox_and_production_honours_it(
    production_client, session, app_store_chain
):
    """Guard 3 for the second door: the reviewer's household has no Production row, so their
    Sandbox purchase promotes — in one round trip now, whatever Apple's notification does."""
    family = await make_family(session)
    reviewer = await make_user(session, family=family)
    await session.commit()

    response = await _submit(
        production_client,
        reviewer,
        stub.sign_transaction(
            app_store_chain,
            signed_date=SIGNED_AT,
            environment="Sandbox",
            app_account_token=family.id,
            expires_date=EXPIRES,
        ),
    )

    assert response.json()["status"] == "tier:subscribed"
    assert (await _entitlement(session, family.id)).tier == "subscribed"
    assert (await _transaction(session, "2000000000000001")).environment == "Sandbox"


async def test_a_sandbox_submission_cannot_touch_a_household_production_has_spoken_about(
    production_client, session, app_store_chain
):
    """A paying household whose card failed reads `free` from a Production `EXPIRED`. A TestFlight
    build on the same account submitting a Sandbox receipt must not resurrect it."""
    family = await make_family(session)
    parent = await make_user(session, family=family)
    await session.commit()

    bought = await _notify(
        production_client,
        stub.sign_notification(
            app_store_chain,
            notification_type="SUBSCRIBED",
            subtype="INITIAL_BUY",
            signed_date=SIGNED_AT,
            environment="Production",
            original_transaction_id="1000000000000001",
            app_account_token=family.id,
            expires_date=EXPIRES,
        ),
    )
    assert bought.json()["status"] == "tier:subscribed"
    lapsed = await _notify(
        production_client,
        stub.sign_notification(
            app_store_chain,
            notification_type="EXPIRED",
            subtype="BILLING_RETRY",
            signed_date=SIGNED_AT + dt.timedelta(days=30),
            environment="Production",
            original_transaction_id="1000000000000001",
            app_account_token=family.id,
            expires_date=SIGNED_AT + dt.timedelta(days=30),
        ),
    )
    assert lapsed.json()["status"] == "tier:free"

    response = await _submit(
        production_client,
        parent,
        stub.sign_transaction(
            app_store_chain,
            signed_date=SIGNED_AT + dt.timedelta(days=31),
            environment="Sandbox",
            original_transaction_id="2000000000000009",
            app_account_token=family.id,
            expires_date=EXPIRES,
        ),
    )

    assert response.json()["status"] == "ignored:sandbox-blocked"
    assert (await _entitlement(session, family.id)).tier == "free"
    assert await _transaction(session, "2000000000000009") is None


async def test_the_owners_household_in_production_on_sep_3(
    production_client, session, app_store_chain
):
    """The row as production held it at 23:48 UTC: Sandbox, attributed by the 139 code, latest
    type `DID_CHANGE_RENEWAL_PREF`, tier still `free`. The phone submits the annual it holds."""
    family = await make_family(session)
    owner = await make_user(session, family=family)
    await session.commit()

    downgrade = await _notify(
        production_client,
        stub.sign_notification(
            app_store_chain,
            notification_type="DID_CHANGE_RENEWAL_PREF",
            subtype="DOWNGRADE",
            signed_date=SIGNED_AT,
            environment="Sandbox",
            original_transaction_id="2000001226887447",
            app_account_token=family.id,
            expires_date=EXPIRES,
        ),
    )
    assert downgrade.json()["status"] == "recorded:no-tier-change"
    assert (await _entitlement(session, family.id)).tier == "free"

    response = await _submit(
        production_client,
        owner,
        stub.sign_transaction(
            app_store_chain,
            signed_date=SIGNED_AT + dt.timedelta(seconds=2),
            environment="Sandbox",
            original_transaction_id="2000001226887447",
            app_account_token=family.id,
            expires_date=EXPIRES,
        ),
    )

    assert response.json()["status"] == "tier:subscribed"
    assert response.json()["family"]["access"] == "subscribed"
    assert (await _entitlement(session, family.id)).tier == "subscribed"
    row = await _transaction(session, "2000001226887447")
    assert row.latest_notification_type == "DID_CHANGE_RENEWAL_PREF"
    assert row.latest_signed_date == SIGNED_AT


# --- The receipt whose household has nobody left in it (phase 143) --------------------------------
#
# Sep 3, 2026, 10:17Z, 10:51Z and 10:52Z in production: `POST /families/me/transactions` answered
# `409` three times, for two live households, and the paywall came back. The receipt was the
# owner's Sandbox annual, `2000001226887447`, whose `appAccountToken` names the household he bought
# it in — and that household's only member had since run account deletion. `execute_deletion`
# removes `users` and `guardians` and deliberately leaves `families` and `entitlements` standing,
# so the ledger row was attributed to a household reading `tier=subscribed` with nobody in it, and
# the `409` that protects a household from a stranger's replay was protecting an empty room.

GHOST_TRANSACTION = "2000001226887447"


async def _household_whose_only_member_left(session, client, chain) -> uuid.UUID:
    """The production shape, arranged in production's order: a member buys, Apple's `SUBSCRIBED`
    attributes the ledger row and promotes the household, and *then* the member erases their
    account. Running the real deletion rather than omitting the user is the point — the guard is
    about the state the erasure leaves behind, and `test_app_store.py`'s erased-household tests
    make the same choice for the same reason."""
    family = await make_family(session)
    member = await make_user(session, family=family)
    await make_child(session, parent=member)
    await session.commit()

    bought = await _notify(
        client,
        stub.sign_notification(
            chain,
            notification_type="SUBSCRIBED",
            subtype="INITIAL_BUY",
            signed_date=SIGNED_AT,
            environment="Sandbox",
            original_transaction_id=GHOST_TRANSACTION,
            app_account_token=family.id,
            expires_date=EXPIRES,
        ),
    )
    assert bought.json()["status"] == "tier:subscribed"

    await deletion.request_deletion(session, member)
    await session.commit()
    await deletion.run_due_deletions(
        session, get_settings(), now=dt.datetime.now(tz=dt.UTC) + dt.timedelta(days=8)
    )
    assert await session.get(User, member.id) is None
    assert await session.get(Family, family.id) is not None
    assert (await _entitlement(session, family.id)).tier == "subscribed"
    assert (await _transaction(session, GHOST_TRANSACTION)).family_id == family.id
    return family.id


def _stale_receipt(chain, ghost_id: uuid.UUID, *, signed_at: dt.datetime) -> str:
    """The JWS the phone still holds: Apple's signature over the household it was bought in."""
    return stub.sign_transaction(
        chain,
        signed_date=signed_at,
        environment="Sandbox",
        original_transaction_id=GHOST_TRANSACTION,
        app_account_token=ghost_id,
        expires_date=EXPIRES,
    )


async def test_a_receipt_whose_household_has_nobody_left_follows_the_caller(
    app_store_client, session, app_store_chain, caplog
):
    """**Case (a), the reported symptom.** The same person, in a new household, submits the
    receipt Apple signed for the household they erased. Before phase 143: `409`, and a paywall in
    the face of somebody Apple is charging. Now: the receipt follows the caller, the ledger row
    moves with it, and the move is logged loudly enough to be found."""
    ghost = await _household_whose_only_member_left(session, app_store_client, app_store_chain)
    mine = await make_family(session)
    me = await make_user(session, family=mine)
    await session.commit()

    with caplog.at_level(logging.WARNING, logger="rascal.app_store.events"):
        response = await _submit(
            app_store_client,
            me,
            _stale_receipt(app_store_chain, ghost, signed_at=SIGNED_AT + dt.timedelta(days=1)),
        )

    assert response.status_code == 200, response.text
    assert response.json()["status"] == "tier:subscribed"
    assert response.json()["family"]["family_id"] == str(mine.id)
    assert response.json()["family"]["tier"] == "subscribed"

    entitlement = await _entitlement(session, mine.id)
    assert entitlement.tier == "subscribed"
    assert entitlement.lapsed_at is None
    assert entitlement.payer_user_id == me.id

    row = await _transaction(session, GHOST_TRANSACTION)
    assert row.family_id == mine.id, "the ledger row did not follow the caller"
    # The notification's ordering key is still the notification's: a move is not a rewrite.
    assert row.latest_signed_date == SIGNED_AT
    assert row.latest_notification_type == "SUBSCRIBED"

    moved = [
        r
        for r in caplog.records
        if r.getMessage() == "submitted transaction reattributed from empty household"
    ]
    assert len(moved) == 1, caplog.text
    assert moved[0].original_transaction_id == GHOST_TRANSACTION
    assert moved[0].from_family_id == str(ghost)
    assert moved[0].to_family_id == str(mine.id)


async def test_the_empty_households_entitlement_is_left_exactly_as_it_was(
    app_store_client, session, app_store_chain
):
    """**Case (f).** A submission may only promote (D5, as amended by phase 140), and that holds
    for the household it is moving *away from* as much as the one it is moving to: the ghost keeps
    its `subscribed`, because writing `free` to it would be this door demoting something — and
    there is nobody left in it to be either helped or harmed by the correction."""
    ghost = await _household_whose_only_member_left(session, app_store_client, app_store_chain)
    before = await _entitlement(session, ghost)
    assert before.tier == "subscribed"
    mine = await make_family(session)
    me = await make_user(session, family=mine)
    await session.commit()

    response = await _submit(
        app_store_client,
        me,
        _stale_receipt(app_store_chain, ghost, signed_at=SIGNED_AT + dt.timedelta(days=1)),
    )
    assert response.json()["status"] == "tier:subscribed"

    after = await _entitlement(session, ghost)
    assert after.tier == "subscribed"
    assert after.lapsed_at is None
    assert after.payer_user_id == before.payer_user_id
    assert after.updated_at == before.updated_at


async def test_a_household_that_still_has_a_member_keeps_its_receipt(
    app_store_client, session, app_store_chain
):
    """**Case (b), unchanged.** The other household has a parent with a child: that is somebody's
    archive, and a second account presenting its receipt is exactly the replay the `409` exists
    for. Nothing moves, for either household."""
    mine = await make_family(session)
    me = await make_user(session, family=mine)
    theirs = await make_family(session)
    somebody = await make_user(session, family=theirs, display_name="Somebody")
    await make_child(session, parent=somebody)
    await session.commit()

    response = await _submit(
        app_store_client,
        me,
        stub.sign_transaction(
            app_store_chain,
            signed_date=SIGNED_AT,
            app_account_token=theirs.id,
            expires_date=EXPIRES,
        ),
    )

    assert response.status_code == 409
    assert response.json()["error"]["code"] == "conflict"
    assert (await _entitlement(session, mine.id)).tier == "free"
    assert (await _entitlement(session, theirs.id)).tier == "free"
    assert await _rows(session) == 0


async def test_a_member_with_no_children_yet_is_still_a_member(
    app_store_client, session, app_store_chain
):
    """**The definition of "nobody left", pinned.** Emptiness is counted in `users`, not in
    `guardians`: a parent who has signed up and not yet added a child has no `guardians` row and is
    still in the household, still able to sign in, and still the person whose household the
    receipt names. Counting guardian rows would call this household empty and hand its receipt to
    whoever asked."""
    mine = await make_family(session)
    me = await make_user(session, family=mine)
    theirs = await make_family(session)
    await make_user(session, family=theirs, display_name="No kids yet")
    await session.commit()

    response = await _submit(
        app_store_client,
        me,
        stub.sign_transaction(
            app_store_chain,
            signed_date=SIGNED_AT,
            app_account_token=theirs.id,
            expires_date=EXPIRES,
        ),
    )

    assert response.status_code == 409
    assert await _rows(session) == 0


async def test_a_token_naming_no_household_at_all_is_still_a_409(
    app_store_client, session, app_store_chain
):
    """**Case (d).** A household with nobody in it has a `families` row; a UUID nothing resolves
    to does not. The second is a receipt this server has no record of at all, and it is refused
    exactly as it was — "no household" is not a degenerate case of "empty household"."""
    mine = await make_family(session)
    me = await make_user(session, family=mine)
    await session.commit()

    response = await _submit(
        app_store_client,
        me,
        stub.sign_transaction(
            app_store_chain,
            signed_date=SIGNED_AT,
            app_account_token=uuid.uuid4(),
            expires_date=EXPIRES,
        ),
    )

    assert response.status_code == 409
    assert (await _entitlement(session, mine.id)).tier == "free"
    assert await _rows(session) == 0


async def test_a_ledger_row_held_by_a_third_household_does_not_move(
    app_store_client, session, app_store_chain
):
    """The move is permitted in one case only: the ledger agrees with Apple's token about which
    household the receipt was for, and that household is empty. Apple's token naming an empty
    household while the ledger names a *third*, living one is a disagreement nobody here can
    settle, and the answer stays what phase 140 made it — touch nothing."""
    ghost = await _household_whose_only_member_left(session, app_store_client, app_store_chain)
    third = await make_family(session)
    await make_user(session, family=third, display_name="Third")
    row = await _transaction(session, GHOST_TRANSACTION)
    row.family_id = third.id
    await session.commit()
    mine = await make_family(session)
    me = await make_user(session, family=mine)
    await session.commit()

    response = await _submit(
        app_store_client,
        me,
        _stale_receipt(app_store_chain, ghost, signed_at=SIGNED_AT + dt.timedelta(days=1)),
    )

    assert response.status_code == 409
    assert (await _entitlement(session, mine.id)).tier == "free"
    assert (await _transaction(session, GHOST_TRANSACTION)).family_id == third.id


async def test_a_pre_refund_receipt_cannot_leave_the_household_it_was_refunded_in(
    app_store_client, session, app_store_chain
):
    """**Found in review before this shipped.** The lapse for a receipt is recorded against the
    household it was bought in; the caller's new household has never heard of the subscription
    and its `lapsed_at` is `None`. So a `REFUND`, then a neutral notification that becomes the
    row's latest word, then the erasure, then the pre-refund JWS the phone still holds from a new
    household: neither of phase 140's two lapse checks would fire on the caller's side alone, and
    a refunded subscription would have walked into a new household `subscribed`. The moving
    receipt's lapse is read from the household it is leaving as well."""
    old = await make_family(session)
    member = await make_user(session, family=old)
    await make_child(session, parent=member)
    await session.commit()
    t0 = SIGNED_AT
    bought = await _notify(
        app_store_client,
        stub.sign_notification(
            app_store_chain,
            notification_type="SUBSCRIBED",
            subtype="INITIAL_BUY",
            signed_date=t0,
            app_account_token=old.id,
            expires_date=EXPIRES,
        ),
    )
    assert bought.json()["status"] == "tier:subscribed"
    refunded = await _notify(
        app_store_client,
        stub.sign_notification(
            app_store_chain,
            notification_type="REFUND",
            signed_date=t0 + dt.timedelta(days=1),
            app_account_token=old.id,
            expires_date=EXPIRES,
        ),
    )
    assert refunded.json()["status"] == "tier:free"
    neutral = await _notify(
        app_store_client,
        stub.sign_notification(
            app_store_chain,
            notification_type="DID_CHANGE_RENEWAL_STATUS",
            subtype="AUTO_RENEW_DISABLED",
            signed_date=t0 + dt.timedelta(days=2),
            app_account_token=old.id,
            expires_date=EXPIRES,
        ),
    )
    assert neutral.json()["status"] == "recorded:no-tier-change"
    await deletion.request_deletion(session, member)
    await session.commit()
    await deletion.run_due_deletions(
        session, get_settings(), now=dt.datetime.now(tz=dt.UTC) + dt.timedelta(days=8)
    )
    assert (await _entitlement(session, old.id)).lapsed_at == t0 + dt.timedelta(days=1)
    mine = await make_family(session)
    me = await make_user(session, family=mine)
    await session.commit()

    response = await _submit(
        app_store_client,
        me,
        stub.sign_transaction(
            app_store_chain,
            signed_date=t0 + dt.timedelta(hours=1),
            app_account_token=old.id,
            expires_date=EXPIRES,
        ),
    )

    assert response.status_code == 200
    assert response.json()["status"] == "ignored:out-of-order"
    assert (await _entitlement(session, mine.id)).tier == "free"
    assert (await _transaction(session, "2000000000000001")).family_id == old.id


async def test_after_the_move_apples_notifications_with_the_stale_token_follow_the_ledger(
    app_store_client, session, app_store_chain
):
    """**Case (e).** Apple does not know the household moved: every later notification for this
    subscription carries the token of the household it was bought in. Before phase 143 a
    `DID_RENEW` would have reached the ghost (and been refused by guard 5), and an `EXPIRED` would
    have demoted the ghost while the household actually holding the membership kept it on a
    cancelled card. Both now follow the ledger to where the receipt lives."""
    ghost = await _household_whose_only_member_left(session, app_store_client, app_store_chain)
    mine = await make_family(session)
    me = await make_user(session, family=mine)
    await session.commit()
    moved = await _submit(
        app_store_client,
        me,
        _stale_receipt(app_store_chain, ghost, signed_at=SIGNED_AT + dt.timedelta(days=1)),
    )
    assert moved.json()["status"] == "tier:subscribed"

    renewed = await _notify(
        app_store_client,
        stub.sign_notification(
            app_store_chain,
            notification_type="DID_RENEW",
            signed_date=SIGNED_AT + dt.timedelta(days=30),
            environment="Sandbox",
            original_transaction_id=GHOST_TRANSACTION,
            app_account_token=ghost,
            expires_date=EXPIRES,
        ),
    )
    assert renewed.json()["status"] == "tier:subscribed", renewed.text
    assert (await _transaction(session, GHOST_TRANSACTION)).family_id == mine.id
    assert (await _entitlement(session, mine.id)).tier == "subscribed"

    expired = await _notify(
        app_store_client,
        stub.sign_notification(
            app_store_chain,
            notification_type="EXPIRED",
            subtype="VOLUNTARY",
            signed_date=SIGNED_AT + dt.timedelta(days=60),
            environment="Sandbox",
            original_transaction_id=GHOST_TRANSACTION,
            app_account_token=ghost,
            expires_date=SIGNED_AT + dt.timedelta(days=60),
        ),
    )
    assert expired.json()["status"] == "tier:free", expired.text
    live = await _entitlement(session, mine.id)
    assert live.tier == "free"
    assert live.lapsed_at == SIGNED_AT + dt.timedelta(days=60)
    # The ghost is not the notification's household any more, and nothing here writes to it.
    assert (await _entitlement(session, ghost)).tier == "subscribed"
    assert (await _transaction(session, GHOST_TRANSACTION)).family_id == mine.id


async def test_a_stale_token_naming_a_living_household_still_follows_the_token(
    app_store_client, session, app_store_chain
):
    """The other branch of the same fork, unchanged: when the token's household still has members
    and the ledger says somewhere else, Apple's word wins and the disagreement is logged — the
    behaviour `apply_notification` has had since phase 37a. Phase 143 reroutes only when the
    token's household is empty."""
    mine = await make_family(session)
    await make_user(session, family=mine)
    theirs = await make_family(session)
    await make_user(session, family=theirs, display_name="Somebody")
    await session.commit()
    first = await _notify(
        app_store_client,
        stub.sign_notification(
            app_store_chain,
            notification_type="SUBSCRIBED",
            subtype="INITIAL_BUY",
            signed_date=SIGNED_AT,
            app_account_token=mine.id,
            expires_date=EXPIRES,
        ),
    )
    assert first.json()["status"] == "tier:subscribed"

    renewed = await _notify(
        app_store_client,
        stub.sign_notification(
            app_store_chain,
            notification_type="DID_RENEW",
            signed_date=SIGNED_AT + dt.timedelta(days=30),
            app_account_token=theirs.id,
            expires_date=EXPIRES,
        ),
    )

    assert renewed.json()["status"] == "tier:subscribed"
    assert (await _transaction(session, "2000000000000001")).family_id == theirs.id
    assert (await _entitlement(session, theirs.id)).tier == "subscribed"
    assert (await _entitlement(session, mine.id)).tier == "subscribed"


# --- The verifier's own contract for a bare transaction ------------------------------------------


def test_verify_transaction_flattens_what_the_writer_reads(app_store_verifier, app_store_chain):
    token = uuid.uuid4()
    revoked_at = SIGNED_AT + dt.timedelta(days=3)
    verified = app_store_verifier.verify_transaction(
        stub.sign_transaction(
            app_store_chain,
            signed_date=SIGNED_AT,
            environment="Sandbox",
            original_transaction_id="42",
            transaction_id="43",
            product_id=stub.MONTHLY_PRODUCT_ID,
            app_account_token=token,
            expires_date=EXPIRES,
            revocation_date=revoked_at,
            purchase_date=SIGNED_AT - dt.timedelta(days=1),
        )
    )
    assert verified.original_transaction_id == "42"
    assert verified.transaction_id == "43"
    assert verified.product_id == stub.MONTHLY_PRODUCT_ID
    assert verified.transaction_type == "Auto-Renewable Subscription"
    assert verified.environment == "Sandbox"
    assert verified.signed_date == SIGNED_AT
    assert verified.purchase_date == SIGNED_AT - dt.timedelta(days=1)
    assert verified.expires_date == EXPIRES
    assert verified.revocation_date == revoked_at
    assert verified.app_account_token == token
    assert verified.raw["environment"] == "Sandbox"


def test_verify_transaction_refuses_a_malformed_token_as_orphan_not_error(
    app_store_verifier, app_store_chain
):
    verified = app_store_verifier.verify_transaction(
        stub.sign_transaction(
            app_store_chain,
            signed_date=SIGNED_AT,
            app_account_token="not-a-uuid",
            expires_date=EXPIRES,
        )
    )
    assert verified.app_account_token is None
