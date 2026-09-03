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

from sqlalchemy import select

import app_store_stub as stub
from factories import make_family, make_user
from helpers import auth_headers
from rascal.constants import PRODUCT_PLANS
from rascal.models import AppStoreTransaction, Entitlement
from rascal.schemas.family import FamilyOut
from rascal.services.guardians import access_for
from rascal.services.membership import membership_signals

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


async def test_a_production_row_outranks_a_newer_sandbox_row(
    app_store_client, client, session, app_store_chain
):
    """Phase 139 lets a Sandbox row be attributed to a household that later pays for real. A
    sandbox subscription renews on an accelerated clock and can simulate a billing failure, so
    by signed date alone the tester's row would be the one this screen reads — and a paying
    household would see `billing_retry: true` and the wrong plan."""
    family = await make_family(session)
    user = await make_user(session, family=family)
    await session.commit()

    production = await _post(
        app_store_client,
        app_store_chain,
        signed_date=SIGNED_AT,
        environment="Production",
        original_transaction_id="2000000000000001",
        app_account_token=family.id,
        product_id=stub.ANNUAL_PRODUCT_ID,
    )
    sandbox = await _post(
        app_store_client,
        app_store_chain,
        notification_type="DID_FAIL_TO_RENEW",
        subtype="GRACE_PERIOD",
        signed_date=LATER,
        environment="Sandbox",
        original_transaction_id="2000000000000002",
        app_account_token=family.id,
        product_id=stub.MONTHLY_PRODUCT_ID,
    )
    assert production.status_code == sandbox.status_code == 202
    # The precondition, pinned: both rows are this household's, so signed date alone would
    # pick the Sandbox one. (`ENVIRONMENT=local` in the suite, where Sandbox is attributed.)
    attributed = (
        (
            await session.execute(
                select(AppStoreTransaction.family_id).where(
                    AppStoreTransaction.original_transaction_id.in_(
                        ["2000000000000001", "2000000000000002"]
                    )
                )
            )
        )
        .scalars()
        .all()
    )
    assert attributed == [family.id, family.id]

    body = await _me(client, user)
    assert body["plan"] == "annual"
    assert body["billing_retry"] is False


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
    # Phase 144: no count, no date, no word about renewal — a client renders the bare headline.
    assert decoded.trial_days_left is None
    assert decoded.expires_at is None
    assert decoded.auto_renew is None


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
        # Phase 144's three, for the Settings card: the count beside the trial's date, and the
        # period end with Apple's word on whether it renews. All null for this household — no
        # trial is served to a subscriber, and there is no receipt behind a hand-set tier.
        "trial_days_left",
        "expires_at",
        "auto_renew",
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


# --- Phase 144 · `expires_at`, `auto_renew` and `trial_days_left` -----------------------------
#
# The Settings card's redesign (Sep 3, 2026) asked two questions the wire could not answer:
# *when does this membership renew or end*, and *how many days of the trial are left*. The
# first is on the ledger row `plan` already reads; the second is arithmetic beside the one
# trial comparison in `access_for`. Both are for copy only and neither moves a gate.


def _far_future() -> dt.datetime:
    """A period end a year out, **relative to the clock and never a literal** — a future date
    literal is what `test_fixture_dates.py` forbids, because it becomes a past one on a day
    nobody is watching. Truncated to whole seconds because Apple's `expiresDate` is in
    milliseconds and the stub rounds to them; a fixture carrying microseconds would come back
    a hair earlier than it went in and the equality below would be false for no reason."""
    return dt.datetime.now(tz=dt.UTC).replace(microsecond=0) + dt.timedelta(days=365)


def _moment(value: str) -> dt.datetime:
    return dt.datetime.fromisoformat(value)


async def _entitlement(client, user, family_id) -> dict:
    response = await client.get(f"/v1/families/{family_id}/entitlement", headers=auth_headers(user))
    assert response.status_code == 200
    return response.json()


async def test_a_subscription_reports_when_it_renews(
    app_store_client, client, session, app_store_chain
):
    """The owner's ask, on the wire: *Renews {date}* needs a date and a word, and both come off
    the ledger row `plan` is already read from — one query, no new column."""
    renews = _far_future()
    family = await make_family(session)
    user = await make_user(session, family=family)
    await session.commit()

    await _post(
        app_store_client,
        app_store_chain,
        app_account_token=family.id,
        product_id=stub.ANNUAL_PRODUCT_ID,
        expires_date=renews,
    )

    body = await _me(client, user)
    assert _moment(body["expires_at"]) == renews
    assert body["auto_renew"] is True, "the stub signs `autoRenewStatus: 1` unless told otherwise"
    assert body["plan"] == "annual"


async def test_auto_renew_off_is_reported_as_apple_said_it(
    app_store_client, client, session, app_store_chain
):
    """`DID_CHANGE_RENEWAL_STATUS` moves no tier — the household is paid up to the date — and
    the card now says *Expires {date}* rather than *Renews*, because Apple said so, not because
    the last notification type was inferred into a guess."""
    ends = _far_future()
    family = await make_family(session)
    user = await make_user(session, family=family)
    await session.commit()

    await _post(
        app_store_client,
        app_store_chain,
        app_account_token=family.id,
        product_id=stub.MONTHLY_PRODUCT_ID,
        expires_date=ends,
    )
    await _post(
        app_store_client,
        app_store_chain,
        notification_type="DID_CHANGE_RENEWAL_STATUS",
        subtype="AUTO_RENEW_DISABLED",
        signed_date=LATER,
        app_account_token=family.id,
        product_id=stub.MONTHLY_PRODUCT_ID,
        expires_date=ends,
        auto_renew_status=0,
    )

    body = await _me(client, user)
    assert body["access"] == "subscribed", "turning renewal off takes nothing away today"
    assert _moment(body["expires_at"]) == ends
    assert body["auto_renew"] is False
    assert body["plan"] == "monthly"


async def test_a_payload_without_renewal_info_leaves_auto_renew_unknown(
    app_store_client, client, session, app_store_chain
):
    """Null means nobody knows, and the client renders *Paid through {date}* for it. A receipt
    the app submitted itself (phase 140) is the live case: it carries the transaction JWS and
    no `renewalInfo`, so until Apple's next notification the status is genuinely unknown."""
    renews = _far_future()
    family = await make_family(session)
    user = await make_user(session, family=family)
    await session.commit()

    await _post(
        app_store_client,
        app_store_chain,
        app_account_token=family.id,
        product_id=stub.ANNUAL_PRODUCT_ID,
        expires_date=renews,
        include_renewal_info=False,
    )

    body = await _me(client, user)
    assert _moment(body["expires_at"]) == renews
    assert body["auto_renew"] is None


async def test_a_lapsed_household_reports_no_period_end_even_though_the_row_holds_one(
    app_store_client, client, session, app_store_chain
):
    """The same rule `plan` has: both fields describe a *current* subscription. The ledger row
    keeps its date — it is the audit record — and the wire reports null beside `access: free`."""
    family = await make_family(session, trial_ends_at=None)
    user = await make_user(session, family=family)
    await session.commit()

    await _post(
        app_store_client,
        app_store_chain,
        app_account_token=family.id,
        product_id=stub.ANNUAL_PRODUCT_ID,
        expires_date=_far_future(),
    )
    await _post(
        app_store_client,
        app_store_chain,
        notification_type="EXPIRED",
        subtype=None,
        signed_date=LATER,
        app_account_token=family.id,
        product_id=stub.ANNUAL_PRODUCT_ID,
        expires_date=LATER,
    )

    body = await _me(client, user)
    assert body["access"] == "free"
    assert body["expires_at"] is None
    assert body["auto_renew"] is None
    row = (
        await session.execute(
            select(AppStoreTransaction).where(AppStoreTransaction.family_id == family.id)
        )
    ).scalar_one()
    assert row.expires_date is not None, "the ledger still holds the date; the wire does not"


async def test_a_period_end_in_the_past_is_not_reported(app_store_client, session, app_store_chain):
    """A stale ledger — the renewal happened and Apple's notification has not landed yet — must
    never surface as *Renews {a date that has passed}*. The clock is injected rather than slept
    past, which is the same shape `access_for` gives its tests."""
    renews = _far_future()
    family = await make_family(session, tier="subscribed")
    await session.commit()

    await _post(
        app_store_client,
        app_store_chain,
        app_account_token=family.id,
        product_id=stub.ANNUAL_PRODUCT_ID,
        expires_date=renews,
    )

    day = dt.timedelta(days=1)
    before = await membership_signals(session, family.id, tier="subscribed", now=renews - day)
    assert before.expires_at == renews
    assert before.auto_renew is True

    after = await membership_signals(session, family.id, tier="subscribed", now=renews + day)
    assert after.expires_at is None
    assert after.auto_renew is None, "no word about renewal beside no date"
    assert after.plan == "annual", "the plan is still what the ledger says"

    # `now == expires_date` is the boundary, and the period has ended: the comparison is strict
    # so the card never says *Renews today* about a renewal that is already due.
    boundary = await membership_signals(session, family.id, tier="subscribed", now=renews)
    assert boundary.expires_at is None


async def test_a_household_in_grace_reports_no_period_end(
    app_store_client, client, session, app_store_chain
):
    """The date on a row in retry is the day the renewal *failed*, which is neither a renewal
    to announce nor an expiry to state. **The fixture carries a future date on purpose**: the
    stub's default is no date at all, and a test that passed because there was nothing to hide
    would prove nothing about the rule."""
    renews = _far_future()
    family = await make_family(session)
    user = await make_user(session, family=family)
    await session.commit()

    await _post(
        app_store_client,
        app_store_chain,
        app_account_token=family.id,
        product_id=stub.ANNUAL_PRODUCT_ID,
        expires_date=renews,
    )
    await _post(
        app_store_client,
        app_store_chain,
        notification_type="DID_FAIL_TO_RENEW",
        subtype="GRACE_PERIOD",
        signed_date=LATER,
        app_account_token=family.id,
        product_id=stub.ANNUAL_PRODUCT_ID,
        expires_date=renews,
    )

    body = await _me(client, user)
    assert body["access"] == "subscribed", "grace withholds nothing"
    assert body["billing_retry"] is True
    assert body["expires_at"] is None
    assert body["auto_renew"] is None


async def test_a_free_household_reports_none_of_the_three(client, session):
    family = await make_family(session, tier="free", trial_ends_at=None)
    user = await make_user(session, family=family)
    await session.commit()

    body = await _me(client, user)
    assert body["access"] == "free"
    assert body["trial_days_left"] is None
    assert body["expires_at"] is None
    assert body["auto_renew"] is None


async def test_a_trial_reports_its_days_left_and_a_subscriber_does_not(client, session):
    """`make_family` leaves the trial to its column default — fourteen days from the insert —
    so a read seconds later has thirteen-and-a-bit days left, which `ceil` reports as 14: the
    count a parent reads on day one is the fourteen they were promised."""
    trialling = await make_family(session)
    parent = await make_user(session, family=trialling)
    # A subscriber holding the same future trial is not on a countdown (`subscribed` beats
    # `trial`, and the count follows `access`).
    paying = await make_family(session, tier="subscribed")
    payer = await make_user(session, family=paying)
    await session.commit()

    trial = await _me(client, parent)
    assert trial["access"] == "trial"
    assert trial["trial_days_left"] == 14

    subscribed = await _me(client, payer)
    assert subscribed["access"] == "subscribed"
    assert subscribed["trial_ends_at"] is not None, "the column is untouched"
    assert subscribed["trial_days_left"] is None


def test_trial_days_left_is_arithmetic_on_the_one_comparison():
    """Every edge of the count, against an injected clock. **No new comparison against
    `trial_ends_at` exists for it** — `test_entitlement_cadence.py`'s AST walk still finds
    exactly one — so the day the count says the trial ends is the day the gate closes."""
    now = dt.datetime.now(tz=dt.UTC)
    day = dt.timedelta(days=1)
    hour = dt.timedelta(hours=1)

    def left(**kwargs) -> int | None:
        granted = kwargs.pop("granted", False)
        return access_for(Entitlement(**kwargs), granted=granted, now=now).trial_days_left

    assert left(tier="free", trial_ends_at=now + 14 * day) == 14
    assert left(tier="free", trial_ends_at=now + 13 * day + hour) == 14, "a partial day is a day"
    assert left(tier="free", trial_ends_at=now + 13 * day) == 13
    assert left(tier="free", trial_ends_at=now + hour) == 1, "the last hours are still day one"
    assert left(tier="free", trial_ends_at=now + dt.timedelta(seconds=1)) == 1
    # `now == trial_ends_at` is the boundary the cadence tests pin: the trial has ended.
    assert left(tier="free", trial_ends_at=now) is None
    assert left(tier="free", trial_ends_at=now - day) is None
    assert left(tier="free", trial_ends_at=None) is None
    # Not a countdown for anybody who is not on the trial, whatever the column holds.
    assert left(tier="subscribed", trial_ends_at=now + 14 * day) is None
    assert left(tier="free", trial_ends_at=now + 14 * day, granted=True) is None


async def test_the_entitlement_route_reports_the_same_three(
    app_store_client, client, session, app_store_chain
):
    """One function, two shapes — the rule `plan` and `billing_retry` already obey, extended
    to the three fields phase 144 added, so the console and the app can never disagree about
    when a membership renews."""
    renews = _far_future()
    family = await make_family(session)
    user = await make_user(session, family=family)
    await session.commit()

    await _post(
        app_store_client,
        app_store_chain,
        app_account_token=family.id,
        product_id=stub.ANNUAL_PRODUCT_ID,
        expires_date=renews,
    )

    me = await _me(client, user)
    entitlement = await _entitlement(client, user, family.id)
    for key in ("trial_days_left", "expires_at", "auto_renew"):
        assert me[key] == entitlement[key], key
    assert _moment(entitlement["expires_at"]) == renews
    assert entitlement["auto_renew"] is True
    assert entitlement["trial_days_left"] is None
