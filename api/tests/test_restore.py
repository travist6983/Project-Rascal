"""The restore, actually performed.

`docs/memory-app-roadmap.md` sets the P1 exit criterion as "a restore you've actually
performed". Rather than perform one once and write it down, the machine performs one on
every push: dump a real database, drop it, restore from the dump, and assert the rows came
back.

This is the test that would have caught a backup that dumps successfully and restores into
nothing.
"""

from __future__ import annotations

import datetime as dt
import gzip
import os
import shutil
import subprocess
import uuid
from collections.abc import Iterator
from pathlib import Path

import pytest
import sqlalchemy as sa
from scripts.restore import looks_occupied, psql_url, restore

from conftest import API_DIR
from rascal.services.seeding import seed_prompts

pytestmark = pytest.mark.skipif(
    shutil.which("pg_dump") is None or shutil.which("psql") is None,
    reason="pg_dump/psql not installed",
)


def _admin_engine(url: str) -> sa.Engine:
    admin = sa.engine.make_url(url).set(database="postgres")
    return sa.create_engine(
        admin.render_as_string(hide_password=False), isolation_level="AUTOCOMMIT"
    )


@pytest.fixture
def scratch_url() -> Iterator[str]:
    """A database of its own, created and dropped around the round trip."""
    url = sa.engine.make_url(os.environ["DATABASE_URL"])
    name = f"{url.database}_restore"
    admin = _admin_engine(os.environ["DATABASE_URL"])
    with admin.connect() as conn:
        conn.execute(sa.text(f'DROP DATABASE IF EXISTS "{name}" WITH (FORCE)'))
        conn.execute(sa.text(f'CREATE DATABASE "{name}"'))
    target = url.set(database=name).render_as_string(hide_password=False)

    subprocess.run(
        ["alembic", "upgrade", "head"],
        cwd=API_DIR,
        env={**os.environ, "DATABASE_URL": target},
        check=True,
        capture_output=True,
    )
    yield target

    with admin.connect() as conn:
        conn.execute(sa.text(f'DROP DATABASE IF EXISTS "{name}" WITH (FORCE)'))
    admin.dispose()


def _populate(url: str) -> dict:
    """A small but representative archive: a child, an entry, media, a tag, an assignment."""
    engine = sa.create_engine(url, future=True)
    entry_id = uuid.uuid4()
    child_id = uuid.uuid4()
    user_id = uuid.uuid4()
    body = "He called it a 'hangaburger' again — the one sentence that has to survive."

    with engine.begin() as conn:
        # `users.family_id` is NOT NULL since phase 36, so a seeded user needs a household.
        family_id = conn.execute(
            sa.text("INSERT INTO families (id) VALUES (gen_random_uuid()) RETURNING id")
        ).scalar_one()
        conn.execute(
            sa.text(
                "INSERT INTO users (id, family_id, email, display_name, is_admin) "
                "VALUES (:id, :family, :email, 'Travis', true)"
            ),
            {"id": user_id, "family": family_id, "email": "travis@example.com"},
        )
        conn.execute(
            sa.text(
                "INSERT INTO children (id, name, birthdate, family_timezone) "
                "VALUES (:id, 'Miles', DATE '2022-06-14', 'America/Detroit')"
            ),
            {"id": child_id},
        )
        conn.execute(
            sa.text(
                "INSERT INTO guardians (user_id, child_id, role) "
                "VALUES (:user_id, :child_id, 'parent')"
            ),
            {"user_id": user_id, "child_id": child_id},
        )
        conn.execute(
            sa.text(
                "INSERT INTO entries "
                "(id, child_id, author_id, occurred_at, child_age_months, body, entry_type) "
                "VALUES (:id, :child_id, :author_id, :occurred_at, 50, :body, 'text')"
            ),
            {
                "id": entry_id,
                "child_id": child_id,
                "author_id": user_id,
                "occurred_at": dt.datetime(2026, 8, 15, 19, 4, tzinfo=dt.UTC),  # future-date: pure
                "body": body,
            },
        )
        conn.execute(
            sa.text(
                "INSERT INTO media (id, entry_id, s3_key, kind, bytes, upload_status, transcript) "
                "VALUES (:id, :entry_id, 'children/x/story.m4a', 'audio', 900000, "
                "'complete', 'once upon a time there was a dinosaur')"
            ),
            {"id": uuid.uuid4(), "entry_id": entry_id},
        )
    engine.dispose()
    return {"entry_id": entry_id, "child_id": child_id, "body": body}


def _counts(url: str) -> dict[str, int]:
    engine = sa.create_engine(url, future=True)
    tables = ("users", "children", "guardians", "entries", "media", "prompts")
    with engine.connect() as conn:
        counts = {t: conn.scalar(sa.text(f'SELECT count(*) FROM "{t}"')) or 0 for t in tables}
    engine.dispose()
    return counts


def _dump(url: str, path: Path) -> None:
    """The same pg_dump invocation the nightly workflow uses."""
    result = subprocess.run(
        [
            "pg_dump",
            psql_url(url),
            "--format=plain",
            "--no-owner",
            "--no-privileges",
            "--clean",
            "--if-exists",
        ],
        capture_output=True,
    )
    assert result.returncode == 0, result.stderr.decode()[:2000]
    with gzip.open(path, "wb") as handle:
        handle.write(result.stdout)


async def test_a_dump_restores_into_an_empty_database(scratch_url: str, tmp_path: Path) -> None:
    """Dump, drop everything, restore, and prove the archive came back intact."""
    engine = sa.create_engine(scratch_url, future=True)
    # Seed the real library so the dump has content beyond the handful of fixture rows.
    from sqlalchemy.ext.asyncio import async_sessionmaker, create_async_engine

    aengine = create_async_engine(scratch_url, poolclass=sa.pool.NullPool)
    async with async_sessionmaker(bind=aengine, expire_on_commit=False)() as session:
        await seed_prompts(session)
    await aengine.dispose()

    planted = _populate(scratch_url)
    before = _counts(scratch_url)
    assert before["entries"] == 1
    assert before["prompts"] > 100

    dump = tmp_path / "rascal-test.sql.gz"
    _dump(scratch_url, dump)
    assert dump.stat().st_size > 1024

    # Drop everything. This is the part that makes it a restore and not a no-op.
    with engine.begin() as conn:
        conn.execute(sa.text("DROP SCHEMA public CASCADE"))
        conn.execute(sa.text("CREATE SCHEMA public"))
    engine.dispose()

    # The schema really is gone — so the restore below is doing work, not a no-op.
    assert looks_occupied(scratch_url) == []

    restore(dump, scratch_url)

    after = _counts(scratch_url)
    assert after == before

    # Not just row counts — the actual words have to be there.
    engine = sa.create_engine(scratch_url, future=True)
    with engine.connect() as conn:
        body = conn.scalar(
            sa.text("SELECT body FROM entries WHERE id = :id"), {"id": planted["entry_id"]}
        )
        transcript = conn.scalar(sa.text("SELECT transcript FROM media LIMIT 1"))
        alembic = conn.scalar(sa.text("SELECT version_num FROM alembic_version"))
    engine.dispose()

    assert body == planted["body"]
    assert transcript == "once upon a time there was a dinosaur"
    # The schema version travels with the dump, so a restored database is not stranded
    # outside Alembic's history.
    assert alembic is not None


async def test_restore_refuses_to_overwrite_a_populated_database(
    scratch_url: str, tmp_path: Path
) -> None:
    """A mistyped URL must not quietly destroy the thing it was aimed at."""
    _populate(scratch_url)
    dump = tmp_path / "rascal-test.sql.gz"
    _dump(scratch_url, dump)

    with pytest.raises(SystemExit) as caught:
        restore(dump, scratch_url)
    assert "already has data" in str(caught.value)

    # And --force is the way through, so the escape hatch works.
    restore(dump, scratch_url, force=True)
    assert _counts(scratch_url)["entries"] == 1


def test_occupancy_check_reports_what_is_in_the_way(scratch_url: str) -> None:
    assert looks_occupied(scratch_url) == []
    _populate(scratch_url)
    occupied = looks_occupied(scratch_url)
    assert any(item.startswith("entries") for item in occupied)
    assert any(item.startswith("children") for item in occupied)
