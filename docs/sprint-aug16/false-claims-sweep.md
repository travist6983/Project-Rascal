# Phase 72 — the false-claims sweep

Commissioned Aug 17, 2026 by the owner, after story 5 found that a privacy page had been
describing a system that no longer existed. **The question this sweep asks is not "is the code
right" but "is what we have written down still true"** — and it was run because story 5's first
pass fixed two pages and missed six, which is the shape of the mistake worth generalising from.

## What was checked, and how

Three surfaces, each with a mechanical check rather than a reading:

1. **`docs/api-contract.md` against the routes actually served.** The served set was taken from
   the app's own OpenAPI schema, not from a grep of decorators, so nothing conditionally mounted
   could hide. Both sides were normalised for the `/v1` prefix and parameter naming before
   diffing.
2. **`docs/data-model.md` against the tables actually declared.** Every `__tablename__` in
   `models/` was checked for a corresponding entry.
3. **Absolute retention claims across `docs/` and the iOS user-facing strings**, since phase 66
   shipped account deletion and that is precisely the change that turns a true absolute false —
   the same defect class story 5 found on the marketing site.

## Findings

### 1. "Nothing is deleted in this system" — false since phase 66

`api-contract.md:492`, in the `recompute-ages` section. **Phase 66 made this false**:
`POST /me/deletion` hard-deletes rows and storage objects seven days after a parent asks.

The claim was also doing less work than it appeared to. What that paragraph actually needs is
that *this endpoint* deletes nothing, which is true and unaffected. Narrowed to the load-bearing
claim, with the old wording and the date recorded.

**This is the exact class story 5 found**, now confirmed to have reached a second surface. An
absolute written before a feature exists does not announce itself when the feature ships.

### 2. `POST /children/{id}/guardians` — a route that never existed

`api-contract.md:502`, written in the present indicative with a request body, so it reads as
shipped. **There is no such route and there never was.** Guardians are invited through
`POST /families/me/invites`, built in phase 36.

This is worse than a stale sentence: `CLAUDE.md` names this file authoritative and story 3b's
gate 2 says to build against the contract rather than a prompt file. **A client written from the
contract would call a 404** — and the iOS client did not, only because phase 63 was built against
the shipped API instead.

Struck rather than deleted, with the reason the shape changed: an invite belongs to the household,
not to one child, because a second parent joins a family and gets every child in it.

### 3. `POST /debug/board` — served but undocumented

The only route in the service missing from the contract. Local-only, and its two siblings
(`/debug/scheduler/run`, `/debug/reset-today`) were both documented, so this was an omission
rather than a policy. Now documented.

## What was checked and found sound

- **Every table in `models/` is documented in `data-model.md`** — all 21, no gaps. Including
  `deletion_requests`, which phase 66 added and documented in the same pass.
- **Three of the four documented-but-unserved routes were already honest.**
  `GET /families/{id}/entitlement` and `POST /webhooks/app-store` are both written in the
  subjunctive — *"**Would** return…"*, *"**Would** accept…"* — which is a deliberate and effective
  way to describe something unbuilt. `POST /prompts/batch-review` is explicitly negated: *"There
  is no `POST /prompts/batch-review`, and there is not going to be."* These were flagged by the
  crude route-name diff and cleared on reading. **A tool that only diffs names cannot tell a lie
  from a plan**, which is why every hit was read before being called a finding.
- **The iOS "forever" strings are not this defect.** "a zip you can keep forever" is about a file
  the parent now owns, which is true and unaffected by anything server-side. "it lasts forever" on
  the welcome screen is product voice, not a retention promise.
- **`data-model.md:737` and `mission-library.md:309`** both use "never deleted" in properly
  scoped senses — a specific timer, and prompts being deactivated rather than removed because rows
  still point at them. Both true.

## After the sweep

The route diff now comes back **clean in both directions**: nothing served is undocumented, and
every documented-but-unserved route is explicitly marked unbuilt.

## The generalisation worth keeping

Story 5 and this sweep found the same thing twice on different surfaces: **the claims that go
false are the absolute ones, and they go false when a feature ships rather than when the sentence
is written.** Nothing flags them, because nothing links a new `DELETE` path to a sentence written
months earlier promising the opposite.

The cheap defence is not to write fewer absolutes — some of them are the product — but to run
this diff after any phase that adds a destructive operation. It took one command per surface.
