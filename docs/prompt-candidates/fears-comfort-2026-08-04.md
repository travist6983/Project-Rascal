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
| What noise in the house makes {them} look up right now? | fears-comfort | 24–96 | Concrete sensory fear detail specific to young kids, not already covered. |
| What does {name} ask you to check under or behind before {they}'ll go to sleep? | fears-comfort | 30–96 | Distinct from existing sleep-routine/fear prompts, very specific bedtime behavior. |
| What did {they} refuse to do today because {they_were} scared, even if {they} wouldn't say so? | fears-comfort | 30–144 | Captures avoidance behavior tied to fear, not duplicated elsewhere. |
| What's the one thing {name} needs in bed with {them} to fall asleep — object, not person? | fears-comfort | 24–108 | Specific comfort-object detail distinct from crying/fear prompts already in library. |
| What did {they} ask you to promise wouldn't happen? | fears-comfort | 36–144 | Captures verbal reassurance-seeking, a distinct angle from existing fear questions. |
| What's the first thing {they_do} when {they_are} scared — run to you, freeze, or something else? | fears-comfort | 24–120 | Behavioral pattern question, not yet asked in library. |
| What movie, show, or book scene does {name} ask you to skip? | fears-comfort | 36–144 | Concrete media-avoidance detail, age-appropriate for kids who watch shows. |
| What does {name} do after waking up from a nightmare? | fears-comfort | 24–132 | Distinct nighttime-fear behavior, not covered by 'what did he cry about' prompt. |
| What's a sound {they} used to be scared of that doesn't bother {them} anymore? | fears-comfort | 36–156 | Tracks growth through fear specifically, different framing from generic change prompt. |
| What does {name} think is hiding in the dark right now, if anything? | fears-comfort | 24–96 | Age-narrow, concrete imaginative-fear question for younger kids. |
| What's the thing {they} won't do alone, even though {they_are} capable of it? | fears-comfort | 48–168 | Captures independence-adjacent fear for older kids, distinct from younger comfort prompts. |
| What did {they} need you to sit with {them} through this week? | fears-comfort | 24–144 | Broad but action-based comfort question not yet in library. |
| What's a worry {they_have} brought up more than once lately? | fears-comfort | 48–180 | Captures recurring anxiety in older kids who can articulate worries. |
| What does {name} do with {their} hands when {they_are} nervous? | fears-comfort | 36–168 | Physical tell of anxiety, concrete and observable, no overlap with existing prompts. |
| What did {they} need reassurance about today that seems small to you but wasn't to {them}? | fears-comfort | 30–144 | Distinct from existing fears prompt by focusing on reassurance rather than the fear itself. |
| What's something {name} checks or counts to feel okay before doing something else? | fears-comfort | 36–132 | Captures ritual/comfort behavior, specific and observable. |
| Who does {name} ask for when {they_are} upset, if it's not you? | fears-comfort | 24–168 | Relationship-adjacent comfort question distinct from existing relationships prompts. |
| What's a place in the house {name} avoids, and did {they} ever say why? | fears-comfort | 24–96 | Very specific spatial-fear detail for young kids. |
| What did {they} do today that showed {they_were} brave, even if {they} didn't call it that? | fears-comfort | 36–168 | Flips the fear lens to a courage moment, still concrete and observable. |
| What's a fear {they_have} grown out of that you almost forgot {they} ever had? | fears-comfort | 60–192 | Retrospective fear question for older kids, distinct angle from 'what's changed' generic prompt. |

## Rejected

_Nothing was rejected._
