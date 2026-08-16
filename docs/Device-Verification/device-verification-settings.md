# Settings — device verification

Simulator screenshots satisfied the build gate. **They do not satisfy this.** Everything below
needs a real phone, because every item on it is something the simulator either fakes or cannot
reach: the share sheet's destinations, a timezone that is genuinely somewhere else, a radio that
can actually be turned off, and a keyboard attached to a hand rather than to a Mac.

Run against a build pointed at a real API — `API_HOST` on the LAN, or a deployed one once
section 3 of `docs/blocked.md` closes. **Sign the build**; an unsigned one cannot write to the
keychain, every request after sign-in comes back `401`, and it looks like an auth bug.

Tick each line or write down what happened instead. A line that "seemed fine" is not ticked.

> **Updated for Phase 13 (Settings v2), and never yet run.** This was written for PR #21 and the
> screen has since had its design pass — so §0 is new, §1 and §4 have moved, and the row names in
> them have changed. Sections 2, 3, 5, 6 and 7 are unchanged in substance and were already
> outstanding. **Run §0 first.** It is short, it is new, and it is the one that failed once
> already.

---

## 0. `Advanced` is actually there — run this before anything else

**This section exists because the bug it describes shipped and was caught by accident.**
`SyncStatusModel` was built in a `.task` that runs exactly once, and `RootView` builds the
`SyncEngine` in *its* own `.task`. Reach Settings before that second task completes and the model
was never built and never retried, so the entire `Advanced` card — dry run, reset — plus the pull
toggle, the position row and the last-attempt row were **absent for the rest of the session, with
nothing on screen saying anything was missing.**

It is fixed with `.onChange(of: syncEngine != nil, initial: true)`. What a device adds that the
suite cannot is the real ordering: launch timing on a cold device is not simulator timing, and
this failure is entirely a race.

- [ ] **Cold launch** the app (force quit first), then go to Settings **as fast as you can**.
      The `ADVANCED` card is present, with **Run a dry run** and **Reset sync position** in it.
- [ ] Same again, but this time wait on Today for ten seconds before opening Settings. Still
      present.
- [ ] In the `SYNCING` card, confirm **Last pull**, **Pull changes from the server** and — once a
      pull has been attempted — **Position** and **Last attempt** are all present.
- [ ] Switch away to Timeline and back to Settings several times. Nothing disappears.
- [ ] **Airplane mode, then cold launch straight into Settings.** The hero shows *"Waiting for
      this archive's details."* rather than a name, a notice line explains why, and `ADVANCED` is
      **still there** — the sync machinery does not depend on the child having loaded.

---

## 1. Export the archive

The highest-value row on the screen, and the one with the most that can only be seen on a
device. The development archive is ~86MB; a real one will be larger.

> Renamed in Phase 13. The row is now a card under a **KEEP A COPY** label, headed **Export the
> archive** in terracotta with the explanation underneath it. The whole card is the tap target —
> including its padding, which on the hero card was a genuine defect this phase fixed, so it is
> worth a deliberate check here too.

- [ ] **Tap near the card's outer edge**, not in the middle of the words. It starts.
- [ ] Tap **Export the archive**. Progress starts within a second or two and the percentage moves.
      It must never sit at 0% with no indication that anything is happening.
- [ ] **Scroll the rest of Settings while it runs.** The screen stays responsive and the other
      rows stay tappable — the export must not block them.
- [ ] Leave the tab and come back mid-export. Note what happens: the current build **cancels**
      on leaving, so it should return to the idle row rather than to a stale progress bar.
- [ ] Wait for **Your archive is ready** and check the size shown is plausible for the archive.
- [ ] Tap **Save or share**:
  - [ ] **Save to Files** → open Files and confirm the zip is there under the server's own
        name, `rascal-<child>-<yyyymmdd>.zip`.
  - [ ] **AirDrop to a Mac** → unzip it. Confirm `manifest.json`, `entries.json`, and
        `media/YYYY/MM/…` are present and that a photo opens.
  - [ ] **Mail or Messages** → confirm the attachment is the zip and not a 0-byte file.
- [ ] Tap **Done** afterwards, then check Settings → General → iPhone Storage for the app.
      The export is written to `Caches/exports` and deleted on Done; storage should not have
      grown by the size of the archive.
- [ ] **On cellular, off Wi-Fi**, start an export and let it run a full minute. It must keep
      moving and must not time out.
- [ ] **Interrupt it**: start an export on cellular, then enable Airplane Mode mid-download.
      The failure is calm, says the archive is safe, and offers **Try again**. Nothing is red.
- [ ] Tap **Try again** with the radio back on and confirm it completes.

## 2. Timezone

The value the server's scheduler uses to decide when a new day starts, so this is the one edit
with a consequence a day later.

- [ ] Open **Archive → Timezone**. The search is seeded with this phone's own city.
- [ ] Search for a city on another continent, pick it, save. The row updates immediately.
- [ ] Confirm the sheet said, quietly and in one line, that new prompts arrive in the morning
      in this timezone. It must not be a warning box.
- [ ] **Come back the next morning** and confirm the Today board rolled over on the new zone's
      schedule rather than the old one. This is the only item here that takes a day, and it is
      the only one that proves the setting does what it says.
- [ ] Set it back.

## 3. Birthday, and the correction that is not automatic

- [ ] Open **Archive → Birthday**. Confirm the picker shows **the same day** as the row behind
      it. (A UTC/local mismatch here showed a June 1st birthday as May 31st in the simulator;
      it is fixed, and it is worth one glance on a device in a different zone.)
- [ ] Change the birthday by one day and save. The row updates.
- [ ] Go to **Timeline** and open any entry. **Its age chip has not changed.** That is correct
      and deliberate — stored ages are not rewritten by a birthday edit.
- [ ] Go to **Settings → Corrections → Recompute ages from birthday**. Confirm the card sits in
      its own card with clear space above it, not adjacent to an edit row.
- [ ] Tap it. The confirmation says plainly what will happen. Cancel — nothing changes.
- [ ] Tap it again and confirm. It reports a count.
- [ ] Return to **Timeline** and confirm the age chips now reflect the corrected birthday.
- [ ] Run it a second time. It reports **0** and that reads as a normal outcome, not a failure.
- [ ] Set the birthday back and recompute again.

## 4. Sync status, with the radio off

> Restyled in Phase 13. The card now has a **summary head** rather than a plain row: eyebrow,
> count, one sentence, and it **washes `terracottaSoft` while anything is outstanding**. The head
> is the thing to watch here — this is the only place in the app that uses tint to mean "live",
> and the whole point is that it must not read as an alarm.

- [ ] With everything synced, confirm the head reads **SYNC** / **Everything's uploaded.**, is
      **untinted**, shows **no dot** and **no counter**, and that there is **no Retry now row at
      all** — not a disabled one.
- [ ] Turn on **Airplane Mode**.
- [ ] Write two entries, one with a photo.
- [ ] Return to Settings. The head flips to **UPLOADING**, gains the terracotta dot and a
      **`N left`** counter, and the sentence names entries and files separately. The count is
      phrased as waiting, never as failure. **No badge, no red, no exclamation.**
- [ ] **Look at the wash and ask whether it reads as a warning.** It should read as "this is
      happening", the same terracotta everything else in progress uses. If it reads as an alarm,
      write that down — that is a design finding, not a bug.
- [ ] Confirm the counter and the sentence agree. "3 left" over "1 entry and 2 files still to
      upload" is right; any disagreement between the two numbers is a defect.
- [ ] Tap **Retry now** while still offline. It fails quietly, the row shows **Retrying** and is
      disabled while it runs, and the count stays. Nothing alarming appears.
- [ ] Turn Airplane Mode off. Tap **Retry now**.
  - [ ] The count drops to zero, the **Retry now** row disappears entirely, and the head returns
        to the untinted **Everything's uploaded.**
  - [ ] Check the Timeline: the entries are there once each, not twice.
- [ ] Repeat, but instead of tapping Retry, background the app and reopen it. The sweep runs on
      foreground and the count clears on its own.

## 5. Keyboard and safe area, on a device with a notch and a home indicator

For each sheet — **Archive** and **Account**:

- [ ] Open it. The keyboard appears without covering the field being edited.
- [ ] Scroll while the keyboard is up. Nothing is trapped underneath it.
- [ ] Confirm **Save** is reachable with the keyboard up.
- [ ] Confirm Save is **disabled** until something changes, and disabled again while saving.
- [ ] Dismiss with the swipe-down gesture. Nothing is saved and nothing is lost from the form
      if you reopen it.
- [ ] Rotate to landscape. Nothing clips and the content stays inside the safe area.
- [ ] With **Dynamic Type at an accessibility size** (Settings → Accessibility → Display & Text
      Size → Larger Text), reopen both sheets. Labels wrap rather than truncate and no row
      overlaps another.

## 6. The account row, on a real Sign in with Apple account

Only possible once Apple Developer enrollment closes — `docs/blocked.md` section 1.

- [ ] Sign in with Apple choosing **Hide My Email**. Confirm the Email row shows the relay
      address, or **Not provided** if Apple sends none. It must never be blank.
- [ ] Open **Account**, change your name, save. The row updates.
- [ ] **Force quit and relaunch.** Note what the Your name row shows. The current build cannot
      refetch the user record — there is no `GET /me` — so it renders no value rather than
      claiming "Not set". If that reads badly on a real device, that is the argument for asking
      Lane A for a `GET /me`.
- [ ] Try to save a blank name and a very long one. Both are refused with the server's own
      wording under the field, not a generic error.

## 7. Sign out

- [ ] With something still waiting to upload, sign out. The confirmation says the archive stays
      on the server and unfinished uploads resume after signing back in.
- [ ] Confirm you land on the signed-out screen and **stay there** — nothing signs you back in
      on its own.
- [ ] Sign back in. Confirm the waiting items are still queued and still upload.

---

## 8. The child hero — new in Phase 13

The screen's new opening element, and the design import's whole argument: Settings should open on
the child rather than on configuration.

- [ ] The card shows the terracotta disc with the child's **initial**, the **name**, and
      **"4 years, 1 month · born June 19, 2022"** underneath.
- [ ] **Tap the outer edge of the card, well away from the words** — the top-left corner above
      the avatar, and the strip just inside the right-hand hairline. Both open the edit sheet.
      *(This is the defect the phase found: the padding used to sit outside the tap target.)*
- [ ] Change the name in the sheet and save. The hero updates without a refetch.
- [ ] Change the birthday and save. The hero's **age does not move** — it is the server's
      `age_months` — and the born date does. Then confirm no entry's stored age changed.
- [ ] Cold launch with **Airplane Mode** on. The hero shows the plain disc and *"Waiting for this
      archive's details."*, and the notice line below explains the network. The card is **not
      tappable** in this state.
- [ ] A child whose name begins with an accented letter or an emoji renders **one glyph** in the
      disc, not a box and not half a pair.

### 8a. The stats strip — new Aug 16, 2026 (phase 44)

Shipped after this checklist was written and had no boxes until now. It reads
`412 entries · 1,204 photos · 3 sealed`, from `GET /children/{id}/stats`. **Three owner decisions
are embedded in it and each one is only checkable on a device.**

- [ ] 8a.1 The strip renders under the born-date line, with an **`Archive starts <date>`** line
      above it when the archive has a first entry.
- [ ] 8a.2 **The middle cell counts photographs, not media.** On a child with voice notes and
      videos, the photo count must be **lower** than the total number of files. Count them if you
      have to. Video and audio are deliberately not counted here and the timeline still shows
      every one of them.
- [ ] 8a.3 **Cold launch with Airplane Mode on.** The strip **does not render at all** — no strip,
      no dashes, and above all **no zeros**. Nil is not zero: a strip reading `0 entries` about an
      archive with four hundred is the worst thing this line can say.
- [ ] 8a.4 Watch a cold launch **with** the network. The strip appears when the server answers.
      It must not flash zeros first and then correct itself.
- [ ] 8a.5 On a child with **no entries at all**, the strip and the archive-start line are both
      **absent** — an empty archive shows nothing rather than three zeros.
- [ ] 8a.6 On an archive with more than a thousand of anything, the number is **grouped**
      (`1,204`, not `1204`).
- [ ] 8a.7 On a child with exactly **one** entry, one photo, one sealed letter, the words are
      singular — `1 entry · 1 photo · 1 sealed`.

### 8b. Adding a child — new Aug 16, 2026 (phase 44)

Multi-kid shipped Aug 13 and its **only** entry point is here, deliberately: the switcher's
chevron does not exist until there are two children, which is precisely the account that needs to
add one. Nothing in this file covered it.

- [ ] 8b.1 On a **single-child account**, the `Children` section shows one `Add a child` row. There
      is no list of children beside it — the switcher is the list.
- [ ] 8b.2 Add a second child. The sheet is a plain create, **not** the full setup flow — it must
      not ask again about notifications, which this account already answered.
- [ ] 8b.3 A successful add **switches to the new child**, and the hero, the timeline and Today all
      show the new one.
- [ ] 8b.4 **The switcher chevron now exists.** It did not before there was a second child.
- [ ] 8b.5 Switch back to the first child and open the timeline. **You see that child's entries and
      not the sibling's.** This is the check that matters most in this section — every child-bound
      object captures its child at init, so a switch that half-applied would show one child's
      entries under the other's name.
- [ ] 8b.6 With two children, complete something for child A, then switch to B. B's Today is B's,
      and nothing from A appears on it.
- [ ] 8b.7 Sign out with two children on the device, then sign back in. Nothing from either child
      survives the sign-out, and the switch state does not resurrect a child that was erased.

## 9. Accessibility on glass — Dynamic Type and VoiceOver

Dynamic Type XXL was generated on a simulator (`docs/reports/phase-13-settings-v2/`) and nothing
clipped. **VoiceOver was not run** — it cannot be driven from a CLI — so everything in the second
list is derived from source and needs a real ear.

- [ ] Dynamic Type at the **largest accessibility size**, not just XXL. Scroll the whole screen.
      Nothing clips, nothing overlaps, every card grows with its text.
- [ ] The **closing note** at the bottom clears the floating tab bar when scrolled to the end.
- [ ] With **Reduce Motion** on, the tap-scale on rows and the hero is skipped and taps still
      register.

Turn VoiceOver on and swipe through the screen top to bottom:

- [ ] The hero reads as **one** element: *"Hendrix, 4 years 1 month old, born June 19, 2022,
      button"*, with the hint *"Opens name, birthday and timezone"*. Not four separate swipes.
- [ ] The sync card's head reads as one element and **does not say the count twice** — the
      counter is deliberately left out of the spoken label because the sentence already carries
      the number.
- [ ] Open the **rotor → Headings**. It should list the section names — THE ARCHIVE, YOU, KEEP A
      COPY, SYNCING, ADVANCED, APP, CORRECTIONS — and **must not** list the sync card's summary
      sentence among them.
- [ ] **Recompute ages from birthday** announces as a button, reads its explanation, and its
      confirmation dialog is announced when it opens.
- [ ] **Sign out** announces as a button and its confirmation is announced.
- [ ] The **Pull changes from the server** toggle announces its on/off state and its caveat line.
- [ ] Every chevron is silent — the rows carry their own labels and a chevron says nothing.
