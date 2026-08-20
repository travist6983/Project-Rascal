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
    # Where a notification goes, and the record that it went.
    "devices",
    "notification_sends",
    "prompt_suppressions",
    # phase 96. Admin decisions about the seeded library that survive a re-seed.
    "prompt_library_overrides",
}

EXPECTED_INDEXES = {
    # The scheduler's idempotency guarantee, in two halves since phase 36: daily slots are
    # per-guardian and carry `user_id`, shared slots are one per child and must not — a
    # single wide index would let NULL `user_id` defeat uniqueness on the shared rows.
    "ix_guardians_child_id",
    "uq_assignments_daily",
    "uq_assignments_shared",
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
    # Full-text search. GIN, over the generated tsvector columns.
    "ix_entries_search_vector",
    "ix_media_search_vector",
    # A sandbox token and a production token are different tokens.
    "uq_devices_token_environment",
    "ix_devices_user_id",
    # One notification per user per day. This index is the guarantee.
    "uq_notification_sends_user_id_notification_date",
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
    "ck_devices_platform",
    "ck_devices_environment",
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
    "devices",
    "prompt_suppressions",
    "prompt_library_overrides",
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
        assert tables >= EXPECTED_TABLES

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


def test_the_mission_b_slot_round_trips_with_rows_in_the_table(scratch_url: str) -> None:
    """Upgrade, downgrade *with data present*, upgrade again.

    The downgrade is the half worth testing. Postgres will not create a CHECK that existing
    rows violate, so a `mission_b` row left in place would make `downgrade` fail outright and
    the migration irreversible in practice — which is the thing every migration in this chain
    promises not to be. 0003's letter-slot downgrade is the pattern, and this asserts it holds
    against a table that actually holds one. The test below does the same for 0003 itself.
    """
    _alembic("upgrade head", scratch_url)
    engine = sa.create_engine(scratch_url)

    with engine.begin() as conn:
        child_id = conn.execute(
            sa.text(
                "INSERT INTO children (id, name, birthdate, family_timezone) "
                "VALUES (gen_random_uuid(), 'Miles', DATE '2022-06-14', 'America/Detroit') "
                "RETURNING id"
            )
        ).scalar_one()
        # Since phase 36 a daily assignment names the guardian it was served to, so this
        # needs a household to hang one on. The slot is still the only thing under test.
        family_id = conn.execute(
            sa.text("INSERT INTO families (id) VALUES (gen_random_uuid()) RETURNING id")
        ).scalar_one()
        user_id = conn.execute(
            sa.text(
                "INSERT INTO users (id, family_id, display_name) "
                "VALUES (gen_random_uuid(), :family, 'Travis') RETURNING id"
            ),
            {"family": family_id},
        ).scalar_one()
        conn.execute(
            sa.text(
                "INSERT INTO guardians (user_id, child_id, role) VALUES (:user, :child, 'parent')"
            ),
            {"user": user_id, "child": child_id},
        )
        # A parent-authored one-off, so this needs no prompt row: the table's CHECK is
        # satisfied by `custom_body`, and the slot is the only thing under test.
        for slot in ("mission", "mission_b"):
            conn.execute(
                sa.text(
                    "INSERT INTO assignments "
                    "(id, child_id, user_id, custom_body, slot, assigned_on, expires_on, "
                    "status) VALUES "
                    "(gen_random_uuid(), :child, :user, 'x', :slot, CURRENT_DATE, "
                    "CURRENT_DATE + 14, 'pending')"
                ),
                {"child": child_id, "user": user_id, "slot": slot},
            )

    with engine.connect() as conn:
        assert _slot_check(conn).count("mission_b") == 1
        assert _slot_count(conn, "mission_b") == 1

    # The revision by name, not `-1`. A relative step meant "unwind 0008" only while 0008 was
    # head, so the first migration added after it silently retargeted this test at something
    # else — which is what 0009 did, and it failed here rather than quietly passing against a
    # downgrade that has nothing to do with slots.
    _alembic("downgrade 0007_prompt_suppressions", scratch_url)

    with engine.connect() as conn:
        # The rows went, and only the mission_b ones.
        assert _slot_count(conn, "mission_b") == 0
        assert _slot_count(conn, "mission") == 1
        assert "mission_b" not in _slot_check(conn)

    _alembic("upgrade head", scratch_url)

    with engine.connect() as conn:
        assert _slot_check(conn).count("mission_b") == 1
        # Re-widening does not resurrect what the downgrade deleted, and must not pretend to.
        assert _slot_count(conn, "mission_b") == 0
    engine.dispose()


def test_the_theme_rename_round_trips_and_reaches_rows_the_seeder_cannot(
    scratch_url: str,
) -> None:
    """0009 is a data migration, so the rows *are* the test.

    The row that matters is a retired one. A live seeded prompt gets its theme rewritten by
    `make seed` — `theme` is mutable and is not part of the content hash — so if this
    migration only ever ran against the active library it would be doing nothing at all. The
    99 prompts phase 24 retired are absent from `prompts.yaml` forever, and they are the
    reason there is a migration here rather than a re-seed. One of each is inserted below and
    both must move.
    """
    # `scratch_url` is module-scoped, so this database arrives at whatever revision the test
    # above left it at. Upgrading *to* an earlier revision is a silent no-op in alembic, not
    # an error, so reaching 0008 has to be a downgrade from a known head rather than an
    # `upgrade 0008` that does nothing and takes the assertions with it.
    _alembic("upgrade head", scratch_url)
    _alembic("downgrade 0008_mission_b_slot", scratch_url)
    engine = sa.create_engine(scratch_url)

    def _insert(conn: sa.Connection, body: str, active: bool) -> None:
        conn.execute(
            sa.text(
                "INSERT INTO prompts (id, kind, cadence, completion_mode, body, theme, "
                "min_age_months, max_age_months, month_tags, source, active, content_hash) "
                "VALUES (gen_random_uuid(), 'question', 'daily', 'text', :body, 'his-words', "
                "24, 216, '{}', 'seeded', :active, md5(:body))"
            ),
            {"body": body, "active": active},
        )

    def _themes(conn: sa.Connection) -> dict[str, str]:
        return dict(conn.execute(sa.text("SELECT body, theme FROM prompts ORDER BY body")).all())

    with engine.begin() as conn:
        _insert(conn, "retired literal body", active=False)
        _insert(conn, "live tokenised body", active=True)

    _alembic("upgrade head", scratch_url)

    with engine.connect() as conn:
        assert _themes(conn) == {
            "retired literal body": "their-words",
            "live tokenised body": "their-words",
        }

    _alembic("downgrade 0008_mission_b_slot", scratch_url)

    with engine.connect() as conn:
        # Lossless in both directions: a data migration that cannot be reversed is a schema
        # change wearing an UPDATE, and this chain does not have one of those.
        assert _themes(conn) == {
            "retired literal body": "his-words",
            "live tokenised body": "his-words",
        }

    # Put the database back where this test found it, rows included — the fixture is shared
    # with every test below.
    with engine.begin() as conn:
        conn.execute(sa.text("DELETE FROM prompts"))
    _alembic("upgrade head", scratch_url)
    engine.dispose()


def test_the_letter_slot_round_trips_with_rows_in_the_table(scratch_url: str) -> None:
    """The same round trip, for 0003 — the migration that established the pattern.

    0008 delete-then-narrows because 0003 did it first, but only 0008's downgrade had ever
    been run against a table holding a row it has to destroy. Reaching 0003 unwinds every
    revision above it with data in place, which makes this the deepest reversal the suite
    performs — and the one a `letter` assignment in a real database would have to survive.
    """
    _alembic("upgrade head", scratch_url)
    engine = sa.create_engine(scratch_url)

    with engine.begin() as conn:
        child_id = conn.execute(
            sa.text(
                "INSERT INTO children (id, name, birthdate, family_timezone) "
                "VALUES (gen_random_uuid(), 'Ada', DATE '2021-03-02', 'America/Detroit') "
                "RETURNING id"
            )
        ).scalar_one()
        # `weekly` is the control: it is a legal slot at every revision in the chain, so a
        # weekly row that disappears is the downgrade over-reaching rather than doing its job.
        # Like the test above, `custom_body` satisfies the prompt-or-body CHECK so no prompt
        # row is needed and the slot is the only thing under test.
        for slot in ("letter", "weekly"):
            conn.execute(
                sa.text(
                    "INSERT INTO assignments "
                    "(id, child_id, custom_body, slot, assigned_on, expires_on, status) VALUES "
                    "(gen_random_uuid(), :child, 'x', :slot, CURRENT_DATE, "
                    "CURRENT_DATE + 14, 'pending')"
                ),
                {"child": child_id, "slot": slot},
            )

    with engine.connect() as conn:
        assert _slot_check(conn).count("letter") == 1
        assert _slot_count(conn, "letter") == 1

    # Named rather than counted: `downgrade -N` means a different revision every time a
    # migration lands, and the revision 0003 has to land *before* never moves.
    _alembic("downgrade 0002_entry_type_artifact", scratch_url)

    with engine.connect() as conn:
        # The letter row went, and only it.
        assert _slot_count(conn, "letter") == 0
        assert _slot_count(conn, "weekly") == 1
        assert "letter" not in _slot_check(conn)

    _alembic("upgrade head", scratch_url)

    with engine.connect() as conn:
        assert _slot_check(conn).count("letter") == 1
        # Re-widening does not resurrect what the downgrade deleted, and must not pretend to.
        assert _slot_count(conn, "letter") == 0
        assert _slot_count(conn, "weekly") == 1
    engine.dispose()


def _slot_check(conn: sa.Connection) -> str:
    return conn.execute(
        sa.text(
            "SELECT pg_get_constraintdef(oid) FROM pg_constraint "
            "WHERE conname = 'ck_assignments_slot'"
        )
    ).scalar_one()


def _slot_count(conn: sa.Connection, slot: str) -> int:
    return conn.execute(
        sa.text("SELECT count(*) FROM assignments WHERE slot = :slot"), {"slot": slot}
    ).scalar_one()


def test_the_slot_check_constraint_admits_exactly_the_slots_the_code_knows(
    scratch_url: str,
) -> None:
    """The migration freezes slot names as a literal; `constants.SLOTS` is the live list.

    That duplication is deliberate — a migration must not read a constant that can change under
    it — which is exactly why it needs a test. A slot the code serves but the schema rejects is
    an IntegrityError in the scheduler; a slot the schema allows but the code never writes is
    dead permission.
    """
    from rascal.constants import SLOTS

    _alembic("upgrade head", scratch_url)
    engine = sa.create_engine(scratch_url)
    with engine.connect() as conn:
        definition = _slot_check(conn)
    engine.dispose()

    admitted = {value for value in SLOTS if f"'{value}'" in definition}
    assert admitted == set(SLOTS), f"the CHECK does not admit: {sorted(set(SLOTS) - admitted)}"
