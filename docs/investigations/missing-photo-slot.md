# The photo slot is not being served — investigation

Run 2026-08-12 on `investigation/missing-photo-slot`, cut from `main` @ `90d1c03`. **Read-only:
no code changed, no production row written, no scheduler re-run.** Every production query below
is a `SELECT`; the two service calls are read paths.

> **This supersedes the earlier attempt on `claude/deploy-readiness-scheduler-5pr0uh`
> (`b98312b`), which is not on `main`.** That run had no `flyctl`, no egress to
> `rascal-api.fly.dev`, and no production database, so it recorded §1, §2.1–2.2, §3 and §4.1 as
> NOT INVESTIGATED and reproduced the failure locally instead. **This run had `flyctl`
> authenticated and executed all four.** Its hypothesis was substantially right and its benign
> alternative — "a one-time transition artifact on the day of the release" — is now **ruled out**.

---

## 1. The answer, in one sentence

**The hourly scheduler machine is pinned to a Fly image built ~22 hours before Phase 19's code
existed, so every morning it creates two slots instead of three and fills `mission` from all five
mission kinds rather than photo-only — and nothing ever corrects that row, so the photo slot has
not been served once since Phase 19 shipped.**

A second, independent cause is also live: **the installed iOS build predates `3df6cd4`**, so it
decodes `mission_b` as an unknown slot and renders it grey and "Still open". That one also fully
explains §4.3, which is therefore **not** a separate defect.

---

## 2. The slot-to-card mapping — established, not inferred

From the production rows for `assigned_on = 2026-08-12` (child `Hendrix`,
`c08d7fba-8baa-4a28-a348-fc5f07da63ba`, `America/Detroit`):

| Card in the screenshot | Slot | Prompt kind | Body |
|---|---|---|---|
| **VOICE** · "Today's mission" · Capture it | **`mission`** | `audio` | "Record him counting as high as he can go." |
| **ACTIVITY** · "Still open" · We did it | **`mission_b`** | `activity` | "Let him win, and don't tell him you did." |
| **QUESTION** · "Today's question" · Write it | **`question`** | `question` | "What is he afraid of right now?" |
| `WAITING — 2 waiting` | 2026-08-11's `mission` + `mission_b`, both still `pending` | | |

**The photo is missing because `mission` — the slot Phase 19 narrowed to photos only — is
occupied by an audio prompt.** It was not left empty; it was filled with the wrong kind.

**I did not receive the screenshot.** The mapping above is established from the database rows and
the client's own label and colour rules, not from the image. The one residual is noted in §6.

---

## 3. Every check, with raw output

### §1.1 — The assignment rows

```
CHILDREN:
   (UUID('c08d7fba-8baa-4a28-a348-fc5f07da63ba'), 'Hendrix', date(2022, 6, 19), 'America/Detroit')

ASSIGNMENTS 2026-08-09..13   (assigned_on, slot, status, kind, cadence, completion_mode, created_at, updated_at, body)
   2026-08-10  mission    dismissed  activity  daily  did_it  2026-08-11 01:07:17Z  2026-08-12 02:42:16Z  'Carry him when he asks, even though he can walk fine.'
   2026-08-10  question   done       question  daily  text    2026-08-11 01:07:17Z  2026-08-11 01:59:53Z  "What's his favorite thing to do with his mom?"
   2026-08-11  mission    pending    activity  daily  did_it  2026-08-11 09:26:04Z  2026-08-11 09:26:04Z  'Apologize to him for something. Out loud.'
   2026-08-11  mission_b  pending    activity  daily  did_it  2026-08-11 23:44:53Z  2026-08-11 23:44:53Z  'Go outside with him with no plan and no phone.'
   2026-08-11  question   done       question  daily  text    2026-08-11 09:26:04Z  2026-08-11 12:32:44Z  'What song is stuck in the house right now?'
   2026-08-12  mission    pending    audio     daily  media   2026-08-12 09:26:05Z  2026-08-12 09:26:05Z  'Record him counting as high as he can go.'
   2026-08-12  mission_b  pending    activity  daily  did_it  2026-08-12 10:38:35Z  2026-08-12 10:38:35Z  "Let him win, and don't tell him you did."
   2026-08-12  question   pending    question  daily  text    2026-08-12 09:26:05Z  2026-08-12 09:26:05Z  'What is he afraid of right now?'
```

Answering the brief's four questions directly:

- **How many slots for 2026-08-12?** Three. `mission_b` **does** exist.
- **Does `mission_b` exist at all?** Yes — on 08-11 and 08-12. So "the new code ran" *somewhere*.
- **If `mission` exists, what kind is its prompt?** `audio` on 08-12, `activity` on 08-11 and
  08-10. **Never photo.** The narrowing to `{photo}` is not in effect on whatever wrote these.
- **`created_at` versus the release:** this is the load-bearing observation. Note the pairing —

  | day | `question` + `mission` created | `mission_b` created |
  |---|---|---|
  | 08-11 | **09:26:04** | 23:44:53 |
  | 08-12 | **09:26:05** | 10:38:35 |

  `question` and `mission` share a timestamp to the microsecond — one transaction, and always at
  **:26**, which is the scheduler machine's hourly boot (see §3 logs). `mission_b` is created
  **off-cadence, over an hour later, by a different process** — the read path (§3, `ensure_day_filled`).

  **Two writers, two different images.**

### §1.2 — The `slot` CHECK constraint, read from production

```
CONSTRAINT: ck_assignments_slot | CHECK ((slot = ANY (ARRAY['question','mission','mission_b','weekly','monthly','letter'])))
CONSTRAINT: uq_assignments_child_id_assigned_on_slot | UNIQUE (child_id, assigned_on, slot)
```

**It admits `mission_b`.** No insert was ever rejected by it, so the rollback question the brief
raises does not arise.

### §1.3 — `alembic_version` in production

```
ALEMBIC_VERSION: [('0008_mission_b_slot',)]
```

Head. The migration ran.

### §1.4 — Active prompt counts, from production

```
ACTIVE DAILY PROMPTS BY KIND:
   ('activity', 'daily', 16)
   ('audio',    'daily', 12)
   ('photo',    'daily', 22)     ← the pool that is allegedly empty
   ('question', 'daily', 30)
   ('video',    'daily', 11)
```

**All-time, every `mission` row ever written:**

```
ALL-TIME mission slot by kind: [('activity', 2), ('audio', 1)]
mission rows span: (2026-08-10, 2026-08-12, 3 rows)
mission_b rows total: 2
```

**Zero photos, across every `mission` row that has ever existed.** The archive is young — three
days — so this is 3 of 3 rather than a long run, but it is complete rather than sampled.

### §2.1 / §2.2 — What is actually deployed

```
 ID             │ NAME               │ STATE   │ PROCESS GROUP │ IMAGE
 2870901b4761d8 │ delicate-wind-1252 │ stopped │ app           │ rascal-api:deployment-01KZSQ43BP46RAN8Z2ZC8AEMZ1
 e826d3df469118 │ patient-wood-1946  │ started │ app           │ rascal-api:deployment-01KZSQ43BP46RAN8Z2ZC8AEMZ1
 185d762c643778 │ divine-hill-1816   │ stopped │ (none)        │ rascal-api:deployment-01KZQ30VVRJEM2SQK99QWM6HXF
```

Release → image:

```
 v1: 2026-08-11T00:20:22Z  deployment-01KZQ30VVRJEM2SQK99QWM6HXF   ← the scheduler machine
 v7: 2026-08-11T23:18:25Z  deployment-01KZSHWD056KQJG48KC9X065D0
 v8: 2026-08-12T00:31:38Z  deployment-01KZSP2NBHSXSEP70J1CVPHSQQ
 v9: 2026-08-12T00:49:49Z  deployment-01KZSQ43BP46RAN8Z2ZC8AEMZ1   ← both app machines
```

Timeline:

```
2026-08-11T00:20:22Z   v1 released                       ← scheduler machine's image, frozen here
2026-08-11T22:18:35Z   3df6cd4 authored — mission_b, photo narrowing
2026-08-11T23:49:05Z   PR #48 merged (546d02e)
2026-08-12T00:49:49Z   v9 released                       ← app machines
```

**The scheduler machine's image predates the existence of Phase 19's code by roughly 22 hours.**
It has never run it, not once.

The third machine has **no process group**, which is why `fly deploy` does not update it — exactly
the failure mode `docs/runbook-deploy.md` §9 warns about for a machine created with
`fly machine run` rather than as part of the app's machine set.

**Is it running the scheduler or a third uvicorn?** The scheduler:

```
 Command       │ ["python","-m","rascal.jobs.scheduler"]
 Created       │ 2026-08-11T00:26:19Z
```

with a clean hourly cycle (`start` at :26:00, `exit code=0` at :26:11). **So the runbook's
`--command`-dropped-silently bug is not in play** — that half was fixed. The machine does its job
correctly; it is simply doing the *old* job.

### §2.4 — Do migrations run on release?

`fly apps list` returns exactly one app (`rascal-api`), so there is no second writer anywhere in
this account.

`api/fly.toml`:

```toml
[deploy]
  release_command = "alembic upgrade head"
```

Yes — which is why §1.3 is at head despite the scheduler being stale. The release command runs on
the *deploy*, not on the ad-hoc machine.

### §3 — What the scheduler logged

```
2026-08-12T09:26:00Z  Preparing to run: `python -m rascal.jobs.scheduler` as rascal
2026-08-12T09:26:05Z  {"logger": "rascal.scheduler", "message": "scheduler run", "children": 1,
                       "children_off_hour": 0, "assignments_expired": 0,
                       "assignments_created": 2, "assignments_skipped": 0, "slots_exhausted": 0}
2026-08-12T09:26:05Z  scheduler: 2 created, 0 already there, 0 expired, 0 not at their 5am,
                      0 slot(s) with no eligible prompt
2026-08-12T09:26:05Z  Main child exited normally with code: 0

2026-08-12T10:26:05Z  {... "children_off_hour": 1, "assignments_created": 0, "slots_exhausted": 0}
```

**`assignments_created: 2`, not 3.** And **`slots_exhausted: 0`** — the scheduler did not leave a
slot empty for want of a prompt; it does not know there is a third slot to fill.

No `IntegrityError`, no CHECK violation, no rollback anywhere in the retained window.

**`GET /children/{id}/pool-health`** — the endpoint needs a user token, and minting one writes
refresh-token rows to production, which this run's read-only rule forbids. The same service was
therefore called directly, read-only, on the **v9** app machine:

```
SlotHealth(slot='question',  kind='question', eligible=30, suppressed=0, served_within_cooldown=3, available_now=27, relaxation_active=False, relaxation_step='none')
SlotHealth(slot='mission',   kind='photo',    eligible=20, suppressed=0, served_within_cooldown=0, available_now=20, relaxation_active=False, relaxation_step='none')
SlotHealth(slot='mission_b', kind='video',    eligible=10, suppressed=0, served_within_cooldown=0, available_now=10, relaxation_active=False, relaxation_step='none')
SlotHealth(slot='mission_b', kind='audio',    eligible=11, suppressed=0, served_within_cooldown=1, available_now=10, relaxation_active=False, relaxation_step='none')
SlotHealth(slot='mission_b', kind='activity', eligible=16, suppressed=0, served_within_cooldown=4, available_now=12, relaxation_active=False, relaxation_step='none')
SlotHealth(slot='weekly',    kind='any',      eligible=10, available_now=10, relaxation_active=False)
SlotHealth(slot='monthly',   kind='photo',    eligible=1,  available_now=1,  relaxation_active=False)
SlotHealth(slot='monthly',   kind='video',    eligible=0,  available_now=0,  relaxation_active=True, relaxation_step='age_window_dropped')
SlotHealth(slot='monthly',   kind='audio',    eligible=0,  available_now=0,  relaxation_active=True, relaxation_step='age_window_dropped')
SlotHealth(slot='monthly',   kind='activity', eligible=0,  available_now=0,  relaxation_active=True, relaxation_step='age_window_dropped')
SlotHealth(slot='monthly',   kind='measurement', eligible=3, available_now=3, relaxation_active=False)
SlotHealth(slot='letter',    kind='letter',   eligible=8,  available_now=8,  relaxation_active=False)
```

**`mission` / `photo`: 20 available, 0 on cooldown, no relaxation.** The pool this ticket suspects
is the healthiest daily pool in the archive. **The photo slot is not empty for want of photos.**

*(Unrelated but visible: the three `monthly` non-photo kinds are at zero with the age window
already dropped. Not this bug; worth its own ticket.)*

### §4 — The client

**§4.1 — the live Today JSON: NOT EXECUTED.** It needs a real user token, and issuing one writes
to production. The database rows in §1.1 are the same ground truth for the slot question, and the
serializer was read instead (below) to confirm nothing is dropped between the rows and the wire.

`api/src/rascal/routers/today.py:71-83` serves what exists — `assignments_for(...)` then
`to_assignment_out(...)` per item, with no slot allow-list. **The API returns all three slots.**

**§4.2 — does the client render slots generically?** Nearly. `ios/Rascal/Rascal/Models/TodayResponse.swift:90`:

```swift
nonisolated enum Slot: RawRepresentable, Equatable, Sendable {
    case question, mission, missionB, weekly, monthly, letter
    case unknown(String)
    ...
    case "mission_b": self = .missionB
```

It is a fixed list **with an `unknown` fallback**, so an unrecognised slot degrades rather than
being dropped. Nothing is silently discarded.

**Which slots say "Today's mission"?** `PromptCard.swift:214-224`:

```swift
case .question: assignedOn == today ? "Today's question" : "Still open"
// Both daily missions say the same thing. There is no "second mission" in the copy
case .mission, .missionB: assignedOn == today ? "Today's mission" : "Still open"
case .unknown: "Still open"
```

**So on current `main`, a `mission_b` assigned today would read "Today's mission".** The screenshot
reads "Still open" — which is what `.unknown` produces. **The installed build predates
`3df6cd4`** (2026-08-11T22:18:35Z), the only commit that taught the client `mission_b`.

**§4.3 — the grey "Still open" ACTIVITY card.** Not a section-assignment defect and not intended
Today v2 behaviour. `AssignmentPresentation.swift:12-38`:

```swift
var isRecognised: Bool {
    if case .unknown = slotKind { return false }
    if case .unknown = promptKind { return false }
}
// line 22:  guard isRecognised else { return .inkMuted }   ← grey text
// line 30:  guard isRecognised else { return .surface }    ← neutral fill
// line 38:  guard isRecognised else { return .border }     ← neutral border
```

**The label and the colour come from the same line.** Both are symptoms of the stale client, not a
third bug. Per the brief it is reported and not fixed — and the finding is that there is nothing
here to fix beyond shipping a current build.

**§4.4 — stale local cache.** Not required as an explanation: the three cards' *kinds and bodies*
match the production rows exactly, so the screen is honest about content. The only divergence is
label and colour, and both are explained by the build. Not fully ruled out as a contributor,
because §4.1 was not executed — see §6.

---

## 4. Hypotheses, each with a verdict

| # | Hypothesis | Verdict | Evidence |
|---|---|---|---|
| 1 | Merged but not deployed | **Eliminated** | App machines on v9; `alembic_version` at `0008`; `pool_health` from the app machine reports `mission → photo`. |
| 2 | **Scheduler machine stale** | **CONFIRMED — primary cause** | Machine `185d762c643778` on image `01KZQ30VVR…` = **v1**, 2026-08-11T00:20:22Z, ~22h before `3df6cd4` existed. No process group, so `fly deploy` never touches it. |
| 3 | Scheduler machine running the wrong process | **Eliminated** | `Command = ["python","-m","rascal.jobs.scheduler"]`; hourly logs show real scheduler runs exiting 0. |
| 4 | Migration not applied in production | **Eliminated** | `alembic_version = 0008_mission_b_slot`; CHECK admits `mission_b`; `release_command = alembic upgrade head`. |
| 5 | Pool exhausted | **Eliminated** | 22 active daily photo prompts; `mission/photo available_now=20`, `served_within_cooldown=0`, `relaxation_active=False`; scheduler logs `slots_exhausted: 0`. |
| 6 | Candidate query broken by the narrowing | **Eliminated on current code** | v9's `pool_health` correctly reports `mission → photo` and `mission_b → video/audio/activity`. The stale image is the problem, not the query. |
| 7 | `ensure_day_filled` not updated alongside the nightly job | **Eliminated — the brief was followed** | Both call `_fill_slot`; `scheduler.py:161` and `:374` say so explicitly. The divergence is **machine images, not code**. |
| 8 | **Client dropping or mislabelling the slot** | **CONFIRMED — second, independent cause** | Client learned `mission_b` only in `3df6cd4`; `.unknown` → "Still open" + `.inkMuted`/`.surface`/`.border`. Nothing is dropped, but it is mislabelled and mis-tinted. |
| 9 | Stale local cache | **Not required; not fully ruled out** | Card kinds and bodies match the production rows exactly. §4.1 not executed, so a cache contribution to *labels* cannot be excluded outright. |

**Two causes are live simultaneously**, which is what §0 warned about: fixing the scheduler makes
the photo appear, and the ACTIVITY card would *still* read "Still open" in grey until a current
build is installed.

---

## 5. Verified empirically vs reasoned about

**Verified — I ran this against production:**

- The eight assignment rows for 08-09..08-13, with `created_at` to the microsecond.
- The `slot` CHECK constraint and unique constraint, from `pg_constraint`.
- `alembic_version`.
- Active daily prompt counts by kind.
- The machine list, the ad-hoc machine's `Command`, its event log, and its image ref.
- The release → image mapping for v1..v9.
- The scheduler's own log lines for 09:26 and 10:26 on 2026-08-12.
- `pool_health` for all seven slot/kind pairs, via the service on the v9 machine.
- `fly.toml`'s `release_command`.
- The client's `Slot` enum, `footnoteLabel`, and `isRecognised`, on `main`.

**Reasoned about — not executed:**

- **That `mission_b`'s off-cadence `created_at` is `ensure_day_filled` on the read path.** Strongly
  supported (the timestamps are not on the :26 boot cycle; `GET /today` calls it at
  `today.py:69`; notifications call it too) but I did not trace a specific request to a specific
  row.
- **That the installed iOS build predates `3df6cd4`.** Inferred from the label and colour, both of
  which follow from `.unknown`. I did not read the build number off the device.
- **The slot-to-card mapping**, which is established from the rows plus the client's rules rather
  than from the screenshot — which I never received.
- **That a photo would appear "by luck" roughly 1 day in 5** under the old all-kinds selection.
  Consistent with three days of activity/activity/audio, but three samples prove nothing.

---

## 6. Least confident, ranked

1. **Which row the ACTIVITY card actually is.** I read it as 2026-08-12's `mission_b` rendered
   `.unknown`. But "Still open" is *also* what a **recognised** slot with `assignedOn != today`
   produces — so it could be one of the two 08-11 rows in the waiting set. The grey tint argues
   against that (08-11's `mission` is `activity`/did-it and would render sage), and its being
   inside the TODAY section argues against it too. **Resolved by:** the raw `/today` JSON, or the
   build number on the phone.
2. **Whether a stale cache is contributing anything.** Not needed to explain the screen, but §4.1
   was not run. **Resolved by:** the raw JSON compared against the screenshot.
3. **Whether `mission_b` being written by the read path has its own consequences** — a child who
   never opens the app gets no `mission_b` at all until they do, and the notification path also
   calls `ensure_day_filled`. Not investigated; possibly benign, possibly its own ticket.

---

## 7. The proposed fix — stated, not applied

Per §6 of the brief, the cause is **deployment and machine state**, so **the fix is operational
and belongs in `docs/runbook-deploy.md`, not in application code.** No application code should
change for this.

**The fix:** destroy the ad-hoc scheduler machine and recreate it as part of the app's machine
set, so `fly deploy` updates it like any other — a `[processes]` entry in `fly.toml` with a
`scheduler` group, or at minimum a documented post-deploy step that updates it explicitly. The
runbook already records that this machine was built wrong once; it now records that it also does
not get updated, which is the more expensive half.

**Cost:** one deploy. The machine is stateless and runs for 11 seconds an hour.

**What it does not cover:**

- **The 08-11 and 08-12 rows stay wrong.** Per the brief's standing rule they are not backfilled —
  those days are historically accurate about what was asked, and a hand-inserted assignment would
  be the archive telling a small lie.
- **The client half.** The grey "Still open" card persists until a build containing `3df6cd4`
  is installed. That is a TestFlight release, not a server fix.
- **Nothing about the `monthly` pools at zero**, visible in §3's `pool-health` and out of scope
  here.

**Explicitly not done:** no prompts authored (pool exhaustion was eliminated, and §6 forbids it
regardless), no rows touched, no scheduler re-run, no test assertion edited.

---

## 8. Adversarial re-read

Re-read as though the conclusion were wrong.

- **Is the slot-to-card mapping established or inferred from labels?** *Established* for the VOICE
  and QUESTION cards — the kinds and bodies come from the rows and there is exactly one `audio`
  and one `question` row on 08-12. **Partly inferred for the ACTIVITY card** (§6.1), and the report
  now says so rather than claiming three-for-three.
- **Does the evidence distinguish "not served" from "served and not drawn"?** **Yes, decisively.**
  The `mission` row exists and holds an `audio` prompt. There is no photo row to draw. This is not
  a rendering failure — and that distinction is exactly what the earlier investigation could not
  make without the database.
- **Did I compare `created_at` against the release timestamp, or assume the row is new?**
  Compared, and it is the load-bearing fact: rows at **09:26:0x** on the scheduler's boot cycle,
  against a scheduler image from **2026-08-11T00:20:22Z** and Phase 19 code from
  **2026-08-11T22:18:35Z**.
- **Did I read the constraint from production or from the migration file?** From production
  `pg_constraint`. It admits `mission_b`, which is why hypothesis 4 dies.
- **Is a second cause still standing that the first would mask?** **Yes — the stale client, and it
  is why this report has two confirmed causes rather than one.** Fixing the scheduler will make a
  photo appear tomorrow and will *not* fix the grey "Still open" card. Had only the scheduler been
  fixed, that card would have looked like a fresh regression.

**One thing the re-read changed:** the earlier investigation offered "a one-time transition
artifact on the day of the release, which is not a bug" as the benign alternative. **That is ruled
out.** The 08-12 row was written at 09:26:05Z — nine hours *after* v9 shipped — by a machine that
still cannot see Phase 19. This recurs every morning until the machine is replaced.
