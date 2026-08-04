# RASCAL — blocked, and deliberately deferred

Two lists. The first is things I could not finish because they need something only you can
provide. The second is things I chose not to build, with the reasoning, so you can overrule
any of them.

Nothing in either list blocks the backend from running. `cp .env.example .env && make up &&
make migrate && make seed && make test` works today, and the acceptance test drives the
whole daily loop end to end.

---

## Blocked on you

### 1. Apple Developer enrollment — blocks real Sign in with Apple

`POST /v1/auth/apple` is fully implemented and tested: it fetches and caches Apple's JWKS,
verifies the signature, and checks `iss`, `aud` against `APPLE_BUNDLE_ID`, and `exp`. The
tests generate a local RSA keypair and stub the JWKS fetch, so the verification logic is
exercised without the network.

What it cannot do is accept a token from a real device, because the `aud` claim has to match
a bundle id from an enrolled team.

**What I need from you:** the bundle id, once enrollment clears. Set it and nothing else
changes:

```bash
fly secrets set --app rascal-api APPLE_BUNDLE_ID="com.yourname.rascal"
```

**Meanwhile:** `POST /v1/auth/dev-login` returns a real session with real tokens against a
fixture account, and it works for curl and for the iOS client. It is registered only when
`ENVIRONMENT == "local"`, and `tests/test_auth.py` builds a production app and asserts the
route does not exist.

### 2. AWS credentials — blocks a real upload round-trip

Presigning, multipart planning, and completion are implemented and tested against `moto`, so
the request and response shapes are correct and the multipart flow works. Nothing has been
uploaded to a real bucket, because there is no bucket and no credential.

**What I need from you:** run section 2 of `docs/DEPLOY.md` (bucket, public-access block,
versioning, encryption, CORS, lifecycle rule, IAM user, access key), then set the four S3
secrets. The IAM policy JSON is in that document, ready to paste.

The one thing worth checking by hand afterwards, because `moto` cannot prove it: a real
presigned PUT from a real device, and a real multipart upload of a video over cellular. The
CORS rule must expose `ETag` or multipart completion fails in a way that reads like a
signature error.

### 3. Fly and Neon accounts — blocks deployment

Every artifact exists: multi-stage `Dockerfile`, `fly.toml` with `release_command =
"alembic upgrade head"` and a `/health` check, and a full runbook. I did not deploy, because
I do not have your credentials and you did not ask me to.

**What I need from you:** work through `docs/DEPLOY.md`. It is written as a sequence of
commands to paste, including the full `fly secrets set` line with every required key.

---

## Deferred by decision, not blocked

### 4. `POST /prompts/batch-review` — not built

`docs/api-contract.md` lists it; the task's out-of-scope list names "the admin prompt review
queue" explicitly. The endpoint accepts or rejects candidates *sitting in a review queue*,
and there is no queue — building the endpoint means building the thing it operates on.

`GET /prompts` and `POST /prompts` are both built. `POST /prompts` writes `source = "user"`,
so hand-authored additions are already distinguishable from seeded ones, and `source =
"llm"` plus `active = false` is a review queue whenever you want one.

**Say the word and it is a small piece of work** — a filter and a bulk status update.

### 5. `POST /children/{id}/guardians` — not built

Marked P2 in the contract, and "the guardian invite flow" is on the out-of-scope list. The
`guardians` table, the `parent`/`viewer` roles, and the whole authorization path are built
and tested — a viewer can read and cannot write, and a revoked guardian is refused
everywhere. Only the invite mechanism is missing.

### 6. Thumbnails and poster frames — not built

Out of scope per the task and per `docs/decisions.md`. `POST /media/{id}/complete` marks the
row and leaves `thumb_key` null. The column exists, `MediaSummary` carries it, and clients
already handle it being null — so the pipeline slots in later without a schema change or a
contract change.

---

## Two judgment calls worth your attention

Neither is blocking. Both are places where the specs were genuinely ambiguous and I picked
the boring option, and both are cheap to change now and expensive to change at 500 entries.

### The `monthly` slot serves letters as well as measurements

`docs/data-model.md` annotates the monthly slot "(measurement)". But the eight letters in
`docs/mission-library.md` are `cadence: monthly` with no slot of their own, and restricting
the slot to `kind = measurement` would make them permanently unreachable — including the
money letter and the who-you-are-right-now letter, which are the emotional centre of the
product.

So the monthly slot draws from every `cadence: monthly` prompt. On the 1st of the month you
get a measurement mission *or* a letter, weighted random, with the same 180-day cooldown as
everything else. Twelve monthly prompts against twelve firings a year means the rotation is
tight either way.

**If you would rather they were separate:** add `letter` to the `slot` CHECK constraint (a
one-line `ALTER`, which is exactly why these are CHECKs and not Postgres enums), add it to
`SLOT_SPECS` in `services/scheduler.py`, and decide what day it fires on. Maybe the 15th, so
the month has two beats rather than one.

### The coverage table in `mission-library.md` under-counts four kinds

Eligible at 48 months, the seed file actually holds:

| Kind | The doc says | Actually |
|---|---|---|
| Question | 30 | 30 |
| Photo | ~19 | 22 (18 once seasonal prompts are filtered out) |
| Video | 9 | **11** |
| Audio | 11 | 11 |
| Activity | 15 | **16** |
| Weekly | 9 | **10** |
| Monthly | 4 | 4 |
| Letter | 8 | 8 |

The table was written before the last few prompts were added. Nothing is wrong with the
library — there is *more* than the doc claims, and the 180-day cooldown holds comfortably.

`tests/test_seeding.py` asserts the exact figures *and* treats the doc's table as a floor,
so drift is caught in either direction without hard-coding a stale number. Worth fixing the
table in the doc when you next touch it.
