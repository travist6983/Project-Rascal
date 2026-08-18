"""The owner's email copy, loaded from `seeds/email_copy.yaml`.

**The copy is never written in Python.** `docs/marketing/email-sequence.md` is the authoring
surface, its own header forbids an agent editing it, and
`scripts/email_sequence_to_yaml.py` is the only thing that reads it. This module reads the
generated YAML — the same split `docs/mission-library.md` and `seeds/prompts.yaml` already use,
and for the same two reasons: `CLAUDE.md` says runtime never parses markdown, and `docs/` is
outside the Docker build context so the markdown is not in the image at all.

**Every shape problem here is fatal.** A silently-empty pool would send blank emails on a
schedule, which is the failure this whole module is arranged to make impossible.
"""

from __future__ import annotations

import functools
from dataclasses import dataclass
from pathlib import Path
from typing import Any

import yaml

#: `seeds/` is copied into the image by the Dockerfile, unlike `docs/`.
COPY_PATH = Path(__file__).resolve().parents[3] / "seeds" / "email_copy.yaml"

EXPECTED_POOL_SIZE = 30


class EmailCopyError(RuntimeError):
    """The copy file is missing or malformed. Always fatal, never a warning."""


@dataclass(frozen=True)
class WelcomeEmail:
    """One of the five, timed off a subscriber's own confirmation."""

    index: int
    day: int
    subject: str
    body: str


@dataclass(frozen=True)
class EmailCopy:
    welcome: tuple[WelcomeEmail, ...]
    pool: tuple[str, ...]
    footer: str

    def prompt_for(self, day_of_year: int) -> tuple[int, str]:
        """Day-of-year modulo the pool length, as the copy file itself specifies.

        Deterministic and stateless: the same date always yields the same prompt, so a rerun
        of a given day cannot send a different one, and nothing has to be remembered between
        runs to make that true.

        Returns the index as well as the text, because the index is what the ledger stores —
        the owner may edit the pool, and a row that recorded only the text could not later be
        told apart from a row whose text has since changed.
        """
        index = (day_of_year - 1) % len(self.pool)
        return index, self.pool[index]


def _require(data: dict[str, Any], key: str) -> Any:
    if key not in data:
        raise EmailCopyError(f"{COPY_PATH.name} is missing '{key}'")
    return data[key]


@functools.lru_cache(maxsize=1)
def load(path: Path | None = None) -> EmailCopy:
    """Read and validate the copy. Cached, because it does not change between runs."""
    source = path or COPY_PATH
    if not source.exists():
        raise EmailCopyError(
            f"{source} is missing. Run scripts/email_sequence_to_yaml.py and commit the result."
        )

    try:
        data = yaml.safe_load(source.read_text(encoding="utf-8"))
    except yaml.YAMLError as exc:
        raise EmailCopyError(f"{source.name} is not valid YAML: {exc}") from exc

    if not isinstance(data, dict):
        raise EmailCopyError(f"{source.name} should be a mapping")

    pool = _require(data, "pool")
    if not isinstance(pool, list) or not pool:
        raise EmailCopyError("the prompt pool is empty, so every send would be a blank email")
    if len(pool) != EXPECTED_POOL_SIZE:
        # Not silently tolerated: the pool size sets the repeat interval, and a pool that
        # halved without anybody noticing would repeat twice as often.
        raise EmailCopyError(f"expected {EXPECTED_POOL_SIZE} prompts, found {len(pool)}")
    if any(not isinstance(item, str) or not item.strip() for item in pool):
        raise EmailCopyError("a prompt in the pool is empty")

    footer = _require(data, "footer")
    if not isinstance(footer, str) or not footer.strip():
        raise EmailCopyError("the footer is empty, and every email is required to carry it")

    welcome_raw = _require(data, "welcome")
    if not isinstance(welcome_raw, list) or len(welcome_raw) != 5:
        raise EmailCopyError("expected five welcome emails")

    welcome = tuple(
        WelcomeEmail(
            index=int(item["index"]),
            day=int(item["day"]),
            subject=str(item["subject"]),
            body=str(item["body"]),
        )
        for item in welcome_raw
    )

    return EmailCopy(welcome=welcome, pool=tuple(pool), footer=footer)
