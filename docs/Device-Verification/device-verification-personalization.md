# Device verification — device-side personalization

**24 boxes.** Needs a TestFlight build on **iOS 26+ hardware with Apple Intelligence**, and a child
whose name is set.

**Nothing in this checklist has ever been answered.** `SystemLanguageModel.default.availability`
has never returned `.available` on any hardware this project owns, so **every personalization in
the test suite is a stub**. This file is the only thing that can tell you whether the feature does
anything at all.

Tick a box or write down what happened instead.

---

## §0 — Does this phone qualify? Five minutes, and everything else depends on it.

- [ ] 0.1 Open Today. Note whether any prompt differs from the library's wording.
      What you saw: _______________________________________________
- [ ] 0.2 On a phone **without** Apple Intelligence, the app must behave identically — canonical
      text, **no banner, no error, no "unavailable" messaging anywhere**. Confirm there is nothing
      on screen that mentions personalization at all.
- [ ] 0.3 If nothing is personalized on qualifying hardware, stop and record it here. That is the
      most likely outcome and it is worth knowing before anything else is measured.

## §1 — Does it stay a mission?

**The model personalizes; it does not author.** Every rule in `PersonalizationGuard` exists because
a rewrite can quietly become a different instruction.

- [ ] 1.1 Read five personalized prompts against their library originals (`docs/mission-library.md`).
      For each: is it the **same task**, with only the child's name or pronouns changed?
- [ ] 1.2 Any prompt that gained a step, a condition, or a second sentence — write it down verbatim.
      That is the failure this whole phase is built to prevent.
      _______________________________________________
- [ ] 1.3 Any prompt that turned an instruction into a question, or the reverse.
- [ ] 1.4 Any prompt that acquired warmth the library did not write — *precious*, *cherish*,
      *treasure*, *little moments*, or anything in that register.

## §2 — The rejection rate, which is information rather than a bug

The suite measures the guard against **ideal** substitution and gets 0 rejections in 99. This
section measures it against a real model, which is a different number.

- [ ] 2.1 Open the debug board and read the personalization counters after a full day's board.
      accepted: ______  rejected: ______  rate: ______
- [ ] 2.2 Which rule fires most? _______________________________________________
- [ ] 2.3 **A high rate is not a bug to suppress.** If it is high, the instructions need work or
      this library resists substitution — both are findings. Write which you think it is.

## §3 — Latency, and whether it ever blocks

- [ ] 3.1 Cold launch to Today. **The board must draw immediately with library text.** If you ever
      see a spinner, a blank card, or a delay attributable to personalization, that is a defect
      against Phase B and it is the most serious one in this file.
- [ ] 3.2 Roughly how long after the board appears does text change, if it does? ______ seconds
- [ ] 3.3 Scroll and switch tabs during that window. Nothing should jump or reflow.
- [ ] 3.4 Open the composer on a mission Today already personalized. It should show the **same**
      sentence, with no second delay — that is the shared cache working.

## §4 — Dynamic Type, the likeliest defect

**A personalized string is longer than its canonical source.** Phase 18 already found a severe
truncation defect of exactly this class, on a screen with no scroll.

- [ ] 4.1 Settings → Accessibility → Larger Text → **accessibility XXL**. Open Today.
- [ ] 4.2 No prompt is clipped, truncated with an ellipsis, or running under the tab bar.
- [ ] 4.3 The composer's quoted prompt header, same size, not clipped.
- [ ] 4.4 A **long name** (try one of 12+ characters) at XXL. This is the worst case in the app.
      What you saw: _______________________________________________

## §5 — VoiceOver

- [ ] 5.1 VoiceOver on, open Today, and **start reading a prompt card aloud**. If personalization
      lands mid-read, does it re-announce from the top, or move focus?
      What happened: _______________________________________________
- [ ] 5.2 The spoken sentence matches the visible one. `PromptCard` funnels both through one
      property so they cannot diverge — confirm that holds with a model in the loop.

## §6 — Pronouns, including unset

- [ ] 6.1 Set the child's pronouns to **she/her** in Settings. Prompts should say *she/her*, not
      *he/him*, and not the name everywhere.
- [ ] 6.2 Set them to **they/them**. Same check.
- [ ] 6.3 **Clear pronouns** so the field is unset. Prompts must use the **name** and must never
      guess a pronoun. A guessed pronoun here is the worst outcome in this section.
      What you saw: _______________________________________________

## §7 — Battery and heat

- [ ] 7.1 Open and close Today twenty times. The model must be asked **once per assignment**, not
      once per render — the phone should not warm.
- [ ] 7.2 Anything in Settings → Battery attributing meaningful drain to the app after a day.

---

## The thing to write down regardless

**Does personalization make the product better?** The library is written he/him and 99 of its 113
prompts say so. If personalization reads as natural, that is an argument for it. If it reads as
uncanny, or is slow, or fires rarely, the better fix is **tokenizing the library server-side**,
which works on every device with no model at all — see the phase 23 PR.

Your answer: _______________________________________________
