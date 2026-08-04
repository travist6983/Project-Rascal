"""The migration is the schema contract with docs/data-model.md.

These tests build a throwaway database, run ``alembic upgrade head``, assert every table,
index, constraint, and trigger exists *by name*, then run ``downgrade base`` and assert
nothing is left behind. Names matter: a migration that cannot find a constraint later
cannot alter it.
"""

from __future__ import annotations

import os
import subprocess
from collections.abc import Iterator

import pytest
import sqlalchemy as sa

from conftest import API_DIR

EXPECTED_TABLES = {
    "users",
    "credentials",
    "refresh_tokens",
    "idempotency_keys",
    "children",
    "guardians",
    "prompts",
    "assignments",
    "entries",
    "media",
    "tags",
    "entry_tags",
}

EXPECTED_INDEXES = {
    # The scheduler's idempotency guarantee.
    "uq_assignments_child_id_assigned_on_slot",
    "ix_assignments_child_id_status_assigned_on",
    # Apple is one credential row among several providers.
    "uq_credentials_provider_subject_id",
    "ix_refresh_tokens_token_hash",
    # The timeline, and On This Day.
    "ix_entries_child_id_occurred_at",
    "ix_entries_child_month_day",
    "ix_media_entry_id",
    "ix_entry_tags_tag_id",
    "uq_tags_child_id_name",
    # The scheduler's candidate pool, and the seed loader's idempotency key.
    "ix_prompts_kind_cadence_active_age",
    "ix_prompts_content_hash",
}

EXPECTED_CHECKS = {
    "ck_credentials_provider",
    "ck_guardians_role",
    "ck_prompts_kind",
    "ck_prompts_cadence",
    "ck_prompts_completion_mode",
    "ck_prompts_source",
    "ck_assignments_slot",
    "ck_assignments_status",
    "ck_assignments_prompt_or_custom_body",
    "ck_entries_entry_type",
    "ck_media_kind",
    "ck_media_upload_status",
    "ck_entry_tags_source",
}

TABLES_WITH_UPDATED_AT_TRIGGER = {
    "users",
    "children",
    "prompts",
    "assignments",
    "entries",
    "media",
    "tags",
    "entry_tags",
}


@pytest.fixture(scope="module")
def scratch_url() -> Iterator[str]:
    """A database of its own, so upgrade/downgrade never touches the suite's database."""
    url = sa.engine.make_url(os.environ["DATABASE_URL"])
    name = f"{url.database}_migrations"
    admin = sa.create_engine(
        url.set(database="postgres").render_as_string(hide_password=False),
        isolation_level="AUTOCOMMIT",
    )
    with admin.connect() as conn:
        conn.execute(sa.text(f'DROP DATABASE IF EXISTS "{name}"'))
        conn.execute(sa.text(f'CREATE DATABASE "{name}"'))
    scratch = url.set(database=name).render_as_string(hide_password=False)
    yield scratch
    with admin.connect() as conn:
        conn.execute(
            sa.text(
                "SELECT pg_terminate_backend(pid) FROM pg_stat_activity "
                "WHERE datname = :name AND pid <> pg_backend_pid()"
            ),
            {"name": name},
        )
        conn.execute(sa.text(f'DROP DATABASE IF EXISTS "{name}"'))
    admin.dispose()


def _alembic(command: str, url: str) -> None:
    result = subprocess.run(
        ["alembic", *command.split()],
        cwd=API_DIR,
        env={**os.environ, "DATABASE_URL": url},
        capture_output=True,
        text=True,
    )
    assert result.returncode == 0, f"alembic {command} failed:\n{result.stderr}"


def _names(conn: sa.Connection, query: str) -> set[str]:
    return {row[0] for row in conn.execute(sa.text(query))}


def test_upgrade_creates_every_named_object_then_downgrade_leaves_nothing(
    scratch_url: str,
) -> None:
    _alembic("upgrade head", scratch_url)

    engine = sa.create_engine(scratch_url)
    with engine.connect() as conn:
        tables = _names(conn, "SELECT tablename FROM pg_tables WHERE schemaname = 'public'")
        assert EXPECTED_TABLES <= tables

        indexes = _names(conn, "SELECT indexname FROM pg_indexes WHERE schemaname = 'public'")
        missing = EXPECTED_INDEXES - indexes
        assert not missing, f"missing indexes: {sorted(missing)}"

        checks = _names(
            conn,
            "SELECT conname FROM pg_constraint WHERE contype = 'c' "
            "AND connamespace = 'public'::regnamespace",
        )
        missing = EXPECTED_CHECKS - checks
        assert not missing, f"missing CHECK constraints: {sorted(missing)}"

        # Constrained columns are text + CHECK, never Postgres enums.
        enums = _names(
            conn,
            "SELECT typname FROM pg_type WHERE typtype = 'e' "
            "AND typnamespace = 'public'::regnamespace",
        )
        assert enums == set(), f"Postgres enums are forbidden, found: {sorted(enums)}"

        functions = _names(
            conn,
            "SELECT proname FROM pg_proc WHERE pronamespace = 'public'::regnamespace",
        )
        assert "set_updated_at" in functions

        triggers = _names(
            conn,
            "SELECT tgname FROM pg_trigger WHERE NOT tgisinternal",
        )
        expected_triggers = {f"trg_{t}_set_updated_at" for t in TABLES_WITH_UPDATED_AT_TRIGGER}
        missing = expected_triggers - triggers
        assert not missing, f"missing updated_at triggers: {sorted(missing)}"
    engine.dispose()

    _alembic("downgrade base", scratch_url)

    with engine.connect() as conn:
        tables = _names(conn, "SELECT tablename FROM pg_tables WHERE schemaname = 'public'")
        # alembic_version survives a downgrade to base by design; nothing else may.
        assert tables - {"alembic_version"} == set()
        functions = _names(
            conn,
            "SELECT proname FROM pg_proc WHERE pronamespace = 'public'::regnamespace",
        )
        assert "set_updated_at" not in functions
    engine.dispose()


def test_every_timestamp_column_is_timezone_aware(scratch_url: str) -> None:
    """A naive timestamp in an archive spanning eighteen years is a bug that surfaces late."""
    _alembic("upgrade head", scratch_url)
    engine = sa.create_engine(scratch_url)
    with engine.connect() as conn:
        naive = list(
            conn.execute(
                sa.text(
                    "SELECT table_name, column_name FROM information_schema.columns "
                    "WHERE table_schema = 'public' "
                    "AND data_type = 'timestamp without time zone'"
                )
            )
        )
    engine.dispose()
    assert naive == [], f"naive timestamp columns: {naive}"
