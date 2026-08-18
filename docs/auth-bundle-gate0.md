# Vellum auth bundle — Gate 0 preflight

> **Renamed Aug 18, 2026.** The title read *"Dogear auth bundle"*. This was the last live occurrence of the dead name in `docs/`, and it survived phase 76's sweep — which reported the repo clean — because the sweep read the body of each file and a title is the one line nobody re-reads. The product is **Vellum** (`decisions.md:115`); the bundle's contents are unaffected.

**Run:** Aug 16, 2026, against `main` at `f47a2a1`, working tree clean.
**Verdict: PASSED, with three of the gate's own premises corrected.** No check failed in the
sense that halts the run. Two documentation defects were found that are real and are recorded
here rather than repaired, per the gate's own rule.

Every claim below was produced by one agent and then re-checked by a second agent whose brief was
to refute it. Where the refuter corrected something, the correction is what is written here.

---

## 1. Phase numbering — resolved, and the discrepancy is larger than the gate describes

**The number claimed is 51, and the eight units of work take 51–58.**

### Which file is correct: neither of the two the gate names

| Source | Highest phase it records | Correct? |
|---|---|---|
| `docs/phase-queue.md:13-14` | "The highest number used is **46**, so a genuinely new phase takes **47**" | **No.** Stale by four. |
| `docs/phase-queue.md:121` | "the icon shipped Aug 16 as phase **47**" | Correct — and it contradicts line 13 of the same file. |
| `docs/roadmap-status.md:457` | row `\| **47** \| The app icon \|` | Correct as far as it goes. **Records no 48, 49 or 50.** |
| `docs/data-model.md:391, 440, 467` | phase **49** | Correct. |
| `docs/api-contract.md:699`, `docs/decisions.md:234`, `docs/mission-library.md:263` | phase **50** | Correct. |
| `git log` on `main` | phase **50** — PR #97, `921d882` | Correct, and the highest anywhere. |

**Correction to the gate's own premise.** The gate states that `data-model.md` "refers to Phase
50's `pool-health`." It does not. `grep -oiE 'phase[- ]?[0-9]+' docs/data-model.md` returns only
30 and 49. The phase-50 references live in `api-contract.md:699`, `decisions.md:234` and
`mission-library.md:263`. The dispute is real; one of its two cited locations is misattributed.

### The taken/free table

| Phase | What | Where it is recorded |
|---|---|---|
| 44 | Verification backlog reconciled | `roadmap-status.md:454`, PR #92 |
| 45 | Multi-kid device coverage | `roadmap-status.md:455`, PR #93 |
| 46 | Caption probe | `roadmap-status.md:456`, PR #94 |
| 47 | App icon | `roadmap-status.md:457` — **no branch**, shipped as direct commits `caab89b`, `f47a2a1` |
| 48 | iOS concurrency warnings | **git only** — PR #95, `ios/phase-48-concurrency-warnings`. Absent from all docs. |
| 49 | Activity clock + two consent lanes | **git + `data-model.md`** — PR #96, migration `0010_activity_and_consent`. Absent from `roadmap-status.md`. |
| 50 | pool-health observed rate | **git + 3 docs** — PR #97. Absent from `roadmap-status.md`. |
| **51–58** | **free** | claimed below |

### Why 51 is derivable rather than inferred

`CLAUDE.md` says phase numbers "come from `docs/roadmap-status.md` and are **read from the file,
never inferred** — not by adding one to the highest integer in sight." Read literally against a
file whose highest row is 47, that rule yields 48 — which is **taken**, merged as PR #95. The rule
taken literally produces a three-way collision with shipped work.

It is not unsatisfiable, because the designated source contains its own escape hatch and it is
emphatic about it:

> `roadmap-status.md:231` — *"A phase prompt should measure `main` directly rather than quote a
> status document's count, and the number above is a convenience that is expected to rot."*
> `roadmap-status.md:235` — *"**Measure `main` rather than trusting this line.**"*

Measuring `main` gives 50. **Next free: 51.**

Note that neither source alone is sufficient: `roadmap-status.md` has 47 but not 48–50, and git has
48–50 but not 47 (phase 47 never had a branch). Only the union is complete, which is exactly why
this needed checking rather than assuming.

### Number assignment

| Ref | Phase | Lane |
|---|---|---|
| A | **51** — `aud` allowlist, and unbundling the APNS topic | api |
| B | **52** — Credential linking, revocation state, dev-login namespace | api |
| C | **53** — Apple server-to-server notifications | api |
| D1 | **54** — Google sign-in, server | api |
| D2 | **55** — Google sign-in, client | ios |
| E | **56** — The mailer | api |
| F1 | **57** — Magic-link email sign-in, server | api |
| F2 | **58** — Magic-link email sign-in, client | ios |

### Two documentation defects found, deliberately not repaired here

1. **`roadmap-status.md` records no phase 48, 49 or 50.** Three shipped phases are missing from the
   file `CLAUDE.md` designates as the numbering authority. Phase 48's author skipped the docs
   deliberately to avoid colliding with another session's uncommitted phase 47 work, and promised
   the row "once 47 lands"; 47 landed and the row was never written.
2. **`phase-queue.md` contradicts itself in a single commit.** `f47a2a1` — the current tip — added
   "the icon shipped Aug 16 as phase 47" at line 121 while leaving "the highest number used is 46,
   so a genuinely new phase takes 47" at line 13. Six lines of diff apart.

This is the same failure `roadmap-status.md` documents six revisions running, inverted: the file
usually reports work as outstanding after it landed; here it does not report it at all.

---

## 2. Lane confirmation — passes

**No phase in this set requires touching both `api/` and `ios/`.** D and F are already split by
lane in the plan, which is the correct shape.

Three things worth knowing before relying on it:

- **The lane boundary is wider than `api/` vs `ios/`.** `.claude/skills/rascal-review/SKILL.md:81-82`
  defines API lane as `api/**`, `.github/scripts/**`, `.github/workflows/ci.yml`,
  `docs/api-contract.md`, `docs/data-model.md`; iOS lane as `ios/**`, `docs/design-system.md`.
  Phases 51–54, 56 and 57 all touch `docs/api-contract.md`, which is correctly API-lane.
- **Nothing mechanically enforces it.** No CODEOWNERS, no git hook, no `core.hooksPath`, no
  pre-commit config, no branch protection on `main`, and no lane check in any workflow. CI is
  path-scoped, but path scoping selects which suite runs; it never rejects a commit. The only
  lane-aware tooling in the repo is `rascal-review`'s skill, which *reports* a cross-lane diff
  rather than blocking it.
- **The rule has slipped within the week.** Five commits in the 337-commit history touch both
  lanes, most recently `3df6cd4` (Aug 11) — titled `feat(api):` and shipping five Swift files
  including a new test file.

`ios.yml` is `workflow_dispatch:` only (the push/PR block is commented out), so a phase-55 or
phase-58 commit runs **no** CI on its own. That is a pre-existing cost decision, not a defect here.

---

## 3. Read before writing — done

Read in full: `docs/api-contract.md` §Auth (:20-95) and §Me (:97-157), `docs/data-model.md`
`users`/`credentials`/`refresh_tokens` (:12-51) and the PROPOSED section (:384-480),
`docs/decisions.md`, `CLAUDE.md`, `api/src/rascal/routers/auth.py`,
`api/src/rascal/services/auth.py`, `api/src/rascal/services/apple.py`,
`api/src/rascal/config.py`, `api/tests/test_auth.py`.

---

## 4. The three state confirmations — all three hold exactly as the plan predicts

**(a) `credentials` unique constraint and CHECK — confirmed.**
`uq_credentials_provider_subject_id` on `(provider, subject_id)`, and
`ck_credentials_provider` permitting exactly `apple | google | password`. Defined once in
`0001_initial.py:238-258`; **no migration since has touched the table.** The model at
`models/user.py:102-117` mirrors it, and `models/base.py`'s naming convention renders the model's
`one_of()` CHECK to a byte-identical name and body.

Three additions the plan will need:

- **`credentials` has no `updated_at`, no `revoked_at`, no `deleted_at`, and no
  `set_updated_at()` trigger.** It is absent from `TABLES_WITH_UPDATED_AT_AT_0001` in the migration
  and from `TABLES_WITH_UPDATED_AT` in `models/base.py:77-88`. Phase 52 adding `updated_at` must
  add `credentials` to **both** lists or the trigger will not fire.
- The `Credential` model is in `models/user.py`, **not** `models/credential.py`.
- This is consistent with `refresh_tokens` and `idempotency_keys`, which also lack `updated_at`.
  `CLAUDE.md` rule 5 is evidently read as covering synced user data, not auth rows. Phase 52's
  `updated_at` is therefore a departure from the local convention, which is fine — it is what makes
  a revocation syncable — but it is a departure and should be stated as one.

**(b) `services/auth.py` fills `email`/`display_name` first-non-null-wins — confirmed.**
`services/auth.py:43-46`:

```python
if user.email is None and email:
    user.email = email
if user.display_name is None and display_name:
    user.display_name = display_name
```

One nuance the plan should carry: the guard is `column IS NULL **and** incoming is truthy`, so an
incoming empty string never fills a null column either. "Only fills when currently NULL" is
necessary but not sufficient. Separately, `display_name` is not globally immutable — `PATCH /me`
writes it at `routers/me.py:109-110`. Only `email` is genuinely write-once.

**(c) `dev_router` is mounted only when `settings.is_local` — confirmed.**
`main.py:71` is a single `if settings.is_local:` block including both `auth.dev_router` and
`debug.router`. `is_local` is the property at `config.py:126-128` (`return self.environment ==
"local"`); the string comparison exists nowhere else. `fly.toml:34` sets `ENVIRONMENT = "prod"`.

`test_dev_login_is_not_registered_outside_local` (`tests/test_auth.py:368`) makes **three**
assertions against a `prod` app's OpenAPI paths: dev-login absent, `/v1/auth/apple` still present
(the control), and no path starting with `/v1/debug`. There are two further assertion sites the
plan does not mention: `tests/test_scheduler.py:522` covers the debug half, and
`.github/workflows/smoke.yml:32-52` re-asserts both against the deployed API on every run.

The local-only surface is exactly four paths: `/v1/auth/dev-login`, `/v1/debug/scheduler/run`,
`/v1/debug/reset-today`, `/v1/debug/board` — verified by building both apps and diffing the
OpenAPI path sets.

---

## 5. The inherited-warnings figure — the gate's premise is false

**The "21 inherited warnings" figure is stale. The current count is 0.**

Phase 48 (PR #95, `ios/phase-48-concurrency-warnings`) cleared **exactly** those 21, one for one:

| The 21, as documented at `roadmap-status.md:645-648` | Cleared by |
|---|---|
| 3 in `Rascal/Extraction/ExtractedDetails.swift` | `5efd79e` — `nonisolated` on the `private extension String` |
| 14 in `RascalTests/PushPermissionTests.swift` | `8469499` — lock/unlock pairs rewritten to `withLock` |
| 4 in `RascalTests/ExtractionTests.swift` | `8469499` — same |

The removed call-site counts in the diffs match the documented 14 and 4 exactly.

Two things this changes:

- **The 21 was already wrong, in the flattering direction.** Phase 46 (merged the same day) added
  5 warnings in `Captions/CaptionProbe.swift` that were never counted. The true pre-48 cold count
  was 26.
- **`8469499` claims a cold `build-for-testing` across all four targets from a deleted
  DerivedData**, reporting zero project warnings and 918 tests in 113 suites green. That is the
  right command — `5efd79e` used `xcodebuild build`, which never compiles the test target. **No
  cold build was run for this report**; the zero is derived from that commit plus the fact that no
  commit has touched `ios/` since (phases 49 and 50 are both API lane, tree clean).

**Consequence for this bundle:** the baseline for phases 55 and 58 is **0, not 21**, and it must be
re-measured cold before either is claimed complete. Phases 51, 52, 53, 54, 56 and 57 touch no Swift
and inherit nothing.

Also stale, found on the way and not repaired: `roadmap-status.md:119` records the iOS suite at
860 tests / 108 suites and `:538` at 801/101; phase 48 reports 918 in 113.

---

## Premise corrections that change the work

**Phase A / 51 — `APNS_TOPIC` already exists.** The plan says "Add an explicit `APNS_TOPIC`
setting." It is already at `config.py:102`, with `resolved_apns_topic` at `:110-112`:

```python
apns_topic: str | None = None

@property
def resolved_apns_topic(self) -> str:
    return self.apns_topic or self.apple_bundle_id
```

The trap the plan identifies is real — the fallback reads the field that is becoming a list — but
half the fix is shipped. What phase 51 actually owes is the **startup guard**, not the setting.

**Phase C / 53 — `users` already carries two consent columns.** Phase 49 shipped
`marketing_consent` and `transactional_consent` (`models/user.py:86-92`, migration
`0010_activity_and_consent`), both `boolean not null default true`, neither settable through the
API. `email_deliverable` is a third and genuinely distinct column — deliverability is not consent —
so it does not collide. But the plan's justification cites D3/D3a as though nothing had landed, and
phase 53 should state the three-column relationship rather than introduce the third in isolation.

**Phase B / 52 — the production claim is verified, not asserted.** Read from
`rascal-api` on Aug 16, 2026:

```
credentials by provider: ('apple', 1)
users: 1
```

Zero `password` rows in production. The data migration touches the local dev fixture only, exactly
as the plan claims. This is the one thing the plan explicitly said to verify rather than assert.

**Phase B / 52 — a pre-existing race the plan will inherit.** `user_for_credential` does a SELECT
at `services/auth.py:35-39` and an INSERT at `:52` with nothing between them but
`uq_credentials_provider_subject_id`. Two concurrent first-ever sign-ins for the same subject both
miss and both insert; one raises `IntegrityError`, which nothing catches, so it surfaces as a 500
rather than a `RascalError`. Not caused by this bundle, and phase 52 rewrites this function — worth
fixing there rather than leaving under new code.

**Phase F1 / 57 — the `CLAUDE.md` edit is already anticipated.** `decisions.md:235` (open item 12,
the marketing list) says the public-write endpoint "forces that call rather than inheriting it,"
referring to `CLAUDE.md:79`'s rate-limiting exclusion. Phase 57's proposed diff to that line is
consistent with a question already recorded as open.

**No settled decision is being relitigated.** `decisions.md` carries no entry on magic links,
email sign-in, password auth or credential linking. The only adjacent settled item is the
Facebook/Meta rejection at `:201-211`, which this bundle does not touch. ~~`phase-queue.md:163-169` records the ordering constraint — linking before Google — which the
plan's A→B→C→D order honours.~~ **Struck Aug 18, 2026: that citation rotted and the constraint is
now history.** `phase-queue.md:163-169` is today about `Transcript.Segment` and the caption
clobber — the file was rewritten under the line number, which is why this file now cites *the
forward queue's `Google sign-in` row* in `roadmap-status.md` **by name rather than by line**.
The constraint itself was honoured and is spent: credential linking shipped as **phase 52** and
Google as **54 and 55**, all on Aug 16, 2026, in that order. **The reusable part is the failure
mode, not the fact**: a line-numbered cross-reference into a living document is a claim with an
expiry date nobody sets, and this one was quoted as current for two days after it stopped being
true.
