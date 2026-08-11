# Claude Code — iOS Phase 17: Structured Extraction

**Repo:** `travist6983/Project-Rascal`
**Branch:** `ios/phase-17-extraction`, **off `main`**
**Lane:** iOS only, **unless preflight finds a gap** — see Phase A.
**Run mode:** fully autonomous, unattended. Resolve ambiguity by matching existing code, record every such call in the PR under **Judgment calls**, and keep going.

---

## Mission

P3 item 2. Feed a freeform entry to the on-device model, get back a typed struct — people, place, mood, tags, a one-line summary — and persist it as plain data. Auto-tagging with no cloud round-trip. This is what a small on-device model is genuinely good at.

**Scoped deliberately to entry bodies, not transcripts.** Extraction over text needs no transcriber, so this phase is not gated on the device checklist and does not stack two unknowns in one branch. Transcript extraction is a small follow-on once transcription has been verified on a device.

---

## The rule that is not negotiable

**The on-device model never authors mission content.** It structures, extracts, and summarizes what a human wrote. It does not write prompts, it does not rewrite a parent's entry body, and it does not edit anything the parent typed. Small model, weak world knowledge, and those prompts are the soul of the product — settled decision, not open.

---

## Preflight — hard stop

Any failure: stop, write `docs/blocked.md` with exact output, open a draft PR, do not proceed.

1. `main` green, working tree clean.
2. **The iOS workflow is dispatch-only** since PR #33. Run the suite locally, cold, from a deleted `DerivedData`, with `CODE_SIGNING_ALLOWED=NO`. Record test and suite counts. Do not carry a number forward.
3. Baseline builds with **zero warnings**. An incremental build under-reports warnings.
4. Read `docs/decisions.md` in full.
5. Read `TranscriptionQueue.swift` and the availability-gating pattern it uses. **You are matching that shape**, not inventing a second background-work mechanism.
6. **Determine whether `PATCH /v1/entries/{id}` can write tags with `source = device_ai`.** `entry_tags` carries a `source` column in the schema; whether the API exposes it is the open question. Record the answer precisely — it decides Phase A.

---

## Phase A — The write path

`entry_tags.source` exists specifically so that tags a parent chose can be told apart from tags a model extracted, and so extraction can be re-run without clobbering the parent's own.

- **If the API accepts `source` on tag writes:** use it. `device_ai` for everything this phase produces.
- **If it does not:** stop. Write `docs/blocked.md` naming the exact endpoint change needed and open a draft PR. **Do not write model-generated tags as if a human chose them.** That is unrecoverable — once the two are indistinguishable, no future re-run can safely touch them, and a parent cannot tell which tags are theirs.

This is a hard gate, not a preference. The `source` column is the whole reason re-running extraction is safe.

---

## Phase B — The `@Generable` struct

Write against `LanguageModelSession`. The provider layer means call sites do not change if a hard task is later routed elsewhere — keep that option open and do not couple to a concrete backend.

Extract, from an entry body:

- **People** — names mentioned
- **Place** — where it happened, if stated
- **Mood** — of the moment described
- **Tags** — a small set
- **Summary** — one line

Rules:

- **Gate every call behind an availability check and degrade silently.** Not every device qualifies. An app on a non-qualifying device behaves identically minus the tags — no error, no banner, no degraded-mode messaging.
- Bound the tag count. An entry with eleven tags is worse than one with three.
- **Never modify `title` or `body`.** The parent's words are the archive. Extraction adds metadata beside them and touches nothing else.
- Nothing is extracted from a **sealed** entry. A sealed letter's contents must not leak into tags that render on an unsealed surface — this is the highest-consequence defect available in this phase and it needs an explicit test.
- Run in the background, following the existing queue's battery and thermal posture. `isDiscretionary = false` applies to uploads, not to this — extraction is genuinely deferrable and should behave that way.

---

## Phase C — Re-running safely

- A re-run replaces only `device_ai` tags. **Parent-authored tags are never touched**, not even if the model would have produced the same one.
- Removing a `device_ai` tag by hand and re-running must not resurrect it. Track that, or do not offer re-running — a tag the parent deleted coming back is the kind of thing that makes someone stop trusting the app.
- Extraction is idempotent enough that running it twice on unchanged text produces no churn in the sync log.

---

## Explicitly out of scope

- Any `api/` change beyond what Phase A gates on — and if that gate trips, this run stops rather than crossing lanes.
- Extraction from transcripts. Follow-on phase.
- Photo captioning — gated on the iOS 27 wave and Apple Intelligence hardware, and a bonus rather than a dependency.
- Device-side prompt personalization. That is phase 19.
- Any model-authored prompt, mission, or entry text, under any framing.
- Surfacing extracted people or places as a browsable index — that is a feature with its own design, not a side effect of this one.
- Timeline, Moments, Today, capture, `Sync/`, the widget, the share extension, push.

---

## Tests

- A known entry body yields a struct with the expected shape, against a stubbed model.
- Availability false degrades silently — no error, no retry storm, no user-visible difference beyond absent tags.
- **A sealed entry is never extracted from** — asserted explicitly against a sealed fixture.
- `title` and `body` are byte-identical before and after extraction.
- Re-running replaces `device_ai` tags and leaves `user` tags untouched, asserted with both present.
- A hand-deleted `device_ai` tag does not return on re-run.
- Tag count is bounded.
- Everything written carries `source = device_ai`.

**Assertions over implementations.** If a test fails and the code disagrees, assume the assertion is right, stop, and report both sides.

**Verify at least two assertions by breaking the code.** The sealed-entry exclusion is a required one of the two.

**Any test that waits must poll for a condition, never sleep a fixed interval.**

---

## Docs

- `docs/decisions.md`: text-entries-only scope and why, `device_ai` provenance, never touching parent text, sealed exclusion, and the deleted-tag rule.
- `docs/roadmap-status.md`: what landed, and **rewrite the "Recommended next phase" section rather than leaving it.**
- `docs/device-verification-extraction.md`: new. Model availability across real hardware, extraction quality against real entries, and battery behavior — none of which a simulator answers.

---

## Done when

- [ ] Suite green locally, cold from a deleted `DerivedData`, zero warnings, count grown, no existing test modified
- [ ] Two assertions verified by breaking the code, one of them sealed-entry exclusion
- [ ] Every tag written carries `source = device_ai`
- [ ] Docs and the new device checklist written
- [ ] PR opened against `main`

PR must include: what shipped, **Judgment calls**, **Blocked**, test counts before and after with the command used, **verification honesty** — the model has not run on real hardware, so say plainly what is stubbed — and a ranked list of what you are least confident about.
