# RASCAL — API Contract

Plain JSON over HTTPS. No client-specific serialization anywhere in the wire format — this is the insurance policy for a web client later.

Base: `/v1`. Auth: bearer token. All timestamps ISO 8601 UTC. All IDs UUID.

Last updated: **Aug 3, 2026** — build-ready.

---

## Health

**`GET /health`** → `{ "status": "ok", "db": "ok" }`

Unauthenticated. The only route outside `/v1`. Fly's health check hits this; it touches
the database so a green check means the app can actually serve.

---

## Auth

**`POST /auth/apple`**
Body: `{ identity_token, authorization_code, display_name? }`
Exchanges an Apple credential for a session. Creates a `users` row on first sight, then a `credentials` row. Returns `{ access_token, refresh_token, user }`.

Verification is real: fetch Apple's JWKS, verify the signature, check `iss`, `aud`
against the bundle ID, and `exp`. Cache the JWKS with a TTL; don't fetch it per request.

**`POST /auth/refresh`**
Body: `{ refresh_token }` → `{ access_token, refresh_token }`

Rotating. The presented token is revoked and a new pair issued. A revoked token presented
again is a 401 with code `refresh_token_reused`.

**`POST /auth/logout`** — revokes the presented refresh token.

**`POST /auth/dev-login`** — **registered only when `ENVIRONMENT == "local"`.** Creates or
returns a fixture user plus a token pair, so the iOS client and curl can hit the API
before Apple Developer enrollment clears. This route must not exist in a production build,
and there's a test that asserts it.

Access tokens live 15 minutes. Refresh tokens live 30 days.

Later: `POST /auth/password` and `POST /auth/google` slot in with no schema change. That's the point.

### Authorization

Every child-scoped route resolves the child and checks `guardians` for a non-revoked row
with sufficient role — `parent` reads and writes, `viewer` reads only. This lives in **one
FastAPI dependency**, not in handler bodies. Routes that reach a child indirectly (an
entry id, a media id, an assignment id) resolve the owning child and run the same check.

Failure is `403` with code `not_authorized`. Never `404` — leaking existence is fine here
and a wrong 404 sends me debugging the wrong thing.

---

## Children

**`GET /children`** → children the caller can see, with `role` on each.

**`POST /children`**
Body: `{ name, birthdate, family_timezone }` → creates the child and a `parent` guardian row for the caller.

**`PATCH /children/{id}`** — name, birthdate, timezone, avatar.

**`POST /children/{id}/guardians`**
Body: `{ email, role }` → creates an invite. P2.

**`GET /children/{id}/export`** — parent only → `application/zip`.

The whole archive, in a format that outlives this API:

```
manifest.json            format version, child, counts, media that could not be fetched
entries.json             every entry, oldest first, with its prompt, tags, and media rows
media/YYYY/MM/<id>.<ext> the objects themselves, foldered by occurred_at
```

- **Soft-deleted rows are included** and carry `is_deleted: true` with a `deleted_at`. An
  export that quietly drops them is not a copy of the archive.
- **Sealed letters export in the clear.** `unlock_at_age` is retained as data; the seal is
  an app behaviour, and an export you cannot read is not a backup.
- A media row whose bytes are not in S3 keeps its metadata, gets a null `path`, and is
  listed in `manifest.missing_media`. One dead upload does not fail the export.
- Response headers `x-rascal-export-entries`, `-media`, `-missing-media` summarise the run;
  `content-length` is exact, so a client can show real progress.

The zip is assembled on disk and streamed back, so memory is bounded regardless of size.

---

## Today

**`GET /children/{id}/today`**

The single call the home screen makes. Returns everything the Today screen renders:

```json
{
  "date": "2026-08-14",
  "child": { "id": "...", "name": "Miles", "age_months": 50 },
  "today": [
    { "id": "...", "slot": "mission", "body": "Record him telling you a story...",
      "kind": "audio", "completion_mode": "media", "theme": "voice",
      "status": "pending", "expires_on": "2026-08-28" },
    { "id": "...", "slot": "question", "body": "What did he say this week...",
      "kind": "question", "completion_mode": "text", "theme": "his-words",
      "status": "pending", "expires_on": "2026-08-28" }
  ],
  "waiting": [ ... ],
  "done_today": [ ... ]
}
```

`waiting` is pending assignments from previous days, oldest first. `done_today` is anything completed with `occurred_at` today.

**`POST /assignments/{id}/dismiss`** → `status = dismissed`.

**`POST /assignments/{id}/custom`**
Body: `{ body }` — replaces today's assignment with a parent-authored one. Keeps the slot filled.

---

## Entries

**`POST /entries`**
Body:
```json
{
  "id": "client-generated-uuid",
  "child_id": "...",
  "assignment_id": null,
  "occurred_at": "2026-08-14T18:22:00Z",
  "title": null,
  "body": "He called it a 'hangaburger' again.",
  "entry_type": "text",
  "unlock_at_age": null,
  "tags": ["his-words"]
}
```
Header: `Idempotency-Key: {uuid}`. Retries are safe — a replay returns the original `201`
body byte-for-byte, never a second row and never a `409`. The key is scoped to the user.

Server computes and stores `child_age_months` from `occurred_at` minus birthdate. If
`assignment_id` is set and the assignment is pending, it flips to `done` in the same
transaction.

`entry_type` is **derived server-side and any value sent is ignored.** It describes what the
entry is, resolved in this order:

1. Media attached → the media kind (`photo` / `video` / `audio`), first attached wins.
2. Else the entry completes an assignment whose prompt is `completion_mode: did_it` →
   `did_it`. A note on "get on the floor for ten minutes" does not make it a text entry.
3. Else any `title` or `body` → `text`. A title is written content.
4. Else → `did_it`.

Recomputed on `POST /media/{id}/complete`, since media lands after the entry exists. A
freeform entry has no assignment and so falls through to (3)/(4). What was asked is still
reachable through `assignment_id` → `prompt.kind`. The values are `photo`, `video`, `audio`,
`text`, `did_it`.

Deleting an entry releases its assignment back to `pending` unless another live entry still
completes it, so "wrong photo, redo it" puts the mission back on the Today screen. If the assignment is already `done`, `dismissed`, or `expired`, the entry
still saves — the archive matters more than the bookkeeping — and the assignment is left
alone.

**`GET /entries`**
Query: `child_id`, `before`, `after`, `type`, `tag`, `q`, `limit`, `cursor`.
Returns entries newest-first by `occurred_at`, with media summaries inline (thumb keys, counts, durations) so the timeline renders without N+1 calls.

Cursor is opaque and encodes `(occurred_at, id)` — keyset pagination, not `OFFSET`.
Backdating inserts rows into the middle of the order, and offset paging would skip them.
`limit` defaults to 50, caps at 200. Soft-deleted entries are excluded here.

### `q` — full-text search

Passing a non-blank `q` switches this endpoint from the timeline to search. Everything else
about it is unchanged: same response shape, same filters, same guardian check, same
`deleted_at IS NULL`.

**What it searches.** Postgres full-text over four fields, with these weights:

| Weight | Field | Why |
|---|---|---|
| A | `entries.title` | A word in the title you chose is the strongest signal there is. |
| B | `entries.body`, `media.transcript` | What was written, and what was said out loud. |
| C | `media.caption` | Machine-written, so it never outranks a person. |

`media.transcript` is what makes this matter: the phone transcribes on device, `PATCH
/media/{id}/derived` persists the words, and from that moment they are findable from
anything that speaks HTTP — including the browser in 2027 that will never have an on-device
model. A media row with `deleted_at` set stops matching.

**How queries are parsed.** `websearch_to_tsquery`, so:

- Bare words are ANDed: `moon car` needs both.
- `"exact phrase"` in double quotes matches in order.
- `-word` excludes.
- Punctuation is never a syntax error. `(((` is a search for nothing, not a 500.

**Words are stemmed, not lemmatised.** `run` finds `running` and `runs`; it does not find
`ran`. There is no prefix matching — `hangab` finds nothing, `hangaburgers` finds
`hangaburger`. This is search-on-submit, not search-as-you-type. A query of nothing but
stopwords (`the and of`) returns zero results, which is the honest answer.

**Ordering and paging.** Best match first, then newest first among equal scores — rank ties
are the common case, so `occurred_at` and `id` are what make a page boundary stable. The
cursor encodes `(rank, occurred_at, id)`. **A cursor from the timeline is not valid in
search and vice versa**; passing one across returns `422 validation_failed` rather than a
quietly wrong page.

No snippet is returned. `title` and `body` come back in full, so the client marks up its own
highlight rather than being handed HTML in a JSON API.

**`GET /entries/{id}`** — full detail including all media, transcripts, tags, and the originating prompt.

**`PATCH /entries/{id}`** — title, body, occurred_at, unlock_at_age, tags.

**`DELETE /entries/{id}`** — soft delete. Sets `deleted_at`, keeps the row.

---

## Media

Three-step upload. The server never proxies bytes.

**`POST /media/upload-url`**
Body: `{ entry_id, kind, filename, bytes, content_type }`
→ `{ media_id, upload_url, parts?, s3_key }`

Single presigned PUT under ~15MB; presigned multipart above that. Video always assumes multipart.

**Client uploads directly to S3** on a background `URLSession`. This survives app backgrounding and cellular flakiness, which matters more than anything else in the capture path.

**`POST /media/{id}/complete`**
Body: `{ etags?, captured_at, duration_seconds? }`
Server marks `upload_status = complete`, kicks off thumbnail and poster-frame generation.

**`PATCH /media/{id}/derived`**
Body: `{ transcript?, caption?, tags? }`
**This is the on-device AI write-back endpoint.** The phone transcribes locally, then persists the text here so search works everywhere — including from a browser that will never have an on-device model.

Tags written here get `entry_tags.source = 'device_ai'`. They never overwrite or delete a
row with `source = 'user'` — re-running extraction must be free, and it must never eat a
tag I typed. Idempotent: sending the same transcript twice changes nothing.

---

## Moments

**`GET /children/{id}/moments`**
Query: `date` (defaults today)
Returns entries from this month/day in prior years, grouped by years-ago. If empty, returns `{ "fallback": "random", "entries": [...] }` so the client can render the warm redirect instead of a void.

---

## Sync

**`GET /sync?child_id={id}&since={cursor}`**

```json
{
  "entries": [...],
  "media": [...],
  "assignments": [...],
  "tags": [...],
  "cursor": "2026-08-14T18:22:00.481Z"
}
```

Every entity carries `updated_at` and `deleted_at`. Deletions arrive as rows, never as absences — a client can't infer a delete from a missing record.

**The cursor is deliberately behind, and clients must upsert by id.** It comes back as
`max(updated_at) - 30 seconds`, so a pull will re-deliver rows the client has already seen.
That is not a bug to work around — it is the fix for one.

`set_updated_at()` uses Postgres `now()`, which is *transaction-start* time, not commit
time. A transaction that opens, takes a while, and commits therefore writes a row whose
`updated_at` is already behind a cursor another device advanced past in the meantime — and
that row would never appear in a sync again. Lagging the cursor by a window wider than any
write transaction closes the hole.

Re-delivery is free, which is what makes this the right trade: entries are last-write-wins
and keyed on a client-generated UUID, so applying the same row twice is a no-op. **A client
that treats every returned row as new will duplicate data.** Upsert by id.

The window bounds the longest write transaction. A `POST /sync/push` batch has to stay well
under 30 seconds; if batch push ever grows past that, this window grows with it. A
sequence-based cursor is *not* the alternative — `nextval()` is assigned at statement time,
not commit time, so a `bigint` sequence has the identical race and costs a migration and a
column on four tables.

**`POST /sync/push`**
Body: `{ entries: [...], media: [...], idempotency_keys: {...} }`
Batched offline queue drain. Returns per-record accept/conflict so the client can reconcile without a full refetch.

---

## Prompts (admin, me only)

**`GET /prompts`** — filterable by kind, theme, age band, source. Any authenticated caller.
**`POST /prompts`** — hand-authored additions. **Requires `users.is_admin`**; anyone else
gets `403 not_authorized`. The library is content every child draws from, so a `viewer`
login must not be able to write to it. `dev-login`'s fixture user is an admin.
**`POST /prompts/batch-review`** — accept/reject LLM-generated candidates sitting in the review queue.

The library is content. It's authored and reviewed server-side, never generated at request time and never authored on-device.

---

## Debug (local only)

Registered only when `ENVIRONMENT == "local"`, same gating as `dev-login`. These exist
because building the daily loop means running the daily loop dozens of times in one
evening, and waiting until 5am tomorrow is not a development strategy.

**`POST /debug/scheduler/run`**
Body: `{ date, child_id? }` → runs the full scheduler for an arbitrary date. Idempotent,
same as the real job.

**`POST /debug/reset-today`**
Body: `{ child_id, date? }` → deletes today's assignments for that child so the scheduler
can be re-run against a changed prompt library.

---

## Error shape

```json
{ "error": { "code": "assignment_expired", "message": "...", "field": null } }
```

Stable machine-readable `code`, human `message`. The client switches on `code`, never on message text. Codes live in one enum server-side; adding one is a deliberate act.

| Code | Status |
|---|---|
| `unauthenticated` | 401 |
| `token_expired` | 401 |
| `refresh_token_reused` | 401 |
| `not_authorized` | 403 |
| `not_found` | 404 |
| `validation_failed` | 422 |
| `assignment_expired` | 409 |
| `upload_incomplete` | 409 |
| `conflict` | 409 |
| `internal_error` | 500 |

Validation failures set `field`. Nothing ever returns a stack trace or a raw SQL error —
a `psycopg` message in a client alert is a leak, not a debugging aid.
