# Settings — device verification

Simulator screenshots satisfied the build gate. **They do not satisfy this.** Everything below
needs a real phone, because every item on it is something the simulator either fakes or cannot
reach: the share sheet's destinations, a timezone that is genuinely somewhere else, a radio that
can actually be turned off, and a keyboard attached to a hand rather than to a Mac.

Run against a build pointed at a real API — `API_HOST` on the LAN, or a deployed one once
section 3 of `docs/blocked.md` closes. **Sign the build**; an unsigned one cannot write to the
keychain, every request after sign-in comes back `401`, and it looks like an auth bug.

Tick each line or write down what happened instead. A line that "seemed fine" is not ticked.

---

## 1. Export the archive

The highest-value row on the screen, and the one with the most that can only be seen on a
device. The development archive is ~86MB; a real one will be larger.

- [ ] Tap **Export archive**. Progress starts within a second or two and the percentage moves.
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

- [ ] With everything synced, confirm the row reads **Everything's uploaded** and offers no
      action.
- [ ] Turn on **Airplane Mode**.
- [ ] Write two entries, one with a photo.
- [ ] Return to Settings. The count appears and is phrased as waiting, never as failure. **No
      badge, no red, no exclamation.**
- [ ] Tap **Retry now** while still offline. It fails quietly and the count stays. Nothing
      alarming appears.
- [ ] Turn Airplane Mode off. Tap **Retry now**.
  - [ ] The count drops to zero and the row returns to **Everything's uploaded**.
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
