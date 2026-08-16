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

**Sign-in and refresh both record activity.** `POST /auth/apple`, `POST /auth/dev-login` and
`POST /auth/refresh` all stamp `users.last_sign_in_at`, throttled to a day's granularity. It is
server-side bookkeeping with no field in any response — it feeds D3's twelve-month inactivity
clock, and **a refresh has to count** or an app in daily use, which rotates its token and never
signs in afresh again, would look dormant for a year. Nothing reads the column yet.

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
  "notify_enabled": false,
  "notify_local_time": "19:00:00",
  "created_at": "2026-08-08T00:00:00Z"
}
```

- **Every field in the body is optional**, and an omitted field is left alone. A Settings
  screen toggling notifications does not have to resend a name it is not changing, and
  `{}` is a valid no-op. An explicit `null` for any writable field is a rejection, not a
  clear — none of them is nullable.
- **`email` is not writable.** It comes from the credential provider. Sending one is
  ignored — Apple's relay address is not the user's to retype, and letting them set it
  would decouple the row from the credential that produced it.
- `display_name` is **trimmed**. Blank after trimming, or longer than **100 characters**,
  is `400` with code `invalid_display_name` and `field: "display_name"`.
- `users.updated_at` moves, written by the `set_updated_at()` trigger like every other row.

Why it exists: Apple sends a display name exactly once, at first authorization, and the
relay email is unreliable enough that `users.email` is nullable. `display_name` is the only
human-readable identity in the product, so an account that cannot fix it is labelled with
whatever Apple sent that one time, forever.

#### The notification preference

`notify_enabled` and `notify_local_time` are the whole of it. **There is no preferences
endpoint** — the preference is part of the user object, so a client that already reads
`GET /me` on launch learns it without a second call.

- The preference is on the **user**, not the child. One human decides when their own phone
  buzzes; a second guardian on the same child is a second phone with a second opinion.
- `notify_enabled` **defaults to `false`**. The client sets it true only *after* the parent
  grants OS notification permission, never before.
- `notify_local_time` is a **wall-clock time**, e.g. `"19:00"`, read in the **child's
  `family_timezone`** — never the device's timezone and never UTC. A value carrying a UTC
  offset (`"19:00:00-04:00"`) is `422` with `field: "notify_local_time"`; it is a different
  and unanswerable request, not a more precise one. Seconds are dropped.
- The default is **19:00**, and it is a default rather than an answer: `docs/decisions.md`
  open item 6 — what time actually works — is still open.

---

## Devices

Where a notification is delivered. Both routes act on the account behind the bearer token;
there is no path parameter naming a user, the same shape as `/me`.

**`POST /v1/devices`**
Body: `{ "token": "…", "platform": "ios", "environment": "production" }` → the device row.

```json
{
  "id": "uuid",
  "token": "a1b2…",
  "platform": "ios",
  "environment": "production",
  "last_seen_at": "2026-08-14T23:01:00Z",
  "created_at": "2026-08-14T23:01:00Z",
  "updated_at": "2026-08-14T23:01:00Z",
  "revoked_at": null
}
```

- **Idempotent.** Call it on every launch that holds a token. The same
  `(token, environment)` pair updates the existing row and refreshes `last_seen_at` rather
  than creating a second one — a client that grew a row per launch would, within a month,
  send one parent thirty copies of the same notification.
- **`environment` is required and has no default.** It follows the `aps-environment`
  entitlement in the embedded provisioning profile, **not the distribution channel**.
  `sandbox` for a build signed with a development profile — an Xcode-installed build.
  `production` for anything signed with a distribution profile, which is **TestFlight and
  the App Store alike**: TestFlight ships through App Store infrastructure and there is no
  separate TestFlight APNs host. A sandbox token and a production token are different tokens
  addressed to different APNs hosts, and sending to the wrong one **fails silently** — this
  is the single most common way push works in development and not in TestFlight. The same
  token string may legitimately exist as both a sandbox and a production row, and they do
  not collide.
- **One user, many devices.** Phone today, iPad later. Every live token receives the day's
  one notification, collapsed by APNs so it is one row on each lock screen.
- A token that was revoked at sign-out comes back live when it re-registers, on the row it
  already had. A token registering under a different account **moves** to that account.
- Registering does **not** turn notifications on. That is `notify_enabled` on `PATCH /me`.
- `platform` is `ios` only. A browser client would need WebPush, which is a different
  protocol and a different credential; the column is `text` + `CHECK` so adding it later is
  an `ALTER`.

**`DELETE /v1/devices/{token}`** → `204`, no body. Called on sign-out.

- A **soft delete**: `revoked_at` is set and the row stays, so the same phone signing back
  in updates it rather than growing a duplicate.
- Revokes the token across **both environments** — sign-out means this phone stops
  receiving on this account, and a phone that has run both a development and a TestFlight
  build holds a row for each.
- **Idempotent**: revoking twice is still `204`. A token this account never registered is
  `404`, including one that belongs to somebody else — answering "it exists, but not for
  you" would make this route a way to probe tokens.

### What a notification contains

Not a route, but part of the contract, because a client deep-links on it:

```json
{
  "aps": { "alert": { "title": "Miles", "body": "<today's mission>" }, "sound": "default" },
  "assignment_id": "uuid"
}
```

The mission body, optionally the child's first name, and the assignment id. **Never entry
content, never anything from a sealed entry, and never a count of waiting or missed items.**
This renders on a lock screen other people can see. The body is not truncated server-side —
prompts run long and the OS lays them out.

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
Body: `{ name, birthdate, family_timezone, pronouns? }` → creates the child and a `parent` guardian row for the caller.

**`PATCH /children/{id}`** — name, birthdate, timezone, pronouns, avatar.

### `pronouns`

`he/him`, `she/her`, `they/them`, or **null**, and null is not a synonym for `they/them` — it
means the question was not answered. Onboarding is allowed to skip it, and prompt rendering
has to be able to fall back to the library's existing wording rather than assert something
the parent never said. An explicit `null` on `PATCH` clears it back to unanswered.

A closed set with a named `CHECK`, per the constrained-value convention. The consumer is
pronoun substitution in prompt bodies, which has to enumerate the forms it writes; widening
the set later is a migration, whereas storing text nothing can render is not something a
migration can undo. See `docs/decisions.md` open item 10.

### The avatar

The bucket is private, so a key is not a URL. Two calls, mirroring media minus the entry.

**`POST /children/{id}/avatar-upload-url`** — parent only.
Body: `{ content_type, bytes }` → `{ upload_url, avatar_key, expires_in }`

```json
{ "content_type": "image/jpeg", "bytes": 41234 }
```

- **A single PUT, never multipart.** An avatar is a ~512px square; the multipart machinery
  exists for video.
- `image/jpeg`, `image/png`, `image/heic`. Anything else is `422` on `content_type` — the
  key's extension has to be derived from something, and a type nothing can decode is better
  refused here than discovered when the archive tries to render it in 2044.
- **This stores nothing.** `PATCH /children/{id}` with the returned `avatar_key` is what
  commits it, and only after the PUT succeeds. An abandoned upload therefore leaves an
  orphaned object rather than a child pointing at bytes that never arrived; only the second
  is visible to a parent.
- A fresh key per presign, never a stable `avatar.jpg`. Overwriting one key would make a
  replaced avatar indistinguishable from a corrupted one, because every cached copy and every
  URL already in flight would follow the overwrite.

**`GET /children/{id}/avatar-url`** — `viewer` is enough; anyone who can see the child can see
their face.

```json
{ "url": "https://…", "expires_in": 3600 }
```

**`404` when the child has no avatar**, deliberately rather than a null URL. "This child has
no avatar" and "here is a URL that will not resolve" are different answers, and only the
first lets a client fall back to initials without a round trip that fails.

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

Query: `from`, `to` — both optional `YYYY-MM-DD`, both **inclusive**, either may be sent
alone. Omit both for the whole archive, which is what every caller before this got and still
gets. `from` after `to` is `422` with `field: "from"`.

The archive, in a format that outlives this API:

```
manifest.json            format version, child, counts, media that could not be fetched
entries.json             every entry, oldest first, with its prompt, tags, and media rows
media/YYYY/MM/<id>.<ext> the objects themselves, foldered by occurred_at

index.html               the readable layer — double-click it, no server, no internet
assets/app.css           constant for every export; copied from the repo, never generated
assets/app.js            likewise
entries.js               entries.json's bytes as `window.RASCAL_ENTRIES = …;`
manifest.js              manifest.json's bytes as `window.RASCAL_MANIFEST = …;`
```

- **Soft-deleted rows are included** and carry `is_deleted: true` with a `deleted_at`. An
  export that quietly drops them is not a copy of the archive.
- `manifest.child` is `{ id, name, birthdate, family_timezone, pronouns }`. **`pronouns` is
  there so the viewer can render prompt tokens**, and it is nullable — null means the
  they/them column, the same as everywhere else. The server still does not render: it ships
  the bodies with tokens intact and the answer needed to resolve them, and `assets/app.js`
  substitutes at read time like every other client.
- **Sealed letters export in the clear.** `unlock_at_age` is retained as data; the seal is
  an app behaviour, and an export you cannot read is not a backup.
- A media row whose bytes are not in S3 keeps its metadata, gets a null `path`, and is
  listed in `manifest.missing_media`. One dead upload does not fail the export.
- Response headers `x-rascal-export-entries`, `-media`, `-missing-media` summarise the run;
  `content-length` is exact, so a client can show real progress. They describe **the export**,
  so a scoped one reports its own counts and not the archive's.
- **`from` and `to` are calendar days in the child's `family_timezone`, not UTC**, and the
  server resolves the boundary. An entry logged at 8pm on Dec 31 in Detroit is stored as Jan 1
  UTC and belongs to December — a range built from naive UTC dates files it in the next year,
  which for a book printed once a year is a mistake nobody catches until it is on paper. This
  is the same rule as "the server owns what day it is".
- **Selection is by `occurred_at`, never `created_at`.** A photo taken in December and
  uploaded in January is December's. Backdating is a first-class flow and this is where it
  shows.
- **Scoping chooses days, never rows.** Soft-deleted entries inside the range come out exactly
  as they do from a whole-archive export.
- `manifest.scope` is `{ complete, from, to, timezone }` and is **the record of what this zip
  is a copy of**. `complete: true` has `from` and `to` null. When it is false,
  `manifest.notes` leads with a partial-archive warning naming the range and the zone instead
  of the usual "contains every entry" line, and the viewer shows a banner saying the same.
  **A partial archive must never be mistakable for a whole one** — the gap before March has to
  read as a gap in the download, not a gap in the childhood. `scope` is absent from every
  archive exported before this existed, and **absent means whole**: a reader must not infer
  partial from a missing key.
- A scoped download is named for its range — `dogear-<child>-20260101-20261231.zip`, with
  `start` or `end` standing in for an open bound — so two exports taken the same afternoon do
  not collide. The complete export's name is unchanged.

The zip is assembled on disk and streamed back, so memory is bounded regardless of size.

**The readable layer is the same data, not a second export.** `entries.js` and `manifest.js`
are the `.json` files' own bytes with `window.<NAME> = ` prepended and `;` appended — strip
those and you have the JSON back verbatim, with the sole exception of `</` written as `<\/`
and U+2028/U+2029 written as their `\u2028`/`\u2029` escapes. All three are JSON escapes
that parse to the same value, and all three exist so that a body somebody typed cannot
close the script tag or trip an older JavaScript engine.

The `.js` files exist at all because **a page opened from a `file://` path cannot `fetch()`
a file next to it** — the origin is opaque and the request is blocked — while a
`<script src>` tag works. Nothing about the viewer is per-child or per-export, and nothing about it is
stored: `index.html`, `assets/app.css` and `assets/app.js` are constant bytes copied out of
`api/src/rascal/export_viewer/` during the same assembly pass that writes the manifest.

---

## Today

**`GET /children/{id}/today`**

The single call the home screen makes. Returns everything the Today screen renders:

```json
{
  "date": "2026-08-14",
  "child": { "id": "...", "name": "Miles", "age_months": 50 },
  "today": [
    { "id": "...", "slot": "question", "body": "What did he say this week...",
      "kind": "question", "completion_mode": "text", "theme": "their-words",
      "status": "pending", "expires_on": "2026-08-28" },
    { "id": "...", "slot": "mission", "body": "Photograph what he built today...",
      "kind": "photo", "completion_mode": "media", "theme": "everyday-ordinary",
      "status": "pending", "expires_on": "2026-08-28" },
    { "id": "...", "slot": "mission_b", "body": "Record him telling you a story...",
      "kind": "audio", "completion_mode": "media", "theme": "voice",
      "status": "pending", "expires_on": "2026-08-28" }
  ],
  "waiting": [ ... ],
  "done_today": [ ... ]
}
```

**Three daily slots.** `question`, `mission` (photo only) and `mission_b` (video, audio or activity) are filled every day; `weekly` on Saturday, `monthly` on the 1st and `letter` on the 15th fire on top of them, so `today` holds up to five items. **The response shape is unchanged** — `slot` simply has one more possible value. A client that groups by whatever `today` contains needs no change; one holding a list of slot names does.

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
  "tags": ["their-words"]
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

#### `visibility`: specified, not yet built

`shared` | `private`, never null. **Not accepted on `POST /entries`** — the server sets it from the
prompt kind (`letter` → `private`, everything else → `shared`), because the default is the whole
point of the per-kind half of the decision and a client that could send it would drift from the
rule. `PATCH /entries/{id}` is where a parent changes it, and it follows the same set-ness rule as
`unlock_at_age` below: omitting the key leaves it alone.

**Every read path returns it, and no read path filters on it yet.** Until a route can create a
`viewer` row the only guardian is a `parent`, and a parent sees their own archive whole. When
guardian invites land, `child_access("viewer")` is where the filter goes — one place, the same
place every other authorization decision already lives. `/sync` returns it like any other column,
and the export writes it into `entries.json`: an archive that dropped it would come back with the
distinction erased.

**A seal is not a visibility state.** `unlock_at_age` is *when*, `visibility` is *who*. See
`docs/decisions.md`.

#### `unlock_at_age`: omitting the key and sending `null` are different

| What you send | What happens |
|---|---|
| key absent | Sealed at the prompt's `default_unlock_age`, if it has one |
| `"unlock_at_age": null` | **Not sealed.** The parent turned sealing off |
| `"unlock_at_age": 21` | Sealed at 21 |

Letters are sealed by default and the server owns that, so a client that has never heard of
sealing still writes a sealed letter. The *explicit* null is the only thing that overrides it,
and only because a parent said so on a screen.

This is setness, not value — the same distinction `PATCH` gets for free from `exclude_unset`.
`POST /sync/push` follows the identical rule, and it is the more important of the two: a
letter written offline with sealing deliberately off arrives hours later with nobody watching.

Deleting an entry releases its assignment back to `pending` unless another live entry still
completes it, so "wrong photo, redo it" puts the mission back on the Today screen. If the assignment is already `done`, `dismissed`, or `expired`, the entry
still saves — the archive matters more than the bookkeeping — and the assignment is left
alone.

**`GET /entries`**
Query: `child_id`, `before`, `after`, `type`, `tag`, `sealed`, `q`, `limit`, `cursor`.
Returns entries newest-first by `occurred_at`, with media summaries inline (thumb keys, counts, durations) so the timeline renders without N+1 calls.

Cursor is opaque and encodes `(occurred_at, id)` — keyset pagination, not `OFFSET`.
Backdating inserts rows into the middle of the order, and offset paging would skip them.
`limit` defaults to 50, caps at 200. Soft-deleted entries are excluded here.

**`sealed`** — `true` for sealed entries only, `false` for unsealed only, omitted for both.
Sealed means `unlock_at_age IS NOT NULL`. It is deliberately **not** a seventh `entry_type`:
a sealed letter is a `text` entry, and a sealed photo is possible and has to stay findable as
a photo. The two axes are orthogonal, so `type` cannot express this and they compose. It
narrows `q` searches too.

**`prompt_body`** is on every row: the sentence the entry answered, or `null` for a freeform
entry. A parent-authored `custom_body` wins over the library prompt it replaced, because that
is what was actually on screen. `EntryDetail` still carries the whole `prompt` object; this is
the one field a list row needs, and inlining it is what keeps a timeline card from fetching
per entry to quote its own prompt.

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

### Tags on an entry

`POST /entries` and `PATCH /entries/{id}` both take `tags`, and each element is either a bare
string or an object naming its source:

```json
"tags": ["beach", { "name": "seaside", "source": "device_ai" }]
```

**`source` defaults to `user`, so a bare string means exactly what it always meant** — every
client written before this existed is unaffected.

`source` is why re-running on-device extraction is safe: `device_ai` writes never overwrite or
delete a row with `source = 'user'`, and a parent retyping a tag the model found promotes it to
`user`. A source **absent** from the payload is left alone, so an extraction write carrying only
`device_ai` tags does not touch the parent's own, and a plain `user` write behaves as before.

Sources are applied `user` first, then `device_ai`. The protection only runs one way, so the
reverse order would have the `user` pass delete what the model just wrote.

---

**`PATCH /media/{id}/derived`**
Body: `{ transcript?, caption?, tags? }`
**This is the on-device AI write-back endpoint.** The phone transcribes locally, then persists the text here so search works everywhere — including from a browser that will never have an on-device model.

Tags written here get `entry_tags.source = 'device_ai'`. They never overwrite or delete a
row with `source = 'user'` — re-running extraction must be free, and it must never eat a
tag I typed. Idempotent: sending the same transcript twice changes nothing.

**`POST /children/{id}/prompt-suppressions`** — parent only
Body: `{ prompt_id, reason? }` → `201` with the suppression and the prompt inlined.

"Stop asking me this." **Idempotent** — suppressing twice returns the one row, and re-suppressing
something previously undone revives it rather than growing a second.

**This outranks every relaxation rule, including an empty candidate pool.** A suppressed prompt is
removed from the pool *before* selection begins, so the relaxed 90-day cooldown, the dropped theme
rotation and the final "anything at all" fallback each fall back to a list it was never in.

Distinct from dismissing an assignment, which still means "not today". Whether a client's single
dismiss action should offer this is an open product question — see `docs/decisions.md`.

**`DELETE /children/{id}/prompt-suppressions/{prompt_id}`** → `204`
Soft delete: `revoked_at` is set and the row stays. **A permanent decision a parent cannot undo is
worse than no decision.** Idempotent; `404` for a prompt this child never suppressed.

**`GET /children/{id}/prompt-suppressions`**
Query: `include_revoked` (default false). Each row carries the prompt, so a client can show what
has been suppressed and offer to restore it without fanning out.

**`GET /children/{id}/stats`** — any guardian → what is in the archive.

```json
{
  "child_id": "...", "as_of": "2026-08-14",
  "entries": 412, "sealed": 3,
  "media": { "photo": 1204, "video": 22, "audio": 61 },
  "first_entry_on": "2022-06-21", "last_entry_on": "2026-08-14"
}
```

**This exists because the client cannot answer it.** The timeline is a paged, partial cache, so
`docs/settings-v2-inventory.md` dropped the hero's stats strip (D1) and its first-entry line (D12)
rather than let the app assert the size of an archive it has only seen part of — the same rule the
Timeline header follows when it says *"412 so far"*.

- Counted live, never cached. A cached count of a growing archive is wrong for as long as the
  cache lives, and this is an admin-grade read like `pool-health`, not a hot path.
- **Soft-deleted rows are excluded**, and media is counted through a live entry — a delete takes
  the media with it, so a media row whose entry is gone is not in the archive whatever its own
  `deleted_at` says.
- `sealed` is a **subset** of `entries`, not a separate population.
- `media` carries **every kind, always, including zeros.** A key that appears only once a child
  has recorded audio is a key every client has to guard.
- `first_entry_on` / `last_entry_on` are **calendar days in the child's `family_timezone`**, not
  instants — an evening entry in Detroit is a Detroit day, and a UTC date would report the next
  one. `null` on an empty archive, never today standing in for one.

**`GET /children/{id}/pool-health`**
Per slot and per kind: `eligible`, `suppressed`, `served_within_cooldown`, `available_now`,
`estimated_days_until_first_repeat`, `served_in_window`, `observation_window_days`,
`nominal_interval_days`, `estimate_basis`, `relaxation_active`, `relaxation_step`.

Computed on every call, never cached — an admin-grade read, not a hot path. **It reports and
nothing else**; the scheduler decides.

**The estimate divides by the rate the slot is *observed* to be served, never by the cadence it is
nominally on** — corrected in phase 50, because the two had diverged in production. `mission` is
nominally daily and was being served zero times a day, so the old arithmetic counted down to a
first repeat that could not arrive. `served_in_window` is the observed count over
`observation_window_days` (28), and `nominal_interval_days` travels beside it so the gap between
intended and actual is legible in the response rather than inferred.

**A null estimate has two meanings and `estimate_basis` says which.** `pool_empty` — nothing is
available, and a projection of zero would read as a countdown to something that has already
happened. `not_observed` — the slot was not served once in the window, so there is no rate to
project from. **`not_observed` is not good news**: the pool cannot run dry because nothing is
drawing from it, which usually means something upstream stopped. `observed_rate` is a real
projection. Every assignment counts toward the rate, including dismissed and expired ones — they
consumed a prompt for that day and put it inside the cooldown.

---

## Moments

**`GET /children/{id}/moments`**
Query: `date` (defaults today)
Returns entries from this month/day in prior years, grouped by years-ago. If empty, returns `{ "fallback": "random", "entries": [...] }` so the client can render the warm redirect instead of a void.

---

## Sync

**`GET /sync?child_id={id}&since={cursor}&limit={n}`**

```json
{
  "entries": [...],
  "media": [...],
  "assignments": [...],
  "tags": [...],
  "cursor": "2026-08-14T18:22:00.481Z",
  "has_more": false
}
```

Every entity carries `updated_at` and `deleted_at`. Deletions arrive as rows, never as absences — a client can't infer a delete from a missing record.

**The response is a page.** `limit` caps each of the four collections independently — default
500, maximum 2000 — and `has_more` is true while *any* of them was cut. Keep calling with the
returned `cursor` as `since` until `has_more` is false. A client that stops at the first
response has a hole in its archive. Omitting `since` is a full snapshot **paged**, not a
single response: eighteen years of one child is the product, so scoping the read to one child
was never a bound, and the API runs on a 512MB machine.

**A cut page's cursor is the earliest of the cut collections' last `updated_at`, not the
latest.** The four collections advance at different rates. A cursor taken from whichever one
reached furthest would carry the client past rows another collection has not handed out yet,
and nothing would ever offer those rows again.

**The cursor is deliberately behind, and clients must upsert by id.** Whichever watermark it
is taken from — `max(updated_at)` on a complete page, the earliest cut watermark on a partial
one — it comes back 30 seconds behind it, so a pull will re-deliver rows the client has
already seen. That is not a bug to work around — it is the fix for one.

`set_updated_at()` uses Postgres `now()`, which is *transaction-start* time, not commit
time. A transaction that opens, takes a while, and commits therefore writes a row whose
`updated_at` is already behind a cursor another device advanced past in the meantime — and
that row would never appear in a sync again. Lagging the cursor by a window wider than any
write transaction closes the hole.

Re-delivery is free, which is what makes this the right trade: entries are last-write-wins
and keyed on a client-generated UUID, so applying the same row twice is a no-op. **A client
that treats every returned row as new will duplicate data.** Upsert by id.

The window bounds the longest write transaction. A `POST /sync/push` batch has to stay well
under 30 seconds, and the batch ceiling below enforces that rather than asking for it. If
batch push ever grows past 30 seconds, this window grows with it. A sequence-based cursor
is *not* the alternative — `nextval()` is assigned at statement time, not commit time, so a
`bigint` sequence has the identical race and costs a migration and a column on four tables.

**Paging and the overlap window have one interaction worth stating.** A collection holding
more than `limit` rows inside a single 30-second window cannot be paged past: the lagged
cursor lands back inside the group and the same page returns. Every row a transaction writes
carries that transaction's start time, so a bulk write is one `updated_at` however many rows
it touches, and `POST /children/{id}/recompute-ages` over a large archive is the realistic way
to reach it. The symptom is a cursor that stops advancing while `has_more` stays true, and the
answer is to retry with a larger `limit`. Failing that way is deliberate: the alternative
advances the cursor over rows it never delivered, and those are gone silently.

**`POST /sync/push`**
Body: `{ child_id, entries: [...], media: [...], idempotency_keys: {...} }`
Batched offline queue drain. Returns per-record accept/conflict so the client can reconcile without a full refetch.

**At most 200 entries and 200 media per call**, and more is a `422` the client answers by
draining in pages. The batch applies in one transaction and every record inside it costs
several sequential round trips, so an unbounded batch is an unbounded connection hold — and
one that runs past 30 seconds breaches the overlap window above, which turns a slow request
into rows that never sync again.

**No cursor comes back.** A sync cursor is the newest `updated_at` actually returned, and a
push returns no rows. A clock read would be ahead of `GET /sync`'s deliberately lagged cursor
and would skip everything committed inside the window — including the server-derived
`entry_type` and `child_age_months` this very push just wrote — and, being a wall clock rather
than a read position, it would also skip every older row the client had never pulled. Pull
after a drain using the cursor you already hold; that is how the server's corrections to your
own records reach you.

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

## Prompt pronoun tokens — a wire-format contract

Prompt bodies are stored and served **with tokens intact**. The server never renders them; every
client does, at the last moment before a human sees the sentence. A body pre-rendered server-side
could not be re-rendered when the answer changes, and the same body reaches a phone, a browser
client, an export and a printed book.

Fourteen tokens, one dictionary, no logic. Settled Aug 11, 2026 — see `docs/decisions.md`.

| Token | he/him | she/her | they/them | null |
|---|---|---|---|---|
| `{they}` | he | she | they | they |
| `{them}` | him | her | them | them |
| `{their}` | his | her | their | their |
| `{theirs}` | his | hers | theirs | theirs |
| `{themself}` | himself | herself | themself | themself |
| `{they_are}` | he is | she is | they are | they are |
| `{they_were}` | he was | she was | they were | they were |
| `{they_have}` | he has | she has | they have | they have |
| `{they_do}` | he does | she does | they do | they do |
| `{They}` | He | She | They | They |
| `{Them}` | Him | Her | Them | Them |
| `{Their}` | His | Her | Their | Their |
| `{name}` | the child's given name, identical in every column | | | |

**Why they/them are the keys.** They/them is the only English pronoun set whose five grammatical
slots are five distinct words, so it is the only set usable as a key without collision. A he-keyed
table cannot resolve `{his}`, which is one word for both "his favourite" and "that one is his"
where they/them uses "their" and "theirs".

**Verb agreement is four compound tokens, never conjugation.** A conjugator fails silently, and a
permanent archive cannot hold text that is only usually grammatical.

Three invariants every implementation must satisfy, and they are assertions rather than intentions:

1. Text containing no tokens passes through **byte-identical** — the 113 seeded prompts are literal
   he/him, contain no braces, and are never rewritten.
2. A null pronoun renders the **they/them** column.
3. An unknown token renders **literally, braces included**, and does not throw. `{foo}` stays
   `{foo}`: a visible bug is fixable, a silently dropped word is not even discoverable.

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

---

## Monetization — **UNBUILT**

**No endpoint in this section exists.** Nothing below is implemented, routed, or callable; this
records the shape D5 requires so that it is settled before it is built. The decisions are D1–D6 in
`docs/decisions.md`, and the tables are the PROPOSED section of `docs/data-model.md`.

### The entitlement is read from the server, always

**`GET /families/{id}/entitlement`** — any guardian. *Would* return the household's tier and, when
lapsed, the computed deletion-eligibility date.

```json
{
  "family_id": "...",
  "tier": "free",
  "lapsed_at": "2026-05-01T00:00:00Z",
  "eligible_at": "2028-05-01",
  "media_storage_tier": "archive"
}
```

**`eligible_at` is computed per request**, never stored — `max(lapsed_at + 24 months,
last_sign_in_at + 12 months)`, and both clocks move. A client may display it and must not cache it.

**The device never decides whether a household is subscribed.** A StoreKit transaction on the phone
is a receipt, not an entitlement, in exactly the way an Apple identity token is a credential and not
the identity model. Every gate reads the server, for the same reason the server owns what day it is.

### App Store Server Notifications V2

**`POST /webhooks/app-store`** — unauthenticated in the bearer sense and authenticated by signature.
*Would* accept Apple's V2 notification, verify the signed payload, and write the entitlement.

This is the **only** path that may set `tier`. A subscribe, a renewal, a cancellation, a billing
failure and a refund all arrive here, which is what keeps one authority over the answer — and is why
Apple Family Sharing is not enabled on the subscription: it would create a second opinion about who
is entitled, and two authorities that can disagree about the same fact is the shape of bug this
contract avoids everywhere else.

A notification for a family this server does not recognise is recorded and acknowledged, never
rejected — Apple retries, and a 4xx to a real notification is an entitlement that silently never
lands.
