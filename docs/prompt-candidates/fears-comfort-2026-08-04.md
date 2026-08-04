# Prompt candidates — `fears-comfort` · `question`

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
| What noise in the house makes him look up right now? | fears-comfort | 24–96 | Concrete sensory fear detail specific to young kids, not already covered. |
| What does he ask you to check under or behind before he'll go to sleep? | fears-comfort | 30–96 | Distinct from existing sleep-routine/fear prompts, very specific bedtime behavior. |
| What did he refuse to do today because he was scared, even if he wouldn't say so? | fears-comfort | 30–144 | Captures avoidance behavior tied to fear, not duplicated elsewhere. |
| What's the one thing he needs in bed with him to fall asleep — object, not person? | fears-comfort | 24–108 | Specific comfort-object detail distinct from crying/fear prompts already in library. |
| What did he ask you to promise wouldn't happen? | fears-comfort | 36–144 | Captures verbal reassurance-seeking, a distinct angle from existing fear questions. |
| What's the first thing he does when he's scared — run to you, freeze, or something else? | fears-comfort | 24–120 | Behavioral pattern question, not yet asked in library. |
| What movie, show, or book scene does he ask you to skip? | fears-comfort | 36–144 | Concrete media-avoidance detail, age-appropriate for kids who watch shows. |
| What does he do when he wakes up from a nightmare? | fears-comfort | 24–132 | Distinct nighttime-fear behavior, not covered by 'what did he cry about' prompt. |
| What's a sound he used to be scared of that doesn't bother him anymore? | fears-comfort | 36–156 | Tracks growth through fear specifically, different framing from generic change prompt. |
| What does he think is hiding in the dark right now, if anything? | fears-comfort | 24–96 | Age-narrow, concrete imaginative-fear question for younger kids. |
| What's the thing he won't do alone, even though he's capable of it? | fears-comfort | 48–168 | Captures independence-adjacent fear for older kids, distinct from younger comfort prompts. |
| What did he need you to sit with him through this week? | fears-comfort | 24–144 | Broad but action-based comfort question not yet in library. |
| What's a worry he's brought up more than once lately? | fears-comfort | 48–180 | Captures recurring anxiety in older kids who can articulate worries. |
| What does he do with his hands when he's nervous? | fears-comfort | 36–168 | Physical tell of anxiety, concrete and observable, no overlap with existing prompts. |
| What did he need reassurance about today that seems small to you but wasn't to him? | fears-comfort | 30–144 | Distinct from existing fears prompt by focusing on reassurance rather than the fear itself. |
| What's something he checks or counts to feel okay before doing something else? | fears-comfort | 36–132 | Captures ritual/comfort behavior, specific and observable. |
| Who does he ask for when he's upset, if it's not you? | fears-comfort | 24–168 | Relationship-adjacent comfort question distinct from existing relationships prompts. |
| What's a place in the house he avoids, and does he say why? | fears-comfort | 24–96 | Very specific spatial-fear detail for young kids. |
| What did he do today that showed he was brave, even if he didn't call it that? | fears-comfort | 36–168 | Flips the fear lens to a courage moment, still concrete and observable. |
| What's a fear he's grown out of that you almost forgot he ever had? | fears-comfort | 60–192 | Retrospective fear question for older kids, distinct angle from 'what's changed' generic prompt. |

## Rejected

_Nothing was rejected._
