# Prompt candidates

Worksheets. Each file in this folder is one batch of machine-generated candidates waiting to
be read, and every one of them is meant to be **deleted** once it has been.

Nothing here is live. Nothing here is seeded. `api/seeds/prompts.yaml` is generated from
`docs/mission-library.md` and from nothing else, and the seed loader has never heard of this
folder.

## Where they come from

```
uv run python scripts/generate_prompts.py --thinnest 4        # the four thinnest themes
uv run python scripts/generate_prompts.py --theme fears-comfort --kind photo --count 20
```

Or the **Prompt candidates** workflow in Actions, which runs the same script and opens a pull
request with the result.

Both need `ANTHROPIC_API_KEY`. Without it the script says so and exits cleanly.

## Why a pull request and not a review queue

`docs/mission-library.md` asks for candidates to land "in a review queue you approve", and
`docs/api-contract.md` used to carry a `POST /prompts/batch-review` for approving them. Both
described a thing that already exists: a branch with a diff is an accept/reject interface
with a comment thread, an audit trail, and an undo, and it costs no table, no admin screen,
and no endpoint. So the queue is a PR, and `POST /prompts/batch-review` is gone from the
contract rather than deferred in it.

The trade is real and worth naming: reviewing on a phone means reviewing in the GitHub app,
which is worse than a purpose-built screen would be. It is not worse enough to justify
building the screen.

## The four Aug 4 batches were tokenised on Aug 18, before anybody read them

**Read this before reviewing them.** They were generated on Aug 4 and the library was tokenised on
Aug 13, so all four batches were written in literal `he/him/his` — which meant that approving a row
approved copy that could not be seeded. 79 of the 80 rows carried a gendered word. Rewriting them
first was cheaper than approving them twice.

Every Prompt cell now uses the thirteen tokens, and all 80 render clean in he/him, she/her, they/them
and null — 320 renderings, no surviving brace, no invented token, no subject-verb disagreement, no
literal gendered word left. `{name}` appears at most once per body, per the library's own rule.

**Three things were deliberately NOT fixed, because they are copy edits rather than tokenisation, and
they are yours to judge.** They predate the rewrite and all three are in `sleep-routine`:

- *"What did he ask for a glass of water, a hug, or a check for monsters tonight?"* — ungrammatical
  as generated, in every pronoun column. It is missing a dash after "for". Two independent reviewers
  called it the worst row in the batch.
- *"...has to be in the bed tonight"* — should be "in bed" or "in the bed with them". This is the one
  row of the 80 that contains no token at all, so it never refers to the child.
- *"...doing lately — reading, a screen, talking to {themself}"* — the list is not parallel; the
  flanking items are gerunds and the middle one is a noun.

**The `Why` column still says "he" in eight cells.** That is intentional: the rewrite was scoped to
the Prompt column, `Why` is reviewer scaffolding, and step 5 deletes the file. But if you paste a
`Why` into a commit message, tokenise it as you go.

**One known cost, decided and not a defect.** `{they_are}` and `{they_have}` have no contracted
forms, so they render *"she is scared"* and *"he has a phone"* where a person would say *"she's"* and
*"he's"*. It is slightly stilted across sixteen rows. Adding `{they_re}` and `{they_ve}` would widen
a wire contract three clients implement, which the library rejects explicitly — so this stays.

## Reviewing one

1. Delete the rows you do not want. Leave the ones you do.
2. Move the survivors into the right table in `docs/mission-library.md`.
3. `uv run python scripts/mission_library_to_yaml.py`, then `make seed`.
4. `api/tests/test_seeding.py` asserts the coverage table at the bottom of the library. It
   will fail and hand you the corrected numbers.
5. Delete the candidate file in the same commit.

The generator filters what it can — the four rejection rules in the library's "Expanding the
library" section, plus near-duplicates — and shows you what it rejected and why. Those
filters are a spam trap, not an editor. Everything that survives them still needs reading.
