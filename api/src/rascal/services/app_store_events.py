"""Applying a verified App Store notification to a household.

**This is the only code path in this service that writes `entitlements.tier`**, per D5, and a
test in `tests/test_app_store.py` asserts that it stays the only one. `docs/runbook-deploy.md`
§7a remains the manual override, run by hand against production; there is no admin route and
this phase does not add one.

Everything in this module runs *after* `services/app_store.verify_notification` has verified a
signature. ~~There is no other entry point: the router hands this function a
`VerifiedNotification`, which cannot be constructed from an unverified payload.~~ — **there are
two entry points since phase 140 (Sep 3, 2026), and the sentence's real claim still holds.**
`apply_notification` takes a `VerifiedNotification` from `POST /webhooks/app-store`;
`apply_submitted_transaction` takes a `VerifiedTransaction` from `POST /families/me/transactions`,
the JWS the app itself holds for a purchase, verified by the same verifier against the same roots.
Neither type can be constructed from an unverified payload, `_write_tier` is still the one
assignment to `tier`, and a submitted transaction may only ever *promote* — the notification
stream stays the sole authority on a membership ending. Why the second door exists: a purchase
StoreKit reports as a success is not always one Apple announces as `SUBSCRIBED` (a plan change on
an Apple ID already holding the group is `DID_CHANGE_RENEWAL_PREF`, no tier effect), and a
`SUBSCRIBED` that was lost or discarded left the app with no way to tell the server about a
receipt it could see with its own eyes — "Restore a purchase" only re-read the server.

## Six guards, and the table of notification types matters less than any of them

**1. Ordering.** Apple retries until it gets a 2xx, and retries arrive interleaved with new
notifications. An `EXPIRED` delivered *after* a `RESUBSCRIBE` will, in the obvious
implementation, set a paying household free. Nothing whose `signedDate` is older than or equal
to the stored `latest_signed_date` for its `originalTransactionId` may write anything — which
also makes redelivery of the same notification a no-op, so idempotency falls out of the same
comparison rather than needing its own mechanism.

**2. One `originalTransactionId` belongs to one environment.** A payload disagreeing with the
row already recorded for that transaction is refused outright rather than recorded, because the
transaction id is the primary key and there is no second row to put it in. Recording it would
let a Sandbox payload advance `latest_signed_date` on a Production subscription, after which
guard 1 makes every legitimate Production notification look stale and the household's tier
freezes wherever it happened to be, with nothing in any log to say why.

**3. Production wins, and Sandbox only ever promotes.** ~~Sandbox may never write a Production
entitlement.~~ — **reversed Sep 2, 2026 by phase 139, because App Review buys in Sandbox.** Apple's
reviewers purchase through the same sandbox TestFlight uses, against this production server, and
under the old rule the reviewer's household stayed `free` while the paywall waited for a
confirmation that could never arrive — rejected under guideline 2.1(b), with the Sandbox
`SUBSCRIBED` sitting in `app_store_transactions` with `family_id = NULL` the whole time. A rule
that keeps the app out of the App Store is not a security property. What replaces it is two
narrower rules, both gated on the same `ENVIRONMENT` setting that compiles out `dev-login`:

* **A Sandbox notification writes `tier` and attribution only for a household with no Production
  row in the ledger.** Once a household has paid for real, nothing Sandbox says about it is
  acted on — recorded, unattributed, touching nothing — so a sandbox tester cannot promote,
  demote, or resurrect a paying household, and the deletion clock a Production `EXPIRED` started
  cannot be reset by buying nothing.
* **A Sandbox notification never demotes.** Sandbox subscriptions expire on an accelerated clock
  and nobody acts on the `EXPIRED`; letting it write `free` would demote the owner's own
  hand-written household (§7a, no rows) the day after any TestFlight purchase test, which is the
  exact failure guard 4 was written against. The accepted cost is the direction the contract
  already fails in: an owner-invited tester can hold a free membership until somebody reconciles
  it by hand.

The old docstring said *"a sandbox tester account is free to create"*. Overstated: the verifier
pins `bundleId`, so a Sandbox payload for this app can only come from a build StoreKit will sell
this app's products to — Xcode, TestFlight, App Review — and sandbox Apple Accounts are minted in
App Store Connect by this team, not by the public. But every TestFlight tester is in that
population, so the rules above do not rest on the population being small.

**4. Never demote a family with no transaction record.** `runbook-deploy.md` §7a wrote the
owner's own household `subscribed` by hand and there is no App Store transaction behind it,
nor will there ever be. A reconciliation that noticed a subscribed family with no receipt and
set it free would lock the owner out of his own product. So a demotion is refused unless this
service already holds a row linking that family to that `originalTransactionId`.

**And a refused demotion does not create the link it was refused for.** The row is still
recorded — the audit trail is the point — but with a null `family_id`, because attaching the
family would mean the *next* demoting notification found the record this one was refused for
and went through. Recording the attribution we just declined to make is how this guard would
quietly become a one-notification delay instead of a guard.

**5. Never promote a household nobody is left in.** Account deletion hard-deletes `users` and
deliberately leaves `families` standing, so an erased household is a real row with no members —
and Apple keeps sending renewals for a subscription nobody cancelled, because cancelling is
something only the subscriber can do and they are gone. Without this guard a `DID_RENEW`
arriving after an erasure walks straight into `_write_tier`, marks the empty household
`subscribed`, and clears `lapsed_at` — which is not cosmetic, because `lapsed_at` is the clock
D3's media-deletion policy runs off, so a renewal for somebody who no longer exists silently
restarts the abandonment timer on what is left of their household. The notification is still
recorded, unattributed, for the same reason a refused demotion is: a refund may follow it and
the audit trail is the point.

Symmetrical with guard 4 by construction: that one refuses a demotion it cannot justify, this
one refuses a promotion there is nobody to give. Added by phase 127 alongside Sign in with Apple
revocation, because both are the same question — what does this service still owe a person who
has left — asked from two directions.

**And a receipt whose household has nobody left in it follows the caller** — phase 143, Sep 3,
2026, on the owner's instruction (*"Please fix this"*). The household guard 5 describes is also
one a receipt can be stuck in: its only member erased their account, Apple goes on charging them,
and the JWS on their phone goes on naming the household they left. Production answered that
person `409` three times on Sep 3 — *"This purchase belongs to a different household"* — and put
the paywall back in front of somebody Apple was charging. The `409` protects a household from a
stranger's replay; a household with nobody in it has nothing to protect, and the person holding
the Apple-signed receipt on their device is the one Apple is charging. So the submission
proceeds under the caller when the token names a household that *exists* and is *empty*, moving
the ledger row with it, and `apply_notification` thereafter follows the ledger past that token
rather than routing Apple's later word about the subscription into the ghost.
`services/guardians.household_is_empty` is the one definition of *empty*, counted in `users` —
a member with no children yet is still a member. Every other refusal stands.

**6. A sibling receipt keeps a household subscribed.** D4 makes the subscription unit the
household and lets *any* guardian subscribe to restore a lapsed one, so a two-guardian family can
legitimately hold two Production subscriptions at once: the payer's card fails, the other parent
subscribes, and then the payer's card recovers (`DID_RENEW` / `BILLING_RECOVERY`). From that day the
ledger holds two rows for one family, both renewing, and an `EXPIRED` on *either* one — honoured
by the obvious implementation, because the row is linked and Production — sets the household
`free` while Apple is still charging the other parent. So a demotion guards 3 and 4 have both let
through is **held** when another row for the same family, in the same environment, whose own latest
word is not a demotion, carries an `expires_date` still ahead of the clock — or is in Apple's
billing grace period, where the row's date is the failed renewal's and already past while the
household is fully entitled. Held rather than refused: the row is recorded *with* its attribution,
unlike guard 4's refusal, because this row is linked and the notification is genuinely Apple's last
word about this subscription — dropping the link would make the sibling's own `EXPIRED`, when it
comes, look like guard 4's stranger. `lapsed_at` is untouched, so D3's clock does not start while a
parent is paying; when the last paying receipt expires nothing holds that one, and the household
lapses then, dated to that `signedDate`. Same environment, because Production and Sandbox are
already two worlds (guards 2 and 3) and a tester's renewing Sandbox subscription must never hold a
Production demotion. Added by phase 145 on Sep 5, 2026 from a read-only trace of this module against
the production ledger; no household was affected, because no Production transaction had yet reached
the server — all three rows in the ledger were Sandbox.
"""

from __future__ import annotations

import datetime as dt
import logging
import uuid

from sqlalchemy import exists, select
from sqlalchemy.ext.asyncio import AsyncSession

from rascal.constants import (
    BILLING_RETRY_NOTIFICATION,
    BILLING_RETRY_SUBTYPE,
    DEMOTING_NOTIFICATIONS,
    PROMOTING_NOTIFICATIONS,
    Tier,
)
from rascal.models import AppStoreTransaction, Entitlement, Family, User
from rascal.services.app_store import VerifiedNotification, VerifiedTransaction
from rascal.services.guardians import family_members, household_is_empty

log = logging.getLogger("rascal.app_store.events")


def tier_effect(notification_type: str, subtype: str | None) -> Tier | None:
    """What this notification does to `tier`: `subscribed`, `free`, or `None` for no change.

    The full table is in `docs/api-contract.md`. The two entries that are easy to get
    backwards, and expensive:

    * **`DID_CHANGE_RENEWAL_STATUS` never changes the tier.** Turning auto-renew off is not
      lapsing — the household is paid up until `expires_date`, and demoting here bills them
      for time they do not get.
    * **`DID_FAIL_TO_RENEW` depends entirely on its subtype.** With `GRACE_PERIOD` Apple is
      still retrying the card and the household keeps everything; with no subtype the billing
      has actually failed. `GRACE_PERIOD_EXPIRED` is the separate notification that arrives
      when the retrying stops, and that one demotes.
    * **`REFUND_REVERSED` promotes here, and `apply_notification` then reads the date.** Apple
      reversed a refund it had granted, reinstating what the `REFUND` revoked — access until
      `expiresDate`. This table says `subscribed` so that it stays a table; the writer downgrades a
      reversal whose `expiresDate` is missing or already past to no change, because a period that
      has ended has nothing left to reinstate. `REFUND_DECLINED` stays a no-change: a refund that
      was refused revoked nothing. Closed the gap the Aug 20, 2026 decisions-log line recorded,
      by phase 145 on Sep 5, 2026.
    """
    if notification_type in PROMOTING_NOTIFICATIONS:
        return "subscribed"
    if notification_type in DEMOTING_NOTIFICATIONS:
        return "free"
    if notification_type == "DID_FAIL_TO_RENEW":
        return None if subtype == "GRACE_PERIOD" else "free"
    # `DID_CHANGE_RENEWAL_STATUS` (auto-renew on/off), `DID_CHANGE_RENEWAL_PREF`
    # (monthly <-> annual, a plan change rather than two subscriptions under D5a's single
    # group), and every type this service does not know: recorded, acknowledged, no change.
    return None


def is_sandbox_in_production(payload_environment: str, service_environment: str) -> bool:
    """The one comparison, other than `Settings.is_local`, that branches on the environment.

    Locally everything is honoured, because a local database is the place you exercise this
    and a Sandbox notification is the only kind that will ever exist there. The two rules
    below both read this and nothing else reads `service_environment`, so the one exception
    `Settings.is_local`'s docstring names stays at one site.
    """
    return service_environment == "prod" and payload_environment == "Sandbox"


def may_write_tier(
    payload_environment: str,
    service_environment: str,
    *,
    family_has_production_row: bool,
) -> bool:
    """Whether a notification from *payload_environment* may write in *service_environment*.

    Production honours Production unconditionally, and honours Sandbox **only for a household
    Production has never spoken about** — App Review and TestFlight both buy in Sandbox against
    this server, so refusing Sandbox outright is a rejection under guideline 2.1(b), which is
    what happened on Sep 2, 2026.

    Pure, so the whole table is one parametrized test. Whether a Sandbox notification may
    *demote* is `may_demote_tier`, and the answer there is never.
    """
    if not is_sandbox_in_production(payload_environment, service_environment):
        return True
    return not family_has_production_row


def may_demote_tier(payload_environment: str, service_environment: str) -> bool:
    """Whether a notification from *payload_environment* may write `free` in *service_environment*.

    Sandbox subscriptions expire on an accelerated clock and nobody acts on the `EXPIRED`, so
    a Sandbox demotion in production is never evidence that a household stopped paying — and
    honouring one would demote the owner's own hand-written household (§7a, no rows) the day
    after any TestFlight purchase test, which is exactly the failure guard 4 exists to refuse.
    """
    return not is_sandbox_in_production(payload_environment, service_environment)


async def apply_notification(
    session: AsyncSession,
    note: VerifiedNotification,
    *,
    service_environment: str,
) -> str:
    """Record one verified notification and apply it. Returns what was done, for the log.

    **Every return is a `202`.** Apple retries anything that is not a 2xx, so "we recorded it
    and deliberately did nothing" has to be a success — a 4xx here is a promise to handle
    something later, and for a real notification it is an entitlement that silently never
    lands.
    """
    if not note.original_transaction_id:
        # Nothing to key the ledger on, so there is no row to write and no subscription to
        # act on. Summary notifications (a renewal-date extension applied in bulk) are the
        # real case. Acknowledged, because Apple would otherwise tell us forever.
        log.warning(
            "app store notification with no originalTransactionId",
            extra={"type": note.notification_type},
        )
        return "ignored:no-transaction-id"

    existing = await session.get(AppStoreTransaction, note.original_transaction_id)

    # --- Guard 1: ordering ------------------------------------------------------------------
    #
    # `<=` rather than `<` so a redelivery of the same notification is caught here too. This
    # is the single most likely defect in this phase and it fails silently in production
    # while every unit test passes, which is why the comparison is the first thing that
    # happens after the lookup and before anything is written.
    if existing is not None and note.signed_date <= existing.latest_signed_date:
        log.warning(
            "app store notification ignored as out of order",
            extra={
                "type": note.notification_type,
                "original_transaction_id": note.original_transaction_id,
                "signed_date": note.signed_date.isoformat(),
                "stored_signed_date": existing.latest_signed_date.isoformat(),
            },
        )
        return "ignored:out-of-order"

    # **Attribution falls back to the ledger, and that is not a weakening of guard 4.**
    # `appAccountToken` is attached at purchase time, and the notification that matters most —
    # the `EXPIRED` a year or two later — is the one furthest from it. Requiring the token on
    # every payload would mean a household that stops paying keeps `subscribed` forever, which
    # is the failure that costs money rather than the one that annoys somebody. The row we
    # fall back to *is* the transaction record guard 4 asks for, so this is the same evidence,
    # not weaker evidence — and a family with no row (the owner's, per §7a) has nothing to
    # fall back to.
    token_family_id = await _resolve_family(session, note)
    family_id = token_family_id or (existing.family_id if existing is not None else None)

    if (
        token_family_id is not None
        and existing is not None
        and existing.family_id is not None
        and existing.family_id != token_family_id
    ):
        if await household_is_empty(session, token_family_id):
            # **The token is stale, not wrong.** Apple stamps every notification with the token
            # the subscription was bought under, and a receipt that followed its holder into a
            # new household (`apply_submitted_transaction`, phase 143) goes on naming the one
            # they erased. The ledger row is where the receipt lives now. Routed by the token,
            # a `DID_RENEW` would reach the ghost and be refused by guard 5 while the live
            # household got nothing, and an `EXPIRED` would demote nobody while the live
            # household kept `subscribed` on a cancelled card — so the ledger outranks a token
            # that names a household with no one in it, and only such a token.
            log.warning(
                "app store notification follows the ledger past an empty household",
                extra={
                    "original_transaction_id": note.original_transaction_id,
                    "token_family_id": str(token_family_id),
                    "family_id": str(existing.family_id),
                },
            )
            family_id = existing.family_id
        else:
            # Apple does have an API for changing a subscription's `appAccountToken`, so this is
            # reachable rather than impossible — but nothing in this service calls it, so seeing
            # it means something changed that nobody here decided. The old household keeps
            # whatever tier it had; sorting that out is a support conversation, not a guess.
            log.warning(
                "app store transaction reattributed to a different family",
                extra={
                    "original_transaction_id": note.original_transaction_id,
                    "from_family_id": str(existing.family_id),
                    "to_family_id": str(token_family_id),
                },
            )

    effect = tier_effect(note.notification_type, note.subtype)

    # --- Guard 2: one transaction, one environment -------------------------------------------
    #
    # **One `originalTransactionId` belongs to one environment**, and a payload from the other
    # one does not get to touch its row — not the tier, not the attribution, and above all not
    # `latest_signed_date`. That last one is why this refuses the write outright rather than
    # recording it: the ordering guard reads that column as a high-water mark, so a Sandbox
    # payload advancing it would make every subsequent *legitimate* Production notification
    # look stale, freezing the household's tier wherever it happened to be with nothing in any
    # log to say why. There is no second row to put it in — the transaction id is the primary
    # key — so the choice is refuse or corrupt.
    if existing is not None and existing.environment != note.environment:
        log.warning(
            "app store notification refused: it claims a transaction recorded in the other "
            "environment",
            extra={
                "original_transaction_id": note.original_transaction_id,
                "recorded_environment": existing.environment,
                "payload_environment": note.environment,
                "type": note.notification_type,
            },
        )
        return "ignored:environment-mismatch"

    # --- Guard 3: Production wins, and Sandbox only ever promotes ---------------------------
    #
    # The ledger query runs only for a Sandbox payload in production that resolved to a
    # household, so the path every real subscriber takes issues no extra read. `EXISTS` on
    # `ix_app_store_transactions_family_id`.
    sandbox_blocked = False
    if family_id is not None and is_sandbox_in_production(note.environment, service_environment):
        sandbox_blocked = not may_write_tier(
            note.environment,
            service_environment,
            family_has_production_row=await _has_production_transaction(session, family_id),
        )
    if sandbox_blocked:
        log.warning(
            "sandbox notification recorded without touching a household production has "
            "spoken about",
            extra={
                "type": note.notification_type,
                "environment": note.environment,
                "family_id": str(family_id),
            },
        )
        effect = None

    # **And Sandbox never demotes.** Where Production has spoken the block above already took
    # the effect, so this reaches only a household Sandbox itself promoted, or §7a's. The row
    # is still recorded — the sandbox `EXPIRED` is the audit trail of a subscription that ended
    # — but through guard 4's refused-demotion path, so it neither writes `free` nor attributes
    # itself. An orphan receipt is left to the `family_id is None` exit below, where it was
    # already going.
    demotion_refused = False
    if (
        effect == "free"
        and family_id is not None
        and not may_demote_tier(note.environment, service_environment)
    ):
        log.warning(
            "sandbox notification may not demote a production household",
            extra={
                "type": note.notification_type,
                "original_transaction_id": note.original_transaction_id,
                "family_id": str(family_id),
            },
        )
        effect = None
        demotion_refused = True

    # --- Guard 4: never demote a family with no transaction record --------------------------
    #
    # Evaluated against `existing` — the row as it was *before* this notification — because
    # the row this notification is about to write is not evidence of anything.
    linked = existing is not None and family_id is not None and existing.family_id == family_id
    if effect == "free" and family_id is not None and not linked:
        log.warning(
            "refusing to demote a family with no transaction record",
            extra={
                "type": note.notification_type,
                "original_transaction_id": note.original_transaction_id,
                "family_id": str(family_id),
            },
        )
        effect = None
        demotion_refused = True

    # --- Guard 5: never promote a household nobody is left in --------------------------------
    #
    # An erased household is a `families` row with no `users`: account deletion hard-deletes the
    # members and leaves the household standing. Apple goes on renewing a subscription nobody is
    # there to cancel, and `_write_tier` would mark that empty household `subscribed` and clear
    # `lapsed_at` — restarting D3's media-deletion clock on behalf of somebody who asked to be
    # forgotten. Counted rather than inferred from the transaction row, because the question is
    # about the household now and not about what Apple once knew.
    promotion_refused = False
    if (
        effect == "subscribed"
        and family_id is not None
        and await household_is_empty(session, family_id)
    ):
        log.warning(
            "refusing to promote a household with no members left",
            extra={
                "type": note.notification_type,
                "original_transaction_id": note.original_transaction_id,
                "family_id": str(family_id),
            },
        )
        effect = None
        promotion_refused = True

    # **A refund reversal reinstates a period, so it needs a period to reinstate.** The table
    # promotes on `REFUND_REVERSED` because Apple has undone the `REFUND` that demoted this
    # household — but what that refund revoked was access *until `expiresDate`*, and Apple's
    # dispute process can outlast a monthly period. A reversal arriving after that date would
    # otherwise write `subscribed` and clear `lapsed_at` on a household whose subscription has
    # ended with nothing renewing it. So the payload's own `expiresDate` decides, against the same
    # clock `apply_submitted_transaction` holds a receipt to: ahead of it, the promotion goes
    # through; missing or behind it, the reversal is recorded and the tier stays where the
    # `REFUND` — or a later `EXPIRED` — put it. Checked after guard 5 so it fires only for a
    # promotion that was otherwise about to be written, and the log line means exactly that.
    nothing_to_reinstate = False
    if (
        effect == "subscribed"
        and family_id is not None
        and note.notification_type == "REFUND_REVERSED"
        and (note.expires_date is None or note.expires_date <= dt.datetime.now(dt.UTC))
    ):
        log.warning(
            "refund reversal recorded without reinstating: the period it would restore has ended",
            extra={
                "original_transaction_id": note.original_transaction_id,
                "family_id": str(family_id),
                "expires_date": (
                    note.expires_date.isoformat() if note.expires_date is not None else None
                ),
            },
        )
        effect = None
        nothing_to_reinstate = True

    # --- Guard 6: a sibling receipt keeps a household subscribed ----------------------------
    #
    # Reached only by a demotion guards 3 and 4 have both let through: a Production `EXPIRED`
    # (or `REFUND`, `REVOKE`, `GRACE_PERIOD_EXPIRED`, a failed `DID_FAIL_TO_RENEW`) on a row this
    # service already links to this household. D4 lets any guardian subscribe to restore a lapsed
    # household, so after the payer's card recovers a two-guardian family holds two renewing
    # Production rows — and this notification is Apple's word about *one* of them. Before writing
    # `free`, ask whether the other is still paid up: same family, same environment, a different
    # transaction, its own latest word not a demotion, and either an `expires_date` still ahead of
    # the clock **or a card in Apple's billing grace period** — `DID_FAIL_TO_RENEW` / `GRACE_PERIOD`
    # carries the *failed* renewal's date, which is already past, and that household is fully
    # entitled while Apple retries (`membership.py` says the same about `expires_at`), so a row in
    # retry pays without a future date. Compared to now rather than to this payload's `signedDate`
    # because the question is whether somebody is paying *today*, which is the comparison
    # `apply_submitted_transaction` already makes about a receipt. Held, not refused: the row is
    # recorded with its attribution
    # intact, because it is a linked row and this is Apple's newest word about it — dropping the
    # link here would make the sibling's own `EXPIRED`, when it comes, look like guard 4's
    # stranger. `lapsed_at` is untouched, so D3's clock does not start while a parent is paying.
    sibling_active = False
    if effect == "free" and family_id is not None:
        sibling = await _active_sibling(session, note, family_id=family_id)
        if sibling is not None:
            log.warning(
                "demotion held: a sibling subscription still pays for this household",
                extra={
                    "type": note.notification_type,
                    "original_transaction_id": note.original_transaction_id,
                    "sibling_original_transaction_id": sibling,
                    "family_id": str(family_id),
                },
            )
            effect = None
            sibling_active = True

    # **Two cases record the notification without recording who it is about**, and both are
    # the same argument: an attribution this service has just declined to act on must not
    # become the transaction record that lets a *later* notification act. A refused demotion
    # would otherwise be a one-notification delay rather than a guard, and a Sandbox
    # notification about a household Production has spoken about would otherwise become the
    # row `membership_signals` reads a plan from.
    await _record(
        session,
        note,
        existing=existing,
        family_id=None if (demotion_refused or sandbox_blocked) else family_id,
    )

    if effect is None or family_id is None:
        await session.flush()
        return _outcome(
            effect,
            family_id,
            demotion_refused,
            promotion_refused,
            sandbox_blocked,
            sibling_active=sibling_active,
            nothing_to_reinstate=nothing_to_reinstate,
        )

    await _write_tier(
        session,
        family_id,
        effect,
        signed_date=note.signed_date,
        source=note.notification_type,
        environment=note.environment,
        set_payer=note.notification_type == "SUBSCRIBED",
    )
    await session.flush()
    return f"tier:{effect}"


class TransactionBelongsElsewhere(Exception):
    """The submitted transaction's `appAccountToken` is not the caller's household.

    Raised rather than returned as a status because it is the one outcome the caller must not
    be allowed to mistake for success: nothing was recorded and nothing will be, and the
    router turns it into a `409` the client can show. Every other refusal here is a `200` with
    a status string, the way the webhook answers `202`, because for those the household is
    right and the answer is simply "not yet" or "not this".
    """


#: The ledger's `latest_notification_type` for a row a submission created — a value Apple
#: never sends, so a reader of the table can tell a client-reported purchase from a
#: notification at a glance. `membership_signals` reads only the `plan` off such a row.
SUBMITTED = "SUBMITTED"

#: The only `type` claim this door acts on. A consumable or a non-renewing product carries no
#: `expiresDate`, and "active until further notice" is not a claim this service will make
#: about anything Apple did not call a subscription.
_AUTO_RENEWABLE = "Auto-Renewable Subscription"


async def apply_submitted_transaction(
    session: AsyncSession,
    txn: VerifiedTransaction,
    *,
    family_id: uuid.UUID,
    service_environment: str,
) -> str:
    """Record a transaction the app submitted and, if it proves an active subscription, promote.

    **What this is allowed to do, and what it is not.** It may write `tier = subscribed` and
    attribute a ledger row to the caller's household. It never writes `free`, never touches
    `latest_signed_date` on a row a notification has already written, and never records a
    transaction it declined to act on — so the notification stream is still the only thing that
    can end a membership, and a submission can never make a later `EXPIRED` look stale
    (guard 1 reads that column as a high-water mark, and a client can obtain a freshly signed
    JWS at any time).

    `family_id` is the caller's, from the bearer token, and the transaction's own
    `appAccountToken` must name it: the token was attached at purchase by this app and is inside
    Apple's signature, so this checks Apple's statement of who bought it against who is asking,
    rather than taking either party's word. Two exceptions, phases 143 and 145, both below.

    **And it cannot resurrect a lapse it predates.** A JWS is Apple's statement that the
    subscription was active *as of its `signedDate`*; a `REFUND` signed an hour later is a newer
    statement, and the phone may still hold the older one. So a submission signed at or before
    the household's `lapsed_at`, or at or before a demoting notification that is the ledger's
    latest word on that transaction, is refused — guard 1's ordering rule, read against the two
    places a lapse is recorded rather than against the row's high-water mark alone, because a
    neutral notification (a renewal-preference change) can land after the refund and become the
    row's latest without un-lapsing anything.

    **One exception to the token rule, since phase 143 (Sep 3, 2026): a receipt whose household
    has nobody left in it follows the caller.** Account deletion hard-deletes `users` and
    `guardians` and leaves `families` and `entitlements` standing, so the household a receipt
    was bought in can outlive its only member — still reading `tier=subscribed`, with no one to
    read it. Apple goes on charging the person, the phone goes on holding a JWS whose token names
    the erased household, and on Sep 3, 2026 production answered that person `409` three times
    and put the paywall back in front of them. The `409` protects a household from a stranger's
    replay; a household with nobody in it has nothing to protect, and the person holding the
    Apple-signed receipt on their device is the one Apple is charging. So when the token names a
    household that *exists* and is *empty*, the submission proceeds under the caller's household
    and the ledger row moves with it — logged as a warning, because a moved receipt is the fact a
    support conversation would need. Every other refusal stands exactly as it was: a household
    that still has a member, a household this server has no row for, and a ledger row a *third*
    household holds. A receipt with no token at all is the other exception, phase 145's, next.

    **A receipt with no `appAccountToken` follows the caller when nobody holds it — phase 145,
    Sep 5, 2026, owner-authorised.** App Store Connect has Streamlined Purchasing on, and an offer
    code redeemed in the App Store app has the same shape: a subscription bought with this app not
    running is one this app never attached a token to, and Apple will never carry one for it. The
    webhook records such a receipt unattributed, correctly — a notification has no caller — and
    until this phase this door refused it with `409`, so the person Apple was charging could never
    be attributed even from their own signed-in device. The bearer token already proves a member of
    the household; the JWS is Apple's signature over an active subscription; and the only party who
    can present a token-less receipt *first* is the device it was delivered to. A stranger who
    obtained the bytes could claim an unclaimed orphan before its owner did — the same exposure as
    sharing a sign-in — and that is accepted in exchange for a paying customer not being locked
    out. So a token-less receipt is accepted, and attributed to the caller's household, only when
    the ledger has no row for it or a row with `family_id` NULL (an orphan the webhook recorded
    first). **A row already attributed to another household stays `409`, empty or not** — phase
    143's move is not extended here: a stale token names its ghost, which is how that move knows
    where the receipt came from; a missing token names nobody, and there is nothing to follow. A
    row attributed to the caller's own household is the caller's, and re-submitting it is the
    ordinary restore. Every other rule on this door applies unchanged, and the attribution is
    logged at warning. Once attributed, `apply_notification` follows the ledger for every later
    token-less notification about the subscription (`family_id = token_family_id or
    existing.family_id`), so Apple's renewals and the eventual `EXPIRED` reach the same household.

    **The ghost's entitlement is not touched.** It may go on reading `subscribed` with nobody in
    it: writing `free` there would be this door demoting, which it may not do, and there is no
    one in that household to be helped by the correction. What does change is where Apple's later
    word about the subscription lands — `apply_notification` follows the ledger past a token that
    names an empty household, so a `DID_RENEW` or an `EXPIRED` reaches the household that holds
    the receipt now rather than the one that used to.
    """
    # **A missing token is not a refusal any more; it is a question for the ledger** (phase 145).
    # The receipt names nobody, so whether the caller may have it turns on whether anybody else
    # already does — decided below, once the row is loaded, by the same check that refuses a row
    # another household holds. `untagged` is carried to that point and to the log.
    untagged = txn.app_account_token is None

    # `moved_from` is the household the receipt is leaving, or `None` for the ordinary case where
    # Apple's token and the bearer token agree. Set only when the token's household exists and
    # nobody is left in it — `household_is_empty` does not check existence, and "no such
    # household" is a receipt this server knows nothing about, not a degenerate empty one. A
    # token-less receipt never sets it: there is no household to have left.
    moved_from: uuid.UUID | None = None
    if not untagged and txn.app_account_token != family_id:
        token_family = await session.get(Family, txn.app_account_token)
        if token_family is None or not await household_is_empty(session, token_family.id):
            log.warning(
                "submitted transaction refused: appAccountToken is not the caller's household",
                extra={
                    "original_transaction_id": txn.original_transaction_id,
                    "family_id": str(family_id),
                    "app_account_token": str(txn.app_account_token),
                },
            )
            raise TransactionBelongsElsewhere
        moved_from = token_family.id

    if not txn.original_transaction_id:
        return "ignored:no-transaction-id"
    if txn.transaction_type != _AUTO_RENEWABLE:
        log.warning(
            "submitted transaction ignored: not an auto-renewable subscription",
            extra={
                "original_transaction_id": txn.original_transaction_id,
                "type": txn.transaction_type,
            },
        )
        return "ignored:not-a-subscription"

    existing = await session.get(AppStoreTransaction, txn.original_transaction_id)

    # Guard 2, unchanged in meaning: one transaction id, one environment.
    if existing is not None and existing.environment != txn.environment:
        log.warning(
            "submitted transaction refused: it claims a transaction recorded in the other "
            "environment",
            extra={
                "original_transaction_id": txn.original_transaction_id,
                "recorded_environment": existing.environment,
                "payload_environment": txn.environment,
            },
        )
        return "ignored:environment-mismatch"

    # The ledger already attributes this subscription to a different household. Apple's
    # signature says the caller, the ledger says somebody else, and a client cannot resolve
    # that: `apply_notification` logs the same disagreement and proceeds on Apple's word
    # because a notification is Apple speaking; here it is the caller speaking with Apple's
    # signature in hand, and the conservative answer is to touch nothing. **The one row that
    # may move is the one held by the empty household the token itself names** — the ledger and
    # Apple agree about where the receipt was, and that place has nobody in it. A row a *third*
    # household holds is a disagreement nobody here can settle, empty token household or not.
    # **For a token-less receipt this is the whole decision**: `moved_from` is `None`, so a row
    # any other household holds — empty or not — is refused here, and a row nobody holds, or no
    # row, goes on to be attributed to the caller.
    if (
        existing is not None
        and existing.family_id is not None
        and existing.family_id != family_id
        and existing.family_id != moved_from
    ):
        log.warning(
            "submitted transaction refused: the ledger attributes it to a different family",
            extra={
                "original_transaction_id": txn.original_transaction_id,
                "recorded_family_id": str(existing.family_id),
                "family_id": str(family_id),
            },
        )
        raise TransactionBelongsElsewhere

    # **Active means an `expiresDate` in the future and no `revocationDate`.** A subscription
    # transaction with no expiry at all is not "active until further notice" — Apple always
    # sends one, and `apply_notification` never invents an entitlement from a claim a payload
    # omitted. A lapsed or refunded transaction is Apple's to report, through the door that may
    # demote; recording it here would be a client writing its own `lapsed_at`.
    active = (
        txn.revocation_date is None
        and txn.expires_date is not None
        and txn.expires_date > dt.datetime.now(dt.UTC)
    )
    if not active:
        return "ignored:not-active"

    # **A receipt from before the lapse.** Both places a demotion is recorded are consulted:
    # the household's `lapsed_at` (written by every demotion, cleared by every promotion) and,
    # for this transaction's row, a demoting notification that is the row's latest word.
    entitlement = await session.get(Entitlement, family_id)
    lapsed_at = entitlement.lapsed_at if entitlement is not None else None
    if moved_from is not None:
        # **A moving receipt's lapse was recorded against the household it is leaving.** The
        # caller's household has never heard of this subscription, so its own `lapsed_at` says
        # nothing about it — and a `REFUND` followed by a neutral notification leaves the row's
        # latest word neutral, so the row-level check below would not catch a pre-refund JWS
        # either. Read both households and take the later; found in review before this shipped.
        departed = await session.get(Entitlement, moved_from)
        if departed is not None and departed.lapsed_at is not None:
            lapsed_at = (
                departed.lapsed_at if lapsed_at is None else max(lapsed_at, departed.lapsed_at)
            )
    if lapsed_at is not None and txn.signed_date <= lapsed_at:
        log.warning(
            "submitted transaction ignored: signed before the household's lapse",
            extra={
                "original_transaction_id": txn.original_transaction_id,
                "family_id": str(family_id),
                "signed_date": txn.signed_date.isoformat(),
                "lapsed_at": lapsed_at.isoformat(),
            },
        )
        return "ignored:out-of-order"
    if (
        existing is not None
        and tier_effect(existing.latest_notification_type, existing.latest_notification_subtype)
        == "free"
        and txn.signed_date <= existing.latest_signed_date
    ):
        log.warning(
            "submitted transaction ignored: a demoting notification for it is newer",
            extra={
                "original_transaction_id": txn.original_transaction_id,
                "family_id": str(family_id),
                "signed_date": txn.signed_date.isoformat(),
                "stored_signed_date": existing.latest_signed_date.isoformat(),
                "stored_type": existing.latest_notification_type,
            },
        )
        return "ignored:out-of-order"

    # Guard 3, the same rule: Production wins, and Sandbox only ever promotes.
    if is_sandbox_in_production(txn.environment, service_environment) and not may_write_tier(
        txn.environment,
        service_environment,
        family_has_production_row=await _has_production_transaction(session, family_id),
    ):
        log.warning(
            "sandbox transaction submitted for a household production has spoken about",
            extra={
                "original_transaction_id": txn.original_transaction_id,
                "family_id": str(family_id),
            },
        )
        return "ignored:sandbox-blocked"

    # Guard 5 does not apply: the caller is a member of this household by construction, so
    # `household_is_empty` is false, and asserting it would be asserting the bearer token.
    # Guard 4 does not apply either: this door cannot demote.

    if moved_from is not None:
        # Logged here rather than where the decision was made, so a refusal further up (not
        # active, out of order, sandbox-blocked) never leaves a log line claiming a move that
        # did not happen. A warning rather than info: a receipt changing households is the one
        # fact a support conversation about either household will need.
        log.warning(
            "submitted transaction reattributed from empty household",
            extra={
                "original_transaction_id": txn.original_transaction_id,
                "from_family_id": str(moved_from),
                "to_family_id": str(family_id),
            },
        )
    if untagged and (existing is None or existing.family_id is None):
        # Same placement, same reason: only an attribution that is about to be written is logged.
        # A warning because this is the one write on this door that rests on the bearer token
        # alone — Apple's signature proves the subscription, not whose household it is.
        log.warning(
            "submitted transaction attributed to the caller: the receipt carries no "
            "appAccountToken",
            extra={
                "original_transaction_id": txn.original_transaction_id,
                "family_id": str(family_id),
            },
        )
    await _record_submission(session, txn, existing=existing, family_id=family_id)
    await _write_tier(
        session,
        family_id,
        "subscribed",
        signed_date=txn.signed_date,
        source=SUBMITTED,
        environment=txn.environment,
        set_payer=True,
    )
    await session.flush()
    return "tier:subscribed"


async def _record_submission(
    session: AsyncSession,
    txn: VerifiedTransaction,
    *,
    existing: AppStoreTransaction | None,
    family_id: uuid.UUID,
) -> None:
    """The ledger's side of a submission: a row where there was none, attribution where it was
    missing — or, since phase 143, where it named a household with nobody left in it — and
    **nothing else**.

    A row a notification wrote keeps its `latest_signed_date`, its type and its payload. The
    date is guard 1's high-water mark and a submission's `signedDate` is whenever StoreKit last
    fetched the JWS — advancing it would let a restore tapped today outrank an `EXPIRED` Apple
    signed an hour ago and has not delivered yet. A new row's date *is* the submission's,
    which is safe by the same reasoning inverted: an active transaction signed at *S* is
    Apple's statement that nothing had ended it by *S*.
    """
    if existing is None:
        session.add(
            AppStoreTransaction(
                original_transaction_id=txn.original_transaction_id,
                family_id=family_id,
                product_id=txn.product_id,
                environment=txn.environment,
                latest_notification_type=SUBMITTED,
                latest_notification_subtype=None,
                latest_signed_date=txn.signed_date,
                expires_date=txn.expires_date,
                raw_payload=txn.raw,
            )
        )
        return
    # Either null, or the empty household the caller's receipt is leaving: the guard in
    # `apply_submitted_transaction` has already refused every other disagreement.
    if existing.family_id != family_id:
        existing.family_id = family_id


def _outcome(
    effect: Tier | None,
    family_id: uuid.UUID | None,
    demotion_refused: bool,
    promotion_refused: bool,
    sandbox_blocked: bool,
    *,
    sibling_active: bool,
    nothing_to_reinstate: bool,
) -> str:
    if demotion_refused:
        return "recorded:demotion-refused"
    # Named rather than folded into `no-tier-change`, because `blocked.md` §25 is two evenings
    # spent discovering that a correctly-refused Sandbox write is invisible everywhere.
    if sandbox_blocked:
        return "recorded:sandbox-blocked"
    # Before the `family_id is None` branch, like the demotion above it: a refused promotion is
    # attributed — we know exactly which household it was for — and calling it `unattributed`
    # would lose the one fact that makes it findable.
    if promotion_refused:
        return "recorded:promotion-refused"
    # Both of phase 145's are attributed by construction, and both are named for the same reason
    # `sandbox-blocked` is: a held demotion is the one outcome here where "tier unchanged" is
    # good news, and a reversal with nothing to reinstate is the one that reads like a lost
    # payment until the `expiresDate` is beside it in the log.
    if sibling_active:
        return "recorded:sibling-active"
    if nothing_to_reinstate:
        return "recorded:nothing-to-reinstate"
    if family_id is None:
        return "recorded:unattributed"
    return "recorded:no-tier-change"


async def _has_production_transaction(session: AsyncSession, family_id: uuid.UUID) -> bool:
    """Whether Production has ever spoken about this household — the thing that outranks Sandbox."""
    return bool(
        await session.scalar(
            select(
                exists().where(
                    AppStoreTransaction.family_id == family_id,
                    AppStoreTransaction.environment == "Production",
                )
            )
        )
    )


async def _active_sibling(
    session: AsyncSession, note: VerifiedNotification, *, family_id: uuid.UUID
) -> str | None:
    """The `original_transaction_id` of another receipt still paying for this household, or `None`.

    Another row for the same family in the same environment, not this transaction, whose own
    latest word is not a demotion — and which is paying today, which is one of two things: an
    `expires_date` still ahead of the clock, or a card in Apple's billing grace period. **The
    second is why the date is selected rather than filtered on in SQL.** A row whose latest word is
    `DID_FAIL_TO_RENEW` / `GRACE_PERIOD` carries the failed renewal's `expiresDate`, already past,
    and that household is fully entitled while Apple retries the card — `membership.py` nulls
    `expires_at` for the same row for the same reason. Filtering on the date would have dropped
    exactly the sibling whose parent is mid-retry and written the household `free` under them;
    found in review before this shipped.

    "Is a demotion" is `tier_effect` in Python rather than a restatement in SQL, so that what
    counts as a demotion has one definition; a household holds a handful of rows at most, and
    `ix_app_store_transactions_family_id` finds them. A row a submission created (`SUBMITTED`)
    counts, because it is Apple's signed statement that the subscription was active and
    `tier_effect` reads it as no change. Ordered so a redelivery's log line names the same sibling.
    """
    now = dt.datetime.now(dt.UTC)
    rows = (
        await session.execute(
            select(
                AppStoreTransaction.original_transaction_id,
                AppStoreTransaction.latest_notification_type,
                AppStoreTransaction.latest_notification_subtype,
                AppStoreTransaction.expires_date,
            )
            .where(
                AppStoreTransaction.family_id == family_id,
                AppStoreTransaction.environment == note.environment,
                AppStoreTransaction.original_transaction_id != note.original_transaction_id,
            )
            .order_by(AppStoreTransaction.original_transaction_id)
        )
    ).all()
    for original_transaction_id, latest_type, latest_subtype, expires_date in rows:
        if tier_effect(latest_type, latest_subtype) == "free":
            continue
        in_retry = (
            latest_type == BILLING_RETRY_NOTIFICATION and latest_subtype == BILLING_RETRY_SUBTYPE
        )
        if in_retry or (expires_date is not None and expires_date > now):
            return original_transaction_id
    return None


async def _resolve_family(session: AsyncSession, note: VerifiedNotification) -> uuid.UUID | None:
    """The family this transaction belongs to, or `None`.

    **`appAccountToken` is the only channel by which Apple can carry a family id**, so a
    purchase made without one is an orphan receipt that no server-side process can ever
    attribute. The client obligation is named in `docs/api-contract.md`; from here the only
    correct behaviour is to record it unattributed.

    **A family this server does not recognise is also `None`, and no family is created.**
    Inventing a household because a stranger's receipt named a UUID would be creating user
    data from an unauthenticated request.
    """
    if note.app_account_token is None:
        log.warning(
            "app store notification with no usable appAccountToken: orphan receipt",
            extra={"original_transaction_id": note.original_transaction_id},
        )
        return None
    family = await session.get(Family, note.app_account_token)
    if family is None:
        log.warning(
            "app store notification for an unknown family",
            extra={
                "original_transaction_id": note.original_transaction_id,
                "app_account_token": str(note.app_account_token),
            },
        )
        return None
    return family.id


async def _record(
    session: AsyncSession,
    note: VerifiedNotification,
    *,
    existing: AppStoreTransaction | None,
    family_id: uuid.UUID | None,
) -> None:
    """Upsert the ledger row. `updated_at` is the trigger's job and is never set here."""
    if existing is None:
        session.add(
            AppStoreTransaction(
                original_transaction_id=note.original_transaction_id,
                family_id=family_id,
                product_id=note.product_id,
                environment=note.environment,
                latest_notification_type=note.notification_type,
                latest_notification_subtype=note.subtype,
                latest_signed_date=note.signed_date,
                expires_date=note.expires_date,
                raw_payload=note.raw,
            )
        )
        return

    existing.product_id = note.product_id or existing.product_id
    existing.environment = note.environment
    existing.latest_notification_type = note.notification_type
    existing.latest_notification_subtype = note.subtype
    existing.latest_signed_date = note.signed_date
    # **Only when this notification actually carried one.** Not every type carries
    # `transactionInfo`, and phase 38 schedules against these dates — blanking a known expiry
    # because one payload was quiet about it is how a household gets treated as never having
    # had one.
    if note.expires_date is not None:
        existing.expires_date = note.expires_date
    existing.raw_payload = note.raw
    # An attribution is never *unset* by a later notification: a renewal that arrived without
    # an `appAccountToken` must not orphan a receipt this service had already attributed.
    if family_id is not None:
        existing.family_id = family_id


async def _write_tier(
    session: AsyncSession,
    family_id: uuid.UUID,
    effect: Tier,
    *,
    signed_date: dt.datetime,
    source: str,
    environment: str,
    set_payer: bool,
) -> None:
    """The one place `entitlements.tier` is assigned. `updated_at` is the trigger's.

    Takes the four facts it acts on rather than a `VerifiedNotification`, since phase 140,
    because a submitted transaction reaches it too — and the single `.tier =` below is what
    `test_tier_has_exactly_one_writer` counts, so a second writer for the second door would
    have failed that test rather than passed it, which is the test doing its job.
    """
    entitlement = await session.get(Entitlement, family_id)
    if entitlement is None:  # pragma: no cover — create_household writes both rows together
        entitlement = Entitlement(family_id=family_id)
        session.add(entitlement)

    entitlement.tier = effect
    if effect == "subscribed":
        entitlement.lapsed_at = None
        if set_payer:
            await _set_payer(session, entitlement, family_id)
    else:
        # `signedDate` rather than "now": when Apple decided is what D3's clocks run from, and
        # a late-delivered notification would otherwise date the lapse to when we heard.
        entitlement.lapsed_at = signed_date

    log.info(
        "entitlement written from an app store notification",
        extra={
            "family_id": str(family_id),
            "tier": effect,
            "type": source,
            "environment": environment,
        },
    )


async def _set_payer(session: AsyncSession, entitlement: Entitlement, family_id: uuid.UUID) -> None:
    """Record who is paying — **only when the household leaves no room to guess.**

    `appAccountToken` carries a *family* id, per the client obligation in
    `docs/api-contract.md`, so a notification never names a user. With one guardian there is
    only one person it can be. With two there is no way to tell from anything Apple sends, and
    a wrong `payer_user_id` is worse than a null one: D3a's win-back writes to the payer, so
    guessing means emailing the wrong parent about the other one's cancelled card.
    """
    members: list[User] = await family_members(session, family_id)
    if len(members) == 1:
        entitlement.payer_user_id = members[0].id
        return
    log.warning(
        "payer_user_id left unset: the household has more than one guardian and Apple's "
        "notification names a family rather than a user",
        extra={"family_id": str(family_id), "guardians": len(members)},
    )
