# Phase 17 — BLOCKED at Phase A

**Branch:** `phase-17/extraction`, stacked on `phase-16/video-audio`
**Status:** blocked. **No implementation was attempted.**

## The gate

Phase 17's preflight #6 asks one question, and Phase A makes the answer decisive:

> **Determine whether `PATCH /v1/entries/{id}` can write tags with `source = device_ai`.**
> …
> **If it does not:** stop. Write `docs/blocked.md` naming the exact endpoint change needed and
> open a draft PR. **Do not write model-generated tags as if a human chose them.** That is
> unrecoverable — once the two are indistinguishable, no future re-run can safely touch them, and
> a parent cannot tell which tags are theirs.
>
> This is a hard gate, not a preference.

## The answer: it cannot

Read from source, not inferred.

**`api/src/rascal/schemas/entry.py`**

```python
class EntryUpdate(ApiModel):
    title: str | None = None
    body: str | None = None
    occurred_at: dt.datetime | None = None
    unlock_at_age: int | None = Field(default=None, ge=0, le=120)
    tags: list[str] | None = None        # <- a bare list of names. No source, anywhere.
```

**`api/src/rascal/services/entries.py`** — both entry write paths hardcode the source:

```
line 432:  await apply_tags(session, entry, tags, "user")
line 659:  await apply_tags(session, entry, tags, "user")
```

So every tag written through `POST /v1/entries` or `PATCH /v1/entries/{id}` is recorded as
`source = 'user'`, with no way for a caller to say otherwise.

### The column exists; the API does not expose it

`entry_tags.source` is real (`TagSource = Literal["user", "device_ai"]`) and `apply_tags` already
honours it correctly — a `device_ai` write refuses to touch a row a human wrote. The gap is
purely that **no entry endpoint lets a caller name the source.**

### The one endpoint that does write `device_ai` cannot serve this phase

`PATCH /media/{id}/derived` calls `apply_tags(session, entry, tags, "device_ai")`. But it is
**keyed on a media row**, and phase 17 is deliberately scoped to *entry bodies* — text. A
text-only entry has no media, so there is no `media_id` to address, and the archive treats an
entry with no artifact as first-class by design (standing rule 4). Routing text extraction
through a media endpoint would also mean inventing a media row for an entry that has none, which
is worse than the problem it solves.

## The exact endpoint change needed

The narrowest change that unblocks this, in the API lane:

**Let a tag write carry its source.** In `schemas/entry.py`, change `EntryUpdate.tags` (and
`EntryCreate.tags`) from `list[str]` to accept either a bare string or `{ name, source }`, with
`source` defaulting to `"user"` so every existing client is unaffected:

```python
class TagWrite(ApiModel):
    name: str
    source: TagSource = "user"

tags: list[str | TagWrite] | None = None
```

Then have `update_entry` group the incoming tags by source and call the existing `apply_tags` once
per source, instead of passing the literal `"user"`. `apply_tags` already implements the
protection this phase depends on — a `device_ai` write never clobbers a `user` row — so no new
merge logic is needed.

**Alternative, if a narrower surface is preferred:** a dedicated
`PATCH /v1/entries/{id}/derived` mirroring `PATCH /media/{id}/derived`, taking
`{ tags?, summary? }` and writing `device_ai` unconditionally. This keeps model output on its own
endpoint and leaves `EntryUpdate` untouched.

Either is a Lane A change. **This phase is iOS-lane and did not make it** — the phase file scopes
the lane as "iOS only, unless preflight finds a gap", and its instruction when the gap is found is
to stop rather than to cross lanes.

## Why writing the tags anyway would have been unrecoverable

`entry_tags.source` exists specifically so a tag the parent chose can be told apart from one a
model extracted, and so extraction can be re-run without eating the parent's own. Writing
model-generated tags as `user` destroys that distinction **permanently**:

- No future re-run can safely replace them, because it cannot tell which are its own.
- A parent deleting a `device_ai` tag by hand and having it resurrect on the next run is exactly
  the behaviour phase 17 has a rule against — and it becomes unavoidable.
- The parent cannot tell which tags they wrote.

There is no migration back from that, because the information needed to undo it was never stored.

## What is not blocked

Everything else in the phase is designed and unblocked: the `@Generable` struct over
`LanguageModelSession`, the availability gate matching `TranscriptionQueue`'s posture, the sealed-
entry exclusion, and the never-touch-`title`-or-`body` rule. **None of it was written**, because
all of it terminates in a write this API cannot accept.
