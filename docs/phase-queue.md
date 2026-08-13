# RASCAL — the phase queue

The short list. `docs/roadmap-status.md` is the long one: it explains *why* and carries the
evidence. **This file says what to do next, one line each. Delete a line when it is done.**

If a line needs more than a sentence, the sentence goes in `roadmap-status.md` and the line
stays short. If a line stops being true, delete it — a queue that carries finished work is the
exact failure `roadmap-status.md` has now made six revisions running.

Synced with `roadmap-status.md` at **Aug 12, 2026**. Next phase number is **24** — measured from
`main`, and expected to rot. Measure it again rather than trusting this line.

---

## Questions I need from you

**Nothing is open.** Every question this file has asked has been answered, and the answers are in
`docs/decisions.md`. Add new ones here as they come up.

**Answered Aug 12, 2026** and written into `docs/decisions.md`, which is the authority for all of
these — **the app is called `Dogear`**, tokenise all 113 prompts, letter-on-any-day is
freeform-plus-seal with the age asked only once sealing is chosen, a seal is always editable, the
kind chip takes `periwinkleDeep` in all three places, sage stays below AA as a recorded exception,
multi-kid is in scope and prioritised, per-entry visibility gets designed now, and paper grain
stays rejected (no action).

---

## Now — production is wrong today

- Confirm tomorrow's 5am Detroit scheduler run puts a **photo** in the `mission` slot. All-time it
  is `activity ×2, audio ×1` and has never once held a photo. Check the rows, not the deploy.
- If it does not: recreate machine `185d762c643778` inside the app's machine set, or give
  `api/fly.toml` a `scheduler` process group so `fly deploy` reaches it.
- Do the same for the notify machine `8900ddf6719058` — created Aug 12, outside the process group,
  pinning its own image. Current today, stale after the next deploy. Same flaw, same fix.
- Ship an iOS build. The installed TestFlight build predates `3df6cd4` and renders `mission_b` as
  an unknown grey "Still open" slot regardless of what the server does.

## Blocked on you, not on code

- Read the **79 prompt candidates**. They were generated before `decisions.md` settled the tone as
  warm and cheerful on Aug 11 — read for warmth as well as accuracy. All 79 are `question` kind.
- Run a **restore drill**. The machinery is tested; the act has never been performed. Use the
  pinned Postgres 16 binaries — a 17 client writes a dump 16 will not take back.

## Verification backlog — 409 boxes, and the only instrument that reads what tests cannot

Run in this order. Details and the "why here" for each are in `roadmap-status.md`.

- The App Group check: `device-verification-widget.md` §1 **+** `-share-extension.md` §1. Half an
  hour, answers both at once, and do it before anything else.
- `device-verification-share-extension.md` — 45 boxes. The only one with a number to write down.
- `device-verification-today-v2.md` — 39. Swipe-to-skip has never been swiped.
- `device-verification-settings.md` — 73. Longest; §0 is five minutes.
- The audio list in PR #22 — needs iOS 26+ and a quiet room. Prerequisite for transcription.
- `device-verification-transcription.md` — 45. The one whose answer could invalidate a design.
- `device-verification-backfill.md` — 19. Needs a real camera roll.
- `device-verification-extraction.md` — 19. Needs Apple Intelligence hardware.
- `device-verification-entry-detail.md` — 28. Fix its header (says 22) and add the v2 checks first.
- `device-verification-personalization.md` — 25. Same hardware gate as extraction.
- `device-verification-moments.md` — 44.
- `device-verification-push.md` — §0–§3 mostly ticked Aug 12. Left: force-quit delivery, the
  sandbox row alongside production, and all of §4–§7.
- The sync-pull sequence — not a file: Settings → dry run → read the report → flip
  `syncPullEnabled` → pull to refresh. Never run against the real archive.

## The build queue

Numbered items match `roadmap-status.md`'s forward queue. **Prioritised, in order**, per Aug 12.

- **Rename to `Dogear` — code is done, three things left and all three are yours.** Shipped
  Aug 12: display name on the app, widget and share extension (verified out of the built bundles,
  not just the source), the onboarding wordmark, 13 in-app copy strings, the export viewer's
  titles and the download filename. **Left: the app icon** (a design asset), **the App Store
  Connect / TestFlight listing name**, and **the repo name plus `docs/` prose** — the last is
  cosmetic and deliberately not swept, because it would bury a real diff under a few hundred
  mechanical lines. Ship a build for any of it to reach the phone.
- **24 — Tokenise all 113 seeded prompts.** Owner's call, reversing `decisions.md`. Edit
  `docs/mission-library.md` and regenerate — never `prompts.yaml` by hand. **Three things that are
  scope, not objections:** re-seeding keys on `sha256(kind, cadence, body)` and never deletes, so
  113 rewrites *insert* 113 new prompts and the literal ones must be deactivated in the same pass;
  `test_seeding.py` pins a coverage table to reconcile; and `export_viewer/assets/app.js` must
  learn the token table or every export prints raw `{their}`.
- **31 — Multi-kid.** Now in scope — `ios/CLAUDE.md` updated. Entirely iOS: the child is hardcoded
  to `.first` in three places and `ChildSwitcherPill` already draws its chevron whenever
  `onSelect` is non-nil, which today only a preview supplies. The chevron appears when there is a
  second child, never before.
- **Per-entry visibility — design first, then 30.** Undesigned, not just unbuilt:
  `docs/data-model.md`'s `entries` spec has no visibility column. Must answer per-entry vs
  per-kind, what a `viewer` sees by default, and whether a sealed letter is a visibility state.
- **27 — Letter on any day.** Freeform-plus-seal; sealing is what asks for the unlock age; entry
  point is the *Add to the archive* sheet behind **+**. The API needs no change. iOS end to end.
- **Editing a seal after the fact.** `PATCH /entries/{id}` supports it and
  `EntryChanges.unlockAtAge` already exists at `TimelineAPI.swift:118` and is never set — a dead
  seam to wire, not a type to add. Includes unsealing, which the setness fix made expressible.
- **30 — Guardian invites + viewer role.** No route can create a `viewer` row today, so it is
  enforced code nothing can enter. Needs the visibility design above first.
- **25 — Author photo prompts.** Not urgent until the scheduler fix lands; the photo pool is the
  healthiest in the archive (20 of 20 available), just unreachable. Zero photo candidates among the 79.
- **28 — `GET /children/{id}/stats`.** Nothing exists. Lights up three dropped Settings surfaces at
  once. Model it on `pool-health` (`routers/children.py:303`), same shape, same `child_access`.
- **33 — Photo captioning, device half.** Server half is complete and was being carried as "not
  started". Needs a third protocol: the two existing on-device seams take text, not pixels.
- **32 — Year One book.** Nothing started. All five of its own problems are untouched.
- **34 — Membership billing / costs.** *(Was written as a second 33; renumbered, since this file
  exists partly to stop the phase-number collisions the ledger already carries four of.)*
- **auth — credential linking.** Do this before Google sign-in, or Google mints second,
  disconnected `users` rows.
- **auth — `aud` allowlist.** One line at `services/apple.py:89` once `config.py:70` parses a list.
  Note `resolved_apns_topic` falls back to the same field.
- **auth — Apple revocation, server-to-server.** Client half shipped and works; no route exists, so
  revoking while the app is closed leaves the session alive until the refresh token expires.
- **auth — Google sign-in.** Zero code. Gated on credential linking.

## Deliberately not doing

Delete nothing here without a decision to go with it.

- Cross-share deduplication — sharing the same photo twice makes two entries, on purpose.
- Renumbering the phase collisions (3, 11, 19, 20 each mean two things). The ledger disambiguates.
- Paper grain. Already in `decisions.md` under "Rejected — do not revisit"; confirmed Aug 12, no
  action. The design exports will keep shipping it and the answer stays no.
