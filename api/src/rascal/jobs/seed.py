"""`python -m rascal.jobs.seed` — load seeds/prompts.yaml into the prompts table."""

from __future__ import annotations

import argparse
import asyncio
import sys
from pathlib import Path

from rascal.db import get_sessionmaker
from rascal.logging_config import configure_logging
from rascal.services.seeding import SEEDS_PATH, seed_prompts


async def _run(path: Path) -> int:
    async with get_sessionmaker()() as session:
        result = await seed_prompts(session, path)
    print(
        f"prompts: {result.inserted} inserted, {result.updated} updated, "
        f"{result.unchanged} unchanged ({result.total} in the library)"
    )
    return 0


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument(
        "--file",
        type=Path,
        default=SEEDS_PATH,
        help="path to the prompts YAML (default: api/seeds/prompts.yaml)",
    )
    args = parser.parse_args(argv)
    configure_logging()
    return asyncio.run(_run(args.file))


if __name__ == "__main__":
    sys.exit(main())
