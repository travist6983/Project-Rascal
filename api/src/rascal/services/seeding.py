"""Loading the mission library from YAML into the `prompts` table.

Idempotent, keyed on a stable hash of `(kind, cadence, body)`. Re-running updates rows whose
content changed and inserts rows that are new. It never duplicates and it never deletes — a
prompt removed from the markdown stays in the table, because entries and assignments already
point at it. It is **deactivated** instead, which is the difference between a prompt the
scheduler will not serve again and a foreign key that no longer resolves.

The body is part of the key, so editing a body is not an update — it is a new prompt plus a
retired one. That is exactly what phase 24 did to all 113 seeded bodies at once, and why
retirement lives here rather than in a one-off migration: the next edit to the library needs
the same thing to happen, and a migration that names 113 hashes would only ever work once.

This module reads YAML and nothing else. `docs/mission-library.md` is an authoring surface
converted by `scripts/mission_library_to_yaml.py`; runtime never parses a markdown table.
"""

from __future__ import annotations

import hashlib
import logging
import re
from dataclasses import dataclass
from pathlib import Path
from typing import Any

import yaml
from sqlalchemy import func, or_, select, update
from sqlalchemy.dialects.postgresql import insert
from sqlalchemy.ext.asyncio import AsyncSession

from rascal.constants import (
    CADENCES,
    COMPLETION_MODES,
    PROMPT_KINDS,
    PROMPT_SOURCES,
    PROMPT_TOKENS,
)
from rascal.models import Prompt

log = logging.getLogger("rascal.seeding")

# `{...}` with no brace inside, which is what the renderers treat as a token. An unclosed `{`
# is deliberately not matched: the renderers pass it through as literal text rather than
# calling it a malformed token, and a validator that disagreed with them would reject bodies
# that render perfectly well.
TOKEN_PATTERN = re.compile(r"\{([^{}]*)\}")

SEEDS_PATH = Path(__file__).resolve().parents[3] / "seeds" / "prompts.yaml"

# Fields compared to decide whether a re-seed is a real update. content_hash is excluded
# because it is the key, and the timestamps are excluded because the trigger owns them.
MUTABLE_FIELDS = (
    "completion_mode",
    "theme",
    "min_age_months",
    "max_age_months",
    "month_tags",
    "source",
    "default_unlock_age",
    "active",
)


@dataclass(frozen=True)
class SeedResult:
    inserted: int
    updated: int
    unchanged: int
    retired: int = 0

    @property
    def total(self) -> int:
        return self.inserted + self.updated + self.unchanged


def content_hash(kind: str, cadence: str, body: str) -> str:
    """The loader's idempotency key.

    Unit separators rather than a plain join, so a body containing the delimiter cannot
    collide with a different (kind, cadence) pair.
    """
    payload = f"{kind}\x1f{cadence}\x1f{body}"
    return hashlib.sha256(payload.encode("utf-8")).hexdigest()


def _validate(prompt: dict[str, Any], index: int) -> None:
    """Fail on a bad seed file rather than letting a CHECK constraint fail mid-load."""
    for field, allowed in (
        ("kind", PROMPT_KINDS),
        ("cadence", CADENCES),
        ("completion_mode", COMPLETION_MODES),
        ("source", PROMPT_SOURCES),
    ):
        value = prompt.get(field)
        if value not in allowed:
            raise ValueError(f"prompts.yaml[{index}]: {field}={value!r} is not one of {allowed}")
    if not prompt.get("body"):
        raise ValueError(f"prompts.yaml[{index}]: body is required")
    for token in TOKEN_PATTERN.findall(prompt["body"]):
        if token not in PROMPT_TOKENS:
            raise ValueError(
                f"prompts.yaml[{index}]: {{{token}}} is not one of the prompt tokens in "
                f"docs/api-contract.md — every client would render it as literal braces"
            )
    low, high = prompt["min_age_months"], prompt["max_age_months"]
    if low > high:
        raise ValueError(f"prompts.yaml[{index}]: min_age_months {low} exceeds max {high}")
    for month in prompt.get("month_tags") or []:
        if not 1 <= month <= 12:
            raise ValueError(f"prompts.yaml[{index}]: month_tags contains {month}")


def load_seed_file(path: Path = SEEDS_PATH) -> list[dict[str, Any]]:
    """Parse and validate the YAML, returning rows ready to upsert."""
    raw = yaml.safe_load(path.read_text(encoding="utf-8")) or []
    rows: list[dict[str, Any]] = []
    for index, prompt in enumerate(raw):
        _validate(prompt, index)
        rows.append(
            {
                "kind": prompt["kind"],
                "cadence": prompt["cadence"],
                "completion_mode": prompt["completion_mode"],
                "body": prompt["body"],
                "theme": prompt["theme"],
                "min_age_months": prompt["min_age_months"],
                "max_age_months": prompt["max_age_months"],
                "month_tags": prompt.get("month_tags") or [],
                "source": prompt["source"],
                "default_unlock_age": prompt.get("default_unlock_age"),
                "active": prompt.get("active", True),
                "content_hash": content_hash(prompt["kind"], prompt["cadence"], prompt["body"]),
            }
        )

    seen: dict[str, str] = {}
    for row in rows:
        if row["content_hash"] in seen:
            raise ValueError(
                f"prompts.yaml contains two prompts with the same (kind, cadence, body): "
                f"{row['body']!r}"
            )
        seen[row["content_hash"]] = row["body"]
    return rows


async def seed_prompts(session: AsyncSession, path: Path = SEEDS_PATH) -> SeedResult:
    """Upsert every prompt in the seed file. Safe to run as often as you like."""
    rows = load_seed_file(path)
    if not rows:
        return SeedResult(inserted=0, updated=0, unchanged=0)

    before = await session.scalar(select(func.count()).select_from(Prompt)) or 0

    statement = insert(Prompt).values(rows)
    excluded = statement.excluded
    # DO UPDATE only where something actually differs, so a no-op re-seed leaves updated_at
    # alone and clients do not resync the whole library for nothing. IS DISTINCT FROM rather
    # than != because default_unlock_age is null on everything that is not a letter.
    differs = or_(
        *(
            getattr(Prompt, field).is_distinct_from(getattr(excluded, field))
            for field in MUTABLE_FIELDS
        )
    )
    upsert = statement.on_conflict_do_update(
        index_elements=[Prompt.content_hash],
        set_={field: getattr(excluded, field) for field in MUTABLE_FIELDS},
        where=differs,
    ).returning(Prompt.content_hash)

    touched = {row[0] for row in (await session.execute(upsert)).all()}

    # Anything seeded that the file no longer contains is retired, in the same transaction as
    # the upsert that replaced it. Two conditions carry the whole safety argument:
    #
    # `source == "seeded"` — a user's own prompt and an llm-generated one were never in this
    # file and must survive a re-seed untouched. Without this the first `make seed` after a
    # prompt is authored in the app silently deactivates it.
    #
    # `active.is_(True)` — so a no-op re-seed reports 0 retired rather than rewriting rows that
    # are already inactive, which would churn `updated_at` and resync the library for nothing.
    obsolete = (
        update(Prompt)
        .where(
            Prompt.source == "seeded",
            Prompt.active.is_(True),
            Prompt.content_hash.notin_({row["content_hash"] for row in rows}),
        )
        .values(active=False)
        .returning(Prompt.content_hash)
    )
    retired = len((await session.execute(obsolete)).all())

    await session.commit()

    after = await session.scalar(select(func.count()).select_from(Prompt)) or 0
    inserted = after - before
    updated = len(touched) - inserted
    result = SeedResult(
        inserted=inserted,
        updated=updated,
        unchanged=len(rows) - len(touched),
        retired=retired,
    )
    log.info(
        "seeded prompts",
        extra={
            "inserted": result.inserted,
            "updated": result.updated,
            "unchanged": result.unchanged,
            "retired": result.retired,
        },
    )
    return result
