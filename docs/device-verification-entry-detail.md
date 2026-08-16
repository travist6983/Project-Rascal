# Device verification — Entry Detail

**36 boxes.** Needs a TestFlight build and a real archive with at least one sealed letter, one
did-it entry, one voice note, and one entry with several photos.

Entry Detail shipped in Phase 4 and has never had a checklist. Phase 22 added this one before
redesigning the screen rather than after, because **§1 below is the check that matters most and it
is easier to trust on the current design than on a new one.**

**Reconciled with the shipped v2 screen on Aug 16, 2026 (phase 44), and it needed it.** The count
said 22 against 28 actual boxes. Two boxes asked about a **navigation bar that v2 removed** —
`EntryDetailScreen` has no `navigationTitle` and no `toolbar` anywhere in it — so a tester would
have failed a correct build or skipped the check confused. §7 is new and covers what v2 actually
changed. **§1.8's "Open it" was checked against the source and kept**: the design export drops that
button, the shipped screen does not, and `decisions.md` is why — a lock the author cannot pick is a
lock on the wrong person.

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
- [ ] 1.5 **There is no navigation bar** — v2 moved this screen off it, so the top of the screen is
      the back chevron and the overflow button and nothing else. Confirm no title strip of any kind
      is drawn, and in particular that **no part of the body has been promoted into one**.
      *(This box used to read "the navigation-bar title is the entry's date". It was written before
      v2 and asked about a bar that no longer exists.)*
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
      date shown is the day it **happened**, not the day it was added. Check it against the day
      the timeline files the entry under; the two must agree.
      *(This box used to say "check the nav-bar title and the metadata row agree". There is no
      nav bar after v2, so the timeline is the second opinion now.)*
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

## §7 — What v2 changed — new Aug 16, 2026

Everything above predates the v2 redesign and was written against the Phase 4 screen. These are
the things v2 actually altered, and none of them had a box until now. Each one is a correction the
redesign made for a stated reason, which means each one is a thing that can regress.

**The sheet is a real bottom-anchored surface, not the last child of a scroll stack.** That is the
correction v2 made: it used to be a `VStack` member inside a `ScrollView`, so on any entry shorter
than the screen it floated wherever the stack happened to end and left canvas showing beneath it.

- [ ] 7.1 Open the **shortest entry in the archive** — a did-it with no note and no media is ideal.
      The sheet sits on the **bottom safe area**, rounded on its top corners only, with the grabber
      over it. There is **no canvas visible below it** and it is not floating mid-screen.
- [ ] 7.2 Open a **long** entry. The sheet still anchors to the bottom, and the artifact above it
      is what moves.
- [ ] 7.3 Set Dynamic Type to **AX5 (the largest)** and open an entry that has a caption, a prompt
      **and** a chip row. The sheet **scrolls inside itself**. The title must not be pushed up past
      the top edge, and must not be clipped. Both were possible before the cap existed — a stack
      that hugs its content pushes, a fixed height clips.
- [ ] 7.4 At an ordinary text size, a **short** sheet does not bounce or rubber-band. The scroll
      only engages once the content outgrows the cap.

**The screen moved off the navigation bar, and Edit and Delete moved with it.** They live in the
overflow button in the chrome now, which is a different route than §5 was written against.

- [ ] 7.5 The chrome is drawn **against the screen, not against the artifact** — the back chevron
      and overflow sit at the screen's top edge, not floating on the top edge of a card in the
      middle of the screen.
- [ ] 7.6 Reach **Edit** and **Delete** through the overflow button. Both work from there, and §5's
      checks still hold when you get to them by this route.
- [ ] 7.7 **On a sealed letter**, the overflow button is present and **Delete works from it** —
      without opening the letter. This is the one entry a parent most needs to be able to delete
      and the one they cannot open to check first, so a sealed letter that can only be deleted by
      unsealing it is a defect.
- [ ] 7.8 With the letter **still sealed**, confirm the overflow menu itself leaks nothing — no
      body text in a menu title, no preview in a confirmation dialog. Read the delete confirmation
      out loud and write down what it says: _______________________________________________

---

## What to write down regardless

- The device and iOS version: _______________________
- Anything that looked wrong but is not covered above: _______________________
- **§1.6 and §1.10 in particular** — a seal that holds visually and leaks to a screen reader or to
  the task switcher is still broken, and neither is something a test on this project can currently
  see.
