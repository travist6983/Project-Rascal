# Prompt candidates — `me-as-a-parent` · `question`

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
| What did you do today that you'd do differently if you could rewind ten minutes? | me-as-a-parent | 24–216 | Concrete daily self-audit, not sentimental. |
| What's the excuse you gave {them} today that wasn't really the truth? | me-as-a-parent | 24–216 | Specific admission an ordinary parent can name in seconds. |
| What did you say to {them} today that you also heard your own parent say? | me-as-a-parent | 24–216 | Concrete generational-echo moment, no feeling-words. |
| What's something {they} asked you to stop doing? Did you stop? | me-as-a-parent | 36–216 | Requires verbal negotiation, so excludes very young toddlers. |
| What time did you actually put your phone down today, and what were you doing with {them} instead? | me-as-a-parent | 24–216 | Doable Tuesday self-check with a concrete answer. |
| What did you do for {them} today that nobody saw or thanked you for? | me-as-a-parent | 24–216 | Invisible-labor prompt anchored in a specific act. |
| What's a question {they} asked today that you dodged instead of answering? | me-as-a-parent | 36–216 | Needs a child old enough to ask real questions. |
| What did you let slide today that you would have corrected last year? | me-as-a-parent | 24–216 | Concrete comparison over time, no plans or outings required. |
| What's the last thing you Googled about parenting {them}, and did you find an answer? | me-as-a-parent | 24–216 | Very specific, verifiable, ordinary-Tuesday behavior. |
| What did you compare {them} to today — another kid, a sibling, yourself at that age? | me-as-a-parent | 24–216 | Names a specific habit parents actually do without moralizing. |
| What's a chore or responsibility you keep meaning to hand to {them} and haven't? | me-as-a-parent | 48–216 | Requires a child old enough for chores, narrows the band. |
| What did you overhear {them} say about you today, on purpose or by accident? | me-as-a-parent | 36–216 | Needs verbal child, distinct from existing their-words prompts about the child's own speech. |

## Rejected

_Nothing was rejected._
