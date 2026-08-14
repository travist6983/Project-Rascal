"""No fixture date may sit in the future.

**A fixture date in the future is a test that has not run yet**, and this is the file that says
so out loud.

`test_today.py` pinned its board to the literal `2026-08-14`, written when that was comfortably
ahead. `GET /today` self-heals — when the requested date *is* the child's current date,
`ensure_day_filled` mints the day's missing slots before answering — so for as long as the
constant sat in the future those tests asserted a board nothing had filled. On the morning it
arrived, the fill ran, minted the `mission_b` that migration 0008 had added a year earlier, and
the suite went red having never once exercised the path it claimed to cover. The failure was
correct; the eleven green runs before it were not.

That is a class, not an incident. Any date the suite hardcodes drifts toward the real clock at a
day a day, and the day it lands is the day the test starts meaning something different — silently,
because nothing about a green run says which branch it took.

So: every `dt.date(...)` literal under `tests/` must already have happened. A date in the past can
never become today again, which makes it the only kind that is stable. Where a test genuinely needs
a future date — a horizon, a loop bound, an expiry — say so on the line and say why.
"""

from __future__ import annotations

import ast
import datetime as dt
from pathlib import Path

TESTS = Path(__file__).resolve().parent

# The escape hatch, and it has to be earned on the line itself: a future date that is *about*
# being in the future is legitimate, and one that is a fixture is a bomb. A marker with no reason
# after it is not accepted, because "why" is the whole content of the exemption.
MARKER = "future-date:"


def _literal_dates(tree: ast.AST) -> list[tuple[int, dt.date]]:
    """Every `dt.date(y, m, d)` / `date(y, m, d)` written out in full.

    Only fully-literal calls. `dt.date(year, 8, 14)` over a variable is not a hardcoded date and
    is not this file's business.
    """
    found: list[tuple[int, dt.date]] = []
    for node in ast.walk(tree):
        if not isinstance(node, ast.Call):
            continue
        name = (
            node.func.attr if isinstance(node.func, ast.Attribute) else getattr(node.func, "id", "")
        )
        if name != "date" or len(node.args) != 3 or node.keywords:
            continue
        if not all(
            isinstance(arg, ast.Constant) and isinstance(arg.value, int) for arg in node.args
        ):
            continue
        try:
            found.append((node.lineno, dt.date(*(arg.value for arg in node.args))))
        except ValueError:
            # A deliberately impossible date is somebody testing validation, not a fixture.
            continue
    return found


def test_no_test_hardcodes_a_date_that_has_not_happened_yet() -> None:
    today = dt.date.today()
    offenders: list[str] = []

    for path in sorted(TESTS.glob("*.py")):
        if path.name == Path(__file__).name:
            continue
        source = path.read_text(encoding="utf-8")
        lines = source.splitlines()
        for lineno, value in _literal_dates(ast.parse(source)):
            if value <= today:
                continue
            line = lines[lineno - 1]
            if MARKER in line:
                # Exempt, and the reason is on the line where the next reader will see it.
                continue
            offenders.append(f"{path.name}:{lineno}: {value.isoformat()} — {line.strip()}")

    detail = "\n".join(offenders)
    assert offenders == [], (
        "These fixture dates have not happened yet. A test pinned to a future date is a test "
        "that has not run: it asserts one branch until the clock arrives, then silently starts "
        "asserting another. Move it into the past, or mark the line "
        f"`# {MARKER} <why>` if being in the future is the point.\n{detail}"
    )
