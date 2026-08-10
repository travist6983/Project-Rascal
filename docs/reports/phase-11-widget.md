# Phase 11 — the widget

Today's mission and question on the Home Screen and the Lock Screen, opening straight into the
composer. Five families, five states, and the project's first extension target.

---

## What is actually new here

Three things that did not exist in this repo before this branch:

1. **An extension target.** `RascalWidget`, its own synchronized folder group, embedded into the
   app, with an App Group entitlement on both targets. Committed separately (`b7af9be`) so it can
   be reverted without taking the feature with it.
2. **Deep-link handling.** There was no URL scheme, no `onOpenURL`, nothing. `childarchive://` is
   registered in both plists and parsed by one type.
3. **A dark rendering.** The first in the product, and scoped to the widget alone.

---

## The architecture, in one paragraph

The app writes a versioned `WidgetSnapshot` — a few hundred bytes — into the shared App Group
container whenever the Today board changes, then asks WidgetKit to reload. The extension reads that
file and renders it. **It makes no network requests, holds no credential, and has nothing to
refresh.** A token refresh running inside an extension concurrently with the app can invalidate the
app's own session, and that failure is rare, intermittent, and very hard to attribute; the cheapest
way not to debug it is not to make it possible.

The cost is staleness, and most of the design is about paying it honestly.

---

## The screenshots

Every image is a real render of the real widget view types, at the real widget dimensions, driven
by launch arguments so no tap was needed. **The harness was deleted before this branch was pushed**
— `git show --stat` on the feature commit will not find it, and neither will the project file.

| Page | Light | Dark |
| --- | --- | --- |
| `systemSmall`, all five states | `small-light-default.png` · `small-light-xxl.png` | `small-dark-default.png` · `small-dark-xxl.png` |
| `systemMedium`, states 1–3 | `medium-a-light-default.png` · `medium-a-light-xxl.png` | `medium-a-dark-default.png` · `medium-a-dark-xxl.png` |
| `systemMedium`, states 4–5 | `medium-b-light-default.png` · `medium-b-light-xxl.png` | `medium-b-dark-default.png` · `medium-b-dark-xxl.png` |
| All three accessory families | `lockscreen-light-default.png` · `lockscreen-light-xxl.png` | `lockscreen-dark-default.png` · `lockscreen-dark-xxl.png` |

The prompts in every shot are the **two longest active prompts** in `api/seeds/prompts.yaml` — a
100-character question and a 94-character activity — rather than a short example. On
`systemSmall` the long ones are the normal case; a short one proves nothing.

### What the screenshots changed

They found three defects that no test caught, and one of them changed a design.

- **The layout overflowed the widget at XXL.** Two labels, two prompts and a name need about 182pt
  of the 158pt a `systemMedium` has, and the surplus simply spilled out. Shortening sentences does
  not fix that; the *composition* has to give things up. Every family is now a `ViewThatFits` over
  whole layouts that drop the name, then prompt length, then the second prompt's words, in that
  order.
- **`lineLimit(1)` made a candidate lie about fitting.** "Nothing else waiting." reported a
  one-line height at any type size — by truncating itself to "Nothing else waiti…" — so the
  fallback that drops it was never reached. A wrapped line reports an honest height.
- **`accessoryInline` is now a status, not a prompt.** It began as the prompt shortened to 44
  characters. At XXL iOS truncated that to "What did y…" — the inline slot is a single
  system-laid-out run beside the clock, so nothing can measure it and no fallback can fire. A
  half-asked question on a Lock Screen is unusable *and* puts a fragment of the archive in front of
  whoever is holding the phone. It now says "Mission waiting". **The test changed with the design,
  and this is the one place in the branch where that happened** — the assertion did not fail and
  get weakened; the screenshot showed the design was wrong, and both moved together.

---

## Design under three constraints the system has never faced

### Dark mode, which the widget cannot decline

There is no `preferredColorScheme` for a widget. "Light mode only" is settled for the app and stays
settled; it simply cannot be honoured here.

`WidgetPalette` keeps both rules the design system actually cares about. **Never pure black, never
pure white**: the dark ground is a warm charcoal drawn *down* from the cream canvas — it keeps the
brown cast, because a neutral grey is what makes a warm product look cold at night — and the ink is
a warm off-white. **Colour carries meaning**: terracotta is still missions and periwinkle is still
questions, lifted in luminance rather than swapped, because `#C05A2B` on a dark ground fails
contrast badly. Measured against the dark surface they land around 5:1 and 6:1.

Inverting to black and white was the obvious move and it reads as a different product.

### The Lock Screen has no colour at all

Accessory families render through a monochrome mask, so terracotta-means-mission and
periwinkle-means-question convey nothing there — and in this product those are not decoration.

**Solved with the SF Symbol each prompt kind already carries on its `PromptCard`** — a walking
figure for an activity, a camera for a photo, a speech bubble for a question — plus weight and size
hierarchy in place of hue. The Lock Screen therefore inherits the app's existing vocabulary instead
of inventing a second one, and `accessoryCircular`, which has room for exactly one glyph, can still
say which *kind* of thing is waiting. The mapping is asserted against `PromptKind.symbol` so the
two cannot drift.

### A 100-character prompt in a 158pt box

`PromptText.wordSafe` shortens on a whole word; `ViewThatFits` picks the longest candidate that
actually fits. That combination is correct at every Dynamic Type size rather than at the one it was
designed against, and it is why no prompt in any screenshot is cut mid-word.

---

## Accessibility

**Generated, not assumed:** every screenshot above, at Dynamic Type XXL (`.accessibility2`), in
both appearances. I read each of the sixteen individually rather than glancing at the set. No
clipped text and no broken word survives in any of them.

**Generated, not assumed:** the VoiceOver strings. `WidgetNarration` lives in the app target
specifically so the tests can assert on it, and they assert the shape that matters — the widget
reads as *one sentence*, not as a pile of labels:

> "Today for Sam. Mission: Photograph his hands. Question: What made him laugh?"

A finished prompt reads "Mission, done." and **does not read the prompt back** — the parent already
answered it. Both finished collapses to "Both done." rather than two clauses, because that is a
single quiet fact and not a list. The stale reading names no day and blames nobody; it is asserted
not to contain "yesterday" or "missed".

**Assumed, not verified:** how any of it actually sounds. Nothing in this environment speaks. The
accessibility tree was audited by reading it; section 9 of the device checklist is how it gets
heard.

---

## What could not be verified, and what that means

This is the largest such section any phase in this repo has had, and the reason is structural
rather than an excuse: **a widget cannot be added to a simulator's Home Screen without tapping, and
nothing here drives taps.** Everything below was reasoned about and is not observed.

| Thing | Status |
| --- | --- |
| The views render correctly in all five states, both appearances, two type sizes | **Observed** — sixteen screenshots, read individually |
| The extension compiles, links, embeds, and signs with the App Group | **Observed** — `.appex` present in `PlugIns/`, entitlement present in both `.xcent` files |
| The snapshot round-trips, classifies staleness, and excludes entry content | **Observed** — 61 new tests, cold run |
| **WidgetKit ever rendering any of this** | **Not observed.** No widget has been instantiated by the system. The views were driven directly by a harness |
| **Refresh budget** | **Not observed, and not observable here.** The simulator does not enforce one. Whether `reloadAllTimelines()` keeps up over a real day is section 3 of the checklist |
| **File protection on a locked device** | **Not observed.** Simulator file protection is a no-op, so the correct and the incorrect protection class look identical. This is the failure that appears only after a reboot |
| **The real monochrome accessory render** | **Not observed.** Approximated as light-on-dark. Real vibrancy, real wallpaper and a user's tint are all absent |
| **App Group provisioning on a device** | **Not observed.** The simulator signs ad hoc and it simply worked. A device needs the group registered on the developer portal; if it is not, the widget shows the neutral state forever with no error anywhere |
| **The midnight timeline entry firing** | **Not observed.** The date arithmetic is asserted, including across DST; whether the system honours the wake-up is a different question |

`docs/device-verification-widget.md` is ordered by how much of the above each section closes.

---

## Numbers

| | Before | After |
| --- | --- | --- |
| iOS tests | 429 | **490** |
| Suites | 46 | **50** |
| Warnings in our sources | 0 | **0** |

Both measured from a deleted `DerivedData`. That is not ceremony: the first warm run of this branch
reported zero warnings and the first cold run reported five, including a real actor-isolation
warning in `WidgetRoute.swift` that a warm build had never recompiled.

No existing test was modified.
