# Structured extraction — device verification

**The model has never run.** Every assertion in the suite goes through a stub `EntryExtracting`.
`FoundationModels` is present in the iOS 26.4 SDK so the code compiles, but
`SystemLanguageModel.default.availability` has never returned `.available` on anything here —
the simulator does not carry the model, and no Apple Intelligence hardware has run this build.

So the seam is exercised thoroughly and **the thing behind the seam has been exercised zero
times.** Everything below is about that half.

Run on a real device on **iOS 26 or later** with Apple Intelligence enabled. On anything else the
correct outcome is that nothing happens at all — §1 checks exactly that.

---

## 0. Upgrade the build in place, before anything else

This phase adds one property to the `Entry` `@Model`: `extractedAt`. It is optional, which is the
rule in `ios/CLAUDE.md`, and **nothing in the suite or CI can prove the migration worked** —
every test store is `isStoredInMemoryOnly`.

- [ ] Install this build **over** the existing one. **Do not uninstall first.**
- [ ] Launch. It opens, and the timeline still has the entries it had before.
- [ ] No `unreadable-store-*` folder in `Library/Application Support/`.

## 1. Availability, and the majority case

- [ ] On a device **without** Apple Intelligence: write an entry. No tags appear, **no error, no
      banner, nothing in the interface differs.** This is the commonest outcome and it must be
      indistinguishable from the app before this phase.
- [ ] On iOS 18: same.
- [ ] With Apple Intelligence **switched off** mid-session: same, and no retry loop.

## 2. The one that matters most, and no test can tell you

**Are the tags any good?** Nobody knows. A small on-device model over one sentence a tired parent
typed is a genuinely open question.

- [ ] Write **five ordinary entries** — not test phrases. Real ones about a real day.
- [ ] For each, write down: how many tags, how many you would have chosen yourself, and how many
      are wrong or meaningless.
- [ ] Judge the **people** field hardest. A name it invented, or a name it got wrong, is worse
      than no name at all — this is metadata that will outlive the phone.
- [ ] Check the place field never invents a location the text did not state.

## 3. The rule with the worst failure mode

**A sealed entry must never be read.** The suite asserts it; this confirms it on the thing that
actually holds letters.

- [ ] Write a letter entry with an unlock age. Confirm **no tags appear on it**, ever.
- [ ] Confirm nothing from its body appears anywhere on the timeline, in search, or in a tag.
- [ ] Search for a distinctive word that appears **only** in the sealed letter. It must not match.

## 4. Never twice

Extraction runs once per entry, by design — see `docs/decisions.md`.

- [ ] An entry that has been extracted gains no new tags on later launches.
- [ ] **Delete a model-generated tag by hand. It never comes back.** This is the behaviour the
      once-only rule exists to guarantee.
- [ ] Edit an entry's body afterwards. Its tags do **not** change — that is the accepted cost.

## 4a. Two children — new Aug 16, 2026 (phase 45)

The extraction queue was one of the six unscoped reads. It is device-wide work that must still
carry each row to its own child.

- [ ] 4a.1 With two children on the device, run extraction with **A** selected. Tags land on A's
      entries and **no tag is written to any of B's**.
- [ ] 4a.2 Switch to B and run it. B's queue is B's — entries A already had extracted are not
      re-queued under B.
- [ ] 4a.3 Check that an entry belonging to B never appears in a queue count shown while A is
      selected.

## 5. Battery and thermals

- [ ] Write several entries in a row. The phone does not get warm.
- [ ] No measurable battery cost in a normal day's use.
- [ ] Confirm extraction never runs while a transcription is running — the two are separate
      queues and neither yields to the other, so this is the one place parallel inference could
      still happen in practice.
