"""The scene graph, and the caption track derived from it.

**The captions are derived on every write, and that is the whole point of this module.**

Be precise about what was wrong before, because the loose version of this claim is wrong and was
written here first. Claude never authored a WebVTT track: phase 97's `SHOT_LIST_SCHEMA` had four
properties per shot and none of them was a caption, and `renderers.caption_track(shots)` derived
the track server-side from the shot list — at the moment of generation the two agreed.

**They were then stored as two independent columns, and only one of them was ever recomputed.**
`caption_track` sat in `studio.EDITABLE`, so a `PATCH` could replace it with anything; and
editing the shot list did *not* re-derive it, so the ordinary act of changing a shot left a
track describing the previous video. Both were reachable through the public API and nothing
anywhere compared them.

So the fix is not "derive it" — it was already derived. The fix is that the derivation now runs
on **every** path that can set the graph, and the derived columns are not settable at all:
`_apply_treatment` in `studio.py` is the only writer, and `caption_track` and `duration_seconds`
are gone from `SocialAssetIn`, `SocialAssetUpdate` and `EDITABLE`. That is what makes "the cues
say what the cards say" a property rather than a description of a row's first minute.

**Milliseconds, integers, no floats.** WebVTT stamps to a thousandth of a second and a scene
graph is authored in milliseconds, so the arithmetic here is exact integer arithmetic and the
cue boundaries are the running sum. The browser's `sceneAt()` in `admin/static/timeline.js`
computes the same running sum the same way, which is what makes "the captions line up with the
cards" a property rather than a hope.
"""

from __future__ import annotations

from typing import Any

__all__ = ["boundaries_ms", "caption_track", "stamp", "total_ms"]


def _length_of(scene: dict[str, Any]) -> int:
    """One scene's duration in whole milliseconds, clamped at zero.

    **The clamp is not defensive dressing — it is what makes this module's central claim true.**
    The docstring above says `timeline.js` walks the same running sum the same way, and its
    `boundaries()` reads `Math.max(0, Math.trunc(scene.duration_ms) || 0)`. Without the `max`
    here the two agree on every duration a validated treatment can hold and disagree on a
    negative one, which is precisely the case where "the same way" would stop being true and
    nothing would notice: the cue times would still be internally consistent and would describe
    a different video. `Math.trunc` and `int()` already truncate toward zero identically, and
    `NaN || 0` and `None or 0` already both give zero.
    """
    return max(0, int(scene.get("duration_ms") or 0))


def boundaries_ms(scenes: list[dict[str, Any]]) -> list[int]:
    """Cumulative scene ends, in order. `[1500, 4500, 7000]` for three scenes.

    **The only running sum in this module.** `total_ms` is its last element and `caption_track`
    walks it, rather than each keeping a `clock` of its own — three copies of one sum inside a
    file whose whole argument is that there is one is the drift this phase exists to remove,
    written smaller. `timeline.js` is arranged the same way for the same reason.
    """
    clock = 0
    ends = []
    for scene in scenes:
        clock += _length_of(scene)
        ends.append(clock)
    return ends


def total_ms(scenes: list[dict[str, Any]]) -> int:
    """The whole runtime. The last boundary, and never anything cleverer."""
    ends = boundaries_ms(scenes)
    return ends[-1] if ends else 0


def _cue_text(value: str) -> str:
    """WebVTT reserves `&` and `<` in cue text, and no cue line may contain `-->`.

    **Escaped here rather than rejected at the schema**, because the card draws these characters
    verbatim and the cue has to say the same words — refusing a headline containing "R&D" or
    "<3" would be the renderer's rules leaking into the copy. A conforming parser reads `<` as
    the start of a cue span and drops everything to the next `>`; a line holding `-->` ends the
    cue and is reparsed as a timings line, which deletes the cue outright. Both are silent, in
    the one artifact this module exists to make trustworthy.

    `&` goes first or it would double-escape the `&lt;` the next line produces.
    """
    return value.replace("&", "&amp;").replace("<", "&lt;").replace("-->", "--&gt;")


def caption_track(scenes: list[dict[str, Any]]) -> str:
    """A WebVTT track, one cue per scene, boundaries exactly the scene boundaries.

    WebVTT rather than SRT because it is what a browser `<track>` element reads and what every
    social platform's upload accepts; SRT would need a conversion somewhere and this needs none.

    **Captions are not optional on a social video** — most of them are watched with the sound
    off, which makes this the accessibility feature that is also the reach feature. Here they
    carry the whole burden: there is no audio track at all, by decision, so the cues are the
    only thing a platform's own transcript surface has to read.

    A scene with no headline still consumes its slice of the clock and simply gets no cue. The
    running sum is over every scene, never only over the ones that produced text — a cue whose
    start is computed from the scenes before it that *happened to have words* is the bug this
    sentence exists to stop somebody reintroducing.
    """
    lines = ["WEBVTT", ""]
    number = 0
    # Starts are the previous ends, so the clock is read from `boundaries_ms` rather than kept
    # again here. A scene with no headline advances it exactly like any other — that is what
    # walking the boundaries instead of accumulating alongside the cues guarantees.
    ends = boundaries_ms(scenes)
    for index, scene in enumerate(scenes):
        headline = str(scene.get("headline") or "").strip()
        if not headline:
            continue
        subhead = str(scene.get("subhead") or "").strip()
        number += 1
        start = ends[index - 1] if index else 0
        # The subhead goes on a second cue line rather than being joined with a space:
        # WebVTT renders a newline as one, and the card draws them as two blocks.
        body = f"{_cue_text(headline)}\n{_cue_text(subhead)}" if subhead else _cue_text(headline)
        lines += [str(number), f"{stamp(start)} --> {stamp(ends[index])}", body, ""]
    return "\n".join(lines)


def stamp(milliseconds: int) -> str:
    """`HH:MM:SS.mmm`, which is the only timestamp form WebVTT's parser is required to accept.

    Integer arithmetic throughout. A float seconds value rounded at the last moment is how a
    cue that should end at 4.500 ends at 4.499 and stops lining up with the frame the browser
    drew, which is exactly the drift this module was written to make impossible.
    """
    # Clamped for the same reason `_length_of` is: `divmod(-1, 1000)` is `(-1, 999)` in Python,
    # so a negative would render as `-1:59:59.999` — a string no WebVTT parser accepts, produced
    # without an error anywhere.
    whole, millis = divmod(max(0, int(milliseconds)), 1000)
    return f"{whole // 3600:02d}:{whole % 3600 // 60:02d}:{whole % 60:02d}.{millis:03d}"
