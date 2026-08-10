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
   `deleted_at` set, never as absences.
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
- The seeded library is written he/him **on purpose, for now** — see `docs/decisions.md` open
  item 10. Do not bulk-rewrite it, and do not write *new* copy that assumes a child's gender.
  Client-side strings are already neutral and stay that way.

## Stack (settled — do not substitute)

Python 3.12 · FastAPI · SQLAlchemy 2.0 (`Mapped`/`mapped_column`) · Alembic · Pydantic v2 +
pydantic-settings · Postgres (Neon in prod, Docker locally) · boto3 · uv · pytest +
pytest-asyncio + httpx · ruff · Fly.io.

## Out of scope for the API lane — stop if you find yourself designing one

Swift or iOS code (that is the other lane, not this one), push notifications, full-text
search, thumbnail or transcode pipelines,
LLM prompt generation, the guardian invite flow, the admin prompt review queue, a web
frontend, multi-kid UI concerns, rate limiting, observability beyond structured logging.

## Working here

`cp .env.example .env && make up && make migrate && make seed && make test`. Judgment calls
go in `docs/decisions-log.md`, one line each. Anything blocked on a credential goes in
`docs/blocked.md`.
