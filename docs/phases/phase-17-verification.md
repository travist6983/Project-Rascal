# Phase 17 — certainty pass

Run as its own pass after the suite was green. Every file touched was re-read top to bottom.

## Findings that changed the code

### 1. A test asserted JSON key order, which `JSONEncoder` does not guarantee
`writeCarriesOnlyTags` compared the encoded payload to a literal string and failed on key order —
a brittle assertion that says nothing about the rule it claims to protect. Rewritten to decode and
assert the substance: exactly one top-level key, and the tag's name and source.

### 2. `ExtractionQueue` was built but never called
The first wiring pass added the construction inside `if transcription == nil, let mediaCoordinator`
— so extraction would only have existed on a launch where media staging also initialised, and
never on a text-only session. It reads text and has nothing to do with media landing. Moved out to
its own unconditional branch.

### 3. The composer's dismissal already had two callers
`main` picked up phase 14's post-entry notification re-offer between this branch being planned and
written, so `onDismiss` was no longer the single-statement closure the plan assumed. Extraction was
appended rather than replacing it — worth naming because the plan's snippet was stale and copying
it would have deleted the re-offer.

## Assumptions confirmed against source, not memory

| Assumption | How it was confirmed |
|---|---|
| The seal is `unlockAtAge` | Read `Entry.apply(response:)` — the server owns it, and a letter prompt's `default_unlock_age` can arrive on a row this device never marked. Nil means unsealed. |
| The API accepts `source` on tag writes | PR #45, merged. `apply_tag_writes` is on `main` and groups by source, `user` before `device_ai`. |
| A `device_ai` write cannot touch a parent's tag | Server-side: a source absent from the payload is left alone. The client sends **only** `device_ai` entries, asserted by decoding the payload — one key, one source. |
| `FoundationModels` compiles against this SDK | `FoundationModels.framework` is present in iPhoneSimulator26.4.sdk. `@Generable` compiles; the build is warning-free. |
| A new `@Model` property needs a declaration default | `extractedAt: Date?` is optional, per `ios/CLAUDE.md` rule 6. Nothing in the suite can prove the migration, because every test store is in-memory — hence §0 of the device checklist. |
| Nothing enumerates the archive | `extractLatest()` reduces to a single newest row; `ExtractionQueue.pending` is never called anywhere automatically. |
| One inference at a time | `running` guards re-entry within the queue. **Not confirmed across queues** — see below. |

## Things I could not confirm, stated plainly

- **The model has never run.** `SystemLanguageModel.default.availability` has never returned
  `.available` here. Every assertion goes through a stub. **Tag quality is completely unknown** —
  that is §2 of the device checklist and it is the open question of this phase.
- **Extraction and transcription can run concurrently.** Each holds its own one-at-a-time guard,
  and nothing coordinates between them. It has never been observed because the model has never
  run. Recorded in the device checklist §5 rather than pre-emptively fixed, because the right fix
  depends on whether it is actually a problem on hardware.
- **The `@Generable` guides are unvalidated.** How well those descriptions steer a small model is
  exactly what a real run answers.
- **The migration is unproven.** Optional property, correct by the rule, but only an
  install-over-the-top confirms it.
