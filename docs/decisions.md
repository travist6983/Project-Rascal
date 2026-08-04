# RASCAL — Decision Log

Read this before proposing anything. Settled decisions are settled; don't relitigate them without new information.

Last updated: **Aug 3, 2026**

---

## Settled

### Product

| Decision | Rationale |
|---|---|
| One question + one mission per day | Borrowed from Paired. Two items is the most that survives a bad Tuesday. |
| Weekly bigger mission, Saturday | Room for the things that need an afternoon. |
| Monthly measurement mission | Height, weight, same-wall photo. Cheap, and the payoff compounds. |
| Items stack; expire at 14 days | Backlog is fine. Infinite backlog is guilt. |
| Parent can dismiss any item | Not every prompt fits every family. |
| Three completion shapes: did-it, captured-it, wrote-it | The inspiration list is mostly behaviors. A media-required schema loses half the product. |
| Freeform entries are first-class | Not everything worth keeping came from a prompt. |
| No streaks | A parenting app that punishes a missed day is a bad parenting app. |
| Sealed entries with `unlock_at_age` | Letters written *to* him. Impossible to retrofit at 500 entries. |
| Backdating is a core flow, not a setting | Camera-roll backfill is a whole mission category. |
| Kid gets access "later" — mechanism TBD | See open items. |

### Technical

| Decision | Rationale |
|---|---|
| Native iOS first, SwiftUI | Camera roll, mic, background upload, widgets, share sheet. The AI is a bonus; the capture surface is the reason. |
| Web client later, same API | Reserved architecturally, built only if this takes off. |
| FastAPI + Postgres + S3 | What I already know. Fastest path to shipping. |
| Fly/Railway + Neon for the POC | Not Fargate. Migrate when there's a reason. |
| SwiftData as a local cache, server as source of truth | One sync engine, written carefully, once. |
| Server owns the schedule, expiry, all logic | Two phones and a browser must agree on what today is. |
| Sign in with Apple as a credential row, not the identity model | Web signup later requires no migration. |
| Client-generated UUIDs + idempotency keys | Offline creation has to sync cleanly. |
| Presigned direct-to-S3, background `URLSession` | The server never proxies bytes. Video on cellular demands it. |
| Soft deletes and `updated_at` everywhere | The archive should outlive the app. |
| On-device AI output persisted server-side as plain data | A web client will never have an on-device model. The phone is an inference worker. |
| On-device transcription is the priority AI feature | It's what makes his voice findable in 2040. |
| Mission library authored server-side, never on-device | Small model, weak world knowledge, and these prompts are the soul of the product. |
| Rotating refresh tokens in a `refresh_tokens` table | A JWT I can't revoke is a problem the day I lose a phone. This archive has his face and voice in it. |
| Authorization is one FastAPI dependency, not per-handler checks | Retrofitting this at 20 endpoints is how a hole gets left in one of them. |
| Constrained columns are `text` + CHECK, never Postgres enums | Adding a value later is an `ALTER`, not a migration dance. |
| `updated_at` maintained by a database trigger | A bulk `UPDATE` from psql has to move the sync cursor too, or clients silently miss rows. |
| Scheduler takes `as_of_date` as an argument | Testable, backfillable, and re-runnable for a date I slept through. It never reads the clock from inside selection. |
| Keyset pagination on `(occurred_at, id)`, never OFFSET | Backdating inserts into the middle of the order. Offset paging would skip rows. |
| Debug routes and dev-login exist, gated to `local` | Building the daily loop means running it thirty times in an evening. Waiting for 5am is not a development strategy. |
| Prompts seed from a generated `prompts.yaml`, not from the markdown | The markdown stays the authoring surface. Runtime never parses a table. |
| Thumbnails and transcodes deferred out of P0 | `thumb_key` stays null. The capture path has to work before the polish path matters. |
| `entry_type` describes the artifact | In order: attached media wins (its kind); else a `did_it`-mode mission stays `did_it` however much you wrote about it; else any title or body makes it `text`; else `did_it`. Denormalizing the prompt's kind made the Voice filter surface entries with no audio; deriving purely from content pushed noted did-its out of the Did it filter. Both are the same lie in opposite directions. What was asked is still reachable through `assignment_id` → `prompt.kind`. |
| Deleting an entry releases its assignment | "Wrong photo, redo it" happens in week one. A mission stranded `done` with nothing to show for it loses the slot for the day. |
| Letters get their own slot, on the 15th | Sharing `monthly` with the measurement mission meant the money letter could lose that coin flip every month for years. The 15th rather than the 1st because four items in one day breaks the two-item rule. |
| Sync returns a 30-second overlap window; clients upsert by id | `now()` is transaction-start time, so a slow transaction can commit a row already behind another device's cursor and lose it forever. Re-delivery is free — entries are last-write-wins on a client UUID. A sequence has the identical race for a migration's cost. |
| Scheduler runs hourly and filters on local time | One daily cron is 5am in exactly one timezone and drifts an hour against DST twice a year. 24 wakeups a day is nothing, and the job is already idempotent. |
| `users.is_admin` gates writes to the mission library | `POST /prompts` was authenticated but not authorized. The library is content every child draws from; a grandparent's `viewer` login must not be able to write to it. |

### Design

| Decision | Rationale |
|---|---|
| Warm, friendly, polished — Journey and Raven register | Two attempts at an art-directed riso/poster direction were rejected. |
| Terracotta `#C05A2B` primary, periwinkle `#5566D6` secondary | Derived from the reference screenshots, not invented. |
| Cream canvas `#FDFAF4`, navy-charcoal ink `#23253C` | Never pure white, never pure black. |
| Color carries meaning: orange = missions/photos, blue = questions/voice | Not decoration. |
| Timeline is a scannable date-grouped card list with thumbnails | Not a full-bleed story feed. Every reference app does it this way. |
| Completion = circular terracotta checkmark + spring + haptic | Satisfying, quiet, repeatable. No stamp, no confetti. |
| Light mode only for now | Dark mode is P2 at the earliest. |
| Floating pill tab bar with center + FAB | Straight from the references. |

### Rejected — do not revisit

- Risograph, halftone, misregistration, screen-print aesthetics
- Condensed poster type, rotated headlines, type breaking the grid
- Passport-stamp completion, receipt-spike card stacks
- Full-bleed edge-to-edge photo timeline as the primary view
- Electric cobalt as the secondary color
- Rigid two-colors-only discipline
- Streaks, guilt copy, red urgency states

---

## Open

| # | Question | Needed by | Notes |
|---|---|---|---|
| 1 | The name | P1 | RASCAL is a placeholder. Needed for the widget, TestFlight, and the app icon. Alternates: SMALL FRY, SIDEKICK, HOLLER. |
| 2 | Handoff age — 10, 13, 16, or 18? | P4 | This is a *default* for `unlock_at_age`, set per-entry, so it isn't a lock-in. But it changes how you write. |
| 3 | What the handoff actually *is* — an account, an export, a device, a printed set? | P5 | Worth deciding before writing 500 entries addressed to someone. |
| 4 | Mission tone — warm, plain, or dry? | P1 | Set it before authoring 200 more prompts, not during. The seed library leans dry-and-specific; confirm that's right. |
| 5 | Video transcode policy | P1 | Original quality × two kids × eighteen years is real money. Decide before the archive is large. |
| 6 | Push notification time | P1 | One per day, silenceable. What time actually works? |
| 7 | Second kid — when? | P2 | Model already supports it. UI cost is a switcher plus per-child scheduling. |
| 8 | Does the printed book include did-it entries? | P4 | A page of behaviors with no photos may read beautifully or may read empty. |
| 9 | Full export format | P2 | Folder of files + JSON manifest. Build it before you'd need it. |

---

## Changelog

**Aug 4, 2026** — Hardening pass before iOS. Six decisions settled above, of which three
change the schema: `entry_type` narrows to the five things the derivation can produce,
`letter` joins the `slot` CHECK, and `users.is_admin` arrives. Migrations `0002` and `0003`,
both reversible, both taken while the database is empty. Two correctness fixes with no
schema cost: deleting an entry releases its assignment, and the sync cursor carries a
30-second overlap window. The coverage table in `mission-library.md` was corrected — it had
under-counted video, activity, and weekly since before the last prompts were added.

**Aug 3, 2026** — Build started. Sprint One planning added an "Epic Z" of ground-zero
infrastructure the original backlog assumed but never defined: repo skeleton, migrations,
seed loader, deploy pipeline, S3 setup. Backend build order fixed at skeleton → schema →
seeds → auth → endpoints → scheduler → deploy artifacts, with iOS deliberately held back
as a separate task so the first agentic run needs nothing from me. Nine technical
decisions settled above, of which two change the data model: a `refresh_tokens` table and
CHECK constraints in place of Postgres enums. Thumbnail generation cut from P0.

**Jul 31, 2026** — Design direction reset after two rejected mockup rounds. Riso/poster out, Journey/Raven register in. Palette rederived from reference screenshots. Timeline changed from full-bleed story feed to date-grouped card list.

**Jul 30, 2026** — Pivoted from web-first to native iOS first. Backend constraints for a later web client fixed at the same time. On-device AI plan set: transcription first, structured extraction second, camera-roll backfill third.

**Jul 30, 2026** — Initial scope set. Six phases, P0 exit test defined as behavioral (seven days of unforced use) rather than a feature checklist. Year One printed book set as the December forcing function.
