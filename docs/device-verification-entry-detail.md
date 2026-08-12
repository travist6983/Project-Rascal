# Device verification — Entry Detail

**22 boxes.** Needs a TestFlight build and a real archive with at least one sealed letter, one
did-it entry, one voice note, and one entry with several photos.

Entry Detail shipped in Phase 4 and has never had a checklist. Phase 22 added this one before
redesigning the screen rather than after, because **§1 below is the check that matters most and it
is easier to trust on the current design than on a new one.**

Tick a box or write down what happened instead. A line that "seemed fine" is not ticked.

---

## §1 — The seal. Do this one first.

**Why this section exists, in full.** The app's primary seal assertion is
`SealControlTests.sealedEntryRendersSealed`, and it builds its fixture with `media: []`. It then
asserts `card.preview == nil` — which is true whether or not the seal is doing anything, because
there was never a preview to suppress. The shipped gate in `EntryDetailScreen.content` is correct
(`entry.unlockAtAge != nil && !unsealed` → `sealedCard` and nothing else). But the *evidence* that
it holds is thinner than the test's name suggests, and a seal that silently stops holding is the
worst defect this app can ship.

A phone is the only place this is currently provable end to end.

**Setup:** write a letter, seal it, and give it **both a photo and a body** — the case no test
covers.

- [ ] 1.1 Open it from the timeline. The screen shows the sealed card — lock glyph, the title,
      "Sealed until N.", "Written on <date>, and waiting." — and **nothing else**.
- [ ] 1.2 **No part of the photo is visible.** Not blurred, not scrimmed, not a thumbnail, not a
      one-pixel edge behind the card.
- [ ] 1.3 **No part of the body text is visible**, including while the screen is animating in.
      Watch the push transition, not just the settled state.
- [ ] 1.4 Scroll the screen. Nothing appears below the sealed card — no metadata rows, no tags, no
      transcript block.
- [ ] 1.5 The navigation-bar title is the entry's date. It does not contain any of the body.
- [ ] 1.6 Turn **VoiceOver on** and swipe through every element. Say out loud what it reads.
      **The body text and the photo must not be announced anywhere** — not as a label, not as a
      hint, not as an image description.
      Write what VoiceOver actually said: _______________________________________________
- [ ] 1.7 With VoiceOver still on, use the rotor to navigate by *image*. The sealed entry's photo
      must not be reachable.
- [ ] 1.8 Tap **Open it**. The entry opens fully — photo and body both present. The author is not
      locked out of their own letter.
- [ ] 1.9 Leave the screen and come back. It is **sealed again**. Opening is per-viewing and
      nothing was persisted.
- [ ] 1.10 Background the app while unsealed, then return via the app switcher. Check what the
      iOS **task-switcher snapshot** shows. Write down whether the body was visible in it:
      _______________________________________________

## §2 — The three completion shapes

- [ ] 2.1 A **did-it** entry with no note and no media renders as complete — the check and "We did
      it" — with no empty photo frame and no blank region.
- [ ] 2.2 A **written** entry with no media renders its title and body with no media region.
- [ ] 2.3 A **voice** entry renders its player. If it has no transcript, there is **no** heading,
      no empty block, and nothing saying "pending".
- [ ] 2.4 A voice entry **with** a transcript shows it as readable body copy under its own label.

## §3 — Dates, prompts, and what the screen claims

- [ ] 3.1 Open a **backfilled** entry — one whose `occurred_at` is months before it was saved. The
      date shown is the day it **happened**, not the day it was added. Check the nav-bar title and
      the metadata row agree.
- [ ] 3.2 An entry made from a mission shows the prompt that caused it.
- [ ] 3.3 A **freeform** entry (no assignment) renders cleanly with no prompt block and no gap
      where one would be.
- [ ] 3.4 Open an entry whose prompt contains pronoun tokens. It renders the child's pronouns, not
      braces.

## §4 — Media

- [ ] 4.1 An entry with **several photos** pages through all of them; the count in the metadata row
      matches what you can actually swipe to.
- [ ] 4.2 A **video** entry opens full screen and plays.
- [ ] 4.3 Open an entry whose media this phone never captured (came down from the server). The
      bytes download and render.

## §5 — Edit and delete

- [ ] 5.1 **Edit** opens the composer with the entry loaded — not a second editor.
- [ ] 5.2 **Delete** asks first, and the confirmation says what it costs.
- [ ] 5.3 After deleting, the screen pops and the row is gone from the timeline in the same motion.
- [ ] 5.4 Delete an entry **with the phone in airplane mode**. It leaves both screens, and nothing
      claims it reached the server.

## §6 — Offline and missing

- [ ] 6.1 Open an entry in airplane mode. It renders from cache; no error dialog.
- [ ] 6.2 An unsynced entry says so — "Here — it'll sync when you're back on" — rather than looking
      like it failed.
- [ ] 6.3 Open an entry deleted on another device. It says "That's no longer here." rather than
      rendering an empty screen.

---

## What to write down regardless

- The device and iOS version: _______________________
- Anything that looked wrong but is not covered above: _______________________
- **§1.6 and §1.10 in particular** — a seal that holds visually and leaks to a screen reader or to
  the task switcher is still broken, and neither is something a test on this project can currently
  see.
