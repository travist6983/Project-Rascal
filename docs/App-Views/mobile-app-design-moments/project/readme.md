> **⚠️ SUPERSEDED IN ONE RESPECT — read before generating anything. Added Aug 18, 2026.**
> This bundle was exported Aug 16, 2026 and is accurate about that day. **Two things changed on
> Aug 17–18 and both bear directly on the `Wordmark` rules below:**
>
> 1. **The product is called `Vellum`, not `RASCAL`.** Settled by the owner Aug 17, 2026
>    (`docs/decisions.md:115`) and renamed through both lanes as phases 71 and 73. `RASCAL` remains
>    the repository, package and path name and is correct wherever you see it as an identifier —
>    but it is no longer the product's name in any copy a person reads.
> 2. **A mark now exists, and the name is never set in capitals.** The statements below that
>    *"there is no logo file in any source"* and *"no logo — wordmark only, by design"* were true
>    when written and are false now: phase 70 drew the mark (`docs/app-icon/vellum-mark.svg`,
>    `vellum-icon-fan.svg`) and phase 77 drew the wordmark as geometry, ported into the app as
>    `WordmarkView`. **Phase 78 makes it a rule with no exceptions: the name is never set in
>    capitals** — `VELLUM` in tracked-out capitals is exactly what phase 77 removed from the
>    welcome screen. Where a mark goes, use the drawn wordmark; where the name appears in a
>    sentence, write it sentence case.
>
> **Do not "fix" the body below to match.** It is a dated export and its value is that it records
> what was true on Aug 16. `docs/design-system.md` is the live authority for the app.

> **⚠️ SUPERSEDED AGAIN, Aug 27, 2026 — appended, not merged into the Aug 18 note above.**
> **The product is called `Pocket Chronicle`.** An attorney found a trademark conflict and `Vellum`
> was retired; phases 128 and 130 renamed both lanes. **The banner above is left exactly as it was
> written on Aug 18, 2026 and is a true record of that day** — it says `Vellum` because that was
> the name then, and phases 71 and 73 really were the Dogear → Vellum rename. Editing a dated note
> to name a name that did not exist yet is the failure `docs/decisions.md:120` records from the
> last rename, and this file carried it for one commit before it was caught.
> **`RASCAL` still remains the repository, package and path name.**
# RASCAL Design System

RASCAL is a daily-memory app for parents. Every morning it hands you **one** small
thing to do about your kid — record his voice, photograph the mess, write down the
word he says wrong — and files what you make into a timeline stamped with his exact
age. The whole product is built against one anxiety: *he is changing and I am not
writing any of it down.*

Two surfaces exist today:

| Surface | What it is | Source |
| --- | --- | --- |
| Marketing site | Single long-scroll page, warm paper, scroll-linked reveals | `github.com/travist6983/Rascal-Marketing` (branch `main`) |
| iOS app (v2) | Today prompts, timeline, capture flows | Two screenshots supplied by the founder + the onboarding flow built in this project |

Sources this system was built from — recorded so a future reader can re-check them:

- **GitHub:** `travist6983/Rascal-Marketing`, branch `main`. Tokens, type scale,
  easings, and both webfonts were lifted from its `styles.css` and `index.html`.
- **Fonts:** `fonts/nunito-var-latin.woff2`, `fonts/source-sans-3-var-latin.woff2` —
  copied from that repo, self-hosted, latin subset, variable.
- **App screens:** `uploads/` (two PNGs of the shipped v2 app: Today list and a
  capture screen). Screenshots are lossier than code — see CAVEATS.
- **Onboarding flow:** `RASCAL Onboarding.dc.html` in this project — a ten-screen
  clickable flow designed against these foundations. It is the most complete
  living example of the app's voice and layout rules.

There is **no logo file in any source**. RASCAL has a wordmark, not a mark: the
letters `RASCAL` set in Nunito 800 with `0.14em` tracking, in ink. The
`Wordmark` component is that, and nothing was drawn or invented to fill the gap.

---

## CONTENT FUNDAMENTALS

The copy is the product. If you get the voice wrong, no amount of correct color
saves the screen.

**It talks like a friend who has already lost the thing you're about to lose.**
Warm, plain, a little blunt. Never chirpy, never a coach, never a brand.

- **Second person, no "we" pushing you around.** "Let's save today before it's
  gone." — the one place *we* appears is as a shared act, not a company.
- **Short declaratives. Periods, not exclamation marks.** "One down." /
  "Nothing to upload. It still counts." / "Starts today."
- **Sentence case everywhere.** Headlines are sentences with full stops:
  "One gentle nudge in the morning." Title Case is never used.
- **Uppercase is reserved for two things:** the wordmark, and small structural
  labels — eyebrows (`TONIGHT`, `TODAY`, `YESTERDAY`) and badges (`PHOTO`,
  `VOICE`, `QUESTION`, `DID IT`). Both get `0.06–0.08em` tracking.
- **The kid's name is used constantly**, in the possessive: "When was Milo born?",
  "Milo's timeline", "Save this to Milo's archive." Copy that could say "your
  child" says the name instead.
- **Prompts are instructions with a physical detail.** Not "capture a memory" but
  "Photograph the mess he made. Don't clean it up first." The second sentence
  removes the excuse. Every prompt has one.
- **It removes pressure out loud.** "Miss a day and nothing happens." /
  "Nothing is counting." / "No account yet. Nothing to set up." There are no
  streaks, no counts, no gamification language — and the copy says so explicitly,
  because that restraint *is* the pitch.
- **Payoff copy is concrete and time-shifted.** Not "build your archive" but
  "At two hundred of these, you can scroll back and hear him at four."
- **Permission and privacy copy states the mechanism, then the limit.**
  "The recording stays on your phone. Nothing is uploaded, transcribed, or
  listened to."
- **Numbers are spelled out in prose** ("two hundred of these", "ten minutes"),
  and numeric only in metadata (`0:34`, `AUG 8, 2026`, `4y 2m`).
- **No emoji. Ever.** Not in the app, not in the marketing site, not in push
  notifications.

Words the system does not use: *journal, capture your memories, unlock, streak,
premium, magic, effortless, seamless, join thousands.*

---

## VISUAL FOUNDATIONS

### The one-sentence version
Warm paper with visible grain, two typefaces doing two strictly separate jobs,
terracotta as the only action color, and motion that arrives and then stops.

### Color
One palette, one theme. Not light/dark aware — `color-scheme: light` is declared
and there is no dark variant, because the paper metaphor doesn't survive inversion.

- **Never pure black, never pure white.** Canvas is `#FDFAF4`, cards are
  `#FFFDF9`, ink is `#23253C` (a navy-leaning near-black).
- **Terracotta `#C05A2B` is the only action color** — primary buttons, the
  active tab, the FAB, the recording state, the live timeline rail, link text.
  If something is tappable and important, it is terracotta. Nothing decorative
  is terracotta.
- **Periwinkle `#5566D6` is the second voice**, used for *written* things and for
  age metadata — the age chip, `QUESTION`/`WROTE IT` badges, the write-it CTA.
  It is never used for the primary action on a screen where terracotta is present.
- **Three section tints wash whole blocks:** peach `#FBEDE2`, lavender
  `#E9EBFB`, sage `#E8F0E6`. The app uses a deeper peach `#F8E7DC` behind
  prompt cards, with `#F3D9C7` badge fills inside it. **Nothing outside this set.**
  Max two tints visible at once.
- **Muted `#6E6A63`** carries every secondary sentence. Disabled fills are
  `#D9CFC2` — a warm gray, never a desaturated blue-gray.
- Semantic red/green/amber do not exist. There are no error states in the source
  material; if you need one, ask before inventing a color.

### Type
Two families, no exceptions.

- **Nunito, 700 and 800 only** — every heading, prompt, button label, badge, and
  the wordmark. Its round terminals are the entire warmth of the brand. Display
  sizes carry `-0.02em` tracking; prompts `-0.015em`.
- **Source Sans 3, 400 and 600** — every sentence of body copy, secondary line,
  caption, and iOS-chrome text. Line-height `1.5` body, `1.55` lede.
- **System mono, small only** — dates (`AUG 8, 2026`), timers (`0:34`), and spec
  keys. Always with `font-variant-numeric: tabular-nums`. Mono is metadata; it is
  never used for content a human wrote.
- Marketing type is fluid (`clamp()`); app type is fixed px against a 393pt
  screen. Both scales are tokenized separately — don't cross them.
- `text-wrap: pretty` on every multi-line heading and paragraph.

### Backgrounds
- **Paper grain is identity, not decoration.** An inline SVG `feTurbulence` at
  `0.055` opacity tiles at 160px over the canvas on *every* surface, web and app.
  It ships as `--rascal-grain`. A RASCAL screen without grain looks wrong.
- No photographic backgrounds, no gradients as decoration. The only gradients in
  the system are **protection gradients**: canvas-to-transparent fades at the top
  and bottom of the birthdate wheel so the numbers dissolve rather than clip.
- Full-bleed tint blocks divide the marketing page; cards never sit on a tint of
  their own color.

### Cards
- Radius `20px` on web and timeline cards, `24px` on app prompt cards (one step
  softer because they hold the emotional content). Sheets are `28px` top corners
  only. Anything tappable is `999px`.
- Surface `#FFFDF9` + **1px hairline `#EDE5DA`** + the resting shadow. The
  hairline does the work; the shadow is nearly invisible on purpose.
- **Tinted prompt cards carry no border at all** — the tint is the edge.
- Selected state thickens the border to `1.5px` terracotta and swaps the fill to
  peach. Never a check mark, never a colored left border only.

### Shadows
Two, plus three fixed-element specials. That's the whole system.
- `--rascal-shadow: 0 2px 8px rgba(0,0,0,.04)` — resting.
- `--rascal-shadow-lift: 0 12px 32px rgba(0,0,0,.10), 0 2px 8px rgba(0,0,0,.05)`
  — the "this one thing matters" state, used when a card is what a sheet is
  asking about.
- Tab bar `0 4px 20px rgba(0,0,0,.10)`, sheet `0 -10px 40px rgba(0,0,0,.10)`,
  FAB `0 4px 14px rgba(192,90,43,.34)` (tinted, not neutral).
- No inner shadows anywhere. No shadow on a tinted card.

### Motion
- **Two easings.** `cubic-bezier(0.16,1,0.3,1)` for anything entering — it
  decelerates hard and stops dead. `cubic-bezier(0.65,0,0.35,1)` for
  scroll-linked scrubs. **Never `linear`, never a bounce, never an overshoot.**
- Durations: press `150ms`, hover `180ms`, enter `320ms`, settle `620ms`,
  reveal `900ms`.
- Only `transform` and `opacity` animate. Nothing animates a layout property.
- Named keyframes ship in `tokens/motion.css`: `rascal-settle` (the timeline
  entry dropping into place — the single most important animation in the product),
  `rascal-sheet-up`, `rascal-pulse` (recording), `rascal-wave` (waveform),
  `rascal-caret-blink`.
- `prefers-reduced-motion` is honored globally in `tokens/base.css`.

### Hover & press
- **Hover** (web only): terracotta text darkens to ink; buttons lift 1px with no
  color change; cards raise their shadow to `--rascal-shadow-lift`. Opacity is
  never used for hover.
- **Press** (both): `transform: scale(0.98)` over `150ms`. No color change, no
  ripple. Touch targets are never below 44px.
- **Focus:** 2px terracotta outline, `2px` offset, `:focus-visible` only.
- **Disabled:** fill `#D9CFC2`, label stays canvas-colored, no opacity change.

### Transparency & blur
Used in exactly two places: the iOS-native permission alert (`rgba(252,250,246,.97)`
over a scrim) and the scrim itself, `rgba(35,37,60,.40)`. Frosted-glass panels
are not part of this brand.

### Layout
- Web wrap `1180px`, page pad `24px`.
- App gutters `22px` (content) / `30px` (hero-weight screens), safe top `88px`,
  safe bottom `34px`, `110px` of bottom padding on any scroller that sits under
  the tab bar.
- Two fixed elements in the app: the floating tab bar (inset `14px`, height
  `66px`, radius `34px`) and its `62px` center FAB overhanging `-14px`.
- Buttons are full-width in the app, hugging on web.
- Layout is flex/grid with `gap` throughout; no margin-based spacing between
  siblings.

### Imagery
User photos are the only imagery in the app, always inside a `14px`-radius well
on a tint. There is no stock photography and no illustration in any source.
Do not add either.

---

## ICONOGRAPHY

**RASCAL has no icon set, and that is a deliberate finding, not a gap in my
reading.** Neither the marketing repo nor the two app screens contain an icon
font, an SVG sprite, or icon files of any kind. What the sources use instead:

- **Text labels where other apps use icons.** The tab bar is five words —
  `TODAY`, `TIMELINE`, `MOMENTS`, `SETTINGS` — in Nunito 700 at 11px,
  uppercase, tracked `0.06em`. No glyphs above them.
- **Geometry built from divs** for the few symbols that exist: the FAB's plus is
  a `32px` Nunito `+`; the record button is a circle inside a ring; stop is a
  `6px`-radius square; the waveform is 17 rounded `6px` bars; timeline nodes are
  `13px` circles.
- **Two Unicode characters**, used as-is: `&#10227;` (⟳, the refresh affordance on
  the Today header) and the mono `·` separator in `Milo · 4y 2m`.
- **Emoji: never.**

If a future screen genuinely needs an icon set, the closest match to Nunito's
round terminals is **Lucide at `stroke-width: 2` with round caps**, CDN-linked —
but nothing in the current sources uses it, so it is *not* included here. Ask the
founder before introducing one; adding icons changes the product's texture more
than it looks like it will.

---

## Intentional additions

Everything below has a counterpart in the sources. Two entries are formalizations
rather than literal source components, flagged here so nobody mistakes them for
things the founder designed:

- **`Wordmark`** — the sources set the letters inline in each place they appear.
  Formalized into one component so the tracking can never drift.
- **`EyebrowLabel`** — the uppercase structural label appears on nearly every
  screen with identical styling; it was never a named component, but repeating it
  by hand is how tracking values rot.

---

## Index

| Path | What's there |
| --- | --- |
| `styles.css` | The one file consumers link. `@import`s only. |
| `tokens/` | `fonts`, `colors`, `typography`, `spacing`, `radius-shadow`, `motion`, `base` |
| `fonts/` | Nunito + Source Sans 3, variable, latin subset, self-hosted |
| `guidelines/` | Foundation specimen cards (colors, type, spacing, motion, brand) |
| `components/core/` | `Button` `Card` `Badge` `EyebrowLabel` `Wordmark` `Sheet` |
| `components/app/` | `PromptCard` `AgeChip` `TimelineEntry` `TabBar` `WaveformMeter` `RecordButton` `NotificationPreview` `ProgressBar` |
| `components/forms/` | `ChoiceRow` `NameField` |
| `ui_kits/app/` | Click-through recreation of the v2 app: Today, Timeline, Capture, Settings |
| `RASCAL Onboarding.dc.html` | The ten-screen onboarding flow, in-brand and interactive |
| `SKILL.md` | Agent Skills front-matter, for use in Claude Code |

## CAVEATS

- **The app kit is built from two screenshots, not code.** The founder has no app
  repo attached. Type sizes, gutters, and tints were measured off the PNGs and are
  faithful to about a pixel, but any screen I did not see — Timeline detail,
  Moments, Settings — is composed from the system's own rules rather than copied.
  Those three are marked as inferred inside `ui_kits/app/README.md`.
- **No marketing UI kit yet.** The tokens are grounded in the marketing repo, but
  I did not build web-page screens; the app is where the founder's attention is.
- **No logo.** Wordmark only, by design (see above).
- **No error, empty, or loading states** exist in any source. They are not
  invented here.
