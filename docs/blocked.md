# RASCAL — blocked

Things I cannot finish because they need a credential or an account only you have — **and, as of
Aug 14, 2026, one that needs a platform.** §9 is the first entry here blocked by a missing API
rather than a missing secret, and it is filed here anyway because the effect is identical: the
work cannot proceed and no amount of engineering changes that. Nothing
here blocks the backend from running: `cp .env.example .env && make up && make migrate &&
make seed && make test` works today, and the acceptance test drives the whole daily loop end
to end.

Last reviewed: ~~**Aug 22, 2026.**~~ **Aug 25, 2026.** The Aug 11 pass is described below and its
findings stand; what Aug 16 changed is recorded in the paragraphs immediately after it.

**Aug 25, 2026 — phase 126's allocation added §23, and it is filed as a correction rather than as an errand.** The brief that prompted it said `getvellumapp.com` *"currently has no mail routing"*; the domain is on iCloud Custom Email Domain with both Apple exchangers, an SPF record, the `apple-domain=` verification TXT and a DMARC policy, all read off public DNS the same day and reproduced in the section. **What survives as genuinely yours is narrower and was not the thing named**: an MX record routes a domain and does not create an address, so whether `hello@` exists and whether a message to it arrives are the open questions, and both need an inbox this lane cannot reach. **Count the sections by running it rather than quoting this line**: `grep -c '^## §' docs/blocked.md` answers **13** as this is written. **Answers 15 as of Aug 28, 2026 by phase 129, which added §25** — a delta this line notes rather than reconciles, per its own rule two sentences later that a count corrected by somebody who did not re-derive the whole thing is the failure this file keeps recording. That is a different basis from the *thirteen* the phase 122 note below reports, which counted before §23 existed and over a wider set of headings; it is left alone rather than reconciled here, because a count corrected by somebody who did not re-derive it is the failure this file keeps recording.

**Aug 25, 2026 — phase 122, a docs sweep, and it touched three things here.** **New: §22**, the
three `GEMINI_*` Fly secrets that phase 120 orphaned on Aug 25 — the only genuinely owner-only act
that phase produced, and it was written into a phase report rather than onto this page, which is
the same failure §20 was filed for three days earlier. **§17 gains a note under its heading**: its
subject — `services/social/gemini.py`, `stitch.py` and the three settings — was deleted out from
under it, so a section that reads as a closed billing errand is now explicit that there is no
billing left to check, and its surviving *"Omni Flash stays reachable by setting
`GEMINI_VIDEO_MODEL`"* is struck because that setting no longer exists. **And the unstruck-section
count went ~~eleven~~ → thirteen**, twelve of which were already there when this pass opened the
file: the Aug 22 recount was stale within three days, for the exact reason its own note gives.

**Aug 22, 2026 — this pass closed a section whose stated blocker was environment-specific rather
than universal, and struck one that had been resolved for four days.** §10a item 1 said Apple Root
CA - G3 could not be fetched because `www.apple.com` is refused at an egress proxy. That was true
of the environment phase 37a was built in, and the section wrote it as though it were true
everywhere. One `curl` from this machine returned the 583 bytes; the anchor is committed at
`api/src/rascal/certs/appstore/AppleRootCA-G3.cer` and the loader returns it. **§14 was struck
outright**: phase 86 answered its question on Aug 18 (commit `a1b25b8`, PR #137) and its central
factual claim — that `plan_upload` does not recompute `entry_type` — has been false against `main`
ever since. **The lesson is the one this file keeps re-learning from a new direction: a blocker
states a reason, and the reason has a scope.** *"Refused by an egress policy"* and *"refused by
**this** egress policy"* are different sentences, and only one of them is still true when the file
is read on a different machine. A blocker inherits the environment it was written in; say which
one.

**Everything else this pass changed, in one place.** §13's *no marketing email before the P0
behavioural gate* is struck — the broadcast has been armed since Aug 19 and has sent on four
consecutive days (owner's call, Aug 22, 2026). §10 step 5's 14-day introductory offer is corrected
to **no introductory offer**, because the server already grants the free fortnight and Apple would
stack a second one. §9 was re-verified against the same and only installed SDK and has not moved;
the owner will run the measurement this week. §11's runbook is rewritten so a wrong answer is
repairable and so its step 4 stops misreporting a correct system as a failure. §16 gains the
upload-only App Store Connect key it never mentioned. §18 is downgraded — the Instagram credential
is not in this service at all. And the four resolved iOS sections that had sat at the top of a file
titled "blocked" since Aug 11 are finally **moved**, which is the habit this file wrote down for
itself in the Aug 11 second pass and then did not follow for eleven days.

**And a second sweep of this pass, after the first was audited, added one section and corrected
four counts.** **New: §20**, the deletion job that has no Fly machine — the only entry on this page
where a promise is actively being broken rather than deferred, and it is blocked on nobody. The
counts: the unstruck-section number went ~~nine~~ → **eleven** and is now stated as a command
rather than a figure; §4's *"79 candidates"* → **139** across nine worksheets and four kinds; §4's
*"the four thinnest themes"* is scoped to Aug 4, 2026 with the current bottom five named; and
Phase 16's copy of *"Nothing in this feature has ever run"* is struck, five days after the sentence
it quotes was corrected and **an hour after this same pass struck the identical quote at the top of
this file without grepping for its siblings**.

**Aug 21, 2026 — §17 is closed, and closing it is the argument for reading this file sceptically.**
Gemini video billing was enabled and the render path saw its first 200. **The errand was correctly
diagnosed and was not the last thing in the way**: the first successful render was refused by Omni
Flash's safety filter over a shot of a photograph, so the default model moved to Veo 3.1 Lite —
which is also half the price — and two response-shape errors surfaced that only a live call could
find. §17 has the evidence. **Also closed here: the second §17**, which was a numbering collision
one day old and is now §18.

Previously reviewed: **Aug 11, 2026** — and this was the review where most of the file stopped being
true. Apple enrollment (§1), Fly (§3), object storage (§2) and Actions billing (§0) were already
struck. What this pass found is that **every Lane A gap the iOS lane had recorded here has since
been built** — the seal's setness, `children.pronouns`, the avatar presign pair, `prompt_body` on
`EntryOut`, `?sealed=`, and the tag source that gated Phase 17 — and none of them had been marked
resolved. They were checked by reading the merged code on `main`, one grep each, and the greps are
in each section.

**Aug 12, 2026 — §1a is closed. Push notifications work in production.** The APNs key is minted
and set as Fly secrets, the notification job has its scheduled machine, and a real notification
was delivered to a locked phone and deep-linked on tap. Details and the evidence are in §1a.

~~**Aug 16, 2026 review — nothing in this file is blocked on a credential any more.**~~ — **that
stopped being true on Aug 20, 2026, and §10a is why.** §0, §1, §2, §2b and §3 are still closed, and
§10 is still an errand rather than a blocker: its blocking decision was the price, and D1 settled
that on Aug 15.

**What changed is that phase 37a built the thing §10 was waiting for, and building it produced two
blockers of its own** — one file and one number, both in §10a. Neither needed a decision and neither
could be done from the branch that found them. ~~**`POST /v1/webhooks/app-store` answers `401` to
every notification until both are done**~~ — **the file half closed on Aug 22, 2026, so it now
answers `401` to Production notifications only; Sandbox verifies.** The design is unchanged and is
deliberate: it fails closed rather than
accepting an unverified payload, so the failure is loud rather than a billing hole.

**One thing is blocked on a platform and cannot be engineered around: §9**, on-device photo
captioning. The grep that proves it lives in the section and is the thing to re-run when a new SDK
lands. Do not soften it and do not re-derive it from memory.

**Everything else on this list is unrecorded rather than blocked**, and that is a different
problem with a different fix. The device-verification checklists describe work that in at least one
case **has already been done in the world and was never written down**. Phase 16 is the example:
`SpeechAnalyzer` has produced a real, accurate transcription on a real device, and ~~the checklist
that gates the phase still opens with *"Nothing in this feature has ever run."* The gate is shut on
evidence that exists.~~ — **the checklist was corrected on Aug 17, 2026 and this paragraph went on
citing the dead sentence until Aug 22.**
`docs/Device-Verification/device-verification-transcription.md:3` reads
`~~**Nothing in this feature has ever run.**~~ — **corrected Aug 17, 2026**`, with the owner's
account of the run quoted directly underneath it. **The example survives the correction, and is
sharper for it**: the gap between the world and the written record closed after two days, and the
gap between the written record and the page citing it took another five. See the Phase 16 section.

> **This paragraph said "two things" for about an hour, and the second one had already been
> fixed.** It named the `sandbox`/`production` description bug in `schemas/device.py` and
> `docs/api-contract.md`; commit `39fb97f` had corrected both earlier the same day. It was
> copied here from `roadmap-status.md` without a grep, which is the exact failure that file
> records five times over — and it propagated into two more documents before anyone checked.
> **The rule that would have caught it is already written down: a shipped-status claim carries
> the command that proves it.** One `git log -L` closed it.

**Aug 11 second pass — the resolved sections were struck but not moved, and that was the defect.**
~~The four iOS sections below (Seal control, Onboarding, Timeline v3, Settings)~~ — **they are no
longer below; phase 111 moved all four into *Resolved since the last review* on Aug 22, 2026** —
were all correct at
the top of this file on Aug 11 and were still sitting under a heading that means "blocked",
describing workarounds as current. **A struck section is not a moved section**, and a file read for
"what is blocking me" gets skimmed by heading rather than read for strikethroughs. Two of them have
since been closed outright by phase 19 (PR #48); the remaining iOS follow-ups are named as such.

> **Standing habit this pass earns:** when a section resolves, it moves to
> `Resolved since the last review` in the *same pass* that strikes it, with the follow-on work
> stated as a phase rather than as a paragraph. The original entry can travel with it — the
> reasoning is usually why the fix is shaped the way it is, and that is worth keeping, just not at
> the top of the blocker list.

> **And the habit was not followed for eleven days.** It was written on Aug 11, 2026, in the same
> pass that diagnosed the defect it was meant to prevent, and the four sections it was written
> about stayed exactly where they were until **Aug 22, 2026**. Every reader in between opened a
> file called "blocked" and met four resolved iOS sections before the first real blocker. **A habit
> recorded in the same document it governs is not a process**, and this is the second time this
> page has caught itself that way — the first was the *"a shipped-status claim carries the command
> that proves it"* rule two paragraphs up, which was also written down before it was applied. What
> would actually have caught it is a rule with a place to run: the move belongs in the checklist of
> whatever phase strikes the section, not in a blockquote near the top of the thing being struck.

---

> **Seventeen resolved sections are archived.** GitHub Actions billing, Apple enrollment, object
> storage, Fly, `ANTHROPIC_API_KEY`, the six iOS-lane entries Lane A closed, §12, §14 and §17 are in
> [`docs/archive/blocked-resolved.md`](archive/blocked-resolved.md), moved whole and unedited by
> **phase 123 on Aug 25, 2026**, with the commands that proved each one closed. **Nothing partially
> resolved moved** — §10a and §18 each still have an open half and stay here in full.

## 2b. ~~The production media bucket does not exist yet~~ — IT EXISTS, AND THE UNRECOVERABLE HALF IS DONE. Verified Aug 11, 2026

**The bucket was created Aug 10, 2026 at 20:14, and soft delete is on.** This was the one item on
this page that could not be fixed after the fact, so it was checked by reading the bucket's own
configuration rather than by trusting the runbook:

```
$ tigris buckets get rascal-media-prod
Name                 rascal-media-prod
Soft Delete          Enabled (30 day retention)      <- the one that mattered
Delete Protection    No
Snapshots Enabled    No
CORS Rules           (none)
```

`rascal-backups` reads identically on the line that counts (`Enabled (30 day retention)`), and
`rascal-media-dev` still reads `Disabled`, which is the deliberate dev-bucket choice this section
described. So the configuration is exactly what this section asked for, on all three buckets. **The
window in which a mis-set production bucket could have quietly lost a photo is closed**, and it
closed before any real media went in.

### Two Tigris items, promoted out of prose. Neither blocks anything.

**7a — Delete Protection: wanted on prod and backups, and the flag is deprecated.**
`Delete Protection` reads `No` on all three buckets. Soft delete protects *objects*; delete
protection protects the *bucket* from one `tigris buckets delete` on the wrong name, and 30-day
retention on objects inside a bucket that no longer exists is not obviously a rescue. Owner,
Aug 16: turn it on for **`rascal-media-prod` and `rascal-backups`**, and **not** on
`rascal-media-dev`.

**The CLI does not straightforwardly support what that asks for, and this was checked rather than
guessed.** `tigris buckets set --help`, run Aug 16, 2026, lists:

```
--enable-delete-protection [value]   (deprecated) Enable delete protection Use
                                     --soft-delete instead.
```

It is the **only** delete-protection flag in `tigris buckets set`, it is marked deprecated, and the
CLI's own advice is to use `--soft-delete` — which is **already enabled with 30-day retention on
both of the buckets in question.** So either the control has been folded into soft delete and the
`No` in the bucket listing above is now vestigial, or it still exists and is reachable only through
a deprecated flag or the dashboard.

**Do not run either of these until that is settled** — the second uses a flag its own tool says not
to use:

```bash
# <verify> — deprecated per `tigris buckets set --help`, Aug 16 2026.
tigris buckets set rascal-media-prod --enable-delete-protection true
tigris buckets set rascal-backups    --enable-delete-protection true
```

The question to answer first is whether `Delete Protection: No` alongside `Soft Delete: Enabled`
still means anything on a current Tigris bucket. That is a dashboard or support question, not a
CLI one.

**7b — `rascal-media-dev` CORS `AllowedOrigins: ["*"]`: left as-is, and now it has an owner.**
Harmless while the only client is native: CORS is browser-enforced and `URLSession` ignores it
entirely. **This belongs to the web client phase** rather than sitting here as a loose note — the
entire risk is that nothing prompts it on the day a browser first loads a photo, and a note nobody
owns is exactly how that day arrives unprepared. `rascal-media-prod` has no CORS rules at all,
which is correct today and needs a real origin added by that same phase.

The original entry follows, because the reasoning is why the bucket was set up correctly, and
because the `access-keys assign` warning still catches people.

Not blocking anything today; local development runs against `rascal-media-dev`. Recorded here
because both items below are six-weeks-from-now problems that nothing currently reminds anyone
about, and one of them is unrecoverable.

**Soft delete must be on for the production media bucket.** `rascal-media-dev` deliberately has
it off — a dev bucket you cannot clear is a nuisance. Production is the opposite case: it holds
the one category of data in this system that cannot be regenerated. `rascal-backups` is already
configured the right way (soft delete, 30-day retention) and is the model to copy:

```bash
tigris buckets create rascal-media-prod --access private
tigris buckets set rascal-media-prod --soft-delete enable --retention-days 30
tigris access-keys create rascal-api-prod
tigris access-keys assign <key-id> --bucket rascal-media-prod --role Editor
```

The assign step is not optional — a new key has no permissions and every call, including
presigned PUT, returns `AccessDenied`.

**`DEPLOY.md` §3 used to specify versioning for the AWS bucket, and that requirement did not
survive the move to Tigris.** Tigris soft delete covers the same ground — recovering an object
deleted or overwritten by mistake — but it is a different mechanism with a retention window
rather than unlimited history, and it is off by default. That drift is the actual risk: the
old document said "turn on versioning", the new one does not say "turn on soft delete", and
nobody notices until they need it.

**CORS should be tightened when a web client exists.** `rascal-media-dev` is currently
`AllowedOrigins: ["*"]`. That is harmless while the only client is native — CORS is
browser-enforced and `URLSession` ignores it entirely — but it should become the real origin
the day a browser first loads a photo, and nothing else will prompt that.

---

## Deferred by decision — not blocked, and not waiting on you

These were left out on purpose. Each is a small piece of work if you decide otherwise.

- **`POST /prompts/batch-review`.** Not deferred any more — **cut**, and removed from
  `docs/api-contract.md` rather than left in it as a promise. The review queue it approved
  candidates from is a pull request now: `scripts/generate_prompts.py` writes batches into
  `docs/prompt-candidates/` and the *Prompt candidates* workflow opens a PR with them. A
  branch with a diff is already an accept/reject interface with a comment thread, an audit
  trail, and an undo. — **Half of this was overtaken Aug 20, 2026 by phase 103, and the half
  that matters here still holds.** The endpoint under this name is still not built and still
  not planned: approving a candidate is `PUT /prompts/{id}/active`, one prompt at a time, read
  by a person. What stopped being true is the reasoning — there *is* a review queue now, in the
  console's Library tab, writing `source='llm'`, `active=false` rows that
  `scripts/review_candidates.py` reads. The PR flow above is unchanged and is still the batch
  path. Left rather than struck, because the conclusion is still correct and only its argument
  moved.
- ~~**`POST /children/{id}/guardians`.** P2 in the contract, and the guardian invite flow is
  out of scope. … Only the invite mechanism is missing.~~ — **struck Aug 18, 2026. Phase 36 built
  the invite mechanism on Aug 17, and the route named here never existed at all.** Guardians are
  invited through **`POST /families/me/invites`**, because an invite belongs to the *household*
  rather than to one child: a second parent joins a family and gets every child in it. Phase 72
  struck the child-scoped route from `api-contract.md` for the same reason. The rest of this bullet
  was accurate and is now simply history.
- **Thumbnails and poster frames.** `POST /media/{id}/complete` marks the row and leaves
  `thumb_key` null. The column exists and clients already handle it being null, so the
  pipeline slots in later with no schema or contract change.
- **The `ORDER BY random()` scan in the moments fallback.** Fine at 100 entries, worth
  revisiting at P1.
- ~~**Transcribing the audio track of a video.** Cut from the transcription phase rather than
  shipped shaky.~~ — **struck Aug 18, 2026: phase 16 shipped it on Aug 17**, and it did not need the
  device checklist run first. **The premise below was false and that is the interesting part**: a
  diagnostic handed `AVAudioFile(forReading:)` a real H.264 + AAC mp4 and it opened it, reading
  22050 frames at 44.1 kHz mono — Core Audio reads the track straight out of the container, so the
  separate-export machinery this bullet anticipated was built for a problem that does not exist. What
  the premise *had* been hiding: a video with **no** audio track fails to open, which would have
  burned a silent clip's whole six-attempt retry budget over hours. Original text kept below. The roadmap asks for it and `AVAudioFile` plausibly opens an MPEG-4
  container's audio track — but *plausibly* is the whole problem: nothing in this environment
  can run a single real transcription, so a second input path would be unverifiable on top of
  an already unverified first one. It is also the expensive one, because a backlog video has
  to be fetched to be read at roughly 70MB a minute. **What it needs:** the audio path
  confirmed on a device via `docs/Device-Verification/device-verification-transcription.md`. After that it is one
  clause in `TranscriptionQueue.isTranscribable` plus a rule about not doing it on cellular.
  **Aug 16, 2026: that prerequisite is now a runnable action rather than an unrun one.** The
  transcriber has produced real, accurate output on a real device — see the Phase 16 section — so
  what stands between this and being buildable is somebody running the checklist and writing the
  results down, not a question about whether the transcriber works.
- **Backfilling transcripts on a phone that never sees Wi-Fi.** Fetching a recording this device
  does not hold refuses expensive and constrained networks on purpose — a backlog run is hundreds
  of files and nobody consented to that on cellular. The consequence is that those rows never
  backfill on a cellular-only phone; they report *"Waiting for Wi-Fi"* and stop after the retry
  cap. There is deliberately **no override toggle** — Settings has no preferences and adding one
  for this would be the first. **What it would need:** evidence that anyone is actually in this
  position. Recordings made on the phone itself are unaffected, which is the common case.
- **Transcript editing.** A parent will eventually want to correct a word. That is a real
  feature with a real conflict story — two devices editing the same derived field against a
  server documented never to regenerate it — and shipping an editor without that story turns
  "on-device output is durable data" into "whichever phone typed last".
- **A search result matched on someone else's transcript cannot say why it matched.**
  `GET /entries` inlines `MediaSummary`, which carries no transcript, so the client can only
  quote a matching line for a transcript it has cached. It renders as an ordinary card
  otherwise, which is correct rather than broken. **What it needs:** either `transcript` on
  `MediaSummary` or a `matched_snippet` on the search response — both are API-lane changes and
  neither is worth making for this alone.

---

## Phase 16 (video audio tracks) — **not blocked. Unrecorded.** (rewritten Aug 16, 2026)

**Nothing stands in front of this phase.** No credential, no platform gap, no design question.
~~It is unstarted~~ — **and as of Aug 17, 2026 it is shipped**: phase 16 landed as `b5eaa1c` (PR
#116), `ios/Rascal/Rascal/Media/VideoAudioTrack.swift`. **This section is kept because its diagnosis
was right and its premise was wrong**, which is a more useful record than a deleted heading: the
thing holding the phase really was *a document that disagrees with the world*, and when somebody
finally ran the code, the document was wrong in the other direction too — the separate audio export
everyone had specified around turned out to be unnecessary.

**The transcriber works, and it has been seen working.** Owner, Aug 16, 2026: `SpeechAnalyzer` has
produced a real transcription on a real device, on a build from that day, and the output was
accurate enough to capture his son's actual pronunciation of words. That is precisely the question
`docs/Device-Verification/device-verification-transcription.md` §0 — per-recording word accuracy — exists to answer.

~~**So the blocker is the file, not the feature.** The checklist still records **0 of 45** and still
opens with *"Nothing in this feature has ever run."* Phase 16's preflight #1 reads that document
rather than the world, so it hard-stops — **correctly, given what the document says.** The gate is
doing its job on stale input.~~ — **struck Aug 22, 2026. Both halves of that sentence are wrong,
and the same false quote was struck sixteen hundred lines further up in this very pass while this
copy went on repeating it.**

**The opening sentence was corrected on Aug 17, 2026, five days before this page stopped citing
it.** `docs/Device-Verification/device-verification-transcription.md` §0's opening now reads
`~~**Nothing in this feature has ever run.**~~ — **corrected Aug 17, 2026**`, with the owner's
account of the run quoted directly beneath it. So the gate is no longer shut on that sentence.

**And the count was stale in the other direction: it is `0 of ~~45~~ 52`, not 0 of 45.** Phase 79
added §4a's seven boxes on Aug 18, 2026 and the checklist says so on its own line 13. Counted
today: `grep -c '^- \[ \]'` returns **52** and `grep -c '^- \[x\]'` returns **0**, so *nothing has
been ticked* remains true and *how much there is to tick* grew by seven. **The 45 is not only
here** — `docs/roadmap-status.md`, `docs/phase-queue.md` and two files under `docs/sprint-aug16/`
carry it too, and they belong to other lanes and other phases; this page corrects only itself and
says where the rest are.

**The lesson is the narrow one, and it is about this document rather than that one.** The
correcting sentence at the top of this file — *"the checklist was corrected on Aug 17, 2026 and
this paragraph went on citing the dead sentence until Aug 22"* — was written in this same pass, and
**the author fixed the instance they were looking at and did not grep for the others.** A quotation
is a copy, and a copy has siblings: when a quoted sentence turns out to be dead, the fix is
`grep -rn` for the quote across `docs/`, not an edit at the cursor.

**The single action:** run `docs/Device-Verification/device-verification-transcription.md` on the current build and
record results, dates and device names. Start with §0, which is now largely **retrospective** — it
is writing down something that has already happened. Run the PR #22 audio checklist in the same
sitting; it is the stated prerequisite and it needs the same quiet room and the same device.

**Nobody but the owner may tick those boxes.** This section was written by an agent that has not
run the checklist, cannot run it, and must not record a result it did not observe. The whole value
of that file is that a ticked box means somebody watched it happen.

> **This is the file's recurring failure mode wearing a new face, and it is worth naming.** Every
> previous instance was a *claim copied forward without a grep* — something asserted as true that
> had stopped being true. This one runs the other way: **a verified real-world result was never
> copied *into* the document**, and a gate stayed shut on evidence that already existed. The
> standing rule — *a shipped-status claim carries the command that proves it* — only defends
> against the first kind. The second needs the opposite habit: when something is proven in the
> world, write it down where the gate will read it, in the same sitting.

The original reasoning, which was sound on the day and is why the gate exists at all: building video
transcription on an unverified transcriber stacks two unknowns in one branch, and if the output were
poor nothing would distinguish a bad extraction from a model that cannot read a four-year-old. That
argument has not been refuted — **it has been satisfied**, and the checklist is where that gets
recorded.

---

## §9 — Photo captioning has no on-device API to call (Aug 14, 2026)

**Phase 33's server half is complete and its device half cannot be written.** Not "is hard", not
"needs design" — there is no public, on-device, no-network API in the installed SDK that turns
pixels into prose, so the one function at the centre of the phase has nothing to call. Everything
downstream of it — a queue, a Settings row, a backoff ladder, a wire field — is scaffolding for a
body that cannot be filled in.

**The evidence, so nobody re-derives it.** Against iPhoneOS26.4 (Xcode 26.4.1), the only SDK
installed here:

```
SDK=/Applications/Xcode.app/Contents/Developer/Platforms/iPhoneOS.platform/Developer/SDKs/iPhoneOS.sdk
FM=$SDK/System/Library/Frameworks/FoundationModels.framework/Modules/FoundationModels.swiftmodule/arm64e-apple-ios.swiftinterface
grep -n "public enum Segment" -A 3 "$FM"        # -> case text(...) / case structure(...), and nothing else
grep -ciE "CGImage|CVPixelBuffer|UIImage|CIImage" "$FM"   # -> 0
```

`Transcript.Segment` is the entire input vocabulary of the on-device model, and it has exactly two
cases, neither of which is an image. **That single grep is the whole answer**, and it is the one to
re-run when a new SDK lands.

**The near misses are worse than nothing, and each is a trap worth naming:**

- `Vision.ClassifyImageRequest` returns `ClassificationObservation { identifier, confidence }` — a
  taxonomy label, not a sentence. Composing prose out of labels invents the specifics, and a
  caption is durable data the server never regenerates. A permanent plausible lie about somebody's
  child is worse than an empty field.
- `VisionKit`'s `ImageAnalysis.transcript` is OCR of text *inside* the picture.
- `AnalysisTypes.visualLookUp` is **server-backed**. Reaching for it would send a child's
  photograph to a third party. That is forbidden by the product's own promise that nothing leaves
  the device — `docs/memory-app-roadmap.md`'s on-device guardrails and rule 7's "on-device AI
  output is durable data" premise. **Not rule 4**, which an earlier draft of this cited: rule 4 is
  "no third-party dependencies", about SPM and CocoaPods, and it has nothing to say about where
  bytes go.
- `ImagePlayground` runs the other way: text in, image out.
- `MediaAccessibility`'s `MAImageCaptioningCopyCaption` exists and has since iOS 13, but it is a
  *metadata accessor* — it reads an XMP field a human or another tool already embedded. It runs no
  model. (Worth a measurement spike as a different, smaller feature; see below.)

**The roadmap's scheduling claim is unverified and has been corrected.** It read *"on-device image
input landed in the iOS 27 wave"*, in the past tense, about a release whose SDK is not installed
here — and `docs/phases/phase-17.md` already quotes it forward as settled. The half that is
confirmed is *not available now*. When it arrives is not something this repo has checked.

**One shippable alternative, if it is ever wanted:** `MAImageCaptioning` covers the entire 18.6
install base, needs no model, no Apple Intelligence hardware, no battery and no network — and
because the text is human-authored rather than machine-invented, it sidesteps the permanent-lie
hazard entirely. The hit rate on photos straight from an iPhone camera is unknown and probably
low, so it is worth a measurement before it is worth a phase. It is a different feature from the
one the roadmap describes, so it is the owner's call.

### Re-verified Aug 16, 2026, and the measurement now exists (phase 46)

**The grep above was re-run and the block is unchanged.** Same SDK — iPhoneOS26.4, Xcode 26.4.1.
`Transcript.Segment` is still exactly `case text` and `case structure`, and the interface grep for
`CGImage|CVPixelBuffer|UIImage|CIImage` still returns **0**. Nothing about the platform half of
this section has moved.

**`MAImageCaptioning` was verified to work rather than assumed to.** `CaptionProbeTests` writes a
caption into a real JPEG with `MAImageCaptioningSetCaption` and reads it back through the same
`MAImageCaptioningCopyCaption` call the probe uses. The round trip passes, so **the reader is not
in question — only the population is.** The header confirms what it reads:
*"This checks for XMP metadata field: `Iptc4xmpExt:AOContentDescription`."*

**The owner's call was: measure first.** `CaptionProbe` and its Settings row ship as a
**diagnostic, not a feature** — it walks the newest 500 on-device photos, counts how many carry
that field, and reports a rate plus a few examples. It writes nothing, uploads nothing, persists
nothing, and never pulls an iCloud original.

**Aug 16, 2026: the measurement is runnable now, and is no longer waiting on a build.** This
section previously said it needed a TestFlight build. The owner has a current device build from
Aug 16 carrying `CaptionProbe` and its Settings row, so the only remaining input is a real camera
roll and an evening. Run it with `docs/Device-Verification/device-verification-captions.md`.

### Re-verified Aug 22, 2026. The platform block has not moved, and the owner will measure this week

**Owner's call, Aug 22, 2026: keep the probe, run the measurement this week.** No code changes.
The threshold table immediately below already decides the outcome the moment the number exists, so
there is nothing to design and nothing to argue about — there is a number to go and get.

**The section's own re-check command was re-run today, against the same and only installed SDK.**
iPhoneOS26.4, Xcode 26.4.1 (17E202). `Transcript.Segment` is still exactly `case text` and
`case structure`, and the `CGImage|CVPixelBuffer|UIImage|CIImage` count against the
FoundationModels swiftinterface is still **0**. **Eight days on, nothing about the platform half of
this section has changed** — so §9's factual core is *re-verified, not stale*, and the right
treatment is this note rather than a rewrite. That distinction is the reason for running the grep
instead of trusting the paragraph: a section that turns out to be correct should be marked correct
with a date, so the next reader knows how old the last look was rather than how old the prose is.

**The checklist itself was carrying a dead prerequisite until today, and that is fixed.**
`docs/Device-Verification/device-verification-captions.md:3` opened *"Needs a TestFlight build and
a real camera roll"* — superseded on Aug 16, 2026, when the owner took a device build carrying
`CaptionProbe` and its Settings row. **The paragraph directly above recorded that six days ago and
the checklist never heard.** That matters more than an ordinary stale line because **the checklist
is the instrument somebody opens in order to do this**: its first sentence named the thing that had
stopped it, so the reader most likely to run the measurement was the reader most likely to be told
not to bother. Phase 111 struck it; the real remaining input is a real camera roll, years of it,
which a simulator cannot supply. **The historical entry in `docs/decisions-log.md` was deliberately
left alone** — it was true on the day it was written, and a log is not a status page.

### The decision rule, set before the number is known

This section already warns that a disappointing result can be quietly reinterpreted later as a
reason to build anyway. **The defence against that is a threshold agreed in advance**, so here it
is, as the owner's rule, Aug 16, 2026:

| Measured rate | Outcome |
|---|---|
| **Under 20%** | Delete `CaptionProbe` and `CaptionProbeScreen`. **Close phase 33.** A caption writer costs a SwiftData migration over every media row plus the clobber guard; four photos in five with an empty field does not justify it, and an inconsistently populated caption makes a search result unexplainable — the parent cannot tell why one photo matched and its neighbour did not. |
| **20–50%** | Keep the probe as recorded evidence. **Do not build the writer.** Revisit only if an SDK ships real on-device captioning. |
| **Over 50%** | The writer earns a phase — and it lands with the clobber guard in `Media.applyServerSummary` and `SyncEngine.differs(_:from:)` **in the same commit**, exactly as this section already specifies below. |

**A rate is only as good as the library it was measured against.** One phone is one data point, and
a photographer's roll and a parent's roll are not the same population; if the number lands near a
boundary, run it on a second phone before applying the rule.

**Two things deliberately did not ship with it, and both would have been premature:**

- **No caption writer, and therefore no caption state ladder.** The ladder is a SwiftData
  migration on every media row, and committing to it before the number is known is exactly the
  mistake this section warned against.
- **No clobber guard.** `Media.applyServerSummary` and `SyncEngine.differs(_:from:)` both handle
  `caption` unguarded, so **they agree with each other and there is no live defect**. A guard now
  would guard a writer that does not exist. The clobber's deferral, recorded by phase 41, now
  points at this measurement rather than at a phase that may never land.

**If the number comes back near zero, the honest outcome is that `CaptionProbe` and
`CaptionProbeScreen` are deleted and 33 closes.** That is a real possible result of this work and
it is written down here so it is not quietly reinterpreted later as a reason to build anyway.

**One thing to fix on the way in, whenever this unblocks.** The pull path already clobbers
captions, and it has since before there was anything to clobber. `Media.applyServerSummary`
(`Media.swift:210`) writes `caption = summary.caption ?? caption` **outside** the
`!hasUnpushedTranscript` guard directly above it, and `SyncEngine.hasUnpushedChanges(_ media:)`
(`SyncEngine.swift:660`) tests transcripts and upload state and nothing else. It is the Aug 9
transcript defect, pre-installed on the caption field.

**It is inert today and that is not luck** — `Media.caption` has exactly one writer in the whole
app and it is that same server-fold line, and `RascalAPI.writeDerived` sends the transcript alone,
saying so in a comment at `RascalAPI.swift:267`. Nothing produces a caption, so nothing can be
overwritten. **It stops being inert the moment this phase writes the first one.**

The fix is not separable from the phase. A guard needs a caption sync state to read, and that
state is the same SwiftData migration over every media row that the phase needs anyway — which is
why it was never worth doing alone. Whoever builds the writer extends `hasUnpushedChanges(_ media:)`
and moves the caption line inside a guard **in the same commit**, and mirrors it in
`differs(_:from:)` at `SyncEngine.swift:633`, whose doc comment promises it matches
`applyServerSummary` exactly. Owner's call, Aug 15; carried here by phase 41 on Aug 16.

---

## §10 — Monetization: a prerequisite **errand**, not a blocker (reclassified Aug 16, 2026)

Phase 37 (entitlement and StoreKit) cannot be written against nothing. Two account actions come
first, and both are yours — this file's original terms exactly: a credential or an account only you
have.

- **Enrol in the App Store Small Business Program.** D5 assumes 15%, and enrollment is what makes
  that true in year one. Subscriptions fall to 15% in year two regardless, so this is a year-one
  difference of 15 percentage points on every payment.
- **Create the subscription products in App Store Connect** — the annual and the monthly, ~~with the
  14-day trial and~~ **with no introductory offer** (corrected Aug 22, 2026 — the fourteen days are
  granted server-side and an Apple offer would stack a second fourteen on top; see step 5 below) and
  annual preselected per D1. Without product identifiers there is no StoreKit
  transaction to receive, no sandbox to test against, and nothing for the webhook to be sent about.

**Nothing else in D1–D6 is blocked.** 38 (lifecycle notices) needs no Apple account at all — it is a
job, two tables and three channels, and it can be built and tested before a single payment exists.
39 is a research task. And the print partner (D6) needs an account only once one is chosen, which
D6 explicitly does not do.

~~**This is recorded rather than acted on**: creating products and choosing price tiers were named
out of scope for the phase that wrote this, and doing either from here would be picking a price.~~

### That last line went stale the day it was written

**D1 settled the price on Aug 15** — $59.99/year or $5.99/month, annual exactly two months free,
annual preselected, a 14-day trial, and a permanent free tier. Creating these products no longer
requires a decision from anybody. What is left is data entry.

> **One word of that needed amending, Aug 22, 2026: *where* the 14-day trial lives.** D1 says
> "a 14-day trial" and does not say who grants it, and the runbook below read that as *an Apple
> introductory offer*. It is **server-side** — `constants.TRIAL_DAYS` and
> `entitlements.trial_ends_at`, written at family INSERT — and Apple is configured with none. The
> owner's call, today. `docs/decisions.md` carries the amendment against D1 with the same date;
> this is a note, not the record. **The reason it matters here is that this section is the runbook
> somebody types from**, and a decision that is ambiguous about implementation gets disambiguated
> by whoever writes the runbook, silently and once.

**This section blocks nothing currently in the queue.** Phase 37 sits downstream of the P0
behavioural gate — seven days of unforced use — which has nothing to do with money. Building
StoreKit before that gate passes is building a checkout for a shop that may not open.

**One part is time-sensitive anyway, and it is not the products.** Small Business Program
enrollment is reviewed by Apple, and the 15% rate applies from the start of the **next fiscal month
after approval**. Left until launch week it costs 30% for a month. The form is worth filing early
even though the products are not.

### The product identifiers, chosen Aug 16 and permanent once created

```
Subscription group:  Vellum Membership
Annual:              com.travisterry.childarchive.subscription.annual
Monthly:             com.travisterry.childarchive.subscription.monthly
```

**One group containing both durations**, so they are mutually exclusive and StoreKit treats
monthly → annual as a *plan change* rather than two live subscriptions. The `.subscription.`
segment keeps the namespace clear for a future non-renewing product — the printed book, per D6.
**App Store product identifiers cannot be renamed after creation**, which is why these were chosen
at a desk rather than mid-phase. Recorded as **D5a** in `docs/decisions.md`.

### The errand, in order. Each step gates the next.

1. **App Store Connect → Agreements, Tax, and Banking.** The Paid Applications agreement must be
   **active**: complete the banking details and the tax forms. Nothing else on this list is
   possible until it shows active.
2. **Enrol in the App Store Small Business Program.** Requires step 1. Note the fiscal-month lag
   above — this is the one worth doing now.
3. **Create the subscription group** `Vellum Membership`. **Renamed from `Dogear Membership` on
   Aug 17, 2026 with the product, and this line was the urgent half of that rename**: a
   subscription group name is **permanent on first save**, so working this runbook before it was
   corrected would have carried the dead name for the life of the listing. Nothing has been
   created yet, which is the only reason this edit was still possible.
4. **Create the two products** with the identifiers above, at **$5.99/month** and **$59.99/year**.
5. **Set the annual as the preselected option**, and create both products with **no introductory
   offer at all.** ~~configure the **14-day free trial** as an introductory offer, per D1.~~ —
   **corrected Aug 22, 2026 by the owner's call. This step would have given away twenty-eight free
   days, not fourteen.**

   The trial is **server-side and already granted**. A family row gets `entitlements.trial_ends_at`
   at INSERT from `constants.TRIAL_DAYS` (`models/family.py`), so day 0–14 is full membership for
   free before Apple is involved at all; on day 15 the board locks to the daily question and shows
   a CTA, and **when the parent taps Join, Apple charges immediately.** An Apple introductory offer
   on top of that is a *second* free fortnight: **Apple's introductory-offer eligibility is per
   Apple ID and per subscription group, and it cannot see `trial_ends_at`** — there is no field to
   tell it the fourteen days were already spent. The two clocks stack, and fourteen becomes
   twenty-eight.

   **This is the step where a wrong line costs money rather than time.** Nothing has been created
   yet, which is the only reason this is an edit and not an incident; a configured introductory
   offer is visible to every purchaser from the moment the product goes live.
6. **Record the App Store Server Notifications V2 endpoint URL.** D5 holds that the server writes
   the entitlement and every gate reads the server, so this URL is what phase 37 is built against.

**`ios/Rascal/RascalTests/Vellum.storekit` is now inconsistent with step 5, and it is iOS-lane
work.** The local StoreKit configuration phase 37b was written against carries two
`introductoryOffer` blocks — one per product — so the simulator's purchase flow currently rehearses
a free trial that App Store Connect will not be configured to offer. **Nobody working from this
file may edit it**: `CLAUDE.md` is explicit that an agent working in `api/` never edits `ios/`.
It is recorded here, and in `docs/phase-queue.md`, so that the inconsistency is owned rather than
discovered during the first sandbox purchase — where the symptom would be a paywall that offers a
trial in the simulator and charges immediately in sandbox, which reads as a StoreKit bug and is not
one.

**Apple's exact menu wording is not verified here.** These steps name destinations rather than
click paths on purpose — App Store Connect's navigation changes, and a stale menu path in a runbook
is worse than a described destination. Nobody on this branch has an App Store Connect session.

~~**Phase 37b shipped against a `.storekit` file and has never been exercised against Apple**~~
(Aug 20, 2026; **the client half has since been exercised, Aug 27–28, 2026, by phase 129**). The
client half — products, paywall, purchase, restore, the `Transaction.updates` listener — is built
and merged, and `ios/Rascal/RascalTests/Vellum.storekit` is the local configuration it was written
against. **A real TestFlight purchase reached the App Store and a real `DID_RENEW` notification
came back**, so this is no longer untested against Apple — see §10a below for what that
notification proved and correctly did not do. ~~The errand above is unchanged and still gates the
first real transaction: until steps 1–5 are done there is no sandbox purchase to make, and **the
`appAccountToken` round trip to 37a's webhook has never been observed end to end.**~~ — **wrong as
of Aug 28, 2026: the round trip has been observed end to end, in Sandbox.** What is still true is
narrower — **no Production purchase has ever reached this service**, which is the first live
subscriber's job to prove, not this errand's.


---

## §10a — The webhook is built; ~~and cannot verify anything yet~~ ~~it verifies Sandbox today and still cannot verify Production~~ **it verifies both today, and a live Sandbox notification has round-tripped through the whole path** (Aug 20, 2026; item 1 closed Aug 22, 2026; item 2 closed Aug 28, 2026)

**Phase 37a shipped `POST /v1/webhooks/app-store`, the only code that writes
`entitlements.tier`.** It is tested, reviewed twice, and ~~**refuses every notification with
`401`** until the two items below are done~~ — ~~**that was true until Aug 22, 2026. Item 1 is now
closed and only Production is still blocked.**~~ — **both items are closed as of Aug 28, 2026; see
below.** The fail-closed design is unchanged and is still the
point: the signature is the
only thing standing between a stranger and somebody's billing state, so there is no branch that
accepts an unverified payload and no local bypass.

**Neither of these was the errand in §10, and neither waited on it.** §10 needs the Paid
Applications agreement before anything else can happen. These two did not: the app record already
exists, and the certificate was a public download — **which is how item 1 came to be closed on a
day when nothing about §10 had moved at all.**

### ~~1. Apple Root CA - G3 is not in the repository~~ — **CLOSED Aug 22, 2026. It is in the repository.**

**Fetched, verified twice, and committed.** `https://www.apple.com/certificateauthority/AppleRootCA-G3.cer`
answered **HTTP 200** with **583 bytes**, now at `api/src/rascal/certs/appstore/AppleRootCA-G3.cer`.

What the file is, read out of the file itself:

- `subject` and `issuer` are both `CN=Apple Root CA - G3, OU=Apple Certification Authority,
  O=Apple Inc., C=US` — self-signed, as a root must be.
- Valid `Apr 30 18:19:06 2014 GMT` → `Apr 30 18:19:06 2039 GMT`.
- SHA-256 `63:34:3A:BF:B8:9A:6A:03:EB:B5:7E:9B:3F:5F:A7:BE:7C:4F:5C:75:6F:30:17:B3:A8:C4:88:C3:65:3E:91:79`.

And what the code does with it: `rascal.services.app_store.load_root_certificates(CERTS_DIR)`
returns **1** anchor of 583 bytes, where it returned none, and the startup `ERROR` this item
described is gone. `pytest -k "app_store or webhook"` → **96 passed**.

**Why the blocker was real and why it was still stale, which are both true at once.** This section
said `www.apple.com` is refused at the egress proxy and that the root is carried by neither
`certifi` nor the container's system CA bundle. **All of that was correct — of the environment
phase 37a was built in.** What went stale is not the observation, it is the scope the sentence
implied. Written as *"the environment refuses it"* it reads as a property of the work; it was a
property of one machine, and the very next machine to open the file had ordinary internet access.
**A blocker inherits the environment it was written in, and the environment is part of the claim.**
The correct form was *"cannot be done from the branch that found it"*, which the top of this file
happens to say and this section did not.

**The documented verification step could not be followed as written, and replacing it was the real
work.** Both this item and `api/src/rascal/certs/appstore/README.md` said to compare the SHA-256
against *"the fingerprint Apple publishes beside the download"* on
<https://www.apple.com/certificateauthority/>. **That page was fetched on Aug 22, 2026 and contains
no fingerprints at all** — zero occurrences of *"fingerprint"* or *"SHA-256"*; it is a bare list of
download links. So the one instruction standing between a downloaded root and a trusted root was
unfollowable, and had been for however long. **An unfollowable verification step is worse than no
step**, because the next person either skips it or invents a substitute under time pressure.

**The substitute, and why it is a genuine second source rather than a file checked against
itself.** Apple Root CA - G3 also ships inside macOS, in the system keychain, put there by Apple
through an entirely different distribution channel:

```sh
security find-certificate -a -c "Apple Root CA - G3" -Z \
  /System/Library/Keychains/SystemRootCertificates.keychain
#  -> SHA-256 hash: 63343ABFB89A6A03EBB57E9B3F5FA7BE7C4F5C756F3017B3A8C488C3653E9179
cmp downloaded.der keychain.der
#  -> identical
```

Two Apple-controlled channels, byte for byte identical. **This is macOS-specific and that is a real
limitation**: a Linux checker cannot run `security` and needs a different second source. **The
method replaced the dead instruction in `api/src/rascal/certs/appstore/README.md` in the same
phase**, along with the macOS caveat — that file sits next to the code and is where somebody stands
when they need it, so a verification step that lives only on this page is a step that will not be
run.

### ~~2. `APP_STORE_APP_APPLE_ID` is unset~~ — **CLOSED Aug 28, 2026. It is set, and both verifiers build.**

The app's **numeric** Apple ID from App Store Connect — not the bundle id. Apple's own library
refuses to construct a Production verifier without it, because a bundle id alone does not pin which
app a signed payload is about, so a Production notification cannot verify while it is missing.

It is on the app's page in App Store Connect and takes a minute to read off. Set it as a Fly secret;
`docs/runbook-deploy.md` §4 has the row.

**This does not wait on the Paid Applications agreement.** The app record has existed since
TestFlight, so unlike everything in §10 this one is available today.

~~**Still open, confirmed Aug 22, 2026.** `flyctl secrets list -a rascal-api` was read in full and
`APP_STORE_APP_APPLE_ID` is **absent**.~~

**Wrong by Aug 28, 2026, and stale for longer than that was noticed.** `flyctl secrets list -a
rascal-api`, read that day, shows `APP_STORE_APP_APPLE_ID` **Deployed**, alongside
`APPLE_BUNDLE_ID`. Nobody had re-run the check since Aug 22 to see it change. Confirmed by
constructing the verifier directly, on the production machine, rather than trusting the secret's
mere presence:

```
$ flyctl ssh console -a rascal-api -C "python -c \"
from rascal.services.app_store import AppStoreVerifier
from rascal.config import get_settings
v = AppStoreVerifier(get_settings())
print(sorted(e.name for e in v._verifiers))
\""
['PRODUCTION', 'SANDBOX']
```

**Both verifiers build today.** The distinction §10a drew between them — Sandbox needs only the
root and the bundle id, Production needs the app id too — is still correct; what changed is that
the app id is now present, so both branches of that distinction construct rather than one.

**And more than construction was proven, the same day, by a live notification rather than a
manual check.** A Sandbox `DID_RENEW` for `com.travisterry.childarchive.subscription.monthly`
arrived at `POST /v1/webhooks/app-store` on Aug 28, 2026 and is in `app_store_transactions`.
Reading it end to end: the outer JWS verified, the nested `signedTransactionInfo` verified and
decoded, `appAccountToken` decoded to a real `family_id` that `session.get(Family, …)` resolves —
every step this item and its heading describe as unverified, verified, on production, against a
payload Apple actually signed. **The one thing that did not happen, correctly:** the notification
did not write `entitlements.tier`, because `may_write_tier("Sandbox", "prod")` returns `False` —
Guard 3, working exactly as `app_store_events.py`'s own docstring says it should: *"a Sandbox
tester account is free to create, so treating its notifications as real would let anybody
subscribe a production household by buying nothing."* The row was correctly recorded and
correctly left unattributed. That guard is not this item's business and is not weakened by
closing it — see the new entry below for what *is* worth fixing about it.

**What is still genuinely unverified, stated so the next reader does not read "both verifiers
build" as "a real purchase has gone through end to end."** No Production App Store Server
Notification has ever reached this service — the evidence above is Sandbox, by construction,
because that is what a TestFlight build sends. The first live subscriber is still the first time
the Production branch of this code runs against a real Apple payload rather than a constructed
verifier object.

### What is *not* blocked

Everything else in phase 37a. The table, the four guards, the ordering and sandbox isolation, the
entitlement read route and 986 passing tests are all in `main`'s history and need nothing from
anybody. **And nothing here blocks the app**: the webhook is the only route affected, no client
calls it, and the existing paywall reads `entitlements` exactly as it did before.

---

## §11 — Apple's `sub` has never been observed across a revoke and re-authorize (Aug 16, 2026)

> ~~**Owner, Aug 19, 2026: deferred — "not today, but remind me about it."**~~ — **the reminder was
> delivered on Aug 22, 2026 and the owner's answer was to run it, with a pre-step. See *Rewritten
> Aug 22, 2026* below; this note is kept because the deferral is why the experiment is three days
> older than the code it tests.** So this stayed open by
> decision rather than by neglect, and the reminder is this paragraph: it is a five-minute errand on a
> device, and it is the last unobserved assumption underneath account recoverability.
>
> **What changed while it waited:** phase 93 added two tests that assert the *failure* mode rather
> than the feature — a changed `sub` after a revoke produces a second, empty archive with the first
> still in the database owned by a user nobody can sign in as, and nothing links the two by email.
> `services/auth.py:44-52` already described that consequence in its own docstring; the suite did not.
>
> That does **not** narrow this item. It means the cost of the wrong answer is now executable instead
> of prose, so whoever runs the experiment can see immediately which branch they landed in. The
> experiment itself still needs a real Apple ID, because the suite mints its own tokens and can only
> assert what it chose to simulate.

**Phase 53 is built and tested and may not be called complete on that.** The route, the four
event behaviours, the signature verification and nineteen tests are on `main`. What has never
happened is the thing the design rests on, and it needs your phone.

**The assumption.** `credentials.subject_id` is Apple's `sub`, and the whole recoverability
story — revoke, come back, land on the same archive — depends on that `sub` being **the same
value** after a parent removes the app from their Apple ID and signs in again. Apple documents
it as stable per Apple ID per developer team. It has never been observed here, not once, and
no test can observe it: the suite signs its own tokens, so it can only prove that the code does
the right thing *given* a stable `sub`.

**If the `sub` changes, the design is wrong rather than buggy.** A returning parent would get a
brand-new empty account, their archive would sit behind a `users` row nothing can reach, and
every one of the nineteen passing tests would still pass. **Stop and say so rather than
patching it** — the fix would be a redesign, and it would need to happen before anybody relies
on revocation being recoverable.

### Rewritten Aug 22, 2026 — two pre-steps, and one query that would have misreported

**Owner's call, Aug 22, 2026: run it for real, but attach an email credential first.** What makes
that possible today and not on Aug 19 is that **Resend is live** — `MAIL_PROVIDER`, `MAIL_API_KEY`
and `MAIL_FROM` are all `Deployed` on `rascal-api` and this service has sent real mail (§13). The
magic link actually arrives now. Before that it was a route that returned `202` into a `console`
provider, which is not a way back into an account.

**Pre-step A — attach an email credential to the account before revoking anything.**

```
POST /v1/me/credentials/email        { "email": "<an inbox you control>" }
```

Then open the link it mails, which completes through `POST /auth/email/complete`; the credential is
created inactive and **the click is what activates it**, so nothing is proved until the mail lands.
Confirm with `GET /v1/me/credentials` that the row is there and live.

**This is not belt-and-braces, it is what makes the bad branch survivable.** If step 5 comes back
with a different `subject_id`, the failure this section describes is *a production archive sitting
behind a `users` row nobody can sign in as* — and with an email credential attached, that stops
being true: sign in by magic link, land on the same `users` row, and the new Apple subject attaches
to the account that already owns the archive. **The repair uses only shipped code.** Without the
pre-step, discovering the answer and losing the archive are the same event.

**Pre-step B — confirm Apple is actually configured to call us.** Step 3 below reads the log for a
server-to-server notification, and **nothing in this repository records that the Sign in with Apple
notification endpoint was ever registered with Apple** — it is a field on the Services ID / primary
App ID configuration in the Apple Developer portal, and it is set by hand. Check it before the run.
If it is unregistered, step 3 prints nothing, and **an unregistered webhook and a broken handler
look identical from the log side** — the experiment would report a code defect that does not exist.
`services/auth.py` and phase 53's nineteen tests all exercise the handler given a delivered
notification; none of them can tell you that Apple was told where to deliver it.

### The run

- [ ] **0.** Do pre-steps A and B above. Neither is optional: A is what makes a wrong answer
  survivable, B is what stops step 3 misreporting.

- [ ] **1.** Sign in on the device. Record `users.id` and `credentials.subject_id`:
  ```bash
  fly ssh console -a rascal-api -C "python -c \"
  import asyncio
  from sqlalchemy import text
  from rascal.db import get_sessionmaker
  async def m():
      async with get_sessionmaker()() as s:
          for r in (await s.execute(text('''select c.id, c.user_id, c.provider, c.subject_id,
              c.revoked_at from credentials c'''))).all():
              print(r)
  asyncio.run(m())\""
  ```
  `users.id` = ______________________  `subject_id` = ______________________

- [ ] **2.** Settings → Apple ID → Sign-In & Security → Sign in with Apple → find Vellum →
  **Stop Using Apple ID**.

- [ ] **3.** Confirm the webhook arrived. **Read it from the logs, not from the app UI** — the
  app cannot tell you whether the server heard anything.
  ```bash
  fly logs --app rascal-api | grep -i "apple credential revoked\|apple notification"
  ```
  What it printed: ______________________

  **If this prints nothing, do not conclude anything about the code until pre-step B is
  confirmed.** An endpoint Apple was never told about and a handler that does not run produce the
  identical silence here.

- [ ] **4.** Confirm `revoked_at` is set on the credential, and that every refresh token **for that
  user** is revoked. Re-run the query from step 1, and — **substituting the `users.id` you wrote
  down in step 1** — run:
  ```bash
  fly ssh console -a rascal-api -C "python -c \"
  import asyncio
  from sqlalchemy import text
  from rascal.db import get_sessionmaker
  USER_ID = 'PASTE_USER_ID_FROM_STEP_1'
  async def m():
      async with get_sessionmaker()() as s:
          print((await s.execute(text('''select count(*) from refresh_tokens
              where user_id = :u and revoked_at is null'''), {'u': USER_ID})).scalar())
  asyncio.run(m())\""
  ```
  Expect `0`. Got: ______

  > **The query was unscoped until Aug 22, 2026, and it would have failed a correct system.** It
  > read `select count(*) from refresh_tokens where revoked_at is null` across **every user**, but
  > `revoke_all_refresh_tokens` (`api/src/rascal/services/tokens.py:99-110`) revokes
  > `where RefreshToken.user_id == user_id` — per user, by design, because Apple told us about one
  > parent's consent and not about anybody else's. Any other live session in production makes the
  > count non-zero, **including the session belonging to whoever is running this checklist**, and
  > the step would then read as *"revocation did not work"* on a system where it worked perfectly.
  >
  > **The general shape: a verification query has to be scoped exactly as tightly as the behaviour
  > it verifies.** Wider is not safer — it is a different assertion, and here it is one the code
  > never promised and should never satisfy. `PASTE_USER_ID_FROM_STEP_1` is deliberately not valid
  > input: pasting this command unedited fails loudly rather than deploying a blank, which is the
  > rule §13 wrote down after a placeholder ellipsis reached Fly as a real secret value.

- [ ] **5. Sign in again, and confirm you land on the same `users.id`.** **This is the box the
  phase turns on.** Compare against what you wrote in step 1.
  Same `users.id`? ______  Same `subject_id`? ______  `revoked_at` cleared? ______

- [ ] **6.** Confirm the archive is still there — open the timeline and check the entry count
  is what it was before step 2.

**If step 5 shows a different `subject_id`**, stop. Do not adjust anything. Record what you saw
here and raise it: the recoverability design needs rethinking, and until it is rethought,
nothing should tell a parent that removing the app is reversible.

**"Stop" no longer means "and lose the archive", which is the whole point of pre-step A.** With an
email credential attached, sign in by magic link: that lands on the same `users` row, and the new
Apple subject attaches beside the email credential rather than founding a second account. The
archive is reachable again with shipped code and no migration. **Do that as recovery, not as
investigation** — write down both `subject_id` values first, because they are the finding, and the
repair overwrites the state that proves it.

**Not blocked on a credential.** This is on the list because it needs a physical device and a
real Apple ID, which is the same reason the twelve device-verification checklists are.

---

## §13 — The marketing site and the email provider: an **errand**, not a blocker (Aug 16, 2026)

D7, D8 and D8a settle where the landing page lives and who sends the mail. What they cannot settle
is a domain purchase, three vendor accounts and a repository audit — this file's original terms
exactly: a credential or an account only you have.

**None of this blocks anything currently in the queue**, and it is filed here for the same reason
§10 says it about StoreKit rather than as a warning. ~~**The marketing send is downstream of the P0
behavioural gate — seven days of unforced daily use — which has not started.** The page and the
`POST /v1/subscribe` endpoint may be built before any of this exists; only the *marketing send*
waits on it.~~ — **struck Aug 22, 2026 on the owner's call. The gate no longer gates marketing
email: the broadcast has been armed since Aug 19, 2026 and has sent on four consecutive days.** The
evidence is in *The broadcast is live* below. (Transactional mail is a separate question and was
never gated on P0 — phase 57's
magic-link path already sends, ~~or would if `MAIL_PROVIDER` were ever set~~ — **`MAIL_PROVIDER` is
`Deployed` and it does send**.)
Phase 60 is buildable today against a Turnstile test key and a Resend test key, and nothing about
it needs a domain.

### The errand, in order. Each step gates the next.

1. **Clear the name, then buy the domain.** Three checks before money changes hands, none of which
   exists anywhere in this repo today — **`decisions.md` open item 1 settled `Dogear` on Aug 12,
   2026 and recorded no clearance work at all, and the Aug 17, 2026 rename to `Vellum` recorded
   none either** (open item 15). **The rename made this step more urgent rather than resetting
   it**: *Vellum by 180g* is a live software trademark in a publishing-adjacent category, which
   is a nearer neighbour than anything Dogear had. Treat this as the first pass rather than a
   re-verification: the **social handle**, an **App Store search-collision check** for apps
   shipping under a similar name, and a **trademark search** in the classes an app would fall in.
   A name that fails any of these is cheaper to change now than after a domain, an App Store
   listing and a sending reputation are attached to it.
2. **Point DNS, then turn on the GitHub Pages custom domain and *Enforce HTTPS*.** Both settings
   live on the `Rascal-Marketing` repository. **Enforce HTTPS is the one to verify by eye rather
   than assume** — it cannot be enabled until the certificate is issued, so a domain pointed and
   configured in one sitting will often leave it off, and the page then serves happily over plain
   HTTP with nothing failing to draw attention to it. D7 already accepts that HSTS is unavailable
   on this host; this checkbox is the only transport protection left, and it is the whole of it.
3. **Create a free Cloudflare account and a Turnstile widget.** It yields a **site key** (public,
   goes in the page) and a **secret key** (server-side, becomes `TURNSTILE_SECRET_KEY`). Turnstile
   is host-independent, so this is unaffected by the site living on GitHub Pages. No paid plan and
   no DNS migration is involved — Cloudflare is not the CDN here, only the widget's issuer.
4. **Create the Resend account and authenticate a *sending subdomain*, never the apex**, then
   publish **SPF, DKIM and DMARC** on it. Sending from the apex ties the deliverability of a
   marketing send to every other use of the root domain, which is the failure a subdomain exists to
   contain. Resend issues the API key, and **it is filed as `MAIL_API_KEY`, not `RESEND_API_KEY`** —
   the setting is provider-agnostic because the port is (D8a), and `config.py` has carried that
   name since phase 56. **There is no `RESEND_API_KEY` and nothing reads one.** The secrets table
   in `runbook-deploy.md` is the authority on the name, and it records that phase 60 may rename it
   at no cost if you would rather it said Resend.
   - **The key currently in the local `.env` was pasted into a chat transcript and must be
     rotated.** It is inert either way until phase 60 builds the Resend provider — nothing reads
     it, and `MAIL_PROVIDER` remains `console` — but a key that has been through a transcript is
     not a key, and rotating it costs one click.
5. **Audit the `Rascal-Marketing` repository before it is public in earnest.** Three things, and
   the first is the one with a wrong instinct attached: **read the git history for anything ever
   committed and later deleted** — a deletion commit does not remove the object, and **a credential
   found this way is rotated, not rewritten out of history.** Then set the commit author to the
   GitHub **`noreply`** address, and check that no workflow runs with secrets on a pull request
   from a fork.
   - **`api/seeds/prompts.yaml` and `docs/mission-library.md` never enter that repository**, whole
     or in generated slices, per D7. A prompt sampler on the page is a hand-picked handful, typed
     in by hand. It is the one asset in this project a competitor would actually want, and a
     generated slice is how it would leave.

**Vendor menu wording is not verified here.** These steps name destinations rather than click
paths, on purpose and for the same reason §10 does it: vendor navigation changes, and a stale menu
path in a runbook is worse than a described destination. Nobody on this branch has a session with
Cloudflare, Resend, or a registrar.

### Every value this errand produces, and exactly where it goes (Aug 18, 2026)

Written because the steps above say *what to create* and stop short of *where the result lands*,
and the second half is where an errand stalls at a keyboard.

> ### ~~None of these is set~~ — **the errand ran on the evening of Aug 18, 2026. Six of seven values are deployed.**
>
> `fly secrets list --app rascal-api`, run Aug 19, 2026, shows all six marketing values **Deployed**:
> `MAIL_PROVIDER`, `MAIL_API_KEY`, `MAIL_FROM`, `TURNSTILE_SECRET_KEY`, `RESEND_AUDIENCE_ID` and
> `MARKETING_ORIGINS`. `MARKETING_EMAIL_ENABLED` is **absent, deliberately** — see below. Verified
> against the platform, not inferred from a commit.
>
> The domain is `getvellumapp.com`: registered, on GitHub Pages, HTTPS enforced, apex not project
> path. `mail.getvellumapp.com` is verified at Resend — a subdomain, never the apex, as step 5
> required. **The first real email this service has ever sent reached the owner's inbox**, not spam.
>
> So the paragraph this note replaces was true when written and became false within about two
> hours. The steps below are kept rather than struck, because the *order* is still the record of how
> it is done — and a future domain move repeats it.
>
> **`MARKETING_ORIGINS` was missing from the table entirely**, and it became load-bearing the moment
> the site moved to the apex: its default was the `github.io` origin, and the browser now sends
> `https://getvellumapp.com`. It holds both. A value-and-destination table that omits the one value
> CORS depends on is the table's own failure mode, not an oversight in the errand.
>
> **The site key is public by design and its being committed is correct, not a leak.** Cloudflare
> issues two: the *site* key belongs in markup where the browser can read it, and the *secret* key
> is the one `rascal-api` holds. `Rascal-Marketing`'s `site.js` already carries that explanation in
> a comment above the constant — read it there rather than re-deriving it, so the file and this page
> cannot drift into disagreeing about whether a committed key is a problem. Written here because a
> key visible in a public repo is exactly the shape that gets a security issue filed against a
> correct configuration.
>
> **The one thing that actually went wrong, and it was this file's fault.** Two of those secrets were
> set to placeholder text: `TURNSTILE_SECRET_KEY` held a literal ellipsis, and `RESEND_AUDIENCE_ID`
> held `…`, which surfaced as `/audiences/%E2%80%A6/contacts → 422` in a Fly log. The commands in the
> table below are written to be copy-pasteable **and** contain fill-in-the-blanks that are also valid
> shell, so pasting one verbatim succeeds and deploys the blank. Both are corrected.
>
> **The rule that follows, and it generalises past this page:** a runbook command meant to be pasted
> must not contain a placeholder that the shell will accept. Use an obviously-invalid marker that
> fails loudly — `PASTE_KEY_HERE` — or a `$VARIABLE` the shell refuses when unset. A quiet 422 in a
> log is the expensive version of a syntax error.

**Turnstile was the one step with no prerequisite.** It needed no domain and no DNS, which is why it
could be done in isolation — and it is what made the signup form stop saying *"signups are not open
yet."* Done: site key `0x4AAAAAAEUwlZkn4ah9zsvA` committed and deployed.

| # | What you create | Where the value goes |
|---|---|---|
| 1 | Cloudflare Turnstile widget → **site key** (public) | `Rascal-Marketing`, `src/assets/site.js`, `SIGNUP.TURNSTILE_SITE_KEY`. Then `npm run build && npm run check` and push |
| 2 | The same widget's **secret key** | `fly secrets set --app rascal-api TURNSTILE_SECRET_KEY='…'` |
| 3 | Resend API key — **full access, not `sending_access`**, because the contacts upsert needs more than send | `fly secrets set --app rascal-api MAIL_API_KEY='re_…'` — **the setting is `MAIL_API_KEY`, not `RESEND_API_KEY`; nothing reads the latter** |
| 4 | Resend **Audience** → its id | `fly secrets set --app rascal-api RESEND_AUDIENCE_ID='…'` |
| 5 | A verified **sending subdomain**, never the apex, with SPF/DKIM/DMARC | `fly secrets set --app rascal-api MAIL_FROM='Vellum <hello@mail.yourdomain>'` and `MAIL_PROVIDER=resend` |
| 6 | The domain itself | `Rascal-Marketing`, `site.config.json` → `DOMAIN` and `ORIGIN`. **`ORIGIN` is empty on purpose**; the moment it holds a real `https://` origin the build starts emitting canonicals, absolute OG URLs and `sitemap.xml` |
| 7 | GitHub Pages custom domain + **Enforce HTTPS** | Repository settings. **Verify the checkbox by eye** — it cannot be enabled until the certificate issues, so a domain configured in one sitting usually leaves it off, and the page then serves over plain HTTP with nothing drawing attention to it |

**Deliberately not in that table: `MARKETING_EMAIL_ENABLED`.** It is the switch that lets the daily
broadcast actually send, it defaults false, and it is kept separate from the credentials precisely
so that finishing the table above does not start mailing anybody. ~~Open item 12: **no marketing
email before the P0 behavioural gate**, which is seven days of unforced daily use and has not
started. When it is time: `fly secrets set --app rascal-api MARKETING_EMAIL_ENABLED=true`.~~ —
**that time came on Aug 19, 2026. The switch is on and the design worked exactly as written**: the
credentials landed on Aug 18 and mailed nobody, and a separate deliberate act armed the send a day
later. Keeping the flag out of the credentials table is why "the errand finished" and "we started
emailing people" were two events rather than one. **The evidence is in *The broadcast is live* at
the end of this section**; everything between here and there is the history of getting to it.

~~**Two things to do before that flag, in this order.** Exercise `POST /v1/subscribe` once from the
real GitHub Pages origin, which is the first test of CORS and of a genuine Turnstile verification —
neither has ever run against the deployed API. Then run
`python -m rascal.jobs.broadcast --date <a day> ` against an audience containing **only your own
address**, because the Resend Broadcasts API has never been called by this service and its
two-step create-then-send shape is implemented from documentation rather than observation.~~

**Struck Aug 22, 2026: this is history, not an instruction, and it was reading as one.** *"Before
that flag"* names a moment that passed on **Aug 19, 2026**, when `MARKETING_EMAIL_ENABLED` was set —
and its second half rests on a premise the paragraphs below it demolish: the Resend Broadcasts API
**has** been called by this service, four times, and its two-step create-then-send shape is observed
rather than documented — the four `resend_id`s in *The broadcast is live* are what came back. It is
kept in place because what each half was worth is the record of how the send was armed, and because
the second half's caution turned out to be unfalsifiable after the fact, which is its own lesson.
**With this struck, the one thing §13 still owes is at the end of this section: revoke the exposed
Resend key at Resend** — a click, no deploy, no code. (The contacts-scope question in *The broadcast
is live* is a diagnostic to run before anyone widens that key, not a thing owed.)

**Of those two, the first is done.** `POST /v1/subscribe` has now been exercised from the real origin
— that signup is what revealed that Resend's contacts API does **not** do double opt-in, which phase
88 then fixed. So CORS and a genuine Turnstile verification have both run against the deployed API
for the first time.

~~**The second has not, and the machine for it does not exist.** `fly machine list --app rascal-api`,
Aug 19, 2026, returns four: two `app` running uvicorn, one running `python -m rascal.jobs.scheduler`,
one running `python -m rascal.jobs.notify`. **There is no broadcast machine**, so §4d of
`runbook-deploy.md` is still accurate that it was never created. The broadcast dry run against an
audience containing only the owner's own address is therefore still ahead, and it remains the right
first call: the Resend Broadcasts API has never been invoked by this service, and its two-step
create-then-send shape is implemented from documentation rather than from observation.~~

**Struck Aug 22, 2026: the machine exists, and it was created on Aug 19 — the same day this
paragraph was written.** `683e1eea463d28` / `late-fire-837`, created **2026-08-19T02:15:36Z**,
running `python -m rascal.jobs.broadcast`. There are **five** machines now, not four. The Resend
Broadcasts API has been invoked four times and its two-step create-then-send shape is observed
rather than documented — the four `resend_id`s in *The broadcast is live* are what came back.

**Whether the dry run against a one-address audience actually happened first is not recorded
anywhere**, and this file cannot recover it: the earliest row in `email_broadcasts` is
`2026-08-19`, hours after the machine was created, and a dry run would have produced a row exactly
like a real one. **So the advice was taken or it was skipped, and the evidence does not
distinguish.** That is the cost of a caution written in prose with no artifact behind it, and it is
the reason to prefer a check that leaves a trace.

**One item on this page is still open, is not in the table, and got worse rather than better:** the
Resend key that went through a chat transcript and **has not been rotated** — confirmed by the owner
Aug 18, 2026.

The original entry excused it: *"It is inert (`MAIL_PROVIDER` is `console` and nothing reads it), but
a key that has been through a transcript is not a key. Rotate it before step 3 rather than after, so
the key that reaches Fly is the one that was never exposed."*

**That mitigation has expired.** `MAIL_PROVIDER` and `MAIL_API_KEY` are both `Deployed` on
`rascal-api` as of Aug 19, and the service has sent a real email through Resend — so the provider is
no longer `console`, something does read the key, and step 3 has already happened. The advice was
"rotate before step 3"; step 3 ran first.

**Answered by the owner, Aug 19, 2026: the key deployed on Fly is a new one.** It was minted during
the errand, so the exposed key never reached production. That was the question, and it was one only
the owner could answer — `fly secrets list` shows a digest and the value is write-only by design,
which is correct and also why this had to be asked rather than checked.

**One thing remains, and it is smaller than it was.** The exposed key is not in use anywhere, but it
is presumably still *valid* at Resend, and a valid key sitting in a chat transcript is a credential
with no owner. **Revoke it at Resend** — not because anything reads it, but because nothing should be
able to. No deploy, no secret to set, no code: it is a click in the Resend dashboard, and it closes
this item completely.

**The general shape is worth keeping even after this is closed.** A risk note that carries its own
mitigation — *"it is inert, so this is not urgent yet"* — has a shelf life measured by whether the
mitigation still holds, and nothing re-reads it on the day it stops holding. This one was written
about a `console` provider roughly two hours before the provider became `resend`.

### The broadcast is live, and that is intended (Aug 22, 2026)

**Owner's call, Aug 22, 2026: the P0 behavioural gate no longer gates marketing email.** Read from
Fly and from the production database rather than inferred from a commit:

- The machine exists. `683e1eea463d28` / `late-fire-837`, created **2026-08-19T02:15:36Z**, command
  `["python","-m","rascal.jobs.broadcast"]`, process group `(none)`.
- `MARKETING_EMAIL_ENABLED`, `MAIL_PROVIDER`, `MAIL_FROM` and `RESEND_AUDIENCE_ID` are all
  **Deployed** secrets on `rascal-api`.
- `email_broadcasts` holds **four rows, every one `status='sent'`** — none failed, none skipped:

  | send_date | pool_index | resend_id | sent_at |
  |---|---|---|---|
  | 2026-08-22 | 11 | `d9e6b965-c54c-406a-9fa0-b89fd5f5a512` | 12:15:05Z |
  | 2026-08-21 | 10 | `f3e802d5-f091-43e5-a66b-4772adae4223` | 12:15:06Z |
  | 2026-08-20 | 9  | `6f8ab6f3-e217-45bc-bbea-c4fe02ead438` | 12:15:07Z |
  | 2026-08-19 | 8  | `c4a32683-7972-4658-9710-300be51e407c` | 12:15:08Z |

- **The hourly wake is safe because the job checks its own hour, not because the machine is
  scheduled precisely.** Today's 13:15Z run logged
  `broadcast: not the send hour — it is 09:15 EDT, sending at 08:00.` and did nothing.

**One thing is not known, and it is written down as unknown rather than estimated.** `MAIL_API_KEY`
is send-scoped: `GET /audiences/{id}/contacts` answers **403** from inside the production machine.
So **how many people received those four emails, and who they are, cannot be determined from this
repository, from Fly, or from the production database.** Only the Resend dashboard can answer it.
**No recipient count appears anywhere in this file on purpose** — a plausible number written here
would be indistinguishable from a measured one a week from now, and this is the first thing this
service has ever sent to people who are not the owner.

**That the key cannot read the audience is worth noticing rather than quietly fixing.** Row 3 of
the table above specifies a **full-access** Resend key, *"not `sending_access`, because the contacts
upsert needs more than send"* — and the key actually deployed answers `403` to a contacts read. Two
readings fit and this phase settled neither: it may be a narrower key that still covers every call
the service makes, or a latent failure that the next contacts call will find. **Do not widen the
key on the strength of this paragraph.** The check that would decide it is one `POST /v1/subscribe`
against the deployed API and a look at whether the contact appears — cheap, and nobody has run it
since the key was deployed.

---

## §15 — The GitHub billing token: an **errand**, not a blocker (Aug 20, 2026)

`GITHUB_BILLING_TOKEN` is unset, so the Actions cost card renders `unconfigured` with a setup
sentence. **That is a working state and nothing is broken while it lasts** — which is why this is
an errand rather than a blocker. The other six cards are unaffected.

**What is needed:** a **fine-grained** personal access token on github.com → Settings → Developer
settings → Fine-grained tokens, with Account permissions → **Plan → Read-only** and nothing else.
Only the account owner can mint it. Then `flyctl secrets set -a rascal-api GITHUB_BILLING_TOKEN=…`.

**Two things make this easy to get wrong**, both documented in `runbook-admin-console.md`:

- The repo-scoped classic token CI already holds **will not work.** This endpoint reads the
  *account's plan*, which no amount of `repo` scope grants.
- **A token missing `Plan: read` answers 404, not 403.** A bare "not found" reads as a mistyped
  username and sends you checking `GITHUB_ACCOUNT`, which will not be the problem. The card says
  so on its face for this reason.

**Why this card exists at all:** §0 and §0a above are both *"GitHub Actions is not running —
account billing"*, and the second one recurred a day after the first was resolved. Neither was
visible anywhere until CI simply stopped. This is the instrument that was missing. **It cannot
warn before a halt** — the API exposes no budget or quota, and the card says that too — but a
dollar figure that moves is better than the nothing there was before.

**Re-verified Aug 22, 2026: unchanged and still correct.** `GITHUB_BILLING_TOKEN` is confirmed
absent from `flyctl secrets list -a rascal-api`. The code path is built, tested, and degrades to an
`unconfigured` card, so nothing here needs writing — this note exists to record that somebody
looked, and when. **A section marked correct with a date is more useful than a section nobody has
touched**, because "unchanged" and "unread" are indistinguishable otherwise.

**When it is minted, read the second bullet above before reading anything else.** A token missing
`Plan: read` answers **404, not 403** — a bare "not found" reads as a mistyped account name and
sends you checking `GITHUB_ACCOUNT`, which will not be the problem. **That line was already in this
section and needed no addition**, which is worth saying rather than quietly adding a duplicate: the
phase 111 review flagged it as missing, and it was not.

---

## §16 — App Store Connect: **deferred**, and deliberately not requested yet (Aug 20, 2026)

~~Not blocked, because nothing is waiting on it.~~ — **true of the reporting key and only the
reporting key. Qualified Aug 22, 2026**: a second App Store Connect key, for uploading builds, is
owed now and a CI-driven TestFlight upload is waiting on it. See *Two different App Store Connect
keys* below. Recorded here so the credential requirement lives
where credential requirements live, and so the next person costing this out does not rediscover it.

> **`docs/phase-queue.md` said phase 37b's purchase proof "waits on §10a and §16", and it did
> not.** It waits on §10 — the Paid Applications agreement and the two products — and on a
> TestFlight build. §10a's remaining item gates *Production* notification verification, not a
> sandbox purchase, and this section's reporting key gated nothing at all. **Corrected in
> `phase-queue.md` on Aug 22, 2026 by phase 111**, and noted here because the wrong pointer was
> aimed at *this* section: a section whose own first line said nothing was waiting on it was named
> as a blocker by another document for two days, and neither page could see the other.

**Nothing App Store Connect can report before launch is a cost.** Revenue, proceeds, downloads,
impressions and conversion are all built from public App Store activity, and an app that has
never been released has none. `GET /v1/salesReports` requires at least one unit sold and answers
404 on an empty period. App Analytics needs an Admin-role `POST /v1/analyticsReportRequests` and
then one to two days before the first report exists — there is no same-day answer even after
launch. The API is free to call and publishes no billing endpoint at all, so the Apple card
carries the Developer Program membership and an honest sentence instead.

**What a future phase would need**, when TestFlight build state and tester counts go on the *Ops*
panel rather than this one:

- A `.p8` EC private key, its key id, and the issuer id — three new secrets.
- A **team** key. Individual keys cannot reach Sales and Finance.
- ES256 JWT signing with `aud: "appstoreconnect-v1"` and a ≤20-minute lifetime. **No new
  dependency:** `pyjwt[crypto]` is already installed and `services/push.py` already signs an
  ES256 provider token from a `.p8`, cached against its expiry. That is the pattern to copy.

**Not worth requesting until there is an app on the store**, since the data would be empty.

### Two different App Store Connect keys, and only one of them is deferred (Aug 22, 2026)

**This section was about a reporting key and said so nowhere.** Everything above concerns a **team**
key with **Sales and Finance** access, for revenue reporting — and that deferral stands exactly as
written: `GET /v1/salesReports` 404s on an empty period, App Analytics needs one to two days after
launch before a first report exists, and there is nothing to read until an app is on the store.

**A second, different key is owed now, for an unrelated reason, and this section never mentioned
it.** `.github/workflows/ios.yml` is **test-only** — it selects an Xcode, picks a simulator, runs
`xcodebuild test`, greps the log for new warnings, and uploads the log as an artifact. There is no
`archive` step and no upload step, so **CI cannot ship a TestFlight build at all.** That needs a
**build-upload** key, which is a completely different grant from Sales and Finance.

**Owner's call, Aug 22, 2026: mint the upload-only key now, defer the Sales and Finance key until
after launch.**

**The reason it is two keys rather than one wide one is that a key's access is fixed at
generation.** App Store Connect does not let you narrow or widen an existing key — changing access
means revoke and regenerate, and a revoke breaks whatever is already signing with it. So the
choices are one broad key today, minted for a reporting job that has no data to report and would
sit in CI holding Sales and Finance access for months, or two narrow keys minted when each is
actually needed. **This is the least-privilege choice and it costs a second errand during launch
week** — that cost is real and is accepted deliberately, not overlooked.

**What the upload key needs** is the same three-secret shape the reporting key would: a `.p8` EC
private key, its key id, and the issuer id. The ES256 signing pattern above is unchanged and is
still `services/push.py`'s. **Which role to pick is not settled here** — pick the narrowest one App
Store Connect offers that can upload a build, read it off Apple's own access list at generation
time rather than from this page, and **write down which one was chosen**, because it cannot be
changed afterwards and the next person will need to know what the key can and cannot do.

---

## §18 — the Instagram token expires, and ~~two repositories hold a copy~~ **only one does** — the clause struck Aug 22, 2026 so the heading says what the body already says

> **Renumbered from §17 on Aug 21, 2026.** It was filed as a second §17 on Aug 20 — two sections
> on this page carried the same number for a day. ~~Nothing anywhere referenced this one, so the
> collision was cheap to close by moving it~~ — **that was wrong, and it was wrong on the day it
> was written. Corrected Aug 22, 2026.** `.env.example` referenced it, in a comment added by the
> *same commit* that created the section; the renumbering in `a94d6f7` moved the heading and left
> the pointer aimed at §17, which by then was the resolved Gemini section. So for a day the one
> cross-reference that existed pointed a reader at the wrong entry. It reads §18 now.
>
> **The renumbering itself was correct and is not being undone** — the Gemini §17 above keeps its
> number because `roadmap-status.md` points at it, and one inbound link beats none. What was wrong
> was the *justification*: "nothing references this" was asserted rather than grepped, and the
> reference was two files away in the same commit. **A claim about inbound links is a `grep -rn`,
> and it takes about four seconds.**
>
> This is not the phase-number rule in `CLAUDE.md` — collisions
> at 3, 11, 19 and 20 stay exactly as they are, because those are identifiers with history
> attached. A section heading a day old with no inbound links is not.

**Blocked on nobody; this is a diary entry with a date on it.** `IG_ACCESS_TOKEN` is a
long-lived Instagram token, which Meta issues for about sixty days. The only real timestamp
either repository has is the creation time of the `Rascal-Marketing` Actions secret —
**2026-08-20T00:57:19Z** — which puts the lapse at roughly **2026-10-19**.

**Nothing refreshes it and nothing warns.** The first sign will be a failed publish with an auth
error: `OAuthException 190`. On this side that surfaces as `publish_failed` carrying Meta's own
sentence; on the marketing side it is a red workflow run.

~~**Two stores hold the same credential and both must be updated in one sitting** — this service's
Fly secrets and `.env`, and the marketing repository's Actions secrets. Refreshing one leaves the
other posting to the same account with a dead token.~~ — **wrong about this service, corrected
Aug 22, 2026. It is a one-store errand.**

**The complete production secret list on `rascal-api`, read today**, is:

```
ANTHROPIC_API_KEY APNS_KEY_ID APNS_PRIVATE_KEY APNS_TEAM_ID APPLE_BUNDLE_ID
AWS_ACCESS_KEY_ID AWS_SECRET_ACCESS_KEY DATABASE_URL DIRECT_DATABASE_URL FLY_API_TOKEN
GOOGLE_CLIENT_IDS JWT_SECRET MAIL_API_KEY MAIL_FROM MAIL_PROVIDER MARKETING_EMAIL_ENABLED
MARKETING_ORIGINS NAME NEON_API_KEY NEON_PROJECT_ID RESEND_AUDIENCE_ID S3_BUCKET
TURNSTILE_SECRET_KEY
```

**No `IG_ACCESS_TOKEN`, no `IG_USER_ID`, no `SOCIAL_PUBLISH_ENABLED`**, and none of the five
machines on `rascal-api` is a social publisher. So the API-lane publisher — `routers/social.py`,
`jobs/social.py`, `services/social/publishing.py`, `services/social/instagram.py` — **has never
been armed in production**. Only the marketing repository's Actions secrets hold a live copy.

**That lowers this section's urgency, and it is the honest reading rather than a technicality.**
The refresh around **2026-10-19** is one store, not two, and the failure it prevents is one red
workflow run rather than two pipelines posting with a dead token. **If the API-lane publisher is
ever armed, this becomes a two-store errand again and this paragraph is the thing to un-strike** —
which is the reason it is struck in place rather than deleted.

What would close this: a refresh, and a note here with the new date. Automating it is worth its
own phase and is not this one — a calendar reminder and a written date beat a half-built
refresher that nobody checks.

**Where else this needed saying, and one of them is the document somebody would have open at the
time.** `.env.example:307` pointed at "§17" until Aug 22, 2026 and now points here. And
`docs/runbook-deploy.md` — **the one page a person reads while doing a deploy or a secret
rotation** — described a scheduled social machine that is not deployed and did not mention
`IG_ACCESS_TOKEN` at all, so the lapse date and the `OAuthException 190` symptom lived only on this
page. Both are being corrected in phase 111. **A credential with an expiry date belongs in the
runbook, not only in the blocked list**, because the blocked list is read when somebody is looking
for what is stuck and the runbook is read when somebody is holding the keyboard.

**Not yet known: which permission the token actually carries.** `docs/social-setup-checklist.md`
in the marketing repository records that scopes were confirmed in Meta's Access Token Debugger
but never names them, and neither session can read them from here. The Debugger at
`developers.facebook.com/tools/debug/accesstoken/` shows the list in seconds; whether the Meta
app needed review is a question only the owner can answer.

**Also unverified: whether `alt_text` lands.** Both pipelines send it on the container and Meta
accepts it without complaint, but nobody has opened the Instagram app and looked at a post's
accessibility info. Meta ignores that field on some flows. Worth checking on the first real post
from here, and telling the marketing session either way — it has been shipping the field for a
day with no evidence it does anything.

## §19 — The paywall has no Terms and no Privacy link, and it is **two lines in a gitignored file** (Aug 22, 2026)

> **Status, Aug 26, 2026 (phase 124): done on one machine, and that is not the same as done.** Both
> keys are now in `ios/Rascal/Config.xcconfig` on the primary checkout with the `$()` split intact,
> so both links render here and `SubmissionComplianceTests.theLegalURLsResolveInThisBuild` **resolves
> them at runtime rather than grepping for them** — the one assertion in that suite that reads
> `Bundle.main` instead of source text, added because every other test in it passes happily on a
> machine with neither key set. **The file is gitignored
> and machine-local, so this does not travel**: whatever machine cuts the TestFlight archive needs
> the same two lines, and a fresh clone still has neither. **CI was never the gap** — `ios.yml`
> copies `Config.xcconfig.example`, which has carried both values correctly since **phase 37b**
> (`b7a45e3`, Aug 20, 2026; the file's own section header reads *"-- Legal links on the paywall
> (phase 37b) --"*, and `git log -S TERMS_URL` on it returns that one commit).
> **Left open deliberately** until the archiving machine is confirmed, because the failure mode this
> section exists for is a build that renders no links and looks perfectly fine.
>
> **The Terms URL was contested and is now settled, by reading the page rather than the brief.**
> §19 prescribes `TERMS_URL = https://getvellumapp.com/terms`; phase 124's brief prescribes **Apple's
> standard EULA** instead, on the stated ground that *"the current /terms page covers the marketing
> site and waitlist only and explicitly states the app has no terms yet."* **That premise is stale.**
> `https://getvellumapp.com/terms`, read in a browser on Aug 26, 2026, is a full app-and-subscription
> agreement last updated **Aug 25, 2026**. It carries, in its own words, *"Membership, and what it
> costs — $59.99 a year, or $5.99 a month. Both are auto-renewing subscriptions"*, a *Cancelling*
> section naming the Apple Account path, the free tier, the export, and account closure.
>
> **So §19's value is right and the brief's recommendation is superseded.** The page answers
> guideline 3.1.2 better than the standard EULA would, because it names the subscription, its term,
> its price and its renewal in prose a reviewer can check against the paywall. `/privacy` is live and
> current on the same date. **No change to make; recorded so the next reader does not re-open it.**

**An errand, not an engineering problem — and the one entry here that is a Review rejection rather
than a delay.** Found by phase 108 and independently confirmed by phase 110.

`Info.plist:154-157` and `Info-Debug.plist:136-139` both map `$(TERMS_URL)` and `$(PRIVACY_URL)`
through to the bundle. **`ios/Rascal/Config.xcconfig` defines neither key.** Not empty — absent. So
both expand to the empty string, `LegalLinks` returns `nil` at its `!trimmed.isEmpty` guard, and the
paywall renders **no Terms of Use link and no Privacy Policy link at all.**

**App Review Guideline 3.1.2 requires both on any screen selling a subscription.** A submission today
is rejected.

**Why nothing caught it, which is the part worth carrying:**

- The behaviour is *correct*. `LegalLinks` is written to render an absent link rather than a dead one
  — the xcconfig `//` trap truncates `https://getvellumapp.com/terms` to `https:`, which
  `URL(string:)` happily accepts, so the host check exists on purpose and **must not be relaxed.**
  Nothing crashes and nothing looks broken.
- `SubscriptionTests.swift:938-946` pins the half that is in the repository — both `Info.plist` files
  carry the keys — and **says in terms that it cannot detect this half**, because `Config.xcconfig`
  is gitignored and no test can see whether a developer copied the keys across.
- It is visible in the committed renders as blank space under *"Restore a purchase"*. Nobody looked
  until phase 110 read the PNGs rather than the code.

**What is needed, and it is yours because the file is gitignored and machine-local:**

```
TERMS_URL = https:$()/$()/getvellumapp.com/terms
PRIVACY_URL = https:$()/$()/getvellumapp.com/privacy
```

**The `$()` split is not decoration** — `//` starts a comment in xcconfig, so a literal `https://`
written inline is silently truncated. `Config.xcconfig.example:93-94` already carries both keys with
the right values; copying them across is the whole task.

**Depends on §16** only in that the pages must exist at those URLs before submission; the marketing
site is building them. **Nothing in either lane's code changes.** Recorded here rather than fixed
because setting build variables is a signing-and-config change, which every phase this week has been
explicitly scoped out of.

---

## §20 — The deletion job has no machine, so nobody who asks to be forgotten is (Aug 22, 2026)

**Blocked on nobody.** No credential, no vendor account, no decision. It is one `fly machine run`
that has not been typed, and it is filed here because it is the only entry on this page where the
gap is a **promise the service is currently breaking** rather than work not yet started.

**What is built, and it is all of it.** `api/src/rascal/jobs/delete.py` exists and is finished —
`python -m rascal.jobs.delete`, with a `--dry-run` that lists what is due and touches nothing,
delegating to `services/deletion.py`'s `run_due_deletions`. `api/tests/test_deletion.py` covers it.
`POST` and `DELETE /v1/me/deletion` are live, the `deletion_requests` table is migrated, and
phase 67 shipped the Settings card and `DeleteAccountSheet` that reach them. The runbook has a
section for the machine — `docs/runbook-deploy.md` §4c — with the exact invocation, added Aug 18,
2026.

**What is not deployed: the machine.** Read today, Aug 22, 2026, `flyctl machines list -a
rascal-api` returns **five**, and none of them is it:

| Name | Schedule | Command |
|---|---|---|
| `patient-wood-1946` | *(none)* | the API itself |
| `delicate-wind-1252` | *(none)* | the API itself |
| `divine-hill-1816` | hourly | `python -m rascal.jobs.scheduler` |
| `throbbing-water-1063` | hourly | `python -m rascal.jobs.notify` |
| `late-fire-837` | hourly | `python -m rascal.jobs.broadcast` |

**So a `deletion_requests` row sits out its seven days and then sits there.** `execute_after`
passes, the request stays pending because nothing wakes up to read it, and **the API stays green
throughout** — there is no failing check, no error rate, no log line, because the failure is the
absence of a process rather than a fault in one. That is why it has gone unnoticed on this page
since the job shipped: phase 66 landed `jobs/delete.py` on Aug 17, 2026 — **five days ago as this
is written** — and every artifact since has described a system that is not running.

**Why this one is worse than a missed notification, and it is not a matter of degree.** `CLAUDE.md`
rule 5 makes account deletion **the single deliberate exception** to soft-delete in this entire
service — *"account deletion hard-deletes … because a soft delete on an erasure would be the
service keeping exactly what it was asked to stop keeping."* The exception was argued for and
written down **so that the data would actually be destroyed.** With no machine, the erasure never
runs, and the exception buys nothing: the row is neither soft-deleted nor hard-deleted, it is
pending. **The one rule this service broke on purpose is currently not being kept either way.**
Apple's in-app-deletion requirement (decisions.md item 14) is satisfied by a button that files a
request; it is not satisfied by a request nobody executes.

**What to do, and it is the whole task:** run `docs/runbook-deploy.md` §4c's command against the
currently deployed image, then `python -m rascal.jobs.delete --dry-run` once on the machine to see
what is already due before anything is destroyed. **`--schedule daily` is sufficient** — the job
takes its deadline from each row's `execute_after`, so a late run deletes what was due and an early
one deletes nothing, and every run is idempotent because a completed request has no row left.

**Two things to know before running it.** `--dry-run` first is not ceremony: this is the only job
in the service that destroys user data, and anything that has been waiting since Aug 17 will go on
the first real pass. And §5 of the runbook applies the moment the machine exists — a scheduled
machine is **not** updated by `fly deploy`, so it will keep running whatever image it was created
against until somebody moves it, which is the trap §4b was written about.

**Not a new finding, and that is the part worth recording.** `docs/runbook-deploy.md` §4d's machine
inventory already says in terms that there is *"no `python -m rascal.jobs.delete` machine"*, and
`docs/phase-queue.md` carries it as a follow-up. **It has never been on this page**, which is the
page whose job is to be read for what is not done — so the one document an operator opens to ask
*"what is outstanding"* was the one document that did not say it. Filed here now; the other two
already have it and neither is this lane's to edit.

---

## §21 — `is_payer` is unknown in exactly the households where the question means something (Aug 22, 2026)

**Blocked on a client change, not on a credential, a vendor or a decision.** Filed by phase 113,
which shipped `is_payer` on `FamilyOut` and can answer it honestly for one-guardian households and
not at all for two-guardian ones.

**The shape of the gap.** `entitlements.payer_user_id` exists and reaches the wire as
`is_payer: bool | null`, computed for the calling user by `services/guardians.is_payer_for`.
`services/app_store_events._set_payer` writes the column **only when the household has exactly one
guardian at the moment of purchase** — and that is correct rather than lazy. Apple's notification
carries `appAccountToken`, the client obligation pins it to the purchasing user's **`family_id`**
(`api-contract.md`, *The client obligation*), and a family id does not name a person. With one
guardian there is only one candidate. With two there is no way to tell from anything Apple sends,
and a wrong payer is worse than a null one: D3a's win-back writes to the payer, so a guess means
emailing the wrong parent about the other one's cancelled card.

**So the field is null in precisely the case it exists for.** A one-guardian household trivially
has a payer and does not need to be told; a two-guardian household is the only one where "are you
the one paying for this" is a real question, and that is the one the server cannot answer.

**Two extensions were considered and both are unsound. Recording them so they are not re-proposed:**

1. **Call `_set_payer` on `DID_RENEW` too, when the household now has one guardian.** Guardians A
   and B; B purchases, so the column is correctly null; B later leaves; a year on `DID_RENEW`
   arrives and this rule writes **A**, who has never paid for anything. `is_payer` then reads
   `true` for A and the win-back emails A about B's card — the exact failure `_set_payer` exists to
   prevent, arriving through a different door.
2. **Restrict that to households that have only *ever* had one member.** **Not expressible in this
   schema.** `guardians` is keyed `(user_id, child_id)` and has no `family_id`; household
   membership is `users.family_id`, and a user who leaves simply has that column point elsewhere.
   There is no membership history and no tombstone, so "has this family ever had a second member"
   cannot be asked. The one-guardian inference is sound *only* at purchase time, which is exactly
   where it is already applied.

Also worth stating: a resubscribe does **not** arrive as `DID_RENEW` — Apple sends `SUBSCRIBED`
with subtype `RESUBSCRIBE`, so that path already reaches `_set_payer` (`constants.py` says so on
`PROMOTING_NOTIFICATIONS`). And the household `runbook-deploy.md` §7a wrote `subscribed` by hand
can never be fixed by webhook code at all, because no notification exists for it.

**The only real fix, and it is an iOS-lane phase with a contract change.** The client knows who is
tapping Purchase; the server never will. It would need a request field carrying the purchasing
**user** id — or an `appAccountToken` scheme that encodes a user rather than a household, which
would break the existing attribution path and is the worse of the two. Either is a new field in
`api-contract.md` plus a change to `SubscriptionStore.purchase(_:familyID:)`, whose `familyID`
argument is currently non-optional and pinned by two tests. **It is not a drive-by**, it fixes
nothing retroactively for purchases already made, and nobody has asked for it.

**Nothing is broken while it stays null, and that is why this is filed rather than fixed.** Phase
112 treats `null` as *don't know, show the control*, so a paying parent always reaches Apple's
subscription-management sheet. The failure direction is deliberate and matches standing rule D9:
**`is_payer` must never be `false` on a null.** Shipping `false` on a guess would hide the
management control from somebody who is paying, which is the one outcome worse than saying nothing.

---

## §22 — three Fly secrets nothing reads, and only you can unset them (Aug 25, 2026)

**Blocked on you, and it is the shortest errand on this page.** Phase 120 (`01318be`, PR #170)
deleted every reader of `GEMINI_API_KEY`, `GEMINI_VIDEO_MODEL` and `GEMINI_VIDEO_CENTS_PER_SECOND`:
`config.py` no longer declares them (`grep -n -i gemini api/src/rascal/config.py` returns nothing),
`.env.example` no longer lists them, and `services/social/gemini.py` is gone. **Removing them from
Fly is a separate manual act and this lane cannot do it:**

```bash
flyctl secrets unset GEMINI_API_KEY GEMINI_VIDEO_MODEL GEMINI_VIDEO_CENTS_PER_SECOND -a rascal-api
```

**Nothing breaks either way, which is exactly why it will be forgotten.** A secret no process reads
is not an outage; it is a live Google API key sitting in a production machine's environment for no
reason, and the only two records that it is dead are a comment in `.env.example` (:183-185) and a
paragraph in `docs/reports/phase-120-canvas-video.md` (:179-181). **Phase 120 named the act in its
own report rather than filing it here**, which is the same failure §20 was filed for three days
earlier: the one document an operator opens to ask *what is outstanding* was the one document that
did not say it.

**Read before you unset, because this page already contains evidence it may be a no-op.** §18's
complete production secret list on `rascal-api`, read in full on Aug 22, 2026 and reproduced there
verbatim, contains **no `GEMINI_*` name at all**. So either the key was never a Fly secret on
`rascal-api` — in which case this closes on one `flyctl secrets list -a rascal-api` and never
needed the unset — or §18's list was incomplete, which is worth knowing about **§18** as much as
about this. Run the list first and record which of the two it was; `CLAUDE.md` puts anything
blocked on a credential on this page, and *"we checked and there was nothing there"* is a result
this page should carry rather than a reason to have written nothing.

---

## §23 — `hello@getvellumapp.com`: the DNS half is already done, and **only you can say whether the mailbox exists** (Aug 25, 2026)

**Filed because phase 126's brief named this as an owner errand and stated the reason wrongly.**
The brief's words are *"the domain currently has no mail routing."* It has mail routing. Read off
the public DNS on Aug 25, 2026:

```
$ dig +short MX getvellumapp.com
10 mx01.mail.icloud.com.
10 mx02.mail.icloud.com.

$ dig +short TXT getvellumapp.com
"v=spf1 include:icloud.com ~all"
"apple-domain=0LNvcg0C9dw02kIC"

$ dig +short TXT _dmarc.getvellumapp.com
"v=DMARC1; p=quarantine; adkim=r; aspf=r; rua=mailto:dmarc_rua@onsecureserver.net;"
```

That is **iCloud Custom Email Domain**, fully provisioned: Apple's two inbound exchangers, the
`apple-domain=` verification record Apple requires before it will accept the domain, an SPF record
authorising iCloud to send as it, and a DMARC policy at `p=quarantine`. The nameservers are
GoDaddy's (`ns23/ns24.domaincontrol.com`), which matches the brief's guess at *where* the work would
be done — it just does not need doing.

### What is actually unresolved, and why it is still yours

**MX records route a domain. They do not create an address.** iCloud Custom Email Domain requires
each address to be created explicitly in iCloud settings, and mail to an address that has not been
created is rejected by Apple rather than delivered. So the open question is not routing, it is:

1. **Does `hello@` exist as an address or alias on that domain?**
2. **Does a message sent to it from an unrelated account actually arrive somewhere you read?**

Neither is answerable from this repository, from DNS, or from any machine this lane can reach — it
needs a signed-in iCloud session and an inbox. **The test is one email.** Send to
`hello@getvellumapp.com` from an address on a different provider and see whether it lands or
bounces; record which here, because *"we checked and it works"* is a result this page should carry.

### Why it blocks submission

App Review reaches the support contact. If the address bounces, the reviewer finds a dead support
channel on a paid subscription app, which is a rejection under 1.5 rather than a cosmetic gap.

**One claim in the brief could not be checked from here and is not repeated as fact.** It says both
legal pages point at this address. The legal pages live in `travist6983/Rascal-Marketing`, not in
this repository, and `hello@getvellumapp.com` appears nowhere in this tree except phase 126's own
brief — so whether `/terms` and `/privacy` publish that address is unverified from this lane. See
**§13**, which owns the marketing site.

### One thing to know before Resend sends from this domain

**The SPF record above authorises iCloud and nothing else**, and DMARC is at `p=quarantine` with
relaxed alignment. **§13 step 5 already calls for a verified sending *subdomain*, never the apex**,
and today neither `mail.getvellumapp.com` nor `send.getvellumapp.com` has any record at all
(`dig +short MX mail.getvellumapp.com` returns nothing). That separation is what keeps this section
and §13 from colliding: **receiving at the apex through iCloud and sending from a subdomain through
Resend are two independent setups**, and adding Resend's records to the apex instead would put a
second sender under a DMARC policy written for one. Nothing here needs doing today; it is written
down so the day §13's step 5 is worked, nobody points it at the apex.

---

## §24 — There is no Sign in with Apple key, so the revocation phase 127 built cannot fire (Aug 25, 2026)

**This is an errand, not a blocker.** Apple Developer enrollment is resolved (§1), so the key can
be created today; it simply never has been. Phase 127 shipped the whole revocation path against a
local `MockTransport` and **it has never spoken to Apple**, because there is nothing to sign a
`client_secret` with.

### Why it matters

Guideline **5.1.1(v)** requires an app offering Sign in with Apple to call Apple's REST
token-revocation endpoint as part of deleting an account. Until this is done, every erasure logs

```
ERROR  cannot revoke a sign in with apple credential: no key is configured.
       The account is still being deleted. See docs/blocked.md section 24.
```

and the account is still deleted. **That degradation is deliberate** — a parent who asked to be
erased and was not, because a key was missing, is by far the worse failure — but it means the
compliance obligation is currently unmet on a path that reports success.

### The errand

1. Apple Developer portal → **Certificates, Identifiers & Profiles** → **Keys** → **+**.
2. Name it something like `Rascal Sign in with Apple`, tick **Sign in with Apple**, and configure
   it against the primary App ID. **This is a different capability from the APNs key in §1** — an
   APNs key cannot sign for this and the reverse is also true.
3. Download the `.p8`. Apple lets you download it **once**.
4. Note the **Key ID** shown beside it. The Team ID is already in `config.py` and is not secret.
5. Set three Fly secrets — `APPLE_SIWA_PRIVATE_KEY` is the *contents* of the `.p8`, newlines and
   `BEGIN`/`END` lines intact, exactly like `APNS_PRIVATE_KEY`:

   ```
   flyctl secrets set -a rascal-api \
     APPLE_SIWA_KEY_ID=... \
     APPLE_SIWA_CLIENT_ID=com.travisterry.childarchive \
     APPLE_SIWA_PRIVATE_KEY="$(cat AuthKey_XXXXXXXX.p8)"
   ```

   All three or none: a partial set reads as unconfigured, on purpose, because *"nearly working"*
   hides which piece is missing.

### The other half, and it is a separate errand

**Nothing in this repository shows the Sign in with Apple server-to-server notification endpoint
was ever registered with Apple** — §11's pre-step B has said so since Aug 16, 2026 and it is still
true. The handler has existed since phase 53 with twenty tests, so what those tests prove is that
a *delivered* notification is handled correctly, and nothing at all about delivery.

The URL Apple must be given, which appears nowhere else in this tree as a pasteable value:

```
https://rascal-api.fly.dev/v1/webhooks/apple-signin
```

Developer portal → **Identifiers** → the App ID → **Sign in with Apple** → **Edit** → *Server to
Server Notification Endpoint*. **Apple will not send `account-delete` until this is set.**

### How to know it worked, and it is the only proof

**Delete a test account, then look at that device's Settings → Apple Account → Sign in with Apple.**
The app should no longer be listed. This is the check Apple's reviewer can perform and the only
evidence revocation actually happened — the logs prove the call was *attempted*, which is a
different claim.

**Do this before touching §11's `sub`-stability experiment**, not after. §11 asks what Apple
returns for `sub` after a revoke-and-reauthorize, and until then this repository's answer is to
avoid depending on it: phase 127 revokes at *execution* rather than at request time specifically so
that a parent who changes their mind during the seven days never has to re-consent. If §11 ever
resolves that `sub` is stable, revoking earlier becomes available; it is not worth doing on an
assumption.

## §25 — A sandbox-blocked App Store notification is invisible everywhere except a log line (Aug 28, 2026)

**Not a defect in Guard 3.** `may_write_tier` correctly refuses to let a Sandbox notification touch
a production entitlement — the docstring's reasoning stands: *"a Sandbox tester account is free to
create, so treating its notifications as real would let anybody subscribe a production household by
buying nothing."* This section is about what happens **after** the guard fires correctly, which is
nothing a person can see without SSHing into the machine and reading a table by hand.

**How this cost an evening, on Aug 27–28, 2026.** A TestFlight purchase was made against a real
household. `AppStore.sync()` succeeded on the device. The App Store card in Settings kept reading
*Free*. Every plausible cause was checked in the wrong order — whether the sandbox tester was
configured (it was, and irrelevant: TestFlight bills the tester who redeemed the invite, not the
device's Sandbox Apple Account), whether the products existed in App Store Connect (they did),
whether `APP_STORE_APP_APPLE_ID` was set (it was, and §10a item 2 above said otherwise until this
was found) — before landing on the actual answer: the notification arrived, verified, resolved to
the right family, and was correctly discarded by Guard 3, three steps before any of that would have
shown up anywhere a person looks.

**What exists today:** `log.warning("sandbox notification recorded without touching tier", …)` in
`app_store_events.py`, and the row itself in `app_store_transactions` with `family_id = NULL`.
Neither is reachable without `flyctl logs` or a hand-written query — not the app, not the admin
console, not this file until now.

**What would have answered the question in seconds instead of an evening:** one line on the admin
console's cost or families panel — *"N unattributed Sandbox transactions"* — or a `GET` route
that lists `app_store_transactions` rows where `family_id IS NULL`. Either makes the state Guard 3
produces something a person can see without a database credential.

**Not filed as blocking anything.** Guard 3 is correct and stays exactly as written. This is an
observability gap, not a bug, and it is the kind of gap this repository is worst at catching —
nothing goes red while it is missing, per the pattern §12 above already named for the deletion
machine.
