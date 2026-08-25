"""Phase 113. The four additive membership fields, and the states they let the wire express.

The Settings membership surface has to tell nine household states apart and the server could
express three. These are the four fields that add four more, and the tests below are organised
by the thing each one must never do:

* **`lapsed_at`** must tell *never subscribed* from *used to be*, and must stay null through a
  trial expiring — a trial ending is not a lapse, per D3, and conflating them points D3's
  deletion clock at every household that tried the app for a fortnight.
* **`plan`** must answer `None` rather than guess, and must never appear beside `access: free`.
* **`billing_retry`** must move nothing. A household on a failing card is still entitled.
* **`is_payer`** must be `None` and never `False` when nobody knows, because the client hides
  Apple's subscription-management control on `False`.

**Every payload here is minted locally**, like the rest of `test_app_store.py`: no product
exists in App Store Connect and no real Apple notification has ever reached this service
(`docs/blocked.md` §10). The verification is real; the Apple side is not.
"""

from __future__ import annotations

import datetime as dt
import uuid

import app_store_stub as stub
from factories import make_family, make_user
from helpers import auth_headers
from rascal.constants import PRODUCT_PLANS
from rascal.models import Entitlement
from rascal.schemas.family import FamilyOut

# The same fixed past instant `test_app_store.py` uses, for the same reason: a `signedDate` is
# when Apple decided, and pinning it keeps certificate validity out of the runner's clock.
SIGNED_AT = dt.datetime(2026, 6, 1, 12, 0, tzinfo=dt.UTC)
LATER = SIGNED_AT + dt.timedelta(days=30)

WEBHOOK = "/v1/webhooks/app-store"
ME = "/v1/families/me"


async def _post(client, chain, **kwargs):
    """One signed notification through the real webhook. Defaults to a first purchase."""
    kwargs.setdefault("notification_type", "SUBSCRIBED")
    kwargs.setdefault("subtype", "INITIAL_BUY")
    kwargs.setdefault("signed_date", SIGNED_AT)
    return await client.post(
        WEBHOOK,
        json={"signedPayload": stub.sign_notification(chain, **kwargs)},
    )


async def _me(client, user) -> dict:
    response = await client.get(ME, headers=auth_headers(user))
    assert response.status_code == 200
    return response.json()


# --- Task 1 · `lapsed_at`: telling state 5 from state 6 ----------------------------------------


async def test_a_household_that_never_subscribed_reports_no_lapse(client, session):
    """State 5. `null` here is *never subscribed*, and the client renders the plain free tier."""
    user = await make_user(session)
    await session.commit()

    body = await _me(client, user)
    assert body["tier"] == "free"
    assert body["lapsed_at"] is None
    # Nothing else about this household is claimed either — it has never paid for anything.
    assert body["plan"] is None
    assert body["billing_retry"] is False
    assert body["is_payer"] is None


async def test_a_lapsed_household_reports_when_it_lapsed(client, session):
    """State 6, and **the whole reason this field moved onto `FamilyOut`.**

    Before phase 113 the app could not tell this household from the one above: both read
    `tier: free`, `access: free`, and `lapsed_at` lived only on an endpoint the client has no
    method for.
    """
    family = await make_family(session, tier="free", trial_ends_at=None)
    user = await make_user(session, family=family)
    entitlement = await session.get(Entitlement, family.id)
    entitlement.lapsed_at = dt.datetime(2026, 5, 1, tzinfo=dt.UTC)
    await session.commit()

    body = await _me(client, user)
    assert body["access"] == "free"
    assert body["lapsed_at"] == "2026-05-01T00:00:00Z"


async def test_a_trial_running_out_is_not_a_lapse(client, session):
    """**D3, defended on the new field.** A household whose fortnight ended and who never paid
    reads `access: free` with `lapsed_at: null` — it did not cancel anything, and rendering it
    as though it had would be the copy that reads as a threat."""
    family = await make_family(
        session, tier="free", trial_ends_at=dt.datetime(2026, 1, 1, tzinfo=dt.UTC)
    )
    user = await make_user(session, family=family)
    await session.commit()

    body = await _me(client, user)
    assert body["access"] == "free"
    assert body["lapsed_at"] is None


async def test_families_me_never_carries_the_deletion_clock(client, session):
    """**`eligible_at` is absent from this shape and that absence is load-bearing.**

    It is D3's deletion date. `free-tier-copy.md` §4 pre-bans the sentence in words; keeping the
    field off the one schema the Settings screen reads bans it in numbers, so the surface cannot
    render it by accident. It stays on `GET /families/{id}/entitlement` for the console.
    """
    family = await make_family(session, tier="free", trial_ends_at=None)
    user = await make_user(session, family=family)
    entitlement = await session.get(Entitlement, family.id)
    entitlement.lapsed_at = dt.datetime(2026, 5, 1, tzinfo=dt.UTC)
    await session.commit()

    assert "eligible_at" not in await _me(client, user)


# --- Task 2 · `plan`: annual, monthly, or an honest silence -----------------------------------


async def test_an_annual_subscription_reports_annual(
    app_store_client, client, session, app_store_chain
):
    family = await make_family(session)
    user = await make_user(session, family=family)
    await session.commit()

    assert (
        await _post(
            app_store_client,
            app_store_chain,
            app_account_token=family.id,
            product_id=stub.ANNUAL_PRODUCT_ID,
        )
    ).status_code == 202

    body = await _me(client, user)
    assert body["access"] == "subscribed"
    assert body["plan"] == "annual"


async def test_a_monthly_subscription_reports_monthly(
    app_store_client, client, session, app_store_chain
):
    family = await make_family(session)
    user = await make_user(session, family=family)
    await session.commit()

    await _post(
        app_store_client,
        app_store_chain,
        app_account_token=family.id,
        product_id=stub.MONTHLY_PRODUCT_ID,
    )

    assert (await _me(client, user))["plan"] == "monthly"


async def test_an_unrecognised_product_reports_no_plan_rather_than_guessing(
    app_store_client, client, session, app_store_chain
):
    """**The lookup is a mapping, never a substring search.**

    A product id nobody has decided on — D6's printed book lives in this namespace — must read
    as unknown. An implementation that searched the id for `annual` would answer confidently
    for identifiers that have never been agreed.
    """
    family = await make_family(session)
    user = await make_user(session, family=family)
    await session.commit()

    await _post(
        app_store_client,
        app_store_chain,
        app_account_token=family.id,
        product_id=stub.UNKNOWN_PRODUCT_ID,
    )

    body = await _me(client, user)
    assert body["access"] == "subscribed", "an unknown product still subscribed them"
    assert body["plan"] is None
    assert stub.UNKNOWN_PRODUCT_ID not in PRODUCT_PLANS


async def test_a_subscription_with_no_receipt_reports_no_plan(client, session):
    """**`runbook-deploy.md` §7a is a live state, not a defensive branch.** The owner's own
    household was written `subscribed` by hand and there is no Apple transaction behind it, so
    the honest answer to "which plan" is that nobody knows."""
    family = await make_family(session, tier="subscribed")
    user = await make_user(session, family=family)
    await session.commit()

    body = await _me(client, user)
    assert body["access"] == "subscribed"
    assert body["plan"] is None


async def test_a_lapsed_household_reports_no_plan_even_though_a_receipt_exists(
    app_store_client, client, session, app_store_chain
):
    """**`plan` describes a *current* subscription.** This household really did pay annually and
    the ledger row still says so — but it is `free` now, and reporting `plan: "annual"` beside
    `access: "free"` would invite a client to render a membership cadence for a non-member.

    **`trial_ends_at=None` is load-bearing in this fixture.** `make_family` leaves the column to
    its default, which puts every household fourteen days into a trial — so a household demoted
    by `EXPIRED` still reads `access: "trial"`, correctly, and the assertion below would be
    testing the trial rather than the lapse.
    """
    family = await make_family(session, trial_ends_at=None)
    user = await make_user(session, family=family)
    await session.commit()

    await _post(
        app_store_client,
        app_store_chain,
        app_account_token=family.id,
        product_id=stub.ANNUAL_PRODUCT_ID,
    )
    await _post(
        app_store_client,
        app_store_chain,
        notification_type="EXPIRED",
        subtype=None,
        signed_date=LATER,
        app_account_token=family.id,
        product_id=stub.ANNUAL_PRODUCT_ID,
    )

    body = await _me(client, user)
    assert body["access"] == "free"
    assert body["plan"] is None
    assert body["lapsed_at"] is not None, "the lapse itself is still reported"


async def test_a_plan_change_moves_what_the_field_reports(
    app_store_client, client, session, app_store_chain
):
    """Monthly, then a renewal on the annual product. **The renewal is when the change is real**
    — D5a keeps both durations in one subscription group precisely so this is a plan change
    rather than two overlapping subscriptions."""
    family = await make_family(session)
    user = await make_user(session, family=family)
    await session.commit()

    await _post(
        app_store_client,
        app_store_chain,
        app_account_token=family.id,
        product_id=stub.MONTHLY_PRODUCT_ID,
    )
    assert (await _me(client, user))["plan"] == "monthly"

    await _post(
        app_store_client,
        app_store_chain,
        notification_type="DID_RENEW",
        subtype=None,
        signed_date=LATER,
        app_account_token=family.id,
        product_id=stub.ANNUAL_PRODUCT_ID,
    )

    assert (await _me(client, user))["plan"] == "annual"


# --- Task 3 · `billing_retry`: saying something without moving the gate -------------------------


async def test_a_household_in_grace_is_still_fully_entitled(
    app_store_client, client, session, app_store_chain
):
    """**The single most important assertion in this file.**

    Apple is retrying a failing card. The household keeps everything: `access` is still
    `subscribed`, the tier is untouched, and `billing_retry` is the *only* thing that moved. If
    this test ever fails by `access` becoming anything else, phase 113 has taken a family's
    archive away over a card that may yet go through.
    """
    family = await make_family(session)
    user = await make_user(session, family=family)
    await session.commit()

    await _post(
        app_store_client,
        app_store_chain,
        app_account_token=family.id,
        product_id=stub.ANNUAL_PRODUCT_ID,
    )
    await _post(
        app_store_client,
        app_store_chain,
        notification_type="DID_FAIL_TO_RENEW",
        subtype="GRACE_PERIOD",
        signed_date=LATER,
        app_account_token=family.id,
        product_id=stub.ANNUAL_PRODUCT_ID,
    )

    body = await _me(client, user)
    assert body["access"] == "subscribed"
    assert body["tier"] == "subscribed"
    assert body["billing_retry"] is True
    assert body["plan"] == "annual", "the plan is still readable during a retry"


async def test_billing_retry_clears_itself_when_the_card_goes_through(
    app_store_client, client, session, app_store_chain
):
    """Nothing has to remember to turn it off: the later notification overwrites the same
    ledger row this is derived from."""
    family = await make_family(session)
    user = await make_user(session, family=family)
    await session.commit()

    await _post(
        app_store_client,
        app_store_chain,
        app_account_token=family.id,
        product_id=stub.ANNUAL_PRODUCT_ID,
    )
    await _post(
        app_store_client,
        app_store_chain,
        notification_type="DID_FAIL_TO_RENEW",
        subtype="GRACE_PERIOD",
        signed_date=LATER,
        app_account_token=family.id,
        product_id=stub.ANNUAL_PRODUCT_ID,
    )
    assert (await _me(client, user))["billing_retry"] is True

    await _post(
        app_store_client,
        app_store_chain,
        notification_type="DID_RENEW",
        subtype=None,
        signed_date=LATER + dt.timedelta(days=1),
        app_account_token=family.id,
        product_id=stub.ANNUAL_PRODUCT_ID,
    )

    body = await _me(client, user)
    assert body["billing_retry"] is False
    assert body["access"] == "subscribed"


async def test_when_the_retrying_stops_the_household_lapses_and_stops_retrying(
    app_store_client, client, session, app_store_chain
):
    """`GRACE_PERIOD_EXPIRED` is the notification that actually demotes. `billing_retry` goes
    with it — a free household is not having its card retried.

    `trial_ends_at=None` for the same reason as the lapse test above: the factory's default
    trial would otherwise leave this household reading `access: "trial"` after the demotion.
    """
    family = await make_family(session, trial_ends_at=None)
    user = await make_user(session, family=family)
    await session.commit()

    await _post(
        app_store_client,
        app_store_chain,
        app_account_token=family.id,
        product_id=stub.ANNUAL_PRODUCT_ID,
    )
    await _post(
        app_store_client,
        app_store_chain,
        notification_type="GRACE_PERIOD_EXPIRED",
        subtype=None,
        signed_date=LATER,
        app_account_token=family.id,
        product_id=stub.ANNUAL_PRODUCT_ID,
    )

    body = await _me(client, user)
    assert body["access"] == "free"
    assert body["billing_retry"] is False


async def test_a_free_household_is_never_reported_as_retrying(client, session):
    user = await make_user(session)
    await session.commit()

    body = await _me(client, user)
    assert body["billing_retry"] is False
    assert body["plan"] is None


# --- Task 4 · `is_payer`: three values, and the third is the point -----------------------------


async def test_the_sole_guardian_who_subscribed_is_the_payer(
    app_store_client, client, session, app_store_chain
):
    family = await make_family(session)
    user = await make_user(session, family=family)
    await session.commit()

    await _post(
        app_store_client,
        app_store_chain,
        app_account_token=family.id,
        product_id=stub.ANNUAL_PRODUCT_ID,
    )

    assert (await _me(client, user))["is_payer"] is True


async def test_two_guardians_leave_the_payer_unknown_and_unknown_is_never_false(
    app_store_client, client, session, app_store_chain
):
    """**The case the whole tri-state exists for, and it is the common one.**

    `appAccountToken` carries a *family* id, so Apple's notification never names a user. With
    two guardians the server genuinely does not know, and `_set_payer` correctly declines to
    guess. Both parents must read `null` — **not `false`** — because phase 112 hides Apple's
    subscription-management control on `false`, and hiding it here would strip it from whichever
    of these two is actually paying.
    """
    family = await make_family(session)
    first = await make_user(session, family=family, display_name="Travis")
    second = await make_user(session, family=family, display_name="Anna")
    await session.commit()

    await _post(
        app_store_client,
        app_store_chain,
        app_account_token=family.id,
        product_id=stub.ANNUAL_PRODUCT_ID,
    )

    for guardian in (first, second):
        body = await _me(client, guardian)
        assert body["access"] == "subscribed"
        assert body["is_payer"] is None, "unknown must stay unknown for both parents"
        assert body["is_payer"] is not False


async def test_the_other_guardian_reads_false_only_when_the_payer_is_actually_known(
    client, session
):
    """`False` is a real answer and must still be reachable — otherwise the tri-state is a
    two-state with extra steps. It is reachable exactly when `payer_user_id` is populated."""
    family = await make_family(session, tier="subscribed")
    payer = await make_user(session, family=family, display_name="Travis")
    other = await make_user(session, family=family, display_name="Anna")
    entitlement = await session.get(Entitlement, family.id)
    entitlement.payer_user_id = payer.id
    await session.commit()

    assert (await _me(client, payer))["is_payer"] is True
    assert (await _me(client, other))["is_payer"] is False


async def test_the_response_never_discloses_which_member_is_the_payer(client, session):
    """`is_payer` answers the question **about the caller**, and that is the whole disclosure.

    The raw `payer_user_id` is not on the wire under any name. Note what this test deliberately
    does *not* assert: that the payer's UUID is absent from the body. It is present, and
    legitimately so — every household member appears in `guardians[].user_id`, which has been
    true since phase 36 and is what lets a client render the household at all. What must not
    leak is *which* of those members is paying, and a caller reading `is_payer: false` learns
    only that it is not them.
    """
    family = await make_family(session, tier="subscribed")
    payer = await make_user(session, family=family, display_name="Travis")
    other = await make_user(session, family=family, display_name="Anna")
    entitlement = await session.get(Entitlement, family.id)
    entitlement.payer_user_id = payer.id
    await session.commit()

    response = await client.get(ME, headers=auth_headers(other))
    body = response.json()

    assert "payer_user_id" not in response.text
    assert all("is_payer" not in guardian for guardian in body["guardians"])
    assert body["is_payer"] is False
    # The payer is in the guardian list as a member, and is not marked out as the payer there.
    assert sorted(g["user_id"] for g in body["guardians"]) == sorted([str(payer.id), str(other.id)])


# --- The compatibility floor: every new field absent -------------------------------------------


async def test_a_payload_missing_every_new_field_still_decodes_to_the_safe_direction():
    """**The old-client check, and it is really a check on which way the defaults fail.**

    A client built before phase 113 sends nothing and reads nothing new; a server built before
    it omits all four. What matters is that every default is the *permissive* one — the same
    principle as standing rule D9, where an unrecognised `access` means entitled rather than
    locked.
    """
    decoded = FamilyOut.model_validate(
        {
            "family_id": uuid.uuid4(),
            "tier": "subscribed",
            "access": "subscribed",
            "guardians": [],
        }
    )

    assert decoded.lapsed_at is None
    assert decoded.plan is None
    # Show the management control, never hide it, when nobody has said otherwise.
    assert decoded.is_payer is None
    # No alarm about a card nobody said was failing.
    assert decoded.billing_retry is False


async def test_the_new_fields_are_additive_and_change_nothing_that_was_there(client, session):
    """Every field `GET /families/me` reported before phase 113 still reports the same value.

    The four additions are new keys beside them, not a reinterpretation of any of them —
    `tier` in particular still means exactly what it has meant since phase 37a.
    """
    family = await make_family(session, tier="subscribed")
    user = await make_user(session, family=family)
    await session.commit()

    body = await _me(client, user)

    assert body["tier"] == "subscribed"
    assert body["access"] == "subscribed"
    assert body["family_id"] == str(family.id)
    assert [g["is_you"] for g in body["guardians"]] == [True]
    assert body["pending_invites"] == []
    assert set(body) == {
        "family_id",
        "tier",
        "access",
        "trial_ends_at",
        "guardians",
        "pending_invites",
        # Phase 113, and nothing else. A fifth key appearing here is a contract change.
        "lapsed_at",
        "plan",
        "billing_retry",
        "is_payer",
        # Phase 121's three, and the same three `GET /families/{id}/entitlement` reports.
        # **`tier` above still means what Apple said** — that is the assertion two lines up and
        # it is unchanged; `entitled` is the union a gate reads, and `entitlement_source` is what
        # tells a paid household from a complimentary one without a fourth `access` value.
        "entitled",
        "entitlement_source",
        "grant_expires_at",
    }
    # This household is subscribed with no grant, so the additions say exactly that.
    assert body["entitled"] is True
    assert body["entitlement_source"] == "receipt"
    assert body["grant_expires_at"] is None


async def test_billing_retry_is_the_last_word_apple_said_and_under_reports_by_design(
    app_store_client, client, session, app_store_chain
):
    """**A known imprecision, pinned so it stays in the safe direction.**

    `billing_retry` reads *the last notification for this subscription*, and any notification
    overwrites it — including ones that change no tier. A household that turns auto-renew off
    while Apple is still retrying its card reads `false`.

    **The error is always under-reporting and never over-reporting**, which is the whole reason
    this is acceptable: a missed offer to fix a card costs nothing (entitlement is untouched and
    nothing renders the field yet), whereas telling a healthy subscriber their payment is failing
    is a false alarm. **If this test ever flips to asserting `True`, check what made it exact** —
    being exact needs `renewalInfo.gracePeriodExpiresDate`, which is a separate phase.
    """
    family = await make_family(session)
    user = await make_user(session, family=family)
    await session.commit()

    await _post(
        app_store_client,
        app_store_chain,
        app_account_token=family.id,
        product_id=stub.ANNUAL_PRODUCT_ID,
    )
    await _post(
        app_store_client,
        app_store_chain,
        notification_type="DID_FAIL_TO_RENEW",
        subtype="GRACE_PERIOD",
        signed_date=LATER,
        app_account_token=family.id,
        product_id=stub.ANNUAL_PRODUCT_ID,
    )
    assert (await _me(client, user))["billing_retry"] is True

    # Auto-renew off. Changes no tier — and must not, the household is paid up to `expires_date`.
    await _post(
        app_store_client,
        app_store_chain,
        notification_type="DID_CHANGE_RENEWAL_STATUS",
        subtype="AUTO_RENEW_DISABLED",
        signed_date=LATER + dt.timedelta(days=1),
        app_account_token=family.id,
        product_id=stub.ANNUAL_PRODUCT_ID,
    )

    body = await _me(client, user)
    assert body["billing_retry"] is False, "under-reports, and that is the documented direction"
    # The part that actually matters, and it is unchanged: they are still fully entitled.
    assert body["access"] == "subscribed"
    assert body["plan"] == "annual"
