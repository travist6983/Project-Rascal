# RASCAL iOS — Phase 2.5 (Fix & Feel) report

**Aug 8, 2026.** Branch `ios/phase2.5-fix-and-feel`, off the merged capture work.
Nothing under `api/` touched. **69 tests in 7 suites, zero warnings.**

## Preflight

| Check | Result |
|---|---|
| Clean build from empty derived data | **0 errors** |
| Full suite | **57 passed** (before this phase's changes) |
| `/health`, auth, `today` | ok / ok / **empty — see below** |
| **C-6 audio** | **Dropped.** No `AVAudioRecorder` anywhere; `Media/` has no recorder |
| **`needingRefetch` consumer** | **Still none.** Referenced only by its own definition and one test |

`today` came back **0 / 0 / 2** — the board was empty because I'd completed those assignments
during the Phase 2 verification, not because anything was broken. Restored with
`debug/reset-today` + `debug/scheduler/run` to get a working board (mission/photo/media,
question/question/text, weekly/activity/media).

On `needingRefetch`: per the rule you set, D-1 consumes it or the Phase 3 PR deletes it. It is
still neither.

---

## What shipped

### F-1 — Today merges local over server

`TodayBoard.merge(response:entries:media:)` — a pure value type, so the merge is testable
without a view. Local entries are folded over the server's board by `assignment_id`; an entry
completing an assignment renders it done regardless of what the server thinks.

Read through `@Query` rather than held in memory, so it survives relaunch by construction rather
than by remembering to reload.

**What the merge revealed about the Today model** — the thing worth recording:

The old model treated `TodayResponse` as *the* board. It isn't; it's the server's half. Two
sections of that response, `today` and `waiting`, are really "assignments the server believes
are outstanding" — a belief that goes stale the instant a parent saves anything offline. The
merge makes that explicit: the server owns **what was assigned**, the client owns **what was
done**, and the screen is the join.

That reframing also removed a bug I hadn't set out to fix. `done_today` is server-computed from
`occurred_at`, so a *backdated* entry completing today's assignment never appeared there — the
card would have sat in Today looking untouched even after syncing. The local join catches it
because it keys on `assignment_id` rather than on a date.

The dedupe is doing real work, not defensive padding: for a window after sync the assignment is
in `done_today` **and** has a local entry, and without it the card renders twice.

### F-2 — Progress on the card

Banner gone. `UploadRing` fills from **real bytes**: the delegate writes `totalBytesSent` to the
row as the session reports it.

Weighted by bytes rather than file count — three photos where one is 8× the others would
otherwise jump the ring to two-thirds while most of the work was outstanding. `bytesSent` resets
to 0 on failure, because a retry re-sends from the start and a stale high-water mark would make
the ring appear to go backwards.

Failures list per file with their own **Upload it**, plus **Upload all N** when there's more than
one. The copy says "This photo hasn't uploaded yet" — what happened, no implication of loss,
because there isn't one.

### F-3 — Completion

The check draws itself via a trimmed `Path` on the existing spring, the ring closes into it, the
haptic warmed to `.success`. Reduce Motion still fills without springing. Logged in
`decisions.md` as a deliberate widening with the no-confetti and no-streak rules reaffirmed.

### F-4 — Composer defects

All four. The `+` tile now opens the same picker via a programmatic `.photosPicker`; the freeform
composer attaches photos and is framed like the prompted one; **no video affordance anywhere**.

The date picker is worth a note. The numerals were inheriting `inkMuted` from the surrounding
metadata styling — grey on cream, under contrast minimums. The *selected* date looked fine
because `.tint` colours it independently, which is precisely why it survived review: the one
date you're looking at while checking is the one that was never broken.

### F-5 — Done cards

Tint by kind, sage reserved for `did_it`. Tapping opens the composer in edit mode via
`PATCH /entries/{id}`, media read-only.

**One model change this forced, and it's the sharpest thing in the phase.** `Entry.existsOnServer`.
Without it, an edit made offline would be re-**POST**ed by the sweep, the stored idempotency key
would return the **original** body byte-for-byte, and the edit would silently vanish while the
sweep reported success. The idempotency guarantee that makes creation safe is exactly what makes
editing unsafe if the two aren't distinguished.

---

## Was per-file progress as available as expected?

**Yes, and slightly better.** `didSendBodyData` fires on the background session with
`totalBytesSent` per task, and `taskDescription` carries the `media_id` across a relaunch — so
progress attributes correctly even when the callback arrives into a process that has restored
nothing.

Two caveats:

1. **Granularity is the system's, not ours.** Callbacks arrive per chunk written to the socket,
   so a small photo on fast wifi can go 0 → 100 in one callback. The ring is correct but barely
   animates. That's honest — it *did* take one beat — and I'd rather it be abrupt than pad it.
2. **Not verified on device.** Everything above is simulator. On cellular, callback cadence is
   the thing most likely to differ, and it's in the device session.

## Language

No user-facing string I wrote assumes a child's gender. The strings I touched are neutral, and
none of the new copy introduces one.

**The library is the visible problem and it's Lane A.** The board on screen right now says *"Take
a photo of him with his grandparents"* and *"What's the last thing he was proud of himself for?"*
— see appendix A-2, which I have **not** started because it requires your decision first.

---

## What I'd change / am unsure about

**1. `TodayBoard.merge` runs on every render.** It's O(entries + media) with two dictionary
builds. Fine at tens of entries; at a thousand it's wasteful. A `@Query` filtered to
assignment-completing entries would fix it, but SwiftData predicates over optionals are awkward
and I'd rather not contort the model before there's a measurable problem.

**2. The ring animates `fraction` with a fixed `easeInOut(0.3)`.** If a callback lands mid-animation
the ring effectively re-targets, which looks smooth but means displayed progress can lag actual by
a fraction of a second. Correct enough for a progress indicator; worth knowing it isn't exact.

**3. Edit mode sets `didIt = true` unconditionally when loading an entry.** For a did-it entry
that's right. For a text entry the flag is unused. It works but reads as sloppy, and if edit mode
ever gains the did-it toggle it would be wrong.

**4. `existsOnServer` defaults to `false` on existing rows.** Anything already in SwiftData from
before this build will be treated as new and re-POSTed. The idempotency key makes that safe — the
server returns the original — but it means a *pre-existing* unsynced entry can't be edited-then-
synced correctly. Only affects my dev device. Worth knowing before any TestFlight build.

**5. I did not add the macOS CI job.** You agreed it goes in before Phase 3; it isn't in this
branch because this branch is iOS-behavioural and I'd rather it landed on its own where it can be
reviewed as infrastructure. Still outstanding.

**6. Not device-verified.** Everything here came from a device session and none of it has been
back to a device. The airplane-mode F-1 case in particular is simulator-only so far.
