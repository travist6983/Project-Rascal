"""The declarative base and the column helpers every table shares."""

from __future__ import annotations

import datetime as dt
import uuid
from typing import Annotated

from sqlalchemy import MetaData, func
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

# entries and media carry UUIDs minted on the phone so a record exists offline before the
# server ever sees it. Same column type; the only difference is who calls uuid4().
client_uuid_pk = Annotated[
    uuid.UUID,
    mapped_column(PGUUID(as_uuid=True), primary_key=True),
]

timestamp = Annotated[
    dt.datetime,
    mapped_column(server_default=func.now(), nullable=False),
]
