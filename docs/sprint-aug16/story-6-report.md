# Story 6 — report

**HALTED — Gate 2 — `docs/blocked.md` contradicts this story's P1. Reporting both sides, as the
gate instructs.**

> **Resolved the next day, and the halt was right. Annotated Aug 18, 2026.** The work shipped as
> **phase 16** on Aug 17 (`b5eaa1c`, PR #116). **Both sides of the contradiction this report
> refused to pick between turned out to be wrong**, which is the vindication of halting rather than
> guessing: the story assumed a video's audio had to be exported to a separate m4a first, and
> `blocked.md` assumed the device checklist was the gate. A diagnostic settled it — `AVAudioFile`
> opens an mp4 and reads the AAC track straight out of the container, so there was no second input
> path to verify and no checklist to wait on. **The halt cost a day; picking either side would have
> shipped machinery for a problem that does not exist.** Kept as written, because a report that
> refused to invent an answer is the record worth having.

No code written. No documentation commit. No PR. No checklist box touched. Tree clean except this report.

**Stated in its own sentence, as the story requires: §0 was *not* recorded, no box was ticked, and
no device-verification file was modified.**

---

## Gate 2 — both sides

### The side that supports this story

`docs/blocked.md:1206`, the Phase 16 section, rewritten Aug 16, 2026 — **merged, and it corroborates
story 6's premise exactly.** This is the first story this sprint whose central claim checks out
against a document on `main`:

> **The transcriber works, and it has been seen working.** Owner, Aug 16, 2026: `SpeechAnalyzer` has
> produced a real transcription on a real device, on a build from that day, and the output was
> accurate enough to capture his son's actual pronunciation of words.

and:

> The original reasoning… building video transcription on an unverified transcriber stacks two
> unknowns in one branch… That argument has not been refuted — **it has been satisfied**.

**So phase 16's block is genuinely lifted, by a merged document.** That part of the story is sound
and I am not disputing it.

### The side that contradicts it

The same section, four paragraphs earlier:

> **Nobody but the owner may tick those boxes.** This section was written by an agent that has not
> run the checklist, cannot run it, and **must not record a result it did not observe.** The whole
> value of that file is that a ticked box means somebody watched it happen.

Story 6's P1 has an agent record the §0 result and "correct the header count to reflect exactly the
boxes §0 covers" — i.e. tick §0 — on the strength of the sentence quoted above plus the story's own
assertion that *"The owner confirmed the §0 result on Aug 16, 2026 and authorised recording it."*
That authorisation appears in no merged document.

**And the evidence gap is not a technicality.** §0 (`device-verification-transcription.md:48`,
*"The one that matters most, and no test can tell you"*) has **five boxes**. The owner's recorded
observation covers part of one:

| §0 box | Covered by the owner's recorded report? |
|---|---|
| Record **three** ordinary voice notes — a story, an explanation, one at the noisy end of the day | **No.** One transcription is reported |
| Read each transcript **against the recording**, not from memory | **No.** Method unstated |
| Per recording: fraction of words right, **and separately** whether it is worth keeping | **Partly.** "Accurate enough to capture his pronunciation" is an impression, not the two-part answer the box asks for |
| Whether **names** survive — his name, siblings, pets, invented words | **No.** Pronunciation of words is not proper nouns |
| Whether it **invents plausible sentences** where he mumbled | **No, and this is the one that matters.** §0 says confident wrong text in a permanent archive "would argue for storing a confidence signal, which is a schema change and a separate phase" |

**The closing line of §0 is why ticking it on partial evidence is worse than leaving it unticked:**

> **Record the answer somewhere durable even if it is "it's fine".** This is the only measurement in
> the project that cannot be re-derived by running something later — **the recordings change as he does.**

A §0 marked satisfied stops prompting anyone to run §0. The boy gets older, the recordings change,
and the one measurement the project calls irreproducible is lost — not wrongly recorded, *lost*.
That is a worse outcome than a gate staying shut another week.

**This is also the third story this sprint to assert an owner authorisation that no merged document
carries** (story 1's rate-limiting exception, story 3a's four settled decisions, this). The first
was contradicted outright by `main`. That pattern is why I am not extending the benefit of the doubt
to the third.

---

## The other gates

- **Gate 1 — PASS, and no number is consumed.** Phase 16 already has its number. This story
  implements 16 and claims nothing new. **Story 7 should not file a new phase for this.**
- **Gate 2 — FAILS.** Above. One of its two named inputs, `docs/phases/phase-16-BLOCKED.md`, **does
  not exist** — there is no `docs/phases/` directory anywhere in the repo, and the only file
  mentioning phase 16 is `blocked.md`. I read `blocked.md`'s section in full and treated it as the
  original reasoning, which it plainly is.
- **Gate 3 — NOT already landed.** Video audio extraction is not wired into the transcription path.
  `Rascal/Media/Transcription.swift:24` carries the doc comment *"Transcribe a local audio or video
  file into plain text"*, but `SpeechTranscription` opens its input with `AVAudioFile(forReading:)`,
  which will not read an mp4/mov container. **The comment is already ahead of the code** — worth
  fixing whenever this phase runs, because it reads as though the capability exists.
- **Gate 4 — Not reached.** No commits made, so no ordering to get wrong.
- **Gate 5 — Premise is stale, harmlessly.** The gate inherits "21 warnings, pre-existing, not yours
  to fix." **Phase 48 cleared all 21 on Aug 16** (`roadmap-status.md:467`; the true cold figure was
  26, because phase 46 had added 5 in `CaptionProbe.swift` that nobody had counted). Noted so the
  next attempt does not go looking for warnings that are gone.

---

## What I need from you — one decision, and it is small

**The code half of phase 16 is genuinely unblocked and does not need §0 ticked.** `blocked.md`
already says the original argument "has not been refuted — it has been satisfied." What is stuck is
only the *record*. Three ways forward:

1. **Run §0 yourself.** Three ordinary voice notes, read back against the recordings. It needs a
   device and a quiet room, and it is the honest answer. It also answers the mumble/confabulation
   question, which is the one that could force a schema change and a separate phase — worth knowing
   before more is built on the transcriber.
2. **Authorise a narrower record, and I would recommend this one if (1) is not happening tonight.**
   Correct the stale opening sentence (*"Nothing in this feature has ever run"* is now false) and
   add a dated, attributed note of your Aug 16 observation — **without ticking a single box and
   without changing the 0-of-45 count.** That unsticks the gate for the next attempt, makes the file
   agree with the world, and leaves §0 still asking to be run. It is the honest version of what P1
   wanted to do.
3. **Confirm the §0 authorisation story 6 claims**, if you did in fact give it and it just was not
   written down — in which case say which of the five boxes your observation actually covers.

**Say "do option 2" and the next iOS-lane loop makes that commit and then builds P2–P5.** The code
work is specified well and its recon is done (below), so it is a build rather than a design.

### Recon banked for the next attempt

- Existing transcription path: `Rascal/Media/Transcription.swift`, `SpeechTranscription.swift`,
  `TranscriptionQueue.swift`; tests in `TranscriptionTests.swift`, `TranscriptionInputTests.swift`,
  `TranscriptionFixtures.swift`.
- `Rascal/Media/VideoPipeline.swift` already uses `AVAssetReader`/`AVAssetExportSession` — **that is
  where extraction belongs**, and it is why P2 can reuse rather than build a second pipeline.
- The input contract to match is in `TranscriptionInputTests.swift`: `AudioPipeline.settings`,
  **44.1 kHz mono AAC at 96 kbps**, opened with `AVAudioFile(forReading:)`. Extraction must produce
  that, or the existing path fails as `bytesUnreachable`.

---

## A repo-wide finding, unrelated to this story but found by it

**The docs reorganisation in `ec87dbb` ("docs rearrane") moved every checklist into
`docs/Device-Verification/`, and nothing that references them was updated.** Stale paths are in
`docs/blocked.md`, `docs/roadmap-status.md`, and all seven sprint story files.

The consequence is not cosmetic — **`roadmap-status.md`'s own verification commands now return 0**:

```
$ grep -chE '^\s*-? *\[[ xX]\]' docs/device-verification-*.md | awk '{s+=$1} END {print s}'
zsh: no matches found: docs/device-verification-*.md
RESULT: 0

$ grep -chE '^\s*-? *\[[ xX]\]' docs/Device-Verification/device-verification-*.md | awk '{s+=$1} END {print s}'
460          # ticked: 9, across 12 files
```

The numbers themselves are still right — **460 boxes, 9 ticked, twelve checklists** — but the
commands the ledger supplies to prove them match nothing.

> **Correction, made while story 7 verified this.** An earlier draft of this report said there were
> *thirteen* checklists and that the ledger's "twelve" was wrong. **That was my error, not the
> ledger's.** `docs/Device-Verification/` holds thirteen files, but one of them —
> `entry-detail-inventory.md` — is not a checklist and carries no boxes. There are twelve
> `device-verification-*.md` files, they sum to exactly 460, and the ledger was right. The glob in
> my check was wider than the glob in the ledger's command, which is the whole of the difference.

This is worth flagging precisely because of what `roadmap-status.md` says about this exact block:
its own comment warns that an earlier bug meant *"this block could have read 0 forever."* It reads 0
again, for a new reason. And it is the mirror of the failure `blocked.md:1206` names — a document
that has stopped describing the world, with the command that would have caught it also broken.

**Story 7 should fix the paths.** I did not, because `roadmap-status.md` is story 7's file and
`blocked.md` is nobody's tonight.

## Deliberately not done

- No §0 record, no box ticked, **no device-verification file opened for writing**.
- No Swift changes, no extraction, no tests, no PR.
- Nothing in `api/` or the marketing repo. Nothing in `roadmap-status.md` or `phase-queue.md`.
- `syncPullEnabled` untouched, still off.
- No new phase number consumed — this is phase 16.
