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
