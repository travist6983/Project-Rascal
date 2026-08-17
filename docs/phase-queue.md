# RASCAL — the phase queue

The short list. `docs/roadmap-status.md` is the long one: it explains *why* and carries the
evidence. **This file says what to do next, one line each. Delete a line when it is done.**

If a line needs more than a sentence, the sentence goes in `roadmap-status.md` and the line
stays short. If a line stops being true, delete it — a queue that carries finished work is the
exact failure `roadmap-status.md` has now made six revisions running.

Synced with `roadmap-status.md` at **Aug 16, 2026 (third pass)**. **The highest number used is
60**, so a genuinely new phase takes **61** — the auth bundle took 51–58, the
universal-link surface took 59, and **60 was allocated Aug 16, 2026 to the marketing signup
endpoint and the Resend swap** (specified, not built). 51–59 merged on Aug 16, 2026
(PRs #99, #100, #101) and are live in production.

> **This header has now been wrong twice in two days, and the second time was worse.** It said
> *"the highest number used is 46, so a genuinely new phase takes 47"* while line 121 of this
> same file, added by the **same commit**, said the icon shipped as phase 47 — a file made to
> contradict itself six lines apart. Meanwhile **48, 49 and 50 had merged** and neither this
> file nor `roadmap-status.md` recorded any of them. A preflight gate caught it before anything
> was numbered; had it not, the auth bundle would have been numbered 47 and collided with three
> merged phases. **Neither file was right. `main` was.** Both are corrected, and the rule that
> works is the one `roadmap-status.md:231` already stated: *measure `main` rather than quoting a
> status document's count.*

Everything else in scope has shipped: 24, 25, 27, 28, 31, 35, adding a child, the visibility
design and Settings' hero strip, with **33 blocked on the platform**. 36–39 are monetization's
forward items, 40 settled the numbering, 41 retired the caption clobber into 33, 42 iceboxed
guardian invites, 43 scoped the export by date, 44 reconciled the verification backlog, 45 gave
multi-kid device coverage, 46 shipped the caption probe, 47 the app icon, 48 cleared the iOS
concurrency warnings, 49 the activity clock and consent lanes, 50 pool-health's observed rate,
and **51–57 the auth bundle's API half**.

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

## Verification backlog — 460 boxes, and the only instrument that reads what tests cannot

Run in this order. Details and the "why here" for each are in `roadmap-status.md`.

- The App Group check: `device-verification-widget.md` §1 **+** `-share-extension.md` §1. Half an
  hour, answers both at once, and do it before anything else.
- `device-verification-widget.md` — 48. **The whole file, which this list only ever pointed at.**
  §8a is new: the snapshot it writes is what the Lock Screen renders, so a wrong-child one is
  wrong where nobody opens the app to look.
- `device-verification-share-extension.md` — 45 boxes. The only one with a number to write down.
- `device-verification-today-v2.md` — 44. Swipe-to-skip has never been swiped. **§8 is new** —
  two children on one board.
- `device-verification-settings.md` — 87. Longest; §0 is five minutes. **§8a and §8b are new** —
  the stats strip and adding a child both shipped after this list was written.
- The audio list in PR #22 — needs iOS 26+ and a quiet room. Prerequisite for transcription.
- `device-verification-transcription.md` — 45. The one whose answer could invalidate a design.
- `device-verification-backfill.md` — 23. Needs a real camera roll, and **two children** — §3a is
  the silent one: a sibling's month used to count as covered, so this child was never offered it.
- `device-verification-extraction.md` — 22. Needs Apple Intelligence hardware. **§4a is new.**
- `device-verification-entry-detail.md` — 36. **Header fixed and the v2 checks added by 44** — two
  boxes asked about a navigation bar v2 removed, and §7 is new. Runnable as written now.
- `device-verification-captions.md` — 9. **Needs a real camera roll, and its answer decides
  phase 33.** Measures how many photos already carry a written description; near-zero closes 33.
- `device-verification-personalization.md` — 25. Same hardware gate as extraction.
- `device-verification-moments.md` — 44.
- `device-verification-push.md` — 32. §0–§3 mostly ticked Aug 12. Left: force-quit delivery, the
  sandbox row alongside production, all of §4–§7, and **§6a — the re-offer with a second child**,
  which is spent once and never comes back.
- The sync-pull sequence — not a file: Settings → dry run → read the report → flip
  `syncPullEnabled` → pull to refresh. Never run against the real archive.

## The build queue

Numbered items match `roadmap-status.md`'s forward queue. **Prioritised, in order**, per Aug 12.

- **Rename to `Dogear` — code is done, ~~three things left~~ two, and both are yours.** Shipped
  Aug 12: display name on the app, widget and share extension (verified out of the built bundles,
  not just the source), the onboarding wordmark, 13 in-app copy strings, the export viewer's
  titles and the download filename. ~~**Left: the app icon** (a design asset)~~ — **the icon
  shipped Aug 16 as phase 47**, and it was never really a rename item: the mark carries no word,
  so it was decidable before the name and would not have changed after it. **Left: the App Store
  Connect / TestFlight listing name**, and **the repo name plus `docs/` prose** — the last is
  cosmetic and deliberately not swept, because it would bury a real diff under a few hundred
  mechanical lines. Ship a build for any of it to reach the phone.
- **Check Tinybeans Group's ASX announcements quarterly (ticker TNY).** It is the only competitor whose product roadmap is legally required to be public, and the Qeepsake acquisition release announced an AI-prompt, voice-and-video, transcription-searchable journaling roadmap — which is this product's feature set. Whether that ships is the single most decision-relevant external fact available, and it arrives on a schedule rather than needing to be dug for.
- **Re-measure `mission`'s pool health.** Phase 25 took the untagged photo pool from 20 to 40, so
  the relaxation date in `mission-library.md` is stale by arithmetic. One call to
  `GET /children/{id}/pool-health` replaces a projection this file must not invent.
- **33 — Photo captioning. Blocked on the platform, and now waiting on a measurement rather than
  on Apple — see `docs/blocked.md` §9.** Re-verified Aug 16: the block is unchanged. **Phase 46
  shipped the measurement instead of the feature** — `MAImageCaptioning` reads a description a
  human already wrote into a photo's metadata, and nobody has counted how many real photos have
  one. Run `device-verification-captions.md` on a phone with a real camera roll; **near-zero
  deletes the probe and closes this phase**, and anything better gets it a real one. The server
  half is complete and the *generating* half cannot be written: the on-device model's whole input
  vocabulary is `Transcript.Segment`, which is text or structure, so there is no pixels-to-prose
  call to make. **The stated reason here was half wrong** — `SpeechTranscribing` takes a file URL
  and *returns* text, so the two seams never shared an input to widen. It is a third protocol
  because they diverge, which is the stronger argument. **Do not land the seam ahead of the API**:
  its state ladder is a SwiftData migration on every media row for a feature that may never ship,
  and a Settings row that permanently reads "0 waiting" is the furniture this app refuses.
  **It also inherits the caption clobber** — a queue line of its own until Aug 16, now on 33's row
  and in §9, where the three call sites and the reason it cannot be fixed early are written out.
  **46 deliberately did not guard it**: `applyServerSummary` and `differs(_:from:)` agree today, so
  there is no live defect, and a guard would guard a writer that does not exist. The deferral now
  points at the measurement rather than at a phase that may never land.
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
- ~~**auth — the whole bundle.**~~ **Shipped and merged Aug 16, 2026: 51, 52, 53, 54, 55, 56,
  57, 58, 59.** Both lanes, deployed, and verified against production rather than against the
  deploy's green tick — routes answer, migrations are at `0013`, the association file serves
  with the right `appID`, `GOOGLE_CLIENT_IDS` took, and dev-login still 404s.
- **Run `blocked.md` §11 — Apple's `sub` across a revoke. Still the sharpest thing on this
  list.** Phase 53 is live and its central assumption has never once been observed: that
  Apple's `sub` survives a revoke-and-reauthorize cycle. **All nineteen of its tests pass
  whether or not it holds**, so nothing in CI can tell you. If it changes, the recoverability
  design is wrong rather than buggy — and that is worth knowing before anything tells a parent
  that removing the app is reversible.
- **Nothing in the auth bundle has run on a phone**, and it cannot until there is a TestFlight
  build: `ios.yml` has no archive, signing or upload step, and the only identity on the build
  machine is `Apple Development`. Google sign-in has never been attempted against real Google,
  no magic link has ever been tapped, and no Dynamic Type XXL screenshots exist for either
  screen. **Merged and invisible** is the honest description.
- **No real email has ever been sent.** `MAIL_PROVIDER` is `console` everywhere; Postmark has
  never been called, so the magic link is proven as logic and unproven as mail.
- **60 — `POST /v1/subscribe`, and Resend replaces Postmark on both lanes.** API lane. Server-side
  Turnstile verification that **fails closed**, CORS allowlisted to the marketing origin, a Resend
  client, and the `stream` argument (`marketing | transactional`) added to the existing
  `services/mail.py` port — **not a second port beside it.** Retires `PostmarkProvider` and
  repoints `auth.py` and `me.py`; cheap only because `MAIL_PROVIDER` has never left `console`, so
  there is no delivery history or warmed domain to carry. **No template beyond the minimum double
  opt-in needs, no `subscribers` table, and no scheduled send.** Per D7, D8, D8a and open item 12.
  **Timing: the endpoint may ship before the P0 behavioural gate; no marketing email sends before
  it.** Stated that way deliberately — *"nothing sends"* is already false, because phase 57's
  magic-link path sends and is not gated on P0.
- **The marketing site itself — `Rascal-Marketing`, a different repository, so it takes no phase
  number here.** GitHub Pages custom domain with **Enforce HTTPS**, CSP via `<meta http-equiv>`
  (the header set is fixed on this host — an accepted exception, D7), the signup form, and the
  Turnstile widget. **`prompts.yaml` and `mission-library.md` never enter that repo**, whole or
  sliced. Owner actions it waits on are `blocked.md` §13. **Timing: the page and its form may ship
  before the P0 gate; no marketing email sends before it.**
- **60's port is a prerequisite for 38 (lifecycle notices), whose email channel cannot be built
  without it.** Recorded as a dependency rather than a phase. **The webhook that writes the
  `email` outcome into `lifecycle_notice_deliveries` belongs to 38 and gets no number of its own**
  — `data-model.md` names the dependency and 38 inherits it. Note the trap recorded there:
  `delivered` must mean the provider confirmed delivery, never that the send call returned without
  raising, because D3 lets a deletion proceed once one channel reads `delivered`. **Timing: 38 is
  itself downstream of the P0 gate, and its notices are transactional rather than marketing — the
  constraint that binds it is D3's, not this one's.**

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
