# The share sheet — device verification

> **Two names appear below and only one of them moved.** The app the share sheet shows is
> **Chronicle** — that is `CFBundleDisplayName`. ~~It read **Vellum** from Aug 17, 2026~~, and four
> boxes here still said "Rascal" until Aug 16, 2026, which would have failed a correct build.
> **Since Aug 27, 2026 the display name and the store name are different strings**: the store name
> is *Pocket Chronicle* and the label iOS renders — here, on the home screen, and in Settings — is
> *Chronicle*. Every box below names the one the surface actually shows. The **target** is still `RascalShare` and the
> entitlements file is still `Rascal.entitlements`: those are build-system identifiers, no parent
> ever sees them, and renaming them would cost a provisioning round trip for nothing. Do not
> "fix" them.

**This checklist matters more than most, for a reason that is specific and not rhetorical.** A
share extension is a *separate process the system starts, constrains, and kills*, and almost
nothing about that is reproduced in a simulator. Five things this feature's correctness rests on
are structurally unobservable there:

- **The memory ceiling.** A share extension gets a hard footprint limit — on the order of 120MB on
  recent devices, and the number is neither published nor stable. **A simulator does not enforce
  one at all.** The whole stage-don't-upload architecture exists because of that ceiling, and the
  simulator cannot tell you whether the design was necessary or whether it was enough. Section 3.
- **Real assets.** Every photo in the suite and in `docs/reports/phase-12-share-extension/` is a
  generated 400×300 JPEG. A real camera roll holds 48MP HEICs, Live Photos, slow-motion, ProRes,
  screenshots, PNGs from Messages, iCloud photos that are **not on the device**, and edited photos
  whose EXIF has been rewritten. Section 2 and section 4.
- **iCloud Photo Library.** A photo that lives only in iCloud has to be downloaded before
  `loadFileRepresentation` can hand over a file. That path does not exist on a simulator. It is the
  most likely source of a slow or failing share on a real phone, and nothing in this repo has
  exercised it. Section 5.
- **App Group provisioning.** The simulator signs ad hoc and the entitlement simply works. A device
  needs `group.com.travisterry.childarchive` registered on the developer portal and present in
  **three** provisioning profiles now — app, widget, and share extension. If it is missing from the
  extension's, `containerURL(forSecurityApplicationGroupIdentifier:)` returns nil and the sheet
  says it cannot save. Section 1, and nothing below it can pass until it does.
- **The share sheet itself.** The extension has never been launched by the system. Every screenshot
  in the report is the real `ShareComposer` rendered inside the *app* by a launch-argument harness,
  because a share sheet cannot be opened from a CLI. The harness was deleted before this branch was
  pushed. Presentation, sizing, keyboard behaviour and dismissal are all unverified.

Run against a build pointed at a real API — `API_HOST` on the LAN. **Sign the build.** An unsigned
build cannot write to the keychain, every request after sign-in comes back `401`, and it reads as
an auth bug rather than a signing one.

Tick each line or write down what happened instead. A line that "seemed fine" is not ticked.

---

## 1. The App Group exists for the *third* target

If this fails, stop. Everything below measures an extension with nowhere to write.

- [ ] Build and run on the device. Let automatic signing register the App Group for `RascalShare`
      the first time; confirm no signing error appears for any of the three targets.
- [ ] Open Photos, pick one photo, tap Share, and find **Chronicle** in the row of apps. It may be
      behind **More** the first time — if so, pin it, and note that a parent will have to.
- [ ] The sheet opens on the cream canvas with **Add to the archive**, a tile, a date and Save.
- [ ] If it instead says *"This can't be saved right now"*: the container is missing. Check
      Signing & Capabilities → App Groups on **all three** targets and confirm
      `group.com.travisterry.childarchive` is ticked on each.

## 2. The date, which is the point of the whole phase

**This is the section to run first if you only run one.** A photo filed under the wrong day looks
completely normal and stays wrong forever.

- [ ] Share a photo **taken years ago** — scroll the library back, do not use a screenshot. The
      capsule shows that photo's date, not today, and the line beneath reads *"Read from the
      photo."*
- [ ] Open the app. The entry appears on the Timeline **grouped under the year it was taken**, not
      under today.
- [ ] Check the entry's detail: "when it happened" is the photo's date, and the entry was created
      today. The two must not be the same.
- [ ] Share a **screenshot** (screenshots carry a creation date but often no `DateTimeOriginal`).
      Note which branch it takes — if it says *"Read from the photo"*, check the date is the day the
      screenshot was taken and not something odd.
- [ ] Share an **edited** photo — crop something in Photos first. Apple rewrites metadata on edit;
      confirm the original capture date survives, and write down what happens if it does not.
- [ ] Share a photo **with no date at all** if you can find or make one. The capsule says **Today**
      and the line reads *"This photo doesn't say when it was taken, so today is standing in."*
- [ ] **The timezone case.** Set the phone to a timezone several hours from home (Settings →
      General → Date & Time), share a photo taken late in the evening, and confirm the date shown is
      the day printed in Photos — not the day before or after. Set the timezone back afterwards.

## 3. Memory — the thing a simulator cannot tell you

The extension copies files with `FileManager.copyItem` and never reads one into memory.
`ShareInboxTests` measures a peak footprint across a 160MB file **in the app's process**, which has
no ceiling. This is the first time the code runs somewhere that does.

- [ ] Share **one 4K video of at least two minutes** (~250MB+). The sheet must reach the ready state
      and Save must work. If the sheet vanishes, that is a jetsam kill, not a cancel.
- [ ] Share **ten photos at once** from a modern iPhone camera (48MP HEIC). Same.
- [ ] Share **five videos at once.** This is the worst case the activation rule permits and the one
      most likely to fail.
- [ ] Attach Instruments' Allocations to the extension (Xcode → Debug → Attach to Process by
      name → `RascalShare`) during the 4K video share and **write the peak footprint down here**.
      It is the only real number this feature will ever have:

      peak observed: ______ MB    device: ______________    iOS: ______

- [ ] If any share dies: check Settings → Privacy & Security → Analytics → Analytics Data for a
      `RascalShare` jetsam log and record the `pageSize`/`rpages` figures.

## 4. Types the activation rule lets in

`NSExtensionActivationRule` accepts anything conforming to `public.image` or `public.movie`, which
is wider than "photos and videos from Photos".

- [ ] **Live Photo.** Shares as its still image. One tile, one entry, no error.
- [ ] **Slow-motion video.** Confirm it stages, and check what the app's transcode does to it —
      `VideoPipeline` is 1080p H.264 and may flatten the slow-motion ramp. Write down what happens;
      this is a known unknown rather than a checked behaviour.
- [ ] **A GIF**, shared from Messages or Files. It will be archived as a **still JPEG of the first
      frame** — the app's existing HEIC→JPEG path does this and the share sheet inherits it. Confirm
      that is what happens and decide whether it is acceptable.
- [ ] **A PDF** or a **web page** from Safari. Chronicle must **not appear** in the share sheet at all.
      If it does, the activation rule is not doing its job.
- [ ] **A contact card** or a **text selection.** Same — Chronicle must not be offered.

## 5. iCloud Photo Library, which the simulator has never had

- [ ] Turn on **Optimise iPhone Storage** and find a photo that is not resident on the device (an
      old one, after the phone has been low on space).
- [ ] Share it. Record how long the sheet spends on *"Getting it ready…"* — the download happens
      inside `loadFileRepresentation` and the parent is watching it.
- [ ] Share one while in **Airplane Mode**. The extension has no network entitlement, so the
      download cannot happen. Record what the sheet does: it should either stay on "Getting it
      ready…" or land on the cannot-save message. **It must never save an entry with nothing in
      it.**
- [ ] Note whether the "Getting it ready…" line needs a way out. It currently has Cancel and
      nothing else.

## 6. The drain, and the ordering it depends on

- [ ] Share a photo with the app **fully quit** (swipe it out of the app switcher first). Open the
      app: the entry appears on Today's in-flight count and then on the Timeline.
- [ ] Share a photo with the app **already open in the background**. Foreground it. Same result —
      `runSweep` runs on `scenePhase == .active` as well as at launch.
- [ ] **Airplane Mode drain.** Turn on Airplane Mode, share three photos, open the app. The entries
      appear locally and are queued. Turn Airplane Mode off; they push, then their media uploads.
      **Nothing is lost and nothing is duplicated.**
- [ ] **Kill mid-drain.** Share five large photos, open the app, and force-quit it while the
      conversion is still running. Reopen. Exactly five media on exactly one entry — no second
      entry, no missing photo.
- [ ] **Storage.** After a drain completes and the entry has synced, check that the share-inbox copy
      is gone: Settings → General → iPhone Storage → Chronicle. Sharing a 250MB video should not leave
      500MB behind once it has uploaded.

## 7. Cancelling, and the bytes it leaves

- [ ] Share a large video and tap **Cancel**. Open the app, then check storage. The staged copy
      should be gone.
- [ ] Share a large video and **swipe the sheet down** instead of tapping Cancel. This takes a
      different path — `viewDidDisappear` rather than the button — and is the one most likely to
      leak. Confirm storage is reclaimed after the next app launch, which runs the orphan sweep.

## 8. Signed out, and before onboarding

The extension deliberately does not know which child a share belongs to; the app resolves that at
drain time. So a share made before there is a child is *held*, not lost — and nothing tells the
parent that.

- [ ] Sign out in Settings, then share a photo. The sheet saves normally.
- [ ] Sign back in. The entry appears.
- [ ] On a **fresh install**, share a photo before completing onboarding. Then onboard. The entry
      should appear afterwards. **Write down how long it sat and whether anything anywhere said it
      was waiting** — if this feels like a lost photo, that is a real finding and the fix is a
      surface in the app, not a change to the extension.

## 9. Accessibility on glass

The XXL screenshots are real renders but were taken in the app's window, not in a share sheet,
which is shorter.

- [ ] Set Dynamic Type to **XXL** and share one photo. Nothing clipped, Save still reachable.
- [ ] Same with **five** photos, where the date explanation wraps to two lines.
- [ ] Turn **VoiceOver** on and share a photo. Swipe through every element: Cancel, the heading, the
      tile ("Photo" / "Photo 1 of 5"), "When it happened", the date and its explanation as one
      utterance, the note field, and Save with its "Files one entry" hint.
- [ ] Confirm the tile is reachable and reads as a photo. It is a decorative thumbnail with an
      explicit label; if VoiceOver skips it, the count is invisible to a blind parent.
- [ ] Turn on **Reduce Motion** and confirm nothing animates unexpectedly.
- [ ] With VoiceOver on, confirm the *"Getting it ready…"* state is announced. A silent screen that
      then changes under you is the worst case here.

## 10. The things this checklist cannot settle

Write findings here rather than in a commit message.

- [ ] **Is the twelve-second promise kept?** Time it, from opening Photos to the sheet dismissing,
      one-handed, with a real photo. Three taps is the design; the clock is the test.
- [ ] **Does the date get read?** The whole feature turns on a parent noticing a wrong date before
      saving. Watch someone else use it once and see whether they look at the capsule at all.
- [ ] **Is one-entry-per-share right?** Sharing five photos of one afternoon makes one entry. Share
      five photos of five *different* days and see whether the earliest-date rule produces something
      a parent finds surprising.
- [ ] **Dedup.** Share the same photo twice, deliberately. Two entries. Decide whether that is
      correct — the current position is that it is, because the same photo on two days is a
      legitimate pair — or whether it needs a warning.
