# Device verification — the photo caption check

**9 boxes.** Needs a TestFlight build and **a real camera roll** — years of it, from a real phone.
A simulator's photo library is a handful of Apple-supplied samples and answers nothing.

**This is not a feature checklist. It is a measurement, and its result decides a phase.**

Phase 33's device half has no API to call: `FoundationModels`' entire input vocabulary is
`Transcript.Segment`, which is text or structure, so there is no pixels-to-prose call and no way to
generate a caption on device. `docs/blocked.md` §9 carries the grep that re-checks it.

The one thing that does exist is `MAImageCaptioningCopyCaption`, and it is a **metadata accessor,
not a model**: it reads the XMP field `Iptc4xmpExt:AOContentDescription` and returns nil when
nobody wrote one. It invents nothing, which is exactly why it is interesting — a caption a human
already wrote cannot be a permanent plausible lie about somebody's child.

**Whether it is worth building rests entirely on one number that nobody has measured:** what
fraction of a real camera roll carries that field. If it is near zero, the device half ships a
queue that is permanently empty and a Settings row that reads "0 waiting" forever, which is the
furniture this app refuses. So this measures first.

**Settings → Sync card → Photo caption check.** Nothing is uploaded, nothing is saved, and no
photo is pulled down from iCloud.

Tick a box or write down what happened instead. A line that "seemed fine" is not ticked.

---

## §1 — Run it

- [ ] 1.1 The row is present under the sync card. *(It is not behind `#if DEBUG` on purpose — the
      only phone with a real camera roll is running a release build.)*
- [ ] 1.2 Grant photo access if asked, then tap **Run the check**. It finishes without the app
      becoming unresponsive.
- [ ] 1.3 **Write the numbers down. This is the whole point of the exercise:**
      - Photos read: ______
      - With a description: ______
      - Share: ______%
      - In iCloud, not read: ______
      - Could not open: ______
- [ ] 1.4 If any captions were found, copy them here verbatim — the quality matters as much as
      the count, because a description written for accessibility may not be a sentence anybody
      wants in an archive:
      _______________________________________________
      _______________________________________________

## §2 — The things that would make the number a lie

- [ ] 2.1 **Watch cellular data during the run** (Settings → Cellular, or run it in Airplane Mode
      with iCloud photos present). **No photo may be downloaded.** The check sets
      `isNetworkAccessAllowed = false`; if data moves, the measurement is being taken on assets it
      should have skipped and the "in iCloud, not read" figure is wrong.
- [ ] 2.2 If **"Could not open"** is a large share of what was walked, the "Share" figure is
      measured over a small sample and must be read as provisional. Say so when writing it down.
- [ ] 2.3 Run it on a phone whose library is **mostly iCloud-only**. It should report almost
      everything as "in iCloud, not read" and a small "photos read", rather than reporting a
      confident 0%.
- [ ] 2.4 Tap **Stop** mid-run. It stops, and the screen returns to idle rather than showing a
      half-counted result as though it were finished.

## §3 — The answer

- [ ] 3.1 Decide, and write the decision down rather than leaving it in the numbers:
      **near-zero → 33 closes and the probe is deleted**; **meaningfully non-zero → 33 gets a real
      phase**, with the caption state ladder, a provenance distinction (`docs/decisions.md`), and
      the clobber guard that comes with having a writer at all.
      Decision: _______________________________________________

---

## What to write down regardless

- The device, iOS version, and roughly how many photos are in the library: _______________
- Whether the library is mostly on-device or mostly iCloud: _______________
- **This measurement is only as good as the library it ran against.** One phone is one data point,
  and a photographer's roll and a parent's roll are not the same population. If the answer is
  close to the line, run it on a second phone before deciding.
