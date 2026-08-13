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

These gate work below. Nothing on them is a coding problem; each is a call only you can make.

- **Tokenize the 113 seeded prompts, or leave them?** `decisions.md:56` settled "not rewritten" on
  Aug 11. The counter-argument is that what they render today is `he/him` to a she/her child, on
  every screen, permanently. Blocks item 24 either way. Three hidden costs are in
  `roadmap-status.md` — the yaml is generated, re-seeding *inserts* rather than updates, and the
  export viewer would print raw `{their}`.

  **Answer** Lets redo these for sure for a female we cant have it male oriented costs is fine. 

- **A narrower option for the above:** tokenize only the ~30 bodies that reach Today's three daily
  slots and leave the rest. Nobody has costed it. Want it costed?

  **Answer** No do them all 

- **Letter on any day (item 27): freeform-plus-seal, or written against a `letter` prompt?** And
  does the entry point live in the *Add to the archive* sheet behind **+**? Both are design calls;
  the API already accepts it.

**Answer** I think you can do written with the option to seal it and if you do we find the age to unlock it then

- **Editing a seal after the fact:** allow it, or is the age it was written with final? Today a
  letter sealed at 13 by a mis-tap cannot be moved, and nothing on screen says the number is final.

**Answer** Always edit after something is added it could need to change years down the road for reasons. always be flexible with out users content 

- **`KindBadge` contrast** measures ~3.3–3.7:1, below WCAG AA. Fix with a new `periwinkleDeep`
  token, or restyle the badge? Design-system decision, not a patch.

**Answer** fix with periwinkleDeep 

- **Paper grain.** The design export calls it mandatory identity; `design-system.md` lists
  screen-print texture as an anti-pattern; neither decisions file mentions it. It has been deferred
  three phases running. Pick one and I will write it down.

**Answer** it is fine lets not worry about this 

- **Multi-kid:** `ios/CLAUDE.md` scopes it out, and the server has supported it since migration
  `0001`. Change the scope rule, or keep it out? Item 31 cannot be scheduled until this is answered.

**Answer** We def want to do this and it needs to be a prioritized phase 

- **Per-entry visibility (P2)** is undesigned, not merely unbuilt — `docs/data-model.md`'s `entries`
  spec has no visibility column. Do you want it designed now, or is P2 deferred wholesale?

**Answer** lets get this knocked out so it doesnt lingear 

- **The app's name.** Still `RASCAL`. Not blocking code, but the widget gallery groups by app name,
  so it is now visible to anyone adding the widget.

  **Answer** still working on it :/ I know but this is so hard to pick 

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

Numbered items match `roadmap-status.md`'s forward queue.

- **25 — Author photo prompts.** Not urgent until the scheduler fix lands; the photo pool is the
  healthiest in the archive (20 of 20 available), just unreachable. Zero photo candidates among the 79.
- **28 — `GET /children/{id}/stats`.** Nothing exists. Lights up three dropped Settings surfaces at
  once. Model it on `pool-health` (`routers/children.py:303`), same shape, same `child_access`.
- **33 — Photo captioning, device half.** Server half is complete and was being carried as "not
  started". Needs a third protocol: the two existing on-device seams take text, not pixels.
- **30 — Guardian invites + viewer role.** No route can create a `viewer` row today, so it is
  enforced code nothing can enter. Blocked on the visibility question above.
- **31 — Multi-kid.** Entirely iOS: the child is hardcoded to `.first` in three places and the
  shipped switcher pill is a label (`onSwitchChild` is supplied only in previews). Blocked on the
  scope question above.
- **32 — Year One book.** Nothing started. All five of its own problems are untouched.
- **33 — Membership Billing / Costs**
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
- Bulk-rewriting the seeded library — unless the first question above changes it.
