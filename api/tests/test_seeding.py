"""The mission library: conversion, coverage, and an idempotent loader."""

from __future__ import annotations

import collections

import sqlalchemy as sa
import yaml
from sqlalchemy.ext.asyncio import AsyncSession

from rascal.models import Prompt
from rascal.services.seeding import SEEDS_PATH, content_hash, load_seed_file, seed_prompts

# docs/mission-library.md, "Coverage check for the POC": prompts eligible at 48 months.
# The doc's table was corrected on Aug 4 2026 to match these exactly — it had been written
# before the last handful of prompts were added. Asserted exactly, so drift in either
# direction fails here and names the new numbers.
ELIGIBLE_AT_48_MONTHS = {
    "question": 30,
    "photo": 22,
    "video": 11,
    "audio": 11,
    "activity": 16,
    "weekly": 10,
    "monthly": 4,
    "letter": 8,
}

TOTAL_PROMPTS = 113
# Every seeded prompt is served: video returned when multipart shipped, audio when the recorder
# did. `UNCOMPLETABLE_KINDS` is empty and stays in place for the next kind that needs it.
ACTIVE_PROMPTS = 113


def _buckets() -> dict[str, list[dict]]:
    """Group the seed file the way the coverage table does."""
    rows = yaml.safe_load(SEEDS_PATH.read_text(encoding="utf-8"))
    grouped: dict[str, list[dict]] = collections.defaultdict(list)
    for row in rows:
        if row["kind"] == "letter":
            grouped["letter"].append(row)
        elif row["cadence"] == "weekly":
            grouped["weekly"].append(row)
        elif row["cadence"] == "monthly":
            grouped["monthly"].append(row)
        else:
            grouped[row["kind"]].append(row)
    return grouped


def test_every_seeded_prompt_parses_and_validates() -> None:
    rows = load_seed_file()
    assert len(rows) == TOTAL_PROMPTS
    assert all(row["source"] == "seeded" for row in rows)

    # Nothing is held back any more — video returned when multipart shipped, audio when the
    # recorder did. The mechanism stays in place for the next kind that arrives before its
    # capture surface: a prompt no client can complete is a dead end rather than a mission.
    active = {row["kind"] for row in rows if row["active"]}
    inactive = {row["kind"] for row in rows if not row["active"]}
    assert inactive == set(), f"unexpected inactive kinds: {inactive}"
    assert {"video", "audio"} <= active, "the capture kinds are served again"
    assert sum(1 for row in rows if row["active"]) == ACTIVE_PROMPTS


def test_age_ranges_and_month_tags_follow_the_conversion_rules() -> None:
    rows = load_seed_file()
    # `all` -> 24..216.
    describe_his_laugh = next(row for row in rows if row["body"] == "Describe his laugh.")
    assert (describe_his_laugh["min_age_months"], describe_his_laugh["max_age_months"]) == (
        24,
        216,
    )

    # An explicit range is carried across verbatim.
    alphabet = next(row for row in rows if row["body"] == "Record him saying the alphabet.")
    assert (alphabet["min_age_months"], alphabet["max_age_months"]) == (30, 84)

    # A Months value becomes month_tags; everything else is any-month.
    snow = next(row for row in rows if row["body"] == "Photograph him in the first snow.")
    assert snow["month_tags"] == [12, 1, 2]
    assert describe_his_laugh["month_tags"] == []


def test_only_letters_are_sealed_and_they_carry_their_unlock_age() -> None:
    rows = load_seed_file()
    sealed = [row for row in rows if row["default_unlock_age"] is not None]
    assert {row["kind"] for row in sealed} == {"letter"}
    assert len(sealed) == 8
    birth_story = next(
        row for row in rows if row["body"].startswith("Write down the story of the day he was born")
    )
    assert birth_story["default_unlock_age"] == 13


def test_coverage_at_48_months_meets_the_documented_floor() -> None:
    """docs/mission-library.md asks: is there enough for 14 days at 48 months?"""
    for bucket, rows in _buckets().items():
        eligible = [row for row in rows if row["min_age_months"] <= 48 <= row["max_age_months"]]
        assert len(eligible) == ELIGIBLE_AT_48_MONTHS[bucket], bucket
        # Every bucket has to carry its own cadence: a slot that fires monthly needs at least
        # a few, a slot that fires daily needs a fortnight's worth.
        assert len(eligible) >= 4, bucket


def test_each_daily_slots_own_pool_covers_a_fortnight() -> None:
    """One pool per daily slot, which is three pools now and used to be two.

    This previously pooled photo, video, audio and activity together and asked whether *that*
    covered a fortnight. It did, and it would have gone on saying so long after the pool stopped
    existing: `mission` draws photo alone from migration 0008, and photo alone is the thin one.
    A slot is only as healthy as the kinds it can actually reach.
    """
    buckets = _buckets()

    def eligible(*kinds: str) -> int:
        return len(
            [
                row
                for kind in kinds
                for row in buckets[kind]
                if row["min_age_months"] <= 48 <= row["max_age_months"]
            ]
        )

    assert eligible("question") >= 14
    # `mission` is photo-only. This is the slot that reaches cooldown relaxation first, and the
    # number to watch: it clears the fortnight floor and not by much.
    assert eligible("photo") >= 14
    # `mission_b` pools its three kinds, which is why none of them needs 14 on its own — and
    # video and audio do not have 14 on their own.
    assert eligible("video", "audio", "activity") >= 14


def test_content_hash_distinguishes_kind_cadence_and_body() -> None:
    assert content_hash("photo", "daily", "x") != content_hash("video", "daily", "x")
    assert content_hash("photo", "daily", "x") != content_hash("photo", "weekly", "x")
    assert content_hash("photo", "daily", "x") == content_hash("photo", "daily", "x")


async def test_seeding_twice_produces_the_same_row_count(session: AsyncSession) -> None:
    first = await seed_prompts(session)
    assert first.inserted == TOTAL_PROMPTS
    assert first.updated == 0

    count_after_first = await session.scalar(sa.select(sa.func.count()).select_from(Prompt))

    second = await seed_prompts(session)
    assert second.inserted == 0
    assert second.updated == 0
    assert second.unchanged == TOTAL_PROMPTS

    count_after_second = await session.scalar(sa.select(sa.func.count()).select_from(Prompt))
    assert count_after_first == count_after_second == TOTAL_PROMPTS


async def test_seeded_prompts_match_the_per_kind_counts_in_the_yaml(
    session: AsyncSession,
) -> None:
    await seed_prompts(session)
    rows = yaml.safe_load(SEEDS_PATH.read_text(encoding="utf-8"))
    expected = collections.Counter(row["kind"] for row in rows)

    stored = await session.execute(sa.select(Prompt.kind, sa.func.count()).group_by(Prompt.kind))
    assert dict(stored.all()) == dict(expected)


async def test_reseeding_updates_a_changed_prompt_without_duplicating_it(
    session: AsyncSession, tmp_path
) -> None:
    """A changed theme or age band updates in place; the body is the identity."""
    await seed_prompts(session)
    rows = yaml.safe_load(SEEDS_PATH.read_text(encoding="utf-8"))
    rows[0]["theme"] = "seasons-holidays"
    rows[0]["max_age_months"] = 200
    edited = tmp_path / "prompts.yaml"
    edited.write_text(yaml.safe_dump(rows, allow_unicode=True), encoding="utf-8")

    result = await seed_prompts(session, edited)
    assert result.inserted == 0
    assert result.updated == 1
    assert result.unchanged == TOTAL_PROMPTS - 1

    changed = await session.scalar(
        sa.select(Prompt).where(
            Prompt.content_hash
            == content_hash(rows[0]["kind"], rows[0]["cadence"], rows[0]["body"])
        )
    )
    assert changed.theme == "seasons-holidays"
    assert changed.max_age_months == 200
    total = await session.scalar(sa.select(sa.func.count()).select_from(Prompt))
    assert total == TOTAL_PROMPTS


async def test_reseeding_never_deletes_a_prompt_dropped_from_the_file(
    session: AsyncSession, tmp_path
) -> None:
    """Entries and assignments point at prompts; removing the markdown row must not orphan them."""
    await seed_prompts(session)
    rows = yaml.safe_load(SEEDS_PATH.read_text(encoding="utf-8"))
    dropped = rows.pop()
    shorter = tmp_path / "prompts.yaml"
    shorter.write_text(yaml.safe_dump(rows, allow_unicode=True), encoding="utf-8")

    await seed_prompts(session, shorter)

    survivor = await session.scalar(
        sa.select(Prompt).where(
            Prompt.content_hash
            == content_hash(dropped["kind"], dropped["cadence"], dropped["body"])
        )
    )
    assert survivor is not None
    total = await session.scalar(sa.select(sa.func.count()).select_from(Prompt))
    assert total == TOTAL_PROMPTS


async def test_a_new_prompt_is_inserted_on_the_next_seed(session: AsyncSession, tmp_path) -> None:
    await seed_prompts(session)
    rows = yaml.safe_load(SEEDS_PATH.read_text(encoding="utf-8"))
    rows.append(
        {
            "kind": "activity",
            "cadence": "daily",
            "completion_mode": "did_it",
            "body": "Let him pick the music in the car, the whole way there.",
            "theme": "humor",
            "min_age_months": 36,
            "max_age_months": 216,
            "month_tags": [],
            "default_unlock_age": None,
            "source": "seeded",
            "active": True,
        }
    )
    longer = tmp_path / "prompts.yaml"
    longer.write_text(yaml.safe_dump(rows, allow_unicode=True), encoding="utf-8")

    result = await seed_prompts(session, longer)
    assert result.inserted == 1
    assert result.unchanged == TOTAL_PROMPTS
    total = await session.scalar(sa.select(sa.func.count()).select_from(Prompt))
    assert total == TOTAL_PROMPTS + 1


def test_the_committed_yaml_still_matches_the_markdown() -> None:
    """The markdown is the authoring surface; drift between the two is a silent content bug."""
    import importlib.util
    import sys

    from conftest import API_DIR

    spec = importlib.util.spec_from_file_location(
        "mission_library_to_yaml", API_DIR / "scripts" / "mission_library_to_yaml.py"
    )
    module = importlib.util.module_from_spec(spec)
    # @dataclass resolves annotations through sys.modules, so register before executing.
    sys.modules[spec.name] = module
    spec.loader.exec_module(module)

    regenerated = module.convert()
    committed = yaml.safe_load(SEEDS_PATH.read_text(encoding="utf-8"))
    assert regenerated == committed, (
        "docs/mission-library.md and seeds/prompts.yaml disagree — "
        "re-run scripts/mission_library_to_yaml.py and commit the result"
    )
