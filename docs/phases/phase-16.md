# Claude Code — iOS Phase 16: Video Audio Tracks

**Repo:** `travist6983/Project-Rascal`
**Branch:** `ios/phase-16-video-audio`, **off `main`**
**Lane:** iOS only. **No `api/` changes** — `PATCH /media/{id}/derived` already takes the transcript.
**Size:** small. This is the piece cut from Phase 7.
**Run mode:** fully autonomous, unattended. Resolve ambiguity by matching existing code, record every such call in the PR under **Judgment calls**, and keep going.

---

## Mission

Video entries carry speech and none of it is searchable. The audio missions are described in `docs/mission-library.md` as the highest-value entries in the archive because transcription makes them findable forever — and half the video library is the same thing with a picture attached. *"Film him telling you about his day. Don't prompt him."* produces exactly the content that matters and currently produces zero searchable text.

The transcription pipeline exists. This phase points it at video.

---

## The gate that comes before the code

**`docs/device-verification-transcription.md` must record a completed run, on a real device, with real speech.**

Transcription is currently structurally verified and empirically unverified. `SpeechAnalyzer` requires iOS 26, `isAvailable` is false on every simulator, and no real transcription has ever run — so the one thing that matters most, how well it reads a four-year-old, is unknown rather than good.

Building video transcription on top of that means two unknowns in one branch, and if the output is poor you will not know which layer produced it.

**Preflight check #1 is to open that document and confirm it contains results.** If it records no completed run, **stop immediately.** Write `docs/blocked.md` saying the phase is gated on the device checklist, and open nothing. This is not a soft gate.

The audio checklist from PR #22 is its prerequisite — the simulator has no microphone — so in practice both must have been run.

---

## Preflight — hard stop

1. **`docs/device-verification-transcription.md` records a completed device run with results.** See above.
2. `main` green, working tree clean.
3. **The iOS workflow is dispatch-only** since PR #33. Run the suite locally, cold, from a deleted `DerivedData`, with `CODE_SIGNING_ALLOWED=NO`. Record test and suite counts. Do not carry a number forward.
4. Baseline builds with **zero warnings**. An incremental build under-reports warnings.
5. Read `docs/decisions.md` in full.
6. Read `SpeechTranscription.swift`, `Transcription.swift`, and `TranscriptionQueue.swift` end to end. **You are extending this pipeline, not writing a second one.**
7. Confirm how video media is stored locally and whether the original asset remains available after upload. Record what you find — this determines whether extraction happens before or after upload.

---

## Scope

Extract the audio track from a video asset and run it through the existing transcriber, writing back with `PATCH /media/{id}/derived` exactly as audio entries do.

Rules:

- **Reuse `TranscriptionQueue` wholesale**, including its backlog handling, its availability check, and whatever it already does about battery and thermal state. Do not add a second queue and do not add a second set of scheduling rules.
- **Extract, do not transcode.** Read the audio track from the `AVAsset`. Do not produce a second media row, do not upload the extracted audio, and do not alter the stored video.
- **Never re-transcribe.** A media row with a transcript is done. Re-running must not clobber an existing one — the standing rule that on-device output is durable data means overwriting it is data loss, not a refresh.
- Video with no audio track, or a silent track, completes cleanly with an empty result and is not retried forever.
- **Degrade silently** when the model is unavailable, matching the existing availability gate. Not every device qualifies and the app must behave identically on those that do not.
- Long videos: the queue's existing behavior governs. If it has no answer for a ten-minute asset, say so in the PR rather than inventing one here.

---

## Explicitly out of scope

- Any `api/` change.
- Structured extraction, captioning, or tagging — Phase 17.
- Re-transcribing existing audio entries.
- Changing the search surface.
- Uploading extracted audio as media.
- Timeline, Moments, Today, the composer, capture, `Sync/`, the widget, the share extension, push.

---

## Tests

- An `AVAsset` with an audio track yields a transcript through the existing pipeline.
- An asset with no audio track completes without error and is not re-enqueued.
- An existing transcript is never overwritten.
- Unavailable model degrades silently — no error surfaced, no retry storm.
- The write-back goes through `PATCH /media/{id}/derived` and no other path.
- A video entry with a transcript is findable through the existing search surface.

**Assertions over implementations.** If a test fails and the code disagrees, assume the assertion is right, stop, and report both sides.

**Verify at least two assertions by breaking the code.** The never-overwrite assertion is a required one of the two — silent data loss is the worst outcome available in this phase.

**Any test that waits must poll for a condition, never sleep a fixed interval.**

---

## Docs

- `docs/decisions.md`: extract-not-transcode, never-re-transcribe, and whatever the long-asset answer turns out to be.
- `docs/roadmap-status.md`: what landed, and **rewrite the "Recommended next phase" section rather than leaving it.**
- `docs/device-verification-transcription.md`: extend rather than replace. Video audio is a new question against the same checklist — in particular whether a phone-recorded video's audio reads as well as a dedicated recording.

---

## Done when

- [ ] The device gate was confirmed satisfied before any code was written
- [ ] Suite green locally, cold from a deleted `DerivedData`, zero warnings, count grown, no existing test modified
- [ ] Two assertions verified by breaking the code, one of them never-overwrite
- [ ] Docs updated
- [ ] PR opened against `main`

PR must include: what shipped, **Judgment calls**, **Blocked**, test counts before and after with the command used, **verification honesty** — say plainly whether a real video was transcribed or only a fixture — and a ranked list of what you are least confident about.
