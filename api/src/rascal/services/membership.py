"""What the receipt ledger can say about a subscription that `entitlements` cannot.

`entitlements` answers *may this household do things* — one row, two columns, one authority in
`services/guardians.access_for`. **Nothing here touches that answer.** This module reads
`app_store_transactions`, the ledger of what Apple last told us, and derives two facts a
client may *say* without either of them moving a gate:

* **`plan`** — annual or monthly, so Settings can name the cadence instead of showing a bare
  "Subscribed".
* **`billing_retry`** — whether Apple is currently retrying a failing card.

**Neither field gates anything, and `billing_retry` in particular must never start.** A
household in the grace period is fully entitled and reads `access: "subscribed"`: Apple is
still retrying, the archive stays open, and that is the product call rather than an oversight.
`services/app_store_events.tier_effect` is where that is decided and it is unchanged by this
phase — the field exists so the app can offer to fix a card, not so it can take anything away.

## Both fields describe a *current* subscription, and that is one rule rather than two

A household that lapsed from annual reports `plan: None`, not `"annual"`. A household that is
not subscribed reports `billing_retry: False` whatever the last notification said. The
alternative — reporting the last thing Apple mentioned regardless of standing — puts
`plan: "annual"` next to `access: "free"` on the wire and invites a client to render a
membership cadence for somebody who is not a member. One rule, checked once, and every
downstream combination that would need explaining is unrepresentable instead.

## Why this is derived per read rather than stored

The alternative is a column on `entitlements`, which then has to be kept true by every path
that writes a notification — and `CLAUDE.md`'s constrained-value rule would make it `text` plus
a named `CHECK` besides. The ledger row is already the authority for both facts and is already
indexed by family, so a column would be a denormalisation whose only job is to disagree with
the ledger eventually. `eligible_at` is derived for the same reason and says so.
"""

from __future__ import annotations

import uuid
from dataclasses import dataclass

from sqlalchemy import select
from sqlalchemy.ext.asyncio import AsyncSession

from rascal.constants import (
    BILLING_RETRY_NOTIFICATION,
    BILLING_RETRY_SUBTYPE,
    PRODUCT_PLANS,
    SubscriptionPlan,
    Tier,
)
from rascal.models import AppStoreTransaction


@dataclass(frozen=True)
class MembershipSignals:
    """The two derived facts, together, because one query produces both."""

    #: `annual` | `monthly` | `None`. **`None` is an answer, not a gap** — no transaction row,
    #: a product id this build does not recognise, or a household that is not subscribed.
    plan: SubscriptionPlan | None
    #: Whether Apple is retrying a failing card. **Never gates anything.**
    billing_retry: bool


#: What a household with nothing to say reports. Named rather than repeated so the three
#: paths that reach it cannot drift into three different shapes of "nothing".
NO_SIGNALS = MembershipSignals(plan=None, billing_retry=False)


async def membership_signals(
    session: AsyncSession, family_id: uuid.UUID, *, tier: Tier
) -> MembershipSignals:
    """The plan and billing state for one household. One indexed query, or none at all.

    *tier* is passed in rather than re-read because every caller has already loaded the
    `entitlements` row through `services/guardians.entitlement_for`, and a second read of the
    same row to answer the same question is how two callers eventually get two answers.

    **A household that is not subscribed short-circuits before the query**, so the free tier —
    which is most households — pays nothing for this field pair at all.
    """
    if tier != "subscribed":
        return NO_SIGNALS

    # Only the three columns that are read. `raw_payload` on this table is the whole decoded
    # Apple notification, and loading a JSONB blob of that size on every household read to
    # look at two strings beside it is the kind of cost that never shows up in a test.
    #
    # `original_transaction_id` breaks ties on `latest_signed_date` so the answer is stable
    # between two calls that see the same rows — a household holding two transactions signed
    # in the same second is a plan change, and picking a different one each read would flap
    # the plan on somebody's Settings screen.
    #
    # `environment` sorts first, and `"Production"` sorts before `"Sandbox"`. Since phase 139
    # a Sandbox row can be attributed to a household that later pays for real, and a sandbox
    # subscription renews on an accelerated clock, so by signed date alone the tester's row
    # would keep outranking the paying one — and a sandbox account can simulate a billing
    # failure, which would put `billing_retry: true` on a paying household's Settings screen.
    row = (
        await session.execute(
            select(
                AppStoreTransaction.product_id,
                AppStoreTransaction.latest_notification_type,
                AppStoreTransaction.latest_notification_subtype,
            )
            .where(AppStoreTransaction.family_id == family_id)
            .order_by(
                AppStoreTransaction.environment.asc(),
                AppStoreTransaction.latest_signed_date.desc(),
                AppStoreTransaction.original_transaction_id.desc(),
            )
            .limit(1)
        )
    ).first()

    if row is None:
        # Subscribed with no receipt behind it. `docs/runbook-deploy.md` §7a wrote the owner's
        # own household by hand and there is no Apple transaction for it, so this is a live
        # state rather than a defensive branch — and the honest answer to "which plan" is that
        # nobody knows.
        return NO_SIGNALS

    product_id, notification_type, subtype = row
    return MembershipSignals(
        # `.get` on the mapping, never a substring search — see `constants.PRODUCT_PLANS`.
        plan=PRODUCT_PLANS.get(product_id) if product_id is not None else None,
        # The ledger row is overwritten in place by every later notification for the same
        # subscription, so this clears itself: a successful retry arrives as `DID_RENEW` and a
        # failed one as `GRACE_PERIOD_EXPIRED`, and either overwrites both columns read here.
        # Nothing has to remember to turn it off.
        #
        # **It is "the last thing Apple said was a grace notification", not "is in grace", and
        # those differ.** Any notification for this subscription overwrites these two columns,
        # including ones that change no tier — `DID_CHANGE_RENEWAL_STATUS` (auto-renew off) and
        # `DID_CHANGE_RENEWAL_PREF` (a plan change) both do — so a household that turns off
        # auto-renew *during* a retry reads `false` while Apple is still retrying.
        #
        # **Left as-is rather than made exact, and the direction is why.** The error is always
        # under-reporting: this can say "not retrying" when it is, and can never say "retrying"
        # when it is not. A missed offer to fix a card costs a household nothing — entitlement
        # is untouched either way, and phase 112 renders nothing for this field — whereas a
        # false alarm tells a healthy subscriber their payment is failing. Being exact needs
        # `renewalInfo.gracePeriodExpiresDate`, which `VerifiedNotification` does not parse;
        # that is the `grace_until` variant, and it is a phase rather than a line.
        billing_retry=(
            notification_type == BILLING_RETRY_NOTIFICATION and subtype == BILLING_RETRY_SUBTYPE
        ),
    )
