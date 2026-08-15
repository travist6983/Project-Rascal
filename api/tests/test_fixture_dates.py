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

So: every `dt.date(...)` and `dt.datetime(...)` literal under `tests/` must already have happened.
A date in the past can never become today again, which makes it the only kind that is stable. Where
a test genuinely needs a future date — a horizon, a loop bound, an expiry — say so on the line and
say why.

**Today counts as not-yet-happened, and that is the whole point.** The first version of this guard
said `value <= today`, which exempted the single most dangerous value it exists to catch: on
14 Aug 2026 it would have passed `dt.date(2026, 8, 14)` clean, on the exact day that literal took
the suite down. A date equal to today is a bomb mid-detonation, not a safe one.

**`datetime` counts too.** A fixture is a fixture whichever constructor built it, and the first
version saw only `date`.
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


def _literal_dates(tree: ast.AST) -> list[tuple[int, int, dt.date]]:
    """Every `dt.date(...)` and `dt.datetime(...)` written out in full.

    Returns `(first line, last line, value)`. The span rather than just the start, because the
    exemption marker has to be findable on any physical row the statement occupies: `ruff format`
    rewraps a long assertion and moves a trailing comment onto a continuation line, which turned a
    valid exemption into a suite failure once already.

    Only fully-literal calls. `dt.date(year, 8, 14)` over a variable is not a hardcoded date and
    is not this file's business.
    """
    found: list[tuple[int, int, dt.date]] = []
    for node in ast.walk(tree):
        if not isinstance(node, ast.Call):
            continue
        name = (
            node.func.attr if isinstance(node.func, ast.Attribute) else getattr(node.func, "id", "")
        )
        # `date` takes exactly three; `datetime` takes three to seven, and `tzinfo=` is the one
        # keyword that does not stop it being a literal moment.
        if name == "date":
            ok = len(node.args) == 3
        elif name == "datetime":
            ok = 3 <= len(node.args) <= 7
        else:
            continue
        if not ok or any(kw.arg != "tzinfo" for kw in node.keywords):
            continue
        if not all(
            isinstance(arg, ast.Constant) and isinstance(arg.value, int) for arg in node.args[:3]
        ):
            continue
        try:
            value = dt.date(*(arg.value for arg in node.args[:3]))
        except ValueError:
            # A deliberately impossible date is somebody testing validation, not a fixture.
            continue
        found.append((node.lineno, getattr(node, "end_lineno", None) or node.lineno, value))
    return found


def test_no_test_hardcodes_a_date_that_has_not_happened_yet() -> None:
    today = dt.date.today()
    offenders: list[str] = []

    # Recursive: pytest collects the whole tree, so a fixture in a subdirectory is collected
    # and would otherwise be invisible to this.
    for path in sorted(TESTS.rglob("*.py")):
        if path.name == Path(__file__).name:
            continue
        source = path.read_text(encoding="utf-8")
        lines = source.splitlines()
        for start, end, value in _literal_dates(ast.parse(source)):
            if value < today:
                continue
            # Any physical row the statement occupies, so a formatter that rewraps a line cannot
            # silently revoke an exemption somebody earned.
            if any(MARKER in row for row in lines[start - 1 : end]):
                continue
            offenders.append(
                f"{path.name}:{start}: {value.isoformat()} — {lines[start - 1].strip()}"
            )

    detail = "\n".join(offenders)
    assert offenders == [], (
        "These fixture dates have not happened yet. A test pinned to a future date is a test "
        "that has not run: it asserts one branch until the clock arrives, then silently starts "
        "asserting another. Move it into the past, or mark the line "
        f"`# {MARKER} <why>` if being in the future is the point.\n{detail}"
    )
