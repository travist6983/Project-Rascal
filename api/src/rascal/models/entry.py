"""Entries, their media, and their tags — the archive itself."""

from __future__ import annotations

import uuid

from sqlalchemy import BigInteger, ForeignKey, Index, Integer, Text, UniqueConstraint, text
from sqlalchemy.orm import Mapped, mapped_column, relationship

from rascal.constants import (
    ENTRY_TYPES,
    MEDIA_KINDS,
    TAG_SOURCES,
    UPLOAD_STATUSES,
    EntryType,
    MediaKind,
    TagSource,
    UploadStatus,
)
from rascal.models.base import (
    Base,
    client_uuid_pk,
    created,
    moment,
    one_of,
    optional_moment,
    updated,
    uuid_fk,
    uuid_pk,
)


class Entry(Base):
    """`occurred_at` is when it happened; `created_at` is when it was logged. Never conflate."""

    __tablename__ = "entries"
    __table_args__ = (
        one_of("entry_type", ENTRY_TYPES, name="entry_type"),
        # The timeline query. Sorted by occurred_at, because backdating puts a 2023 photo in
        # the middle of the order, not at the end.
        Index("ix_entries_child_id_occurred_at", "child_id", text("occurred_at DESC")),
        # ix_entries_child_month_day — the On This Day index — is functional and is created
        # as raw SQL in the migration. SQLAlchemy's Index() cannot express it the way
        # Postgres needs, so it deliberately does not appear here.
    )

    # Minted on the phone so the record exists offline before the server sees it.
    id: Mapped[client_uuid_pk]
    child_id: Mapped[uuid_fk] = mapped_column(ForeignKey("children.id", ondelete="CASCADE"))
    # Nullable: freeform entries are first-class. Not everything worth keeping came from a prompt.
    assignment_id: Mapped[uuid.UUID | None] = mapped_column(
        ForeignKey("assignments.id", ondelete="SET NULL"), nullable=True
    )
    author_id: Mapped[uuid_fk] = mapped_column(ForeignKey("users.id", ondelete="RESTRICT"))
    occurred_at: Mapped[moment]
    created_at: Mapped[created]
    # Computed at write from occurred_at minus birthdate, then stored. Correcting a birthdate
    # typo must not shift the whole archive.
    child_age_months: Mapped[int] = mapped_column(Integer)
    title: Mapped[str | None] = mapped_column(Text, nullable=True)
    body: Mapped[str | None] = mapped_column(Text, nullable=True)
    entry_type: Mapped[EntryType] = mapped_column(Text)
    # Sealed until the child is this age. Null on everything that isn't a letter to him.
    unlock_at_age: Mapped[int | None] = mapped_column(Integer, nullable=True)
    deleted_at: Mapped[optional_moment]
    updated_at: Mapped[updated]

    media: Mapped[list[Media]] = relationship(
        back_populates="entry", cascade="all, delete-orphan", lazy="raise"
    )
    entry_tags: Mapped[list[EntryTag]] = relationship(
        back_populates="entry", cascade="all, delete-orphan", lazy="raise"
    )


class Media(Base):
    """The server holds keys and metadata. Bytes go device → S3 and never through here."""

    __tablename__ = "media"
    __table_args__ = (
        one_of("kind", MEDIA_KINDS, name="kind"),
        one_of("upload_status", UPLOAD_STATUSES, name="upload_status"),
        Index("ix_media_entry_id", "entry_id"),
    )

    id: Mapped[client_uuid_pk]
    entry_id: Mapped[uuid_fk] = mapped_column(ForeignKey("entries.id", ondelete="CASCADE"))
    s3_key: Mapped[str] = mapped_column(Text)
    # Thumbnail and poster-frame generation is out of P0 scope; this stays null.
    thumb_key: Mapped[str | None] = mapped_column(Text, nullable=True)
    kind: Mapped[MediaKind] = mapped_column(Text)
    captured_at: Mapped[optional_moment]
    duration_seconds: Mapped[int | None] = mapped_column(Integer, nullable=True)
    bytes: Mapped[int] = mapped_column(BigInteger)
    # Written back from on-device transcription and captioning. The server never regenerates
    # these — they are durable data, not a cache.
    transcript: Mapped[str | None] = mapped_column(Text, nullable=True)
    caption: Mapped[str | None] = mapped_column(Text, nullable=True)
    upload_status: Mapped[UploadStatus] = mapped_column(Text, server_default="pending")
    # Not in docs/data-model.md: S3 hands back a multipart upload id at initiation and needs
    # it again to complete, and the client never sees it. See docs/decisions-log.md.
    s3_upload_id: Mapped[str | None] = mapped_column(Text, nullable=True)
    deleted_at: Mapped[optional_moment]
    created_at: Mapped[created]
    updated_at: Mapped[updated]

    entry: Mapped[Entry] = relationship(back_populates="media")


class Tag(Base):
    """Tags are per child, so two children never share a vocabulary by accident."""

    __tablename__ = "tags"
    __table_args__ = (UniqueConstraint("child_id", "name", name="uq_tags_child_id_name"),)

    id: Mapped[uuid_pk]
    child_id: Mapped[uuid_fk] = mapped_column(ForeignKey("children.id", ondelete="CASCADE"))
    name: Mapped[str] = mapped_column(Text)
    created_at: Mapped[created]
    updated_at: Mapped[updated]


class EntryTag(Base):
    """`source` keeps a tag you typed distinct from one the on-device model extracted.

    Re-running extraction has to be free, and it must never eat a tag a human chose.
    """

    __tablename__ = "entry_tags"
    __table_args__ = (
        one_of("source", TAG_SOURCES, name="source"),
        Index("ix_entry_tags_tag_id", "tag_id"),
    )

    entry_id: Mapped[uuid.UUID] = mapped_column(
        ForeignKey("entries.id", ondelete="CASCADE"), primary_key=True
    )
    tag_id: Mapped[uuid.UUID] = mapped_column(
        ForeignKey("tags.id", ondelete="CASCADE"), primary_key=True
    )
    source: Mapped[TagSource] = mapped_column(Text)
    # Untagging syncs as a row with deleted_at set. A client cannot infer a removal from
    # an absence.
    deleted_at: Mapped[optional_moment]
    created_at: Mapped[created]
    updated_at: Mapped[updated]

    entry: Mapped[Entry] = relationship(back_populates="entry_tags")
    tag: Mapped[Tag] = relationship(lazy="raise")


__all__ = ["Entry", "EntryTag", "Media", "Tag"]
