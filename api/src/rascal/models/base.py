"""The declarative base and the column types every table shares."""

from __future__ import annotations

import datetime as dt
import uuid
from typing import Annotated

from sqlalchemy import CheckConstraint, DateTime, MetaData, func
from sqlalchemy.dialects.postgresql import UUID as PGUUID
from sqlalchemy.orm import DeclarativeBase, mapped_column

# Explicit names for every constraint and index. Alembic autogenerate against unnamed
# constraints produces migrations that cannot be reversed cleanly.
NAMING_CONVENTION = {
    "ix": "ix_%(table_name)s_%(column_0_N_name)s",
    "uq": "uq_%(table_name)s_%(column_0_N_name)s",
    "ck": "ck_%(table_name)s_%(constraint_name)s",
    "fk": "fk_%(table_name)s_%(column_0_N_name)s",
    "pk": "pk_%(table_name)s",
}


class Base(DeclarativeBase):
    metadata = MetaData(naming_convention=NAMING_CONVENTION)


uuid_pk = Annotated[
    uuid.UUID,
    mapped_column(PGUUID(as_uuid=True), primary_key=True, default=uuid.uuid4),
]

# entries and media carry UUIDs minted on the phone, so a record exists offline before the
# server ever sees it. Same column type; the only difference is who calls uuid4().
client_uuid_pk = Annotated[
    uuid.UUID,
    mapped_column(PGUUID(as_uuid=True), primary_key=True),
]

uuid_fk = Annotated[uuid.UUID, mapped_column(PGUUID(as_uuid=True))]

# timestamptz everywhere. A naive timestamp in an archive spanning eighteen years and two
# timezones is a bug that only shows up years later.
created = Annotated[
    dt.datetime,
    mapped_column(DateTime(timezone=True), server_default=func.now(), nullable=False),
]

# Written by the set_updated_at() trigger, never by application code.
updated = Annotated[
    dt.datetime,
    mapped_column(
        DateTime(timezone=True),
        server_default=func.now(),
        nullable=False,
    ),
]

moment = Annotated[dt.datetime, mapped_column(DateTime(timezone=True))]
optional_moment = Annotated[
    dt.datetime | None, mapped_column(DateTime(timezone=True), nullable=True)
]


def one_of(column: str, values: tuple[str, ...], *, name: str) -> CheckConstraint:
    """A named CHECK restricting a text column to a fixed set."""
    rendered = ", ".join(f"'{value}'" for value in values)
    return CheckConstraint(f"{column} IN ({rendered})", name=name)


# Every table carrying an updated_at column, and therefore the set_updated_at() trigger.
#
# This is the *current* schema's list, and no migration reads it. Each migration attaches the
# triggers for the tables it creates, from a literal frozen at that revision — a migration
# that reads a live constant describes whatever the models look like today rather than the
# schema it was written for, and starts creating triggers for tables that do not exist yet.
TABLES_WITH_UPDATED_AT: tuple[str, ...] = (
    "users",
    # Phase 52. The odd one out in this list: `credentials` is auth infrastructure rather than
    # synced user data, and its siblings `refresh_tokens` and `idempotency_keys` still carry
    # neither `updated_at` nor a trigger. It earns one because a revocation is a change to a
    # row that is otherwise write-once, and a change nothing can observe is a change nobody
    # can act on.
    "credentials",
    "children",
    "prompts",
    "assignments",
    "entries",
    "media",
    "tags",
    "entry_tags",
    "devices",
    "prompt_suppressions",
    # Phase 36. The household and its entitlement.
    "families",
    "entitlements",
    "guardian_invites",
    # Phase 66.
    "deletion_requests",
    # Phase 69. Not user data — a broadcast has no recipient in this schema — but it carries
    # `updated_at` because a row is written before the send and updated after it.
    "email_broadcasts",
    # phase 96. An admin decision about the seeded library. Not user data and not synced;
    # it carries `updated_at` because an override is edited in place when the console
    # changes its mind, and the trigger is how every other table in this list gets one.
    "prompt_library_overrides",
    # Phase 97. Marketing output, following `email_broadcasts` rather than the user-data
    # tables: `updated_at` because a draft is edited in place, no `deleted_at` because
    # discarding one is a status rather than a disappearance.
    "social_assets",
)
