---
paths:
  - "api/seeds/prompts.yaml"
  - "docs/mission-library.md"
  - "api/src/rascal/services/seeding.py"
---

- **The seeded library is tokenised.** ~~All **133** bodies carry the pronoun tokens~~ — **struck
  Aug 25, 2026 by phase 122.** **119** of the **133** carry a `{token}`, and the other fourteen
  correctly carry none, because they never refer to the child in the third person: *"What song
  is stuck in the house right now?"*, *"Take a photo of the two of you. You're in almost none of
  them."* Run it rather than quoting it: `grep -c '^  body: ' api/seeds/prompts.yaml` prints
  **133**, `grep '^  body: ' api/seeds/prompts.yaml | grep -c '{'` prints **119**, and
  the **Prompt library** row of `docs/roadmap-status.md`'s facts table has carried the measured
  form since Aug 18, 2026 — *"119 of the 133 carry a `{token}`"*. 113 were
  tokenised in phase 24 and phase 25 added twenty more already tokenised, so *"113"* has been the
  wrong **total** since Aug 14, 2026 — but *how many bodies there are* and *how many carry a token*
  are two different numbers, and this line ran them together while narrating the first one's
  history. **The loader does not require a token; it rejects an unrecognised one.**
  `constants.PROMPT_TOKENS` is the list and the seed loader rejects a body containing anything
  else (`api/src/rascal/services/seeding.py:109-114`) — which is why a body with no braces at all
  passes untouched, and why **the fourteen are not a backlog: do not go inserting tokens into
  them.** Edit `docs/mission-library.md` and regenerate; never touch `prompts.yaml` by
  hand. Re-seeding keys idempotency on `sha256(kind, cadence, body)`, so **an edited body is a
  new prompt, not an update** — `seed_prompts` deactivates the seeded rows the file no longer
  contains, which is what keeps the old and new copies from both serving.
