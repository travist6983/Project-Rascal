"""The receipt ledger: *why* a household is entitled to what `entitlements` says it is.

`entitlements` holds one row per family and answers "what may this household do". This table
answers "what did Apple tell us, and when", and it is the substrate three separate guards in
`services/app_store_events.py` stand on:

* **Idempotency.** Apple retries until it gets a 2xx, so the same notification arrives more
  than once as a matter of course. `original_transaction_id` is the natural key, so a repeat
  updates a row rather than accumulating one.
* **Ordering.** `latest_signed_date` is the high-water mark. Retries interleave with new
  notifications, so an `EXPIRED` can arrive *after* the `RESUBSCRIBE` that superseded it, and
  the obvious implementation sets a paying household free. Nothing older than the stored
  value is allowed to write.
* **Provenance.** A demotion is refused for a family with no row here linking it to that
  transaction. `docs/runbook-deploy.md` §7a wrote the owner's own household `subscribed` by
  hand and there is no Apple transaction behind it — a webhook that may demote what it cannot
  account for locks the owner out of his own product on the first stray notification.

**`original_transaction_id` is the primary key rather than a surrogate.** It is Apple's stable
identifier for one subscription across every renewal, upgrade and resubscribe, so it is
already the thing this table is one-row-per. A surrogate id beside it would permit two rows
about one subscription, which is the state every guard above exists to make unrepresentable.

**The decoded payload is stored, not the JWS.** A stored JWS is a secret-shaped blob nobody
will ever verify a second time; a stored decode is something a human can read during an
incident, which is the only time anybody opens this table.

**No `deleted_at`, and that is not an exception to the standing rule.** The rule governs user
data that syncs to a phone. This is a billing audit trail: no client ever reads it, there is
nothing to sync a tombstone to, and a receipt is not a thing a parent deletes.
"""

from __future__ import annotations

import uuid

from sqlalchemy import ForeignKey, Index, Text
from sqlalchemy.dialects.postgresql import JSONB
from sqlalchemy.orm import Mapped, mapped_column

from rascal.constants import APP_STORE_ENVIRONMENTS, AppStoreEnvironment
from rascal.models.base import Base, created, moment, one_of, optional_moment, updated


class AppStoreTransaction(Base):
    """One subscription, as Apple last described it."""

    __tablename__ = "app_store_transactions"
    __table_args__ = (
        one_of("environment", APP_STORE_ENVIRONMENTS, name="environment"),
        Index("ix_app_store_transactions_family_id", "family_id"),
        # Reads that ask "what has Sandbox been telling us" and "what is the newest thing
        # Production said" are both incident questions, and both want this order.
        Index(
            "ix_app_store_transactions_environment_latest_signed_date",
            "environment",
            "latest_signed_date",
        ),
    )

    original_transaction_id: Mapped[str] = mapped_column(Text, primary_key=True)

    # **Nullable, deliberately.** `appAccountToken` is the only channel by which Apple can
    # carry a family id, and a purchase made without one is an orphan receipt. Recording it
    # unattributed is strictly better than refusing it: the row is the evidence a support
    # conversation needs, and a 4xx would make Apple retry it forever. See
    # `docs/api-contract.md`, Monetization — the client obligation is named there.
    family_id: Mapped[uuid.UUID | None] = mapped_column(
        ForeignKey("families.id", ondelete="SET NULL"), nullable=True
    )

    product_id: Mapped[str | None] = mapped_column(Text, nullable=True)
    environment: Mapped[AppStoreEnvironment] = mapped_column(Text)
    latest_notification_type: Mapped[str] = mapped_column(Text)
    latest_notification_subtype: Mapped[str | None] = mapped_column(Text, nullable=True)

    #: Apple's `signedDate` off the **outer** payload. The ordering key; see the module
    #: docstring. Not `created_at` — one is when Apple decided, the other is when we heard,
    #: and conflating them is what makes out-of-order delivery invisible.
    latest_signed_date: Mapped[moment]

    expires_date: Mapped[optional_moment]
    raw_payload: Mapped[dict] = mapped_column(JSONB)
    created_at: Mapped[created]
    updated_at: Mapped[updated]
