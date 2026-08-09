# RASCAL — Design System

The build-time reference. `rascal-design-prompt-v2.md` is for generating mockups; this is
the authority for writing SwiftUI. If a mockup and this file disagree, this file wins.

Last updated: **Aug 9, 2026** — Timeline v3. Every value here is derived from the reference
screenshots and from `docs/mobile-app-design-timeline/`, not invented.

**Register:** warm, friendly, polished. The neighborhood of Journey and Raven. Not Day One,
not Retro, and never the risograph/poster direction.

---

## Color

```swift
enum Palette {
    static let terracotta      = Color(hex: 0xC05A2B)  // primary
    static let terracottaSoft  = Color(hex: 0xFBEDE2)  // tinted fills
    static let terracottaDeep  = Color(hex: 0x9A431E)  // pressed

    static let periwinkle      = Color(hex: 0x5566D6)  // secondary
    static let periwinkleSoft  = Color(hex: 0xE9EBFB)

    static let periwinkleBorder = Color(hex: 0xDADDF7) // hairline on a periwinkle fill

    static let ink             = Color(hex: 0x23253C)  // headlines, body
    static let inkMuted        = Color(hex: 0x6E6A63)  // metadata, timestamps
    static let inkFaint        = Color(hex: 0xB4ADA3)  // weekday, closing line, eyebrow dates

    static let canvas          = Color(hex: 0xFDFAF4)  // app background
    static let surface         = Color(hex: 0xFFFDF9)  // cards
    static let border          = Color(hex: 0xEDE5DA)  // hairlines
    static let chipPlain       = Color(hex: 0xF4EEE5)  // neutral chip fill (a tag, not a kind)

    static let sage            = Color(hex: 0xE8F0E6)  // did-it entries
    static let sageBorder      = Color(hex: 0xD8E4D5)  // hairline on a sage card
    static let sageInk         = Color(hex: 0x4B7A4F)  // did-it check, did-it chip ink
    static let sageSoft        = Color(hex: 0xDCE8DA)  // chip fill on a sage card

    static let sealedBorder    = Color(hex: 0xF0DFD5)  // hairline on the sealed wash
    static let sealedInk       = Color(hex: 0xA79A92)  // "opens at 18" under the seal

    // The 2pt rule down the left of a quoted prompt, tinted to that prompt's kind.
    static let ruleTerracotta  = Color(hex: 0xEBD8C8)
    static let rulePeriwinkle  = Color(hex: 0xC6CCF2)
    static let ruleSage        = Color(hex: 0xB7CDB3)
}
```

**Never** pure black or pure white. Ink is navy-charcoal, canvas is cream.

**A tinted card gets a tinted hairline.** `border` is tuned for cream; on sage it reads as a
smudge and on the sealed wash as dirt. Same for `periwinkleBorder` on the voice hero.

**The ink ramp is three steps, not two.** `ink` for what is being read, `inkMuted` for what
frames it, `inkFaint` for what is merely present — a weekday, an eyebrow date, the line at the
bottom of the archive.

### Semantic assignment

| Meaning | Color |
|---|---|
| Mission, photo/video entries, primary action, FAB | terracotta |
| Question, voice entries, secondary action, waveforms | periwinkle |
| Did-it entries | sage |
| Written entries | plain surface |
| Sealed entries | soft gradient wash + ink |

Color carries meaning here. Don't use terracotta for a question card just because it's the
brand color.

### Gradients

Reserved for emotional beats only — onboarding, all-caught-up, throwback headers, sealed
entries. Diffuse and low contrast:

`#FDE8DC → #F7DDE8 → #FBF6EF`, roughly top-left to bottom-right.

---

## Type

| Role | Spec |
|---|---|
| Display | 34pt bold, rounded-friendly geometric. Occasionally one word in terracotta. |
| Screen title | 29pt bold, rounded — a screen's own name in a sticky header |
| Detail title | 26pt bold, rounded — the entry title on Entry Detail |
| Title | 22pt semibold |
| Day number | 19pt bold, rounded — the day on a timeline group header |
| Card title | 17pt semibold |
| Body | 16pt regular, line height 1.45 |
| Quote | 14pt regular, line height 1.4, **set italic at the use site** — a quoted prompt |
| Metadata | 13pt regular, inkMuted |
| Label / small caps | 12pt semibold, tracked +0.6, uppercase, inkMuted |

SF Pro Rounded for headlines gets you most of the reference warmth for free. SF Pro Text
for body. The mockups set headlines in Nunito; rounded is the system stand-in, and no font
file is bundled.

Date headers use the reference pattern: bold day number beside a lighter month, with the age
he was that day on the right — `**9** August 2026 · SUN · [4y 2m]`.

Dynamic Type is respected throughout. The sizes above are the values at the default
setting; nothing is a fixed point size that refuses to scale.

---

## Shape & elevation

- Card radius: **20**
- Chip / pill radius: **fully rounded** (capsule)
- Media inset radius: **14** — also the mosaic block and the voice band on a card
- Quote block radius: **16** — the filled prompt block on Entry Detail
- Hero radius: **18** — the media or voice block at the top of Entry Detail
- Border: 1px `border` on cards
- Shadow: barely there — `y: 2, blur: 8, opacity: 0.04`. Warmth comes from the cream, not
  from depth.
- Card padding: 16 internal, 16 horizontal screen margin, 12 between cards

---

## Components

### PromptCard
Today's mission or question. Tinted fill by kind (terracottaSoft / periwinkleSoft), a small
kind badge chip ("PHOTO", "VOICE", "ACTIVITY"), the prompt body at 20pt, and a capsule
primary button. Expiring-soon shows a quiet chip: "2 days left" — inkMuted, never red.

States: `pending` · `expiringSoon` · `done` (tinted, checkmark badge, body de-emphasized) ·
`dismissed` (removed).

The `slot` values are `question`, `mission`, `weekly`, `monthly`, and `letter`. A slot or
kind the client doesn't recognise renders as a neutral surface card with its body text
intact — an unknown value from a future server release is never a crash and never a blank
card.

### EntryCard
The timeline workhorse. **v3 rebuilt it around the prompt**: the card reads top to bottom in
the order the moment happened — what was asked, then what came back.

Six zones, stacked, and **every one drops out when it is empty.** No reserved space, no
placeholder frame, no gap where a picture would go. Half the mission library produces no
artifact, so a card with nothing but a prompt and a title is the common case, and it has to
look deliberate. Height follows content, and that variation is the only rhythm the list needs.

| Zone | Spec | Gap below |
|---|---|---|
| Media mosaic | see below | 13 |
| Voice band | periwinkleSoft fill, radius 14, 34pt periwinkle play circle, waveform, mono duration | 13 |
| Quoted prompt | 2pt rule + 11pt indent, quote role italic, inkMuted, 2 lines | 9 |
| Title | card title, ink, 2 lines — with a sage check on did-it, a terracotta envelope on sealed | 5 |
| Body | body role, inkMuted, 2 lines (**3 for written**) | — |
| Chips | kind chip tinted, then up to two tags on `chipPlain` | 12 above |

**The mosaic has four shapes**, by tile count: one (242 tall, 196 for video), two (164),
three (62% wide plus two stacked, 216), and a 2×2 (108 per row). Gutters are 4pt of card
showing through — no hairline per tile. Past four, the count is **printed on the fourth tile**
over a 30% terracotta wash, never given a tile of its own: nine photos and four photos must
produce the same card height.

**The prompt is the point of v3.** It comes from `entries.prompt_body` when the detail fetch
has cached one, else from the assignment the entry completed. Freeform entries have no prompt
and the zone is simply absent.

**No age chip on the card.** Age moved to the day header, stated once per group.

Card fill and hairline by state: surface/`border`, sage/`sageBorder` for did-it, the gradient
wash/`sealedBorder` for a sealed letter.

`thumb_key` is null for now — thumbnail generation is deferred out of P0 — so every tile must
lay out correctly with no image at all, as its kind's tinted placeholder.

### TimelineHeader
Sticky, translucent: cream at 94% over a blur, so the archive is softened behind it rather
than hidden. Screen title left, count right, filter row beneath.

The count **never claims to know the size of the archive**. Until the last page has landed it
reads "412 so far"; only once paging is exhausted does it read "412 entries".

### DayHeader
Bold day number, lighter month and year, faint uppercase weekday, and the age he was that day
as a periwinkle capsule pushed to the trailing edge. A year rule sits above the first group of
each calendar year.

### Chip
Capsule, 13pt. Filter chips: active = solid terracotta with cream text; inactive = surface
with border. Metadata chips: soft tint, no border.

`emphasis` makes a chip semibold and a touch wider — the tinted chips along the bottom of an
`EntryCard` and the tags on Entry Detail. It is off by default so the timeline's weight does
not restyle Today and Settings on its way past.

The timeline's filter row is All · Photos · Video · Voice · Written · Did it · **Sealed**. The
last one is `unlock_at_age`, not an `entry_type`, and the server has no parameter for it — see
`docs/blocked.md`.

### FloatingTabBar
Capsule, floating above the safe area with a soft shadow. Five slots: Today · Timeline ·
**+** · Moments · Settings. The center + is a filled terracotta circle, slightly raised.

### DatePill
Capsule showing the entry date with a chevron. Tapping opens the date picker. This is the
backdating affordance and it lives in the composer header where it's obvious.

### AudioRecorder
Periwinkle waveform on canvas, large terracotta record button centered, elapsed timer
beneath, cancel (×) and confirm (✓) circles flanking. Follows the reference layout closely.

### CompletionCheck
Circular terracotta checkmark that fills with a spring (`response: 0.35, damping: 0.7`) plus
a light haptic. The card then settles into its done state and moves to the Done Today
section.

No confetti. No stamp. No streak counter.

---

## Motion

| Interaction | Spec |
|---|---|
| Card tap | scale 0.98, 0.12s |
| Completion | spring, response 0.35, damping 0.7 |
| Sheet | standard iOS presentation |
| Card → done transition | 0.4s, with the card sliding down into Done Today |
| List insert | fade + slight rise |

Gentle and responsive. Nothing theatrical. Respect Reduce Motion: the completion check
still fills, it just doesn't spring.

---

## Layout rules

- Primary actions live in the bottom third — one-thumb reachable.
- Screen margin 16pt.
- Photos sit inset with padding and rounded corners; they rarely bleed to the screen edge.
- Section headers are small-caps labels in inkMuted, not big display type.

---

## Copy rules

- Never scold. "4 waiting" is a count, not an accusation. There is no wording anywhere that
  implies a missed day was a failure.
- No urgency states. Expiry is stated plainly and quietly; nothing turns red.
- Errors say what happened and what to do, in the interface's voice. They never apologise
  and they are never vague.
- An entry saved locally but not yet synced is never presented as an error or a loss.

---

## Anti-patterns

Rejected twice already — don't drift back:

- Risograph, halftone, misregistration, screen-print texture
- Condensed or rotated display type, headlines breaking the grid
- Full-bleed edge-to-edge photo cards as the primary timeline
- Passport stamps, receipt-spike stacks, rotated cards
- High-saturation electric accents
- Streak counters, guilt copy, red urgency states
