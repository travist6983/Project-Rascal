"""Restore a `pg_dump` produced by `.github/workflows/backup.yml`.

    uv run python scripts/restore.py \
        --from rascal-20260804T081000Z.sql.gz --url "$DIRECT_DATABASE_URL"

Refuses to run against a database that already has rows unless you pass `--force`, so a
mistyped URL cannot quietly overwrite production. `tests/test_restore.py` drives this same
function on every push, so the roadmap's "a restore you have actually performed" stays true
continuously rather than once.
"""

from __future__ import annotations

import argparse
import gzip
import shutil
import subprocess
import sys
import tempfile
from pathlib import Path

import sqlalchemy as sa

# If any of these still hold rows, the target is not an empty database.
OCCUPIED_IF_PRESENT = ("entries", "children", "users", "media")


def psql_url(url: str) -> str:
    """`psql` speaks `postgresql://`, not SQLAlchemy's `postgresql+psycopg://`."""
    return (
        sa.engine.make_url(url).set(drivername="postgresql").render_as_string(hide_password=False)
    )


def looks_occupied(url: str) -> list[str]:
    """Tables that exist and are not empty. Empty list means safe to restore over."""
    engine = sa.create_engine(url, future=True)
    occupied: list[str] = []
    try:
        inspector = sa.inspect(engine)
        present = set(inspector.get_table_names())
        with engine.connect() as conn:
            for table in OCCUPIED_IF_PRESENT:
                if table not in present:
                    continue
                count = conn.scalar(sa.text(f'SELECT count(*) FROM "{table}"')) or 0
                if count:
                    occupied.append(f"{table} ({count} rows)")
    finally:
        engine.dispose()
    return occupied


def restore(dump: Path, url: str, *, force: bool = False) -> None:
    """Apply a dump to `url`. The dump is `--clean --if-exists`, so it drops as it goes."""
    if not dump.exists():
        raise FileNotFoundError(f"{dump} does not exist")

    occupied = looks_occupied(url)
    if occupied and not force:
        raise SystemExit(
            "Refusing to restore over a database that already has data:\n  "
            + "\n  ".join(occupied)
            + "\n\nPass --force if you really mean it."
        )

    with tempfile.TemporaryDirectory() as tmp:
        plain = Path(tmp) / "dump.sql"
        opener = gzip.open if dump.suffix == ".gz" else open
        with opener(dump, "rb") as src, plain.open("wb") as dst:
            shutil.copyfileobj(src, dst)

        result = subprocess.run(
            [
                "psql",
                psql_url(url),
                "--quiet",
                # Stop at the first real error rather than leaving a half-restored schema.
                # ON_ERROR_STOP is what makes psql's exit code mean anything.
                "--set=ON_ERROR_STOP=1",
                "--file",
                str(plain),
            ],
            capture_output=True,
            text=True,
        )

    if result.returncode != 0:
        raise SystemExit(f"psql failed ({result.returncode}):\n{result.stderr.strip()}")


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument(
        "--from", dest="dump", type=Path, required=True, help="Path to the .sql.gz dump."
    )
    parser.add_argument(
        "--url",
        required=True,
        help="Target database. Use Neon's DIRECT endpoint, never the pooled one.",
    )
    parser.add_argument("--force", action="store_true", help="Restore even if the target has data.")
    args = parser.parse_args(argv)

    restore(args.dump, args.url, force=args.force)
    print(f"restored {args.dump} into {sa.engine.make_url(args.url).render_as_string()}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
