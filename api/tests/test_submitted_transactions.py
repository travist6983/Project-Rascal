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
import uuid

import pytest
from httpx import ASGITransport, AsyncClient
from sqlalchemy import select

import app_store_stub as stub
from factories import make_family, make_user
from helpers import auth_headers
from rascal.config import get_settings
from rascal.deps import get_app_store_verifier
from rascal.models import AppStoreTransaction, Entitlement
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


async def test_a_transaction_with_no_token_is_a_409(app_store_client, session, app_store_chain):
    """No `appAccountToken` means no proof of whose purchase it is, and the caller's word is not
    proof — the whole point of the token is that it is inside Apple's signature."""
    family = await make_family(session)
    parent = await make_user(session, family=family)
    await session.commit()

    response = await _submit(
        app_store_client,
        parent,
        stub.sign_transaction(app_store_chain, signed_date=SIGNED_AT, expires_date=EXPIRES),
    )

    assert response.status_code == 409
    assert (await _entitlement(session, family.id)).tier == "free"
    assert await _rows(session) == 0


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
