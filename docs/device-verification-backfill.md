# Camera-roll backfill — device verification

**Nothing in this feature has met a real camera roll.** Every assertion runs against a stub source
of `Date` values, so the scan is proven as arithmetic and unproven as a thing that runs on a phone
with years of photos on it.

**Aug 11, 2026: the surface and the picker now exist, so every section below can be run.** The
flow is **+** → *Add to the archive* → *Browse your camera roll* → permission explainer → scan →
suggestions → a month → pick photos from **one day** → a prefilled composer.

Two things to watch for that no test can reach:

- [ ] **The permission explainer is the only thing standing between you and a one-shot iOS
      prompt.** Tap "Not now" first and confirm nothing was asked. Then reopen and grant.
- [ ] **A month whose photos are all in iCloud.** Every tile should say so and none should be
      selectable — and nothing should download while you sit on that screen. Watch the network.

---

## 0. The one that matters most, and no test can tell you

**Does the scan finish, and what does it cost?** A library with 40,000 assets is the normal case
for a parent with a kid, not the extreme one.

- [ ] Run against a real library. Write down the asset count and how long the first scan takes.
- [ ] The app stays responsive throughout — scroll the timeline while it runs.
- [ ] Watch memory in Instruments. Write the peak down; it is the only real figure this feature
      would have.
- [ ] Kill the app mid-scan. Relaunch. Nothing is corrupt and no half-built list appears.
- [ ] Second launch uses the cache and does not re-scan.

## 1. Metadata, which is where the archive gets quietly wrong

**A photo filed under the wrong month looks completely normal forever.**

- [ ] Find a photo with **no** `DateTimeOriginal` — an old import, a screenshot, something from
      WhatsApp. Confirm the month it lands in is the month being backfilled, **not today**.
- [ ] Find a photo whose metadata was **edited** after the fact. Confirm what the scan does with
      it, and whether that matches what you would have wanted.
- [ ] Photos taken **abroad**, in a different timezone from the device. Confirm the month.
- [ ] A photo taken within a few hours of midnight on the 1st or the last of a month. This is
      where a timezone difference changes the answer.

## 2. iCloud — blocked until the surface exists

- [ ] A month whose photos are **not on the device**. The count is honest about it and nothing
      stalls.
- [ ] No iCloud download is triggered by scanning. Watch the network.
- [ ] Selecting a cloud-only asset either downloads it deliberately or says it cannot — never
      presents it as available and then fails.

## 3. Limited access — blocked until the surface exists

- [ ] Grant **selected photos only**. The scan runs, reports what it can see, and reads as a
      working feature rather than an error.
- [ ] Add more photos to the selection. Confirm the scan picks them up.

## 4. The offer, and how it feels

**This is a judgment, and it is the reason the no-guilt rule exists.**

- [ ] Read the suggestion as a parent who has not logged anything in four months. Does it read as
      an invitation, or as a tally of what you failed to do?
- [ ] Dismiss a month. Confirm it stays dismissed across a relaunch.
- [ ] Confirm nothing anywhere counts empty months at you.
