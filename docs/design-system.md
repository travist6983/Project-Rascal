# RASCAL — Design System
The build-time reference. `rascal-design-prompt-v2.md` is for generating mockups; this is the authority for writing SwiftUI. If a mockup and this file disagree, this file wins.

Last updated: **Aug 12, 2026** — the **Backfill photo grid** section rewritten against the phase 18 follow-up: the selection affordance is now on every selectable tile rather than appearing after the first tap, and the tile geometry, request options and pinned-action inset are stated. The contact-sheet numbers themselves are unchanged and were re-confirmed rather than re-derived. Everything else was audited line by line against the shipped client through phase 21; every value here was read out of the code, not out of a mockup and not out of the previous version of this file.

**Register:** warm, friendly, polished. The neighborhood of Journey and Raven. Not Day One, not Retro, and never the risograph/poster direction.

* * *
## Color
```swift
extension Color {
    static let terracotta      = Color(hex: 0xC05A2B)  // primary
    static let terracottaSoft  = Color(hex: 0xFBEDE2)  // tinted fills
    static let terracottaDeep  = Color(hex: 0x9A431E)  // pressed

    static let periwinkle      = Color(hex: 0x5566D6)  // secondary
    static let periwinkleSoft  = Color(hex: 0xE9EBFB)
    static let periwinkleBorder = Color(hex: 0xDADDF7) // hairline on a periwinkle fill
    static let periwinkleDeep  = Color(hex: 0x3F4FB0)  // periwinkle text on a periwinkle ground

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

**They are statics on** `Color`**, in an extension — there is no** `Palette` **type.** `Color.terracotta`, or `.terracotta` wherever a `Color` is expected. `Color(hex:)` is opaque and the palette holds no translucent token: an alpha belongs at the use site, the way `KindBadge` washes its capsule with `tint.opacity(0.12)`.

**Never** pure black or pure white — including over a photograph, which is where the reflex is strongest. `Color.white`, `Color.black`, `Color.gray` and `.secondary` appear nowhere in the codebase. Over media, chrome is `surface` on a scrim of `ink` between 42% and 55%, and a full-screen viewer's ground is `ink` rather than `canvas`: cream behind a photograph reads as a page, and the viewer is not a page.

The one exception is `SignInWithAppleButton`, styled `.black` at 52pt tall and radius 14 on the welcome screen. A vendor asset whose appearance Apple's guidelines fix. Not tinted, not redrawn, and not a precedent.

**A tinted card gets the hairline the palette names for it.** `border` is tuned for cream and reads as a smudge on sage and as dirt on the sealed wash, so those take `sageBorder` and `sealedBorder`, and a periwinkle fill takes `periwinkleBorder`. **A terracotta fill keeps** `border` — that pairing is deliberate, and there is no terracotta hairline token to reach for. `PromptCard` and `ChildHeroCard` both resolve through `AssignmentPresentation.tintBorder` rather than deciding.

**The ink ramp is three steps, not two.** `ink` for what is being read, `inkMuted` for what frames it, `inkFaint` for what is merely present — a weekday, an eyebrow date, the line at the bottom of the archive.

**The third step is not a text colour.** On the cream canvas `inkMuted` measures **5.16:1** and `inkFaint` **2.13:1**. `inkFaint` is for text nobody has to read to use the screen. Anything a parent must read is `inkMuted` or darker, and so is any non-text control — the floor there is 3:1, and `inkFaint` is 2.19:1 on `surface`. Measure before matching a mockup: imports have specified `inkFaint` for section labels and `#C4BAAE` for chevrons, and both were refused on the number rather than on taste.
### Semantic assignment
| Meaning | Color |
| --- | --- |
| Mission, photo/video entries, primary action, FAB | terracotta |
| Question, voice **and written** entries, secondary action, waveforms | periwinkle |
| Did-it entries, and anything already done | sage |
| Written entries — card fill | plain surface |
| Sealed entries | soft gradient wash + ink |

Color carries meaning here. Don't use terracotta for a question card just because it's the brand color.

**Fill and tint are different jobs.** Only did-it and sealed cards are tinted; everything else sits on surface. The kind tint colours the quote rule, the kind chip and the prompt block on Entry Detail — terracotta for photo and video, periwinkle for voice **and writing**, sage for did-it.

**The tint is resolved once, on the wire model.** `AssignmentPresentation` exposes `tint`, `softTint` and `tintBorder` on `AssignmentResponse`, and every card reads them rather than deciding: periwinkle when the slot is a question or the kind is `question` or `audio`, terracotta otherwise, `inkMuted` on `surface` for a slot or kind this build does not recognise. A tint rule written in three cards is a tint rule that drifts.

**Sage is the completion colour, not only the did-it entry type.** A backfill day badged _Written_, a month row carrying its entry count, the permission explainer's bullet checks and the all-caught-up glyph are all `sageInk` on `sage`. It reports, it never congratulates: a month with nothing written in it gets no badge rather than an empty one.

**Done keeps its kind.** A pending `did_it` mission is terracotta like any other mission, and only the finished card goes sage. A completed question stays periwinkle — the tint means mission-or-question, and finishing does not change what it was.

**Kind carries a second channel that survives where colour does not.** `PromptKind.symbol`: question `text.bubble`, photo `camera`, video `video`, audio `waveform`, activity `figure.walk`, letter `envelope`, unknown `sparkles`. The `PromptCard` glyph tile and the Lock Screen accessory families use the same one, so the two surfaces stay one vocabulary.
### Gradients
Reserved for emotional beats only — the welcome screen, all-caught-up, sealed entries, the Moments empty state, a throwback card with no cover, the throwback header on a backfill month, and backfill's own permission and all-caught-up screens. **Never behind a list.** Diffuse and low contrast:

`#FDE8DC → #F7DDE8 → #FBF6EF`, roughly top-left to bottom-right.

It is `Gradients.wash`. `LinearGradient.backfillWash` holds the same three stops and the same endpoints for the backfill flow; those two are the same gradient and there is no third.

**"Onboarding" means the welcome screen, at 55%.** The six setup steps are plain `canvas`. A wash on all six is a wash behind ordinary content, which is what the reservation exists to prevent.

**It carries no text at** `inkMuted` — 4.55:1 on the first stop and 4.22:1 on the middle one, and one line of copy crosses both. A tinted surface that needs muted body copy takes `terracottaSoft` at 4.69:1, with the cream `border` hairline.

* * *
## Type
| Role | Spec |
| --- | --- |
| Display | 34pt bold, rounded. A screen's own name where the header does not stick — Settings, Moments, Backfill — and the welcome headline. Occasionally one word in terracotta. |
| Screen title | 29pt bold, rounded — the timeline's sticky header and an onboarding step heading. A screen that scrolls its own name away takes display instead. |
| Detail title | 26pt bold, rounded — the entry title on Entry Detail |
| Title | 22pt semibold, rounded |
| Prompt body | 20pt regular, rounded, line height 1.30 — the sentence a `PromptCard` is asking, and nothing else |
| Day number | 19pt bold, rounded — the day on a timeline group header |
| Card title | 17pt semibold, rounded |
| Body | 16pt regular, line height 1.45 |
| Quote | 14pt regular, line height 1.4, **set italic at the use site** — a quoted prompt |
| Metadata | 13pt regular, inkMuted |
| Label / small caps | 12pt semibold, tracked +0.6, uppercase, inkMuted |

Rounded runs from Display down to Prompt body and Card title; Body and everything under it is SF Pro Text. The line is headline versus reading copy, not point size — a rounded 16pt body reads as a toy, a non-rounded card title reads as a form. The mockups set headlines in Nunito; rounded is the system stand-in, and no font file is bundled.

**Type is applied with** `.typeRole(_:)` **and never with** `Font.system(size:)`**.** The modifier runs the size through `@ScaledMetric` against the role's text style and applies weight, design, tracking, line spacing and uppercasing together. Tracking and uppercasing belong to the role: `.label` is already tracked +0.6 and uppercased, so `.textCase(.uppercase)` on top of it is redundant. Italic is never part of a role and is always set at the use site. Section headers are `SectionLabel` — `.label` in `inkMuted`, with the header trait already attached.

Date headers set four pieces on one baseline, 8pt apart, with **no separator glyphs**: day number `.dayNumber` in `inkMuted`, month and year `.body` in `inkMuted`, weekday `.label` in `inkFaint`, then the age at the trailing edge as semibold `.metadata` in `periwinkle` on a `periwinkleSoft` capsule. Spacing is the separator — a header joined into one string cannot hold three steps of ink.
### Dynamic Type
Dynamic Type is respected for prose. The sizes above are the values at the default setting, and every role runs through `UIFontMetrics`; a bare `Font.system(size:)` on body or headline copy is a fixed point size that refuses to scale.

Glyphs and geometry-bound numerals are the exception, and the line is whether the size is load-bearing. A glyph that sizes a tile, a disc or a tap target scales with `@ScaledMetric(relativeTo:)` against the role beside it. A decorative glyph, and a numeral set inside a shape that does not grow — a mono duration in a voice band, the `+5` on a mosaic tile, a tab label under a 52pt disc — is a fixed `Font.system(size:weight:)`, because scaling it breaks the shape rather than the reading.

**Picture frames are fixed on purpose.** The mosaic's four heights, the 84pt media preview tile, the 74pt backfill strip and the 232×148 throwback card are sized to a photograph, not to a sentence. Type inside them still scales, so a caption at the accessibility sizes truncates rather than reflows, and nothing that carries meaning lives only inside one of these boxes.

Accessibility-sized layout defects are found by screenshotting, not by reading. Every screen that pins its own geometry should ship a preview at an accessibility size.

* * *
## Prompt bodies
A prompt body is never drawn raw. `Assignment.body` and `Entry.promptBody` are stored and served with pronoun tokens intact — `{they}`, `{their}`, `{They}`, `{they_are}`, `{name}`, thirteen in all — and **every view renders them at the moment of display**, through `PromptTokens.render(_:for:)` with `\.promptSubject` read from the environment. `RootView` sets that environment once, above all five tabs.

Rendering at display rather than on the way into the cache is the whole point: a body rendered upstream could not be re-rendered when the answer changes, and the same body reaches a card, a widget snapshot, an export and a printed book. A view that sets a prompt body without reading the environment prints `{their}` on the card.

Read the rendered body **once**, into a single property shared by the view and its VoiceOver label. Two readings drift into two different sentences.

Thirteen tokens, keyed on they/them — the only English set whose five slots are five distinct words: `{they} {them} {their} {theirs} {themself}`, the agreement compounds `{they_are} {they_were} {they_have} {they_do}`, the capitals `{They} {Them} {Their}`, and `{name}`. Capitalisation is a token, never positional: a prompt may begin mid-thought. Verb agreement is a token, never conjugation: a conjugator is right usually, and an archive does not get "usually".

An unset pronoun renders the they/them column — grammatical for every child, and not a guess at an answer nobody gave. An unknown token renders literally, braces included: a visible `{foo}` is a bug somebody can fix, and a silently dropped one is a sentence that lost a word. A body with no brace comes back byte-identical, which is what lets the 113 seeded he/him prompts stand unmigrated.

`Entry.body` **is never rendered this way.** Those are the parent's own words, and a parent who typed braces gets their sentence back byte for byte.

Client-authored copy — titles, buttons, errors, empty states, accessibility labels — carries no pronoun at all. It uses the child's name, or "your kid" before there is one.

* * *
## Appearance
Light only. The palette is fixed `Color(hex:)` with no dark variant and the app pins no scheme, so the device's appearance is irrelevant to anything drawn from these tokens — until a system control is on screen.

**Every system-drawn picker carries** `.environment(\.colorScheme, .light)` **at its use site.** A `DatePicker` or a wheel `Picker` on a phone in Dark Mode otherwise resolves system label and fill colours for dark appearance and draws near-white rows on the cream canvas: **1.03:1**, measured. Add `.foregroundStyle(Color.ink)` on `.compact` and `.graphical` pickers, whose numerals inherit the ambient foreground; it is a no-op on `.wheel`, where the colour scheme is the whole fix.

The share extension can decline the system appearance and does, with `overrideUserInterfaceStyle = .light`. The widget cannot, and is the one exception — see **Widget**.

* * *
## Shape & elevation
- Card radius: **20** — a full card: `PromptCard`, `EntryCard`, `AllCaughtUpCard`, the skip toast
  
- Compact row radius: **18** — `DoneCard`, `WaitingCard`, and the Entry Detail hero. A row is not a card and does not take the card's corner
  
- Chip / pill radius: **fully rounded** (capsule)
  
- Media inset radius: **14** — also the mosaic block and the voice band on a card
  
- Quote block radius: **16** — the filled prompt block on Entry Detail
  
- Glyph tile radius: **11** on the 34pt filled tile, **10** on the 30pt washed one
  
- Border: 1px `border` on cards
  
- Shadow: barely there — `y: 2, blur: 8, opacity: 0.04`. Warmth comes from the cream, not from depth.
  
- Card padding: 16 internal, 16 horizontal screen margin, 12 between cards in a feed (`Layout.cardSpacing`)
  
- A grouped screen stacks blocks at **18**, with **9** between a section label and the card it opens. A label has to sit nearer the card it names than the card above it, or nine blocks on one scroll read as one column. Sheet fields stack at 22.
  

The numbers live in `Layout` and are applied by `.cardSurface(fill:border:)` — padding, fill, hairline and shadow in one modifier — with `.cardSurface(wash:border:)` the gradient overload sealed letters use. The shadow radius is `blur / 2`: SwiftUI's radius is roughly half a designer's blur, and a card built by hand from the blur figure sits twice as soft as the ones beside it.

`cardSurface` **pads and then fills**, which puts a 16pt ring of card outside the tap target. A card that is itself a button fills first and lets its content pad — `SettingsCard` clips to `cardRadius` rather than backgrounding it, so a child may carry a fill of its own and still take the card's corners.

* * *
## Formatting
Ages, day headers, durations and spelled counts come from `DesignSystem/Formatting.swift`. Four screens saying an age four ways is four vocabularies.

- `AgeText` — `greeting` for the Today header ("5 years old", "14 months old", "5y 2m"), `chip` for a day header ("5y 2m", "11 mo", "newborn"), `long` for a labelled row ("5 years, 2 months"), `spoken` for VoiceOver. Every one takes the server's `child_age_months`; **the client never computes an age**, because a rounding difference in a permanent archive is permanent.
  
- `DurationText.clock` for a voice chip or video badge (`1:04`), `.spoken` for VoiceOver.
  
- `DayHeaderText` for the day header's parts, `.full` for VoiceOver and the Entry Detail date line, `.compact` for a navigation bar.
  
- `CalendarDay` for any `YYYY-MM-DD` the server named. It builds the day at noon UTC and formats it back in UTC, so the day printed is the day the server said. Formatting a calendar day in the device's zone is how a section ends up headed with tomorrow.
  
- `CountText.spelled` for a count inside a sentence — a numeral there reads as a score, and this app keeps score of nothing. Pinned to `en_US`, because the sentences around it are hard-coded English.
  

A clock time is formatted at the use site in the device's zone. `occurred_at` is a genuine instant, and the phone in the parent's hand is the right frame for one.

* * *
## Components
### Chip
Capsule, `.metadata` at 13pt, 10/5 padding, `inkMuted` on `surface`, `bordered` for a hairline. Metadata chips are a soft tint with no border.

`emphasis` makes a chip semibold and 11 wide — the tinted chips along the bottom of an `EntryCard` and the tags on Entry Detail. It is off by default so the timeline's weight does not restyle Today and Settings on its way past.

`Chip` **has no active state.** The timeline's filter capsules are drawn by `TimelineFilterRow`: semibold `.metadata` at 15/8, `canvas` on `terracotta` when active, `inkMuted` on `surface` with a `border` hairline when not, `TapScaleButtonStyle` for the press. Bigger and heavier than a `Chip` on purpose — a filter is a control and a chip is a label. The row scrolls horizontally, because seven capsules do not fit across a phone with Dynamic Type up and truncating one is worse than scrolling, and it carries no background of its own, because it sits inside the header's cream-over-blur.
### KindBadge
The kind marker on a `PromptCard` — "PHOTO", "VOICE", "ACTIVITY". `.label` type in the kind's tint on a capsule of that tint at 12%, 9/4 padding. **Not a** `Chip`: a chip is a fill and this is a wash of one colour, so it never competes with the badge's own word. Pass the text in title case; the role uppercases it.
### Buttons
`PrimaryButtonStyle` — capsule, `.cardTitle` in `surface`, `terracottaDeep` while pressed whatever the tint. `tint` selects the fill by meaning: terracotta for missions and primary, periwinkle for questions. **Two paddings, one shape:** 20/12 inside a card, 20/16 on a screen whose whole job is one decision. Full-width by default, which is what every sheet and form wants; a `PromptCard` sets `fullWidth: false` so its action sits beside the slot's name instead of swallowing the line.

**A disabled primary is waiting, not broken:** `chipPlain` under `inkFaint`. Never red, never a struck-through label, and no new token — a dedicated disabled grey would be an ink-ramp step this palette does not have. That state lives on `OnboardingPrimaryButtonStyle`; callers of the plain style dim their own at 0.5. The mockups fill it `#D9CFC2`, which has no palette equivalent and is not being added as one.

`OnboardingSecondaryButton` — the quiet way out. "Skip for now", "Clear", "Not now": underlined `inkMuted` body at full width. **Never a second filled button competing with the real action**, and never dimmed relative to it — on the notification step both answers carry equal weight, because "Not now" is a complete answer.

`TapScaleButtonStyle` — scale 0.98 over 0.12s, and no scale at all under Reduce Motion. Tappable cards, settings rows and filter capsules all carry it.
### Field
One form field, two dressings.

**In a sheet:** a `SectionLabel`, then the control 8 below it on `surface` at radius 14 with a `border` hairline and 12 of padding. Text fields, the timezone row, the pronoun row and a notice line are all that same box; a read-only value takes it filled `canvas` rather than `surface`. A form that changes shape per field reads as four unrelated controls. Fields stack 22 apart inside the screen margin, and where a value needs explaining one `metadata` line sits under it.

**On an onboarding step:** the field is the screen. A `TextField` at display size with an `inkFaint` prompt, a terracotta caret, and a 2pt terracotta rule 12 below it. No box — the step asks one thing, and the rule is all the chrome it needs.

Sheet chrome is fixed: a `NavigationStack` over `canvas`, an inline title, Cancel in `inkMuted` at the leading edge, and the confirming action trailing in `terracotta` — `inkMuted` and disabled while there is nothing to save, reading "Saving" while the write is in flight. **A sheet whose changes are already on the server drops Cancel and offers Done**: a button called Cancel over a landed save tells the parent the opposite of what happened.
### Toggle
A stock `Toggle`, tinted `.terracotta`. **Never a hand-drawn pill:** a styled `HStack` loses the state announcement, Switch Control, Full Keyboard Access and Dynamic Type growth, and the tint is the only thing a mockup asks for that the stock control cannot already do.

Where the write can be refused, bind through a closure rather than a `Binding` into the model — otherwise the switch animates to a state the server never accepted.

**A one-off instruction attached to a single save is a checkbox, not a switch.** A switch reads as a standing preference. Use a `ToggleStyle` rather than a glyph in an `HStack`, for the same accessibility reasons.

**Off is an available state, not a disabled one.** Nothing dims: same `ink` label, same `inkMuted` detail, same undimmed card, and the detail line says what turning it on would do. A control refused at the system level is replaced by a sentence and a way to iOS Settings — a toggle that moves and changes nothing is a control that lies.
### CompletionCheck
Circular checkmark that fills with a spring (`response: 0.35, damping: 0.7`) plus `Haptics.completion()` — a `.success` **notification**, not a light impact, because a light tap reads as "button pressed" and this is the one moment in the app worth a warmer note. One haptic, never a sequence, fired by the view that completes rather than by the check itself.

**The disc is tinted to what it is reporting**, not to the brand: terracotta where completing is the action, `sageInk` on a did-it card, the card's own tint on a completed question. The tick is `surface`, or `sage` on a `sageInk` disc, and is 45% of the diameter so the control scales as one thing. The host sets the size — 26 on a done row, 56 on the caught-up card, 96 in the composer, 28 by default.

On Today the completed card does not restyle in place: it is replaced by a `DoneCard`.

No confetti. No stamp. No streak counter.
### UploadRing
The completion check with an upload ring around it, and **one control rather than two states swapped at the end**: the ring fills as bytes land and closes straight into the check drawing itself, so upload and completion read as one gesture. It is the done badge on a `PromptCard`, and the completion mark on a `DoneCard` while files are still in flight.

26pt on a card, terracotta throughout. Track at 18%, stroke `max(2, diameter × 0.09)`, arc solid with a round cap from twelve o'clock, floored at 2% so it never reads as empty, easing 0.3 to each new fraction. Progress is **weighted by bytes, not by file count** — one large photo among three small ones must not send the ring to 75% and leave it there. A remaining count sits inside at 0.4× diameter, and only when more than one file is left: "1" beside a nearly-full ring is noise.

Closing is three beats on one timeline — the disc springs in at (0.32, 0.55), the check draws 0.06 behind it, and a halo carries the motion outward to 1.9× and fades over 0.55. Under Reduce Motion the whole thing collapses to `easeOut(0.25)` and the check still fills. Already-done cards start closed rather than replaying; the animation is for the moment it happens, not for every scroll past it.

**The ring never reads as an error.** A failed file counts as landed, so the ring still closes; failures are stated underneath instead, one row per file — an `inkMuted` ✕, "This photo hasn't uploaded yet", and a terracotta "Upload it", plus "Upload all 3" when there is more than one. "1 of 3 uploaded" tells a parent nothing they can act on, and nothing here is red, because the file is still on the phone and nothing has been lost.
### Toast
A transient confirmation with one undo, and **the only inverted treatment in the app**: body in cream on an `ink` fill, the action in `terracottaSoft` semibold. It has to read over a scrolling grid of photographs, which a cream card does not. Two ship — Today's skip toast at card radius, backfill's set-aside toast at quote-block radius — both as a bottom overlay, screen margin in from the sides, 30 up from the bottom, entering on move-plus-fade.

**What Undo means is the surface's own decision, and it follows the endpoint.** A month set aside is persisted before the toast appears, so a force quit leaves it set aside and Undo restores it. A skipped prompt is not sent at all until the toast has gone, because dismissal is one-way.
### StaticWaveform
The bars in the card's voice band and on the Entry Detail hero. Periwinkle, 3pt wide at a 3pt gap, the count read from the available width so the block fills its row on every device and at every Dynamic Type setting. Heights come from a cheap function of the index — **the same shape every time a card scrolls back into view**, because a waveform that reshuffles reads as a loading state. 23 tall on a card, 44 on the hero.

**Never the recording's real levels.** A true waveform means decoding the file for every audio entry on a screen that may hold fifty; what this says is "there is a voice note here, this long". With no playback to report every bar sits at 0.45. Under a player the played bars go to full and the rest to 0.32 — one object doing one job, which is why the hero has no separate progress rule.

* * *
### PromptCard
Today's mission or question, and the only card on the board that is asking for something. Tinted fill by kind (terracottaSoft / periwinkleSoft), radius 20, card padding 16, 14 between zones.

| Zone | Spec |
| --- | --- |
| Glyph tile | 34pt, radius 11, filled `tint`, 15pt `surface` glyph. Scales with Dynamic Type — a fixed glyph in a growing frame becomes a dot. |
| Kind badge | `KindBadge`, not a `Chip`. PHOTO · VIDEO · VOICE · ACTIVITY · QUESTION · LETTER |
| Expiry chip | only inside the window — see below |
| Upload ring | trailing, 26pt, on the done presentation |
| Body | the prompt in `promptBody`, `ink` — `inkMuted` once done |
| Footer | slot footnote left, capsule button right |

The footnote names the slot and counts nothing: "Today's mission", "Today's question", "All week to finish", "Any time this month", "A letter, for later", and "Still open" for anything carried over. A card that said "day 4 of 7" is a streak counter wearing a different hat.

The button's label is the completion mode, never the kind: "We did it" · "Write it" · "Capture it", and "Open" for a mode this build doesn't know. It is tinted to the card and is **not** full width, and the row it sits in stacks vertically rather than clipping when the footnote and the button no longer fit side by side.

Expiring-soon shows a quiet chip on `chipPlain`, `inkMuted`, never red, never bold, never animated: "Last day" · "1 day left" · "2 days left". **It appears only within three days of expiry** — nothing counts down before that, an expiry further out says nothing, and a date already past says nothing either, because the server decides what is expired and a negative number is a board mid-refresh. Both ends of the measurement are the server's: `expires_on` against `TodayResponse.date`, parsed as days rather than instants. `Calendar.current` is the _device's_ idea of today and is off by one for a parent in a different zone from their child.

States: `pending` · `expiringSoon` · `done` · `dismissed` (removed).

**Done keeps its kind.** A completed question stays periwinkle and a completed mission stays terracotta; sage on a done card means `did_it` specifically. The body drops to `inkMuted`, the hairline follows the fill, and the badge is an `UploadRing`. In practice a `PromptCard` on the board is rarely done at all — `TodayBoard.merge` moves anything with a local entry or a server `done` status into Done today as a `DoneCard`, and the card keeps a done presentation mainly for its previews.

The `slot` values are `question`, `mission`, `mission_b`, `weekly`, `monthly`, and `letter` — **three daily slots, not two**, with `mission_b` drawing video, audio and activity. Both daily missions read "Mission" and both footnote "Today's mission": the parent is never told there is an A and a B, because numbering them makes the pair look like a checklist to clear.

A slot **or** kind the client doesn't recognise renders neutral — `surface` fill, `border` hairline, `inkMuted` tile and badge, body text intact, **no guessed tint**. An unknown value from a future server release is never a crash and never a blank card. The badge names the kind and prints the server's raw string only when the kind is the unrecognised half. Note the cost of the same branch: a _real_ slot left out of a switch lands here too, and renders one of the parent's three daily cards grey.
### TodayBoard
One screen, top to bottom, on `canvas`:

| Row | Spec |
| --- | --- |
| Header | `ChildSwitcherPill`, the age greeting beneath it in `metadata`/`inkMuted` |
| Notice | `surface`, radius 14, `border` hairline, info glyph + a `metadata` line + a terracotta Dismiss. A quiet note, never a dialog over the parent's evening |
| Today | `PromptCard` per item |
| Waiting | `WaitingCard` per item, count chip in the header, swipe-to-skip |
| Done today | `DoneCard` per item |
| End | `AllCaughtUpCard`, when it is earned |

**A section with nothing in it is absent, never an empty labelled shell.** Section headers are a small-caps `SectionLabel` over a 1px `border` rule; only Waiting takes a count, and only when it is non-zero.

The board is a `List` styled back down to plain rows — no separators, no fills, no inset chrome — because `swipeActions` exists only on `List`, and a hand-rolled drag gesture would fight the scroll and be invisible to VoiceOver.

The screen's other two states are a terracotta spinner and a "Can't load today" panel carrying the message and a Try again button. A refetch that fails over an already-loaded board becomes a notice instead, never a blanked screen.
### DoneCard
Something finished today. A compact row, not a card: radius **18**, padding 14/16, filled with the tint the item carried as a prompt and that tint's hairline — sage/`sageBorder` for `did_it`.

Leading: a 26pt mark. An `UploadRing` while bytes are still moving, a `CompletionCheck` once they have landed, tinted `sageInk` on did-it and the card's own tint otherwise. A finished check over three photos still climbing out of the phone is the card telling a comfortable lie.

Trailing: the prompt in `body`/`inkMuted`, two lines — at accessibility sizes one line of a long prompt is three words and an ellipsis. Under it a `metadata` line naming **the shape that landed, not the prompt's kind**: "Photo · 4:12 PM", "Voice · 6:30 PM", "Written · 9:20 PM", "Did it · 7:05 PM".

A row the server acknowledged with no local entry — completed on the other parent's phone, or before this install — says what was done and stays quiet about when, which is better than guessing. Those rows are not tappable; every other done row opens the entry it produced.
### WaitingCard
A pending assignment carried over from an earlier day. **Compact on purpose:** a full `PromptCard` each would turn a quiet backlog into a wall of unfinished work, which is the tone this app exists not to have.

`surface` row, radius **18**, padding 14/16, `border` hairline. A 30pt glyph tile — **washed, not filled**: `tint.opacity(0.12)` at radius 10 with the glyph in `tint`, because a solid disc of terracotta on eight rows reads as eight alarms. The prompt in `body`/`ink`, two lines. Beneath it the kind badge and one chip, then an `inkMuted` chevron.

The chip is the expiry when there is one — the only fact here with a deadline in it — and otherwise how long the item has waited: "Yesterday", "3 days ago", "Earlier" past a week. Nothing gets more specific, because "assigned 46 days ago" is an audit and this app does not audit anyone.

The card is presentational. The skip lives on the row that owns it, so VoiceOver gets a rotor action rather than a swipe nobody can discover.
### AllCaughtUpCard
The end of the board. The gradient wash with a `sealedBorder` hairline, 28/22 of padding inside the card's own, centred title in `title`/`ink` and subtitle in `body`/`inkMuted`.

| Mode | Disc | Copy |
| --- | --- | --- |
| `caughtUp` | 56pt terracotta check | "All caught up" · "Three things saved today. Come back tomorrow — or don't. It'll wait." |
| `nothingYet` | none | "Nothing waiting" · "Today's prompts arrive in the morning." |

**"All caught up" requires having caught up with something.** An account whose scheduler has not run yet has an empty board and has done nothing; telling someone on their first morning they are all caught up is praise for no work. Anything still open — today or waiting — means the board is not finished and earns no card at all.

The count is spelled out and counts things saved today. There is no count of consecutive days here and there never will be.
### ChildSwitcherPill
The child's name at the top of Today. `surface` capsule, `border` hairline, padding 6 leading and 6 vertical, 14 trailing with no chevron and 12 with one. A 30pt terracotta disc holding the name's first letter, uppercased, in bold `metadata`/`surface` — "?" for a name that is all whitespace, because the archive belongs to a real child either way. The name in `cardTitle`/`ink`, one line, truncating rather than pushing the row's trailing controls off screen.

**The initial is the whole treatment, not a fallback** — `/today` returns `id`, `name` and `age_months` and no image, so a coloured disc with a letter in it is the only honest thing to draw.

The chevron is `inkMuted` and appears **only when there is somewhere to go**. One child and a chevron is a control that lies. Disc and chevron both scale: a fixed 30pt disc beside 30pt text reads as a bullet point.
### SkipToast
A waiting row is skipped by a trailing full-swipe labelled "Skip", tinted `inkMuted` — **never red.** Skipping a prompt that does not fit this family is an ordinary thing to do, not a destructive one. A live `PromptCard` offers the same thing as "Not for us" in a context menu.

The row leaves immediately and the toast takes its place: the quoted first sentence of the prompt, clamped to two lines and truncated past 60 characters, with an Undo. A row that sits there greyed out while a toast offers to undo it has not visibly done anything, and the parent swipes again.

**The dismissal is not sent while the toast is up.** There is no un-dismiss endpoint, so the only honest undo is to hold the request for eight seconds and send it if Undo is not tapped. Eight rather than five because VoiceOver has to finish announcing the toast before anyone can act on it. Backgrounding commits the skip — leaving is a decision — while `.inactive` does not, because ending someone's undo window when a notification banner slides down takes the decision away from them.

* * *
### EntryCard
The timeline workhorse. **v3 rebuilt it around the prompt**: the card reads top to bottom in the order the moment happened — what was asked, then what came back.

Six zones, stacked, and **every one drops out when it is empty.** No reserved space, no placeholder frame, no gap where a picture would go. Half the mission library produces no artifact, so a card with nothing but a prompt and a title is the common case, and it has to look deliberate. Height follows content, and that variation is the only rhythm the list needs.

| Zone | Spec | Gap below |
| --- | --- | --- |
| Media mosaic | see below | 13  |
| Voice band | periwinkleSoft fill, radius 14, 34pt periwinkle play circle, waveform, mono duration | 13  |
| Quoted prompt | 2pt rule + 11pt indent, quote role italic, inkMuted, 2 lines | 9   |
| Title | card title, ink, 2 lines — with a sage check on did-it, a terracotta envelope on sealed | 5   |
| Body | body role, inkMuted, 2 lines (**3 for written**) | —   |
| Chips | kind chip tinted, up to two tags on `chipPlain`, then "Saving" if the row has not synced — all `emphasis` | 12 above |

**The title zone is the one that never drops out.** A card with no title still has to say what it is: "A letter" when sealed, "We did it" for did-it, else the kind. A did-it entry with no note is the archive working as designed, not a blank row.

The body line is the parent's own preview, else the opening line of the voice transcript, else nothing — and **a line that is not the parent's is set italic**, because the words are somebody else's. Under search the matched sentence outranks both, so a row whose only connection to the query is forty seconds into a recording can say so. A sealed card carries no body and says when it opens instead, in `sealedInk`: the one fact about a sealed letter that is not sealed.

The kind chip pairs fill with ink by tint: `terracottaSoft`/`terracottaDeep`, `periwinkleSoft`/**`periwinkleDeep`**, `sageSoft`/`sageInk`. Terracotta and periwinkle both take the deep step because the base tint on its own soft fill does not read, and sage on sage is not a chip either.

> **Contrast, measured Aug 12, 2026.** Chip text is 12pt semibold, which is *not* large text, so
> the bar is 4.5:1.
>
> | Pairing | Ratio | |
> |---|---|---|
> | `terracottaSoft`/`terracottaDeep` | **5.73** | passes |
> | `periwinkleSoft`/`periwinkleDeep` | **6.00** | passes — was `periwinkle` at 4.17 |
> | `sageSoft`/`sageInk` | **3.96** | **fails, and is a known accepted exception** |
>
> **The sage exception is a decision, not a gap.** A `sageDeep` token was offered and declined by
> the owner on Aug 12, 2026. Sage is the did-it tint — the completion shape that produces no
> artifact — and it is the quietest thing on the card by design; a deep sage would make the chip
> on a did-it entry louder than the entry. **It is recorded here so the next contrast audit finds
> an answer rather than a bug**, which is the same reasoning the paper-grain rejection needed
> three times before it was written in the words the exports use.
>
> `periwinkleDeep` was added for `KindBadge`, which had the identical defect. **The chip pairing
> is written in three places** — `EntryCard.chipTint`, `EntryDetailScreen.kindChip` and
> `KindBadge` — and they must move together. A shallower periwinkle was tried and rejected:
> `#4A5AC4` clears AA on `surface` at 4.99 and **fails on `periwinkleSoft` at 4.33**, which is the
> ground a question card actually uses.
>
> **Glyph tints are a different bar and are unchanged.** `MediaThumbnail` draws an SF Symbol, not
> text, so it answers to the 3:1 graphical-object requirement and `periwinkle` on `periwinkleSoft`
> clears it at 4.17. Two tags at most: a third pushes the row past the card on a narrow phone, and a truncated chip reads as a rendering fault rather than as a tag. **"Saving" is a fact about the network** — never an error, never a warning, never a loss.

**The mosaic has four shapes**, by tile count: one (242 tall, 196 for video), two (164), three (62% wide plus two stacked, 216), and a 2×2 (108 per row). Gutters are 4pt of card showing through — no hairline per tile. Past four, the count is **printed on the last tile drawn** — `+8` at 22pt bold in `canvas` over a 30% terracotta wash — and never given a tile of its own: nine photos and four photos must produce the same card height. That tile drops its kind glyph, because a camera icon behind a number is two marks fighting over one square. The count is the server's media count minus the tiles drawn, **not this phone's cache**, so a card holding one downloaded photo of nine still says `+8`.

**The prompt is the point of v3.** It comes from `entries.prompt_body`, which `GET /entries` carries on every row — the card has no fallback and needs none. Freeform entries have no prompt and the zone is simply absent. Entry Detail keeps a fallback to the assignment the entry completed, so its block does not vanish in the beat before the detail fetch lands.

**No age chip on the card.** Age moved to the day header, stated once per group.

Card fill and hairline by state: surface/`border`, sage/`sageBorder` for did-it, the gradient wash/`sealedBorder` for a sealed letter.

`thumb_key` is null on every media row — generation was cut from P0 — so **the client makes its own**: one fetch of the original, downsampled to 400px, held in memory and on disk beside the staged originals, and never fetched again. Disk first for every kind, the network only for photos: a video is never pulled down for a poster frame and audio has nothing to draw. A tile with no picture is therefore the ordinary case rather than the error case, and renders as its kind's tinted square with a kind glyph. Views reach the cache through `\.thumbnails` in the environment, never through an initialiser, so an `EntryCard` inside a Moments carousel fills the same cache the timeline does.
### TimelineHeader
Sticky, translucent: cream at 94% over a blur, so the archive is softened behind it rather than hidden. Screen title left, count right, filter row beneath, and a magnifier after the count.

The count **never claims to know the size of the archive**. Until the last page has landed it reads "412 so far"; only once paging is exhausted does it read "412 entries".

The timeline's filter row is All · Photos · Video · Voice · Written · Did it · **Sealed**. Sealed is `unlock_at_age`, not an `entry_type`, so it goes on the wire as `?sealed=true` rather than as a `?type=` value. **Every chip is a server filter**, which is what makes one page fetched one page drawn. The chip sends `true` or nothing, never `false`: no chip in this row means "everything except letters".
### Search
Opening the magnifier replaces the title row with a capsule field on `surface` with a `border` hairline and **hides the filter row** — a chip that no longer narrows anything is a control that lies. Same strip, same list, same cards either way: search is a way of looking at the timeline, not a place.

Search reads the whole archive and never combines with a filter. Results draw in the server's order — relevance, then newest — and nothing on device re-sorts them. Keystrokes debounce at 300ms. A row that matched a sentence buried in a transcript sets that sentence italic in the body zone, in place of the parent's own line; a row that matched something the card already shows explains nothing. **No closing line under results** — "Keep scrolling and it only gets younger" is a sentence about an archive, and a page of results is not one. No scope bar, no history, no suggestions, no highlighting. Empty is one line.
### Timeline states
Four, and they must not render the same:

- **Nothing fetched yet** — a terracotta spinner. Not an empty archive.
  
- **Empty archive** — a washed card with one thing to do: "The archive starts here" and _Write the first one_. The first-run state, not a shrug.
  
- **Empty filter** — quieter, no illustration: "Nothing here yet", "No voice notes so far.", and a way back to All. Nothing is missing; the archive simply has none of this kind yet. The noun is written for a sentence, not reused from the chip.
  
- **A failed fetch** — an inline row at the top of the list, `info.circle` on `surface` at media-inset radius. Never a dialog, and never blanking the cache already on screen.
  

Under the last card sits a terracotta spinner while a page is in flight, and once there is no page after it, the closing line in `inkFaint`: "Keep scrolling and it only gets younger.", or "That's every one of these in the archive." under a filter. **No count of days, no streak, no note about how long it has been** — the bottom of a permanent archive is the last place to start keeping score.
### DayHeader
Bold day number, lighter month and year, faint uppercase weekday, and the age the child was that day as a periwinkle capsule pushed to the trailing edge. A year rule sits above the first group of each calendar year.
### EntryDetail
One entry in full. It renders from the cache the instant it opens and fills in `GET /entries/{id}` behind that — the detail call adds the prompt and the transcripts, and neither is worth a spinner over content already on screen.

Unlike the timeline root, this screen wears the standard navigation bar, titled with the entry's `occurred_at` in compact form and carrying an ellipsis menu of Edit and Delete. Edit opens the composer; there is one editor in this app.

Stacked, and every block drops out when it is empty:

| Block | Spec |
| --- | --- |
| Hero | pictures, else the voice player, else nothing. One picture is a 4:3 block at hero radius with a `border` hairline; several are a paged carousel 300 tall. Video carries a play glyph and its runtime. |
| Prompt | filled block at quote radius, tinted to the entry's kind. `ANSWERED <date>` eyebrow in inkFaint over the prompt in inkMuted. 18 below the hero. |
| Title and body | detail title and body, both in **ink** — the parent's words are the one thing on this screen set at full strength. A did-it entry with neither renders a sage check and "We did it". |
| Transcript | `TRANSCRIPT` label in inkFaint over body copy in ink. Absent, never empty: an audio entry with no transcript is complete, not pending, and a heading over a blank line implies something is missing when nothing is. |
| Metadata | key/value rows under a `border` divider — age as a periwinkle capsule, date, count, length, and "Saved / Here — it'll sync when you're back on" while the row has not reached the server. |
| Tags | `chipPlain` chips with `emphasis`. |

The voice hero is periwinkleSoft at hero radius with a `periwinkleBorder` hairline, a 52pt periwinkle play circle, and **the waveform is the progress bar** rather than decoration above one.

A sealed letter replaces the whole stack with a washed card: lock, title, "Sealed until 18", the date it was written, and **Open it** — the parent wrote it, and a lock the author cannot pick is a lock on the wrong person. Opening lasts for that viewing; nothing is persisted.

Tapping a picture opens it fullscreen on `ink` — dark and warm, never black — pinch clamped between actual size and 4×, double tap for 2×, video playing on open and released on dismissal.

* * *
### Composer
One screen per completion shape, because "we did it", "captured it" and "wrote it" are different gestures rather than one form with three labels. `mode` decides, and an unrecognised mode falls to capture — the shape that can hold anything.

- `did_it` — a 96pt `CompletionCheck` with the completion haptic, one line of body copy, and an optional note field of 3–6 lines. This reads as complete and legitimate, never degraded: the server derives the type and a note does not reclassify it.
  
- `media` — capture, then the writing field beneath it. A photo alone is a complete entry; requiring a caption would be requiring homework.
  
- `text` — the writing field, labelled "What happened" freeform and "Your answer" under a prompt. A freeform text entry also gets photo and voice capture, because it is the surface someone sits down at with a year of camera roll.
  

Every field sits on `surface` at radius 14 with a `border` hairline; the writing field is 180 tall at rest. Save enables on the mode's own evidence: did-it toggled in `did_it`, and one staged file or one non-empty line everywhere else. Cancel and Save are navigation-bar actions.

**The quoted prompt in a composer is not the card's.** A 3pt terracotta rule at 35% — one colour, never tinted to the kind — beside body-role `inkMuted` text, unclamped, on a `surface` block at radius 14 with 12pt padding. The composer is showing the sentence being answered right now, not remembering one, so it is set at reading size and never truncated.

**Date provenance.** A composer reached through the camera roll says where its date came from, under the pill, before anything is saved. A date read off the asset gets one metadata `inkMuted` line: "From the photo · tap to change". A date nothing knew gets a `terracottaSoft` block at radius 14 — `calendar.badge.questionmark` at 13pt terracotta, a semibold `ink` line, an `inkMuted` instruction naming the month standing in. The two must not render identically: a photo from October 2019 filed under this week looks completely normal and is wrong permanently. Tinted rather than red, because an absent date is not an error.

**Editing.** Opening the composer on an existing entry edits its date and its words. Media already attached renders read-only — a count label over 84pt thumbnails at radius 14 with a `border` hairline, no remove, no add — and a thumbnail missing from the local cache draws a plain `surface` tile rather than an error, because the bytes are still in storage. `SealControl` is not offered. Save stays enabled with nothing changed: a date-only edit is the whole point of backdating.
### CaptureChoices
What an empty composer offers: full-width `terracottaSoft` tiles at card radius, a 22pt light glyph over a card-title label in terracotta, 22pt of vertical padding.

The prompt's kind decides the set, because an affordance that leads nowhere is worse than its absence: an `audio` prompt gets one Record tile, a `video` prompt gets Choose and Record with no voice tile, and everything else gets Choose, Take a photo and Voice — a voice note is a legitimate answer to almost anything, and to a freeform entry especially.

Once something is staged the tiles give way to `MediaPreviewRow` and two metadata-sized terracotta text actions, Choose from library and Add a voice note. Both, because one entry may hold photos and a voice note together.
### MediaPreviewRow
What is staged in the composer, once anything is. A count as a section label ("3 photos"), then a horizontal strip of 84pt tiles at radius 14 with a `border` hairline, 10pt apart.

Every tile carries its own remove affordance: a 10pt × in `surface` on an `ink`-at-55% circle, inset 5pt at the top trailing corner. A voice note has no thumbnail and never will, so it draws a `periwinkleSoft` tile with a 20pt waveform glyph and its duration — a grey box would read as a picture that failed to load.

Four tiles show and the rest collapse into a `+N` tile on `surface`. **Its own tile here, unlike the** `EntryCard` **mosaic**, which prints the count over the fourth photo: the composer's strip scrolls and has no fixed height to protect. The strip ends in a `terracottaSoft` `+` tile that opens the library picker.
### DatePill
Capsule — `surface` fill, `border` hairline, 12/7 padding — showing the entry date beside an 11pt chevron. The label reads "Today" on today and `9 August 2026` on any other day. This is the backdating affordance and it is the first element of the composer's scrolling content, where it's obvious.

**Tapping expands it in place; nothing is presented.** The chevron rotates 180° and a `.graphical` DatePicker unfolds beneath the pill on a `surface` block at radius 14. Expanding rather than presenting keeps the prompt and the staged photos on screen while the date is chosen. The picker is bounded `...Date()`, because nothing happened tomorrow. It is tinted terracotta, pinned to `.light`, and its numerals are set in `ink` — they inherit the ambient foreground otherwise, which on cream is under contrast minimums.
### SealControl
The one control that writes `unlock_at_age`. Washed with the sealed gradient over `sealedBorder` through the standard card surface — the reader's own treatment, because this is the same object being made.

A `lock` glyph (18pt light, `terracottaDeep`), "Seal this letter" at card title in `ink`, and a terracotta toggle on the trailing edge. Sealed reveals a stepper reading "Opens at 18" — the reader's sentence verbatim, because `EntryCard` writes the same words at the other end of the object's life — over one metadata line saying what that means. The stepper offers 10–21, and a prompt's own `default_unlock_age` is clamped into that range rather than left unreachable.

Offered for `letter` prompts only, never while editing, sealed on by default. It sits after the mode block and before Save: the letter is the thing, and when it opens is decided once it exists.
### AudioRecorder
Presented full-screen on canvas, titled "Voice", with Cancel in the navigation bar. Top to bottom: waveform, elapsed time, control row — **the time sits above the buttons**, so a thumb on the record button never covers the number it is changing.

- Waveform: 96 tall, full width inside the screen margin. 48 periwinkle capsule bars, 3pt gutters, 3pt floor, newest on the right so it reads as moving forward. Full periwinkle while recording, 45% otherwise.
  
- Elapsed time: title role, monospaced digits, `ink` — `terracottaDeep` inside the last thirty seconds of the cap. It is a fact about the recording, not a countdown, and nothing turns red.
  
- Record button: 84pt terracotta circle, terracotta shadow at 28%, r10, y5. The `surface` glyph inside morphs between a 52pt circle and a 30pt rounded square on the completion spring — the same button reads as running without a second control appearing.
  
- Flanking circles: 52pt `surface`, `border` hairline, 19pt glyph, 34pt from the record button. Cancel (×) in `inkMuted`, confirm (✓) in terracotta, disabled as the glyph at 40%.
  

Ten minutes is the cap. At the cap the recording stops and is kept.

**States:** `idle` **·** `recording` **·** `paused` **·** `finished` **·** `denied` **·** `failed`**.**

Idle, recording and paused share one layout so the record button never moves under the thumb; the metadata caption under the timer carries the difference — "Up to ten minutes." / "Recording" / "Paused. What you've recorded is safe."

`finished` is a review screen, not a dismissal: the frozen waveform, the take's length, a `TakeScrubber`, a re-record circle and an 84pt terracotta confirm where the record button was. Hearing a take before committing to it is the point of the step.

`denied` is calm and never a dead end — `mic.slash` at 30pt light in `inkMuted`, "The microphone is switched off", a primary Open Settings button, a "Not now" way out, and the line saying the mission is still answerable by writing or with a photo. `failed` states what stopped and offers Try again.

Destroying a take asks first: a discard dialog on cancel, a replace dialog on re-record. The bytes exist nowhere else.
### TakeScrubber
Play/pause and a draggable position, on a `periwinkleSoft` block at radius 14 with 14pt padding. A 44pt periwinkle circle with a 17pt `surface` glyph, a periwinkle-tinted slider, and `0:04 · 0:12` in metadata `inkMuted` beneath it. Periwinkle throughout, because it is voice.

It seeks on release rather than on every frame of the drag — scrubbing AAC continuously stutters, and the thumb already shows where it will land. Review only: a take already in the archive plays through `VoicePlayerView`, which resolves its media through the API.

* * *
### SettingsRow family
The grouped-list vocabulary. Settings uses the app's own shapes rather than the system's grouped list, which brings its own greys and its own register.

`SettingsCard` — one card per section, rows divided inside it. `surface` fill, radius 20, `border` hairline, the standard shadow. **It fills and lets its content pad itself**, unlike `cardSurface`, which pads and then fills: a row must be tappable to the card's own edges, and a 16pt ring of dead card around a tap target is a defect nothing on screen reveals. Clipped to its corners, so a child may carry a fill of its own.

`SettingsSectionHeader` — a `SectionLabel` with a `border` rule running from it to the trailing edge. With nine blocks on one scroll a bare label reads as belonging to the card above it; a line closes the group it opens.

`SettingsCardHeader` — the head of a card that reports before it lists. Label-role eyebrow, optional trailing counter, headline at card title, one `metadata` detail line.

`SettingsRow` — label `ink` at body, optional trailing value `inkMuted` at body on one line tail-truncated, and a 13pt semibold `inkMuted` chevron. **A row value is** `inkMuted`**, always**: a set value and an unset one differ in the words, never in the colour, and an unanswered optional shows no value at all rather than a claim.

`SettingsValueRow` — the same row reporting rather than navigating. No chevron, no tap.

`SettingsActionRow` — label in `terracotta` because it is a thing you do, one optional `metadata` line beneath it, a terracotta `ProgressView` while busy, `inkMuted` label when disabled. No filled button inside a list.

`SettingsDivider` — a 1px `border` line inset to `cardPadding`, so rows read as a list rather than as stacked boxes.

**A divider says "these belong together"; a gap says "these do not."** Rows that share a card share a meaning, and irreversible actions get their own card with whitespace above it.
### ChildHeroCard
Settings opens on the child, not on configuration. A `terracottaSoft` `SettingsCard` — keeping the cream `border` hairline — holding the avatar disc, the name at detail title, `4 years, 1 month · born 19 June 2022` at metadata, and a chevron into the same sheet Birthday, Pronouns and Timezone open. The whole card is one button, and the padding lives inside it.

The disc is 56pt, scaled against `.title`, clipped to a circle and ringed with 3pt of `canvas` at 70%. **The ring and the frame sit outside both branches**, so an avatar landing a moment after the name cannot resize or re-ring the circle it lands in. With bytes: the image, `scaledToFill`. Without: the name's first grapheme, uppercased, `canvas` on `terracotta` at detail title.

**No avatar is not a failure state and gets no treatment of its own.** A child who never had one, a fresh install with no network, and a key whose object has gone all render the initials disc.

**The avatar has no upload state, and that is the design.** The crop is written to disk and on screen before anything touches the network; the upload rides the foreground sweep with no spinner, no progress and no row of its own; a refusal clears the pending record and keeps the local copy. An error about a picture the parent can see is an error about something that plainly worked.

Before the child has loaded: a `chipPlain` disc, one `inkMuted` metadata line, and no button. It says nothing about why — the same placeholder covers a fetch in flight and a fetch that failed offline, and the screen's notice line is what separates them.

No counts. The hero states nothing about the size of the archive, for the reason `TimelineHeader` gives.
### OnboardingChrome
One frame, every setup step.

`OnboardingStepScaffold` — heading at screen title, optional subtitle at body/`inkMuted` 10 below it, content 28 below that, footer pinned to the bottom. **The content scrolls and the footer is a** `safeAreaInset`**, never a** `Spacer`**.** A spacer only pushes while there is room, so at the accessibility sizes the stack overflows and drives the rail up under the Dynamic Island. The footer sits on a `PinnedActionBackdrop` — a `canvas` fade, clear to opaque — with 26 above it, so copy scrolling underneath fades instead of colliding.

`OnboardingProgressBar` — a 4pt capsule 8 below the top edge, inset to the onboarding margin: `border` track, `terracotta` fill at `step.ordinal / OnboardingStep.count`, easeOut 0.52. That is the screen settling, not an animation playing. One VoiceOver element reading "Step 3 of 6", never one per step. Absent on the welcome screen, which is not a step.

`OnboardingBackButton` — a 17pt `inkMuted` chevron in a 44pt target at the top leading corner, on every step but the first. The first step carries "Not you?" at metadata/`inkMuted` in its place: signing in with the wrong Apple ID is easy, and a state with no exit is a defect.

A step arrives with fade and rise, easeOut 0.28, plain opacity under Reduce Motion. Nothing slides sideways; this is not a page turn.

* * *
### FloatingTabBar
Capsule, floating 4pt above the safe area. Five slots — Today · Timeline · **+** · Moments · Settings — and four buttons: the middle slot is an empty spacer that still claims its fifth, so the four real tabs stay evenly spaced and nothing in the capsule competes with the disc for the tap.

The **+** is a 52pt terracotta disc with a 4pt `canvas` ring, composited over the capsule **after** the capsule's own stroke. An overlay draws above everything in the view it modifies, so a stroke applied last puts a pale ring across the top of the disc — a ring by accident, in the wrong colour, on one edge only.

The disc clears the capsule by 14pt **measured from the capsule's top edge**, never by an `.offset` from its centre. A centre offset holds a fixed distance between two centres, so it yields a fixed protrusion only while the capsule's height is fixed — and at the accessibility sizes it leaves the disc entirely inside a taller capsule.

Tab labels are the one exception to the type scale: 10pt semibold uppercase at 0.3 tracking, one line at minimum scale 0.75, rather than the 12pt label role — five labels beside a raised disc do not fit the capsule at 12.

The bar's shadow is heavier than a card's — `ink` at 0.06, radius 10, y 4 — because it floats over scrolling content rather than sitting on the canvas. The disc keeps the system shadow.

No badge, no count, nothing hides on scroll.
### AddToArchiveSheet
What the centre **+** opens. **It is not the composer.**

A title, then four capture verbs — Photo · Camera · Voice · Write — as a 2×2 grid of card-surface tiles at 10, each an 18pt terracotta glyph in a 38×38 `terracottaSoft` block at radius 12 above a card-title label. Then a `border` divider, and beneath it the camera roll as a full-width row: a 19pt glyph in a 44×44 block at media-inset radius, card title over metadata subtitle, `inkFaint` chevron, top-aligned so a four-line subtitle at the accessibility sizes does not leave the glyph beside the middle of a sentence.

**The divider is the point.** The four above it are verbs; the camera roll is a browse action, and a fifth tile would make it look like a fifth way to capture something. It costs a tap on the way to every entry, which is the price of the camera roll having a home.

**The camera-roll row is present in every authorization state.** Gating it on having something to offer sealed the feature behind its own door: clusters need a scan, a scan needs authorization, and authorization is only ever asked for by the explainer behind this row. Only the subtitle changes — and a count is stated only when it is a complete one, so limited access says whose photos it counted in the same breath as the number.

The sheet is sized to its measured content, seeded at 380, with `.large` kept in the detent set for the accessibility sizes. `.medium` is half the screen whatever the content is, and this content opened it on a gulf of empty cream. `.presentationSizing(.fitted)` is not the answer — a `ScrollView` has no intrinsic height, so `.fitted` sizes it to the proposal.

* * *
### MomentsScreen
This day, in the years before it. **Two shapes, one layout.** A hit is years-ago groups, nearest year first; a miss is the server's `fallback: "random"` — real memories under **From the archive**. The redirect wears the same rail, the same section header and the same cards as a hit: the archive is days old, so the redirect is the screen a parent sees most days, and a miss that looked like a miss would read as a fault every time.

Name in display over a body subtitle in `inkMuted`, on canvas, nav bar hidden. Moments has no sticky header, so its name is display and not `screenTitle`.

A horizontal rail of `ThrowbackCard`s at 12 sits above the sections: one card per section on a hit, one card per **memory** on the redirect, which has only ever one section and would otherwise leave a single card beside a screen of five.

Section header: the year phrase at day-number weight in `inkMuted`, the day it happened in body, the age as a periwinkle emphasis chip at the trailing edge — stated once per group, where v3 put it. **The redirect gets neither date nor age**: five memories from five days and five ages, and one number over all of them is wrong four times. Its one italic quote line in `inkMuted` is the only thing that distinguishes it. Closing line in metadata `inkFaint`.

Empty state: a 66pt wash circle with a 26pt terracotta glyph, a title line, one body line capped at 290, and one primary button capped at 240 into the composer — an invitation, not a report.

**A failed load is never rendered as an empty archive.** Both leave the sections empty; only one of them means the parent has nothing to look back on. The failure is a quiet notice — `surface` at media-inset radius with an `inkMuted` info glyph — and pull to refresh retries.
### ThrowbackCard
The Moments rail card. 232×148, card radius, the standard shadow.

**Two treatments, chosen by whether the section has a picture — never by whether the picture has arrived.** Deciding on arrival flips the caption from ink to cream mid-scroll, which reads as a rendering bug rather than a load.

With a cover: `terracottaDeep` painted first, the image over it, then a three-stop ink scrim — 0 at 28%, 0.18 at 54%, 0.62 at the bottom — so the eyebrow stays legible over a bright frame without greying the picture. Caption in `canvas` over `canvas` at 86%, hairline `ink` at 8%.

Without: the gradient wash, caption in `ink` over `inkMuted`, hairline `sealedBorder`. **No grey box and no broken-image glyph** — `thumb_key` is null until thumbnails leave P0, so this is the common case for a long time, and a throwback to a written or did-it entry is an invitation, not a picture that failed.

Caption is card title over metadata, spacing 3, padding 14, subtitle two lines.

A kind badge — label role in the kind's colour on a capsule, `canvas` at 92% over a cover and `surface` on the wash, padded 10/4 and inset 11 from the top leading corner — names what the cover cannot: shown whenever there is no cover, and over a cover only for video, where a still frame does not say the thing moves. A sealed letter always badges **Letter** in terracotta, cover or not — the cover belongs to the section, not to the sealed entry, whose own tiles are withheld.
### Backfill photo grid
**The app's second grid, and deliberately not the mosaic.** The mosaic is one entry's pictures composed into a block — four shapes, 4pt gutters, one 14pt clip around the whole thing. This is a picker over a camera roll: three columns, 3pt gutters both ways, square tiles at radius 2, screen-margin sides. Tight gutters and square corners are what make a month scan as a contact sheet; mosaic rounding at this density reads as forty separate cards.

The tile side is arithmetic — `BackfillGrid.tileSide`, `(width − 32 − 6) / 3` floored to a whole point — and the columns are `.fixed(side)` rather than `.flexible()`, so one number decides the frame, the clip and the pixel size asked of PhotoKit. Grid thumbnails are requested at `side × displayScale` **pixels** with `deliveryMode = .fastFormat`, `resizeMode = .exact`, `isSynchronous = false` and `isNetworkAccessAllowed = false`: one callback at the size asked for, rather than a degraded frame followed by a second decode. Tiles are identified by `PHAsset.localIdentifier`, never by index — an index-keyed tile recycles its state into a different photograph when the day's contents shift.

**Every selectable tile carries its mark before it is picked** — a 26pt circle in the top trailing corner, inset 6. Unselected it is `surface` at 70% under a 1pt `border` hairline and holds no glyph; selected it fills `terracotta` with a `canvas` checkmark at 13pt semibold, and the tile itself takes a 2pt `terracotta` inner stroke. A cloud-only tile gets **no circle at all**: it is not tappable, and an affordance offering to select it would be a control that lies. **The whole tile is the tap target**, never the circle — one-handed use is the constraint, and a 26pt target inside a ~118pt tile is the wrong hit area.

Drawing the ring only after the first tap is what this replaced (24pt, bottom trailing, selected-only, with a 0.9 shrink). A grid whose entire purpose is selection, showing no affordance until something is already selected, makes the parent's first tap a guess. The tile keeps radius 2 in both states — the inner stroke carries selection, and a radius change on top of a stroke and a circle is three marks for one fact. Motion is the card tap (0.98, 0.12s) on the tile and the completion spring (`response: 0.35, damping: 0.7`) on the circle, which still fills under Reduce Motion without the overshoot. **No haptic** — haptics are reserved for completion, and picking a photo completes nothing.

**No count on a tile and no running total over the grid** — the number lives in the pinned action, "Use 3 photos", where it states what the next tap does rather than keeping a score.

Day headers are sticky and opaque canvas at `.zIndex(1)`, and the grid scrolls under them. They take `DayHeader`'s vocabulary — bold day number, lighter month, count in `inkMuted` — and **not** its periwinkle age capsule: this is a picker, and the age belongs to the timeline the entry lands in.

**A tile occupies its cell exactly, whatever shape the photograph is.** `.scaledToFill()` under a `.clipShape` with no frame between them clips to the *view's own bounds* rather than to the space proposed, so a portrait asset grows, clips itself to the larger square and draws over its neighbours — and a `LazyVGrid` row is as tall as its tallest child, so one overflowing tile also pushes its row into the next and paints across the pinned header above it. Three symptoms, one defect. State the frame and let a `Color.clear` take the proposal.

The pinned action sits on `PinnedActionBackdrop` with 26 above it, like every other pinned action in the app. `safeAreaInset` already insets the scroll content by the pill's own height, so the grid adds only the 16 of clearance under the last row — a second hardcoded inset on top of it is a dead gap that changes length the moment a photo is picked.

A cloud-only asset is `chipPlain` with an `icloud` glyph and is not selectable. The scan counted it, so hiding it makes the count wrong, and fetching it breaks the promise that nothing downloads.

**A selection belongs to exactly one day.** A tap on a second day is held, not acted on: the rule is stated above that day's grid — metadata on `terracottaSoft` at media-inset radius, with a "Start here" that clears the selection — rather than warned about before anyone has done anything, and rather than silently discarding what is picked. One day is what makes the resolved `occurred_at` exact rather than merely defensible.

The month strip prints an overflow count the way the mosaic does, on the fourth tile, over a 42% ink wash. The share preview row is the one surface that gives the count **its own** 84pt tile — that row scrolls horizontally and is a manifest of what is about to be filed, so it has no card height to protect.

* * *
## Motion
| Interaction | Spec |
| --- | --- |
| Card tap | scale 0.98, 0.12s |
| Completion | spring, response 0.35, damping 0.7 |
| Sheet | standard iOS presentation |
| Card → done | 0.4s easeInOut, applied to the list and keyed to its row ids |
| List insert | the list's own. A per-row `.transition` on a `List` row is ignored, so none is set |

Gentle and responsive. Nothing theatrical.

**Reduce Motion is honoured per interaction, not by one switch.** The completion check still fills, at the same 0.35s and without the overshoot, because the parent still needs to know the tap landed. The card-tap scale is dropped outright, because a press already has a target and the scale was only ever flourish.

* * *
## Layout rules
- Primary actions live in the bottom third — one-thumb reachable. This governs the affordances a thumb uses repeatedly, not a form's commit: a sheet's Cancel and Save are navigation-bar actions, leading and trailing, Save terracotta while it can be pressed and `inkMuted` when it cannot.
  
- A full-screen decision pins its action in a bottom `safeAreaInset`, **never behind a** `Spacer`. A spacer only pushes while there is room to push: at the accessibility text sizes the stack overflows its frame and drives the action off the bottom and the headline off the top.
  
- A pinned action bar sits on `PinnedActionBackdrop` — the ground colour fading in from transparent — with **26pt above it**, which is the height the fade needs to fade in. At 12 the gradient has no room to work in and body text collides with the button's top edge.
  
- Screen margin 16pt. **Onboarding is 28**, and a step's content starts 72 from the top, clear of the rail: 16 is tuned for lists of cards, and a screen holding one sentence and one button reads at 16 as though the headline is falling off the edge.
  
- Scrolling screens clear the floating bar with `.safeAreaPadding(.bottom, measuredBarHeight + 4)`, applied once above all five tabs rather than per screen. The bar measures itself with `.onGeometryChange` and reports its height; a hardcoded inset is right for exactly one text size and one disc geometry, and the failure looks like "Retry now" trapped underneath.
  
- A card in a list is a `Button`, never a `NavigationLink` — a link draws a disclosure chevron on every row, and a chevron on a card is furniture this design does not have.
  
- Cards in a `List` carry half the card gap as row inset top and bottom, hide the separator, and set the row background to canvas. A visible separator or a system row background undoes the cream.
  
- Photos sit inset with padding and rounded corners; they rarely bleed to the screen edge.
  
- **The one screen where they do bleed is Entry Detail — settled Aug 11, 2026, phase 22.** Media runs edge to edge there, under an ink scrim, with the reading sheet resting on top of it. It is the "rarely" in the line above rather than an exception to it: Entry Detail is the single screen whose whole job is looking at one artifact. **This is scoped to that screen and is not a licence anywhere else** — `docs/decisions.md` still lists _"full-bleed edge-to-edge photo timeline as the primary view"_ under **Rejected — do not revisit**, and the timeline is still a date-grouped card list with thumbnails. If you are reading this while about to bleed a photo on any other screen, the answer is no.
  
- Section headers are small-caps labels in inkMuted, not big display type.
  

* * *
## Accessibility
**A card is one element, not a pile of labels.** Every card and every row collapses with `.accessibilityElement(children: .combine)` and carries a hand-written `.accessibilityLabel` — the clauses joined with ". ", in the order the card reads — plus an `.accessibilityHint` naming the action and an explicit trait. Left to itself SwiftUI makes every `Text` and every glyph its own stop: five swipes for a card a parent takes in at a glance.

The label carries the **rendered** prompt, never the stored one. A VoiceOver user hearing `{their}` is the pronoun bug arriving through the one door nobody screenshots.

Decoration is hidden. A glyph that repeats the text beside it, an illustration, the completion check — all `.accessibilityHidden(true)`. The check is feedback; the label already says "Done".

The exception is a view with more than one tap target: it stays several elements under `children: .contain`, because collapsing it hides the links. A sighted parent who can open the question directly and a VoiceOver user who can only open the app is the wrong trade.

Ages and durations get a spoken form — `AgeText.spoken`, `DurationText.spoken`. "5y 2m" read aloud is noise.

There are no accessibility identifiers. The label is the only handle, in the app and in the tests.

* * *
## Copy rules
- Never scold. "4 waiting" is a count, not an accusation. There is no wording anywhere that implies a missed day was a failure.
  
- No urgency states. Expiry is stated plainly and quietly; nothing turns red.
  
- **There is no destructive colour.** Sign out is `ink` on a `surface` capsule with a `border` hairline; a destructive row is `terracotta` like any other action. Weight comes from placement, not colour: an irreversible action gets its own card at the bottom with whitespace above it. The only red anywhere is what iOS paints for `role: .destructive` in a system confirmation dialog, and we never draw it ourselves.
  
- Errors say what happened and what to do, in the interface's voice. They never apologise and they are never vague.
  
- An entry saved locally but not yet synced is never presented as an error or a loss. **A save that only failed to reach the network says nothing at all** — the entry is in the local store before the request goes out, so an unreachable server dismisses the composer exactly as a success does and the sync sweep re-sends it. Work in progress is tinted, not flagged: a `terracottaSoft` wash and a 7pt terracotta dot say _live_. No badge.
  
- **Waiting and stalled are two different sentences.** A file still on its way finishes on its own and may be counted down; a file past the retry cap is terminal until something asks again. Folding them together makes a card most reassuring at the moment it should not be.
  
- **A count of zero is an absent row, not a row reading "0".** A section with nothing to report is not rendered — a row that permanently reads "0 waiting" is furniture.
  
- An action says what it achieved, in one sentence derived from the counts on either side of it. A primary action that disables, re-enables and reports nothing teaches the parent that the screen is decorative.
  
- No alerts in a composing surface. The composer's only voice is one metadata-sized `inkMuted` line under the form, and it is spent on the two outcomes worth a sentence — an assignment that expired and a seal the archive kept — plus a file that could not be read.
  

* * *
## Widget
The widget renders dark, and it is the only thing in the product that does — a widget has no `preferredColorScheme`, and a cream card on a dark Home Screen is a bright rectangle in someone's evening. This is a scoped exception, not a reversal: **dark mode is not open for the app.**

Its nine tokens live in `WidgetPalette` and are read from `\.palette` in the environment, so no widget view resolves the appearance itself and none can render half in one palette and half in the other. Light is the app's own tokens unchanged, with `done` mapped to `sageInk` — sage is a fill and needs an ink at this size.

Dark is the same palette in another light rather than an inversion: warm charcoal ground (canvas `#1F1C1A`, surface `#2A2624`, border `#3B3532`), warm off-white ink (`#F3ECE2`, muted `#B2A89D`, faint `#807771`), and the two hues lifted until they carry — mission `#E28B5B`, question `#9AA6F0`, done `#8FB894`, roughly 5:1 and 6:1 on surface. Never pure black and never pure white survives the translation, and so does colour carrying meaning.

Lock Screen accessory families are rendered as a mask and get no colour at all. Kind is carried by its SF Symbol there — the same vocabulary the `PromptCard` glyph tile uses — with `.widgetAccentable()` marking the symbol as the accented group.

Prompt bodies are rendered for the child **app-side, before the snapshot is written**. The extension has no `PromptTokens` and no environment to read a subject from.
## Extension targets
There is no design-system package and there will not be one. A target outside the app gets tokens by **compiling the same files**, never by copying values.

`RascalShare` builds `Palette`, `Typography`, `Layout`, `Motion` and `Formatting` into itself, so the share sheet has the real palette and type scale, `SectionLabel`, `Chip` and `PrimaryButtonStyle`, and redefines nothing. What it cannot reach is anything that would drag SwiftData, the API client or the seal control in with it. Where it needs one of those, it borrows the vocabulary and rebuilds the control.

`RascalWidget` builds `Palette` and `Typography` only — no `Layout`, no `Motion`, no `Formatting` — so `cardSurface`, `Chip`, `KindBadge`, `CompletionCheck` and `AgeText` cannot be called from a widget view and a duplicate is the only option. **Pin every duplicate to its original with a test**, the way `WidgetSnapshot.Item.symbolName` is pinned to `PromptKind.symbol`.

**A new target adds the file it needs to its Sources phase.** Re-declaring a token that already has a name is the duplication this rule exists to prevent.
## The catalog
`DesignSystem/DesignSystemCatalog.swift` draws the tokens on one screen — swatches, the type ramp, the card fills, chips and badges, the check and the capsule button, the gradient — with an Accessibility XXL preview beside the default one. Preview-only, and not reachable from the app. Open it in the canvas before arguing about a value.

It currently covers 11 of the 22 colour tokens and 7 of the 11 type roles, so it proves drift rather than the absence of it. Anything added here belongs there too.

* * *
## Anti-patterns
Rejected twice already — don't drift back:

- Risograph, halftone, misregistration, screen-print texture
  
- Condensed or rotated display type, headlines breaking the grid
  
- Full-bleed edge-to-edge photo cards as the primary timeline
  
- Passport stamps, receipt-spike stacks, rotated cards — a card holds content, and content is never set on an angle. A drifted stack of empty rectangles standing in for photographs is an illustration, not a card: it shows nothing, it is `accessibilityHidden`, and it is the one place the angle is allowed.
  
- High-saturation electric accents
  
- Streak counters, guilt copy, red urgency states
