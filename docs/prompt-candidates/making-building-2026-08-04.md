# Prompt candidates — `making-building` · `question`

Generated 2026-08-04 by `scripts/generate_prompts.py` using `claude-sonnet-5`.

20 of 20 candidates passed the automated filters. **Those filters are a spam trap, not an editor** — they catch the four rejection rules where the rule is textually detectable, and nothing else. Everything below still needs reading.

## How to review this

1. Delete the rows you do not want. Leave the ones you do.
2. Move the survivors into the right table in `docs/mission-library.md`.
3. `uv run python scripts/mission_library_to_yaml.py`, then `make seed`.
4. `api/tests/test_seeding.py` asserts the coverage table in the library; update the numbers it gives you.
5. Delete this file in the same commit. It is a worksheet, not a record.

## Accepted

| Prompt | Theme | Ages | Why |
|---|---|---|---|
| What is he building right now, and what is it actually supposed to be? | making-building | 24–120 | Captures the current project and his own framing of it, not yours. |
| What's the most ambitious thing he's tried to build that didn't work? | making-building | 36–144 | Surfaces failed attempts, which are more specific and revealing than successes. |
| What material does he reach for first when he wants to make something — blocks, cardboard, tape, mud? | making-building | 24–120 | Concrete, observable preference tied to the making-building theme. |
| What has he refused to let you throw away because he built it? | making-building | 30–144 | Specific object-based question with a funny household tension built in. |
| What tool is he currently obsessed with using, real or pretend? | making-building | 30–144 | Tools mark a developmental phase and are easy to answer concretely. |
| Describe the worst structural collapse he's had this month — what fell apart and how did he react? | making-building | 36–144 | Asks for a specific incident, not a vague sentiment. |
| What has he taken apart recently, on purpose or not? | making-building | 30–144 | Covers curiosity and destruction as part of building/making. |
| What does he call the thing he's building, and does the name match what it looks like? | making-building | 30–120 | Combines his-words and making-building without duplicating an existing entry. |
| What's a rule he's invented for how his blocks or Legos have to be sorted or used? | making-building | 36–144 | Zooms in on his own arbitrary systems, a specific and funny detail. |
| What did he build today that you had to step over or around for the rest of the day? | making-building | 24–144 | Grounds the question in an ordinary domestic inconvenience. |
| What's the most useless thing he's ever built with total confidence that it worked? | making-building | 36–144 | Humor-forward, specific to a memorable object. |
| What does he ask for help with when he's building, versus what he insists on doing alone? | making-building | 36–216 | Tracks a shifting independence line through a concrete lens. |
| What's currently under construction in the yard, the living room, or his room, and how long has it been sitting there? | making-building | 30–144 | Location-and-duration detail makes this answerable without being generic. |
| What does he build over and over, the same way every time? | making-building | 24–120 | Repetition is a specific, trackable behavior pattern. |
| What has he tried to fix around the house without being asked? | making-building | 48–216 | Captures initiative and skill at an age when kids start attempting real repairs. |
| What's the last thing he built that he wanted photographed or shown off? | making-building | 30–144 | Focuses on his pride in a specific object, distinct from the existing photo prompt. |
| If he had unlimited cardboard and tape right now, what would he say he's going to build? | making-building | 36–144 | A hypothetical that still asks for a concrete, quotable answer. |
| What's something he built that only makes sense to him? | making-building | 30–144 | Invites a description of his internal logic, not a feeling. |
| What did he build with someone else this week, and whose idea was it? | making-building | 36–216 | Adds a social/collaborative angle not covered elsewhere in the library. |
| What's the most complicated thing he's built without any instructions? | making-building | 60–216 | Age-appropriate for kids capable of multi-step independent projects. |

## Rejected

_Nothing was rejected._
