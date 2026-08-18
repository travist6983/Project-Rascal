# RASCAL — the phase queue

The short list. `docs/roadmap-status.md` is the long one: it explains *why* and carries the
evidence. **This file says what to do next, one line each. Delete a line when it is done.**

If a line needs more than a sentence, the sentence goes in `roadmap-status.md` and the line
stays short. If a line stops being true, delete it — a queue that carries finished work is the
exact failure `roadmap-status.md` has now made six revisions running.

Synced with `roadmap-status.md` at **Aug 18, 2026 (the docs audit)**. **The highest number used is
78**, so a genuinely new phase takes **79** — and **79 through 83 are already allocated**, and **each now has a row in
`roadmap-status.md`** — which is the authority `CLAUDE.md` sends you to, and which carried the
allocation nowhere for the first few hours it existed. **That gap was a fifth instance of this
header's own failure waiting to happen**: a session obeying `CLAUDE.md` literally would read the
ledger, see it stop at 78, and take 79 — colliding with work that is written and green. **An
allocation recorded only in the queue is not recorded.** They go to a
paired session building the four-prompt recording/sync/display-name pack: 79 and 80 and 81 iOS,
**82 iOS and 83 API, split because that item crosses lanes and CI is path-scoped.**

~~*"The highest number used is 75, so a genuinely new phase takes 76"*~~ — **struck Aug 18, 2026,
and this is the fourth instance, not the third.** 76 and 77 merged (`3b6f832`, `0ad7f30`) and
**78 is open as PR #129**, so a reader trusting that line would have collided with *two merged
phases and one open pull request*. Before it: ~~*"the highest number used is 73, so a genuinely new
phase takes 74"*~~, which was true when written and stopped being true the same evening, and
~~*"61 through 67 all went on Aug 17, so the next is 68"*~~ before that, and *"…is 46, so a
genuinely new phase takes 47"* at line 31 below.

**The count inside this header was itself stale, which is the finding worth carrying.** The block
below still opens *"Third time this header has been wrong"* — it was written when three had
happened, and by not being re-counted it committed the very drift it exists to record. **A tally of
your own failures is a figure like any other and rots like any other.**

**The rule needed strengthening, not just the integer — the integer will rot again by morning.**
This file's stated remedy was *"measure `main`, not this file"*, and **`main` alone would not have
saved anyone this time**: 78 is real, is taken, and is not on `main`. The measurement that works is
all three at once, and it is what allocated 79–83:

```
git log --all --pretty=format:'%s%n%b' | grep -oiE 'phase [0-9]+'   # commits, every ref
git for-each-ref refs/heads refs/remotes | grep -oiE 'phase-[0-9]+'  # branch names
gh pr list --state all --limit 200 --jq '.[].title'                  # open PRs included
```

**A number is taken the moment a branch or a PR carries it, not when it merges.**
68 unblocked the sprint, 69 built the daily broadcast, 70 went to the icon and wordmark work,
71 and 73 are the two halves of the Vellum rename, and 72 was the false-claims sweep. 67 closed
the App Store deletion blocker that 65 found; the universal-link surface took 59; **60 was the
marketing signup endpoint and the Resend swap**. 51–59 merged on Aug 16, 2026 (PRs #99, #100,
#101) and are live in production.

> **Third time this header has been wrong, and this one is the mildest of the three** — it was
> stale rather than self-contradicting, and it was stale by six numbers in a single evening
> because seven phases ran in one night. Recorded rather than quietly corrected, because that
> is what the two entries below it are for. **The rule that works has not changed and worked
> again here: measure `main`, not a status document's count.** Phase 71 read this line, found
> it said 68, checked `main`, and found 68 already merged as `364154c`.

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
these — **the app is called ~~`Dogear`~~ `Vellum`** (superseded Aug 17, 2026 by the owner; `decisions.md:115` is the settled row and this line was left saying the dead name for a day after the rename shipped in both lanes), tokenise all ~~113~~ **133** prompts — phase 25 added twenty photo bodies on Aug 14 and `mission-library.md` has said 133 since — letter-on-any-day is
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

## Verification backlog — 467 boxes, 93 ticked, **374 open**, and the only instrument that reads what tests cannot

**Recounted Aug 18, 2026, and the headline moved for the first time.** ~~*460 boxes*~~ was right when
written; it is 467 now because phase 79 added seven to the transcription list. **93 are ticked** —
and 84 of those were ticked on Aug 18 by the owner, on a device, in commit `d99204d` (*"notes
update"*). **That work was invisible to every status document in this repo until this recount**,
which is the same failure this file records about phase numbers, arriving from the other
direction: not work claimed and not done, but **work done and not claimed.**

Count them with `grep -cE '^\s*-? *\[[ xX]\]'` for the total and `\[[xX]\]` for the ticked. **A
`grep '\[ \]'` counts only the unticked ones and will tell you the backlog is shrinking when it is
not** — that mistake was made once during this very recount.

Run in this order. Details and the "why here" for each are in `roadmap-status.md`.

- The App Group check: `device-verification-widget.md` §1 **+** `-share-extension.md` §1. Half an
  hour, answers both at once, and do it before anything else.
- `device-verification-widget.md` — 48. **The whole file, which this list only ever pointed at.**
  §8a is new: the snapshot it writes is what the Lock Screen renders, so a wrong-child one is
  wrong where nobody opens the app to look.
- `device-verification-share-extension.md` — 45 boxes. The only one with a number to write down.
- `device-verification-today-v2.md` — 44. Swipe-to-skip has never been swiped. **§8 is new** —
  two children on one board.
- ~~`device-verification-settings.md` — 87. Longest; §0 is five minutes.~~ — **84 of 87 ticked on
  Aug 18, 2026 by the owner. Three boxes left, and they are specific rather than "finish the
  file":** `:78` interrupt an export by enabling Airplane Mode mid-download, `:99` confirm
  **Archive → Birthday** shows the same day as the row behind it, and `:213` §8a.3 cold launch
  with Airplane Mode on — the stats strip **must not render at all**, because nil is not zero.
  **This was the longest file in the backlog and is now the shortest thing left on it.**
- The audio list in PR #22 — needs iOS 26+ and a quiet room. Prerequisite for transcription.
- `device-verification-transcription.md` — ~~45~~ **52**. The one whose answer could invalidate a
  design. **§4a is new (phase 79)** — seven boxes on the screen going dark mid-recording. Two of
  them expect opposite outcomes on purpose: the screen stays lit while **capturing** and locks
  normally during **review playback**, because the wake lock is scoped to capture. The box that
  matters most is the staged `.m4a` still existing after a return to the foreground — that one
  was genuinely failing.
- `device-verification-backfill.md` — 23. Needs a real camera roll, and **two children** — §3a is
  the silent one: a sibling's month used to count as covered, so this child was never offered it.
- `device-verification-extraction.md` — 22. Needs Apple Intelligence hardware. **§4a is new.**
- `device-verification-entry-detail.md` — 36. **Header fixed and the v2 checks added by 44** — two
  boxes asked about a navigation bar v2 removed, and §7 is new. Runnable as written now.
- `device-verification-captions.md` — 9. **Needs a real camera roll, and its answer decides
  phase 33.** Measures how many photos already carry a written description; near-zero closes 33.
- `device-verification-personalization.md` — 25. Same hardware gate as extraction.
- `device-verification-moments.md` — 44.
- `device-verification-push.md` — 32, of which **9 are ticked** (§0–§3, Aug 12). Left: force-quit delivery, the
  sandbox row alongside production, all of §4–§7, and **§6a — the re-offer with a second child**,
  which is spent once and never comes back.
- The sync-pull sequence — not a file: Settings → dry run → read the report → flip
  `syncPullEnabled` → pull to refresh. Never run against the real archive.

## The build queue

Numbered items match `roadmap-status.md`'s forward queue. **Prioritised, in order**, per Aug 12.

- **Rename to ~~`Dogear`~~ `Vellum` — code is done, ~~three things left~~ two, and both are yours.**
  **Three errors were live in this bullet until Aug 18, 2026, and they compounded.** *(i)* It was
  headed **`Dogear`**, a name superseded on Aug 17 (`decisions.md:115`) and renamed out of both
  lanes as phases 71 and 73. *(ii)* It said the display name shipped on *"the app, widget and share
  extension"* — **that is three, and there are four**, because the app carries both `Info.plist` and
  `Info-Debug.plist`; `roadmap-status.md`'s phase 73 row has this right, and the same off-by-one is
  in a source comment at `RascalShare-Info.plist:22`. *(iii)* Its *"verified out of the built
  bundles, not just the source"* was performed **Aug 12, against a name that has changed twice
  since**, so the strongest-sounding clause in the bullet was the most stale — **a verification is
  only as current as the thing it was run against, and this one outlived two renames.** All four
  bundles read `Vellum` in source today, and `project.pbxproj` sets no
  `INFOPLIST_KEY_CFBundleDisplayName` override, so **a device still showing the old name is a stale
  install rather than a source defect** — a distinction that cost another session a retracted
  finding on Aug 18. Shipped Aug 12 and re-verified in source Aug 18: the display name on all four
  bundles, the onboarding wordmark, 13 in-app copy strings, the export viewer's
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
- ~~**60 — `POST /v1/subscribe`, and Resend replaces Postmark on both lanes.**~~ — **shipped Aug 17, 2026; line deleted per this file's own rule that a queue line goes when it is done.** The specification it carried is preserved in `roadmap-status.md`'s phase 60 row, which is where the long form belongs. **Everything it specified landed as specified**, including the two things most likely to have drifted: the `stream` argument went onto the existing `services/mail.py` port rather than beside it, and **no `subscribers` table was created** — the list is provider-held per open item 12(4).
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

~~**36 is deliberately still in the build queue**~~ — **36 shipped Aug 17, 2026 and is out of
the queue entirely.** The server half is phase 36 itself and the client half is phases 61 and 63;
the sprint's stories 3a and 3b both re-reported it as `ALREADY LANDED` at their own idempotency
gates.

**The distinction that had it iced is the thing that turned out to be confusing, and it is worth
keeping in the owner's own framing:** he had been reading *guardian* as **grandparents** — which
is phase 30, still iced — when what he actually wanted was a **second parent**. The two were
separated on Aug 15 for exactly that reason, and the separation is what let one ship while the
other stayed parked. 30 is unchanged and nothing tonight un-ices it or needs unwinding.

**What un-icing 36 restored: D4's consumer.** *"One price for the whole household"* now has the
thing it is sold on, which it did not while this was parked — and the free tier deliberately does
**not** include a second guardian, so the invite surface is the upgrade surface.

## Deliberately not doing

Delete nothing here without a decision to go with it.

- Cross-share deduplication — sharing the same photo twice makes two entries, on purpose.
- Renumbering the phase collisions (3, 11, 19, 20 each mean two things). The ledger disambiguates.
- Paper grain. Already in `decisions.md` under "Rejected — do not revisit"; confirmed Aug 12, no
  action. The design exports will keep shipping it and the answer stays no.

---

## Follow-ups the Aug 17 sprint generated

One line each, per this file's rule. The reasoning is in `roadmap-status.md` and the story
reports; these are only the things somebody has to *do*.

- **Owner: set the Turnstile site key** in `Rascal-Marketing`'s `src/assets/site.js`. Public key,
  belongs in markup. Until then the signup form declines to post and says so.
- **Owner: the §13 errand.** `docs/blocked.md` now carries a table of every value it produces and
  the exact file or `fly secrets set` command each one lands in. **Turnstile is the only step with
  no prerequisite** and is what makes the signup form stop saying "signups are not open yet".
- ~~Owner: rename the product in `docs/marketing/email-sequence.md`~~ — **done in phase 76**, by
  the owner's explicit say-so, as a name swap and nothing else. The generator was re-run and the
  YAML follows.
- **Owner: write down the trademark check you say you ran** — where you looked and what you
  found, one line. Open item 15. You answered *"already checked — it's fine"* on Aug 18; the repo
  holds the assurance but not the evidence, and only the second kind is auditable later.
- **Re-capture the marketing site's onboarding screenshot** — ~~once phase 73 merges~~ **73 merged Aug 18, 2026, so this is unblocked and waiting on a build.** The old wordmark is baked into its pixels and cannot be fixed from the marketing repo. **It needs a fresh capture from a build carrying the phase 77 wordmark**, which means it is gated on the same iOS build everything else here is gated on.
- **Exercise `POST /v1/subscribe` end to end once**, from the real GitHub Pages origin, to confirm
  CORS and a real Turnstile verification. Never yet done against the deployed API.
- **Run the daily broadcast once with `--date` against an audience of one** before it ever runs for
  the list. The Resend Broadcasts API has never been called.
- **A Fly scheduled machine for `python -m rascal.jobs.broadcast`**, once the above is verified. **The invocation is now written down** — `runbook-deploy.md` §4d, added Aug 18, 2026, along with why this is the one machine that must not be armed before the P0 gate. **And a second machine is missing that nothing here was tracking: `python -m rascal.jobs.delete`** (§4c). That one has no gate and no reason to wait — **without it a parent who asks to be forgotten is never forgotten**, the API stays green throughout, and it is an App Store commitment rather than a feature.
- **§0 device verification is still 0 of 45.** Unchanged by this sprint and still wants running.
