# Preflight — account deletion and Sign in with Apple revocation

**Lane:** API (Lane A). **Read:** Aug 25, 2026, against `26bbf5a`.
**Phase number:** none allocated. See §1, gate 1 — one cannot be read from this tree.

> **VERDICT: HALT.** Gate 2 fails on the spec's own terms (question 5 is unanswered), gate 4
> returns exactly the blocker it was written to find (Apple's refresh token is not persisted, and
> there is no key material to obtain one), and **three of the four scope items describe code that
> already shipped.** No code was written. No file outside this report was changed.

The spec said: *"If it does not answer any one of them, stop and produce a report listing the
unanswered questions. Do not invent an answer, and do not write the answer into `decisions.md`
yourself — proposed decision text comes back as a diff for Travis to apply."* This is that report.
Proposed decision text is in §5, as diffs, unapplied.

---

## 1. The five gates

| # | Gate | Result |
|---|---|---|
| 1 | No API-lane phase in flight | **PASS** on the question asked · **BLOCKED** on the number |
| 2 | `decisions.md` answers the five questions | **FAIL** — question 5 is unanswered |
| 3 | Migration head clean | **PASS** — `0024_canvas_video`, single head, linear |
| 4 | Is the SIWA refresh token persisted? | **NO** — and this is the blocker |
| 5 | Single writer for `entitlements.tier` | **PASS** |

### Gate 1 — PASS on flight, BLOCKED on the number

No API-lane phase is in flight; `gh pr list --state open` returns `[]`.

**But no phase number can be read from this tree, because the tree is four commits stale and
those commits spend three numbers.**

```
$ git rev-parse --short HEAD          26bbf5a
$ git rev-parse --short origin/main   6c0a62a
$ git rev-list --count HEAD..origin/main
4
$ git log --oneline HEAD..origin/main
6c0a62a Merge pull request #172 from travist6983/ios/phase-124-app-review-compliance
6214409 blocked.md §23: the mail errand, filed with its reason corrected
9dc0a25 Phase 126: the submission-gap audit, allocated and briefed
5411989 Phases 124 and 125: allocated, briefed, and one preflight that stopped
```

`docs/phase-queue.md` on disk ends: **"The highest number used is 123. A genuinely new phase
takes 124."**
The same file on `origin/main` ends: **"The highest number used is 126. A genuinely new phase
takes 127."**

Both lines read directly, side by side. `docs/phase-briefs/` does not exist on disk and holds
three files on `origin/main`.

`CLAUDE.md` requires numbers to be **read from the file, never inferred**. Reading the file on
disk yields 124 — already spent three ways. **This is precisely the mechanism that created the
103 collision**: two allocations hours apart, neither able to see the other's. Do not allocate
from this tree.

> **Action: `git pull` first, then re-read `docs/phase-queue.md`.** The current file offers
> **127**. Travis assigns both numbers; this report does not.

Two ledger rows carry stale not-merged markers and are unrelated to this phase:
`roadmap-status.md:708` (row 105, "open — PR #155"; PR #155 is merged) and `:709` (row 106,
whose subject matter — the Gemini vendor — phase 120 deleted).

**One reassurance:** `docs/phase-briefs/phase-126-submission-gaps.md:180` on `origin/main`
explicitly defers *"Account deletion (Guideline 5.1.1(v)). Separate phase."* — so this work is
expected and does not collide with 124/125/126.

### Gate 2 — FAIL

Four of five questions are answered verbatim in the decision record. Question 5 is not answered
anywhere. Full answers in §2; the unanswered question in §3.

### Gate 3 — PASS

```
$ cd api && uv run alembic heads --verbose
Rev: 0024_canvas_video (head)
Parent: 0023_entitlement_grants
Path: api/alembic/versions/0024_canvas_video.py
```

Exactly one head. `alembic history | grep -c ' -> '` returns 24, matching the 24 files
`0001`–`0024`; every `down_revision` value is used exactly once, with exactly one `None`. No
branch point.

**Incidental:** the dev database `rascal` on port 5434 is stamped `0021_social_renders`, three
behind head. `rascal_test` is at head, so the suite is unaffected. `make migrate` closes it;
nothing was run.

### Gate 4 — the blocker, confirmed

**Apple's refresh token is not persisted. Neither is the authorization code, nor an access
token. There is no key material with which to obtain one.**

```
$ grep -rn "auth/revoke"   api/ | grep -v .venv     → exit 1, no output
$ grep -rn "client_secret" api/ | grep -v .venv     → exit 1, no output
```

The only references to `appleid.apple.com` are JWKS verification inputs
(`api/src/rascal/config.py:96-97`), and the only outbound HTTP on the Apple identity path is a
**GET** for the key set (`api/src/rascal/services/oidc.py:34-38`).

**The client already sends the code and the server accepts and discards it**, in writing:

```python
# api/src/rascal/schemas/auth.py:12-17
class AppleSignInRequest(ApiModel):
    identity_token: str = Field(min_length=1)
    # Carried for parity with the Sign in with Apple payload. RASCAL verifies the identity
    # token directly and never calls Apple's token endpoint, so this is accepted and ignored.
    authorization_code: str | None = None
```

iOS supplies it today — `ios/Rascal/Rascal/Onboarding/AppleSignIn.swift:36,41,113`.

There is nowhere to put a token. `Credential` has seven columns
(`api/src/rascal/models/user.py:132-149`): `id, user_id, provider, subject_id, revoked_at,
created_at, updated_at`. `subject_id` is Apple's `sub` — an identifier, which Apple's revoke
endpoint will not accept.

There is no `.p8`. `api/src/rascal/certs/` holds only `appstore/AppleRootCA-G3.cer` and a
README. `config.py` has no SIWA key id, private key, or client secret. `apple_team_id`
(`config.py:154`) is documented in place as *"Not a secret: it is printed in every provisioning
profile"* — association-file material, not signing material. The APNs key trio
(`config.py:471-473`) is a different key with a different capability, and is unset.

> **Consequence, and it is the sharpest fact in this report: existing Apple users cannot be
> revoked at all under one of the two designs.** Nothing is stored to revoke with, and adding a
> column backfills nothing. See the fork in §4.

### Gate 5 — PASS

```
$ cd api && uv run pytest tests/test_app_store.py::test_tier_has_exactly_one_writer -q
1 passed in 0.61s
```

Independent sweep agrees — one assignment site in all of `api/src`:

```
$ grep -rn "\.tier = " api/src/
api/src/rascal/services/app_store_events.py:347:    entitlement.tier = effect
```

Also checked by hand and clean: augmented/walrus assignment, `setattr`, `.values(tier=...)`, raw
`UPDATE entitlements` / `SET tier`, and anything under `scripts/` or `alembic/`. Four
`Entitlement(...)` constructions exist; two take `server_default="free"`
(`models/family.py:100`) and two in `services/admin_metrics.py:524,728` are transient objects
never added to a session.

Adjacent green: `uv run pytest tests/test_deletion.py -q` → **12 passed in 1.44s**.

**Carry-forward caveat.** The test scans only `src/rascal/**/*.py` for the literal substring
`.tier = ` on non-comment lines. The forms above are clean today but **are not pinned by the
suite** — a second writer added as `update().values(tier=...)` would pass CI.

---

## 2. The five decision questions

**Q1 — Hard-delete or anonymise? ANSWERED: hard-delete.**
`docs/decisions-log.md:248-251`, echoed at `docs/data-model.md:367-370`:
> *"This is the one place in the service that hard-deletes user data, breaking rule 5 on
> purpose. Soft deletes exist so a client can learn a row went away; there is no client left to
> tell, and a `deleted_at` on an erasure would be the service keeping exactly what it was asked
> to stop keeping."*

No anonymisation policy exists; a sweep of `docs/` for `anonymi[sz]|pseudonymi|scrub|redact`
returns zero deletion-context hits. One field is nulled rather than deleted, and it is decided:
`entries.author_id`, `ON DELETE SET NULL` (`docs/decisions-log.md:252-255`). Scope is decided
too — `docs/decisions.md:267`: *"The account always; the archive only when no other guardian
remains."*

**Q2 — Immediate or grace window? ANSWERED: seven days.**
`docs/decisions.md:267`: *"Seven days, signed out immediately on request, and any sign-in during
the window cancels it outright."* The constant is
`GRACE_PERIOD = dt.timedelta(days=7)` at `api/src/rascal/services/deletion.py:65`, and the value
is stored on the row at request time so a request runs on the terms it was made under.
*Not decided:* any confirmation or reminder email during the window. The user is signed out and
receives nothing.

**Q3 — Media in object storage? ANSWERED: same clock as the rows, deleted last.**
`docs/api-contract.md:283-286`. Bucket soft-delete is 30 days and is named explicitly as *"a
net, not a licence to treat the operation as reversible"* (`docs/decisions.md:267`).
**See §6 defect 2 — the code does not honour the ordering its own docstring claims.**

**Q4 — Does the lapse/abandonment policy apply? ANSWERED: no, and D3 was amended to say so.**
`docs/decisions.md:31`: *"this row is about what we delete on our own initiative, and nothing
else… It says nothing about a parent who asks us to delete their account, which is a different
trigger with a different scope and is settled in open item 14. Reading this row as covering that
is the specific mistake the amendment exists to prevent."*

**Q5 — UNANSWERED.** See §3.

---

## 3. The unanswered question

> **"What minimal tombstone survives, if any, for fraud and billing reconciliation?"**

The words **fraud**, **chargeback** and **billing reconciliation** appear nowhere in either
decisions file in a deletion context:

```
$ grep -rn -iE "fraud|chargeback|billing reconcil" docs/decisions.md docs/decisions-log.md
(exit 1, no output)
```

The only decision text on the subject says the **opposite** of a tombstone —
`docs/decisions-log.md:244-247`:

> *"There is no `completed_at`, and the absence is the design. A completed deletion has no row:
> it cascades away with the user… Completion is the row being gone, which is also the only
> record consistent with having been asked to forget somebody."*

The nearest adjacent rationale is a schema note, not a decision, and covers billing only —
`docs/data-model.md:265`:

> *"`ON DELETE SET NULL` rather than `CASCADE` because a receipt outlives the household it paid
> for: a hard account deletion must not take the billing record with it, and Apple will still
> send a `REFUND` about it."*

**And that sentence describes a mechanism that never fires.** Nothing in the service deletes a
`families` row:

```
$ grep -n "Family\|Entitlement" api/src/rascal/services/deletion.py   → exit 1, no output
```

`users.family_id` is `ondelete="RESTRICT"` (`api/src/rascal/models/user.py:43-45`), so deleting
a user cannot reach the family. **After a sole-guardian erasure there survives: an orphaned
`families` row, its `entitlements` row, and every `app_store_transactions` row still pointing at
that live `family_id`.** That is a residual, not a decided tombstone. No document states,
justifies, or bounds it — and it is what makes Q5 a real gap rather than a paperwork one.

---

## 4. Scope: what is already built

**Three of four scope items are shipped. This is the most important section of the report.**

### A1 — `DELETE /v1/account` · **ALREADY BUILT, under a different shape and path. Strike it.**

Deletion shipped as **phase 66** (server) and **phase 67** (client) on Aug 17, 2026 —
`docs/roadmap-status.md:674,676,677`, all `✅ shipped`.

- `api/src/rascal/routers/me.py:344` — `POST /v1/me/deletion` → 202
- `api/src/rascal/routers/me.py:362` — `DELETE /v1/me/deletion` → 204 (**cancel**)
- `api/src/rascal/services/deletion.py` — 300 lines, complete
- `api/src/rascal/jobs/delete.py` — the executor, with `--dry-run`
- `api/alembic/versions/0015_deletion_requests.py` — table, two named partial indexes, trigger
- `api/tests/test_deletion.py` — 12 tests, all passing
- iOS: `DeleteAccountSheet.swift`, `AccountDeletionModel.swift`, `AccountDeletionTests.swift`
  (7 tests), wired at `SettingsScreen.swift:274-291`
- `docs/api-contract.md:258-292` documents both routes

There is no `/account` router: `grep -rn 'prefix="/account"' api/src/rascal/routers/` → exit 1.

**Building A1 as specified would be a defect twice over.** Beyond duplicating shipped code:
**`DELETE` on the existing deletion path means *cancel*.** A second `DELETE` at `/v1/account`
meaning *erase* would put two opposite meanings on one verb in one API, one path apart. And if
the spec genuinely intends *immediate* erasure, that is a **reversal of the settled seven-day
window** in `decisions.md:267` — a decision for Travis, not an implementation task.

### A2 — SIWA revocation against Apple · **NOT BUILT. The only genuine greenfield in scope.**

The gap is already recorded in the decision record and nowhere else —
`docs/decisions.md:404-409`:

> *"Apple requires an app offering Sign in with Apple to call the REST token-revocation endpoint
> as part of deletion, and that call exists nowhere in `api/`; the inbound `consent-revoked`
> handling in `services/apple_events.py` is the opposite direction and is not a substitute.
> **It needs a phase number of its own.**"*

Repeated at `decisions.md:126` and `decisions-log.md:295`. It has **no** `blocked.md` section
and **no** `phase-queue.md` entry. No number has ever been allocated for it.

**It is not one design — it is a fork, and the two arms differ by lane, by schema, and by
whether existing users are covered at all.** Apple's authorization code is single-use and
short-lived, so under *either* arm the code cannot be stored; it must be exchanged on receipt.

| | **Arm 1: persist the refresh token** | **Arm 2: re-authorize at deletion time** |
|---|---|---|
| Migration | Yes — a new **secret at rest**, and an encryption-at-rest decision with no existing helper to reuse | **None** |
| Portal errand | `.p8` created, key id, private key, Fly secret, `.env.example` | **Same** |
| New service code | `client_secret` ES256 signer · `/auth/token` exchange · `/auth/revoke` | **Same** |
| Handler change | `routers/auth.py:62-84` must read the code; exchange must be non-fatal | Deletion route accepts a fresh code |
| iOS lane | **None** — client already sends the code | **Required** — re-auth prompt in `DeleteAccountSheet.swift` |
| Existing users | **Not covered.** Revocable only after a next sign-in | **Covered immediately** |
| Contract prose | `schemas/auth.py:14-15`, `:58-62`, `schemas/credential.py:44-45` all become false | Same, plus a body field on the deletion route |

The ES256 signing pattern to model already exists in the tree for a different key:
`api/src/rascal/services/push.py:227-232`.

### A3 — `account-delete` notification handling · **ALREADY BUILT AND ALREADY DECIDED. Do not touch it.**

Shipped in phase 53, Aug 16, 2026. The route is `POST /v1/webhooks/apple-signin`
(`api/src/rascal/routers/webhooks.py:42-45`) — **separate from the App Store hook**, as the spec
requires — signature-verified against Apple's JWKS as the handler's first statement
(`webhooks.py:66` → `services/apple.py:92-105`). Twenty tests in `api/tests/test_apple_webhook.py`.

The spec says *"do not treat them as identical without saying why."* **They are identical, and
the why is already written down** — `api/src/rascal/services/apple_events.py:50-52`:

```python
    match event.event_type:
        # Identical on purpose. See the module docstring and `docs/decisions.md`.
        case "consent-revoked" | "account-delete":
```

And `docs/decisions.md:125` exists specifically to stop somebody "fixing" it:

> *"So `account-delete` and `consent-revoked` do exactly the same thing… **This is recorded here
> rather than only as a code comment because the identical handling will read as a copy-paste
> mistake to whoever finds it next**, and 'fixing' it would delete somebody's archive on a third
> party's say-so."*

Apple is telling us an Apple ID was deleted. It is not telling us to delete a child's archive,
and the parent who wrote that archive has not asked for anything.

**Nothing to build. The remaining risk is not code:** `docs/blocked.md:823-829` records that
nothing in the repository shows the SIWA notification endpoint was ever registered with Apple.
Twenty green tests prove the handler works *given a delivered notification*, and nothing about
delivery. See §7.

### A4 — Orphan safety · **The break-test can be written; written faithfully it FAILS TODAY.**

The `unattributed` concept exists (`services/app_store_events.py:254-259` returns
`"recorded:unattributed"`; `app_store_transactions.family_id` is nullable,
`models/app_store.py:68-70`; documented at `docs/api-contract.md:2184`).

But a `DID_RENEW` after a real erasure does **not** take that path, because the erasure never
removed the family. `_resolve_family` finds the surviving `Family`
(`app_store_events.py:280-290`), the handler returns `tier:subscribed`, and `_write_tier` runs:

```python
# api/src/rascal/services/app_store_events.py:347-349
    entitlement.tier = effect
    if effect == "subscribed":
        entitlement.lapsed_at = None
```

> **A renewal for an erased account silently re-marks the orphaned household `subscribed` and
> clears `lapsed_at`.** That is not cosmetic: `lapsed_at` is what D3's media-deletion clock runs
> off (`services/guardians.eligible_at`). No crash and no FK violation — every nullable FK on
> that path is `SET NULL`, and the demotion guard at `app_store_events.py:218-230` fires only
> for demotions. **Nothing guards a promotion into a household with zero live users.**

The nearest existing test,
`test_an_unknown_family_is_recorded_unattributed_and_no_family_is_created`
(`api/tests/test_app_store.py:609`), arranges a family that **never existed** — not one whose
users were erased. No test anywhere combines account deletion with an App Store notification;
`test_deletion.py` never imports `AppStoreTransaction` and never posts to the webhook.

**Two wording problems in A4 as specified, both load-bearing:**

1. *"records it as unattributed rather than creating anything"* is internally contradictory. The
   unattributed path **does** create a row — an `AppStoreTransaction` with `family_id = NULL` —
   deliberately (`app_store_events.py:232-243`, *"the audit trail is the point"*). The assertion
   must be **"writes no `entitlements` change"**, not "creates nothing".
2. A test that passes today would have to arrange a state the product cannot reach — a deleted
   `families` row, which no code path produces and `RESTRICT` forbids while a user remains. That
   is false assurance, not coverage.

**A4 is therefore a decision before it is a test.** See §5, diff 2.

---

## 5. Proposed decision text — diffs, NOT applied

Per the spec, these come back for Travis to apply. Each is written to be pasted into
`docs/decisions.md` under open item 14. **None of this is settled; all three are drafts.**

### Diff 1 — Q5, the gate-2 halt (required before any code)

```diff
--- a/docs/decisions.md
+++ b/docs/decisions.md
@@ open item 14 — user-requested account deletion
+**(e) What survives an erasure, and why.** Asked and answered Aug 25, 2026, because the record
+said *"completion is the row being gone"* while the code left three things standing and no
+document had ever noticed.
+
+What survives today, by accident rather than by design: the `families` row, its `entitlements`
+row, and every `app_store_transactions` row pointing at that `family_id`. `users.family_id` is
+`ON DELETE RESTRICT`, so deleting a user cannot reach the family, and `services/deletion.py`
+never names `Family` or `Entitlement`.
+
+THE DECISION IS ONE OF THESE THREE — Travis picks one and strikes the other two:
+
+  (i)  KEEP THE RECEIPT, REAP THE REST. `app_store_transactions` rows survive with
+       `family_id` set to NULL; the `families` and `entitlements` rows are deleted with the
+       last guardian. A receipt outlives the household it paid for (`data-model.md:265`) and
+       Apple will still send a REFUND about it — but an *entitlement* is a live grant of
+       access to a household with nobody in it, and nothing needs it to reconcile a refund.
+       This is the only option under which "completion is the row being gone" stays true.
+
+  (ii) KEEP ALL THREE, AND SAY SO. The residual is accepted and written down as a tombstone:
+       an empty household with a tier. Requires stating what reads it and what bounds it, or
+       it is an unbounded retention of exactly the kind rule 5's exception exists to prevent.
+
+  (iii) REAP EVERYTHING, INCLUDING THE RECEIPT. Simplest to reason about and contradicts
+        `data-model.md:265`, which would have to be struck in the same pass.
+
+Whichever is chosen, `docs/decisions-log.md:244-247` ("completion is the row being gone") and
+`docs/data-model.md:265` must be reconciled against it, because today they disagree with the
+code and with each other.
```

### Diff 2 — A4: a renewal for an erased household

```diff
--- a/docs/decisions.md
+++ b/docs/decisions.md
@@ open item 14 — user-requested account deletion
+**(f) An App Store renewal arriving after an erasure.** Apple keeps sending notifications for a
+subscription nobody cancelled. Today `_write_tier` re-marks the orphaned household `subscribed`
+and clears `lapsed_at` — and `lapsed_at` is D3's media-deletion clock, so the erased
+household's abandonment clock is reset by a renewal for a person who no longer exists.
+
+PROPOSED: the notification is recorded — the audit trail is the point, and a REFUND may follow
+— but `entitlements` is not written for a household with no live members. Concretely, a fourth
+guard beside the three at `app_store_events.py:218-230`, refusing a PROMOTION into a memberless
+household, symmetrical with the existing demotion guard.
+
+This is subordinate to (e): if (e)(i) or (e)(iii) is chosen the `entitlements` row is gone and
+the guard is belt-and-braces; if (e)(ii) is chosen the guard is the only thing standing between
+an erased household and a live subscription flag.
```

### Diff 3 — the fork, which is Travis's call and not a proposal

Not offered as text, because it is not a wording choice. See §8.

---

## 6. Defects found on the way, all pre-existing and none in scope

These were found while auditing. **None was changed.** Each is real and each is currently
unowned; the first is the most serious thing in this report.

1. **No Fly machine runs the deletion job — so no erasure has ever completed.**
   `docs/decisions-log.md:385`: *"Nothing on any schedule runs `python -m rascal.jobs.delete`,
   so a seven-day erasure never completes."* Long form at `docs/blocked.md` §20: *"The one rule
   this service broke on purpose is currently not being kept either way."* This is one
   `fly machine run`, and it is an owner action. **Any revocation call added to
   `execute_deletion` inherits this: it would be code that has never run against Apple, inside a
   job that has never run at all.**

2. **The S3 ordering docstring overstates its guarantee.** `deletion.py:209-213` says objects are
   deleted *"after the database work has succeeded."* The code flushes, not commits:

   ```
   deletion.py:251-255   await session.execute(delete(User)...)
                         await session.flush()
                         # Last, and only once the database work has held.
                         await s3.delete_objects(keys, settings)
   deletion.py:288-289   counts = await execute_deletion(...)
                         await session.commit()
   ```

   The DB work is still rollback-able when the bytes are destroyed. It converges on a retry (S3
   answers success for a missing key), but in the window between, surviving `media` rows point at
   bytes that are gone and `presign_get` mints URLs that 404. **This is the answer to the spec's
   adversarial question about non-atomicity**, and it is a real window, not a hypothetical one.

3. **`children.avatar_key` and `media.thumb_key` are never collected.** `_media_keys`
   (`deletion.py:183-197`) selects `Media.s3_key` only. Avatars under `children/{id}/avatar/…`
   (`services/avatars.py:37-38`) **outlive the erasure permanently.** `thumb_key` is null today,
   so that half is latent. Directly contradicts the spec's *"a deleted account that leaves a
   bucket full of a child's photographs is the worst possible failure here."*

4. **No error handling and no error-level logging** in `services/deletion.py`, `services/s3.py`
   or `jobs/delete.py`. One S3 failure unwinds through the bare loop at `deletion.py:287-292`
   and silently skips every remaining due request.

5. **No `GET /me/deletion`.** A client that lost the 202 body cannot ask whether a deletion is
   pending.

6. Minor: `docs/blocked.md:829` and `roadmap-status.md` both say *"nineteen tests"* for the Apple
   webhook; the file has twenty.

---

## 7. Manual errands for Travis — none of these are discoverable from code

1. **Create a Sign in with Apple key (`.p8`) in the Developer portal.** Apple Developer
   enrollment is already resolved (`docs/blocked.md:146`), so the key *can* be created — it
   simply never has been, and **there is no `blocked.md` section asking for it.** Needed under
   both arms of the fork. Blocks A2 entirely.

2. **Register the SIWA server-to-server notification endpoint.** The URL Apple must be given is
   `https://rascal-api.fly.dev/v1/webhooks/apple-signin`. **It appears nowhere in the repo as a
   pasteable value** — in contrast to the App Store hook, whose full URL is written out at
   `docs/runbook-deploy.md:578`. `docs/blocked.md` §11 pre-step B records that nothing shows this
   was ever done.

3. **Schedule the deletion job** (defect 1 above). One `fly machine run` for
   `python -m rascal.jobs.delete`.

4. **Test revocation for real** once A2 ships: delete a test account, then confirm the app no
   longer appears under Settings → Apple Account → Sign in with Apple on that device. This is the
   only proof revocation worked, and it is the check Apple's reviewer performs.

5. **Document the deletion control's location in the review notes.** Reviewers look for it
   specifically; not finding it is a 5.1.1(v) rejection even when the feature exists — and here
   it does exist, and has since Aug 17.

---

## 8. The one decision that gates everything

> **Does Apple revocation work by persisting Apple's refresh token at sign-in, or by asking the
> parent to re-authorize with Apple at deletion time?**

Everything else in this phase is either already shipped or downstream of that answer, and the
two arms are not variations on one design:

- **Persist the token** — a migration, a secret at rest with no existing encryption helper, a
  change to `routers/auth.py:62-84`, **no iOS work at all** (the client already sends the code).
  **It covers no existing Apple user**, because nothing is stored to backfill from. Every current
  account stays unrevocable until its next sign-in.
- **Re-authorize at deletion** — no migration, no secret at rest, **covers existing users
  immediately**, and requires an iOS change to `DeleteAccountSheet.swift` that the API lane may
  not make. **That turns a one-lane phase into two.**

Both need the same portal errand and the same two Apple HTTP calls. The fork decides the schema,
the lane count, and the coverage — so it must be settled before a migration number is chosen or a
line is written.

**Three more to answer in the same sitting, each cheap once you are here and each gating code:**

- **Q5** (§3, diff 1) — the gate-2 halt.
- **A4's behaviour** (§4, diff 2) — refuse the promotion, reap the orphan rows, or accept it.
- **`DELETE /v1/me/credentials/{id}` on an Apple credential** — should removing *one* credential
  also call Apple's revoke, or only full account deletion? Credential revocation is documented as
  reversible by signing in again (`models/user.py:142-144`); calling Apple's revoke there would
  break that property. This is not in the spec, and it is the second place revocation belongs.

**And the scope call:** A1 and A3 should be struck from the spec regardless of how the fork is
settled. What is left for the API lane is A2, plus whichever of A4's three outcomes is chosen —
which is roughly a quarter of what the spec describes, and none of it can start today.

---

## 9. What was verified by running versus by reading

**By running:** the migration head and its linearity (`alembic heads --verbose`,
`alembic history`, a `down_revision` uniqueness sweep); `test_tier_has_exactly_one_writer`
(1 passed); `tests/test_deletion.py` (12 passed); the git divergence and both `phase-queue.md`
tails; every `grep` quoted in this report; `gh pr list --state open`.

**By reading only:** all decision-record quotations; the A4 execution path (traced through
`app_store_events.py`, not exercised); the S3 flush-versus-commit window (read in the source, not
reproduced); the avatar-key gap; the iOS inventory.

**SIWA revocation was not exercised against Apple, and could not be.** No call exists, no key
material exists, and no code was written this run. Nothing in this report claims otherwise.
