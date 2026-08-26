"""Phase 37a. App Store Server Notifications V2, the tier writer, and the entitlement read.

**Nothing in this file has ever spoken to Apple.** No subscription product exists in App Store
Connect (`docs/blocked.md` §10), no sandbox transaction has ever been made, and no real Apple
notification has ever reached this endpoint. Every payload here is minted locally by
`app_store_stub`, signed by a locally-minted chain, and verified by Apple's own library against
a locally-minted root. That makes the *verification* real — the library is the shipping one and
it enforces Apple's chain rules and marker OIDs — and it makes the *Apple side* untested.
"""

from __future__ import annotations

import datetime as dt
import pathlib
import uuid

import pytest
from sqlalchemy import select

import app_store_stub as stub
from factories import make_family, make_user
from helpers import auth_headers
from rascal.config import get_settings
from rascal.models import AppStoreTransaction, Entitlement, Family, User
from rascal.services import deletion
from rascal.services.app_store import (
    AppStoreVerifier,
    NotificationUnverifiable,
)
from rascal.services.app_store_events import tier_effect
from rascal.services.guardians import eligible_at

# Firmly in the past, and everything else in this file is derived from it by arithmetic.
# A notification's `signedDate` is when Apple decided, so a past one is the normal case;
# pinning it to today would make certificate-validity checks drift into the runner's clock.
SIGNED_AT = dt.datetime(2026, 6, 1, 12, 0, tzinfo=dt.UTC)
LATER = SIGNED_AT + dt.timedelta(days=30)
EARLIER = SIGNED_AT - dt.timedelta(days=30)

WEBHOOK = "/v1/webhooks/app-store"


async def _household(session, *, tier: str = "free") -> Family:
    family = await make_family(session, tier=tier)
    await make_user(session, family=family)
    return family


async def _post(client, signed_payload: str):
    return await client.post(WEBHOOK, json={"signedPayload": signed_payload})


# The webhook writes on the request's own session, so this one holds a stale instance.
# `populate_existing` re-reads it eagerly and overwrites what is in the identity map.
#
# **`session.expire_all()` is deliberately not used here**, and the reason is worth keeping:
# it expires every other object too, so the next `family.id` in a test is a lazy load on an
# async session — a `MissingGreenlet` in the assertion rather than a reload.


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


# --- Signature verification ----------------------------------------------------------------
#
# The whole security model. Everything below this section assumes a verified payload, which is
# only true because these pass.


async def test_a_valid_chain_verifies_and_is_accepted(app_store_client, session, app_store_chain):
    family = await _household(session)
    await session.commit()

    response = await _post(
        app_store_client,
        stub.sign_notification(
            app_store_chain,
            notification_type="SUBSCRIBED",
            subtype="INITIAL_BUY",
            signed_date=SIGNED_AT,
            app_account_token=family.id,
        ),
    )

    assert response.status_code == 202
    assert response.json()["status"] == "tier:subscribed"


async def test_a_chain_not_rooted_at_the_trusted_root_is_401(app_store_client, session):
    """**The test that matters most in this file.**

    A second, entirely well-formed chain — right shape, right marker OIDs, right algorithm —
    signed by a root the service does not trust. If this passes, anyone who can mint a
    certificate can write somebody's billing state.
    """
    family = await _household(session)
    await session.commit()
    stranger = stub.build_chain(root_common_name="Definitely Not Apple")

    response = await _post(
        app_store_client,
        stub.sign_notification(
            stranger,
            notification_type="SUBSCRIBED",
            subtype="INITIAL_BUY",
            signed_date=SIGNED_AT,
            app_account_token=family.id,
        ),
    )

    assert response.status_code == 401
    assert response.json()["error"]["code"] == "unauthenticated"
    assert await _entitlement(session, family.id) is not None
    assert (await _entitlement(session, family.id)).tier == "free"


async def test_an_expired_leaf_is_401(app_store_client, session, app_store_chain):
    """Validity is checked against the payload's own `signedDate`, so this is deterministic."""
    family = await _household(session)
    await session.commit()
    expired = stub.build_chain(leaf_not_after=SIGNED_AT - dt.timedelta(days=1))

    response = await _post(
        app_store_client,
        stub.sign_notification(
            expired,
            notification_type="SUBSCRIBED",
            signed_date=SIGNED_AT,
            app_account_token=family.id,
        ),
    )

    assert response.status_code == 401


async def test_a_tampered_payload_is_401(app_store_client, session, app_store_chain):
    """The body is altered and Apple's signature is left alone — the interesting direction."""
    family = await _household(session)
    await session.commit()
    signed = stub.sign_notification(
        app_store_chain,
        notification_type="SUBSCRIBED",
        signed_date=SIGNED_AT,
        app_account_token=family.id,
    )

    response = await _post(app_store_client, stub.tamper(signed))

    assert response.status_code == 401
    assert (await _entitlement(session, family.id)).tier == "free"


async def test_garbage_is_401_not_500(app_store_client):
    response = await _post(app_store_client, "not-a-jws-at-all")
    assert response.status_code == 401


async def test_no_trust_anchors_means_every_notification_is_refused(
    app_store_settings, app_store_chain, tmp_path
):
    """**Fails closed.** An empty trust store refuses rather than accepting unverified.

    This is the state the repository actually ships in — `src/rascal/certs/appstore/` holds no
    `.cer` — so this is not a hypothetical branch.
    """
    verifier = AppStoreVerifier(
        app_store_settings.model_copy(update={"app_store_root_certs_dir": tmp_path})
    )
    assert verifier.configured is False

    with pytest.raises(NotificationUnverifiable):
        verifier.verify(
            stub.sign_notification(
                app_store_chain, notification_type="SUBSCRIBED", signed_date=SIGNED_AT
            )
        )


# --- The nested decode ---------------------------------------------------------------------


async def test_transaction_info_is_read_from_its_own_jws(app_store_verifier, app_store_chain):
    """`data.signedTransactionInfo` is a **JWS string**, not an object.

    This test fails if somebody "simplifies" the decoder to `data.transactionInfo`: the stub
    emits no such key, so the simplified reader gets `None` and every field below is empty.
    That is exactly how this bug behaves in production — silently, forever.
    """
    token = uuid.uuid4()
    signed = stub.sign_notification(
        app_store_chain,
        notification_type="SUBSCRIBED",
        subtype="INITIAL_BUY",
        signed_date=SIGNED_AT,
        app_account_token=token,
        expires_date=LATER,
    )

    # The precondition the assertion depends on: there is no plain object to read.
    note = app_store_verifier.verify(signed)

    assert note.original_transaction_id == "2000000000000001"
    assert note.product_id == stub.ANNUAL_PRODUCT_ID
    assert note.app_account_token == token
    assert note.expires_date == LATER
    # And the decoded transaction is what got stored, not the JWS — under `data`, where
    # Apple put it. The record keeps Apple's own shape rather than flattening it, so what a
    # human reads during an incident is the notification, not our rearrangement of one.
    assert note.raw["data"]["transactionInfo"]["productId"] == stub.ANNUAL_PRODUCT_ID
    assert "signedTransactionInfo" not in note.raw["data"]


async def test_renewal_info_is_read_from_its_own_jws(app_store_verifier, app_store_chain):
    note = app_store_verifier.verify(
        stub.sign_notification(
            app_store_chain, notification_type="DID_RENEW", signed_date=SIGNED_AT
        )
    )
    assert note.raw["data"]["renewalInfo"]["autoRenewStatus"] == 1
    assert "signedRenewalInfo" not in note.raw["data"]


async def test_a_forged_inner_transaction_is_refused(app_store_verifier, app_store_chain):
    """The outer payload is Apple's and the inner transaction is not.

    The nested JWSs are *verified*, not merely base64-decoded, so an attacker who could get
    Apple to sign an outer envelope still cannot smuggle in their own transaction.
    """
    stranger = stub.build_chain(root_common_name="Definitely Not Apple")
    forged_inner = stub.sign_notification(
        stranger, notification_type="SUBSCRIBED", signed_date=SIGNED_AT
    )
    import jwt as pyjwt

    inner = pyjwt.decode(forged_inner, options={"verify_signature": False})
    smuggled = inner["data"]["signedTransactionInfo"]

    genuine = stub.sign_notification(
        app_store_chain,
        notification_type="SUBSCRIBED",
        signed_date=SIGNED_AT,
        include_transaction_info=False,
    )
    outer = pyjwt.decode(genuine, options={"verify_signature": False})
    outer["data"]["signedTransactionInfo"] = smuggled
    # Re-sign the outer envelope with the *trusted* chain, so only the inner is forged.
    hybrid = stub._sign(app_store_chain, outer)

    with pytest.raises(NotificationUnverifiable):
        app_store_verifier.verify(hybrid)


# --- The §1.4 table, row by row ------------------------------------------------------------


@pytest.mark.parametrize(
    ("notification_type", "subtype", "expected"),
    [
        ("SUBSCRIBED", "INITIAL_BUY", "subscribed"),
        ("SUBSCRIBED", "RESUBSCRIBE", "subscribed"),
        ("DID_RENEW", None, "subscribed"),
        ("DID_RENEW", "BILLING_RECOVERY", "subscribed"),
        ("DID_CHANGE_RENEWAL_STATUS", "AUTO_RENEW_DISABLED", None),
        ("DID_CHANGE_RENEWAL_STATUS", "AUTO_RENEW_ENABLED", None),
        ("DID_FAIL_TO_RENEW", "GRACE_PERIOD", None),
        ("DID_FAIL_TO_RENEW", None, "free"),
        ("GRACE_PERIOD_EXPIRED", None, "free"),
        ("EXPIRED", "VOLUNTARY", "free"),
        ("EXPIRED", "BILLING_RETRY", "free"),
        ("REFUND", None, "free"),
        ("REVOKE", None, "free"),
        ("DID_CHANGE_RENEWAL_PREF", "UPGRADE", None),
        ("DID_CHANGE_RENEWAL_PREF", "DOWNGRADE", None),
        ("CONSUMPTION_REQUEST", None, None),
        ("SOMETHING_APPLE_SHIPS_IN_2027", None, None),
    ],
)
def test_the_notification_table(notification_type, subtype, expected):
    """Every row of §1.4, as a pure function with no database in the way.

    The two that cost money if they are wrong: `DID_CHANGE_RENEWAL_STATUS` must not demote —
    cancelling auto-renew leaves the household paid up until `expires_date` — and
    `DID_FAIL_TO_RENEW` inverts on its subtype.
    """
    assert tier_effect(notification_type, subtype) == expected


@pytest.mark.parametrize(
    ("notification_type", "subtype", "starting_tier", "expected_tier"),
    [
        ("SUBSCRIBED", "INITIAL_BUY", "free", "subscribed"),
        ("SUBSCRIBED", "RESUBSCRIBE", "free", "subscribed"),
        ("DID_RENEW", None, "subscribed", "subscribed"),
        ("DID_CHANGE_RENEWAL_STATUS", "AUTO_RENEW_DISABLED", "subscribed", "subscribed"),
        ("DID_FAIL_TO_RENEW", "GRACE_PERIOD", "subscribed", "subscribed"),
        ("DID_CHANGE_RENEWAL_PREF", "UPGRADE", "subscribed", "subscribed"),
    ],
)
async def test_the_table_end_to_end_for_promotions_and_holds(
    app_store_client,
    session,
    app_store_chain,
    notification_type,
    subtype,
    starting_tier,
    expected_tier,
):
    family = await _household(session, tier=starting_tier)
    await session.commit()

    response = await _post(
        app_store_client,
        stub.sign_notification(
            app_store_chain,
            notification_type=notification_type,
            subtype=subtype,
            signed_date=SIGNED_AT,
            app_account_token=family.id,
        ),
    )

    assert response.status_code == 202
    assert (await _entitlement(session, family.id)).tier == expected_tier


@pytest.mark.parametrize(
    ("notification_type", "subtype"),
    [
        ("DID_FAIL_TO_RENEW", None),
        ("GRACE_PERIOD_EXPIRED", None),
        ("EXPIRED", "VOLUNTARY"),
        ("REFUND", None),
        ("REVOKE", None),
    ],
)
async def test_the_table_end_to_end_for_demotions(
    app_store_client, session, app_store_chain, notification_type, subtype
):
    """Demotions need a transaction record first — see the guard below. This establishes one
    the honest way, with a real `SUBSCRIBED`, so the demotion under test is the only thing
    being measured."""
    family = await _household(session)
    await session.commit()
    await _post(
        app_store_client,
        stub.sign_notification(
            app_store_chain,
            notification_type="SUBSCRIBED",
            subtype="INITIAL_BUY",
            signed_date=EARLIER,
            app_account_token=family.id,
        ),
    )
    assert (await _entitlement(session, family.id)).tier == "subscribed"

    response = await _post(
        app_store_client,
        stub.sign_notification(
            app_store_chain,
            notification_type=notification_type,
            subtype=subtype,
            signed_date=SIGNED_AT,
            app_account_token=family.id,
        ),
    )

    assert response.status_code == 202
    entitlement = await _entitlement(session, family.id)
    assert entitlement.tier == "free"
    # `lapsed_at` is Apple's `signedDate`, never "now": D3's clocks run from when Apple
    # decided, and a late-delivered notification would otherwise date the lapse to when we
    # happened to hear about it.
    assert entitlement.lapsed_at == SIGNED_AT


# --- Guard 1: out-of-order delivery ---------------------------------------------------------


async def test_an_older_expired_after_a_resubscribe_leaves_the_household_subscribed(
    app_store_client, session, app_store_chain
):
    """**The defect this phase is most likely to ship**, and it fails silently in production
    while every other test in this file passes.

    Apple retries, and retries interleave with new notifications. The `EXPIRED` here is real,
    correctly signed, and genuinely Apple's — it is simply *old*, and applying it would set a
    paying household free.
    """
    family = await _household(session)
    await session.commit()

    await _post(
        app_store_client,
        stub.sign_notification(
            app_store_chain,
            notification_type="SUBSCRIBED",
            subtype="RESUBSCRIBE",
            signed_date=SIGNED_AT,
            app_account_token=family.id,
        ),
    )
    assert (await _entitlement(session, family.id)).tier == "subscribed"

    late = await _post(
        app_store_client,
        stub.sign_notification(
            app_store_chain,
            notification_type="EXPIRED",
            signed_date=EARLIER,
            app_account_token=family.id,
        ),
    )

    assert late.status_code == 202
    assert late.json()["status"] == "ignored:out-of-order"
    entitlement = await _entitlement(session, family.id)
    assert entitlement.tier == "subscribed"
    assert entitlement.lapsed_at is None
    # And the ledger still describes the newest thing Apple said, not the stale one.
    row = await _transaction(session, "2000000000000001")
    assert row.latest_notification_type == "SUBSCRIBED"
    assert row.latest_signed_date == SIGNED_AT


async def test_the_same_notification_twice_leaves_identical_state(
    app_store_client, session, app_store_chain
):
    """Idempotency, which falls out of the same comparison the ordering guard uses."""
    family = await _household(session)
    await session.commit()
    signed = stub.sign_notification(
        app_store_chain,
        notification_type="SUBSCRIBED",
        subtype="INITIAL_BUY",
        signed_date=SIGNED_AT,
        app_account_token=family.id,
        expires_date=LATER,
    )

    first = await _post(app_store_client, signed)
    entitlement = await _entitlement(session, family.id)
    before = (entitlement.tier, entitlement.lapsed_at, entitlement.payer_user_id)
    row = await _transaction(session, "2000000000000001")
    row_before = (row.latest_notification_type, row.latest_signed_date, row.family_id)

    second = await _post(app_store_client, signed)

    assert first.status_code == second.status_code == 202
    assert second.json()["status"] == "ignored:out-of-order"
    entitlement = await _entitlement(session, family.id)
    assert (entitlement.tier, entitlement.lapsed_at, entitlement.payer_user_id) == before
    row = await _transaction(session, "2000000000000001")
    assert (row.latest_notification_type, row.latest_signed_date, row.family_id) == row_before
    # One subscription, one row — `original_transaction_id` is the primary key.
    count = await session.scalar(
        select(AppStoreTransaction).where(
            AppStoreTransaction.original_transaction_id == "2000000000000001"
        )
    )
    assert count is not None


# --- Guard 2: sandbox isolation -------------------------------------------------------------


async def test_a_sandbox_notification_in_production_records_and_writes_no_tier(
    app, session, app_store_settings, app_store_chain
):
    """**Anybody can create a sandbox tester account.** If a Sandbox notification could write
    a Production entitlement, anybody could subscribe a production household for free."""
    from httpx import ASGITransport, AsyncClient

    from rascal.deps import get_app_store_verifier

    family = await _household(session)
    await session.commit()

    prod_settings = app_store_settings.model_copy(update={"environment": "prod"})
    app.dependency_overrides[get_app_store_verifier] = lambda: AppStoreVerifier(prod_settings)
    # The service, not the verifier, is what the sandbox gate reads.
    from rascal.config import get_settings

    app.dependency_overrides[get_settings] = lambda: prod_settings

    transport = ASGITransport(app=app)
    async with AsyncClient(transport=transport, base_url="http://test") as client:
        response = await _post(
            client,
            stub.sign_notification(
                app_store_chain,
                notification_type="SUBSCRIBED",
                subtype="INITIAL_BUY",
                signed_date=SIGNED_AT,
                environment="Sandbox",
                app_account_token=family.id,
            ),
        )

    assert response.status_code == 202
    assert (await _entitlement(session, family.id)).tier == "free"
    row = await _transaction(session, "2000000000000001")
    assert row is not None, "the notification must still be recorded"
    assert row.environment == "Sandbox"


# --- Guard 3: never demote a family with no transaction record -------------------------------


async def test_a_demotion_for_a_family_with_no_transaction_record_does_not_write(
    app_store_client, session, app_store_chain
):
    """**The owner's own household.** `runbook-deploy.md` §7a made it `subscribed` by hand and
    there is no App Store transaction behind it, nor will there ever be. A stray `EXPIRED`
    naming that family must not be able to lock him out of his own product."""
    family = await _household(session, tier="subscribed")
    await session.commit()

    response = await _post(
        app_store_client,
        stub.sign_notification(
            app_store_chain,
            notification_type="EXPIRED",
            signed_date=SIGNED_AT,
            app_account_token=family.id,
        ),
    )

    assert response.status_code == 202
    assert response.json()["status"] == "recorded:demotion-refused"
    entitlement = await _entitlement(session, family.id)
    assert entitlement.tier == "subscribed"
    assert entitlement.lapsed_at is None
    row = await _transaction(session, "2000000000000001")
    assert row is not None, "the notification is still recorded"


async def test_a_refused_demotion_does_not_create_the_link_it_was_refused_for(
    app_store_client, session, app_store_chain
):
    """The guard must not be a one-notification delay.

    If the refused demotion wrote `family_id` onto the ledger row, the *next* demoting
    notification would find exactly the record this one was refused for and go through.
    """
    family = await _household(session, tier="subscribed")
    await session.commit()

    await _post(
        app_store_client,
        stub.sign_notification(
            app_store_chain,
            notification_type="EXPIRED",
            signed_date=EARLIER,
            app_account_token=family.id,
        ),
    )
    assert (await _transaction(session, "2000000000000001")).family_id is None

    second = await _post(
        app_store_client,
        stub.sign_notification(
            app_store_chain,
            notification_type="EXPIRED",
            signed_date=SIGNED_AT,
            app_account_token=family.id,
        ),
    )

    assert second.json()["status"] == "recorded:demotion-refused"
    assert (await _entitlement(session, family.id)).tier == "subscribed"


# --- Unknown types, unknown families, orphan receipts ----------------------------------------


async def test_an_unknown_notification_type_is_recorded_and_acknowledged(
    app_store_client, session, app_store_chain
):
    family = await _household(session)
    await session.commit()

    response = await _post(
        app_store_client,
        stub.sign_notification(
            app_store_chain,
            notification_type="SOMETHING_APPLE_SHIPS_IN_2027",
            signed_date=SIGNED_AT,
            app_account_token=family.id,
        ),
    )

    assert response.status_code == 202
    assert (await _entitlement(session, family.id)).tier == "free"
    row = await _transaction(session, "2000000000000001")
    assert row.latest_notification_type == "SOMETHING_APPLE_SHIPS_IN_2027"


async def test_an_unknown_family_is_recorded_unattributed_and_no_family_is_created(
    app_store_client, session, app_store_chain
):
    """A 4xx here would make Apple retry forever; creating a family would be manufacturing
    user data from an unauthenticated request."""
    before = len((await session.execute(select(Family))).scalars().all())

    response = await _post(
        app_store_client,
        stub.sign_notification(
            app_store_chain,
            notification_type="SUBSCRIBED",
            subtype="INITIAL_BUY",
            signed_date=SIGNED_AT,
            app_account_token=uuid.uuid4(),
        ),
    )

    assert response.status_code == 202
    assert response.json()["status"] == "recorded:unattributed"
    row = await _transaction(session, "2000000000000001")
    assert row is not None
    assert row.family_id is None
    after = len((await session.execute(select(Family))).scalars().all())
    assert after == before


async def test_a_missing_app_account_token_is_an_orphan_receipt_not_an_error(
    app_store_client, session, app_store_chain
):
    """The 37b obligation, from the server's side: with no `appAccountToken` there is nothing
    any server-side process can ever attribute this payment to."""
    response = await _post(
        app_store_client,
        stub.sign_notification(
            app_store_chain,
            notification_type="SUBSCRIBED",
            subtype="INITIAL_BUY",
            signed_date=SIGNED_AT,
            app_account_token=None,
        ),
    )

    assert response.status_code == 202
    assert (await _transaction(session, "2000000000000001")).family_id is None


async def test_a_malformed_app_account_token_is_a_null_family_not_an_exception(
    app_store_client, session, app_store_chain
):
    response = await _post(
        app_store_client,
        stub.sign_notification(
            app_store_chain,
            notification_type="SUBSCRIBED",
            signed_date=SIGNED_AT,
            app_account_token="not-a-uuid-at-all",
        ),
    )

    assert response.status_code == 202
    assert (await _transaction(session, "2000000000000001")).family_id is None


# --- The ledger row --------------------------------------------------------------------------


async def test_the_ledger_stores_the_decoded_payload_not_the_jws(
    app_store_client, session, app_store_chain
):
    """A stored JWS is a secret-shaped blob nobody verifies twice; a stored decode is what
    somebody reads during an incident."""
    family = await _household(session)
    await session.commit()
    await _post(
        app_store_client,
        stub.sign_notification(
            app_store_chain,
            notification_type="SUBSCRIBED",
            subtype="INITIAL_BUY",
            signed_date=SIGNED_AT,
            app_account_token=family.id,
            expires_date=LATER,
        ),
    )

    row = await _transaction(session, "2000000000000001")
    assert row.raw_payload["notificationType"] == "SUBSCRIBED"
    assert row.raw_payload["data"]["transactionInfo"]["productId"] == stub.ANNUAL_PRODUCT_ID
    assert row.product_id == stub.ANNUAL_PRODUCT_ID
    assert row.environment == "Production"
    assert row.expires_date == LATER
    # Nothing JWS-shaped survived the decode.
    rendered = str(row.raw_payload)
    assert "signedTransactionInfo" not in rendered
    assert "signedRenewalInfo" not in rendered


async def test_updated_at_moves_by_trigger_on_a_renewal(app_store_client, session, app_store_chain):
    family = await _household(session)
    await session.commit()
    await _post(
        app_store_client,
        stub.sign_notification(
            app_store_chain,
            notification_type="SUBSCRIBED",
            subtype="INITIAL_BUY",
            signed_date=EARLIER,
            app_account_token=family.id,
        ),
    )
    first = (await _transaction(session, "2000000000000001")).updated_at

    await _post(
        app_store_client,
        stub.sign_notification(
            app_store_chain,
            notification_type="DID_RENEW",
            signed_date=SIGNED_AT,
            app_account_token=family.id,
        ),
    )

    row = await _transaction(session, "2000000000000001")
    assert row.updated_at > first
    assert row.latest_notification_type == "DID_RENEW"


async def test_the_payer_is_recorded_when_the_household_leaves_no_room_to_guess(
    app_store_client, session, app_store_chain
):
    family = await make_family(session)
    user = await make_user(session, family=family)
    await session.commit()

    await _post(
        app_store_client,
        stub.sign_notification(
            app_store_chain,
            notification_type="SUBSCRIBED",
            subtype="INITIAL_BUY",
            signed_date=SIGNED_AT,
            app_account_token=family.id,
        ),
    )

    assert (await _entitlement(session, family.id)).payer_user_id == user.id


async def test_the_payer_is_left_null_when_two_guardians_could_both_be_paying(
    app_store_client, session, app_store_chain
):
    """**A wrong `payer_user_id` is worse than a null one.** `appAccountToken` carries a family
    id, per the client obligation, so Apple never names a user; D3a's win-back writes to the
    payer, and guessing means emailing the wrong parent about the other one's cancelled card.
    """
    family = await make_family(session)
    await make_user(session, family=family, display_name="Travis")
    await make_user(session, family=family, display_name="Partner")
    await session.commit()

    await _post(
        app_store_client,
        stub.sign_notification(
            app_store_chain,
            notification_type="SUBSCRIBED",
            subtype="INITIAL_BUY",
            signed_date=SIGNED_AT,
            app_account_token=family.id,
        ),
    )

    entitlement = await _entitlement(session, family.id)
    assert entitlement.tier == "subscribed"
    assert entitlement.payer_user_id is None


# --- The full sequence, forwards and out of order ---------------------------------------------


async def test_subscribe_renew_expire_in_order(app_store_client, session, app_store_chain):
    family = await _household(session)
    await session.commit()
    days = [SIGNED_AT, SIGNED_AT + dt.timedelta(days=365), SIGNED_AT + dt.timedelta(days=730)]

    for notification_type, subtype, when in [
        ("SUBSCRIBED", "INITIAL_BUY", days[0]),
        ("DID_RENEW", None, days[1]),
        ("EXPIRED", "VOLUNTARY", days[2]),
    ]:
        await _post(
            app_store_client,
            stub.sign_notification(
                app_store_chain,
                notification_type=notification_type,
                subtype=subtype,
                signed_date=when,
                app_account_token=family.id,
            ),
        )

    entitlement = await _entitlement(session, family.id)
    assert entitlement.tier == "free"
    assert entitlement.lapsed_at == days[2]


async def test_subscribe_expire_renew_with_the_renewal_delivered_last(
    app_store_client, session, app_store_chain
):
    """The same three notifications, with the middle one delivered last.

    The `DID_RENEW` arriving after the `EXPIRED` is *older* than it, so the ordering guard
    ignores it and the household stays `free`. Applying it would resurrect a subscription that
    has genuinely ended.
    """
    family = await _household(session)
    await session.commit()
    days = [SIGNED_AT, SIGNED_AT + dt.timedelta(days=365), SIGNED_AT + dt.timedelta(days=730)]

    for notification_type, subtype, when in [
        ("SUBSCRIBED", "INITIAL_BUY", days[0]),
        ("EXPIRED", "VOLUNTARY", days[2]),
        ("DID_RENEW", None, days[1]),
    ]:
        await _post(
            app_store_client,
            stub.sign_notification(
                app_store_chain,
                notification_type=notification_type,
                subtype=subtype,
                signed_date=when,
                app_account_token=family.id,
            ),
        )

    entitlement = await _entitlement(session, family.id)
    assert entitlement.tier == "free"
    assert entitlement.lapsed_at == days[2]


# --- `entitlements.tier` has exactly one writer -----------------------------------------------


def test_tier_has_exactly_one_writer():
    """**Pins the absence of a second writer**, the way phase 60 pinned the absence of a
    `subscribers` table.

    D5 reserves `tier` for App Store Server Notifications V2, and the day somebody adds a
    second writer — an admin route, a reconciliation job, a "fix it" script — this fails and
    they have to argue with the decision rather than around it. `runbook-deploy.md` §7a stays
    the manual override; it is a hand-run SQL statement rather than code, which is precisely
    why it does not appear here.
    """
    src = pathlib.Path(__file__).resolve().parents[1] / "src" / "rascal"
    writers = []
    for path in sorted(src.rglob("*.py")):
        for number, line in enumerate(path.read_text().splitlines(), start=1):
            stripped = line.strip()
            if stripped.startswith("#"):
                continue
            # An assignment to `.tier`, which is the only way this column is written through
            # the ORM. `storage_tier` is a different column and phase 38's business.
            if ".tier = " in stripped and "storage_tier" not in stripped:
                writers.append(f"{path.relative_to(src)}:{number}")

    assert len(writers) == 1, "entitlements.tier must have exactly one writer. Found: " + ", ".join(
        writers
    )
    assert writers[0].startswith("services/app_store_events.py:"), (
        "the one writer of entitlements.tier must be the App Store notification handler, "
        f"not {writers[0]}"
    )


# --- GET /families/{id}/entitlement -----------------------------------------------------------


async def test_eligible_at_runs_off_the_lapse_clock_when_it_is_the_later_one():
    """`max(lapsed_at + 24 months, last_sign_in_at + 12 months)`, per D3."""
    lapsed = dt.datetime(2026, 5, 1, tzinfo=dt.UTC)
    signed_in = dt.datetime(2026, 6, 1, tzinfo=dt.UTC)
    # lapse + 24mo = 2028-05-01; sign-in + 12mo = 2027-06-01. The lapse clock wins.
    # future-date: a deletion horizon is a future date by definition — it is the output under
    # test, not a fixture, and both inputs above are in the past.
    horizon = dt.date(2028, 5, 1)  # future-date: the horizon under test
    assert eligible_at("free", lapsed, signed_in) == horizon


async def test_eligible_at_runs_off_the_inactivity_clock_when_it_is_the_later_one():
    """**The clock a naive implementation forgets.**

    A parent who lapsed years ago but signed in last month has not abandoned their archive,
    and D3's second clock is what says so. Dropping it would delete the photographs of exactly
    the families still opening the app.
    """
    lapsed = dt.datetime(2024, 5, 1, tzinfo=dt.UTC)
    signed_in = dt.datetime(2026, 5, 1, tzinfo=dt.UTC)
    # lapse + 24mo = 2026-05-01; sign-in + 12mo = 2027-05-01. The inactivity clock wins.
    # future-date: the horizon under test. Both inputs are in the past.
    horizon = dt.date(2027, 5, 1)  # future-date: the horizon under test
    assert eligible_at("free", lapsed, signed_in) == horizon


async def test_eligible_at_with_no_sign_in_at_all_uses_the_lapse_clock_alone():
    """Every guardian's `last_sign_in_at` is null — a real state, not a missing row."""
    lapsed = dt.datetime(2026, 5, 1, tzinfo=dt.UTC)
    # future-date: the horizon under test; the lapse it is computed from is in the past.
    horizon = dt.date(2028, 5, 1)  # future-date: the horizon under test
    assert eligible_at("free", lapsed, None) == horizon


async def test_eligible_at_is_null_while_subscribed():
    """There is no deletion clock on a paying household."""
    assert eligible_at("subscribed", dt.datetime(2026, 5, 1, tzinfo=dt.UTC), None) is None
    assert eligible_at("free", None, None) is None


async def test_eligible_at_clamps_a_leap_day():
    """Feb 29 + 24 months has no Feb 29 to land on. One support conversation every four
    years, or none."""
    assert eligible_at("free", dt.datetime(2024, 2, 29, tzinfo=dt.UTC), None) == dt.date(
        2026, 2, 28
    )


async def test_the_entitlement_route_reports_the_computed_date(client, session):
    family = await make_family(session)
    user = await make_user(session, family=family)
    entitlement = await session.get(Entitlement, family.id)
    entitlement.lapsed_at = dt.datetime(2026, 5, 1, tzinfo=dt.UTC)
    user.last_sign_in_at = dt.datetime(2026, 6, 1, tzinfo=dt.UTC)
    await session.commit()

    response = await client.get(f"/v1/families/{family.id}/entitlement", headers=auth_headers(user))

    assert response.status_code == 200
    body = response.json()
    # **`access` is `trial` and `eligible_at` is still computed, and that pairing is the
    # point.** Phase 107 gives every household a fourteen-day trial at creation, so this
    # fixture is inside one — and the deletion clock is unaffected, because `eligible_at`
    # keys off `tier` and `lapsed_at` and a trial is neither. A trial does not lapse.
    trial_ends_at = body.pop("trial_ends_at")
    assert trial_ends_at is not None
    assert body == {
        "family_id": str(family.id),
        "tier": "free",
        "access": "trial",
        # Phase 121's three. **`entitled` is true and `eligible_at` is still a date**, which is
        # the pairing worth pinning: the household is inside its trial, so it may reach the
        # whole board — and it also lapsed a real subscription in May, so D3's deletion clock is
        # running. A trial holds the door open; it does not stop that clock, and only a receipt
        # or a grant does.
        "entitled": True,
        "entitlement_source": "trial",
        "grant_expires_at": None,
        "lapsed_at": "2026-05-01T00:00:00Z",
        "eligible_at": "2028-05-01",
        # Phase 113's two additions to this shape. **Both are the not-subscribed answer**, and
        # this household is `free` with a live trial, so neither has anything to report: a
        # trial has no receipt behind it, and nobody's card is being retried. This assertion
        # is a whole-body equality on purpose — it is what caught these fields being added,
        # and it is the test that will catch the next one.
        "plan": None,
        "billing_retry": False,
        "media_storage_tier": "hot",
    }


async def test_the_entitlement_route_omits_the_date_while_subscribed(client, session):
    family = await make_family(session, tier="subscribed")
    user = await make_user(session, family=family)
    await session.commit()

    response = await client.get(f"/v1/families/{family.id}/entitlement", headers=auth_headers(user))

    assert response.status_code == 200
    assert response.json()["tier"] == "subscribed"
    assert response.json()["eligible_at"] is None


async def test_the_entitlement_route_takes_the_max_across_the_household(client, session):
    """`last_sign_in_at` is a MAX over the household's guardians, not the caller's own.

    A household stays active because *somebody* is opening the app. Reading only the caller
    would start the deletion clock on a family where the other parent uses it daily.
    """
    family = await make_family(session)
    quiet = await make_user(session, family=family, display_name="Travis")
    active = await make_user(session, family=family, display_name="Partner")
    entitlement = await session.get(Entitlement, family.id)
    entitlement.lapsed_at = dt.datetime(2024, 5, 1, tzinfo=dt.UTC)
    quiet.last_sign_in_at = dt.datetime(2024, 5, 2, tzinfo=dt.UTC)
    active.last_sign_in_at = dt.datetime(2026, 6, 1, tzinfo=dt.UTC)
    await session.commit()

    response = await client.get(
        f"/v1/families/{family.id}/entitlement", headers=auth_headers(quiet)
    )

    # lapse + 24mo = 2026-05-01; the active parent's sign-in + 12mo = 2027-06-01, and it is
    # the later one. A string rather than a `dt.date`, which is what the wire actually carries.
    assert response.json()["eligible_at"] == "2027-06-01"


async def test_another_households_entitlement_is_403(client, session):
    """`{family_id}` is a forgeable path segment. The check is `deps.family_access`."""
    mine = await make_family(session)
    me = await make_user(session, family=mine)
    theirs = await make_family(session, tier="subscribed")
    await make_user(session, family=theirs)
    await session.commit()

    response = await client.get(f"/v1/families/{theirs.id}/entitlement", headers=auth_headers(me))

    assert response.status_code == 403
    assert response.json()["error"]["code"] == "not_authorized"


async def test_the_entitlement_route_requires_a_token(client, session):
    family = await make_family(session)
    await session.commit()

    response = await client.get(f"/v1/families/{family.id}/entitlement")

    assert response.status_code == 401


async def test_families_me_and_the_entitlement_route_never_disagree(
    app_store_client, session, app_store_chain
):
    """**One authority, two shapes.**

    Both routes read the same `entitlements` row through `entitlement_for`. This drives the
    tier with a real notification and then asserts the two readings agree — the failure it
    exists to catch is somebody giving one of them its own idea of what `subscribed` means.
    """
    family = await make_family(session)
    user = await make_user(session, family=family)
    await session.commit()

    await _post(
        app_store_client,
        stub.sign_notification(
            app_store_chain,
            notification_type="SUBSCRIBED",
            subtype="INITIAL_BUY",
            signed_date=SIGNED_AT,
            app_account_token=family.id,
        ),
    )

    headers = auth_headers(user)
    me = await app_store_client.get("/v1/families/me", headers=headers)
    entitlement = await app_store_client.get(
        f"/v1/families/{family.id}/entitlement", headers=headers
    )

    assert me.json()["tier"] == entitlement.json()["tier"] == "subscribed"


# --- The second pass ---------------------------------------------------------------------------
#
# Everything below was found by re-reading the diff against Apple's actual notification
# vocabulary rather than against the phase's description of it.


async def test_a_demotion_still_lands_when_apple_omits_the_app_account_token(
    app_store_client, session, app_store_chain
):
    """**`appAccountToken` is not guaranteed on every notification for a subscription.**

    It is set at purchase time and echoed back, and the notification that matters most here —
    the `EXPIRED` two years later — is the one furthest from that purchase. If the attribution
    has to come from the payload every time, a household that stops paying keeps `subscribed`
    forever, which is the failure that costs money rather than the one that annoys somebody.

    The ledger row written by the `SUBSCRIBED` already records who this subscription belongs
    to. That row *is* the transaction record, so falling back to it is the same evidence the
    demotion guard asks for, not a weaker one.
    """
    family = await _household(session)
    await session.commit()

    await _post(
        app_store_client,
        stub.sign_notification(
            app_store_chain,
            notification_type="SUBSCRIBED",
            subtype="INITIAL_BUY",
            signed_date=EARLIER,
            app_account_token=family.id,
        ),
    )
    assert (await _entitlement(session, family.id)).tier == "subscribed"

    response = await _post(
        app_store_client,
        stub.sign_notification(
            app_store_chain,
            notification_type="EXPIRED",
            subtype="VOLUNTARY",
            signed_date=SIGNED_AT,
            app_account_token=None,
        ),
    )

    assert response.status_code == 202
    entitlement = await _entitlement(session, family.id)
    assert entitlement.tier == "free"
    assert entitlement.lapsed_at == SIGNED_AT
    # The attribution survives a notification that did not carry one.
    assert (await _transaction(session, "2000000000000001")).family_id == family.id


async def test_a_sandbox_notification_never_advances_a_production_rows_clock(
    app, session, app_store_settings, app_store_chain
):
    """**Denial of entitlement, not just a wrong row.**

    `latest_signed_date` is the ordering guard's high-water mark. If a Sandbox notification
    could push it forward on a Production subscription's row, every *legitimate* Production
    notification after it would be ignored as out of order — the household's tier would freeze
    wherever it happened to be, silently, and nothing Apple sent afterwards would move it.
    """
    from httpx import ASGITransport, AsyncClient

    from rascal.config import get_settings
    from rascal.deps import get_app_store_verifier

    family = await _household(session)
    await session.commit()

    prod_settings = app_store_settings.model_copy(update={"environment": "prod"})
    app.dependency_overrides[get_app_store_verifier] = lambda: AppStoreVerifier(prod_settings)
    app.dependency_overrides[get_settings] = lambda: prod_settings

    transport = ASGITransport(app=app)
    async with AsyncClient(transport=transport, base_url="http://test") as client:
        await _post(
            client,
            stub.sign_notification(
                app_store_chain,
                notification_type="SUBSCRIBED",
                subtype="INITIAL_BUY",
                signed_date=EARLIER,
                environment="Production",
                app_account_token=family.id,
            ),
        )
        assert (await _entitlement(session, family.id)).tier == "subscribed"

        # A Sandbox notification, correctly signed, claiming the same subscription and a much
        # newer clock.
        sandbox = await _post(
            client,
            stub.sign_notification(
                app_store_chain,
                notification_type="EXPIRED",
                # Newer than the Production row's clock, so only the environment check can
                # stop it. Still inside the fixture chain's validity, which is checked
                # against the payload's own `signedDate`.
                signed_date=SIGNED_AT + dt.timedelta(days=365),
                environment="Sandbox",
                app_account_token=family.id,
            ),
        )
        assert sandbox.status_code == 202

        row = await _transaction(session, "2000000000000001")
        assert row.environment == "Production", "the Production row was overwritten"
        assert row.latest_signed_date == EARLIER, "a Sandbox payload moved the ordering clock"

        # And the household is still reachable by real Production notifications afterwards.
        await _post(
            client,
            stub.sign_notification(
                app_store_chain,
                notification_type="DID_RENEW",
                signed_date=SIGNED_AT,
                environment="Production",
                app_account_token=family.id,
            ),
        )
        entitlement = await _entitlement(session, family.id)
        assert entitlement.tier == "subscribed"
        assert (await _transaction(session, "2000000000000001")).latest_signed_date == SIGNED_AT


@pytest.mark.parametrize(
    ("notification_type", "subtype"),
    [
        # **Apple's real spellings.** `AUTO_RENEW_OFF` / `AUTO_RENEW_ON` do not exist in
        # Apple's vocabulary — `appstoreserverlibrary.models.Subtype` is the list — and a
        # parametrisation using them would assert the right outcome for a value Apple never
        # sends, which is worth less than no test because it is counted.
        ("DID_CHANGE_RENEWAL_STATUS", "AUTO_RENEW_DISABLED"),
        ("DID_CHANGE_RENEWAL_STATUS", "AUTO_RENEW_ENABLED"),
    ],
)
async def test_turning_auto_renew_off_does_not_lapse_a_paid_up_household(
    app_store_client, session, app_store_chain, notification_type, subtype
):
    """Cancelling auto-renew is not lapsing: the household is paid up until `expires_date`,
    and demoting here bills them for time they do not get."""
    family = await _household(session)
    await session.commit()
    await _post(
        app_store_client,
        stub.sign_notification(
            app_store_chain,
            notification_type="SUBSCRIBED",
            subtype="INITIAL_BUY",
            signed_date=EARLIER,
            app_account_token=family.id,
            expires_date=LATER,
        ),
    )

    response = await _post(
        app_store_client,
        stub.sign_notification(
            app_store_chain,
            notification_type=notification_type,
            subtype=subtype,
            signed_date=SIGNED_AT,
            app_account_token=family.id,
        ),
    )

    assert response.status_code == 202
    entitlement = await _entitlement(session, family.id)
    assert entitlement.tier == "subscribed"
    assert entitlement.lapsed_at is None


async def test_apples_own_test_notification_is_a_no_op(app_store_client, session, app_store_chain):
    """`TEST` is what App Store Connect's *send a test notification* button produces.

    It is the first real payload this endpoint will ever receive, and it must not do anything
    to anybody's tier.
    """
    family = await _household(session)
    await session.commit()

    response = await _post(
        app_store_client,
        stub.sign_notification(
            app_store_chain,
            notification_type="TEST",
            signed_date=SIGNED_AT,
            app_account_token=family.id,
        ),
    )

    assert response.status_code == 202
    assert (await _entitlement(session, family.id)).tier == "free"


async def test_a_notification_with_no_transaction_at_all_is_acknowledged(
    app_store_client, session, app_store_chain
):
    """A payload whose `data` carries neither nested JWS — nothing to key the ledger on.

    Acknowledged rather than refused, because a 4xx means Apple tells us about it forever.
    """
    response = await _post(
        app_store_client,
        stub.sign_notification(
            app_store_chain,
            notification_type="RENEWAL_EXTENDED",
            signed_date=SIGNED_AT,
            include_transaction_info=False,
            include_renewal_info=False,
        ),
    )

    assert response.status_code == 202
    assert response.json()["status"] == "ignored:no-transaction-id"


async def test_a_renewal_without_transaction_info_keeps_the_known_expiry(
    app_store_client, session, app_store_chain
):
    """A notification that carries no `expiresDate` must not erase the one already recorded.

    Phase 38 schedules against these dates. Blanking a known expiry because one notification
    was quiet about it is how a household gets treated as never having had one.
    """
    family = await _household(session)
    await session.commit()
    await _post(
        app_store_client,
        stub.sign_notification(
            app_store_chain,
            notification_type="SUBSCRIBED",
            subtype="INITIAL_BUY",
            signed_date=EARLIER,
            app_account_token=family.id,
            expires_date=LATER,
        ),
    )
    assert (await _transaction(session, "2000000000000001")).expires_date == LATER

    await _post(
        app_store_client,
        stub.sign_notification(
            app_store_chain,
            notification_type="DID_CHANGE_RENEWAL_STATUS",
            subtype="AUTO_RENEW_DISABLED",
            signed_date=SIGNED_AT,
            app_account_token=family.id,
            expires_date=None,
        ),
    )

    assert (await _transaction(session, "2000000000000001")).expires_date == LATER


def test_every_notification_string_this_service_branches_on_is_one_apple_sends():
    """**Pins the vocabulary against Apple's own enums.**

    A typo in `PROMOTING_NOTIFICATIONS`, `DEMOTING_NOTIFICATIONS`, or the `GRACE_PERIOD`
    comparison does not raise, does not log, and does not fail any test that uses the same
    typo in its fixture. It just means that notification never does anything — a household
    that paid stays `free`, or one that lapsed stays `subscribed`, forever.

    This file's own parametrisations were wrong in exactly that way until Aug 20, 2026: they
    used `AUTO_RENEW_OFF` and `AUTO_RENEW_ON`, which are not values Apple sends. The behaviour
    happened to be right — `DID_CHANGE_RENEWAL_STATUS` never changes the tier whatever its
    subtype — so nothing failed, and two tests were asserting the right outcome for a value
    that does not exist. This test is what stops that being possible.
    """
    from appstoreserverlibrary.models.NotificationTypeV2 import NotificationTypeV2
    from appstoreserverlibrary.models.Subtype import Subtype

    from rascal.constants import DEMOTING_NOTIFICATIONS, PROMOTING_NOTIFICATIONS

    apple_types = {member.value for member in NotificationTypeV2}
    apple_subtypes = {member.value for member in Subtype}

    branched_types = set(PROMOTING_NOTIFICATIONS) | set(DEMOTING_NOTIFICATIONS)
    branched_types.add("DID_FAIL_TO_RENEW")  # handled by subtype in `tier_effect`

    assert branched_types <= apple_types, (
        "these notification types are not in Apple's vocabulary and can never match: "
        f"{sorted(branched_types - apple_types)}"
    )
    # The one subtype any branch compares against.
    assert "GRACE_PERIOD" in apple_subtypes
    # And the ones this file's parametrisations rely on being real.
    assert {"INITIAL_BUY", "RESUBSCRIBE", "AUTO_RENEW_DISABLED", "AUTO_RENEW_ENABLED"} <= (
        apple_subtypes
    )


def test_a_refund_that_apple_later_reverses_is_recorded_but_does_not_restore():
    """**A known gap, pinned so it is a decision rather than a discovery.**

    `REFUND_REVERSED` means Apple reversed a refund it had granted — the customer should have
    access again. `REFUND_DECLINED` means a refund request was refused, so nothing should have
    changed. Neither restores `subscribed` here: phase 37a implements the table it was given,
    where anything outside it is recorded with no tier change.

    **The row is written either way**, so this is recoverable by hand from
    `app_store_transactions` and is not a lost payment. It is written down as a test because
    the alternative is somebody finding it while a customer is on the phone.
    """
    assert tier_effect("REFUND_REVERSED", None) is None
    assert tier_effect("REFUND_DECLINED", None) is None
    assert tier_effect("REFUND", None) == "free"


async def test_an_ambiguous_bundle_id_refuses_rather_than_guessing(
    app_store_settings, app_store_chain
):
    """**Two audiences and no `APP_STORE_BUNDLE_ID` means refuse, not pick one.**

    `APPLE_BUNDLE_ID` is an allowlist — the iOS app and, one day, a browser Services ID — and
    `aud` is the only claim that tells them apart. Guessing `[0]` would accept notifications
    about whichever app happened to be first in a comma-separated secret.

    **This refuses at the verifier rather than at startup**, which is the opposite of what
    `APNS_TOPIC` does and is deliberate. Push is configured, so a wrong topic is a silent
    failure worth refusing to boot over. Nothing here is configured, so hard-failing would take
    the whole API down the day somebody adds a second audience — for a webhook already
    answering 401 for want of a root certificate.
    """
    ambiguous = app_store_settings.model_copy(
        update={
            "apple_bundle_id": [stub.BUNDLE_ID, "com.travisterry.web"],
            "app_store_bundle_id": None,
        }
    )
    assert ambiguous.resolved_app_store_bundle_id is None

    verifier = AppStoreVerifier(ambiguous)
    assert verifier.configured is False
    with pytest.raises(NotificationUnverifiable):
        verifier.verify(
            stub.sign_notification(
                app_store_chain, notification_type="SUBSCRIBED", signed_date=SIGNED_AT
            )
        )


async def test_the_app_store_bundle_id_does_not_follow_the_apns_topic(app_store_settings):
    """`APNS_TOPIC` aims push at one audience. It must not also decide whose receipts we take.

    Chaining them would mean a push-configuration change silently re-pointing which app this
    service accepts billing notifications about — a coupling nobody setting `APNS_TOPIC` would
    expect, between a delivery detail and an authorization boundary.
    """
    settings = app_store_settings.model_copy(
        update={
            "apple_bundle_id": [stub.BUNDLE_ID],
            "app_store_bundle_id": None,
            "apns_topic": "com.travisterry.something.else",
        }
    )
    assert settings.resolved_apns_topic == "com.travisterry.something.else"
    assert settings.resolved_app_store_bundle_id == stub.BUNDLE_ID


# --- Guard 5: a renewal for a household nobody is left in, phase 127 -------------------------
#
# Apple keeps sending renewals for a subscription nobody cancelled, because cancelling is
# something only the subscriber can do and they have deleted their account. The `families` row
# survives the erasure by design — account deletion hard-deletes `users` and never names
# `Family` — so these notifications land on a real household with no members.


async def _erased_household(session) -> Family:
    """A real household whose members have actually been erased, not one that never had any.

    Arranged by running the deletion rather than by omitting the user, because the whole point
    of the guard is the state the erasure leaves behind — and a family that never had a member
    is a different bug with a different guard (`recorded:unattributed`).
    """
    family = await make_family(session, tier="free")
    user = await make_user(session, family=family)
    await deletion.request_deletion(session, user)
    await session.commit()

    await deletion.run_due_deletions(
        session, get_settings(), now=dt.datetime.now(tz=dt.UTC) + dt.timedelta(days=8)
    )
    assert await session.get(User, user.id) is None
    return family


async def test_a_renewal_for_an_erased_household_writes_no_entitlement(
    app_store_client, session, app_store_chain
):
    """**Break-test 6.** Before phase 127 this marked the empty household `subscribed` and
    cleared `lapsed_at` — which is not cosmetic, because `lapsed_at` is the clock D3's
    media-deletion policy runs off, so a renewal for somebody who no longer exists silently
    restarted the abandonment timer on what was left of their household."""
    family = await _erased_household(session)

    response = await _post(
        app_store_client,
        stub.sign_notification(
            app_store_chain,
            notification_type="DID_RENEW",
            signed_date=SIGNED_AT,
            app_account_token=family.id,
        ),
    )

    assert response.status_code == 202
    assert response.json()["status"] == "recorded:promotion-refused"
    entitlement = await _entitlement(session, family.id)
    assert entitlement.tier == "free"
    assert entitlement.lapsed_at is None


async def test_a_renewal_for_an_erased_household_still_records_the_receipt(
    app_store_client, session, app_store_chain
):
    """The audit trail is the point, exactly as it is for a refused demotion: a refund may
    still follow this, and Apple will send that too."""
    family = await _erased_household(session)

    await _post(
        app_store_client,
        stub.sign_notification(
            app_store_chain,
            notification_type="DID_RENEW",
            signed_date=SIGNED_AT,
            app_account_token=family.id,
        ),
    )

    row = await _transaction(session, "2000000000000001")
    assert row is not None
    assert row.latest_notification_type == "DID_RENEW"


async def test_an_erased_household_is_never_given_a_payer(
    app_store_client, session, app_store_chain
):
    """`_set_payer` runs inside `_write_tier`, which guard 5 keeps this notification out of.
    A payer id pointing at a deleted user would be a foreign key to nobody."""
    family = await _erased_household(session)

    await _post(
        app_store_client,
        stub.sign_notification(
            app_store_chain,
            notification_type="SUBSCRIBED",
            subtype="INITIAL_BUY",
            signed_date=SIGNED_AT,
            app_account_token=family.id,
        ),
    )

    entitlement = await _entitlement(session, family.id)
    assert entitlement.tier == "free"
    assert entitlement.payer_user_id is None


async def test_a_household_that_still_has_a_parent_is_promoted_as_before(
    app_store_client, session, app_store_chain
):
    """The other half of guard 5, and the one that would fail silently: a guard that refuses
    every promotion would pass all three tests above and break the product."""
    family = await _household(session)
    await session.commit()

    response = await _post(
        app_store_client,
        stub.sign_notification(
            app_store_chain,
            notification_type="DID_RENEW",
            signed_date=SIGNED_AT,
            app_account_token=family.id,
        ),
    )

    assert response.json()["status"] == "tier:subscribed"
    assert (await _entitlement(session, family.id)).tier == "subscribed"
