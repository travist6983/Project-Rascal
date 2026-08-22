# Prompt candidates — `physical-affection` · `audio`

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
| Record the sound {they} make when you pick {them} up. | physical-affection | 24–72 | Captures a physical-affection sound specific to carrying a young child, not yet in library. |
| Ask {them} for a hug and record what {they} says while {they_are} doing it. | physical-affection | 24–96 | Voice during affectionate contact, distinct from existing hug-related activity prompt. |
| Record {them} narrating a tickle fight while it's happening. | physical-affection | 24–84 | Specific ordinary physical play moment captured through sound. |
| Ask {them} to describe what a hug feels like. Record the answer. | physical-affection | 48–144 | Verbal reflection on physical affection, age-appropriate for kids who can articulate sensation. |
| Record {them} calling out to you from another room, the way {they_do} when {they} wants to be found. | physical-affection | 24–96 | Captures a specific vocal bid for closeness unique to younger children. |
| Record the noise {they} makes right before {they} falls asleep against you. | physical-affection | 24–60 | Very specific sound tied to physical closeness in early childhood. |
| Ask {them} what {their} favorite kind of hug is and record the explanation. | physical-affection | 36–132 | Distinct from other hug prompts by asking for a taxonomy of hug types. |
| Record {them} saying goodnight through the door after you've already said it once. | physical-affection | 36–144 | Captures a specific bedtime affection ritual through sound. |
| Record the sound of {them} running to greet you at the door. | physical-affection | 24–96 | Distinct from the existing video 'running toward you' prompt by capturing audio only, no visual, different sensory artifact. |
| Ask {them} to describe {their} favorite person to be held by, and record the answer. | physical-affection | 36–120 | Reflective audio prompt about affection preferences, appropriate mid-childhood. |
| Record {them} groaning about a hug lasting too long. | physical-affection | 72–168 | Captures the shift toward embarrassment about affection in older kids, a distinct developmental beat. |
| Record {them} saying what {they_do} miss about being carried, if {they_do} miss it. | physical-affection | 96–192 | Reflective prompt for older children looking back on physical affection from earlier childhood. |

## Rejected

_Nothing was rejected._
