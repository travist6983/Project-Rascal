# Story 6 — Phase 16, video audio tracks

**Lane:** `ios/` only. **Runs:** first in its lane, before story 3b.
**Read `sprint-runbook.md` before starting.**

Phase 16 has been marked blocked since it arrived. **It is not blocked on anything real.** It is
blocked on a document that disagrees with the world, and the first commit of this story fixes the
document.

---

## The unblock, and its exact boundary

`docs/blocked.md` was rewritten on Aug 16, 2026 to record that the transcriber works and has been
seen working: the owner reported `SpeechAnalyzer` producing a real transcription on a real device,
on a build from that day, accurate enough to capture his son's actual pronunciation. That is
precisely the question `docs/Device-Verification/device-verification-transcription.md` **§0** exists to answer.

But that file still opens with *"Nothing in this feature has ever run"* and still reads **0 of 45**.
Phase 16's preflight reads that sentence and hard-stops — correctly, on stale input.

**The owner confirmed the §0 result on Aug 16, 2026 and authorised recording it.**

### What you may write, and what you may not

**May:** record the §0 result in `docs/Device-Verification/device-verification-transcription.md` — the outcome, the
date, the owner's attribution, and an explicit marker that it is **owner-confirmed retrospectively,
not agent-observed**. Correct the file's opening claim so it no longer says nothing has ever run,
and correct the header count to reflect exactly the boxes §0 covers.

**May not:** tick a single box outside §0. Not one. `blocked.md` says the whole value of that file
is that a ticked box means somebody watched it happen, and an agent that ticks 45 boxes off one
sentence is the failure this project has caught repeatedly. The remaining boxes stay unticked and
the file states why.

**May not:** touch any other device-verification checklist.

---

## Hard-stop preflight gates

**Gate 1 — Phase number.** Per the runbook. Note that phase 16 already has a number; this story
implements 16 and does **not** claim a new one. Say that explicitly so story 7 does not double-file it.

**Gate 2 — Read the original reasoning.** `docs/phases/phase-16-BLOCKED.md` and `docs/blocked.md`'s
phase 16 section, in full. The original argument — that building video transcription on an unverified
transcriber stacks two unknowns in one branch — was sound and **has been satisfied, not refuted**.
If anything in either file contradicts this story, halt and report both sides.

**Gate 3 — Idempotency.** If video audio extraction is already wired into the transcription path,
report `ALREADY LANDED` and exit 0.

**Gate 4 — Commit order.** The documentation commit lands **first and alone**, before any Swift
changes. If the code work halts later, the record still stands and the gate is unstuck for the next
attempt. A doc fix bundled into a code PR that gets abandoned leaves the gate shut for another week.

**Gate 5 — 21 inherited warnings.** Pre-existing, not new issues, not yours to fix.

---

## Implementation

### P1 — The documentation commit

As specified above. Alone, first, and the commit message says it is recording an owner-confirmed
retrospective result.

### P2 — Extract the audio track

Take the audio from a captured video and hand it to the existing transcription path.

- `AVAssetReader` / `AVAssetExportSession` to pull the audio track to a temporary file in the format
  the existing `SpeechAnalyzer` path already accepts. **Reuse the existing path** — do not build a
  second transcription pipeline beside the one phase 7 shipped.
- **A video with no audio track is a normal case, not an error.** Silent clips, screen recordings,
  video where the mic was blocked. Handle it as "nothing to transcribe" and move on without a state
  that looks like failure.
- Long videos: cap the work, or chunk it. Say in the report which you chose and what the cap is.
- Temporary files are cleaned up on every path including the failure ones.

### P3 — Persist and sync

The transcript is written back through the **existing** `RascalAPI.writeDerived` path. On-device AI
output is persisted server-side as plain data and is never regenerated on demand — a web client will
never have an on-device model, so the phone is an inference worker whose output must be durable.

**Do not touch `caption` anywhere.** `RascalAPI.writeDerived` sends the transcript alone, and says so
at `RascalAPI.swift:267`. The caption clobber in `Media.applyServerSummary` (`Media.swift:210`) is
inert precisely because nothing writes a caption, and it belongs to phase 33. Writing one here would
make a dormant defect live, in a phase that has no reason to go near it.

### P4 — Where it runs

`MediaCoordinator.shared` is a **process-wide global by constraint** — the system may create the
process purely to deliver a background callback. Do not fix that, and do not create a second one.

Transcription must not block capture. **Capture stays under 15 seconds, one-handed** — that budget
is judged against every feature and this one is not exempt.

### P5 — Surfacing

If a video's transcript appears anywhere in the UI, it uses the surfaces phase 7 already built —
Timeline search and Entry Detail. **Do not add a new screen, a progress row, or a queue count.** A
Settings row that permanently reads "0 waiting" is the furniture this app refuses.

---

## Verification

- **Dynamic Type XXL screenshots** of any changed surface. If nothing visible changed, say so rather
  than attaching a screenshot of an unchanged screen.
- Unit tests over the extraction path with a fixture video: one with audio, one without, one with an
  audio track containing silence.
- The report lists the **new device-verification boxes this work creates** — extraction from a real
  recording, the no-audio case, a long video — and **does not write them into any checklist file.**
  Story 7 files them.

---

## Break-test at least two assertions

1. **The no-audio path.** Make the extractor throw on a video with no audio track. A test must fail.
   If none does, the normal case is unasserted and the first silent clip becomes a support question.
2. **Reuse of the existing pipeline.** Rename a symbol in the phase 7 transcription path. This
   story's tests must fail to compile. If they still pass, you built a second pipeline — stop and
   report it.

---

## Deliberately out of scope

- Every device-verification checklist except §0 of the transcription file.
- Photo captioning, `CaptionProbe`, and anything in phase 33.
- `syncPullEnabled`. Still off, stays off.
- Anything in `api/` or the marketing repo.
- `roadmap-status.md` and `phase-queue.md`.

## Report to

`docs/sprint-aug16/story-6-report.md`, plus the PR description in the runbook's format. The report
must state, in its own sentence, that §0 was recorded from the owner's confirmation and that no other
box was touched.
