# Phase 16 — BLOCKED at preflight #1

**Branch:** `phase-16/video-audio`, stacked on `phase-15/pool-durability`
**Status:** blocked before any code was written. **No implementation was attempted.**

## The gate, and why it is not soft

Phase 16's own preflight is unambiguous:

> **`docs/device-verification-transcription.md` must record a completed run, on a real device,
> with real speech.** … **Preflight check #1 is to open that document and confirm it contains
> results.** If it records no completed run, **stop immediately.** Write `docs/blocked.md` saying
> the phase is gated on the device checklist, and open nothing. This is not a soft gate.

## What the document actually records

Opened and read in full. It records **no run at all**.

| Measure | Value |
|---|---|
| Checkboxes ticked | **0** |
| Checkboxes unticked | **45** |
| Recorded results, dates, or device names | none |

Its own opening sentence is the finding:

> **"Nothing in this feature has ever run."** That is not a caution, it is the literal state: the
> test suite proves the queue, the writeback, the retry, the sync-conflict rule, and the two
> display surfaces, and every one of those assertions runs against a stub transcriber.

## Why building anyway would have been the wrong call

This is not bureaucratic. `SpeechAnalyzer` requires iOS 26 and `isAvailable` is false on every
simulator, so **no transcription has ever been produced by this app** — the quality of the model
against a four-year-old's speech, which the phase calls "the open question of this entire phase",
is unknown rather than good.

Building video transcription on top of that stacks two unknowns in one branch. If the output is
poor, there is no way to tell whether the extraction is wrong, the model is wrong for this
speaker, or both — and the whole value of the phase is transcript quality.

The prerequisite chain is two deep: the audio checklist from PR #22 has also never been run, and
the simulator has no microphone, so **both must happen on real hardware before this phase can
start.**

## What would unblock it

1. Run the audio checklist from PR #22 on a real device with a real microphone.
2. Run `docs/device-verification-transcription.md` on a device on **iOS 26 or later**, signed,
   pointed at a real API. Its §0a (upgrade-in-place before deleting anything) and §0 (three
   ordinary voice notes of him, read back against the recording) are the two that matter.
3. Record the results in that document — particularly the per-recording word accuracy.

Then this phase starts, and it is small: extract the audio track from the `AVAsset` and run it
through the existing `TranscriptionQueue`. **No code from it exists yet.**

## Deviation from the phase file, logged

The phase file says "open nothing". The overnight run's protocol says a blocked phase gets a
draft PR and a `RUN-STATE` update. A draft PR carrying **only this document** was opened so the
block is visible where the other four phases are, and so the branch exists for phase 17 to stack
on. No `ios/` or `api/` file is touched by it. See `docs/phases/DECISIONS.md` D-007.
