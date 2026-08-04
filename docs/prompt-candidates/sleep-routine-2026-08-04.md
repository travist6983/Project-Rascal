# Prompt candidates — `sleep-routine` · `question`

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
| What's the one stuffed animal or object that has to be in the bed tonight? | sleep-routine | 24–108 | Specific concrete sleep object, narrow to plush-toy years. |
| What excuse did he use tonight to delay lights-out? | sleep-routine | 30–144 | Captures the stalling ritual distinct from existing routine question. |
| What's the last thing he says to you before you leave the room? | sleep-routine | 24–144 | Different angle than 'how does he say goodbye', tied specifically to bedtime exit. |
| What position is he sleeping in when you check on him tonight? | sleep-routine | 24–216 | Simple observational question usable across all ages. |
| What did he negotiate for tonight — one more book, one more song, one more anything? | sleep-routine | 24–120 | Names the specific bedtime-bargaining behavior. |
| What time did he actually fall asleep, versus what time you wanted him to? | sleep-routine | 24–216 | Concrete gap-tracking question, works for any age. |
| What does his bed look like right now — how many things are in it with him? | sleep-routine | 24–132 | Inventory-style question distinct from routine steps. |
| What did he ask for a glass of water, a hug, or a check for monsters tonight? | sleep-routine | 24–96 | Names the classic stall list specific to younger kids. |
| Who tucked him in tonight, and did he ask for someone specific? | sleep-routine | 24–144 | Relationship angle on bedtime without assuming two parents. |
| What's the last text or goodnight message you sent him, if he has a phone now? | sleep-routine | 108–216 | Older-kid version of bedtime contact, narrow band for phone-owning ages. |
| What time did his light actually go off, according to you, versus what he'll claim tomorrow? | sleep-routine | 84–216 | Captures the honesty gap with older kids who control their own lights. |
| What did you have to say twice tonight before he actually got in bed? | sleep-routine | 24–120 | Names a specific repeated-instruction bedtime moment. |
| Is he still sleeping in his own bed tonight, or did he end up somewhere else? | sleep-routine | 24–144 | Tracks the wandering-at-night phase honestly. |
| What noise machine, nightlight, or fan does he insist on right now? | sleep-routine | 24–132 | Specific sleep-environment detail, common in this age range. |
| What time did he wake up asking to come find you? | sleep-routine | 24–96 | Names the early-morning-visit ritual for younger kids. |
| What did he want left on tonight — the door open, a light, the hallway lamp? | sleep-routine | 24–144 | Concrete environmental detail distinct from noise-machine question. |
| Did he fall asleep on his own tonight, or did you have to stay? | sleep-routine | 24–108 | Tracks independence milestone directly and factually. |
| What's he been staying up too late doing lately — reading, a screen, talking to himself? | sleep-routine | 60–216 | Older-kid version acknowledging self-directed bedtime delay. |
| What did he say when you told him it was bedtime tonight — word for word? | sleep-routine | 24–120 | His-words crossover but anchored specifically in the bedtime moment, distinct phrasing from library's general his-words prompts. |
| What time do you actually want him asleep by, and how far off was tonight? | sleep-routine | 24–216 | Reflective but factual gap question that works at any age. |

## Rejected

_Nothing was rejected._
