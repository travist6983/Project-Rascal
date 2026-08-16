# The widget — device verification

**This checklist matters more than most, and the reason is specific.** Every other feature in this
repo can be exercised in a simulator and mostly believed. A widget cannot. Four of the things that
decide whether this feature works at all are structurally unobservable on a simulator:

- **Refresh budget.** WidgetKit gives an extension a limited number of timeline reloads per day and
  decides itself when to honour one. A simulator does not enforce a budget and does not report the
  one it is not enforcing, so "the widget updated" there proves nothing about a phone.
- **File protection.** The snapshot is written with
  `.completeFileProtectionUntilFirstUserAuthentication` so a Lock Screen widget can read it while
  the device is locked. Simulator file protection is a no-op — the default class would look
  identical there and fail on a device after a reboot, which is both the least testable and the
  most visible way to get this wrong.
- **The monochrome render.** Accessory widgets are drawn through a mask on a real Lock Screen, over
  a real wallpaper, in whatever tint the user picked. The screenshots in
  `docs/reports/phase-11-widget/` approximate that as light-on-dark; they are not it.
- **App Group provisioning.** The simulator signs ad hoc and the entitlement simply works. A device
  needs `group.com.travisterry.childarchive` registered on the developer portal and present in both
  provisioning profiles. If it is not, `containerURL(forSecurityApplicationGroupIdentifier:)`
  returns nil, every operation degrades to nothing, and **the widget shows the neutral state
  forever with no error anywhere.** That is section 1, and nothing below it can pass until it does.

Run against a build pointed at a real API — `API_HOST` on the LAN. **Sign the build.** An unsigned
build cannot write to the keychain, every request after sign-in comes back `401`, and it reads as
an auth bug rather than a signing one.

Tick each line or write down what happened instead. A line that "seemed fine" is not ticked.

---

## 1. The App Group actually exists on the device

If this section fails, stop. Everything else measures a widget that has nothing to read.

- [ ] Build and run on the device. Xcode's automatic signing may need to register the App Group the
      first time; let it, and confirm no signing error appears.
- [ ] Open the app to Today and let it load.
- [ ] Add the **Today** widget to the Home Screen. It shows today's mission, not "Open for today's
      prompts".
- [ ] If it shows the neutral state: the container is missing. Check
      Signing & Capabilities → App Groups on **both** targets, and confirm
      `group.com.travisterry.childarchive` is ticked on each.

## 2. The five states, on glass

The simulator renders these from a harness. This is the first time they are drawn by WidgetKit.

- [ ] **Both pending.** Mission leads, question named underneath. No count anywhere.
- [ ] **One done.** Complete the mission in the app. Within a few seconds the widget promotes the
      question to the lead and shows "Mission done" beneath it.
- [ ] **Both done.** Complete the question too. The widget goes quiet and warm — a check, a line,
      no celebration, no confetti, no percentage.
- [ ] **Stale.** See section 4.
- [ ] **No snapshot.** Sign out in Settings. The widget must drop to "Open for today's prompts"
      **and lose the child's name**, on the Home Screen and the Lock Screen, within a few seconds.
      A signed-out phone still naming the child on its Lock Screen is a defect.

## 3. The push, and the budget it is meant to avoid

The app calls `reloadAllTimelines()` on every snapshot write. That is the mechanism; the timeline
is only the backstop. This section is about how well the mechanism actually holds up.

- [ ] Complete an assignment and **watch the Home Screen**. Time how long the widget takes to
      agree. Write the number down.
- [ ] Do it again, five or six times across an hour, completing and re-opening. **Does it get
      slower?** A widget that updates instantly at 9am and lags by minutes at 10am is the refresh
      budget being spent, and it is the single most important observation on this page.
- [ ] Complete an assignment with the phone in **Low Power Mode**. Note what changes.
- [ ] Complete one while **offline**. The board is local-first, so the widget must still flip to
      done — this is the case that proves the widget follows the parent rather than the network.

## 4. The day boundary — the one worth staying up for, or faking

A stale snapshot must never present yesterday's mission as today's.

- [ ] Easiest honest version: in Settings, change the child's timezone to one where it is already
      tomorrow (Pacific/Auckland from the US), let Today reload, then change it back. The widget's
      day check runs against the zone in the snapshot.
- [ ] The real version: leave the phone untouched overnight without opening the app. In the morning,
      **before opening anything**, look at the widget.
- [ ] It shows the neutral state — the child's name and "Open for today's prompts". **It must not
      show yesterday's mission**, and it must not show yesterday's mission crossed out, greyed, or
      captioned. Nothing from the previous day may be legible.
- [ ] Open the app. The widget catches up within seconds.
- [ ] Note whether it had already rolled over *before* you opened the app. That is the midnight
      timeline entry firing, and it is the one thing the app cannot do for it.

## 5. The Lock Screen, which is the reason the monochrome work exists

- [ ] Add all three accessory widgets: rectangular, circular, inline.
- [ ] Lock the phone. **Read the rectangular one.** The prompt is legible against your actual
      wallpaper, at your actual tint.
- [ ] **Can you tell a mission from a question without colour?** That is the whole question this
      design answers, and the symbol is the only thing answering it. If you cannot, say so — the
      alternative is worse, not absent.
- [ ] Circular: the symbol reads at a glance and is not a mystery glyph.
- [ ] Inline: it says "Mission waiting" or similar, whole. **It is not truncated**, and it never
      shows a piece of a prompt.
- [ ] Try a tinted Lock Screen and a photo wallpaper with a busy top third. Still legible.

## 6. Reboot — the file protection case

The one that cannot be seen in a simulator at all.

- [ ] With the widget working, **restart the phone**.
- [ ] **Before unlocking**, look at the Lock Screen widgets.
- [ ] They show today's prompts, not the neutral state. If they are blank or neutral before first
      unlock and correct after it, the snapshot's file protection class is wrong — it is being
      written as `.complete` rather than `.completeFileProtectionUntilFirstUserAuthentication`, and
      it will do this after every reboot.

## 7. The deep link

- [ ] Tap the small widget on a pending mission. The app opens **directly into the composer** for
      that prompt — not Today, not the wrong prompt.
- [ ] Tap each row of the medium widget. Each opens its own prompt.
- [ ] Tap a **done** row. It opens the entry that was written, not an empty composer.
- [ ] Tap a Lock Screen widget while the phone is locked. It asks to unlock, then lands in the
      right place.
- [ ] **The stale case.** Leave the widget on yesterday's snapshot (section 4) and tap it. It lands
      on **Today**. It must not open a composer for a prompt that has rolled over.
- [ ] Start typing in the composer, background the app, then tap a different widget prompt. The
      typed words must survive — the link takes you to Today rather than replacing an open composer.

## 8. Privacy, read over a shoulder

- [ ] Write a **sealed letter** in the app and complete that prompt.
- [ ] Look at every widget family. The widget shows the *prompt* — "Write him a letter" — and
      "Done". **Not one word of what was written.**
- [ ] Lock the phone and hand it to someone else. Ask them what they can read. Nothing they say
      should be anything the parent wrote.

## 8a. Two children — new Aug 16, 2026 (phase 45)

The widget snapshot was one of the six reads phase 31 re-scoped, and it is the one with the
longest reach: **the file it writes is what the Lock Screen renders**, so a wrong-child snapshot
is wrong on a surface nobody opens the app to check.

The rows are filtered in memory rather than in the `@Query` — a `@Query` predicate is fixed at
init and cannot capture the child. That is a correct choice and it is also the kind a later
refactor undoes without noticing.

- [ ] 8a.1 With child A selected, confirm the widget shows **A's** mission. Read the name on it.
- [ ] 8a.2 Switch to child B in the app, then background the app and look at the widget.
      **It shows B's mission**, not A's, and not a mix.
- [ ] 8a.3 Complete a mission for B. The widget reflects B. Switch to A — the widget goes back to
      A's state, and A's completion state is not B's.
- [ ] 8a.4 Check the **Lock Screen** widget as well as the Home Screen one. Both follow the switch.
- [ ] 8a.5 Force-quit the app after switching, then look at the widget. The snapshot on disk is
      the selected child's — it must not revert to whoever was selected at last launch.

## 9. Accessibility, out loud

The suite asserts the strings. It cannot hear them.

- [ ] Turn on VoiceOver. Swipe to the Home Screen widget.
- [ ] It reads as **one sentence** — "Today for Sam. Mission: … Question: …" — not as a pile of
      labels, and not five separate stops.
- [ ] A finished prompt reads "Mission, done." and **does not read the prompt back**.
- [ ] Both finished reads "Both done." once.
- [ ] The stale reading names no day and blames nobody. It must not say "yesterday" or "missed".
- [ ] Set Dynamic Type to the largest accessibility size. Check every family again:
      **no clipped text, and no word broken in half.** The layouts drop content in order — the
      name, then the second prompt's words — rather than overflowing.
- [ ] Check the Lock Screen inline widget at that size. It is a short status and stays whole.
