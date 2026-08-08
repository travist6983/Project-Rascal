# RASCAL — Design System

The build-time reference. `rascal-design-prompt-v2.md` is for generating mockups; this is
the authority for writing SwiftUI. If a mockup and this file disagree, this file wins.

Last updated: **Aug 8, 2026** — committed ahead of the iOS build. Every value here is
derived from the reference screenshots, not invented.

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

    static let ink             = Color(hex: 0x23253C)  // headlines, body
    static let inkMuted        = Color(hex: 0x6E6A63)  // metadata, timestamps

    static let canvas          = Color(hex: 0xFDFAF4)  // app background
    static let surface         = Color(hex: 0xFFFDF9)  // cards
    static let border          = Color(hex: 0xEDE5DA)  // hairlines

    static let sage            = Color(hex: 0xE8F0E6)  // did-it entries
}
```

**Never** pure black or pure white. Ink is navy-charcoal, canvas is cream.

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
| Title | 22pt semibold |
| Card title | 17pt semibold |
| Body | 16pt regular, line height 1.45 |
| Metadata | 13pt regular, inkMuted |
| Label / small caps | 12pt semibold, tracked +0.6, uppercase, inkMuted |

SF Pro Rounded for headlines gets you most of the reference warmth for free. SF Pro Text
for body.

Date headers use the reference pattern: bold day number beside a lighter month —
`**25** August 2026 · Mon`.

Dynamic Type is respected throughout. The sizes above are the values at the default
setting; nothing is a fixed point size that refuses to scale.

---

## Shape & elevation

- Card radius: **20**
- Chip / pill radius: **fully rounded** (capsule)
- Media inset radius: **14**
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
The timeline workhorse. Title, two-line body preview, 56pt square thumbnail on the trailing
edge, metadata row of chips underneath (age at the time, entry type, tags).

Multi-photo entries show a thumbnail row with a `+8` overflow tile. Voice entries show a
periwinkle waveform chip with duration plus the first line of transcript. **Text-only
entries render without an empty thumbnail slot** — they must look complete, not deficient.

`thumb_key` is null for now — thumbnail generation is deferred out of P0 — so every card
must lay out correctly with no thumbnail at all.

### Chip
Capsule, 13pt. Filter chips: active = solid terracotta with cream text; inactive = surface
with border. Metadata chips: soft tint, no border.

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
