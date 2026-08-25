# RASCAL — API Contract

Plain JSON over HTTPS. No client-specific serialization anywhere in the wire format — this is the insurance policy for a web client later.

Base: `/v1`. Auth: bearer token. All timestamps ISO 8601 UTC. All IDs UUID.

### Adding a field: a non-optional field on the wire still wants an Optional in the client

**Added Aug 22, 2026 by phase 113, from a defect the iOS lane measured rather than recalled, and
which would have passed review because it matched this document exactly.**

A new response field is additive and safe on the server: it is always sent, and a value like
`billing_retry: bool` with a default of `false` genuinely has two states rather than three. **The
client has a third state anyway, and it is not "null" — it is `keyNotFound`.** There is always a
window in which the deployed server predates the field: between merging the API change and
actually shipping it, every response omits the key.

**Swift's synthesized `Decodable` does not fall back to a property's default value for a missing
key.** It throws. Measured:

```swift
struct WithDefault: Decodable { let a: String; var flag: Bool = false }
// {"a":"x"}  ->  THREW  keyNotFound … ("flag")     // even WITH a default
struct Optionally: Decodable { let a: String; let flag: Bool? }
// {"a":"x"}  ->  decoded, flag = nil
```

So a non-optional `Bool` mirroring this contract precisely takes down the decode of **the entire
enclosing object** against a server that has not deployed yet — not the one field, the whole
response and every screen behind it.

**The rule, and it is about the two ends answering different questions.** The server asks *what is
true of this household*, where `false` and "not in a billing retry" are the same thing. The client
asks *what did this particular server tell me*, where "it said false" and "it is too old to have an
opinion" are different, and only one of them is safe to render. **Decode every additive field as an
Optional regardless of its wire type**, and give it a non-optional accessor that supplies the safe
default — the same direction standing rule **D9** already sets for `access`, where absent and
unrecognised both mean *entitled*.

**And test the absence, not the null.** A payload carrying `"billing_retry": null` and a payload
that omits the key entirely prove different things, and it is the omission that production sends.

Last updated: **Aug 16, 2026** — phases 51–57 (the auth bundle: `aud` allowlist, credential
linking, Apple server-to-server notifications, Google sign-in, the mailer, magic-link sign-in),
plus the **unbuilt** `POST /v1/subscribe` specified for phase 60.

---

## Health

**`GET /health`** → `{ "status": "ok", "db": "ok" }`

Unauthenticated. ~~The only route outside `/v1`.~~ — **no longer true as of the universal-link work: `wellknown.router` is mounted with no prefix**, so `/.well-known/*` sits outside `/v1` too. That is forced rather than chosen — Apple fetches the association file from a fixed path at the domain root and will not follow a prefix. Fly's health check hits this; it touches
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

**`POST /auth/google`**
Body: `{ identity_token, display_name? }` → the same `SessionResponse` as `/auth/apple`.

Google's JWKS, cached with a TTL and the same one-refetch-on-unknown-`kid` rule Apple has.
`iss` may be **either** `accounts.google.com` or `https://accounts.google.com` — Google
publishes both and both are seen. `aud` is checked against **`GOOGLE_CLIENT_IDS`**, a separate
comma-separated setting and never `APPLE_BUNDLE_ID`: they are different namespaces that happen
to share a claim name, and pooling them would let an Apple token for a Google client id verify.
**`email_verified` must be true** — an unverified address is a claim about an inbox nobody has
proved they can read, and `POST /auth/email/start` turns an address into a key.

`GOOGLE_CLIENT_IDS` unset is the state the repository ships in, because no Google project
exists yet. Unset makes this route `422` with a message naming the setting, rather than
rejecting every real token for no stated reason.

**`POST /auth/email/start`**
Body: `{ email }` → **always `202`**, body `{ "status": "accepted" }`.

**It never creates a user.** It matches an existing, *verified* `email` credential or it does
nothing at all. Email is a second key to a door you already own, added deliberately from
Settings while signed in through `POST /me/credentials/email` — there is no public signup on
this path. Without that rule, a parent who signed in with Apple and later typed their address
here would be handed a second, empty archive, with a working session and no signal that their
real one still exists somewhere they can no longer reach.

**The `202` is unconditional and identical either way** — same status, same body — so this is
not an account-enumeration oracle.

**Rate limited, per-email and per-IP, independently.** Five per address per hour and twenty per
IP per hour by default. Per-email is the one that matters: the abuse is spamming links at one
address, and an edge limiter cannot see the address because it is inside this body. Over the
limit is `429` `rate_limited`. A refusal does not itself count against the window.

**`POST /auth/email/complete`**
Body: `{ token }` → the same `SessionResponse` as `/auth/apple`.

Single use, fifteen minutes. Unknown, already consumed, expired, or a sign-in link for an
address that has since been removed are **all one answer** — `401` `sign_in_link_invalid` —
because telling them apart would say whether a link ever existed. Stamps `last_sign_in_at`.

A link sent by `POST /me/credentials/email` also **verifies** the address, which is what turns
a newly added credential from inactive into a way in. A link sent by `/auth/email/start` never
does: it cannot re-activate an address the parent removed, or Remove would be a suggestion
rather than an action.

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

- **The credential row is `provider = "email"`, `subject_id = <email>`** — not `apple`.
  ~~`provider = "password"`~~ — moved by phase 52, and the migration took the existing rows
  with it. The fixture now rehearses the production credential shape instead of squatting
  beside it: this is the same row a magic link writes. Swapping to Sign in with Apple later
  still produces a *different* user, not the same one.
- **The address must be on a local fixture domain**, `rascal.local` by default
  (`DEV_LOGIN_EMAIL_DOMAINS`). Anything else is `422` with `field: "email"`. The route being
  absent from a production build is the first lock; this is the second, and it closes a
  different hole — a *local* API pointed at a *real* database, during a restore drill or a
  production debugging session, handing back an `is_admin` session for somebody's actual
  account because a developer typed their own address. `ENVIRONMENT` can be right while the
  database is not. The address is lowercased before the domain is compared.
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

**No sign-in route ever links to an existing account.** Each finds or creates the user behind
its own `(provider, subject_id)`, and **nothing anywhere matches on email address** — two people
share addresses, an Apple relay address is not a Google one, and an archive of a childhood is not
a thing to hand over on a string comparison. A parent who signs in with Apple and then with
Google has two accounts until they explicitly join them from inside a session. That is
`POST /me/credentials`.

Google arrived in phase 54 with **no schema change** — a route and a verifier. That is the point
of the credential row.

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

### Deleting the account

Apple has required in-app account deletion for apps offering account creation since June 2022.
Settled in `decisions.md` open item 14.

**`POST /me/deletion`** → `202`

```json
{ "requested_at": "2026-08-17T23:00:00Z", "execute_after": "2026-08-24T23:00:00Z" }
```

`202` rather than `204`: **nothing has been deleted yet**, and saying otherwise is the one lie
this endpoint cannot afford. The body carries the date so a client can say exactly when rather
than paraphrasing a policy it would then have to keep in step.

**Idempotent** — asking twice returns the first request rather than restarting the clock. Every
refresh token is revoked, so this signs them out of every device immediately.

**`DELETE /me/deletion`** → `204`. Idempotent; `204` whether or not there was one to cancel,
because a `404` would alarm somebody who has already been reassured, about nothing.

**Signing in cancels an outstanding request outright**, per D3's precedent — somebody who signs
back in has changed their mind. That is why the immediate sign-out matters: after it, only a
deliberate sign-in can reach the cancel.

**What is deleted, seven days later:** the account always — credentials, devices, tokens, and the
`guardians` rows that gave it access. **The archive only when no other guardian remains.** A
shared archive is not one parent's to destroy, so children, entries and media survive as long as
somebody else guards them; when the last guardian goes, the archive and its objects go too.

**`entries.author_id` is nullable, and null means the author was erased.** A departing parent's
entries survive when another guardian remains — they belong to the child — but the person is
genuinely gone, so the attribution goes null rather than being reassigned to whoever is left.
Null is *"written by somebody no longer here"*, which is true; a reassignment would be a false
claim about who wrote a sentence.

---

### Sign-in methods on this account

**Linking is explicit and nothing here matches on email.** A credential joins an account
because somebody signed in to that account and asked for it.

**`GET /me/credentials`** → a list, oldest first.

```json
[
  {
    "id": "uuid",
    "provider": "apple",
    "subject_hint": "••••cdef",
    "created_at": "2026-08-16T00:00:00Z",
    "revoked_at": null
  }
]
```

- **`subject_id` is never returned.** `subject_hint` is masked by shape rather than truncated,
  because what a parent needs from it is *which of these two is which*: an address keeps its
  domain and the first letter of its local part (`t••••@example.com`), an opaque provider
  subject keeps its last four characters.
- **Revoked credentials are included**, with `revoked_at` set. A parent who turned one off and
  wants it back needs to see that it is off, not find it missing. An `email` credential that
  has been added but not yet verified also reads as revoked — it is not a way in yet.

**`POST /me/credentials`**
Body: `{ provider, identity_token, display_name? }` → the credential, `200`.

`provider` is `apple` or `google`. It is **narrower than the column's CHECK on purpose**: the
schema permits a provider only once something can verify it. Verification is exactly what that
provider's sign-in route does, then the credential is attached to the **current** account — the
one behind the bearer token, never one resolved from an email address.

- A subject already bound to **this** account → `200`, idempotent no-op.
- A subject bound to a **different** account → `409` `credential_in_use`, **and nothing is
  written**. Credentials are never reassigned and accounts are never merged.
- Several credentials per provider are allowed. Two Apple IDs on one account is a real
  household, not a mistake.

**`POST /me/credentials/email`**
Body: `{ provider: "email", email }` → `202`, body `{ "status": "accepted" }`.

**The address is typed by the parent and proved by the click, never by this field.** The
credential is created **inactive** and a link is sent; opening it through
`POST /auth/email/complete` is what turns it into a way in. A typo therefore costs nothing —
the inbox that receives the link is the only one that can activate it.

**It must never be defaulted from `users.email`.** The production account is on a
`privaterelay.appleid.com` address, and Apple can stop forwarding a relay at any time without
telling anybody; a magic link to a dead relay is a key that looks alive. **Always `202`, and the body says nothing about the address** — an address already on a
*different* account is answered identically to a fresh one, with nothing written and nothing
sent. It used to answer `409 credential_in_use`, which told any caller whether a given address
signs in to Vellum; the route is authenticated, but anyone who can create a free account is a
caller. `POST /auth/email/start` already refuses that question unconditionally, so answering it
here was an inconsistency as much as a leak. Read `GET /me/credentials` for the result.

**Rate limited per calling account**, unlike every other authenticated route. This one mails an
address the account does not own and has not proved anything about, so without a limit it is a
way to mail a stranger repeatedly from our sending domain.

**`DELETE /me/credentials/{id}`** → the credential, `200`.

A **soft** revocation: the row stays, `revoked_at` is set, and it keeps its claim on its
provider subject — so signing in with it again clears the revocation and lands on the **same**
account. That is what makes removal recoverable rather than terminal.

- **Refuses to revoke the last live credential** → `409` `last_credential`. Removing the only
  way into an account would lock a parent out of the archive permanently, and that must not be
  reachable through an API call. A client shows this as a plain sentence, not an error state.
- Revoking an already-revoked credential is a `200` no-op.
- A credential on another account is `404`, not `403` — naming somebody else's credential id
  should not confirm that it exists.

---

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

Failure is `403` with code `not_authorized`. **Never `404`, and the reason is the opposite of
what this line used to say.** It read *"leaking existence is fine here"* — which described a
weaker property than the code has and, worse, read as licence to add the 404 branch. An id that
belongs to nobody and an id that belongs to somebody else return **the same 403 with the same
code**, so the route cannot be walked to learn which ids are real. That is a membership fact
about another household and it is not for sale. A wrong 404 would also send you debugging the
wrong thing, which is the smaller of the two reasons. Pinned by
`tests/test_authorization_sweep.py::test_an_id_that_exists_is_indistinguishable_from_one_that_does_not`.

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

- **Soft-deleted entries are included.** Nothing is deleted *by this endpoint*, and a
  restored entry must not come back carrying an age computed against the wrong birthdate.
  This read **"nothing is deleted in this system"** until Aug 17, 2026, which phase 66 made
  false: `POST /me/deletion` hard-deletes rows and objects seven days after a parent asks.
  The narrower claim is the one that was ever load-bearing here.
- **Only rows that actually change are written**, so `GET /sync` carries the correction
  without dragging eighteen years of unchanged entries through the cursor behind it.
  `entries_updated` counts rows changed, not rows examined.
- **Idempotent.** A second call immediately after returns `entries_updated: 0` and moves no
  `updated_at`.
- One transaction. A partially recomputed archive is not an acceptable outcome.
- `occurred_at` and `created_at` are never touched.

~~**`POST /children/{id}/guardians`** — Body: `{ email, role }` → creates an invite. P2.~~
**Struck Aug 17, 2026: this route never existed and is superseded.** Guardians are invited
through **`POST /families/me/invites`**, built in phase 36 — an invite belongs to the
household rather than to one child, because a second parent joins a family and gets every
child in it, not one. Kept struck rather than deleted so the next reader sees that the
child-scoped shape was considered and replaced, rather than wondering where it went.

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
- A scoped download is named for its range — `vellum-<child>-20260101-20261231.zip`, with
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

## Families and invites

Phase 36. The household is the unit of entitlement, per D4 — one price, all guardians,
unlimited children. **Authorization did not change:** an accepted invite writes `guardians`
rows, which is what `require_child_access` already reads.

**`GET /families/me`** → the caller's own household. No `{id}` in the path, so there is
nothing to forge.

```json
{
  "family_id": "…",
  "tier": "free",
  "access": "trial",
  "trial_ends_at": "2026-09-04T00:00:00Z",
  "lapsed_at": null,
  "plan": null,
  "billing_retry": false,
  "is_payer": null,
  "guardians": [
    { "user_id": "…", "display_name": "Travis", "role": "parent",
      "granted_at": "2026-08-17T11:00:00Z", "is_you": true }
  ],
  "pending_invites": [
    { "id": "…", "email": "anna@example.com", "role": "parent",
      "expires_at": "2026-08-24T11:00:00Z", "created_at": "2026-08-17T11:00:00Z" }
  ]
}
```

`granted_at` is **nullable**: a household member with no guardian row — a household whose only
child was deleted, or a member mid-accept — has no grant date, and inventing one would put a
confident wrong timestamp on a screen.

`pending_invites` lists only invites that are still acceptable — accepted, revoked and
expired ones are history, and this is a screen about the household as it is now.

**`access` and `trial_ends_at` were added by phase 107 and `tier` is unchanged in both its
values and its meaning** — a client that has been reading `tier` since phase 37a keeps working.
`tier` says whether Apple has told us somebody is paying; `access` says what the phone will
actually be served today, and during a fourteen-day trial those are different answers. See
`GET /families/{id}/entitlement` below for the definition; both routes read one function.

##### The four membership fields phase 113 added

**All four are additive and optional. No existing field changed meaning**, and a client that
ignores every one of them behaves exactly as it did before. They exist because the Settings
membership surface has to tell nine household states apart and the server could express three.

**`access` still has exactly three values and a fourth is not coming.** Adding `lapsed` or
`grace` to that enum would be the opposite of safe: under standing rule **D9** an unrecognised
`access` means *entitled*, so every client built before such a change would hand a lapsed
household the full board. That is why each of these is a separate optional field instead.

| field | type | what a null/false means |
|---|---|---|
| `lapsed_at` | `datetime \| null` | **Never subscribed.** Non-null is a household that used to be and is not now — the only way to tell those two apart on this route. **A trial expiring never writes it** (D3): a household that tried the app for a fortnight and stopped reads `null` forever and must not be rendered as having cancelled. |
| `plan` | `"annual" \| "monthly" \| null` | **Unknown, and a client must render its fallback rather than guess.** Null means no receipt behind the subscription (the hand-written household in `runbook-deploy.md` §7a), a product id this server does not recognise, **or a household that is not currently subscribed**. |
| `billing_retry` | `bool`, default `false` | Not in a billing retry. **Never optional** — `false` and absent are the same render. |
| `is_payer` | `bool \| null` | **Unknown, and it must never be read as `false`.** See below. |

**`plan` and `billing_retry` describe a *current* subscription.** A household that lapsed from
annual reports `plan: null`, not `"annual"`, so `plan` never appears beside `access: "free"` and
`billing_retry` is never `true` for a non-member. One rule rather than a table of combinations.

**`billing_retry` gates nothing whatsoever.** A household whose card is failing keeps everything
while Apple retries: `access` is still `"subscribed"`, `tier` is untouched, and the whole board
stays open. That was already true before this field existed — `DID_FAIL_TO_RENEW` with subtype
`GRACE_PERIOD` is deliberately a no-op on `tier` — and the field exists so a client can *offer to
fix a card*, never so it can withhold anything. `GRACE_PERIOD_EXPIRED` is the separate
notification that actually demotes.

**`billing_retry` under-reports, deliberately, and never over-reports.** It is derived from *the
last notification Apple sent about this subscription*, so any later notification clears it —
including ones that change no tier, such as `DID_CHANGE_RENEWAL_STATUS` (auto-renew off) and
`DID_CHANGE_RENEWAL_PREF` (a plan change). A household that turns auto-renew off during a retry
reads `false` while Apple is still retrying. **The direction is the point:** a missed offer to fix
a card costs nothing, since entitlement is untouched either way, whereas telling a healthy
subscriber their payment is failing is a false alarm. Being exact needs
`renewalInfo.gracePeriodExpiresDate`, which the webhook does not currently parse — that is the
`grace_until` variant of this field and it is a phase, not a line. A test pins the current
behaviour so it cannot drift into over-reporting unnoticed.

**`is_payer` is computed for the calling user and has three values, and the third is the point.**
`true` and `false` mean what they say; **`null` means nobody knows**. A client hides Apple's
subscription-management control on an explicit `false` — correct, because a non-payer sent to
that sheet finds this subscription is not in it — and hiding it on a `null` would strip the
control from a parent who is paying. **Null is the common case rather than the edge one**:
`payer_user_id` is deliberately left unwritten when a household has two guardians, because
`appAccountToken` carries a *family* id and Apple's notification never names a user, so the field
is unknown in exactly the households where the question means anything. `docs/blocked.md` §20
carries what it would take to fix that; it is a client change, not a server one.

**The raw `payer_user_id` is never on the wire under any name.** It is another household
member's UUID, and the question is answerable about the caller without disclosing one.

**`eligible_at` is deliberately absent from this route** and is not being added. It is D3's
deletion clock; it stays on `GET /families/{id}/entitlement` for the console. Keeping it off the
one shape the Settings screen reads is what makes it structurally impossible for that surface to
render a deletion date by accident.

**`POST /families/me/invites`** → `201`
Body: `{ "email": str | null, "role": "parent" }`. `email` is optional and is only recorded;
**nothing in this phase sends it.** The client delivers the link however it likes.

```json
{ "id": "…", "email": "anna@example.com", "role": "parent",
  "expires_at": "…", "created_at": "…", "token": "2jtAKk90R8tJ…" }
```

**`token` is returned once and is never recoverable.** Only its SHA-256 is stored, so a lost
link is re-issued rather than looked up.

Three refusals:

| | |
|---|---|
| `402` `subscription_required` | The household is on the free tier. **Per D4 the second guardian is what the subscription is sold on**, so the invite surface is the upgrade surface. The message names what subscribing unlocks — it is a door, not a wall |
| `409` `conflict` | The household already has two parents. Two adults is the household; a third is a different product, not a bigger bill |
| `422` `validation_failed`, `field: "role"` | `viewer` was requested. Phase 30 is iceboxed; the column can hold the value, nothing may issue one |

**`DELETE /families/me/invites/{invite_id}`** → `204`. Idempotent. An invite belonging to
another household is `404`, not `403` — the caller has no business knowing it exists.

**`GET /invites/{token}`** — **unauthenticated**, because you have to be able to see what a
link is before you sign in to accept it.

```json
{ "invited_by": "Travis", "role": "parent", "expires_at": "…",
  "children": ["Miles", "Nora"] }
```

Deliberately thin: who invited you, the role, when it expires, and the children's **first
names**. Enough for the right person to recognise their own household, not enough to be
worth harvesting. No ids, no birthdates, no email addresses. An unknown, expired, revoked or
already-accepted token is a flat `404` rather than a `410` — the caller is a stranger at this
point, and that a token once existed is more than they need to know.

**`POST /invites/{token}/accept`** — authenticated, because it writes to the caller's own
account. Sets `users.family_id` and creates a `parent` `guardians` row for **every child in
the household**.

```json
{ "family_id": "…", "children": ["…", "…"] }
```

**Idempotent.** The same user accepting the same link twice succeeds twice and writes nothing
the second time — a parent who taps a link, loses signal and taps again gets a household, not
an error.

---

## Today

**`GET /children/{id}/today`**

The single call the home screen makes. Returns everything the Today screen renders:

```json
{
  "date": "2026-08-14",
  "child": { "id": "...", "name": "Miles", "age_months": 50 },
  "access": "subscribed",
  "trial_ends_at": null,
  "today": [
    { "id": "...", "slot": "question", "body": "What did he say this week...",
      "kind": "question", "completion_mode": "text", "theme": "their-words",
      "status": "pending", "expires_on": "2026-08-28" },
    { "id": "...", "slot": "mission", "body": "Photograph what he built today...",
      "kind": "photo", "completion_mode": "media", "theme": "everyday-ordinary",
      "status": "pending", "expires_on": "2026-08-28" }
  ],
  "locked": [],
  "waiting": [ ... ],
  "done_today": [ ... ]
}
```

And the same day for a household on the free tier — a Friday, so `mission` is what it is missing:

```json
{
  "date": "2026-08-14",
  "child": { "id": "...", "name": "Miles", "age_months": 50 },
  "access": "free",
  "trial_ends_at": "2026-08-07T00:00:00Z",
  "today": [
    { "id": "...", "slot": "question", "body": "What did he say this week...",
      "kind": "question", "completion_mode": "text", "theme": "their-words",
      "status": "pending", "expires_on": "2026-08-28" }
  ],
  "locked": [ { "slot": "mission", "kind_hint": "photo" } ],
  "waiting": [ ... ],
  "done_today": [ ... ]
}
```

**The daily slots rotate by weekday.** ~~*`question`, `mission` (photo only) and `mission_b` (video, audio or activity) are filled every day*~~ — **that stopped being true on Aug 21, 2026 with phase 107.** `question` fires every day; `mission` fires Monday, Wednesday and Friday; `mission_b` fires Tuesday and Thursday; both fire at the weekend. `weekly` on Saturday, `monthly` on the 1st and `letter` on the 15th still fire on top, so `today` still holds **up to five** items — a Saturday that is also the 1st or the 15th — and an ordinary weekday now holds two. **The pools are unchanged**: `mission` is still photo-only, `mission_b` is still video, audio or activity.

**The weekday is the child's, computed in `family_timezone`.** A Saturday in Auckland is a Friday in UTC and the parent gets the Saturday.

**Three additive top-level fields, added by phase 107. Nothing inside `today[]` changed.**

- **`access`** — `"subscribed" | "trial" | "free"`. What this household may reach today. Computed from `entitlements.tier` and `entitlements.trial_ends_at` by the one authority every other entitlement surface reads; `subscribed` beats `trial`. **Always present.**
- **`trial_ends_at`** — nullable timestamp. `null` means *no trial on this household*, not *a trial that ended*. **For copy only** — a client must never compute entitlement from it, because that is the device deciding, which D5 forbids.
- **`locked`** — the slots today holds that this household may not have. **`[]` for an entitled household; never `null`, never absent.**

**A locked item is `{ "slot", "kind_hint" }` and nothing else — no `id`, no `body`, no prompt, no `theme`.** It is the shape of the thing, not a teaser for it. Naming the prompt would mean *picking* one, and a pick writes an assignment and consumes the 180-day cooldown against a 133-prompt pool — so a free household's runway would be spent on prompts they cannot answer, and they would be served repeats on the day they subscribe. D7 also calls the mission library the one asset a competitor would want, and a paywall that serves the copy it is withholding is not a paywall.

`kind_hint` is `photo` for `mission`; `mission` for `mission_b` (deliberately vague — its pool spans video, audio and activity and which one a day would have produced is unknowable without the pick this endpoint is avoiding); and its own name for `weekly`, `monthly` and `letter`. **`question` never appears in `locked`** — it is the free tier. A client should render an unrecognised hint as a generic locked row rather than dropping it.

**Order is the calendar's and is stable:** `mission`, `mission_b`, `weekly`, `monthly`, `letter`, filtered to what that day holds. Two reads of the same day return the same order.

`waiting` is pending assignments from previous days, oldest first. **A locked slot never appears in `waiting`.** The exclusion is in the query rather than in the absence of rows, because a household that lapsed genuinely *has* pending mission rows from when it was entitled; those rows keep existing and are not deleted.

~~**and is never expired against the parent** — it was never offered, so it cannot be missed~~ — **corrected Aug 22, 2026: a hidden row does still expire, on the same fourteen-day clock as any other.** The nightly job flips any pending row past its `expires_on` with no entitlement filter, so a mission served on day 0 and hidden by a lapse on day 1 becomes `expired` on day 15 having been invisible throughout. **Suppressing that was considered and rejected**: a household that lapses for a year and comes back would then find a year-old mission in `waiting`, which is the infinite backlog *"items stack; expire at 14 days"* exists to prevent — a settled decision this phase has no licence to reverse. Entitlement decides what is *served*; it does not stop the clock. **A household that returns inside the window gets the row back with the days it has left**, which is the case that matters and is what not deleting it buys. The cost is named rather than hidden: such a row counts toward `resolved` in the admin console's per-household figures.

`done_today` is anything completed with `occurred_at` today, and **it is never filtered by entitlement.** A parent who finished a mission this morning and lapsed at 2pm keeps seeing it: D3 as narrowed locks the day and never the archive.

**Subscribing takes effect on the next read.** `GET /today` calls `ensure_day_filled`, which re-reads the household's entitlement, so a household that subscribes at 2pm gets its missions immediately rather than tomorrow.

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

**Recomputed on every route that creates, removes or re-owns a media row** — `POST
/media/upload-url`, `POST /media/{id}/complete`, `PATCH /entries/{id}`, and a `/sync/push`
carrying `deleted_at` — because media lands after the entry exists and can leave again.

**Rule (1) counts a media row whose bytes are not in storage yet**, and that is deliberate,
settled Aug 18, 2026 by the owner: `entry_type` describes the media a parent attached, not what
storage happens to hold. So an entry is typed `audio` from the moment `POST /media/upload-url`
mints the row, while `upload_status` is still `pending`.

The alternative was to type it only once bytes landed, and it had a hole with no floor: an upload
that never completes never calls `POST /media/{id}/complete`, so the entry kept its creation-time
type **permanently** and fell out of the `?type=` filters forever. A recording made off Wi-Fi
whose upload later died was a voice note filed as an entry with nothing in it. `upload_status` is
the field that answers "are the bytes there"; `entry_type` answers "what is this".

The full derivation, including every route that recomputes it, is `docs/data-model.md`'s `entries`
section under *"`entry_type` is derived, and this row is the one that has to say so"*. ~~See
`docs/blocked.md` §14.~~ — **struck Aug 22, 2026 (phase 111): §14 was resolved on Aug 18, 2026 by
phase 86 and is struck through in `blocked.md`, so it is where this was open, not where the rule
is written down.** It is named rather than dropped because the pointer stood here for four days
and a reader who followed it should land somewhere that explains why.

A freeform entry has no assignment and so falls through to (3)/(4). What was asked is still
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

Single presigned PUT at or under ~15MB; presigned multipart above that. **Size is the only rule, for every kind** — video assumed multipart regardless of size until Aug 18, 2026, which cost a two-second clip an initiate round trip, a presign, a part upload and a complete call to move less than one chunk.

**Client uploads directly to S3** on a background `URLSession`. This survives app backgrounding and cellular flakiness, which matters more than anything else in the capture path.

**`POST /media/{id}/complete`**
Body: `{ etags?, captured_at, duration_seconds? }`
Server marks `upload_status = complete`. ~~kicks off thumbnail and poster-frame generation~~ — **nothing is kicked off, and nothing ever has been.** `thumb_key` stays null; thumbnail and transcode pipelines are named out of scope in `CLAUDE.md` and were cut from P0 in `decisions.md`. **Struck Aug 18, 2026** — a client written from this line would have waited for a thumbnail that is never coming.

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
nominally on** — corrected in phase 50, because the two had diverged in production. ~~`mission` is
nominally daily~~ — **it was until Aug 21, 2026; phase 107's weekday rotation makes it nominally
1.4 days and `mission_b` 1.75** — and it was being served zero times a day, so the old arithmetic
counted down to a first repeat that could not arrive. `served_in_window` is the observed count over
`observation_window_days` (28), and `nominal_interval_days` travels beside it so the gap between
intended and actual is legible in the response rather than inferred.

**`nominal_interval_days` is fractional and is counted off the scheduler's own calendar**, not
written down a second time. The daily slots rotate by weekday, so `mission` is served five days in
seven and `mission_b` four; a hand-written table saying `1` for both would have put a permanent,
spurious gap on exactly the two slots this field exists to watch — which is the failure phase 50
fixed, arriving by a different route. Values today: `question` 1.0, `mission` 1.4, `mission_b`
1.75, `weekly` 7.0, `monthly` and `letter` 30.44.

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

Every entity carries `updated_at`. **Three of the four carry `deleted_at` — entries, media and tags; `assignments` does not**, and does not need one, because nothing deletes an assignment: they expire by `status`, which the client already reads. Deletions arrive as rows, never as absences — a client can't infer a delete from a missing record. *(Corrected Aug 18, 2026; the line said "every entity" and `SyncAssignment` has never had the field.)*

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

**`GET /prompts`** — filterable by kind, theme, age band, source. Any authenticated caller,
but **pending candidates (`source: "llm"` and not active) are admin-only** — they are a review
queue, not library content. Approving one makes it visible like any other prompt.
**`POST /prompts`** — hand-authored additions. **Requires `users.is_admin`**; anyone else
gets `403 not_authorized`. The library is content every child draws from, so a `viewer`
login must not be able to write to it. `dev-login`'s fixture user is an admin.
**There is still no `POST /prompts/batch-review`, and still no plan for one** — approving a
candidate is `PUT /prompts/{id}/active`, one prompt, read by a person. A bulk approve is the one
action here whose mistake is invisible until a parent reads it.

Everything else in this paragraph changed on Aug 20, 2026 (phase 103), and the old version is
worth stating because it was half right. It said candidates are batch-generated into
`docs/prompt-candidates/` and reviewed in a pull request, and that approving a batch is a commit
to `docs/mission-library.md` rather than an API call. **That is still exactly true of the batch
path** and `scripts/generate_prompts.py` is unchanged. What was wrong was the implied "and
therefore there is no other path": `POST /prompts/generate` and `POST /prompts/candidates` below
are the interactive one.

The library is content. It's authored and reviewed server-side, never generated at request time and never authored on-device.

### Editing it — phase 96, Aug 19, 2026

All four require `users.is_admin`.

**`POST /prompts/preview`** `{body, name}` → one body rendered as all three pronoun columns plus
`unknown_tokens`. **The one place the server renders a token**, and it is an authoring tool rather
than a serving path: bodies still go out with tokens intact and every client still substitutes at
the last moment. It exists because a body can be grammatical in one column and broken in another —
`{they_have}` against a hand-written "has" — and the author is usually picturing one child.

**`PATCH /prompts/{id}`** → `{prompt, action, superseded_prompt_id}`. Partial; anything omitted is
left alone.

> **An edited body is a new prompt, not an update.** `content_hash` is
> `sha256(kind, cadence, body)` and `seed_prompts` keys on it, so editing a **seeded** body in
> place would be undone by the next deploy — the row would be retired as absent from
> `prompts.yaml` and the original re-inserted. Changing `kind`, `cadence` or `body` on a seeded
> prompt therefore **forks** it: a new `source: "user"` prompt carries the new words, the original
> is retired through `prompt_library_overrides`, and `action` comes back `superseded` with
> `superseded_prompt_id` naming the row left behind. That row is never deleted — assignments and
> entries point at it. Everything else, and every edit to a `user` or `llm` prompt, is `updated`
> in place.

**`PUT /prompts/{id}/active`** `{active, note}` → the prompt. For a seeded prompt this writes an
override row as well as the column; the column alone does not survive a deploy.

### Generating candidates — phase 103, Aug 20, 2026

Both require `users.is_admin`. Both live on the console's Library tab.

**`POST /prompts/generate`** `{kind, theme?, count, min_age_months, max_age_months, month_tags?,
default_unlock_age?, guidance?}` → `{theme, kind, cadence, completion_mode, model, accepted,
rejected, candidates[]}`. Asks Claude for candidates and **persists nothing**. `count` is exactly
one of `1`, `5`, `10`, `25`. `kind` must be one the generator has a shape for — `question`,
`photo`, `video`, `audio`, `activity`, `letter`; `measurement` has none and is `422`.

`theme` is **optional, and omitting it is a mode rather than a default**. With a theme, the batch
is that theme. Without one, the age band is the whole brief and the model names a theme per
candidate — `prompts.theme` is `NOT NULL`, so something must fill it, and a model choosing is the
only source that is not an invented constant.

`guidance` is free text folded into the brief. It narrows the instruction and **relaxes no rule** —
every candidate is judged either way. A non-empty `month_tags` makes the batch seasonal, which both
stamps those months on every candidate and stops the occasion filter rejecting the occasions the
batch was asked for.

Every candidate comes back, accepted or not, each with `accepted` and a `reasons[]` naming every
rule it tripped. **Rejections are returned rather than dropped** for the reason
`scripts/generate_prompts.py` gives about its worksheets: a batch where half the rows trip one
filter is telling you the brief needs work, and that signal is invisible if the failures are thrown
away. The console lets a human keep a rejected candidate — the filters are a spam trap, not an
editor. Runs on `ANTHROPIC_CANDIDATES_MODEL` (default `claude-sonnet-5`), separate from the
studio's `ANTHROPIC_MODEL`. Unset `ANTHROPIC_API_KEY` is `422` naming the variable, before any
socket opens.

**`POST /prompts/candidates`** `{candidates: [{kind, body, theme, min_age_months, max_age_months,
month_tags?, default_unlock_age?}]}` → `201` `{inserted[], skipped[], queued_total}`. One to
twenty-five. `cadence` and `completion_mode` are **not accepted** — they are derived server-side
from `kind`, so a caller cannot send a pair that disagrees with its own kind.

> **A queued candidate is `source: "llm"`, `active: false`, and nothing serves it — and
> `GET /prompts` hides it from anyone who is not an admin.** That second clause is not
> decoration: this route takes any authenticated caller and filters `active` only when asked,
> so without it a parent could list the queue and read copy no person had reviewed. The
> scheduler filters on `active` and does not look at `source`, so `active: false` is the entire
> distance between a review queue and model-written copy in a real archive — and `prompts.active`
> has a `server_default` of `true` with no application-side default, so this is written
> explicitly rather than omitted. `scripts/review_candidates.py` reads exactly this queue.
>
> **`seed_prompts` cannot retire one** — its retirement sweep is filtered to `source='seeded'`.
> It *can* reach one through the upsert, and only one way: put the same `(kind, cadence, body)`
> in `prompts.yaml` and the `content_hash` matches, which flips the row to `seeded`. That is the
> promotion path and it is a deliberate act of authoring, not an accident.

Two rules are re-checked here whatever the console believed, because `commit` is reachable
without ever calling `generate`: a **bare gendered pronoun** and a **token outside
`PROMPT_TOKENS`**. Both are `422`. Every other filter stays advisory — those two are the ones
whose failure is permanent and invisible, rendering as a misgendered child or as literal braces in
the app, in an export, and in a printed book for as long as the archive exists.

A duplicate `content_hash` is **`skipped`, not an error** — one repeat must not cost the other
twenty-four — and each skip names the `prompt_id` it collided with. The index does not look at
`active`, so a body matching a *retired* prompt is skipped too, and the reason says so.

**`DELETE /prompts/{id}/override`** → the prompt. Removes the override, handing the decision back
to `docs/mission-library.md`. The `active` column is left where it is until the next seed run.

`422 validation_failed` on a body containing a token outside `constants.PROMPT_TOKENS`; `409
conflict` when the resulting `(kind, cadence, body)` already exists.

---

## Admin console

**`/admin`** serves an HTML page — the only non-JSON route in the service, and the only exception
to *"the Fly app serves JSON and nothing else"* in D7. It is not the marketing site: it has one
reader, it is behind a bearer token, and hosting it anywhere else would need CORS and a second
origin to save nothing. See `routers/admin_ui.py` for the full argument. The page holds no
credential and can read nothing without a token, which is why it is unauthenticated and mounted in
every environment.

Every route below requires `users.is_admin` and returns **counts and operational metadata only** —
no entry title or body, no caption, no transcript, no child's name, no object key. That is a
deliberate line rather than an oversight: a console that can page through a family's archive is a
different product with a different threat model. `tests/test_admin.py` plants distinctive strings
in an archive and asserts none of them appears in any admin response.

| Route | Returns |
|---|---|
| `GET /admin/snapshot?days=` | `{overview, growth, themes, signups}` — the whole first screen in one request |
| `GET /admin/library` | The library with per-prompt served/completed counts, `content_hash`, and override state |
| `GET /admin/ops` | `{environment, flags, scheduler, jobs}` |
| `GET /admin/costs?refresh=` | `{providers, total_known_cents, providers_without_pricing}` |
| `PUT /admin/families/{family_id}/trial` | Move or clear one household's trial. **The only write in the console's API, and the only entitlement lever there is** |

**`PUT /admin/families/{family_id}/trial`** — body `{ "trial_ends_at": "2026-09-04T00:00:00Z" | null }`,
returns `{family_id, tier, access, trial_ends_at}`. A date in the future makes the household
`trial`; a date in the past, or `null`, makes it `free`. Added by phase 107.

**It cannot write `tier` and there is deliberately no control that can.** D5 reserves that column
for App Store Server Notifications V2 and a test asserts it has exactly one writer, so a console
button that set it would be a person disagreeing with Apple about who is paying. Moving
`trial_ends_at` reaches both states the console needs without going near it — which is the entire
reason this is the lever rather than a tier switch.

It exists because the owner is the only user and would otherwise never see the free tier he is
designing: set it to yesterday to drop to `free`, to next month to come back. It goes through the
same `LocalWrites` guard as the library edits, so it **refuses while `ADMIN_READ_DATABASE_URL` is
set** — the console reads production and writes only where it can also read what it wrote. The
console hides the control entirely in that state rather than letting it fail after a click.

`snapshot.signups` carries `family_id`, `access` and `trial_ends_at` alongside `tier` so the lever
has a household to aim at and a reader can see which state it is in. None of the three is archive
content, and the line above still holds.

`costs.providers` is **seven cards, and only two of them carry a figure the vendor computed.**
Anthropic (`/v1/organizations/cost_report`) and GitHub (`/users/{account}/settings/billing/usage`)
return real money. Tigris and Apple carry an `amount_cents` **only** when a price setting names
one — `STORAGE_PRICE_CENTS_PER_GB_MONTH` and `APPLE_MEMBERSHIP_CENTS_PER_YEAR` — and both cards
put the variable's name in `detail`, because an estimate that does not say where it came from is
indistinguishable from a measurement. Fly, Neon and Resend carry no figure at all, and
`providers_without_pricing` names them so the total on screen can say what it excludes.

A provider that is not configured is `status: "unconfigured"` with a `setup` sentence naming the
environment variable — **a first-class state, not an error**, so an unconnected vendor is a
to-do rather than a 500 or a blank that reads as zero spent.

`providers[].series` is a daily chart and **is not always money.** Each point is
`{day, cents, value}` and the report's `series_unit` says which field to read: `"cents"` for
Anthropic and GitHub, or the vendor's own unit — `"CU-hours"` for Neon, which publishes no
dollars anywhere in its API. `series_label` names the axis. A client that assumes `cents` will
chart `null` for Neon.

`growth.days` is **gap-filled** — every day in the range is present with zeros. A missing day and a
zero day are different facts and only the server knows which is which.

`ops.scheduler` reads **what the daily job produced**, not whether its deploy was green: a slot ×
day grid of assignment counts, with `silent: true` on any daily slot that served nothing across the
window. That is the instrument PR #57 did not have.

`ops.database` names **which database the numbers came from**, on every load rather than only
when it is unusual — a console that identifies its source only in the surprising case is one
you have to remember to distrust. `{reading: "local" | "remote", host, read_only, note}`, host
only and never a credential.

**`ADMIN_READ_DATABASE_URL` points the console's read routes at another database** — Neon, from
a laptop — without `DATABASE_URL` learning that address, because `make reset-db` runs
`alembic downgrade base` against it. The connection issues
`SET SESSION CHARACTERISTICS AS TRANSACTION READ ONLY` on connect, so Postgres refuses writes
whatever the role permits. While it is set, **every console write refuses with 403** — showing
production and saving to localhost is worse than either alone — and an unreachable target
answers with a sentence naming the setting rather than a driver error carrying the host, the
resolved IPs and the failing username.

`costs` fans out to **seven** vendors concurrently, cached in-process for `BILLING_CACHE_SECONDS`.
The paragraphs above describe which of them carry a figure and which cannot.

---

## Social studio

Phase 97, and **phase 104 added publishing to Instagram.** Admin only.

> ~~*nothing here posts anything — there is no platform integration, no scheduler, and no route
> that reaches the internet*~~ — **struck Aug 20, 2026.** True until phase 104 and kept as
> history. The owner asked for direct publishing and, shown the sentence, did not recognise it:
> it was an agent's stance rather than a row in `decisions.md`.

**Nothing posts on its own.** `SOCIAL_PUBLISH_ENABLED` defaults false and credentials alone do
not switch it on; every publish is a person pressing a button or a time that person chose; the
scheduled runner only publishes rows a person queued. `status: "published"` is still what the
owner sets by hand for a post made somewhere this service cannot reach.

> **Claude does not generate images or video.** There is no such endpoint on any Anthropic
> model. The studio uses the key for what it genuinely does — art direction, copy, captions,
> alt text, image briefs and **scene graphs** — ~~*and shot lists*~~ — and pixels come from one of
> two places: a brand-card template drawn on a canvas in the browser, which needs no vendor and
> no key, or a third-party renderer that is unconfigured until somebody adds one.
>
> **Since phase 120 that second sentence covers video too, and no vendor generates a frame of
> it.** Claude writes a typed scene graph, the console's browser animates it with the same
> `cards.js` that draws a still card, records the canvas with `MediaRecorder`, and posts the
> recording back to be re-encoded as H.264. What was Google Veo — one paid generation per shot,
> joined with ffmpeg — is gone, along with `GEMINI_API_KEY`.

| Route | Returns |
|---|---|
| `GET /social/studio` | Which renderers are configured, the D7 ledger, the templates, palettes and platform sizes a concept may name, and (phase 120) the scene graph's own closed sets and bounds under `video` |
| `POST /social/chat` | **Streams `text/plain`.** The whole conversation goes up each time — nothing stores a thread |
| `POST /social/concepts` | `n` post concepts, schema-enforced: angle, template, palette, headline, subhead, caption, alt text, hashtags, image brief |
| `POST /social/treatment` | A typed **scene graph** for a short vertical video, plus the WebVTT track **derived** from it. ~~*`POST /social/shot-list` — a shot list plus a caption track*~~, replaced by phase 120 |
| `GET\|POST /social/assets`, `PATCH /social/assets/{id}` | Saved posts |
| `POST /social/assets/{id}/render` | Hands the image brief to a photographic provider. Unconfigured → the environment variable to set |
| `GET /social/account` | Which Instagram account the credentials control, and whether now is a reasonable time to post. Read from Instagram, never from our own rows |
| `POST /social/assets/{id}/image` | Stores the card the browser drew. **Raw JPEG body**, 4MB cap, magic number checked |
| `POST /social/assets/{id}/publish` | Publishes now, or queues for `scheduled_for`. **A too-soon `409` leaves the attempt queued** — see below |
| `GET /social/publications` | The publish queue and what became of each attempt |
| `POST /social/publications/{id}/cancel` | Takes a scheduled post out of the queue. Never legal after it has gone out |
| `POST /social/assets/{id}/video` | Stores the video the browser just recorded. **Raw WebM body**, 64MB cap, EBML magic number checked, re-encoded to H.264 MP4. **200 with the finished render row** — ~~*202 with a render id to poll*~~ |
| `GET /social/assets/{id}/video` | The newest render attempt for this post, or `null` |
| `GET /social/renders/{id}/file` | A short-lived presigned URL for the file a render produced. `404` when it produced none, carrying the reason |

### Publishing to Instagram

**Instagram does not accept an image upload.** You give Meta a public HTTPS URL, it fetches the
image itself, and you publish the container it built. The card is drawn on a canvas in the
browser, so it has to reach the bucket first — and then Meta is handed a **presigned GET**, so
no object is ever world-readable. Verified against the live account: Meta's fetcher does not
mind the `X-Amz-*` query string.

**`POST /social/assets/{id}/image` is one of two routes in this API that take bytes through the
service** — ~~*the one route*~~, until phase 120 added `POST /social/assets/{id}/video` on the
identical argument — rather than handing back a presigned PUT. A browser cannot PUT to the bucket without a
CORS policy on the bucket, and that bucket holds the archive — widening what a browser origin
may do against it to publish a marketing card is the wrong trade. The card is capped at 4MB and
checked to start with JPEG's magic number, because Meta reports a PNG as a container in `ERROR`
rather than as a message naming the format.

**The account is shared with the marketing repository**, by the owner's decision of Aug 20,
2026 — one feed, two publishers, no shared database. So the minimum gap between posts and the
24-hour count are both read from `GET /{ig-user-id}/media`: Instagram is the only thing both
systems can see. A `409 conflict` from the publish route usually means the *other* publisher
posted recently.

**Publishing twice is the only unrecoverable failure here**, so the order is: refuse if the
asset already went out or already has a queued attempt, ask Instagram whether the caption is
already on the account, ask whether it is too soon, build the container and **write its id to
the row**, then publish. `social_publications` keeps the media id, the permalink, and the
caption that actually went out.

Each of those writes is **committed as it happens**, not at the end of the request. One
transaction per request is the rule everywhere else in this API; here it would mean a failure
rolling back the record of itself, including the container id written specifically to survive
it. `services/broadcast.py` reached the same conclusion for the same reason.

The cost is a row that a dying process can leave in `publishing`, which the partial unique index
then makes permanent. `python -m rascal.jobs.social` resolves those at the start of every run by
asking Instagram whether the post is on the account: found → recorded, not found → failed and
the asset is free again. **It never re-sends** — a container that was built and not published is
not a post, and re-sending it is precisely the duplicate this design exists to avoid.

A `409 conflict` from the publish route is one of: the asset already went out, an attempt is
already queued, it is too soon to post, the caption matched a post another attempt already owns,
or another runner claimed the row first. All are readable sentences, and none is a 500.

**One of them is a deferral rather than a refusal, and it is worth reading twice.** *Too soon*
leaves the attempt **queued**: the row goes back to `scheduled` and the hourly runner publishes
it once the gap has passed. So a caller that pressed publish, saw a 409 and stopped will get a
post up to an hour later. The console re-reads `GET /social/publications` after any publish
error for exactly this reason — the queue on screen is the answer to *"did that do anything"*,
and the error text alone is not.

**`POST /social/chat` checks its credential before the response starts.** A `StreamingResponse`
spends its status code the moment headers are sent, so an exception inside the generator
cannot become a 422 — it becomes a truncated body the browser reports as a network error.
A missing key is therefore an ordinary error response; anything that fails mid-stream writes
its reason into the body as text instead.

**`featured_prompt_id` on `POST /social/assets` is the only way a mission-library body reaches
a post.** The body is read server-side from that id and never accepted as text, and using one
consumes a unit of the cap in `GET /social/studio` — see `docs/data-model.md`'s
`social_assets`, and D7 for why there is a cap at all.

**`template` and `palette` are closed sets, not free strings.** They accept only the values in
`services/social/brand.py` — `quote`/`prompt`/`stat`/`announcement` and
`cream`/`terracotta`/`periwinkle`/`sage`/`ink` — and anything else, including `""`, is a 422.
The renderer lives in the browser and can only draw these; before phase 101 the field was a
free string and `models/social.py` described a validation that nothing performed, so the
console's own dropdown could save an empty palette that no card could be drawn from. `GET /social/studio` returns both
lists, so a client never has to hard-code them.

### Video, and the fact that nothing buys one

**`POST /social/treatment` returns a scene graph, not film direction.** An ordered list of 2 to 10
scenes; each names a `template` and a `palette` from the same closed sets a still card uses, a
`transition` from `cut | fade | rise`, its copy, and a `duration_ms` between 1200 and 8000. The
whole thing must total between 6000ms and 60000ms. Every one of those is a `422` on both sides —
too short, too long, too few scenes, too many, and an unknown or empty value anywhere.

~~**`POST /social/assets/{id}/video` answers 202 and does the work afterwards.** Seven shots are
seven generations plus a concatenation and it takes minutes, so the response is a render row and
the console polls `GET` for `shots_done` of `shots_total`.~~ — **struck by phase 120.** It is now
the same shape `POST /social/assets/{id}/image` already had: **the browser is the renderer**, and
this route takes the bytes it recorded. `Content-Type: video/webm`, raw body, 64MB cap, and the
EBML magic number is checked for the same reason the JPEG one is — a wrong format otherwise
surfaces as a downstream error naming neither the format nor the file. The server re-encodes with
`libx264 -profile:v high -pix_fmt yuv420p -r 30 -an -movflags +faststart` and answers **200 with
the completed `social_renders` row**. There is nothing to poll: it is a few seconds of CPU.

**The re-encode is never a stream copy, and that is load-bearing.** `MediaRecorder` writes an
*unknown* duration into the WebM header, so anything that trusts the input's duration gets
nothing; the re-encode recomputes timestamps from the frames. `-pix_fmt yuv420p` is the flag
between a file Instagram accepts and one it rejects.

**The caption track is derived on every write, and cannot be set by a caller.** One cue per
scene, cue boundaries exactly equal to the cumulative scene durations.

Be precise about what changed, because the loose version of this is wrong. The track was derived
before phase 120 too — the model never authored one, `SHOT_LIST_SCHEMA` had no caption field, and
`renderers.caption_track(shots)` computed it server-side. **It was then stored in an editable
column that nothing recomputed**: a `PATCH` could overwrite it, and editing the shots left a track
describing the previous video. Both were reachable through this API and nothing compared them.

So `caption_track` and `duration_seconds` are now **not settable at all** — a `PATCH` carrying
either is accepted and neither value lands — and the derivation runs on every path that can set
the scene graph.

~~Clips are stored and costed **as they land**, so a job that fails on shot six still reports what
it spent. `cost_cents` is derived from `GEMINI_VIDEO_CENTS_PER_SECOND`.~~ — **struck.** There are
no clips. `cost_cents` is **`0`**, written down rather than dropped, on the success path and the
failure path alike: a ledger that stops recording when the number becomes zero cannot show you it
went to zero.

**A failed transcode is a `422` carrying ffmpeg's last line, and it still writes a `failed` row.**
An error that leaves no trace of the attempt makes *it did nothing* and *it failed* the same
event. The same is true of a bucket that would not take the bytes.

**A recording materially shorter than its scene graph is refused, and that is the server half of
a guard the browser also applies.** After the re-encode the server probes the output's duration
and compares it to the sum of the scene durations; more than 0.25s short is a `422` and a `failed`
row saying so. The console refuses to record in a backgrounded tab because
`requestAnimationFrame` does not fire in one and the file comes out *silently short* — right
container, right codec, playable, missing whatever the tab spent hidden. That is the browser
promising; this is the server checking, and it holds against a tab the browser mis-detected, a
recorder that dropped frames, and anything at all posting to this route. A correct recording is
one frame long — the extra `requestAnimationFrame` after the final draw — which is what the
tolerance is sized for. An *unreadable* duration is not a refusal.

**Alt text is required to move an asset to `exported` or `published`**, and the check is at
that moment rather than at creation: a rule enforced while somebody is still typing is a rule
that gets switched off.

---

## Debug (local only)

Registered only when `ENVIRONMENT == "local"`, same gating as `dev-login`. These exist
because building the daily loop means running the daily loop dozens of times in one
evening, and waiting until 5am tomorrow is not a development strategy.

**`POST /debug/board`**
Body: `{ child_id }` → resets today to exactly one assignment per *kind*. **A test fixture, not
a scheduler**, and the distinction is why it exists: the real scheduler fills *slots* — a
question, a photo mission, a second mission — so it cannot produce one of every kind on demand,
and exercising the photo and video paths otherwise meant hand-editing rows.

*Added to this document Aug 17, 2026. It had shipped without an entry here, which the phase 72
sweep found by diffing the served routes against this file — the only route in the service that
was missing.*

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

Thirteen tokens, one dictionary, no logic. Settled Aug 11, 2026 — see `docs/decisions.md`. **This line said *fourteen* until Aug 18, 2026**; the table below, `constants.PROMPT_TOKENS` and the iOS `knownTokens` have always held thirteen. A client written against the old count was never wrong on the wire — the number was decoration and the table is the contract.

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

1. Text containing no tokens passes through **byte-identical**. ~~the 113 seeded prompts are literal
   he/him, contain no braces, and are never rewritten~~ — **struck Aug 18, 2026: that inverted on
   Aug 13.** Phase 24 tokenised the library and phase 25 grew it to **133**; the seed loader now
   *rejects* a body containing anything outside `constants.PROMPT_TOKENS`, and zero seeded bodies
   carry a literal `he/him/his`. The invariant itself is unchanged and still holds — **token-free
   text passes through untouched** — but the example it leaned on is now the opposite of the truth,
   and a reader who took it literally would conclude the renderer is never exercised in production.
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
| `credential_in_use` | 409 |
| `last_credential` | 409 |
| `conflict` | 409 |
| `subscription_required` | 402 |
| `rate_limited` | 429 |
| `sign_in_link_invalid` | 401 |
| `publish_failed` | 502 |
| `internal_error` | 500 |

Validation failures set `field`. Nothing ever returns a stack trace or a raw SQL error —
a `psycopg` message in a client alert is a leak, not a debugging aid.

`publish_failed` is **502 rather than 500** because this service worked and the platform it
called did not — an expired token, an image Instagram could not fetch, a limit on their side.
The console shows the platform's own sentence next to the button; what it never shows is a raw
provider payload or the access token, which `services/social/instagram.py` strips first.

---

## Marketing signup

**`POST /v1/subscribe`** — unauthenticated, and the first browser client this API has ever had.

```json
{ "email": "parent@example.com", "turnstile_token": "0.abc…", "source": "home" }
```

→ `202`

```json
{ "status": "ok" }
```

**The same body for every outcome that is not an outage.** New address, already subscribed,
already unsubscribed — all `202` with `{"status":"ok"}`. Anything else turns the route into an
oracle that tells any caller whether a given address is on the list, and anyone with a browser is
a caller.

`202` rather than `201`: **nothing is created here.** The list is Resend's per `decisions.md` open
item 12(4) — there is no `subscribers` table — and the subscription is not real until they click
the confirmation link.

**Double opt-in is ours, not the provider's — corrected Aug 18, 2026 by phase 88.** This section
said Resend ran it. **It does not**: a contact posted to Resend's contacts API is live
immediately, no confirmation mail is generated, and there is no pending state. That was believed
from documentation until the first real signup landed `Subscribed` with an empty inbox, while the
marketing page promised a link to click. The contact is now created **unsubscribed**, and the
route below is the only thing that flips it. A broadcast expands to subscribed contacts only, so
an unconfirmed address is never mailed.

| Failure | |
|---|---|
| `422` `validation_failed`, `field: "turnstile_token"` | The token was absent, expired or already spent. **Absent is a rejection, never a skip** |
| `422` `validation_failed`, `field: "email"` | Not the shape of an address |
| `503` | Turnstile is unconfigured or unreachable, or the list is. **Never a silent success** |

Delivery of the confirmation mail happens **after** the response and cannot change it — the same
shape `POST /auth/email/start` uses. A send that fails costs a confirmation, not the signup.

---

**`GET /v1/subscribe/confirm?token=…`** — opened from an email client, by a person, in a browser.

→ `303`, always. **Never JSON, including on failure.** Someone arriving here clicked a link in
their mail; showing them `{"error": …}` would show an API response to somebody who does not know
they are talking to an API. The outcome travels as a query parameter on `MARKETING_SITE_URL` so
the page can say the right sentence.

| Redirect | When |
|---|---|
| `…/?confirmed=1` | Confirmed. The contact is now subscribed |
| `…/?confirmed=0` | Unknown, malformed, expired, or minted for another purpose — **one answer for all four**, because telling them apart would say whether a link ever existed |
| `…/?confirmed=retry` | Resend is down or unconfigured. **Distinct from a bad link**: this failure is ours and the link is still good |

**Unauthenticated by necessity** — the token *is* the credential, and holding it is the proof
that the address receives mail, which is the whole of what double opt-in asks.

**The token is a signed JWT carrying the address, and nothing is stored.** It is not a row and
there is nothing to look it up in; see `services/subscribe_token.py`. It carries a `typ` claim
distinct from an access token's, so one secret's signatures are not interchangeable across
purposes. Two consequences worth stating rather than discovering:

- **Unconfirmed and unsubscribed are the same state at Resend** and cannot be told apart. Correct
  for sending — neither gets mail — and wrong for counting.
- **A link confirms every time it is opened**, for its whole life. Somebody who confirms,
  unsubscribes, then reopens the original mail is resubscribed. Single use would require state,
  which is the thing this design avoids; `SUBSCRIBE_CONFIRM_TTL_DAYS` bounds it instead.

**Turnstile is the entire protection.** There is no rate limit on this route, by the owner's call
of Aug 16, 2026 (open item 12(1)) — so a missing `TURNSTILE_SECRET_KEY` **refuses** rather than
skipping the check. Skipping would leave the health check green while the endpoint stood open,
which `roadmap-status.md` names as the defect this phase was written to design against. Cloudflare
being unreachable is a `503` for the same reason: failing open would let an outage at their end
silently open ours.

**CORS is allowlisted to `MARKETING_ORIGINS`, never `*`**, and applied to this route's methods
alone (`POST`, `OPTIONS`) with no credentials. An empty allowlist means no browser origin is
permitted — a refusal a deploy can see — rather than a wildcard nobody notices.

`source` names the page or campaign and reaches a log line only; the contact belongs to Resend.


~~**This endpoint does not exist.** It is not implemented, routed, or callable; this records the
shape phase 60 will build.~~ — **struck Aug 18, 2026: phase 60 built it on Aug 17.**
`POST /v1/subscribe` is implemented in `routers/subscribe.py`, mounted, and callable, with Turnstile
verified server-side and the list held at Resend. **It is the one route in the service with no rate
limit**, by the owner's call of Aug 16 recorded in open item 12(1) — Turnstile is the whole
protection there and it fails closed. The decisions are D7, D8 and D8a in `docs/decisions.md`, and open item
12 records what is deliberately still unanswered.

**`POST /v1/subscribe`**
Body: `{ email, turnstile_token }` → *would* answer **always `202`**, body
`{ "status": "accepted" }`.

**Unauthenticated — the only write endpoint outside `/auth` that would be.** That is a deliberate
exception and the reason the rest of this section exists.

**Turnstile is verified server-side, and a missing or failed token is a rejection rather than a
warning.** `422` `validation_failed` with `field: "turnstile_token"`. A client-side widget alone
protects nothing: the widget is JavaScript on a static page, and anybody can `curl` the endpoint
without ever loading it. The check that counts is the server calling Cloudflare's verification API
with `TURNSTILE_SECRET_KEY` and refusing on anything but success — **including on its own inability
to reach Cloudflare.** Failing open here would be indistinguishable, in production, from having no
protection at all, and by decision this endpoint carries no rate limit to fall back on.

**The endpoint would forward to Resend and store nothing locally. That is a decision, not an
omission.** There is no `subscribers` table, by design — see open item 12(4) and `data-model.md`.
Resend owns suppression, unsubscribe and sending reputation; **double opt-in is ours as of phase
88**, and costs no rows — the confirmation is a signed link, not a record. **The named trigger
for changing this is the first moment a subscriber can also be a user**, which is post-launch;
until then the endpoint is a thin forward and nothing here needs to know about `users`.

**Double opt-in is Resend's, and it is a legal requirement across most of the addressable market
rather than a nicety.** The `202` means *the confirmation request was accepted*, never *this
address is subscribed*. Nothing is on the list until the recipient clicks.

**The response must not reveal whether an address was already subscribed.** Same status, same
body, every time — a known address, a new address, and a suppressed one are one answer. This is
the same rule as `POST /auth/email/start`'s unconditional `202`, for the same reason: a public
endpoint that answers "is this person on the list?" is an enumeration oracle, and it is the
second-order version of the spam problem Turnstile is there to solve.

**No rate limit**, by the owner's decision of Aug 16, 2026 — Turnstile is the whole gate. Recorded
explicitly because the limiter phase 57 built for `/auth/email/start` is right there, and the next
reader will otherwise assume its absence here was an oversight. If Turnstile proves insufficient,
reusing that limiter is the fix and it is a small one.

**CORS: allowlisted to the marketing origin only**, one entry, from `MARKETING_ORIGIN`. No CORS
middleware is configured on this app today; this endpoint is what introduces it, and it must not
be introduced as a wildcard.

**Timing.** ~~The endpoint and the page it serves may ship before the P0 behavioural gate. **No
marketing email sends before that gate passes** — the send job is a separate, later phase, and
nothing in this section authorizes one.~~ — **struck Aug 22, 2026 (phase 111). Both halves are
overtaken.** The send job shipped as phase 69, and the owner lifted the gate on Aug 22: the daily
broadcast has been arming and sending since Aug 19, 2026. **This paragraph is one of four places
that carried the holding after it was lifted**, and it survived the first correction pass because
that pass edited this file for an unrelated pointer without grepping it for the sentence — the
same failure the strike in `blocked.md` §13 records. The evidence is in `blocked.md` §13 under
*"The broadcast is live, and that is intended"*.

---

## Monetization

~~**No endpoint in this section exists.**~~ — **struck Aug 20, 2026. The two routes below are
built and routed**, as phase 37a: `GET /families/{id}/entitlement` and
`POST /webhooks/app-store`, on migration `0019_app_store_transactions`. Everything *else* this
section describes is still unbuilt, and the headings say which is which.

**What is built has never been exercised against Apple**, and that is a different sentence from
"it works". No subscription product exists in App Store Connect, no sandbox transaction has ever
been made, and no real Apple notification has ever reached this endpoint — `docs/blocked.md` §10 is
the errand that changes that. The verification below is tested against synthetic payloads signed by
a locally-minted chain.

The decisions are D1–D6 in `docs/decisions.md`, and the tables are in `docs/data-model.md`.

### The entitlement is read from the server, always

**`GET /families/{id}/entitlement`** — **BUILT.** Any guardian of the household. Returns the
household's tier and, when lapsed, the computed deletion-eligibility date.

**Authorization is `deps.family_access`**, which compares the path id against the caller's
`users.family_id`. Another household's id is `403 not_authorized`, never `404` — **and so is an
id that belongs to nobody**, which is what stops this route being an enumeration oracle over
household ids. It is the newest route that takes a forgeable id and answers with billing state,
so the property is pinned rather than assumed:
`tests/test_authorization_sweep.py::test_an_invented_household_is_indistinguishable_from_somebody_elses`.

**`GET /families/me` reports the same `tier` and `access`, and they never disagree**, because
both read one `entitlements` row through one function. That is one authority with ~~two~~ **three**
shapes — the household screen, the subscription screen, and (since phase 107) a Today board that
has to explain why half of it is locked — and not three answers to "is this household subscribed",
which is the bug D4 and D5 exist to prevent.

```json
{
  "family_id": "...",
  "tier": "free",
  "access": "free",
  "trial_ends_at": "2026-08-07T00:00:00Z",
  "lapsed_at": "2026-05-01T00:00:00Z",
  "eligible_at": "2028-05-01",
  "plan": null,
  "billing_retry": false,
  "media_storage_tier": "hot"
}
```

~~*`"media_storage_tier": "archive"`*~~ — **corrected to `"hot"` on Aug 22, 2026 by phase 113.
The example documented output the server cannot produce.** The field is a hardcoded Python
default on `EntitlementOut` and is not a read of anything, exactly as the paragraph below this
example has always said — so `"archive"` was unreachable, and an example that contradicts its own
prose two lines later is worse than no example. **Nothing about the field changed**; phase 113
only stopped the contract from describing a value no household has ever been sent. It becomes a
real read when phase 38 adds `media.storage_tier` and D3's move to the Tigris Archive tier at 90
days lapsed lands.

**`plan` and `billing_retry` are the same two values `GET /families/me` reports**, from the same
function over the same ledger row — one authority, two shapes, in the pattern `access` already
follows. See the phase 113 section under `GET /families/me` for what each null means. **Neither
gates anything on this route either.** `is_payer` and `lapsed_at` are not repeated here:
`lapsed_at` was already on this shape, and `is_payer` is about the *caller*, which is a household
question rather than a subscription one.

**`access` is `"subscribed" | "trial" | "free"`, computed per request and never stored:**

```
entitled = (tier == "subscribed") or (trial_ends_at is not None and now_utc() < trial_ends_at)
access   = "subscribed" if tier == "subscribed" else ("trial" if entitled else "free")
```

**`subscribed` beats `trial`**, so a subscriber holding a stale future `trial_ends_at` reads
`subscribed` and is never rendered as a household on a countdown. **There is no `trial` tier and
there is deliberately not going to be one** — `tier` has exactly one writer by D5 and a trial that
wrote it would be a second, running on a clock rather than on a receipt. The trial is
`entitlements.trial_ends_at`, a column beside it. Every household gets fourteen days when its row
is created.

**`trial_ends_at` is `null` when there is no trial on the household**, which is a real state
rather than a missing value — it is what the admin console's Clear button produces. It is carried
for copy and a client must not compute entitlement from it.

**A trial expiring is not a lapse.** `lapsed_at` stays `null` through one and `eligible_at` stays
`null` with it, so a household that tried the app for a fortnight and stopped never has a deletion
clock pointed at it. `eligible_at` below is still computed from `tier` and `lapsed_at` alone.

**`eligible_at` is computed per request**, never stored — `max(lapsed_at + 24 months,
last_sign_in_at + 12 months)`, and both clocks move. A client may display it and must not cache it.
It is `null` while `tier` is `subscribed`: there is no deletion clock on a paying household.

`last_sign_in_at` is a **`MAX` over `users.last_sign_in_at` across the household's guardians**, not
the caller's own. A household stays active because *somebody* is opening the app, and reading only
the caller would start the clock on a family where the other parent uses it daily. There is no
`last_sign_in_at` column on `entitlements` and one must not be added — see `docs/data-model.md`.

**`media_storage_tier` is the constant `hot` today, not a read.** D3's move to the Tigris Archive
tier at 90 days lapsed is phase 38 and `media` has no `storage_tier` column yet. The field is
reported now so the client that will show it does not need a second response shape later.

**The device never decides whether a household is subscribed.** A StoreKit transaction on the phone
is a receipt, not an entitlement, in exactly the way an Apple identity token is a credential and not
the identity model. Every gate reads the server, for the same reason the server owns what day it is.

### Sign in with Apple server-to-server notifications

**`POST /webhooks/apple-signin`**
Body: `{ payload }`, where `payload` is a JWT signed by Apple → `202`, `{ "status": "..." }`.

Unauthenticated in the bearer sense and **authenticated by signature** — the same shape as the
App Store hook below, and designed beside it for that reason. The payload is verified against
Apple's JWKS with the same cached fetcher `POST /auth/apple` uses. **The signature is the only
thing standing between a stranger and revoking somebody's session**, so an unverifiable payload
is `401` rather than logged and accepted.

Two claim-set differences from an identity token, both of which reject every real notification
if you get them wrong: `sub` is **not** a top-level claim (it lives inside `events`), and there
is no `exp`. And `events` is a JSON **string**, not an object — decoding twice is mandatory.
`event_time` is in **milliseconds**.

| Event | Behaviour |
|---|---|
| `consent-revoked` | Set `credentials.revoked_at`; revoke every refresh token for that user. **Never touches `users` or the archive.** Recoverable by signing in again. |
| `account-delete` | **Identical to `consent-revoked`.** The Apple ID was deleted; the archive was not. See `docs/decisions.md` — this is a decision, and "fixing" the duplication would delete somebody's archive on a third party's say-so. |
| `email-disabled` | `users.email_deliverable = false`. |
| `email-enabled` | `users.email_deliverable = true`. |

**Always `202` once the signature verifies**, including for an event type or a subject this
service does not know. Apple retries anything that is not 2xx, so a 4xx is a promise to handle
something later; and a `404` for an unknown subject would tell an unauthenticated caller which
Apple IDs have accounts here.

`email_deliverable` is a **safety interlock, not bookkeeping**, and it is not a third consent
lane: `marketing_consent` and `transactional_consent` record what a parent chose, this records
whether the channel physically works. A private relay can be switched off silently — no bounce,
no error — and D3's hard stop is that deletion may not fire without a notice confirmed
delivered. Nothing reads it yet; phase 38 does.

### App Store Server Notifications V2

**`POST /webhooks/app-store`** — **BUILT.** Unauthenticated in the bearer sense and authenticated
by signature. Accepts Apple's V2 notification, verifies the signed payload, and writes the
entitlement.

Body: `{ "signedPayload": "<JWS>" }` → `202`, `{ "status": "..." }`. The status names what the hook
did — `tier:subscribed`, `ignored:out-of-order`, `recorded:unattributed`,
`recorded:demotion-refused`, `recorded:no-tier-change` — because the only other way to find out is
to read the logs of a machine you may not be able to reach.

**Verification is the whole security model.** The `x5c` chain must be exactly three certificates,
must terminate at the **Apple Root CA - G3** bundled in the repository rather than fetched at
request time, must carry Apple's marker OIDs on the leaf and the intermediate, must be valid at the
payload's own `signedDate`, and the leaf must actually sign the payload. Apple's official
`app-store-server-library` does this; it is not hand-rolled. An unverifiable payload is **`401`**,
the same rule `POST /webhooks/apple-signin` follows.

**The trust anchor is absent from the repository and the endpoint fails closed until it is not.**
With no root certificate present every notification is refused with `401`. See
`api/src/rascal/certs/appstore/README.md` for the one command that fixes it.

**Decoding is nested, and the nesting is where implementations get it wrong.** The outer payload
carries `notificationType`, `subtype`, `signedDate` and `data`. Inside `data`,
`signedTransactionInfo` and `signedRenewalInfo` are **themselves JWS strings** and are verified and
decoded separately — reading `data.transactionInfo` as an object yields nothing, silently, forever.
Both nested payloads are *verified*, not merely decoded: an outer envelope Apple signed carrying an
inner transaction Apple did not is the shape of a forged upgrade.

#### The client obligation: `appAccountToken`

~~**Phase 37b must set `appAccountToken` to the purchasing user's `family_id` on every StoreKit
purchase.**~~ — **honoured by the client, Aug 20, 2026.**
`SubscriptionStore.purchase(_:familyID:)` in `ios/Rascal/Rascal/Subscription/SubscriptionStore.swift`
is the only call to `Product.purchase(options:)` in the app, and its only option is
`.appAccountToken(familyID)`. The `familyID` argument is **non-optional**, and the only state that
carries one is `SubscriptionModel.Phase.ready(_, familyID:)` — so a purchase cannot be started from
a screen that does not know the household, rather than being started with a substituted token. Two
tests pin it: one behavioural, that the id reaching the boundary is the one `GET /v1/families/me`
returned, and one that reads the source and fails if the argument is ever anything but `familyID`.

**What is still unproven, and it is the assumption this whole design rests on:** no sandbox purchase
has ever been made, because no product exists in App Store Connect (`docs/blocked.md` §10). **The
round trip — token attached here, echoed by Apple, read by this webhook — has never been observed
end to end.** Both halves are built against the same field name and nothing has ever carried a value
between them.

Apple's notification does not know what a family is. `appAccountToken` — a UUID the client attaches
at purchase time and Apple echoes back in `transactionInfo` — is the **only** channel by which one
can travel. A purchase made without it produces an orphan receipt that no server-side process can
ever attribute to a household: not a job, not a migration, not a support tool. It is unrecoverable
without a support conversation with the person who paid, and the transactions already made that way
stay unattributable forever.

The server's side of this is already built and deliberately forgiving: a missing or malformed
`appAccountToken` is recorded with a null `family_id` and a warning, never an exception and never a
4xx. That forgiveness is what keeps Apple from retrying forever; it is not a fallback that recovers
the attribution, because none exists.

#### What each notification does to `tier`

**This is the only path that may set `entitlements.tier`.** A test asserts it stays the only one.

| `notificationType` | Subtype | Effect |
|---|---|---|
| `SUBSCRIBED` | `INITIAL_BUY`, `RESUBSCRIBE` | → `subscribed`, `lapsed_at` cleared, payer recorded |
| `DID_RENEW` | any | → `subscribed`, `lapsed_at` cleared |
| `DID_CHANGE_RENEWAL_STATUS` | `AUTO_RENEW_DISABLED` / `AUTO_RENEW_ENABLED` | **no change.** Cancelling auto-renew is not lapsing — the household is paid up until `expires_date`, and demoting here bills them for time they do not get |
| `DID_FAIL_TO_RENEW` | `GRACE_PERIOD` | **no change** — Apple is still retrying the card |
| `DID_FAIL_TO_RENEW` | none | → `free`, `lapsed_at` = `signedDate` |
| `GRACE_PERIOD_EXPIRED` | — | → `free`, `lapsed_at` = `signedDate` |
| `EXPIRED` | any | → `free`, `lapsed_at` = `signedDate` |
| `REFUND` | — | → `free`, `lapsed_at` = `signedDate` |
| `REVOKE` | — | → `free`, `lapsed_at` = `signedDate` |
| `DID_CHANGE_RENEWAL_PREF` | any | no change — monthly↔annual is a *plan change*, which D5a's single subscription group is what makes true |
| `REFUND_REVERSED`, `REFUND_DECLINED` | — | **recorded, no change — and this is a known gap, not an oversight.** A reversed refund means the customer should have access back, and this does not give it to them. The row is written, so it is recoverable by hand from `app_store_transactions`; restoring automatically is a decision nobody has made |
| `TEST` | — | recorded, no change. This is what App Store Connect's *send a test notification* button produces, and it is the first real payload this endpoint will ever receive |
| anything else | — | recorded, no change, `202` |

**The subtype spellings above are Apple's own**, taken from `appstoreserverlibrary.models.Subtype` rather than from prose. `AUTO_RENEW_OFF` and `AUTO_RENEW_ON` — which an earlier draft of this table used — are **not values Apple sends**, and a branch or a test written against them would never match anything while looking entirely correct. A test pins every notification string this service branches on against Apple's enums.

**`lapsed_at` is Apple's `signedDate`, never "now".** D3's two clocks run from when Apple decided;
dating a lapse to when we happened to hear about it moves a deletion horizon by however long the
retry took.

**`payer_user_id` is recorded only when the household has one guardian.** `appAccountToken` carries
a *family* id, so Apple never names a user. With two guardians there is no way to tell which one
paid, and a wrong payer is worse than a null one — D3a's win-back writes to the payer, so guessing
means emailing the wrong parent about the other one's cancelled card.

**Phase 113 put this column on the wire as `is_payer` and did not make it any more knowable.**
`GET /families/me` reports `is_payer: bool | null` computed for the calling user; **`null` means
unknown and never `false`**, so a household whose payer was never recorded still shows every
guardian Apple's subscription-management control. **Two ways to populate the two-guardian case were
considered and both are unsound** — extending `_set_payer` to `DID_RENEW` writes whichever guardian
*remains* after the real payer has left the household, and narrowing that to households that have
only ever had one member cannot be expressed: `guardians` is keyed `(user_id, child_id)` with no
`family_id`, membership is `users.family_id`, and a user who leaves leaves no row. There is no
membership history to query. `docs/blocked.md` §21 carries both, and the only real fix — a client
that tells us who transacted — with the shape it would need.

**Note the one thing that is not a gap here:** a resubscribe arrives as `SUBSCRIBED` with subtype
`RESUBSCRIBE`, not as `DID_RENEW`, so it already reaches `_set_payer`.

#### Three rules that matter more than the table

**Out-of-order delivery is normal.** Apple retries, and retries arrive interleaved with new
notifications, so an `EXPIRED` can arrive *after* the `RESUBSCRIBE` that superseded it. Anything
whose `signedDate` is older than or equal to the stored `latest_signed_date` for its
`originalTransactionId` is recorded as ignored and writes nothing. Redelivery of the same
notification is caught by the same comparison, so idempotency needs no separate mechanism.

**Sandbox may never write a Production entitlement.** A sandbox tester account is free to create.
Under `ENVIRONMENT=prod` a Sandbox notification is recorded and touches neither `tier` nor the
row's family attribution.

**A family with no transaction record is never demoted.** `runbook-deploy.md` §7a wrote the owner's
household `subscribed` by hand and there is no Apple transaction behind it. A demotion is refused
unless an `app_store_transactions` row already links that family to that `originalTransactionId` —
and a refused demotion does not record the attribution it was refused for, or the guard would be a
one-notification delay rather than a guard.

**The accepted cost of that guard, stated plainly**: a household that genuinely lapses on a
subscription this server never saw begin — bought before the webhook existed, or during an outage
long enough for Apple to give up retrying the `SUBSCRIBED` — stays `subscribed` until somebody
reconciles it by hand. That is the deliberate direction to fail in. Over-granting costs a
subscription; under-granting locks a paying family out of their own archive, and the specific family
it would lock out first is the owner's.

**Attribution falls back to the ledger when a notification carries no `appAccountToken`.** The token
is attached at purchase time, and the notification that matters most — the `EXPIRED` a year or two
later — is the one furthest from that purchase. If the attribution had to arrive on every payload, a
household that stopped paying would keep `subscribed` forever. The row fallen back to *is* the
transaction record the guard above asks for, so this is the same evidence rather than weaker
evidence; a family with no row has nothing to fall back to.

**One `originalTransactionId` belongs to one environment.** A payload whose environment disagrees
with the row already recorded for that transaction is refused outright — `202`, logged at warning,
nothing written. Recording it would mean a Sandbox payload advancing `latest_signed_date` on a
Production subscription, after which every legitimate Production notification would look stale and
the household's tier would freeze wherever it happened to be. The transaction id is the primary key,
so there is no second row to put it in: the choice is refuse or corrupt.

This is the **only** path that may set `tier`. A subscribe, a renewal, a cancellation, a billing
failure and a refund all arrive here, which is what keeps one authority over the answer — and is why
Apple Family Sharing is not enabled on the subscription: it would create a second opinion about who
is entitled, and two authorities that can disagree about the same fact is the shape of bug this
contract avoids everywhere else.

A notification for a family this server does not recognise is recorded and acknowledged, never
rejected — Apple retries, and a 4xx to a real notification is an entitlement that silently never
lands.
