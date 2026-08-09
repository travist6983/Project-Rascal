# RASCAL — Decision Log

Read this before proposing anything. Settled decisions are settled; don't relitigate them without new information.

Last updated: **Aug 9, 2026**

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
| Video is transcoded to 1080p H.264/AAC in MP4 before upload; the original is written back to the camera roll, never discarded | Same reasoning as HEIC→JPEG: the archive has to open in 2040 in something that isn't Apple, and H.264/MP4 is the most universally decodable video there is. 1080p is what these are actually watched at, and it is roughly a fifth the bytes of 4K — ~70MB/min against ~375MB/min, which over eighteen years and two children is the difference between about 130GB and 650GB. Transcoding is lossy and irreversible, so an in-app capture saves its original to the user's photo library first: the archive stays lean without anything being destroyed to achieve it. |
| `users.is_admin` gates writes to the mission library | `POST /prompts` was authenticated but not authorized. The library is content every child draws from; a grandparent's `viewer` login must not be able to write to it. |
| iOS client lives in this repo under `ios/`, not a separate repo | The client reads `docs/api-contract.md` directly instead of a copy that drifts. CI is scoped by path so the lanes stay independent. |
| Stored `child_age_months` is corrected by explicit user action, never automatically on birthdate edit — a correction is deliberate, not a side effect | `POST /children/{id}/recompute-ages`. Storing the age at write is what stops a birthdate typo silently reshaping 500 entries; the cost is that the typo is otherwise permanent, so the escape hatch has to exist and has to be the user's to pull. It writes only the rows that actually change, because bumping `updated_at` on the whole archive would push eighteen years of entries back through every client's sync cursor to fix three of them. |
| Audio is recorded as AAC in `.m4a`, 44.1 kHz, **mono**, 96 kbps | Same reasoning as JPEG over HEIC and H.264 over HEVC: the archive has to open in 2040 in something that isn't Apple, and AAC in MP4 is the most universally decodable audio there is. Mono because a child talking is a point source and stereo doubles eighteen years of storage for nothing. 96 kbps is transparent for speech and puts a ten-minute recording at roughly 7MB — under the server's multipart threshold, though nothing in the client special-cases audio to stay there: a larger file takes the existing multipart path unchanged. |
| Recording is foreground-only in P0; screen lock stops and preserves | Background audio is a one-line entitlement and a real App Store review surface, and "record two minutes of dinner" is not worth taking that on to close P0. Every interruption path already finalises to a playable file, so adding the entitlement later changes when recording stops, not whether anything is lost. |
| Bundle id is `com.travisterry.childarchive` | A bundle id is permanent and the app name is still open, so it is deliberately name-neutral — RASCAL, SMALL FRY, or anything else can ship on top of it. Settled before the Xcode project exists, because changing it afterward means redoing signing and the Sign in with Apple registration for nothing. `APPLE_BUNDLE_ID` must match it: it is the `aud` claim every Apple identity token is verified against. |

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
| Destructive and irreversible actions are isolated in a separate bottom card, never adjacent to ordinary edit rows | A divider between two rows says "these belong together"; a gap says "these do not". Recomputing every stored age in an archive is not a neighbour of changing a name, and a mis-tap between the two is not recoverable by tapping again. |

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
| 6 | Push notification time | P1 | One per day, silenceable. What time actually works? |
| 7 | Second kid — when? | P2 | Model already supports it. UI cost is a switcher plus per-child scheduling. |
| 8 | Does the printed book include did-it entries? | P4 | A page of behaviors with no photos may read beautifully or may read empty. |
| 9 | Full export format | P2 | Folder of files + JSON manifest. Build it before you'd need it. |
| 10 | **Pronouns, and where the child's name appears in prompts** | **With onboarding** | The library is written he/him and stays that way for now — see the changelog entry below, this is deliberate, not an oversight. Onboarding is the unlock: once it collects the child's pronouns, prompts should render with the right ones, and the name should appear where it reads warmer than "your child". Two mechanisms, and they are separable — pronoun substitution is a rendering concern, a `{name}` token is a content-format decision with a contract every consumer must honour. Do not let the second block the first. |

---

## Changelog

**Aug 9, 2026** — Video transcode settled, and Tigris multipart verified before any client code
was written. A 40MB object was uploaded in five presigned parts and fetched back byte-identical,
so the part-splitting contract, the ETag-per-part requirement, and completion all hold on Tigris
rather than being assumed from S3. `chunk_bytes` came back 8388608 and the server planned five
parts, which is the number the client must split at — not a number it may choose.

Transcode: **1080p H.264/AAC in MP4**, with an in-app capture's original written back to the
camera roll. The reasoning is the same one that made photos JPEG rather than HEIC — the archive
must open in 2040 in something that isn't Apple — plus the storage arithmetic, which is not
marginal: ~70MB/min against ~375MB/min for 4K. Discarding an original outright was rejected;
transcoding is irreversible, and a capture taken in-app exists nowhere else unless it is saved.

**Aug 8, 2026** — **The mission library stays he/him for now. This is a decision, not an
oversight, and it will look like a bug to anyone who reads the library's own rules.**

`docs/mission-library.md` rejects any prompt that "assumes a two-parent household, a particular
income, or a particular ability" — and several prompts say *his mom*, which assumes both a
gender and a household shape. That contradiction is real and it is knowingly left in place.

The reason: this is being developed live against one specific child, who is male, and rewriting
113 prompts to neutral pronouns now would make every prompt read slightly less naturally for the
only person currently using the app, in exchange for correctness that no user yet needs.

**What has to happen, and when:** onboarding is the unlock. Once it collects the child's
pronouns, prompts render with the right ones. Beyond that, the child's *name* should appear
where it reads warmer than a pronoun would — the same idea P3's on-device personalization builds
on. Tracked as open item 10.

Two things for whoever picks this up. The mechanisms are **separable**: pronoun substitution is a
rendering concern needing no new content format, while a `{name}` token is a content-format
decision with a contract every consumer — client, the browser client reserved for 2027, export —
has to honour or prompts render with literal braces. Do not let the second hold up the first.
And prompts naming a *specific other parent* ("his mom") need rewriting or cutting either way;
that is the household-shape assumption, and it is the part the library's own rules already
forbid.

**Aug 9, 2026** — The client's half of sync lands, and **ships switched off**. `GET /sync` is
now read, applied, and gated behind `syncPullEnabled`, which defaults to false. The engine
touches the local cache every other screen reads from, so it is verified against a real archive
before it is trusted with one; a dry-run mode does a genuine `GET /sync`, computes exactly what
it would insert, update and soft-delete, and reports it without applying a single change. Four
decisions settled with it.

**The conflict rule.** Last-write-wins by `updated_at`, matching the server — *except* that a
local record with unpushed changes is never overwritten. The push queue wins, and the record
reconciles on the next pull after a successful push. This is not a refinement of last-write-wins,
it is the thing that makes the engine safe: a row this phone has written and not yet sent is the
parent's most recent intent, and the server's copy is by definition older. Without it, an edit
made on a train disappears the moment the train reaches a signal. The same rule covers media
still uploading and — the case Today already relied on — an assignment completed here that the
server still calls pending. A pull must never revert a locally-completed mission, and that is now
enforced in the cache rather than only papered over by the board's merge.

**The overlap window is handled by being idempotent, not by deduplicating.** The server hands
back `max(updated_at)` minus thirty seconds so a row written by a slow transaction is
re-delivered rather than skipped. The consequence for the client is not that duplicates are
tolerable — it is that **every apply path must leave the store byte-identical when run twice**,
because the window guarantees it happens on every pull. Every apply is therefore a pure
assignment of server fields and never an accumulation, and the idempotency is asserted directly
rather than assumed. Two other things fell out of reading the server rather than the contract:
`GET /sync` does not page, and an *empty* batch still returns an advancing cursor (`now() - 30s`,
since there is no maximum to take), so the round loop terminates on an empty batch first and on a
non-advancing cursor second. Testing only for cursor movement spins forever against an idle
archive.

**The trigger set is deliberately boring:** app foreground, pull-to-refresh on Timeline, straight
after a push-queue drain, and Today's load. **Background sync is deferred** — no `BGAppRefreshTask`,
no timers. It is a separate decision with battery and App Review implications, and taking it
alongside a first sync engine would mean shipping two unverified things and being unable to tell
which one misbehaved. The four triggers coalesce: overlapping ones join the in-flight pull rather
than queueing four identical ones. Push always drains before a pull applies, for the same reason
entries drain before media in the upload sweep — pulling first can hand back a stale row that
overwrites a local edit still in the queue.

**`Assignment` becomes a local `@Model`**, which is the one part of this that touches the
SwiftData schema. It was taken rather than dropping the `assignments` array on the floor: a new
entity is the only schema change that cannot fail lightweight migration the way rule 6 of
`ios/CLAUDE.md` describes, because there are no existing rows of a type that never existed. It is
covered by a real old-schema-to-new-schema test — a store written by the previous three-entity
schema, reopened under the four-entity one — which is the test `StoreMigrationTests` said it could
not write until there was a previous schema to express.

**Aug 8, 2026** — Completion motion widened after the first device session; the no-confetti and
no-streak rules **reaffirmed, not relaxed**. On a phone the completion check simply appeared,
which read as a status field changing value rather than as finishing something. The fix is
motion and timing, not decoration: the check now *draws itself* on the existing spring
(`response: 0.35, damping: 0.7`), the upload ring completes into it so saving and finishing are
one gesture rather than two states swapped at the end, the card settles into Done Today over
0.4s, and the haptic warms from `.light` impact to `.success` notification. Explicitly still
excluded: confetti, particles, stamps, sound, streaks. The original rule was never meant to mean
flat — it meant nothing that congratulates compliance. Reduce Motion still fills the check
without springing, because removing the feedback entirely is a different bug.

Same session: Today now merges local state over the server's board. A photo mission completed
offline kept rendering as not-done while a text answer on the same screen showed done, because
one had synced and the other had not — the same action producing two outcomes decided by network
timing. A completion is a fact about the parent's evening; whether the server has heard is a
fact about the network, and the screen must not conflate them.

**Aug 8, 2026** — Bundle id settled as `com.travisterry.childarchive`, ahead of the Xcode
project rather than after it. Name-neutral on purpose: open question #1 is still open, and a
bundle id outlives whatever the app ends up being called. This closes the "what I need" line
in `blocked.md` §1 — enrollment can now proceed against a real identifier, and
`APPLE_BUNDLE_ID` has already been flipped from `com.example.rascal` to match it, in
`.env.example` and in `ci.yml`; the Fly secret follows when the app exists.

**Aug 8, 2026** — The iOS client lives here, under `ios/`, rather than in its own repo. It
was planned as a separate one; the deciding argument is that a client in the same tree reads
`docs/api-contract.md` directly instead of a copy that drifts, and `make fixtures` can
capture real API responses into `ios/Fixtures/` as ground truth for JSON decoding. The cost
is that CI had to learn the difference: `ci.yml` and `deploy.yml` now carry path filters so
an iOS-only commit neither runs the Python suite nor deploys an unchanged API. The two lanes
are kept apart by convention rather than by tooling — `CLAUDE.md` and the new `ios/CLAUDE.md`
each state that an agent in one lane never edits the other. No API behavior changed.

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
