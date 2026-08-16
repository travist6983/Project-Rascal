# Today v2 — device verification

**This screen now has a gesture on it, and a gesture is the one interaction class a simulator
answers dishonestly.** A trackpad swipe is not a thumb: it has no mass, it starts and stops
exactly where you tell it, and it cannot tell you whether the reveal threshold is discoverable to
someone holding a phone in one hand with a child on the other arm. Everything else on this list is
here because it was verified by *reading the code* rather than by touching the app — the honest
list is in PR #34 §8, and this checklist is the way to close it.

Four things in particular cannot be established from the screenshots taken during the build:

- **The swipe itself.** The full-swipe threshold, whether a partial drag reveals enough of the
  action to be discoverable, and whether it fights the vertical scroll on a long backlog.
- **The undo window.** Skip is implemented by *not sending* a one-way request for eight seconds.
  Every way that can go wrong — a lost skip, a double-send, a skip that fires because a
  notification banner slid down — is a timing question against a real network.
- **VoiceOver.** `swipeActions` is supposed to surface a rotor action, and the toast is supposed to
  be announced. Both were reasoned about, neither was heard.
- **Dynamic Type at the real accessibility sizes**, set in Settings rather than injected into a
  preview.

Run against a build pointed at a real API — `API_HOST` on the LAN, per `ios/device-test.md`.
**Sign the build.** An unsigned build cannot write to the keychain, every request after sign-in
comes back `401`, and it reads as an auth bug rather than a signing one.

Tick each line or write down what happened instead. A line that "seemed fine" is not ticked.

---

## 1. The board still is what it was

The refactor moved the board from a `ScrollView` to a `List` and split it into three card types.
This section is entirely about things that used to work.

- [ ] Open Today. The child's name is on a pill with their initial; the age reads underneath.
- [ ] Today's items are tall tinted cards; **a mission is terracotta and a question is periwinkle.**
      A question card tinted terracotta is a defect, not a preference.
- [ ] **Pull down to refresh.** The spinner appears and the board reloads. `.refreshable` moved from
      the scroll view onto the enclosing view during the refactor and reaches the list through the
      environment — this line is the only proof that actually works.
- [ ] Scroll a board with eight or more waiting items. No separators, no grey list background, no
      inset chrome bleeding through — it should look like cards on cream, not like a table.
- [ ] Tap a card. The composer opens for the right assignment.
- [ ] A section with nothing in it is **absent**, not an empty labelled shell.

## 2. The skip window — the sharpest section here

**Read this before running it.** There is no un-dismiss endpoint. `POST /assignments/{id}/dismiss`
is one-way, so "undo" is implemented by holding the request for eight seconds and only sending it
if you do not tap Undo. That means every failure here is either *a skip the parent asked for that
never happened*, or *a prompt that disappeared without being asked to*. Both are worse than a
visual bug.

Have the API logs where you can see them. `POST /assignments/{id}/dismiss` in the log is the
ground truth for every line below.

- [ ] Swipe a waiting row left a short distance and let go. It springs back, and **no dismiss is
      logged.**
- [ ] Swipe far enough to reveal the Skip action. Is the reveal discoverable — can you tell there is
      something there before you have gone far enough to trigger it? Write down what you think.
- [ ] Full-swipe a waiting row. The row leaves, a dark toast appears with **Undo**, and **no dismiss
      is logged yet.**
- [ ] Wait out the toast without touching it. **Exactly one** dismiss is logged, and the row does not
      come back on the next refresh.
- [ ] Skip another row and tap **Undo** before the toast goes. The row returns, and **no dismiss is
      ever logged for it.** Pull to refresh and confirm it is still there.
- [ ] Skip a row, then immediately skip a second one while the first toast is still up. **Two
      dismisses are logged, one per row**, and — the part that matters — **the first row does not
      flicker back onto the board** in the gap.
- [ ] Skip a row and background the app immediately. The dismiss is logged. (Leaving is a decision;
      the toast is not coming back to confirm it.)
- [ ] Skip a row and pull down Control Center, or let a notification banner land on top of the toast.
      **The window must survive it** — this is `.inactive`, not `.background`, and ending someone's
      undo because a banner slid down takes the decision away from them.
- [ ] Skip a row and force-quit inside the window. The skip is **lost and the prompt is still there**
      on relaunch. That is the intended direction to fail; confirm it fails that way and not the
      other.
- [ ] Skip a row in airplane mode. The row goes, the toast behaves, and when the request finally
      fails you get **one quiet line** — not a dialog, not a lost row with no explanation.

## 3. VoiceOver

Settings → Accessibility → VoiceOver on. This whole section was reasoned about and never heard.

- [ ] Swipe to a waiting card. It reads as one element: kind, then the prompt, then the chip.
- [ ] With focus on a waiting card, use the **rotor / two-finger swipe** to find the actions.
      **"Skip" must be there.** This is the entire reason the board became a `List` instead of using
      a hand-rolled drag gesture — if it is not there, that trade bought nothing.
- [ ] Trigger Skip through the rotor. **The toast is announced.** Then find and reach **Undo**.
- [ ] **Time that.** Eight seconds was chosen because VoiceOver has to finish speaking before anyone
      can act. If the announcement plus navigating to Undo does not fit comfortably inside the
      window, say so — the number is a constant in `TodayModel.skipGrace` and it is meant to change.
- [ ] The circular refresh button in the header reads as "Refresh" (debug builds only).
- [ ] The chevron on a waiting row and the info icon on a notice are **not** announced — they are
      decoration.

## 4. Dynamic Type and Reduce Motion

Set these in Settings, not in a preview.

- [ ] Accessibility sizes, largest. **No prompt body truncates.** The card footer stacks the slot
      label above the button rather than clipping it.
- [ ] At the largest size the kind glyph still reads as an icon rather than a dot — the tile and the
      glyph inside it are both meant to scale.
- [ ] With the toast up at the largest size, **the last card on the board can still be scrolled
      clear of it.**
- [ ] Reduce Motion on: completing something still fills the check, it just does not spring.

## 5. Done cards, and the upload path that was nearly lost

**This section exists because of a real defect.** Moving finished items onto a compact done card
put the failed-upload retry list on a code path that could never execute — and a failed upload is
terminal for the automatic sweep, so those files would have stayed on the phone forever behind a
completion check. It is fixed. This is how you prove it.

- [ ] Complete a **did-it** mission. The card lands in Done today, tinted sage with a sage check.
- [ ] Complete a **question**. It lands periwinkle — **done keeps its kind**, it does not all go sage.
- [ ] Complete a **photo** mission with three photos on a good connection. While the bytes are
      moving the done row shows a **ring with a count**, not a finished check. It becomes a check
      when the last file lands.
- [ ] Now the important one. Complete a photo mission, then **kill the network** so the uploads fail
      out. Force the row to `failed` (six attempts). The done card must show **the failed file list
      with a retry**, on the card, where you can reach it.
- [ ] Tap retry with the network back. The file uploads and the card settles to a check.
- [ ] A done row shows the time it **happened**, not the time it uploaded. Backdate an entry and
      confirm the row does not say "now".

## 6. Expiry, in a timezone that is not the child's

The expiry chip used to anchor on the *device's* day while `expires_on` is computed in the child's
`family_timezone`. That is fixed and unit-tested, but the fix has never run on hardware.

- [ ] Find a prompt expiring within three days. The chip reads "2 days left" — **grey, not bold, not
      red, not animated.**
- [ ] Change the phone's timezone to something far away (Settings → General → Date & Time, off
      automatic, pick Auckland or Honolulu). Reopen Today. **The number on the chip does not
      change.**
- [ ] Put the phone back on automatic before you forget.

## 7. Empty and offline

- [ ] Finish everything for the day. The **All caught up** card appears with the day's work listed
      under it, and the copy counts things saved — never consecutive days.
- [ ] An account with nothing assigned yet says **Nothing waiting**, not "All caught up". Being new
      is not an achievement.
- [ ] Airplane mode with a board already loaded: the last-known Today renders in full, with one
      quiet notice. **Not an error screen, and nothing that implies work was lost.**
- [ ] Complete something in airplane mode. **It moves to Done today the instant the sheet closes** —
      the local-over-server rule, unchanged by this phase and the thing most likely to be broken by
      a refactor of this size.

---

## 8. Two children — new Aug 16, 2026 (phase 45)

Multi-kid shipped Aug 13 and **nothing in this file covered it.** Today's board merge was one of
six local reads that were unscoped before that phase: one store holds every child's rows, so a
merge that does not filter shows a sibling's answers on this child's board.

**Setup:** two children on the account, and at least one completed entry for each.

- [ ] 8.1 With child A selected, open Today. **Every completed card is A's.** Nothing B answered
      appears, in any slot.
- [ ] 8.2 Switch to B via the pill. The board rebuilds as B's — prompts, completions and the
      caught-up state all belong to B.
- [ ] 8.3 Complete something for B, then switch back to A. **A's board is unchanged** and does not
      show B's new entry.
- [ ] 8.4 Switch children and immediately pull to refresh. The refresh belongs to the child now on
      screen — the previous child's request must not land on this board.
- [ ] 8.5 On a **one-child** account the switcher chevron is absent. One child and a chevron is a
      control that lies.

## What to write down even if everything ticks

1. **Whether the swipe is discoverable at all.** Nothing in the app teaches it. If you had not
   built this, would you find it?
2. **Whether eight seconds is right** — too long and it hovers, too short and it is a trap.
3. **Whether the skip should be undoable at all**, or whether a one-way dismiss with a confirm would
   be honester. The current design exists because the endpoint is one-way; that is a constraint, not
   a conclusion.
4. **Whether `KindBadge` is legible in daylight.** It measures roughly 3.3–3.7:1, below WCAG AA, and
   was left alone because fixing it is a design-system decision rather than a patch. A device in
   real light is the tiebreak.
