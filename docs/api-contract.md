# RASCAL — API Contract

Plain JSON over HTTPS. No client-specific serialization anywhere in the wire format — this is the insurance policy for a web client later.

Base: `/v1`. Auth: bearer token. All timestamps ISO 8601 UTC. All IDs UUID.

Last updated: **Aug 9, 2026** — build-ready.

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

**`POST /auth/dev-login`** — **development only.** Registered only when
`ENVIRONMENT == "local"`. Creates or returns a fixture user plus a token pair, so the iOS
client and curl can hit the API before Apple Developer enrollment clears.

Body — both fields optional, so `{}` is a valid request:

```json
{ "email": "dev@rascal.local", "display_name": "Dev Parent" }
```

Returns `200` with the same `SessionResponse` shape as `/auth/apple`:

```json
{
  "access_token": "eyJ...",
  "refresh_token": "…",
  "token_type": "bearer",
  "expires_in": 900,
  "user": {
    "id": "uuid",
    "email": "dev@rascal.local",
    "display_name": "Dev Parent",
    "is_admin": true,
    "created_at": "2026-08-08T00:00:00Z"
  }
}
```

Three things a client must not get wrong:

- **The credential row is `provider = "password"`, `subject_id = <email>`** — not `apple`.
  The fixture account is a password credential that no password can currently satisfy, so
  swapping to Sign in with Apple later produces a *different* user, not the same one.
- **It is idempotent by email.** The same `email` returns the same `users` row; a different
  one creates a second account. It also force-sets `is_admin = true` on every call, so the
  fixture account can seed the prompt library without a second privileged login.
- **It returns no child, and no child id.** There is no child in the response body and
  nothing in `POST /auth/dev-login` creates one. Get the child with `GET /children` and read
  `[0].id`. On a freshly migrated database that array is **empty** — `make seed` loads
  prompts only, never a child — so create one first with `POST /children`
  (`{ name, birthdate, family_timezone }`).

**Production behaviour.** The route is not merely refused in production, it does not exist:
`main.py` mounts `auth.dev_router` inside `if settings.is_local`, so with `ENVIRONMENT=prod`
the path is absent from the app and from `/openapi.json`, and any call returns `404`.
`api/tests/test_auth.py::test_dev_login_is_not_registered_outside_local` asserts that, and
`.github/workflows/smoke.yml` re-asserts it against the deployed API on every run.

Access tokens live 15 minutes (`expires_in: 900`). Refresh tokens live 30 days.

Later: `POST /auth/password` and `POST /auth/google` slot in with no schema change. That's the point.

---

## Me

**`GET /me`**
→ the same user object `POST /auth/apple` returns, for the account behind the bearer token.

It exists because the user record otherwise arrives exactly once, with the sign-in response.
A client that force-quits and relaunches on a stored token has a valid session and no idea
whose it is, so its Settings screen cannot show the account's own name. Call it on launch.

**`PATCH /me`**
Body: `{ "display_name": "Travis" }` → the same user object `POST /auth/apple` returns.

The signed-in user's own record. There is no path parameter and no way to name another
user: both routes act on the row behind the bearer token and nothing else.

```json
{
  "id": "uuid",
  "email": "travis@example.com",
  "display_name": "Travis",
  "is_admin": false,
  "created_at": "2026-08-08T00:00:00Z"
}
```

- **`display_name` is the only writable field.** `email` comes from the credential provider.
  Sending one is ignored — Apple's relay address is not the user's to retype, and letting
  them set it would decouple the row from the credential that produced it.
- The value is **trimmed**. Blank after trimming, or longer than **100 characters**, is
  `400` with code `invalid_display_name` and `field: "display_name"`.
- `users.updated_at` moves, written by the `set_updated_at()` trigger like every other row.

Why it exists: Apple sends a display name exactly once, at first authorization, and the
relay email is unreliable enough that `users.email` is nullable. `display_name` is the only
human-readable identity in the product, so an account that cannot fix it is labelled with
whatever Apple sent that one time, forever.

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

**`POST /children/{id}/recompute-ages`** — parent only. No body.

```json
{ "child_id": "uuid", "entries_updated": 412, "birthdate": "2021-06-01" }
```

Rewrites `entries.child_age_months` for every entry of the child, each from its own
`occurred_at` minus the child's current `birthdate`, in the child's `family_timezone` — the
same computation the write path uses.

`child_age_months` is computed at write and **stored** (`docs/data-model.md`), so correcting
a birthdate typo does not silently reshape 500 entries. The consequence is that the typo is
otherwise permanent, and this is the escape hatch: explicit, user-invoked, never a side
effect of `PATCH /children/{id}`. Fix the birthdate first, then call this.

- **Soft-deleted entries are included.** Nothing is deleted in this system, and a restored
  entry must not come back carrying an age computed against the wrong birthdate.
- **Only rows that actually change are written**, so `GET /sync` carries the correction
  without dragging eighteen years of unchanged entries through the cursor behind it.
  `entries_updated` counts rows changed, not rows examined.
- **Idempotent.** A second call immediately after returns `entries_updated: 0` and moves no
  `updated_at`.
- One transaction. A partially recomputed archive is not an acceptable outcome.
- `occurred_at` and `created_at` are never touched.

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

**`GET /media/{id}/url`**
→ `{ media_id, url, expires_in }`

The read path. The bucket is private, so this is the only way to fetch the bytes — without it
the capture path produces write-only data: the objects survive and nothing can render them.

Short-lived and minted per request. **Do not store the URL**; it outlives its signature and
then fails in a way that looks like the archive lost the file. Cache the *bytes*, refetch the
URL on a 403. `viewer` is sufficient — reading is not a write.

`409 upload_incomplete` if the upload has not finished: a pending row has no bytes at the key,
and a signed URL for it would 404 from storage, which reads like data loss rather than an
unfinished upload.

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
There is no `POST /prompts/batch-review`, and there is not going to be. Candidates are
batch-generated by `api/scripts/generate_prompts.py` into `docs/prompt-candidates/` and
reviewed **in a pull request** — a branch with a diff is already an accept/reject interface
with a comment thread, an audit trail, and an undo. Approving a batch is a commit to
`docs/mission-library.md`, not an API call. See `docs/prompt-candidates/README.md`.

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
| `invalid_display_name` | 400 |
| `assignment_expired` | 409 |
| `upload_incomplete` | 409 |
| `conflict` | 409 |
| `internal_error` | 500 |

Validation failures set `field`. Nothing ever returns a stack trace or a raw SQL error —
a `psycopg` message in a client alert is a leak, not a debugging aid.
