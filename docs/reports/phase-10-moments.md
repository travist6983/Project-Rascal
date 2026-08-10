# Phase 10 — Moments v2

Re-skin of the Moments tab against `docs/mobile-app-design-moments/project/RASCAL Moments v1.dc.html`.
Moments shipped inside PR #19 as part of the Archive phase and had never had a design pass of its
own.

---

## The premise the phase was built on

**The archive is six days old. There is no "1 year ago."**

Every date this month returns `fallback: "random"`, and will keep doing so for a year — and on most
dates for years after that. So the redirect is not the edge case. It is the screen, and it was
built and verified first, before the populated carousel that will be rare for a long time.

What follows from that, and it is the whole design of the phase: **the redirect wears the hit's
clothes.** Same carousel, same section header, same `EntryCard`s. One eyebrow changes and one
italic line appears. A miss with its own visual language would be a language this app spoke on
most mornings, and it would read as a fault on every one of them.

---

## The three states, photographed

All six screenshots are real renders of the real `MomentsScreen`, through the real `MomentsModel`,
`EntryCache` and JSON decoding, with only the HTTP seam stubbed.

| State | Default type | Dynamic Type XXL |
| --- | --- | --- |
| Populated — three years back | `default-populated.png` | `xxl-populated.png` |
| Redirect — the archive stands in | `default-fallback.png` | `xxl-fallback.png` |
| Empty — nothing at all | `default-empty.png` | `xxl-empty.png` |
| **A sealed letter leading the redirect** | `default-sealed.png` | `xxl-sealed.png` |

**No clipped or truncated text at XXL in any of the four.** The empty state's heading wraps to two
lines and its body to three, and the layout absorbs both. The throwback cards hold their 232×148
geometry and their captions wrap to the two lines they are allowed.

### The fourth one is the one to look at

`xxl-sealed.png` is the seal under the hardest case available: a sealed letter that **has a
photograph attached**, leading the random fallback. If the seal leaked anywhere on this screen it
would be visible in that frame — as a cover behind the throwback's scrim, a mosaic on the card, a
body line, or a tag. The frame shows the gradient wash with a **LETTER** badge and no cover, and a
card reading "A letter" / "Opens at 18." with no mosaic and no body.

---

## Accessibility

### Dynamic Type XXL — generated, and I looked at all four

`xcrun simctl ui <udid> content_size extra-extra-large`, the same method as the phase 8 report.
Four screenshots listed above, read individually rather than glanced at as a set.

### VoiceOver — **audited by reading the tree, not by running VoiceOver**

Stated plainly because the brief asks which is which: **no screen reader was run.** VoiceOver
cannot be driven from a CLI and Accessibility Inspector is a GUI. What follows is derived from the
accessibility modifiers in the source, and section 4 of `docs/device-verification-moments.md` is
where it gets confirmed on a device.

| Element | Exposed as | Label |
| --- | --- | --- |
| "Moments" | **heading** | "Moments" |
| Subtitle | text | "On this day · Sunday, August 9" |
| Throwback card | **button**, one combined element | "Letter. From the archive. A letter" — badge, eyebrow, line, as one sentence |
| — its wash or cover photo | *not an element* | decorative; a `Color`/unlabelled `Image` inside a combined parent |
| — its scrim | **explicitly hidden** | `.accessibilityHidden(true)` |
| — its kind badge | folded into the card's label | read first, as someone would say it aloud |
| Section title | **heading** | "1 year ago" |
| Section date | text | "Aug 9, 2025" |
| Age chip | text | **"three years two months old"** — `AgeText.spoken`, not the visible "3y 2m" |
| Redirect note | text | "Nothing from August 11 yet. Here's one from the archive instead." |
| Entry card | **button**, one combined element | prompt, title, body, kind, duration, picture count, age, date — unchanged from PR #25 |
| — mosaic tiles, waveform | folded into the card | never announced individually |
| — a sealed card | same | says "Sealed until age 18" and never its contents |
| Closing line | text | "Six years of 9 August. Nothing else today." |
| Empty-state glyph | **explicitly hidden** | `.accessibilityHidden(true)` |
| "Capture something" | **button** | "Capture something" |
| Notice banner icon | **explicitly hidden** | `.accessibilityHidden(true)` |

Every interactive element is labelled. Every decorative layer is either explicitly hidden or is
structurally not an element. One thing was added during the audit rather than found correct: the
screen's own H1 had no `.isHeader` trait while the section titles did, so the rotor skipped
straight to "1 year ago".

---

## Verification honesty

**Ran, cold, against a deleted derived-data path:**

- The full iOS suite. **426 tests in 46 suites, zero warnings** in `ios/Rascal/{Rascal,RascalTests}`.
  Baseline before this phase, measured the same way on `b348ff7`: **416 tests in 45 suites**.
- All four screen states, rendered on a booted simulator at two type sizes.

**Reasoned about, not run:**

- **VoiceOver.** Audited by reading the accessibility tree. Not spoken aloud by anything.
- **Real covers.** `thumb_key` is null on every row the server returns, so a cover only appears
  when this phone holds the thumbnail. In the simulator every cover falls back to flat
  terracotta — which is what the screenshots show, and which is the honest current appearance of a
  build with no thumbnail pipeline. **How the cream eyebrow reads over an actual photograph is
  unverified**, and it is the thing the three-stop scrim exists for.
- **The real archive.** Every assertion runs against constructed JSON in an in-memory store. The
  755-entry dev archive has not been through this screen.
- **CI.** GitHub Actions has been billing-blocked since ~Aug 10 00:08Z; every run since is a 3–4
  second rejection with zero steps. **This branch cannot be shown green by CI**, and neither could
  the two before it. Local cold runs are the only verification available.
