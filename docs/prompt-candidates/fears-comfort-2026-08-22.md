# Prompt candidates — `fears-comfort` · `question`

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
| What noise in the house makes {them} look up right now — the furnace, the pipes, a door? | fears-comfort | 24–120 | Concrete household-fear detail specific to younger kids still startled by ordinary noises. |
| What did {they} check under or behind before {they} could fall asleep last night? | fears-comfort | 24–108 | Specific bedtime-fear ritual, distinct from existing sleep-routine question. |
| What question does {name} ask you every single time you leave the house? | fears-comfort | 24–96 | Separation-anxiety detail phrased as a repeated verbal habit, not yet in library. |
| What's the one thing {they} won't do alone in this house — a room, the dark, the stairs? | fears-comfort | 30–144 | Names a specific avoided space rather than a generic fear. |
| What did {they} need you to check for monsters, bugs, or something else this week? | fears-comfort | 24–84 | Specific comfort-request action for the classic young-kid fear category. |
| What's the exact phrase you say to calm {them} down, word for word? | fears-comfort | 24–216 | Captures the parent's own comfort script verbatim, wide age range because it's about the parent's habit. |
| What did {they} ask you to promise would be okay? | fears-comfort | 36–168 | Specific verbal reassurance request, distinct wording from library's fear entries. |
| What news or story scared {them} this week, and what did {they} ask about it? | fears-comfort | 60–168 | Older-kid fear source tied to outside information, not covered in library. |
| What does {name} do with {their} hands when {they_are} nervous? | fears-comfort | 36–216 | Physical tell of anxiety, an observational action rather than a feeling. |
| What's the thing {they} keeps asking 'what if' about lately? | fears-comfort | 60–180 | Captures anticipatory worry typical of school-age and teen years. |
| Who did {they} say {they} wanted in the room with {them} last time {they} were scared? | fears-comfort | 24–144 | Specific comfort-figure detail, action-based recall. |
| What's a fear {they} had a year ago that's completely gone now? | fears-comfort | 36–192 | Growth-tinged fear question that still requires a concrete memory, not a feeling in the moment. |

## Rejected

_Nothing was rejected._
