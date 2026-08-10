# Moments v2 — device verification

**What the suite proves and what it cannot.** Phase 10 asserts the model layer hard: both response
shapes, the grouping, the ordering by `occurred_at`, the redirect, the empty archive, and — the one
that matters most — that a sealed letter surfaced here stays sealed. All of it runs against
constructed JSON in an in-memory store.

**What no test in this repo touches is what the screen looks like against the real archive.** The
dev archive holds 755 entries with real dates; the fixtures hold three. Everything below is about
that gap, plus the two things a simulator structurally cannot answer: how the covers look when the
thumbnails are real photographs of an actual child, and how the screen reads out loud.

Run against a build pointed at a real API — `API_HOST` on the LAN. **Sign the build**; an unsigned
one cannot write to the keychain, every request after sign-in comes back `401`, and it looks like
an auth bug rather than a signing one.

Tick each line or write down what happened instead. A line that "seemed fine" is not ticked.

---

## 0. The one that matters most, and the suite can only half-answer it

**A sealed letter must not open here.** The archive has letters in it addressed to a child who is
four; Moments surfaces random entries, so a letter *will* appear on this screen, on a day nobody
chose, without anyone navigating to it. The test suite proves the card model carries no body, no
tiles and no tags. It cannot prove what is on the glass.

- [ ] Find a sealed letter in the archive (Timeline → the **Sealed** filter). Note its title.
- [ ] Open Moments repeatedly — or pass its date — until that letter appears in the redirect.
- [ ] **Read the card.** It shows the title and "Opens at 18." and **nothing else**: no first line
      of the letter, no blurred text you could screenshot and sharpen, no tags.
- [ ] Check the **throwback card at the top**. If the letter leads its section, the card must show
      the gradient wash and a **Letter** badge — never a photograph behind a scrim. A cover here
      would be a picture the seal exists to hold back.
- [ ] Turn the phone sideways, screenshot it, zoom in. Nothing legible appears under any blur,
      because there is nothing under it — the body is never fetched.
- [ ] Tap it. Entry Detail opens and is also sealed, with its **Open it** button.

## 1. The state you will actually be in

**The archive is six days old.** "1 year ago" is empty on nearly every date, so the redirect is not
an edge case to spot-check — it is the screen. Judge it as the primary state.

- [ ] Open Moments on an ordinary day. It shows the redirect, not a void and not an error.
- [ ] **Read the copy as a parent, not as its author.** "Nothing from 11 August yet. Here's one
      from the archive instead." Does it read as an invitation or as a report card? Nothing on this
      screen may say or imply that anyone failed to do something.
- [ ] The section heading says **From the archive**, and there is **no date and no age chip** beside
      it — five random memories span five days and five ages, and one of each would be wrong four
      times.
- [ ] The throwback cards all read **From the archive**. The redirect gets no visual language of
      its own beyond the eyebrow and that one italic line.
- [ ] Pull to refresh. A different five arrive — the server picks at random each time.
- [ ] Confirm it never says "no memories", "nothing yet", or anything with a zero in it.

## 2. A day that does have something

- [ ] Find a date the archive genuinely has prior-year entries for. Backdate an entry a year if
      nothing qualifies yet.
- [ ] Open Moments on that date. Sections are ordered **nearest year first**.
- [ ] Each section header carries the year phrase, the day it happened, and the age chip — and the
      age is the server's stored `child_age_months`, not one computed here.
- [ ] The closing line under the archive is true. Count the sections and read it back.
- [ ] Scroll the carousel. It scrolls horizontally and does not fight the vertical scroll.
- [ ] Tap a throwback card. It opens the **first entry of that section**, and Back returns here
      with the scroll position kept.

## 3. Covers, which the simulator cannot show you

`thumb_key` is null on every row the server has ever returned — that pipeline was cut from P0 — so
a cover only appears when **this phone** holds the thumbnail, which means media captured on it.
In the simulator every cover falls back to flat terracotta. On a real phone with real photographs
it will not.

- [ ] Open a section whose lead entry is a photo taken **on this device**. The throwback card shows
      the actual picture.
- [ ] **Read the eyebrow over it.** "3 years ago" in cream over a bright frame — a beach, snow, a
      white wall — must stay legible. The scrim is three stops and fades out by 72% of the height;
      if a photo defeats it, say which one.
- [ ] Confirm the text does **not** change colour when the image lands. It should be cream from the
      first frame, over terracotta, before the picture arrives.
- [ ] A section whose lead is a **video** shows the cover *and* a Video badge.
- [ ] A section with no picture at all shows the gradient wash with dark type and a kind badge —
      and reads as an invitation, not as an image that failed to load.

## 4. Dynamic Type and VoiceOver, on a real screen

Screenshots at XXL are attached to the pull request and were read; a real device is still the
honest check, because the simulator does not have the display this is read on.

- [ ] Settings → Accessibility → Display & Text Size → Larger Text, to **XXL**. Open Moments in all
      three states. No clipped or truncated text; headings wrap and the layout absorbs it.
- [ ] Push it to the largest accessibility size. Note what breaks — this is beyond what the design
      covers and the answer is allowed to be "it degrades", but not "it loses text".
- [ ] **Turn VoiceOver on.** Swipe through the screen top to bottom.
- [ ] Each throwback card is **one stop**, and reads its badge, its year phrase and its line as one
      sentence — not four separate elements.
- [ ] The gradient, the scrim and the media placeholders are **not** stops. Nothing announces
      "image".
- [ ] Each section heading is announced as a heading.
- [ ] The age chip reads as **"three years two months old"**, not "3y 2m".
- [ ] Each entry card is one stop and one sentence, and a sealed one says "Sealed until age 18"
      and never its contents.
- [ ] The empty state's button is reachable and says what it does.

## 5. The day is the server's, not the phone's

The screen prints a calendar day the server computed in the child's `family_timezone`. The client
formats it and must not shift it.

- [ ] Note the day Moments prints.
- [ ] Change the **device** timezone to something far east — Auckland, or Kiritimati at UTC+14 —
      and relaunch.
- [ ] The day under "Moments" is **unchanged**. If it moves forward a day, the formatter has fallen
      back to the device zone and that is a defect.
- [ ] Change to Honolulu and repeat. Still unchanged.
- [ ] Set the device zone back.

## 6. The empty archive

Hard to reach with 755 entries in the dev archive; worth doing once against a **fresh child** or a
fresh account, because it is the first thing a new parent sees on this tab.

- [ ] With an archive holding nothing, Moments shows the invitation: the wash circle, "The first
      one becomes a memory", and one button.
- [ ] There is **no carousel at all** — not an empty rail, not a rail with no height.
- [ ] The button opens the composer rather than explaining the feature.
- [ ] Save something, come back. The screen has changed state without a relaunch.

## 7. Offline, and failure

- [ ] Airplane mode on, open Moments cold. A quiet notice appears; the screen is not blank and
      nothing reads as an error the parent caused.
- [ ] With the radio back on, pull to refresh. The notice clears.
- [ ] Open Moments, then delete one of the memories it is showing from Entry Detail. Come back:
      the card is gone and its section either rebuilt or disappeared — never a card for a row that
      is not there.
