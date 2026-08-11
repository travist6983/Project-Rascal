"""Assert the schema a real database actually got, by name.

`api/tests/test_migrations.py` proves the migrations build the right schema on Postgres 16.
This proves the same thing about *Neon specifically* — a managed Postgres is not required to
support every feature the local one does, and the parts this schema leans on are exactly the
parts a provider might not: stored generated columns, GIN indexes over `tsvector`, a
`plpgsql` trigger function, and named CHECK constraints instead of enums.

Run against a migrated database with `DATABASE_URL` set. Exits non-zero on the first thing
that is missing, and prints everything it checked either way.
"""

from __future__ import annotations

import os
import sys

import sqlalchemy as sa

# Kept in step with api/tests/test_migrations.py by a test that compares the two lists —
# without it, an index added to one and not the other would silently go unverified here.
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
}

EXPECTED_INDEXES = {
    "uq_assignments_child_id_assigned_on_slot",
    "ix_assignments_child_id_status_assigned_on",
    "uq_credentials_provider_subject_id",
    "ix_refresh_tokens_token_hash",
    "ix_entries_child_id_occurred_at",
    "ix_entries_child_month_day",
    "ix_media_entry_id",
    "ix_entry_tags_tag_id",
    "uq_tags_child_id_name",
    "ix_prompts_kind_cadence_active_age",
    "ix_prompts_content_hash",
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
}

# The two columns Postgres maintains itself. If a provider quietly accepted the DDL but did
# not mark them generated, search would return nothing and nothing else would complain.
GENERATED_COLUMNS = {("entries", "search_vector"), ("media", "search_vector")}


class Report:
    """Collects failures so one run tells you everything wrong, not just the first thing."""

    def __init__(self) -> None:
        self.failures: list[str] = []

    def check(self, label: str, missing: set[str] | list[str]) -> None:
        if missing:
            self.failures.append(f"{label}: missing {sorted(missing)}")
            print(f"  FAIL  {label} — missing {sorted(missing)}")
        else:
            print(f"  ok    {label}")


def _names(conn: sa.Connection, query: str) -> set[str]:
    return {row[0] for row in conn.execute(sa.text(query))}


def main() -> int:
    url = os.environ.get("DATABASE_URL", "").strip()
    if not url:
        print("DATABASE_URL is not set.", file=sys.stderr)
        return 1

    engine = sa.create_engine(url, future=True)
    report = Report()

    with engine.connect() as conn:
        server = conn.scalar(sa.text("SHOW server_version"))
        print(f"server_version: {server}\n")

        tables = _names(conn, "SELECT tablename FROM pg_tables WHERE schemaname = 'public'")
        report.check("tables", EXPECTED_TABLES - tables)

        indexes = _names(conn, "SELECT indexname FROM pg_indexes WHERE schemaname = 'public'")
        report.check("indexes", EXPECTED_INDEXES - indexes)

        checks = _names(
            conn,
            "SELECT conname FROM pg_constraint WHERE contype = 'c' "
            "AND connamespace = 'public'::regnamespace",
        )
        report.check("CHECK constraints", EXPECTED_CHECKS - checks)

        functions = _names(
            conn, "SELECT proname FROM pg_proc WHERE pronamespace = 'public'::regnamespace"
        )
        report.check("set_updated_at()", {"set_updated_at"} - functions)

        triggers = _names(conn, "SELECT tgname FROM pg_trigger WHERE NOT tgisinternal")
        expected = {f"trg_{table}_set_updated_at" for table in TABLES_WITH_UPDATED_AT_TRIGGER}
        report.check("updated_at triggers", expected - triggers)

        # Constrained columns are text + CHECK. An enum here would mean a migration drifted.
        enums = _names(
            conn,
            "SELECT typname FROM pg_type WHERE typtype = 'e' "
            "AND typnamespace = 'public'::regnamespace",
        )
        if enums:
            report.failures.append(f"Postgres enums are forbidden, found {sorted(enums)}")
            print(f"  FAIL  no Postgres enums — found {sorted(enums)}")
        else:
            print("  ok    no Postgres enums")

        generated = {
            (row[0], row[1])
            for row in conn.execute(
                sa.text(
                    "SELECT table_name, column_name FROM information_schema.columns "
                    "WHERE table_schema = 'public' AND is_generated = 'ALWAYS'"
                )
            )
        }
        report.check("stored generated columns", GENERATED_COLUMNS - generated)

        naive = [
            f"{row[0]}.{row[1]}"
            for row in conn.execute(
                sa.text(
                    "SELECT table_name, column_name FROM information_schema.columns "
                    "WHERE table_schema = 'public' "
                    "AND data_type = 'timestamp without time zone'"
                )
            )
        ]
        report.check("every timestamp is timezone-aware", naive)

        revision = conn.scalar(sa.text("SELECT version_num FROM alembic_version"))
        prompts = conn.scalar(sa.text("SELECT count(*) FROM prompts"))
        print(f"\nalembic revision: {revision}")
        print(f"prompts seeded:   {prompts}")

    engine.dispose()

    if report.failures:
        print(f"\n{len(report.failures)} problem(s):", file=sys.stderr)
        for failure in report.failures:
            print(f"  - {failure}", file=sys.stderr)
        return 1

    print("\nSchema verified.")
    return 0


if __name__ == "__main__":
    sys.exit(main())
