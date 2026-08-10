# Phase 12 — the share sheet

A photo goes from Photos into an entry in three taps. The roadmap has listed this in P1 since the
beginning and nothing had ever been built for it.

The design principle every feature here is measured against is that capture costs under fifteen
seconds, one-handed. The share sheet is the shortest path iOS has, and it is the only capture route
that **starts where the photos already are** — every other one starts by opening the app.

---

## The architecture, and why it is not the obvious one

**The extension stages. The app drains.**

The extension copies the incoming media into the App Group container the widget already opened,
writes a small versioned record beside it, and exits. On the next launch or foreground the app
turns that record into an `Entry` and its `Media` rows, through `ImagePipeline`, `VideoPipeline`,
`StagingStore` and the sweep the composer already uses. Nothing about upload, auth or retry is
duplicated anywhere.

The obvious design — upload from the extension, because the parent is already there and the bytes
are already in hand — fails three ways:

1. **The memory ceiling.** A share extension gets a hard footprint limit; a 4K minute is ~250MB. A
   transcode or an upload inside that process is a crash waiting for a large file, and the crash
   looks to a parent like the sheet vanishing.
2. **The session.** A token refresh running inside an extension, concurrently with the app, can
   invalidate the app's own session. It is intermittent and very hard to attribute. The widget was
   given no network for exactly this reason and the same answer applies.
3. **The ordering.** `POST /media/upload-url` needs an `entry_id` the server recognises, so entries
   must be confirmed before their media is pushed. An extension uploading independently breaks an
   ordering the whole sync design rests on, and pays for it in 404s.

The cost is a delay between sharing and the archive holding the photo. It is invisible: the entry
exists locally the moment the extension exits, and the drain runs on the very next foreground.

```
Photos ──► RascalShare ──► App Group ──► Rascal.app ──► EntrySync ──► API
            (copy +         share-inbox/    ingest        push entry,
             record)        records/        convert       then media
                            media/          + rows                     ──► reap
```

---

## The date, which is the actual content of this phase

**A photo shared from Photos is usually not from today.** Defaulting `occurred_at` to now would
file a 2019 photo under this week, and that error has the worst possible shape: the entry looks
completely normal, it is on the wrong day, and nothing will ever flag it. In an archive whose whole
claim is that it knows when things happened, it is the one defect that compounds.

So:

- `occurred_at` is read from EXIF `DateTimeOriginal` for a photo and the asset's creation date for a
  video, through the app's own `ImagePipeline.exifDate` rather than a second reader.
- A multi-select takes the **earliest** date among them. Three photos from one afternoon belong on
  that afternoon, and one of them being undated must not drag the entry forward to today.
- `now` is used only when nothing carried a date, and **the record says which happened**, so the
  screen can tell the parent that today is standing in rather than presenting a guess as a fact.
- `created_at` stays the moment Save was pressed. The two are never conflated.

`MediaDraftBuilder.suggestedOccurredAt` now calls the same function, so the composer's picked-photo
rule and the share sheet's are one rule rather than two that happen to agree today.

**Shown, not editable.** The capsule carries `DatePill`'s vocabulary — the same "Today"-or-the-full-
date wording, the same surface-on-cream capsule — but not its graphical picker: a month grid is most
of a share sheet, and the entry is editable in the app the moment the drain files it. What this
screen owes a parent is the chance to *notice*, and §10 of the device checklist is where we find out
whether it is taken.

---

## The screenshots

Every image is a real render of the real `ShareComposer`, through the real `ShareComposerModel` and
the real `ShareItemLoader`, staging real JPEGs into a real `ShareInbox`. **Nothing is stubbed but
the source of the files.**

A share sheet cannot be opened from a CLI — it needs a tap in Photos — so the views were rendered
inside the app, driven by a launch argument. **The harness was deleted before this branch was
pushed**; `git show --stat` on the feature commits will not find it and neither will the project
file.

| State | Default type (`large`) | Dynamic Type XXL |
| --- | --- | --- |
| One photo carrying an EXIF date | `single-dated-large.png` | `single-dated-xxl.png` |
| Five photos with no date — the fallback | `multi-fallback-large.png` | `multi-fallback-xxl.png` |
| Nothing shareable | — | `unusable-xxl.png` |
| Copying the bytes in | — | `staging-xxl.png` |

`single-dated-xxl.png` is the one to look at. A photo carrying `2019:07:04 14:30:00` produces a
capsule reading **July 4, 2019** and the line *"Read from the photo."* — at the largest type size,
with nothing clipped and Save still on screen. That frame is the phase.

### What the screenshots found

**A grammar defect the tests passed over.** The fallback sentence read *"These files don't say when
**it** was taken"* — a plural subject with a singular verb. The suite asserted
`hasPrefix("These videos don't")` and `contains("today is standing in")`, both of which were true of
the broken sentence. A partial assertion on a sentence tests that the sentence exists, not that it
reads. Fixed, and the assertions are whole sentences now.

**A screenshot that lied about itself.** The harness used a fixed fake `now` so the images would be
reproducible, which produced *"August 6, 2026"* above *"today is standing in"* — incoherent, and not
a thing any parent would ever see, since `openedAt` is genuinely now in production. The harness uses
the real clock and the frame says **Today**.

Two things looked wrong and are not. The fifth tile in the multi shot is off the right edge behind a
horizontal scroll, with the `+1` tile after it — the same behaviour `MediaPreviewRow` has had since
phase 2. And the unusable state shows both **Cancel** and **Close**; the header is deliberately
identical in every state, and Close is the action rather than a second escape.

---

## Accessibility

### Dynamic Type XXL — generated, and each frame read individually

`xcrun simctl ui <udid> content_size extra-extra-large`, the same method as the phase 8, 10 and 11
reports. **Nothing is clipped or truncated in any of the four XXL frames.** The date explanation
wraps to two lines at XXL and the layout absorbs it; the whole screen is a `ScrollView` above a
pinned Save bar precisely so that it can.

One method note, because it cost a full set of images: **`content_size default` is not a valid
argument** — `simctl` returns "Invalid argument" and leaves the previous value in place. iOS's
default is `large`. The first pass produced two byte-identical files per pair, both at XXL, and the
only reason it was caught is that the file sizes matched exactly.

### VoiceOver — **audited by reading the tree, not by running VoiceOver**

Stated plainly because the brief asks which is which: **no screen reader was run.** VoiceOver cannot
be driven from a CLI and Accessibility Inspector is a GUI. What follows is derived from the
accessibility modifiers in the source, and §9 of `docs/device-verification-share-extension.md` is
where it gets checked on glass.

| Control | Reads as | Derived from |
| --- | --- | --- |
| Cancel | "Cancel, button" | A plain `Button` with a text label |
| Title | "Add to the archive, heading" | `.accessibilityAddTraits(.isHeader)` |
| Heading above the tiles | "1 PHOTO" / "5 PHOTOS", heading | `SectionLabel`, which carries `.isHeader` |
| A preview tile | "Photo" alone, or "Photo 2 of 5"; a video adds its duration spoken, not as a clock | `ShareCopy.mediaLabel`, on an explicit `.accessibilityElement()` — a thumbnail says nothing to a screen reader, so position and count carry what the row conveys visually |
| The `+N` tile | "2 more, also being saved" | Explicit label; "+2" alone would read as a fragment |
| The date block | One utterance: "When it happened, July 4, 2019. Read from the photo." | `.accessibilityElement(children: .combine)` with an explicit label — three separate elements would make the parent swipe three times for one fact |
| Note field | "Note, optional" | Explicit label; the visual label is a small-caps section header the field is not bound to |
| Save | "Save to the archive, button", hint "Files one entry holding all 5" | Explicit label and hint. **The hint is where the one-entry-per-share rule is said out loud** — a parent sharing five photos should know they are making one entry |
| "Getting it ready…" | One element, that text | `.accessibilityElement()` with a label |

The copy in that table is asserted in `ShareCopyTests` rather than only screenshotted, which is why
`ShareCopy` exists as a shared type instead of living inside the extension's views: the extension is
its own module and the test host is the app, so a string built inside `ShareComposer` could only
ever have been checked by looking at a picture of it.

---

## Tests

**524 → 567, in 53 → 56 suites. No existing test was modified.** Run cold from a deleted
`DerivedData` with `CODE_SIGNING_ALLOWED=NO`, zero warnings.

Three assertions were checked by breaking the implementation rather than by trusting them.

| Mutation | Result |
| --- | --- |
| Remove the drain's idempotency guard | 4 tests fail, including the double-drain one |
| Reap staged files without waiting for `existsOnServer` | The confirmation test fails on both the record and the files |
| Replace the copy with a chunked read into a `Data` | The memory test reports a **316MB** peak against its 40MB ceiling |

**The third one is the one worth reading.** It began as a before-and-after `phys_footprint` reading
and **passed a mutation it should have caught**: replacing `FileManager.copyItem` with
`Data(contentsOf:)` did not move the number, because Foundation maps a file that size and mapped
clean pages are not charged. Bracketing also cannot see a spike already released by the time the
second reading is taken, which is exactly the shape of "read it all in, write it all out". It samples
a peak on a second thread now, and the mmap limit is written into the test rather than left for
someone to rediscover.

The instrument checks itself first, against a 64MB allocation of known size, so a run where
`phys_footprint` reports nothing fails loudly instead of passing the real assertion vacuously.

One further assertion is worth naming: the shipped `RascalShare-Info.plist` is a **resource of the
test bundle**, and `ShareInboxTests` reads it. The activation rule is the real gate on what this
extension will ever be offered, and the substance of it is the keys that are *absent* — web URL, web
page, text, file — because an absent key defaults to zero. A test that only checked the two present
keys would pass on a plist that also accepted everything else.

---

## What is not built, deliberately

**Cross-share deduplication.** Sharing the same photo twice makes two entries. An `NSItemProvider`
carries no asset identifier, so the only reliable key is the content — and hashing a video inside
the process with the memory ceiling is precisely what this architecture exists to avoid. It is also
not obviously the wrong behaviour: the same photograph attached to two different days is a
legitimate pair of entries, and a heuristic that silently dropped the second would destroy a real
one. Within a single share, duplication is impossible.

**A date picker in the sheet.** See above.

**Child selection, prompt or assignment linkage, tags, people, sealing.** Each is a question a
twelve-second screen cannot afford, and a share is a freeform entry — which is first-class here.

---

## The honest limits

- **The extension has never been launched by the system.** Every frame above is the real view in the
  app's window, which is taller than a share sheet and has no presentation chrome.
- **The memory ceiling has never been met.** A simulator does not enforce one. The architecture
  exists to respect a limit that has not been measured, and §3 of the device checklist asks for the
  number.
- **Video conversion in the drain is untested by the suite.** It calls `VideoPipeline.process`
  unchanged — the same code the composer uses — but no synthetic video fixture is generated, so the
  photo path is what the tests exercise end to end. `VideoPipeline` had no tests before this phase
  and has none now.
- **iCloud Photo Library has never been exercised.** A photo that is not resident on the device has
  to download inside `loadFileRepresentation`, and that path does not exist on a simulator. It is
  the most likely cause of a slow or failing share on a real phone.
- **Conversion runs on the main actor**, matching the composer, which has done so since phase 2. A
  twenty-photo share will visibly hitch during the launch that drains it. `ingest` yields between
  records so the run loop can service a touch, which reduces it rather than removing it.
- **A share made before onboarding is held, not lost — and nothing says so.** The extension has no
  session and does not know which child a share belongs to; the app resolves that at drain time. The
  record simply waits. §8 of the checklist asks whether that reads as a lost photo.
