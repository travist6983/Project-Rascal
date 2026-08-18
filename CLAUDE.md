# RASCAL — standing rules

A native iOS app that archives a child's childhood one daily prompt at a time. This repo
holds both halves: the backend in `api/` and the iOS client in `ios/`. `docs/` holds the
specs and they are authoritative: `docs/data-model.md` (schema), `docs/api-contract.md`
(endpoints), `docs/decisions.md` (settled — do not relitigate), `docs/mission-library.md`
(seed prompts), `docs/memory-app-roadmap.md` (scope).

If the code and `docs/data-model.md` disagree, the code is wrong.

## DO NOT COMMIT ANYTHING WITHOUT ASKING FOR PERMISSIONS 

## Two lanes

`api/` and `ios/` are separate lanes that share a repo, not a codebase. An agent working in
`ios/` never edits `api/`; an agent working in `api/` never edits `ios/`. `docs/` is shared
and either lane may read it — but a change to `docs/api-contract.md` is an API-lane change.

The rest of this file is the API lane. The iOS lane's rules are in `ios/CLAUDE.md`. CI is
scoped by path so a commit in one lane never runs or deploys the other.

## The rules. Violating any of these is a defect.

1. **The server owns the schedule.** Assignment, expiry, and "what day is it" are
   server-computed in the child's `family_timezone`. Never client-computed.
2. **Sign in with Apple is a credential row, not the identity model.** `users` has a stable
   UUID; Apple is one row in `credentials`. Adding password or Google auth later must
   require zero schema changes.
3. **`occurred_at` and `created_at` are never conflated.** Backdating is a first-class flow.
   Timeline sorts by `occurred_at`; sync filters on `updated_at`.
4. **Three completion shapes:** `did_it`, `media`, `text`. Nothing in the schema or the API
   may assume an entry has media. "Get on the floor for ten minutes" is a complete,
   legitimate entry with no artifact.
5. **Soft deletes and `updated_at` on every user-data table.** Deletions sync as rows with
   `deleted_at` set, never as absences. **One deliberate exception, added by phase 66 on Aug 17,
   2026: account deletion hard-deletes.** A request sits in `deletion_requests` for seven days and
   then the user's data is destroyed, because a soft delete on an erasure would be the service
   keeping exactly what it was asked to stop keeping — and there is no client left to tell. The
   exception is documented in `data-model.md`'s `deletion_requests` section and is the only one;
   **every other table still obeys this rule, and adding a second exception is a decision, not a
   precedent you already have.**
6. **Plain JSON over HTTPS.** No Swift-specific serialization anywhere in the wire format. A
   browser will consume this API in 2027.
7. **On-device AI output is durable data.** `PATCH /media/{id}/derived` persists transcripts
   and captions written back from the phone. The server never regenerates them.
8. **No TODOs.** Every function is finished. No `pass  # implement later`, no stub returning
   fake data, no commented-out branches.

## Conventions that follow from those rules

- Constrained-value columns are `text` + a named `CHECK` constraint, never Postgres enums.
- `updated_at` is maintained by the `set_updated_at()` Postgres trigger, never by
  application code. Application code that sets `updated_at` is a bug.
- Every index and constraint is explicitly named, so migrations can reverse cleanly.
- Authorization lives in `deps.py` (`current_user`, `child_access`). Never hand-roll an
  ownership check inside a handler. Routes reaching a child indirectly — through an entry,
  media, or assignment id — resolve the owning child and run the same dependency.
- Every read path filters `deleted_at IS NULL` except `/sync`, which must return deleted rows.
- UUIDs are client-generated for `entries` and `media`, server-generated everywhere else.
- Errors are raised as `RascalError` and rendered by the one handler in `errors.py`:
  `{"error": {"code": ..., "message": ..., "field": ...}}`. Codes are the `ErrorCode` enum.
  Never leak a stack trace or a raw SQL error.
- `dev-login` and every `/debug/*` route are registered only when `ENVIRONMENT == "local"`.
- Prompts are seeded from `api/seeds/prompts.yaml`. `docs/mission-library.md` is the
  authoring surface; runtime never parses markdown.
- **The seeded library is tokenised.** All **133** bodies carry the pronoun tokens — 113 were tokenised in phase 24 and phase 25 added twenty more already tokenised, so *"113"* has been the wrong count since Aug 14, 2026;
  `constants.PROMPT_TOKENS` is the list and the seed loader rejects a body containing anything
  else. Never write copy that assumes a child's gender — client-side strings are neutral too and
  stay that way. Edit `docs/mission-library.md` and regenerate; never touch `prompts.yaml` by
  hand. Re-seeding keys idempotency on `sha256(kind, cadence, body)`, so **an edited body is a
  new prompt, not an update** — `seed_prompts` deactivates the seeded rows the file no longer
  contains, which is what keeps the old and new copies from both serving.

## Stack (settled — do not substitute)

Python 3.12 · FastAPI · SQLAlchemy 2.0 (`Mapped`/`mapped_column`) · Alembic · Pydantic v2 +
pydantic-settings · Postgres (Neon in prod, Docker locally) · boto3 · uv · pytest +
pytest-asyncio + httpx · ruff · Fly.io.

## Out of scope for the API lane — stop if you find yourself designing one

Swift or iOS code (that is the other lane, not this one), thumbnail or transcode pipelines,
LLM prompt generation, the admin prompt review queue, multi-kid UI concerns, observability
beyond structured logging.

~~*push notifications, full-text search*~~ — **both removed from this list Aug 18, 2026, because
both are built and served in `api/`.** Push: `services/notifications.py`, `jobs/notify.py`, the
`devices` and `notification_sends` tables, and a scheduled machine that has delivered to a real
locked phone. Full-text search: migration `0004_full_text_search`, the generated `search_vector`
columns on `entries` and `media`, two GIN indexes, and `GET /entries?q=` which the contract
documents as *"full-text search over title, body, caption, and transcript"*. **An out-of-scope
list that names shipped subsystems is worse than no list**: it reads as permission to remove
working code, and it is the sentence an agent quotes when it deletes something.

**Rate limiting is out of scope for routes that only touch the caller's own data, and
required for any route that can reach somebody else.** A signed-in parent hammering their own
archive is a support conversation, not an attack.

Two routes qualify, and the second is why this is not simply "unauthenticated endpoints".
`POST /auth/email/start` is unauthenticated and mails an address a stranger chose.
`POST /me/credentials/email` is *authenticated* and mails an address the account does not own
and has not proved anything about — so without a limit, anyone who can create a free account
can use it, and our sending reputation, to mail a stranger repeatedly.

The limit lives in the app rather than at the edge because an edge limiter cannot see the
address: it is inside the request body. It is Postgres-backed because there is more than one
Fly machine, so an in-memory counter is per-process theatre.

**`POST /v1/subscribe` deliberately has none**, and that is not an oversight in the rule above:
Turnstile is the whole protection there, by the owner's call of Aug 16, 2026, and it fails
closed. See `decisions.md` open item 12(1).

**A web frontend is no longer out of scope in the sense this line meant.** There is no web
*client* for the archive and there is not going to be one soon — but the marketing site is a
browser calling this API, so CORS, `MARKETING_ORIGINS` and `POST /v1/subscribe` are all API-lane
concerns now. What stays out of scope is serving HTML for the product itself, per D7.

## Working here

`cp .env.example .env && make up && make migrate && make seed && make test`. Judgment calls
go in `docs/decisions-log.md`, one line each. Anything blocked on a credential goes in
`docs/blocked.md`.

**Every discrete unit of work gets a phase number, including docs-only work.** Numbers come from
`docs/roadmap-status.md` and are **read from the file, never inferred** — not from memory, not by
adding one to the highest integer in sight, and not from whatever a prompt happens to say.

**A phase number is an identifier, not a position in a queue.** A lower number does not run first,
and phases are executed in whatever order makes sense at the time. Nothing is renumbered or
reordered to make the sequence read as an execution order. The existing collisions at 3, 11, 19 and
20 stay exactly as they are.
