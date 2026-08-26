"""Applying a verified App Store notification to a household.

**This is the only code path in this service that writes `entitlements.tier`**, per D5, and a
test in `tests/test_app_store.py` asserts that it stays the only one. `docs/runbook-deploy.md`
§7a remains the manual override, run by hand against production; there is no admin route and
this phase does not add one.

Everything in this module runs *after* `services/app_store.verify_notification` has verified a
signature. There is no other entry point: the router hands this function a
`VerifiedNotification`, which cannot be constructed from an unverified payload.

## Five guards, and the table of notification types matters less than any of them

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

**3. Sandbox may never write a Production entitlement.** Anyone with a sandbox tester account
can produce real, correctly-signed Sandbox notifications. In production those are recorded and
touch nothing. Gated on the same `ENVIRONMENT` setting that compiles out `dev-login`.

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
"""

from __future__ import annotations

import logging
import uuid

from sqlalchemy.ext.asyncio import AsyncSession

from rascal.constants import (
    DEMOTING_NOTIFICATIONS,
    PROMOTING_NOTIFICATIONS,
    Tier,
)
from rascal.models import AppStoreTransaction, Entitlement, Family, User
from rascal.services.app_store import VerifiedNotification
from rascal.services.guardians import active_parent_count, family_members

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


def may_write_tier(payload_environment: str, service_environment: str) -> bool:
    """Whether a notification from *payload_environment* may write in *service_environment*.

    Production only ever honours Production. A sandbox tester account is free to create, so
    treating its notifications as real would let anybody subscribe a production household by
    buying nothing. Locally both are honoured, because a local database is the place you
    exercise this and a Sandbox notification is the only kind that will ever exist there.
    """
    if service_environment == "prod":
        return payload_environment == "Production"
    return True


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

    # --- Guard 3: sandbox may never write a Production entitlement ---------------------------
    sandbox_blocked = not may_write_tier(note.environment, service_environment)
    if effect is not None and sandbox_blocked:
        log.warning(
            "sandbox notification recorded without touching tier",
            extra={
                "type": note.notification_type,
                "environment": note.environment,
                "family_id": str(family_id) if family_id else None,
            },
        )
        effect = None

    # --- Guard 4: never demote a family with no transaction record --------------------------
    #
    # Evaluated against `existing` — the row as it was *before* this notification — because
    # the row this notification is about to write is not evidence of anything.
    linked = existing is not None and family_id is not None and existing.family_id == family_id
    demotion_refused = False
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
        and await active_parent_count(session, family_id) == 0
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

    # **Two cases record the notification without recording who it is about**, and both are
    # the same argument: an attribution this service has just declined to act on must not
    # become the transaction record that lets a *later* notification act. A refused demotion
    # would otherwise be a one-notification delay rather than a guard, and a Sandbox
    # notification in production — which anyone with a free tester account can cause — would
    # get to nominate which production household a transaction belongs to.
    await _record(
        session,
        note,
        existing=existing,
        family_id=None if (demotion_refused or sandbox_blocked) else family_id,
    )

    if effect is None or family_id is None:
        await session.flush()
        return _outcome(effect, family_id, demotion_refused, promotion_refused)

    await _write_tier(session, family_id, effect, note)
    await session.flush()
    return f"tier:{effect}"


def _outcome(
    effect: Tier | None,
    family_id: uuid.UUID | None,
    demotion_refused: bool,
    promotion_refused: bool,
) -> str:
    if demotion_refused:
        return "recorded:demotion-refused"
    # Before the `family_id is None` branch, like the demotion above it: a refused promotion is
    # attributed — we know exactly which household it was for — and calling it `unattributed`
    # would lose the one fact that makes it findable.
    if promotion_refused:
        return "recorded:promotion-refused"
    if family_id is None:
        return "recorded:unattributed"
    return "recorded:no-tier-change"


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
    note: VerifiedNotification,
) -> None:
    """The one place `entitlements.tier` is assigned. `updated_at` is the trigger's."""
    entitlement = await session.get(Entitlement, family_id)
    if entitlement is None:  # pragma: no cover — create_household writes both rows together
        entitlement = Entitlement(family_id=family_id)
        session.add(entitlement)

    entitlement.tier = effect
    if effect == "subscribed":
        entitlement.lapsed_at = None
        if note.notification_type == "SUBSCRIBED":
            await _set_payer(session, entitlement, family_id)
    else:
        # `signedDate` rather than "now": when Apple decided is what D3's clocks run from, and
        # a late-delivered notification would otherwise date the lapse to when we heard.
        entitlement.lapsed_at = note.signed_date

    log.info(
        "entitlement written from an app store notification",
        extra={
            "family_id": str(family_id),
            "tier": effect,
            "type": note.notification_type,
            "environment": note.environment,
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
