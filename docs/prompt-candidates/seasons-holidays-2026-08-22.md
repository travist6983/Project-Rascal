# Prompt candidates — `seasons-holidays` · `activity`

Generated 2026-08-22 by `scripts/generate_prompts.py` using `claude-sonnet-5`.

12 of 12 candidates passed the automated filters. **Those filters are a spam trap, not an editor** — they catch the four rejection rules where the rule is textually detectable, and nothing else. Everything below still needs reading.

## How to review this

1. Delete the rows you do not want. Leave the ones you do.
2. Move the survivors into the right table in `docs/mission-library.md`.
3. `uv run python scripts/mission_library_to_yaml.py`, then `make seed`.
4. `api/tests/test_seeding.py` asserts the coverage table in the library; update the numbers it gives you.
5. Delete this file in the same commit. It is a worksheet, not a record.

## Accepted

| Prompt | Theme | Ages | Why |
|---|---|---|---|
| Let {them} pick the first holiday decoration to go up this year, and put it exactly where {they} want it. | seasons-holidays | 24–216 | Simple decision-handoff action tied to a season, doable in minutes. |
| Let {them} choose what the whole house eats for the first cold-weather dinner of the year. | seasons-holidays | 30–144 | Concrete seasonal food decision without any outing or planning. |
| Ask {them} to give out the candy at the door tonight, start to finish. | seasons-holidays | 36–144 | Specific Halloween-adjacent behavior a young kid can actually execute. |
| Let {them} stay up ten minutes past bedtime to watch the fireworks or the ball drop from a window. | seasons-holidays | 24–144 | Concrete New Year's Eve action with a fixed time window. |
| Hand {them} the wrapping paper and let {them} wrap one gift alone, tape disasters included. | seasons-holidays | 48–144 | Specific holiday task ceding control, matches making-building tone. |
| Let {them} write the grocery list for the holiday meal, misspellings and all, and use it as written. | seasons-holidays | 60–144 | Concrete, no outing required, ties writing skill to a holiday task. |
| Ask {them} what {they} wants written on the pumpkin, and carve exactly that. | seasons-holidays | 36–144 | Autumn activity narrowed to the specific act of ceding creative control. |
| Let {them} set the thermostat or pick the blanket for the first cold night this year. | seasons-holidays | 24–96 | Tiny seasonal autonomy moment doable at home. |
| Give {them} the job of turning on the holiday lights every evening this week, and don't do it yourself. | seasons-holidays | 30–120 | Repeatable small responsibility tied to winter holidays. |
| Let {them} choose the music for the drive or the dinner on the holiday itself, no vetoes. | seasons-holidays | 36–216 | Ceding a small control point during a holiday gathering. |
| Ask {them} to teach a cousin or a friend one thing about how your family does this holiday. | seasons-holidays | 60–216 | Behavior-based, specific to older kids who can explain family customs. |
| Let {them} stay in pajamas the entire first day of a school break, no negotiating. | seasons-holidays | 48–168 | Concrete permissive act tied to seasonal school calendar. |

## Rejected

_Nothing was rejected._
