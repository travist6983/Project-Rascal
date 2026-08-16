# RASCAL — the phase queue

The short list. `docs/roadmap-status.md` is the long one: it explains *why* and carries the
evidence. **This file says what to do next, one line each. Delete a line when it is done.**

If a line needs more than a sentence, the sentence goes in `roadmap-status.md` and the line
stays short. If a line stops being true, delete it — a queue that carries finished work is the
exact failure `roadmap-status.md` has now made six revisions running.

Synced with `roadmap-status.md` at **Aug 16, 2026**. Everything in scope has shipped: 24, 25, 27,
28, 31, 35, adding a child, the visibility design and Settings' hero strip, with **33 blocked on
the platform**. What is left below is what you excluded (30, 32, 34, the auth bundle), what only
you can do, and follow-ups the work itself turned up. **The highest number used is 43**, so a
genuinely new phase takes **44** — 36–39 are monetization's forward items, 40 settled the
numbering, 41 retired the caption clobber into 33, 42 iceboxed guardian invites, and 43 scoped
the export by date. **This line
disagreed with `roadmap-status.md` for a day** and a preflight gate caught it: the queue still said
36 was free after the roadmap had taken 36–39. The roadmap is the source and this line follows it —
measure it there rather than trusting this one.

---

## Questions I need from you

**Nothing is open.** Every question this file has asked has been answered, and the answers are in
`docs/decisions.md`. Add new ones here as they come up.

**Answered Aug 14–15, 2026.** Per-entry visibility: **per-entry with a per-kind default**, a
`viewer` sees **everything not marked private**, and **a seal is a separate axis** from visibility
— all three in `decisions.md`, with the column specified in `data-model.md`. The four `his mom`
prompts were **rewritten household-neutral** rather than tokenised around. And the hero's stats
strip: the middle cell **counts photographs, not media**; the strip **does not render until the
server answers**, because nil is not zero; and an **empty archive shows nothing** rather than three
zeros. Those last three are recorded in `settings-v2-inventory.md` where D1 and D12 were dropped.

**Answered Aug 12, 2026** and written into `docs/decisions.md`, which is the authority for all of
these — **the app is called `Dogear`**, tokenise all 113 prompts, letter-on-any-day is
freeform-plus-seal with the age asked only once sealing is chosen, a seal is always editable, the
kind chip takes `periwinkleDeep` in all three places, sage stays below AA as a recorded exception,
multi-kid is in scope and prioritised, per-entry visibility gets designed now, and paper grain
stays rejected (no action).

---

## Now — production

**Four of the five things this section carried were closed on Aug 14, 2026.** What is left is the
iOS build, and it is the one nobody here can do.

- **The `mission` slot served a photo** on the morning of Aug 14 — observed on the phone, which is
  the first time it has ever happened. **The scheduler was not the cause and the machine image was
  not the fix**: that run fired at ~09:00 UTC, hours before the images were refreshed, so the
  narrowing was working and the slot was simply never drawing a photo before. Recorded this way on
  purpose, because "we changed something and then it worked" is how a real cause goes unfound. If
  the photo slot goes quiet again, the pool is where to look, not the machine.
- **Both scheduled machines are on the deployed image.** `185d762c643778` and `8900ddf6719058`
  were updated in place with `fly machine update --image` on Aug 14 — their `schedule`, restart
  policy, command and env were all already correct, and only the image was stale. **The recurrence
  is closed in code**: the deploy workflow now moves any machine with a non-empty `schedule` onto
  the image the app is running. That step shipped with a defect of its own — it compared
  `…:deployment-X` against `…:deployment-X@sha256:…`, which are never equal, so it restarted both
  machines on every deploy — fixed Aug 15 by comparing on the tag.
- **The prompt library is seeded in production.** The Aug 14 run reported
  `99 inserted, 0 updated, 14 unchanged, 99 retired (113 in the library)` — the tokenised bodies
  are live and the 99 literal ones are deactivated. **The recurrence is closed in code**: the seed
  is on `fly.toml`'s `release_command`, so every deploy reconciles the library with the file.
- **Ship an iOS build — still open, and still yours.** `ios.yml` is a *test* workflow: it builds
  for the simulator and runs the suite, and has no archive, signing or upload step anywhere. The
  only signing identity on the build machine is `Apple Development`, so a TestFlight build needs a
  Distribution certificate and an App Store Connect key that live with the owner. Until one ships,
  the installed build predates `3df6cd4` and renders `mission_b` as an unknown grey "Still open"
  slot regardless of what the server does.

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
- **Check Tinybeans Group's ASX announcements quarterly (ticker TNY).** It is the only competitor whose product roadmap is legally required to be public, and the Qeepsake acquisition release announced an AI-prompt, voice-and-video, transcription-searchable journaling roadmap — which is this product's feature set. Whether that ships is the single most decision-relevant external fact available, and it arrives on a schedule rather than needing to be dug for.
- **Re-measure `mission`'s pool health.** Phase 25 took the untagged photo pool from 20 to 40, so
  the relaxation date in `mission-library.md` is stale by arithmetic. One call to
  `GET /children/{id}/pool-health` replaces a projection this file must not invent.
- **33 — Photo captioning, device half. Blocked on the platform — see `docs/blocked.md` §9.** The
  server half is complete and the device half cannot be written: the on-device model's whole input
  vocabulary is `Transcript.Segment`, which is text or structure, so there is no pixels-to-prose
  call to make. **The stated reason here was half wrong** — `SpeechTranscribing` takes a file URL
  and *returns* text, so the two seams never shared an input to widen. It is a third protocol
  because they diverge, which is the stronger argument. **Do not land the seam ahead of the API**:
  its state ladder is a SwiftData migration on every media row for a feature that may never ship,
  and a Settings row that permanently reads "0 waiting" is the furniture this app refuses.
  **It also inherits the caption clobber** — a queue line of its own until Aug 16, now on 33's row
  and in §9, where the three call sites and the reason it cannot be fixed early are written out.
- **32 — Year One book.** Year scoping closed with 43 on Aug 16; `GET /export` takes `from` and
  `to`. **The other four problems are one problem** — print layout, PDF generation, QR
  substitution and the playback surface all need a web client this API has never had. That is
  the gate, and scoping did not move it.
- **34 — Membership billing / costs. Fully decided; it is D1–D6 and phases 36–39 now.** ~~Two
  questions still open.~~ **Both were answered the same day this line was written, and the line
  never caught up** — corrected by 42 on Aug 16. (1) *Export during the cold year without paying*
  is **yes**: D2 says the export is "always free and complete", and D3a puts a one-click free
  export link inside every deletion warning. (2) *What the free tier caps* is **media**, exactly
  the shape the open question recommended: D2 caps photos at 100 lifetime and leaves every prompt,
  all text and all `did_it` entries uncapped. Its "then deletion" summary is also superseded — D3
  deletes **media only, never text**, on two computed clocks. **Nothing here blocks anything.** The
  real gate is `blocked.md` §10 and it is an account action: Small Business Program enrollment and
  the subscription products in App Store Connect, both yours. §10 also records that **38 needs no
  Apple account at all.**
- **auth — credential linking.** Do this before Google sign-in, or Google mints second,
  disconnected `users` rows.
- **auth — `aud` allowlist.** One line at `services/apple.py:89` once `config.py:70` parses a list.
  Note `resolved_apns_topic` falls back to the same field.
- **auth — Apple revocation, server-to-server.** Client half shipped and works; no route exists, so
  revoking while the app is closed leaves the session alive until the refresh token expires.
- **auth — Google sign-in.** Zero code. Gated on credential linking.

## Iceboxed

**Not rejected and not scheduled.** The section below is for things the owner has decided against
doing *for now*, which is a different answer from the one "Deliberately not doing" records — those
are settled no's. Anything here can come back without relitigating it, and the note says what it
would cost to restart.

- **30 — Guardian invites and the `viewer` role, and per-entry visibility with it.** Owner's call,
  Aug 16, 2026: *not for a while.* **Nothing has to be unwound**, which is why this is cheap to
  park — `visibility` is specified in `data-model.md` and was never migrated, so there is no column
  on `entries`, no filter in `deps.py` and no dead code anywhere. The design is not lost either:
  the three answers are settled in `decisions.md` and the column is specified down to its default,
  so restarting is a build against a finished spec rather than a fresh design. **The `viewer` role
  in the schema stays** — it has been in `guardians.role` since `0001` and is enforced by
  `child_access`; what does not exist is any route that can create one, which is exactly the state
  this has always been in. Nothing regresses by leaving it there.
- **Per-entry visibility — the build, not the design.** Iced with 30 above, because it has no other
  consumer. `decisions.md` is unchanged and stays authoritative for when it returns: per-entry with
  a per-kind default, a viewer sees everything not marked private, a seal is a separate axis.
  **The reason it was designed before being scheduled still holds** — a visibility model retrofitted
  onto an archive that already has guardians is a migration over user content, so having it settled
  in advance is worth more now than it was when nothing was iceboxed.

**36 is deliberately still in the build queue**, and the distinction is worth stating because the
two phases overlap. 30 was *grandparents as read-only viewers*. 36 is a **second parent** becoming
a full guardian, which is what D4's "one price for the whole household" is sold on — a different
need with a different consumer. If that should ice too, say so and it moves here in a line.

## Deliberately not doing

Delete nothing here without a decision to go with it.

- Cross-share deduplication — sharing the same photo twice makes two entries, on purpose.
- Renumbering the phase collisions (3, 11, 19, 20 each mean two things). The ledger disambiguates.
- Paper grain. Already in `decisions.md` under "Rejected — do not revisit"; confirmed Aug 12, no
  action. The design exports will keep shipping it and the answer stays no.
