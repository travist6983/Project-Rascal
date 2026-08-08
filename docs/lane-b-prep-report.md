# Lane B Prep — report
**Aug 8, 2026.** Branch `lane-b-prep`, off `main`. Configuration and documentation only — no change to `api/src/`, `api/tests/`, `api/alembic/`, or any migration, verified by `git status`. Nothing was committed; the working tree is left for review.

* * *
## What changed, per task
### P-1 — CI scoped to the API
| File | Change |
|---|---|
| `.github/workflows/ci.yml` | `paths` added to both `push` and `pull_request` |
| `.github/workflows/deploy.yml` | `paths` added to `push` |
| `.github/workflows/smoke.yml` | **no change — see below** |

Both diffs are purely additive: 20 insertions, 0 deletions across the two files. Every existing trigger, job, secret, and step is intact. `ci.yml` kept `branches: ["**"]` rather than being narrowed to `main` as the task template suggested — it deliberately runs on every branch and that is not a filtering concern.

All six workflow files parse under `yaml.safe_load`.

**Two things worth your attention:**

1. `smoke.yml` **has no push trigger at all.** It is `workflow_dispatch:` only — a manual "is production healthy" probe you fire from the GitHub mobile app. A `paths` filter is only valid on `push` and `pull_request`, so adding one would have been a syntax error. The premise that it "runs on pushes to main" was not accurate; I left it alone.
  
2. **I added** `.github/scripts/**` **to** `ci.yml`**'s filter, beyond the template.** The lint job runs `ruff check . ../.github` — it lints `prune_backups.py` and `verify_schema.py`, which are real Python that runs against production data and that nothing else checks. With only `api/**` in the filter, editing either of those would have silently stopped being linted. That is a gap the filter would have introduced, so I closed it.
  

**Confirmed, not assumed** — the three untouched workflows have no push trigger:

| File | Triggers |
|---|---|
| `backup.yml` | `schedule` (cron `10 8 * * *`), `workflow_dispatch` |
| `migrate-neon.yml` | `workflow_dispatch` |
| `prompt-candidates.yml` | `workflow_dispatch` |
### P-2 — `POST /v1/auth/dev-login` documented
Expanded in the Auth section of `docs/api-contract.md`. Note it was not entirely undocumented — a four-line stub already existed saying it is local-only. What was missing was every concrete detail a client needs. The full contract as found in source is below.
### P-3 — Ignore rules
Appended an "iOS lane" block to `.gitignore` with the five requested patterns. Verified with `git check-ignore` that all four hazards match (`ios/Config.xcconfig`, `ios/.DS_Store`, `…/xcuserdata/travis.xcuserstate`, `ios/DerivedData/junk.o`) and that `ios/Fixtures/*.json`, `ios/CLAUDE.md`, and `ios/Config.xcconfig.example` are still trackable.

Created `ios/Config.xcconfig.example`. One non-obvious detail baked in: `//` starts a comment in xcconfig, so a literal `https://` cannot be written inline. The example uses the standard `RASCAL_API_SCHEME = https:$()/$()/` split, with a comment explaining why — otherwise the first person to write a URL there gets a silently truncated value.
### P-4 — `make fixtures`
Added to the `Makefile`, matching its existing conventions (`##` help text, `.PHONY`, `?=` override variable, root `.env` already included and exported).

```
make fixtures                                    # http://localhost:8000
make fixtures API_BASE=https://rascal-api.fly.dev
```

Every response goes to a temp file and is checked for **both** a 200 and parseable JSON before anything is moved into `ios/Fixtures/`. On any failure it prints the status, the response body, and exits non-zero having written nothing. A 404 on dev-login gets a specific message, because it means one thing: the API is not running with `ENVIRONMENT=local`.

Ran successfully against a live API. Both files contain real data:

- `ios/Fixtures/dev-login.json` — 571 bytes, real token pair and fixture user
  
- `ios/Fixtures/today.json` — 1556 bytes, a real child and three real assignments
  

README gained a `make fixtures` row in the Make targets table plus a short subsection stating that it must be re-run whenever an API response shape changes.
### P-5 — Lane rules
`CLAUDE.md` gained a `## Two lanes` section. Two consequential edits beyond adding it:

- The opening line said **"This repo is the backend."** That is now false. Changed to name both halves.
  
- The out-of-scope list began **"Swift or iOS code"** under the heading _"stop if you find yourself designing one."_ Left alone, that instruction would have told an iOS-lane agent reading the root file to stop working. Retitled to "Out of scope for the API lane" and annotated that line.
  

Created `ios/CLAUDE.md` covering every point requested.
### P-6 — Decisions logged
Added the monorepo row to the Settled → Technical table, verbatim as specified, and a dated **Aug 8, 2026** entry at the top of the Changelog.

* * *
## The real dev-login contract
Read from `routers/auth.py`, `schemas/auth.py`, `schemas/common.py`, `services/auth.py`, `main.py`, `config.py`, and `tests/test_auth.py`. Three details differ from what you would guess by pattern-matching the other auth endpoints.

**Request** — both fields optional, so `{}` is valid:

```json
{ "email": "dev@rascal.local", "display_name": "Dev Parent" }
```

**Response** — 200, the same `SessionResponse` model as `/auth/apple`. Note that model is `TokenPairResponse` plus `user`, so it carries `token_type` and `expires_in` as well — the contract doc's shorthand `{ access_token, refresh_token, user }` for `/auth/apple` is under-specified for both endpoints:

```json
{
  "access_token": "eyJhbGciOiJIUzI1Ni…",
  "refresh_token": "EF0Ez24derlz…",
  "token_type": "bearer",
  "expires_in": 900,
  "user": { "id": "…", "email": "dev@rascal.local", "display_name": "Dev Parent",
            "is_admin": true, "created_at": "2026-08-08T17:42:40.350232Z" }
}
```

**The three things a client agent would otherwise get wrong:**

1. **The credential is** `provider = "password"`**,** `subject_id = <email>` — not `apple`. The fixture account is a password credential no password can currently satisfy. Moving to Sign in with Apple later therefore produces a _different_ user, not the same one upgraded.
  
2. **It force-sets** `is_admin = true` **on every call**, so the fixture account can write to the mission library without a second privileged login that does not exist.
  
3. **It returns no child and no child id, and nothing in it creates one.** The child comes from `GET /children` → `[0].id`. On a freshly migrated database that array is **empty** — `make seed` loads the 113 prompts and never a child. This is the single most likely place for the iOS agent to improvise, which is why `make fixtures` fails with an explicit `POST /children` command rather than a generic error.
  
### Is it environment-gated? Yes — properly.
Not merely refused: **it does not exist.** `main.py` mounts `auth.dev_router` inside `if settings.is_local`, so under `ENVIRONMENT=prod` the path is absent from the app and from `/openapi.json`, and any call is a 404. `settings.is_local` is the only environment branch in the service and its docstring says so. This is asserted in three independent places:

- `tests/test_auth.py::test_dev_login_is_not_registered_outside_local`
  
- `tests/test_auth.py` asserts no `/v1/debug` path survives either
  
- `.github/workflows/smoke.yml` re-checks it against the deployed API on every run
  

Both tests pass. **No production concern here.**

* * *
## Does `docs/design-system.md` exist? Not at first — it does now.
It was missing when this task ran, and I did not create one. **You added it the same day**
(189 lines: full palette, type scale, shape and elevation, seven component specs, motion,
layout, copy rules, and an anti-pattern list). `ios/CLAUDE.md` was updated to point at it as
the authority for writing SwiftUI, and the interim "fall back to the Design table in
`decisions.md`" language was removed.

The one rule promoted into `ios/CLAUDE.md` rather than left as a pointer is that **color
carries meaning** — terracotta for missions and photo/video, periwinkle for questions and
voice, sage for did-it. That is the design rule an agent is most likely to violate while
believing it is being on-brand.

* * *
## Open items — all four resolved, same day
**1. Bundle identifier — settled.** `com.travisterry.childarchive`, deliberately name-neutral
so open question #1 (the app name) stays open. Recorded in the Settled → Technical table and
in the changelog. This also closes the "what I need" line in `blocked.md` §1.

**Still to do when you register it:** `APPLE_BUNDLE_ID` is the `aud` claim every Apple
identity token is verified against, and it is still the placeholder `com.example.rascal` in
`.env.example` and in `ci.yml`'s test env. It has to flip to match. I left both alone — real
Sign in with Apple is blocked on enrollment anyway, so nothing is broken by the placeholder
until that clears, and changing it is an API-lane edit.

**2. Path filters and required status checks — moot.** I checked: branch protection is not
available on this repo's plan (`GET /branches/main/protection` → 403, "Upgrade to GitHub Pro
or make this repository public"). There are no required status checks, so a filtered-out
workflow cannot block a PR. Revisit only if the repo goes public or onto a paid plan.

**3. `ios/Fixtures/*.json` — committed**, per your call and my recommendation. They are ground
truth and worthless if every agent regenerates them.

**4. `docs/design-system.md` — you wrote it.** See the section above.

### One live caveat on the committed fixtures

`today.json` reflects a child I created solely to capture it — "Rascal", born 2021-06-01,
`America/Detroit`, age 62 months, with three assignments generated by the debug scheduler
route. **The shapes are real; the child no longer exists.** It lived in a throwaway Postgres
I removed during cleanup, so child id `5cfb928b-b7f0-4c25-8b51-5b5521e56473` resolves to
nothing on any database.

That is a trap worth naming: an agent reading `today.json` could reasonably hardcode that
UUID and wire the app to a child that 404s. Before the first Claude Code run in `ios/`,
create a durable dev child against your own local database and re-run `make fixtures` — the
committed fixture will then carry an id that actually resolves.

* * *
## Environment notes
- **Port 5433 is occupied on your machine** by `eosworkbench-postgres-1`, so `make up` fails with a bind error. To capture the fixtures I ran a throwaway Postgres 16 on 5434, pointed `.env` at it, migrated, seeded, and captured. Afterward I removed that container and reset `.env` from `.env.example`.
  
- `docker-compose.yml` **and** `.env.example` **were edited during this session, but not by me.** They now make the host port overridable (`"${POSTGRES_PORT:-5433}:5432"`, with `POSTGRES_PORT=5433` in the example) — which is the right fix for the conflict above. I left both edits in place and verified them: `docker compose config` resolves to 5433 by default and to 5434 with `POSTGRES_PORT=5434`. Flagging it only because it falls outside the changes this task asked for, so it should not be mistaken for part of the lane-B diff.
  
- The scheduler's real job only assigns at the child's local 5am (`children_off_hour: 1`), so I used `POST /v1/debug/scheduler/run` to generate assignments — the same path the README documents for local development.
  
## Verification performed
- `make fixtures` succeeds against a live API; both files contain real data
  
- `make fixtures` with the API down, and with no child, both fail loudly and write nothing
  
- `git check-ignore` confirms all four ignore hazards match and no wanted file is caught
  
- All six workflow files parse under `yaml.safe_load`; workflow diffs are 20 insertions, 0 deletions
  
- `git status --porcelain api/` shows no change under `api/src`, `api/tests`, or `api/alembic`
  
- `git status` shows no `Config.xcconfig`, no `xcuserdata`, no `.DS_Store`
  
- `make help` still renders; `pytest -k dev_login` passes (2 passed)
