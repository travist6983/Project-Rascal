# Phase 110 — the approved design, and what conforming to it costs

**Status:** open. **Lane:** B (iOS). **Branch:** `ios/phase-110-design-conformance`.
**Companion phase:** 108 (`ios/phase-108-locked-today-membership`) builds the surfaces; this
phase holds the approved visual and audits 108 against it.

**The approved design is now in this repository** at
`docs/App-Views/mobile-app-design-tiers-lock-cta/`, committed by this phase. Primary file:

```
project/RASCAL Free Tier - Locked, Membership, Trial.dc.html    1097 lines, 12 artboards
project/support.js · project/styles.css · project/guidelines/*.html
```

**Why that matters more than it reads.** Both phase prompts carry the same instruction — *"If
that block is empty, stop and say so. Do not proceed from the written description alone — the
whole point of this phase is that a human approved a visual, and building from prose would make
that approval meaningless."* **108's block was empty.** Not through anyone's fault: the bundle
arrived as untracked files in the primary working tree, and git worktrees do not share untracked
files, so the session building the screens could not see the screens. It is committed here so that
stops being true.

---

## 1 · Precedence, and where it actually bit

The order both prompts specify, highest first:

1. **App Review requirements** — §7. Two of them are absent from the approved design.
2. **The behavioural rules in the prompt** — not dismissible, no badge, one button.
3. **`free-tier-copy.md`, verbatim** — §6. The real file was recovered mid-phase; it exists in
   neither repository.
4. **The approved design**, for anything visual.
5. **`design-system.md` defaults**, for anything the design does not specify.

**Three of the five collided in this phase**, and in every case the lower rule was the one that
looked most obviously right on screen.

---

## 2 · The two owner overrides

**Both go against the design's own stated recommendation.** Recorded here rather than only in a PR
description because a reader six months from now will otherwise open the design file, find it
recommending the opposite of what shipped, and assume the build drifted.

### 2.1 · The locked card treatment: the design picked A, the owner picked C

Artboard **`1d`** renders four treatments at card width on cream and annotates a pick:

> **MY PICK: A** — No shadow. At 4% over cream the shadow is not a legible difference at rest —
> but the locked card sits directly under a live one that has it, and the only way a parent ever
> perceives a 4% shadow is as a *difference* between two adjacent cards. Dropping it is the
> quietest available signal and costs nothing.

> **AGAINST C** — `terracottaSoft` at any opacity is the fill a *live* mission wears. Washing it
> makes the locked card look like a live mission rendering badly, which is the failure mode you
> named.

**The owner chose C**, verbatim:

> "The four treatments you asked to see, on cream at card width from the desing I like this one
> the best C · terracottaSoft @45% + border · resting shadow"

**C ships. The design recommended A.** Neither PR says *"per the design"* for this card.

**The AGAINST-C objection is answered, partly.** It assumes C is `terracottaSoft`. It is
`terracottaSoft` **at 45% over canvas**, which resolves to `#FCF4EC` — measurably lighter and
pinker than a live mission's flat `#FBEDE2`, so the two are distinguishable when adjacent. What the
objection still has right is that they are *neighbours on the same axis*: a parent is being asked
to read a hue difference, not a structural one. **The mitigation is that the locked card carries no
action button and its body is `inkMuted` where a live card's is `ink`** — two structural
differences that survive at any tint.

**Implementation note, and it is the way C goes wrong in code while looking right in a mockup:**
do not write `.terracottaSoft.opacity(0.45)` over an unstated parent. If the parent is not canvas
the composite shifts. Phase 108 composites explicitly:

```swift
.background(Color.terracottaSoft.opacity(0.45), in: shape)
.background(Color.canvas, in: shape)          // the ground, stated rather than assumed
```

Two layers, so the wash is always over canvas whatever the parent is. **Preferred over hardcoding
`#FCF4EC`**, which would silently drift if `terracottaSoft` were retuned — and a hex literal in a
view is forbidden anyway.

### 2.2 · Locked slots are always shown as cards; `1f` is rejected

Artboard **`1f`** offers the alternative both prompts explicitly permitted — *"including a single
quiet line under the question instead of a card"* — as one row reading `Included with membership`
with a `See what's included` link. Artboard **`1e`** argues for it:

> **IT SURVIVES — AND THAT'S THE PROBLEM** — Nothing clips, nothing truncates. But the locked card
> is now ~270pt tall, and at AX1 a free parent's whole first screen is one question and one thing
> they don't have. At AX3 the pair alone is taller than the viewport. *This is the strongest
> argument for 1f.*

**The owner rejected it**, verbatim: *"I dont like this idea at all … we want to show the locked
missions always."*

**One card per locked slot, every day, weekday and weekend.** This matches `free-tier-copy.md` §1
independently: *"One card per locked slot — one on a weekday, two on a weekend. Never a single
summary card counting them."*

**The cost the owner is accepting, stated plainly because `1e` is right that it is real:** Lane A
confirms the worst case is **four locked rows** — a Saturday that is also the 15th yields
`mission, mission_b, weekly, letter` against a single live question. No artboard draws that state.
At AX1 that is roughly four × 270pt of withheld content under one offered card. **It is the state
most likely to look bad and least likely to be looked at**, and it must have a preview.

---

## 3 · Artboard inventory

| # | Label | What it fixes | Status |
|---|---|---|---|
| `1a` | Weekday free | One live question + one locked photo mission. Board order, zone gaps. | Build |
| `1b` | Weekend free | One live + **two** locked (`mission`, `mission_b`). | Build |
| `1c` | Weekend member | Three live, zero locked — the entitled board. | Build |
| `1d` | Locked card treatments | Four treatments A–D. **C chosen by owner; A recommended.** | §2.1 |
| `1e` | AX1 | The largest step the card survives. Scaling table. | Build |
| `1f` | Quiet row weekend | The alternative. **Rejected by owner.** | **Do not build** |
| `2a` | Sheet, annual selected | Default state. Annual preselected. | Build |
| `2b` | Sheet, monthly selected | Selection moves; nothing else changes. | Build |
| `2c` | Sheet, StoreKit unavailable | Price rows → one `Notice`; **primary absent, not disabled**. | Build |
| `2d` | Sheet scrolled, 375×667 | Below-the-fold behaviour; pinned action never moves. | Build |
| `3a` | Trial welcome | Once, after first sign-in, before first Today. | Build |
| `3b` | Post-trial notice | One `Notice` at top of board, once. | Build |

**`1a` and `1b` draw the locked card in treatment A** (surface fill, no shadow), because they were
drawn before the owner's pick. **Where `1a`/`1b` and `1d`-C disagree on the locked card's fill and
shadow, `1d`-C wins.** Everything else in `1a`/`1b` — geometry, order, type, the eyebrow, the
footer rule — is authoritative.

---

## 4 · The locked card, as specified

**Structure is three zones, not two.** Neither prompt mentions the eyebrow; the design has one.

| Property | Value | Token |
|---|---|---|
| Fill | `terracottaSoft` @ 45% over canvas → `#FCF4EC` | `.terracottaSoft` + `.canvas` |
| Border | 1px hairline | `.border` |
| Radius | 20 | `Layout.cardRadius` |
| Padding | 16 | `Layout.cardPadding` |
| Zone gap | 14 | — |
| Card-to-card gap | 12 | `Layout.cardSpacing` |
| Shadow | y 2, blur 8, opacity 0.04 | `Layout.Shadow` |
| Glyph tile | 34pt, radius 11, `tint` @ 12% wash, glyph in `tint` | matches `WaitingCard` at 30/10 |
| Eyebrow | `label` 12 / +0.6 tracking, **uppercased by the role** | `.typeRole(.label)`, `.inkMuted` |
| Body | prompt-body 20/1.3 rounded | `.inkMuted` — **not `.ink`** |
| Footer | rule in `border`, `padding-top` 12, metadata 13 | `.inkMuted` |

**Shadow, and the defect the prompt predicts.** `Layout.Shadow` is `y: 2, blur: 8, opacity: 0.04`
and the codebase already divides: `radius: Layout.Shadow.blur / 2`. **SwiftUI's shadow radius is
roughly half a designer's blur.** A card built from `8` sits at twice the softness of every card
beside it and looks correct in isolation. Read it off `Layout.Shadow`, never hand-number it.

**The card is a button, so it fills before it pads.** `cardSurface` pads *then* fills, which leaves
a 16pt ring of card outside the tap target. `SettingsCard` is the existing correct pattern —
clipping to `cardRadius` rather than backgrounding it. **The locked card takes that path** or a
parent tapping near its edge gets nothing.

**No footer glyph.** Treatment **D** is *"A, with the footer glyph you asked for"* and is rejected:
*"The kind glyph is already on the card, in the tile, 34pt. A second mark 13pt below it says
nothing the first one didn't… It also reads as the ring of a disabled control."*

**Tint by `kind_hint`, words by `slot`.** These are different keys and it matters:

| slot | kind_hint | eyebrow | tint |
|---|---|---|---|
| `mission` | `photo` | `TODAY'S PHOTO MISSION` | terracotta |
| `mission_b` | `mission` | `TODAY'S SECOND MISSION` | terracotta |
| `weekly` | `weekly` | `THIS WEEK'S MISSION` | terracotta |
| `monthly` | `monthly` | `THIS MONTH'S MEASUREMENT` | terracotta |
| `letter` | `letter` | `A LETTER TO {THEM}` | periwinkle |

`kind_hint` *is* 1:1 with `slot` today, so either would distinguish them — but the copy file is
organised by slot, and a future server could add a slot reusing an existing hint. **Key words on
`slot`; key tint and glyph on `kind_hint`.** An unrecognised `kind_hint` renders neutral per
`design-system.md:291` — `surface` fill, `border` hairline, `inkMuted` tile, **no guessed tint** —
already centralised in `AssignmentPresentation.swift`.

**Casing: do not write the eyebrow uppercase in Swift.** `.typeRole(.label)` is already tracked
**and uppercased**; `.textCase(.uppercase)` on top is redundant and is a defect, not a no-op. The
copy file renders eyebrows in caps because that is how they appear, not how they are stored. Write
`Today's photo mission`; the role does the rest. This matters doubly for `A letter to {them}` — the
token key is lowercase and must survive substitution before the role uppercases the result.

**Behaviour, which no artboard can express:** the whole surface is one button opening the
membership sheet; no chevron; **not dismissible**; **no badge, no red dot, no count**. VoiceOver
reads it as one element — eyebrow, body, then `Included with membership` — with the button trait
and **an accessibility label that does not contain the word "locked"**. The trait carries the
affordance; the word imports the register `free-tier-copy.md` §4 forbids.

---

## 5 · The membership sheet

**`PaywallSheet.swift` already is this sheet.** Phase 37b (PR #154) shipped title, subtitle,
covered lines, plan selector with annual preselected, primary, secondary, restore and legal links.
**This phase restyles and extends one screen; it does not build a second.** 108 adds a third
`Context` case rather than replacing it.

| Property | Value |
|---|---|
| Ground | `canvas`; top corners 28; scrim `ink` @ 40% |
| Title | detail-title 26 rounded, `ink` |
| Subtitle | body 16, `inkMuted` |
| Block stack gap | 22 (grouped-screen rule) |
| SectionLabel → content | 9–12 |
| **What stays free** block | `surface`, `border`, radius **14** (`mediaInsetRadius`), padding 16 |
| Plan rows | radius **18** (`heroRadius`), 14/16 padding |
| — selected | `terracottaSoft` + **1.5px** `terracotta` |
| — unselected | `surface` + 1px `border` |
| — **no check mark, no radio** | selection is fill + border only |
| Caption chip | `terracottaDeep` on terracotta @12% |
| Actions | pinned on `PinnedActionBackdrop`, 26 above |
| Primary | `PrimaryButtonStyle` 20/16, **full width** |
| Secondary | `OnboardingSecondaryButton` — underlined `inkMuted` at 17, the primary's own label size |
| Detent | sized to measured content, seeded ~700, `.large` kept in the set for accessibility sizes (the `AddToArchiveSheet` rule). **Not `.medium`.** |

**The "what stays free" block is the substantive addition and must not compress into a footnote.**
The design is explicit about why it is `body` 16 / `inkMuted` rather than metadata: *"the Field
vocabulary, so it reads as a stated fact rather than a footnote."* It is the reason this sheet is
not a paywall.

**Selection with no radio needs an accessibility trait.** The design conveys selection purely
through fill and border, which is invisible to VoiceOver, so the selected row needs
`.accessibilityAddTraits(.isSelected)` — otherwise the sheet announces two near-identical buttons.
**This is a gap the mockup cannot show**, not a deviation from it.

**Products unavailable (`2c`):** price rows are replaced by **one** `Notice` row; the **primary
action is hidden, not disabled** — a disabled button is a thing to keep tapping — and there is no
spinner without a terminal state.

**A completed purchase does not set local entitlement.** It refreshes from the server and renders
what the server says. The webhook is the writer. This is D5, and it is already how 37b behaves.

---

## 6 · Copy — the real file, and what disagrees with it

**`docs/design/free-tier-copy.md` does not exist in this repository.** Both iOS prompts name it as
the verbatim, highest-precedence source for every user-visible string. Phase 108 wrote a stand-in
from scratch and marked every string unreviewed. **The real file was recovered mid-phase from the
marketing lane's prompt**, which carries it in full, and 108 has replaced its stand-in with it.

**Provenance caveat, which should stay attached until the file lands in a repository:** what we
have is a *transcription* of a file that reached another agent inside a prompt. It cannot be proved
lossless. **The design bundle is the corroborating witness** — it and the marketing prompt are two
independent copies of the same original, and they agree on every string checked.

### 6.1 · Rules the file adds that neither prompt carried

1. **No guilt, no urgency, no counting.** *"A locked card that accumulates a number is a streak
   wearing a padlock."*
2. **Never "unlock", "upgrade", "premium", "pro".** The word is **membership**; a person **joins**.
3. **The archive is never the thing being sold.**
4. **The lock states inclusion, not deprivation** — *"Included with membership"*.
5. **Show the shape, never blur the content.** No frosted glass, no teased prompt text.
6. **The free tier is described positively and first.**

### 6.2 · §4, the banned list — and the part a grep cannot catch

`Unlock` · `Upgrade` · `Premium` · `Pro` · `Free trial ending` · `Don't lose` · `You've missed` ·
`Limited time` · `Only X left` · `Your archive will be` · `Members only` · `Locked` **as a
user-visible label** (the visual state may still be called locked in code — which is what keeps
`LockedPromptCard` and `LockedSlot` legitimate names) · **any streak, any count of skipped items,
any percentage complete.**

**That trailing clause is a rule about shapes, not strings.** No grep finds it; a conformance pass
has to look for it. It fails if the locked board renders anything of the form "2 missions today", a
filled fraction, or a count chip on a locked section header — **and no banned string appears
anywhere near such a violation.** Note the design's `Waiting` header *does* carry a count chip; that
is pre-existing, counts waiting items rather than withheld ones, and is out of scope — but it is the
exact shape that must not be copied onto the locked group.

### 6.3 · Differences found

| # | String | Source A | Source B | Resolution |
|---|---|---|---|---|
| 1 | Secondary action on the sheet | 37b ships `Not just now` | copy file **and** design say `Not now` | **`Not now`** — precedence 3 beats shipped code |
| 2 | Sheet footnote colour | design: `inkFaint` | copy file: unspecified | **`inkMuted`** — §8, `inkFaint` measures 2.13:1 |
| 3 | Locked-card body | design draws a prompt body | API sends `{slot, kind_hint}` only, frozen | **Static copy keyed on `slot`**, from copy file §1 |
| 4 | Prices | design draws `$59.99` / `$5.99` | copy file uses `{{PRICE_YEAR}}`/`{{PRICE_MONTH}}` | **Neither reaches Swift** — §7.3 |
| 5 | Eyebrows for `weekly`/`monthly`/`letter` | no artboard draws them | copy file §1 specifies all three | **Copy file** — approved, not authored |

**Only one string in this phase is genuinely authored:** the fallback body for a `kind_hint` newer
than the build, which no source could have. It goes in *Proposed additions*.

### 6.4 · The gendered copy, and how it is resolved without anyone authoring

The copy file is written for a boy throughout — seven strings across §1 and §2: *"A picture of
him"*, *"His voice"*, *"How much of him has changed"*, *"A LETTER TO HIM"*, *"Sealed until he's old
enough"*, *"letters you seal until he's old enough"*, *"His other parent, on the same archive"*.

`CLAUDE.md` is explicit: *"Never write copy that assumes a child's gender — client-side strings are
neutral too and stay that way."* The copy file equally forbids agents rewriting it.

**The resolution is one set of tokenised strings rendered against two different subjects** — not two
sets of copy:

- **The locked card** renders against the child on the board. For a `he/him` child this reproduces
  the owner's sentence exactly.
- **The membership sheet** renders against `PromptSubject.unknown`, which is they/them by
  construction, because the sheet is **per-household**: reached from Settings and from the
  guardian-invite surface, and its own footnote says *"every child, both parents."* In a household
  with a son and a daughter there is **no correct pronoun** for *"His other parent"*, and no
  tokeniser can invent one.

**One string, two subjects, no second copy.** This uses `PromptTokens.render(_:for:)`, an existing
client-side function that `PromptCard`, `WaitingCard`, `DoneCard` and `ComposerView` already call at
display time — not a new path.

**Two strings lose a contraction and that must be declared, not absorbed.** The token table has no
contracted form, so *"until he's old enough"* becomes `until {they_are} old enough` → *"until he is
old enough"*. That is a change to the owner's words — mechanical, but real.

**Verified rather than assumed:** the table (`PromptTokens.swift:135–150`) carries capitalised
`{They}` / `{Them}` / `{Their}`, so *"His other parent"* → `{Their} other parent` renders correctly
at sentence start; capitalisation is explicit and never positional. `children.pronouns` exists,
onboarding **does** collect it (`ChildSetupFlow.swift:49`, `PronounsStep`), and both `AddChildSheet`
and `EditChildSheet` carry pickers. **`docs/blocked.md:170` is stale** where it says *"Onboarding
does not ask for pronouns"*. An unanswered pronoun renders the they/them column, so a parent who
skipped the step gets grammatical English and never a visible `{token}`.

**Still open for the owner**, and neither agent may decide it: on the sheet, *"Their other parent, on
the same archive"* is grammatical but stilted beside the owner's *"His other parent."* A sentence
written for the household — *"The other parent, on the same archive"* — reads better and is a **copy
decision**, not an implementation one.

---

## 7 · App Review — where precedence 1 overrides the approved design

Five things are App Review requirements under Schedule 2 §3.8(b), which guideline 3.1.2(c) points
at. **A restyle that drops one is a rejection.**

| # | Requirement | In the design? | Resolution |
|---|---|---|---|
| 1 | Plan **title**, from the product's display name | **No** — plan rows show only `$59.99 a year` | **Keep 37b's rendering.** §7.1 |
| 2 | Length as text — "a year", "a month" | Yes | From `subscriptionPeriod` |
| 3 | Price | Yes | From `displayPrice` |
| 4 | Trial terms, when an offer exists and the customer is eligible | Not drawn | Correct — §7.2 |
| 5 | **Restore control**, on the paywall and in Settings | **No** — absent from `2a`–`2d` | **Keep 37b's.** §7.1 |

### 7.1 · Two omissions, and why they are reported rather than obeyed

**Neither the restore control nor the Terms/Privacy links appear on any sheet artboard.** The
footer of `2a`, `2b` and `2d` is `Become a member` + `Not now`, and nothing else; `2c` is `Not now`
alone.

The prompt says that where the approved design has no room for one of the five, *"stop and report
rather than choosing."* **Precedence 1 settles it — these "are not stylistic and cannot be designed
away"** — so the resolution is not a choice between design and requirement:

- **The controls stay**, exactly as phase 37b shipped them (`PaywallSheet.swift:325–335` for
  restore).
- **The omission is reported**, here and in the PR, rather than treated as a deletion the design
  authorised.

**The most likely explanation is benign** — the artboards draw the sheet's *content*, and 37b's
restore and legal row sit below the pinned action where a mockup naturally stops. But a restyle
that read the design literally would have deleted a rejection-triggering control, which is exactly
the failure the precedence list exists to prevent.

**On requirement 1**, the design's plan row is `$59.99 a year` — price and period, no product
title. 37b renders from `OfferedPlan`, which copies the display name off `Product` at the boundary.
**Do not restyle the plan row into the mockup's shape without checking the display name survives.**

### 7.2 · The no-introductory-offer path is the normal path

**No introductory offer will exist in production.** The trial is server-granted
(`entitlements.trial_ends_at`, phase 107) and a parent reaches this sheet only *after* their
fortnight has ended — so `isEligibleForIntroOffer` is false and the trial row does not render.
**That is the normal path, not an edge case**, and it needs a preview of its own.

### 7.3 · No currency literal reaches Swift

The design draws `$59.99` and `$5.99`; the copy file uses `{{PRICE_YEAR}}` / `{{PRICE_MONTH}}`.
**Both are for copy review and the marketing site.** iOS takes price from `displayPrice` and period
from `subscriptionPeriod`. **A currency literal in a rendered iOS string is a defect** — and 37b's
existing architecture already prevents it: `OfferedPlan` copies price, period and trial off the
`Product` at the boundary, and nothing above that layer imports StoreKit.

### 7.4 · 🚨 Launch blocker — the legal links do not render, today

**`TERMS_URL` and `PRIVACY_URL` currently expand to the empty string.** `LegalLinks.terms` and
`LegalLinks.privacy` both return `nil` at the `!trimmed.isEmpty` guard, and **both links render as
absent right now.**

**The host check is correct and must not be relaxed** — the app refuses to render a link whose URL
has no host, which is the right behaviour. The problem is upstream: the values are never supplied.
The example values *would* have a host (`getvellumapp.com`) once copied across.

`SubscriptionTests.swift:938–946` documents this hole and **states that the test cannot detect it**
— so nothing in CI will fail while the links are missing.

**Phase 109 is creating those pages.** The app expects, once set:

```
TERMS_URL   = https://getvellumapp.com/terms
PRIVACY_URL = https://getvellumapp.com/privacy
```

**This is a launch blocker, not a phase-110 fix.** Setting the build variables is a signing/config
change and is out of scope for both iOS phases.

---

## 8 · Contrast — measured, not quoted

Computed with the WCAG 2.1 relative-luminance formula against the resolved composites. **AA normal
is 4.5:1; AA large (≥18pt, or ≥14pt bold) is 3.0:1.**

| Pair | Ratio | AA normal | AA large | Verdict |
|---|---:|:---:|:---:|---|
| `surface` on `terracotta` — the primary button, 17pt semibold | **4.36** | ✗ | ✓ | Design flags it; §8.1 |
| `surface` on `terracottaDeep` — the proposed fix | 6.47 | ✓ | ✓ | — |
| `terracotta` on canvas @13pt | **4.25** | ✗ | ✗ | Use `terracottaDeep` |
| `terracottaDeep` on canvas @13pt | 6.31 | ✓ | ✓ | The fix, applied |
| **`inkFaint` on canvas @13pt** | **2.13** | ✗ | ✗ | **§8.2 — the one nobody flagged** |
| `inkMuted` on treatment-C fill `#FCF4EC` | 4.94 | ✓ | ✓ | Locked card, all three zones |
| `inkMuted` on `surface` | 5.29 | ✓ | ✓ | — |
| `inkMuted` on canvas | 5.16 | ✓ | ✓ | — |
| `ink` on canvas | 14.38 | ✓ | ✓ | — |
| `ink` on `terracottaSoft` — selected plan title | 13.07 | ✓ | ✓ | — |
| `terracottaDeep` on terracotta@12% over canvas — chip | 5.44 | ✓ | ✓ | — |
| `terracottaDeep` on terracotta@12% over `terracottaSoft` — chip on selected row | 4.96 | ✓ | ✓ | — |
| `periwinkleDeep` on periwinkle@12% over `periwinkleSoft` — KindBadge | 5.20 | ✓ | ✓ | — |

**Treatment C costs nothing in legibility.** At `#FCF4EC` all three locked-card zones measure
4.94:1 — that is the numerical answer to the AGAINST-C objection, which was about confusion, not
contrast.

### 8.1 · The primary button — a palette decision, not this phase's change

The design's own callout: *"primary label is `surface` on `terracotta` = 4.26:1 at 17pt semibold.
**Fails AA.** Fix is `terracottaDeep` as the resting fill (6.31:1) — a palette decision, not a
mockup one."* **I measure 4.36:1**, not 4.26 — same verdict, different figure; quote "fails AA for
normal text, passes for large" rather than a third number.

**This is `PrimaryButtonStyle`, on every screen in the app.** Changing it under a phase about the
free tier would be a global restyle smuggled in sideways. **Reported, not changed.** It is the
owner's call.

### 8.2 · `inkFaint` at 2.13:1 — a failure the design's own callouts missed, and a repeat

The membership sheet's footnote — *"One membership covers the whole family — every child, both
parents."* — is drawn `400 13px` in `inkFaint` `#B4ADA3` on canvas in `2a`, `2b` and `2d`.
**2.13:1. It fails AA at every size and it is not close.**

The design's warning callouts flag the primary button and the 13pt terracotta and say nothing about
this one. It is also the **only** body-ish string in the whole design drawn in `inkFaint` —
`design-system.md` itself says the token is *"not a text colour for anything that must be read."*

**And it is a repeat.** Phase 37b's review already fixed, on this same sheet, *"the unselected
plan's radio was `inkFaint` at ~2.1:1"*. Same token, same surface, a few points further down.

**Resolution: `inkMuted`** (5.16:1). The copy file specifies no colour for that line, so this is not
a copy deviation; and the design itself argues the block directly above should be `inkMuted` *"so it
reads as a stated fact rather than a footnote"* — using `inkFaint` immediately beneath contradicts
its own reasoning.

---

## 9 · Tokens the design needed and the system lacks

**None.** Every value the design specifies resolves to an existing token or an existing `Layout`
constant. Recorded explicitly because the prompt asks, and a blank list is a finding rather than an
omission.

Two near-misses worth naming:

| Design value | Nearest existing | Note |
|---|---|---|
| Locked card fill `rgba(251,237,226,.45)` | `.terracottaSoft` @ 45% over `.canvas` | Composed, not a new token. §2.1 |
| Plan row selected border **1.5px** | no named hairline weight; system hairline is 1px | Used as specified. The only sub-pixel-ish literal in the design, and it is a stroke width rather than a colour |

**The palette has no translucent tokens by construction** — `Color(hex:)` is always opacity 1, and
alphas belong at the use site. So `terracottaSoft @ 45%` is idiomatic here, not a workaround.

---

## 10 · Conformance table

Against phase 108 at `60281dd`, merged and built. **Verified by reading the code against the
artboard source, not by looking at renders.**

| Artboard | Shipped | Deviation | Reason |
|---|---|---|---|
| `1a` Weekday free | ✅ | eyebrow below the tile, not beside it | **Defect — F3** |
| `1b` Weekend free | ✅ | as `1a` | **Defect — F3** |
| `1c` Weekend member | ✅ | none | — |
| `1d` Treatment | ✅ C | **C, not the recommended A** | Owner override, §2.1 |
| `1e` AX1 | ✅ | 4-lock board is 1163pt vs an 852pt viewport | Accepted; §2.2 |
| `1f` Quiet row | **Not built** | whole artboard | Owner override, §2.2 |
| `2a` Sheet annual | ✅ | no bullet dots; no detents; label outside block | **F6, F5**, §10.1 |
| `2b` Sheet monthly | ✅ | as `2a` | — |
| `2c` Unavailable | ✅ | footnote renders where `2c` omits it | Minor, §10.1 |
| `2d` Scrolled | ✅ | no detents — always full height | **F5** |
| `3a` Trial welcome | ✅ | plain canvas, no wash, no progress rail | Correct |
| `3b` Post-trial notice | ✅ | footnote `inkMuted`, not `inkFaint` | Contrast, §8.2 |

**Restore and both legal links survived the restyle**, against a design that draws none of them —
§7.1 — and are now pinned by tests, §10.2.

### 10.1 · Findings

Six specialist readers over the diff, each finding independently refuted by a second agent; the
two HIGH findings were then re-verified by hand in the source.

> **All thirteen are fixed** on `ios/phase-108-locked-today-membership` (`859622a`) and **each fix
> was re-verified here rather than taken on trust** — merged, built cold, and read at the fix site.
> F6, F11, F12 and F13 were additionally confirmed **by looking at the regenerated renders**, which
> is how F13 was found in the first place.
>
> **One fix was correct and unpinned, and that is worth more than the finding was.** Phase 108 fixed
> F1 properly — the welcome is armed only where a credential is exchanged, and `resume()` is not one
> of those places. Then **I put the bug back**, and *"`resume()` calls `oweTrialWelcome()`"* **passed
> all 1125 tests.** `MembershipTests` covers the record-level semantics thoroughly and correctly;
> nothing covered **the wiring**, which is the whole of the defect. The worst bug of the phase was
> one line away from returning against a green suite. `RascalTests/TrialWelcomeWiringTests.swift`
> pins it now — three tests, break-tested 1:1.

| # | Sev | Finding |
|---|---|---|
| **F1** | **HIGH** | **The trial welcome fires for every existing install, every invited second guardian, and every subscribed household.** `shouldShowTrialWelcome` is `!record.trialWelcomeShown` and nothing else; `OnboardingGate:878` runs it in `.task(id: child.id)`, which fires on every launch for anyone already signed in. The flag is new in this build, so it defaults false for everybody. A subscribed parent is told *"Two weeks, everything open. No card, nothing to cancel."* — **a false statement about money.** The code's comment defends not gating on `access`, which is a sound argument against gating on `access` and not an argument for gating on nothing; the missing condition is *"this device just completed a first sign-in"*, which is known at sign-in time. |
| **F2** | **HIGH** | **Locked cards are orphaned when the day's live prompt is done.** `TodayBoardView.section(_:_:)` renders `BoardSectionHeader` only `if !items.isEmpty`, and `ForEach(board.locked)` follows it at the same level — so the moment a free parent answers the question and it moves to `doneToday`, the locked cards render with **no header**, directly above "Waiting". No artboard draws that. It is also the most common state on the board: what every free household sees for the rest of the day. Fix is the header's condition, not a header of their own. |
| **F3** | MED | **The eyebrow is not in the header row.** Every artboard drawing this card — `1a`, `1b`, all four of `1d`, `1e`, `3b` — puts tile and eyebrow on one row, `gap:10`, in the slot `PromptCard` gives its `KindBadge`. Shipped as tile-alone-with-a-`Spacer`, eyebrow moved above the body at a 6pt gap that is not a design value. Checked `1e` first: the design keeps them side by side at AX1 with a 56pt tile, so Dynamic Type is not a reason. |
| **F4** | MED | **VoiceOver says "Opens membership" twice per card.** `MembershipCopy:89` ends the label with it and `LockedPromptCard:100` adds it again as a hint — up to four repetitions on a Saturday-the-15th board. It is also hint material in a label, and a hardcoded user-visible string outside `MembershipCopy`. |
| **F5** | MED | **No `presentationDetents` anywhere**, so the sheet always presents full height. `2d` specifies *"sized to measured content, seeded ~700, `.large` kept in the set for the accessibility sizes — the `AddToArchiveSheet` rule. Not `.medium`."* |
| **F6** | MED | **"What membership adds" ships with no bullet markers.** All four sheet artboards draw a 5px terracotta dot per row. The copy file's *"no icons competing with the terracotta"* is about icons, not about the dot the design itself draws. |
| **F7** | MED | **`MembershipCopy.bannedPhrases` is dead code whose doc claims an enforcement that does not exist**, and the test that does exist covers 8 of §4's 11 phrases against its own divergent list. A dead guard reads as cover. |
| **F8** | MED | **`TodayModel.observe(_:)` has no test**, and it is the only code deciding whether the post-trial notice appears. The offer timeout is also unpinned, and the *"no empty state"* half of the `locked: []` case is asserted by an expression that cannot fail. |
| **F9** | LOW | **`mission_b`'s glyph is not the one the artboard draws.** `TodayResponse:234` renders `figure.walk`; `1b` draws a **video** mark (rounded rect + play triangle) against the first card's camera mark, so the design distinguishes the two locked missions by glyph. Reported as a deviation rather than a defect: the artboard's glyphs are hand-drawn HTML rather than named SF Symbols, and `mission_b` genuinely spans video, audio *and* activity. Leaning to `video` — it is what the approved visual drew, and the copy leads *"{Their} voice, a video, or something to do together"*, of which activity is the last. **An owner call, and it should be a decision rather than a default.** |
| **F10** | LOW | **The trial-welcome flag is spent on tap, not on show.** `OnboardingGate:867` sets `trialWelcomeShown` inside the action closure — the opposite of the rule applied, correctly, to the post-trial notice, where `MembershipPresentationRecord:16` says *"whether or not it was dismissed. Seeing it is what spends it."* Independent of F1 and survives whatever fixes it. |
| **F11** | LOW | **The footnote renders in the products-unavailable state**, where `2c` omits it — it lives inside the price-row group the `Notice` replaces. Weakest of the twelve: the sentence is still true in that state and this may be the artboard's grouping rather than an intended rule. |
| **F12** | LOW | **"What stays free, always" sits outside its bordered block**; `2a`/`2b`/`2d` draw the label inside the card. **The most arguable finding here, and it cuts both ways:** `design-system.md:228` specifies the sheet-field vocabulary as *"a `SectionLabel`, then the control 8 below it on `surface` at radius 14"* — label outside — so the code follows a house pattern. But that is precedence 5, which applies only *"for anything the design does not specify"*, and the design specifies this one. |
| **F15** ✅ | **HIGH (CI)** | **`theSpinnerEndsBeforeTheStoreDoes` flakes at ~50%, and its own comment states it cannot.** Four runs of the identical binary: ✘ ✔ ✘ ✔. Always the same test, always the **second** assertion — `await store.didFinish == false` — never the first, so the phase does leave `.loading` and the store has simply finished first. **Mechanism:** `HangingStore` suspends rather than blocking, so nothing is starved; what is contended is **MainActor**. The deadline is an unstructured `Task` whose body touches `@MainActor` state, so it must hop to MainActor — and with ~1130 tests in parallel that hop can be delayed past the store's fixed **3s** timer. **The assertion is causal in intent and temporal in practice:** it reads as *"did `load()` beat the store"* but asserts *"the deadline Task got scheduled within 3 seconds"*, which nothing guarantees. `offerTimeout: .zero` removes the sleep, not the scheduling. The comment at `MembershipTests:795-797` names this exact failure mode and rules it out — *"it is causal rather than temporal, and it cannot go flaky when 1100 other tests are running in parallel."* **Fix:** replace the fixed timer with a continuation the test releases by hand, making `didFinish == false` deterministic and dropping ~3s from the test. **A test defect, not a product defect** — production has no 1130-way MainActor contention — but it reddens CI half the time, and an intermittent red nobody can reproduce is what eventually gets a test disabled rather than fixed. |
| **F14** | MED | **The offer deadline frees the screen but not the model.** `SubscriptionModel:196-198` — `isLoading` is cleared **only** by the `defer` inside `load()`, so while `load()` is suspended on a hung store every subsequent `load()` early-returns at the re-entry guard. The deadline correctly moves `phase` off `.loading`, so the sheet says something true; but the parent who taps *Not now* and reopens from Settings or another locked card gets the same stale *"Membership isn't open yet"* with **no retry attempted and no spinner**. **It does not need a hang that lasts forever** — any hang longer than the 10s deadline opens a window where the product is unbuyable and every retry is silently ignored, app-wide, because `SubscriptionModel` is now the single instance on `RootView`. That is phase 108's own stated rationale for the timeout, half-satisfied. **Nothing covers it:** `theSpinnerEndsBeforeTheStoreDoes` ends with `await loading.value`, so the store finishes and the `defer` runs. **Reported without a prescribed fix**, because releasing the guard early lets two loads race to assign `phase` — a generation counter resolves it, and accepting the window is also defensible, but it must then be accepted *in writing* at the guard. |
| **F13** | MED | **There is no preview and no render of the sheet with no introductory offer — and that is the only state production will ever have.** `SubscriptionOffer.preview` hardcodes `trial: 2 weeks`; all five `#Preview`s use it, and `membershipSheetRenders` renders only `.ready(.preview)` and `.unavailable(.products)`. So every visual review of this sheet has been done against plan rows reading *"2 weeks free, then $59.99 a year"* — **copy no parent can see**, because the trial is server-granted and this sheet is only reached after it ends. The real rows lose the prefix, become one line instead of two, and change the plan group's height — most at AX3/AX5, where the current renders wrap. **Found by looking at the renders, not by reading code.** |

**Not reported as defects**, having checked: the uniform terracotta wash on a locked `letter` (the
wash is the lock ground, not a tint — the tile carries kind, correctly, in periwinkle); the absent
`SectionLabel` over the locked group (deliberate and right — a header there is where a count would
one day be attached); `Font.system(size:)` on four glyphs (the sanctioned `@ScaledMetric`
exception); and the hardcoded glyph-tile radius `11` (matches `PromptCard` and `WaitingCard`).

### 10.1a · Eight guards that could not fail — and the failure recurses down a chain of fixes

> **A green suite is a sample size of one.** — phase 108's phrase for it.

**This is the finding worth carrying past this phase.** It is a **seam** finding: phase 108 supplied
the recursion insight and the diagnosis of instance 5, the marketing lane supplied the instance
nobody would have predicted, and phase 110 supplied the break-testing that caught three and the
repetition that caught two more. **What none of the three sessions did alone was notice it was a
pattern** — that took three of them comparing notes in one night, which is precisely what a single
reviewer cannot do.

**The transferable part is a method, not the slogan above it**, and it is worth stating separately
so the next reader learns the first rather than the second: **run the identical binary repeatedly
and compare.** Not "re-run if it looks flaky" — run it four times as a matter of course, without a
prior suspicion, because the failure being hunted is one that *presents as a pass*. That is what
turned F15 from an intuition into a measurement (four runs: ✘ ✔ ✘ ✔), and it is what made the
mechanism findable — MainActor contention delaying an unstructured `Task`'s hop past a fixed timer,
which converts an assertion that reads as causal into one that is temporal. The fix followed from
the mechanism: **remove the clock rather than tune it.** A shorter timer or a longer poll would have
made the test luckier; only deleting the wall clock made the assertion mean what its comment
claimed.

**The sharper half, and it is phase 108's observation:** the pattern does not only recur across
people. **The failure recurses down a chain of fixes.** Three layers, one sitting, one author:

1. **The timeout that bounded nothing** — its test stubbed the one property under test
   (`Task.sleep` is cancellable; the defect was an uncancellable call).
2. **The deadline that replaced it** — its test was *structurally silent* on the wedge that same fix
   left behind (F14): it ended with `await loading.value`, letting the store finish and the `defer`
   run.
3. **The wedge fix** — its test carried a written assurance that it *"cannot go flaky when 1100
   other tests are running in parallel"*, and flaked at 50% (F15).

*Each fix's test inherited that fix's model of the problem, and each model was incomplete in a way
its own test could not express.* That is a stronger claim than "authors write weak tests for their
own code": **the depth is bounded only by how many times you fix the fix.**

It also settles which clause of the rule is load-bearing. *Break the guard* caught layer 1. *Break
what the fix left behind* caught layer 2. **Only *run it four times* catches the case where the
guard is present, correct-looking, and non-deterministic** — and two of the eight were invisible to
a single run.

**This is the finding worth carrying past this phase**, and it is about method rather than about
anyone's code. Across three repositories and three sessions, in a single evening, five tests were
found that existed, passed, and **could not fail for the reason they were written**:

| # | The guard | Why it could not fail | Found by |
|---|---|---|---|
| 1 | 37b's `theListenerIsWired` | grepped two substrings that both survived the single edit that reintroduced the bug | 37b's review |
| 2 | Marketing's banned-copy patterns | a generator turned five `\b` word boundaries into literal `0x08` bytes, so they matched nothing | breaking them on purpose |
| 3 | `MembershipCopy.bannedPhrases` | dead constant; the live test enforced 8 of 11 phrases against its own divergent inline list | F7, this pass |
| 4 | The F1 fix | correct fix, and **reintroducing the bug passed all 1125 tests** — the record semantics were covered, the wiring was not | break-testing the fix |
| 5 | The offer timeout's `HangingStore` | used `Task.sleep`, which is **cancellable**; the defect was an *uncancellable* call, so the test proved the easy case and was silent on the real one | 108's own adversarial pass |
| 6 | `theSpinnerEndsBeforeTheStoreDoes`, v1 | proved the deadline; ended with `await loading.value`, so the store finished and the `defer` ran — structurally could not observe the wedge the same fix left behind | F14, break-testing the fix |
| 7 | `theSpinnerEndsBeforeTheStoreDoes`, v2 | not silent but **random** — asserts the deadline `Task` is scheduled within 3s, which nothing guarantees, while carrying a comment ruling that exact failure out | F15, running it four times |
| 8 | The same test's `#expect(model.household != nil)` | asserted *before* `release()`, where `household` cannot yet be assigned — it is written after the join. **It had only ever passed because the flake usually let the store finish first**, so removing the flake exposed a second, deterministic error underneath it | six identical runs after the F15 fix |

**The diagnosis, which is `project-rascal-39`'s and is better than the list:** *a test written from
the same understanding as the code it guards inherits that understanding's blind spot.* `HangingStore`
used `Task.sleep` because its author was thinking about *slow*; the defect was *uncancellable*. The
test could not fail for the reason that mattered, because its author had not yet had the idea that
mattered.

**All five survived review** — several by multiple independent readers, this pass's six-agent
adversarial sweep included. **The only thing that caught any of them was deliberately breaking the
thing and watching.** Eight break-tests were run in this pass; two of them found gaps that
thirteen reviewers had not.

**So the rule for the next phase is not "review harder".** All seven survived review — several by
multiple independent readers, this pass's six-agent adversarial sweep included. The rule is:

1. **For each guard, name the single edit that should make it fail — then make that edit and watch
   it fail.** A guard whose break-test has never been run is a claim, not a guard.
2. **Then break what the fix left behind.** F14 was found this way and nothing else would have
   found it.
3. **Then run it four times.** Two of the seven were invisible to a single run, and F15 is invisible
   to three runs out of every six.

Eight break-tests and eleven full-suite runs were spent this way in this pass. They found five things
that thirteen reviewers had not.

**And one corollary, from instance 8:** removing a flake can expose a deterministic error the flake
was hiding. That is the flake paying for itself — *"a test that is wrong is worth more than one that
is flaky, because it tells you which."* Six identical runs, one message, no ambiguity.

#### The cost of reading it wrong, recorded because the next reader will read it the same way

**Phase 108 hit this flake before anyone named it, and drew the opposite conclusion from the same
data.** The 5.4s `didFinish == true` failures were read as *the implementation is wrong*, and **two
design changes were made on that basis** across four runs — a `withTaskGroup` race, then a one-shot
continuation between unstructured tasks — before the instrument was suspected instead of the
subject. This is recorded at that session's own request, and it is the most useful paragraph in the
section.

**Both halves have to survive, and dropping either one misleads:**

- **The design change stands independently.** `withTaskGroup` really does await every child;
  `cancelAll()` only *requests*. Measured on this toolchain: a 200ms sleeper racing a 3s
  non-cooperative child returned after **3.20s**. The timeout genuinely bounded nothing, and
  replacing it was correct regardless of the flake.
- **The flake was always the test.** `HangingStore` blocked no thread — it suspended. Nothing was
  starved. The failures were never evidence about the implementation at all.

Drop the first half and the fix looks unnecessary. Drop the second and it looks sufficient. **The
tell that separates them is repetition**: a wrong implementation fails every run, and this failed
about half of them. **Nobody counted until the fourth run.**

#### Why the two shipping defects came from the seam rather than from either session

**Neither is a review technique, and that is the point.** The two defects that would have reached a
parent — F1, a paying subscriber told they were on a free trial, and F13, a sheet reviewed only in a
state that cannot occur — were each found by one session holding a different model of the *same
artefact* than the session that made it.

- **F1 needed someone else's break-test against 108's code.** That session could not have broken it
  usefully: it would have broken it the way it built it, which is instances 1, 2 and 3 of the list
  above, three times over.
- **F13 needed someone reading renders 108 had generated and not opened.** The images existed and
  were committed; nobody had looked at the one that mattered, because the harness's purpose was
  understood as *producing* them.

**Both are consequences of two agents comparing models of one artefact**, not of either reviewing
harder. It is the same property that made the eight-instance pattern visible at all — no single
session saw more than two of them.

### 10.2 · Two App Review requirements were deletable, and now are not

Break-tested by deleting controls from a green tree and re-running all 1108 tests:

| deleted | tests that failed |
|---|---|
| the entitlement gate — `access.isEntitled ? [] : response.locked` | **2** ✅ |
| a currency literal added to `MembershipCopy` | **1** ✅ |
| **the restore control** | **0** ❌ |
| **the plan row's `Text(plan.displayName)`** | **0** ❌ |

**`displayName` had in fact been dropped during the restyle** and was restored only because a
reviewer asked — nothing in the suite would have caught it. `RascalTests/AppReviewRequirementsTests.swift`
now pins all five requirements, both legal links and the host guard; all four source guards were
broken simultaneously and each failed **exactly one** test, 1:1 with its break.

### 10.3 · The warning baseline is 0, not 21

Both phase prompts say *"21 inherited warnings exist… do not add the 22nd."* **That figure is
stale.** A cold build of the merged tree — isolated `derivedDataPath`, app and test targets —
produces **zero** warnings under CI's own grep. CI itself gates at zero and would fail on one. The
target is zero and it is met.

---

## 11 · Open decisions for the owner

Neither agent may settle these.

1. **`PrimaryButtonStyle` fill.** `surface` on `terracotta` is 4.36:1 — fails AA for normal text.
   The design proposes `terracottaDeep` as the resting fill (6.47:1). **App-wide change.** §8.1
2. **The sheet's "other parent" line.** *"Their other parent, on the same archive"* is grammatical
   but stilted. *"The other parent, on the same archive"* reads better and suits a per-household
   sheet. **A copy decision.** §6.4
3. **Two contractions lost to tokenisation** — *"until he's old enough"* → *"until he is old
   enough"*, in two strings. Accept, or supply a contracted form. §6.4
4. **`free-tier-copy.md` has no home.** It exists in a prompt and in two agents' transcriptions.
   It should be committed to this repository as the reviewed source. §6
5. **The four-lock Saturday.** `1e` argues the card is too tall at AX1 and the owner has chosen to
   show locked slots always. The worst case is four. **Worth looking at the preview before ship.**
   §2.2
