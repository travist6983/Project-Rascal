# Settings v2 — design import inventory

The Phase 1 deliverable for `ios/phase-13-settings-v2`. Written before any Swift changed, kept
after the build so the reasoning behind each resolution survives the diff.

**Source.** `RASCAL Settings.dc.html`, imported live through the `claude_design` MCP from project
`e227a63f-e516-4426-8074-eb12edd15ad2` ("Mobile app design pending"). The MCP import **succeeded**;
`DesignSync.get_file` returned the file and it is byte-identical to the copy in
`docs/mobile-app-design-settings/project/`. No fallback was needed and none was used.

`support.js` (69 KB) is the prototype's own `x-dc` / `DCLogic` rendering runtime — a template
engine, not design input. It defines `sc-for`, `sc-if` and the `{{ }}` binding the design file
uses. It contains exactly **three** hex values, and all three are the design tool's own chrome
rather than RASCAL tokens: `CANVAS_BG_LIGHT #f0eee6`, `CANVAS_BG_DARK #2e2c26`, and `#b00020`
(with `color:#fff`) on its error banner — a pure white and a signal red, neither of which is in
this app's palette, which is itself the clearest evidence the file is the tool and not the design.
**No RASCAL palette value appears in it.** The bundle's `tokens/*.css` and `guidelines/*.html`
were read in full.

---

## 0. Preflight record

| Check | Result |
|---|---|
| Branch | `ios/phase-13-settings-v2`, off `main` at `075f236` |
| Working tree at start | Clean except the untracked design export, which is this phase's input |
| Baseline suite | **571 tests in 56 suites passed**, `** TEST SUCCEEDED **` |
| Baseline warnings | **0**, across `Rascal`, `RascalTests`, `RascalWidget`, `RascalShare` |
| Cold? | Yes — `rm -rf ~/Library/Developer/Xcode/DerivedData/Rascal-*` first |
| Command | `xcodebuild test -project ios/Rascal/Rascal.xcodeproj -scheme Rascal -destination "id=45D78B71-…" CODE_SIGNING_ALLOWED=NO` |
| CI | Not run. The iOS workflow is dispatch-only since PR #33; no count here was carried forward from a previous phase. |

---

## 1. What the export actually contains

**The file renders one direction, not two.** Its header says "Settings — two directions" and its
closing paragraph says "Both keep your row component…", but `renderVals()` returns
`options:[{id:"1a", …}]`. The constant `b1` — direction 1b, a navy "Archive health" card with an
amber progress bar, per-row 26px dot swatches, and a periwinkle `4y 1m` label tag — **is
constructed and never referenced.** It is dead code in the prototype.

This phase implements **1a — "Subject-led — the child sits at the top"**, because that is what the
file draws. 1b is inventoried below for completeness and is not built. Everything unique to 1b
(the navy card, `#E0A03B` amber, `#9A9CB4`, `#A7A9BE`, the dot swatches, the label tag, a "What's
new" row, an "Advanced" drill-in row) is out of scope by that fact alone, not by judgment.

### 1a — one screen, ten blocks, top to bottom

| # | Block | Contents |
|---|---|---|
| 1 | Screen title | `Settings`, Nunito 800, 31px |
| 2 | **Hero** (`isHero`) | 62px terracotta disc with the child's initial, name at 26px, `4 years, 1 month · born 19 June 2022`, a trailing chevron, and a three-cell stats strip: `412 entries` · `1,204 photos` · `3 sealed` |
| 3 | Group **The archive** | `Birthday` → value + chevron · `Timezone` → value + chevron · `First entry` → value, quiet, no chevron |
| 4 | Group **You** | `Your name` → value + chevron · `Email` → value, quiet |
| 5 | **Export card** (`isExport`), label *Keep a copy* | Terracotta headline `Export the archive`, body, `Last export — never`, plus a decorative motif of three rotated rounded rectangles at the right edge |
| 6 | **Sync card** (`isSync`), label *Syncing* | Peach header: dot, eyebrow `Uploading`, mono counter `8 left`, headline `8 files still to upload`, body, a 64% progress bar. Then three rows: `Retry now` (action) · `Last pull` → `Never` · `Pull changes from the server` (toggle, off) with a sub-line |
| 7 | Group **Advanced** | `Run a dry run` (action + sub) · `Reset sync position` (action + sub) · `Recompute ages from birthday` (action + sub) |
| 8 | Group **App** | `Version` → `1.0 (1)`, quiet |
| 9 | **Sign out** (`isButton`) | Full-width, `surface` fill, `border` hairline, 22px radius, Nunito 700, ink |
| 10 | **Note** (`isNote`) | `Rascal writes to this phone first. Everything you see here exists whether or not the network does.` |

### Row vocabulary the prototype defines

`row(o)` in the `data-dc-script` block supports: `label`, `value`, `sub`, `chevron`, `toggle`,
`action` (terracotta + semibold label), `quiet` (muted label), `dot` (a 26×26 swatch), `bg`, and
`valueTone` (`"ok"` → `#4B7A4F`, `"warn"` → terracotta).

**`valueTone` is never passed anywhere in 1a or 1b, and `bg` never is either.** Both are unexercised
branches of the prototype's own helper. `dot` is used only in 1b.

### States the export draws — and the ones it does not

Drawn: **one.** A single populated screen. The export contains no loading state, no offline state,
no empty state, no error state, no in-flight state for any action, and no sheet.

Not drawn, but required by what ships today:

| Surface | States the shipped app has | States the export draws |
|---|---|---|
| Export card | idle · running(fraction) · running(indeterminate) · ready(url, bytes) · failed(message) | idle only |
| Sync card | outstanding · everything-uploaded · retrying | outstanding only |
| Dry run | idle · running · ready(summary) · failed(message) | the trigger row only |
| Recompute | idle · running · done(updated, birthdate) · failed(message) | the trigger row only |
| Transcription backlog | absent · idle(waiting/failed counts) · running(progress) · finished(report) | **no home at all** |
| Sync pull rows | Last pull · Position · Last attempt · toggle | Last pull and the toggle only |
| Edit child sheet | name · birthday · timezone picker · notice · saving | none |
| Edit profile sheet | name · email · notice · saving · length warning | none |
| Sync report sheet | monospaced report + copy | none |
| Confirmation dialogs | recompute · reset · sign out | none |

Every one of those survives this phase. The design supplies a skin for the populated case and
nothing else, which is normal for a mockup and is called out here so "the design didn't show it"
is never mistaken for "it was dropped".

---

## 2. Token reconciliation

Split by whether a value belongs to the **phone screen** or to the **design-doc canvas** that
frames it. The canvas — page background `#EFE9DF`, the 56px navy bezel, the 47px screen mask, the
notch, the status bar, the `7:19` clock — is presentation furniture for the mockup and is not app
surface. It is excluded from the mapping below and listed once at the end.

### 2a. Colour — every value the screen uses

`✅` = exact match to an existing `Palette.swift` constant. `→` = snapped, per the reconciliation
rule. `1b` = appears only in the unrendered direction.

| Hex | Where the export uses it | Resolution |
|---|---|---|
| `#23253C` | Row labels, screen title, hero name, stat numbers, sign-out label | ✅ `Color.ink` |
| `#FDFAF4` | Screen background, avatar initial | ✅ `Color.canvas` |
| `#FFFDF9` | Card fill, tab bar, toggle knob, sign-out fill | ✅ `Color.surface` |
| `#6E6A63` | Hero sub, row values, body copy | ✅ `Color.inkMuted` |
| `#C05A2B` | Avatar disc, action-row labels, export headline, sync dot, progress bar, toggle-on | ✅ `Color.terracotta` |
| `#B4ADA3` | Section labels, the closing note, export meta line | ✅ `Color.inkFaint` |
| `#EDE5DA` | Card hairline, sign-out hairline | ✅ `Color.border` |
| `#FBEDE2` | Sync-card header wash, hero gradient stop 1 | ✅ `Color.terracottaSoft` |
| `#F4EEE5` | Default dot fill (1b), neutral label tag | ✅ `Color.chipPlain` |
| `#E9EBFB` | Periwinkle label tag, account dots | ✅ `Color.periwinkleSoft` (1b) |
| `#5566D6` | Periwinkle label-tag ink | ✅ `Color.periwinkle` (1b) |
| `#4B7A4F` | `valueTone:"ok"` | ✅ `Color.sageInk` — **never invoked** |
| `#F0E8DC` | Hairline between two rows inside a card | → `Color.border`. Two hairline colours for one job; the card's own line is `#EDE5DA`. |
| `#EAE1D5` | The rule beside a section label | → `Color.border`. Third hairline value. |
| `#8C8279` | Row sub-lines, stat key labels | → `Color.inkMuted`. Ink-ramp step 4 of a ramp `design-system.md` states has three. |
| `#C4BAAE` | Row chevron stroke | → `Color.inkMuted` (**held**, see D6). Ramp step 5. |
| `#C0A79B` | Hero chevron stroke | → `Color.inkMuted`. Ramp step 6. |
| `#B07A5A` | `Uploading` eyebrow and the mono counter, on peach | → `Color.inkMuted`. Ramp step 7, terracotta-tinted. |
| `#E4DACD` | Toggle track, off | → dropped; stock `Toggle` owns its off track (D7). |
| `#E2E5F7` | Hero gradient stop 2 | → dropped; the hero flattens to its first stop (D2) |
| `#FBF6EF` | Hero gradient stop 3 | → dropped with the gradient. (It is `Gradients.wash`'s third stop to the digit — noted because it is more evidence the bundle was drawn against the app.) |
| `#DFE2F0` | Hero hairline | → `Color.border`, the hairline the app already pairs with a terracotta-tinted fill |
| `#EEE1D0` `#E5D8C6` `#DCCFBE` | The export card's three rotated rectangles | → dropped (D3) |
| `#E0A03B` | Amber dot and progress bar in the navy card | 1b only — not built. No amber exists in the palette. |
| `#9A9CB4` `#A7A9BE` | Eyebrow and body on the navy card | 1b only — ramp steps on navy |

Canvas furniture, excluded: `#EFE9DF` (page), `#23253C` (bezel/notch — same value as ink).

### 2b. The bundle's own `tokens/colors.css` versus the prototype

**Third phase running, same result.** Every RASCAL colour in `tokens/colors.css` matches
`Palette.swift` exactly:

| `tokens/colors.css` | Value | `Palette.swift` |
|---|---|---|
| `--rascal-canvas` | `#FDFAF4` | `canvas` ✅ |
| `--rascal-surface` | `#FFFDF9` | `surface` ✅ |
| `--rascal-border` | `#EDE5DA` | `border` ✅ |
| `--rascal-ink` | `#23253C` | `ink` ✅ |
| `--rascal-muted` | `#6E6A63` | `inkMuted` ✅ |
| `--rascal-terracotta` | `#C05A2B` | `terracotta` ✅ |
| `--rascal-peri` | `#5566D6` | `periwinkle` ✅ |
| `--rascal-peach` | `#FBEDE2` | `terracottaSoft` ✅ |
| `--rascal-lav` | `#E9EBFB` | `periwinkleSoft` ✅ |
| `--rascal-sage` | `#E8F0E6` | `sage` ✅ |
| `--rascal-lav-badge` | `#DADDF7` | `periwinkleBorder` ✅ |
| `--rascal-sage-ink` | `#4B7A4F` | `sageInk` ✅ |
| `--rascal-muted-soft` | `#B4ADA3` | `inkFaint` ✅ |

Nine of the eleven unmapped values in §2a appear in **neither** `colors.css` **nor**
`Palette.swift`. One file disagrees with two, and per the rule settled in advance the palette
holds. **No `Palette` constant was added.**

`colors.css` does carry three values the palette lacks — `--rascal-peach-deep #F8E7DC`,
`--rascal-peach-badge #F3D9C7`, `--rascal-ink-disabled #D9CFC2` — but the Settings export uses
none of them, so nothing here turns on that gap.

### 2c. Radius

| Export | Element | Resolution |
|---|---|---|
| 24px | Hero card | → `Layout.cardRadius` (20) |
| 22px | Every group card, the export card, the sync card, the sign-out button | → `Layout.cardRadius` (20) |
| 99px | Avatar disc, toggle, pills, FAB | → `Capsule()` ✅ |
| 10px, 8px | Export motif tiles, row dots | dropped with their elements |
| 56px, 47px, 20px, 2px, 1px | Bezel, screen mask, notch, battery, signal bars | canvas furniture |

Identical to Today v2's D3, resolved the same way and for the same reason: `Layout.cardRadius` is
shared by Timeline, Moments, the composer and Settings. Changing it restyles every screen; changing
it here alone makes Settings the outlier.

### 2d. Spacing

| Export | Meaning | Resolution |
|---|---|---|
| `padding:0 16px` | Screen margin | ✅ `Layout.screenMargin` (16) |
| `gap:18px` | Between blocks | 18, written inline — the shipped file already writes `24` and `10` inline; no `Layout` constant was added |
| `gap:9px` | Section label → its card | 9, inline |
| `padding:15px 17px` | Row padding | → `Layout.cardPadding` (16) |
| `padding:18px` | Export-card padding | → `Layout.cardPadding` (16) |
| `padding:17px 17px 16px` | Sync header padding | → `Layout.cardPadding` (16) |
| `padding:66px 0 108px` | Scroll inset, top and tab-bar clearance | Handled by `RootView`'s `.safeAreaPadding(.bottom, 84)` and the safe area — see D9 |
| `gap:12px` / `gap:9px` | Row label → trailing cluster | 12 / 9, inline, as shipped |

`tokens/spacing.css` names `--rascal-app-gutter: 22px` and `--rascal-app-tabbar-clearance: 110px`,
neither of which the Settings prototype uses — it gutters at 16 and clears at 108. The prototype
and the token file disagree; the shipped `Layout.screenMargin` of 16 agrees with the prototype and
with `design-system.md`, so 16 stands.

### 2e. Type

The export sets Nunito 700/800 for display and Source Sans 3 for body — the mockup families.
`design-system.md` settles SF Pro Rounded and SF Pro Text as the shipped stand-ins and bundles no
font file. Sizes reconcile as:

| Export | Element | Resolution |
|---|---|---|
| 31px / Nunito 800 | `Settings` title | → `.display` (34) — shipped, unchanged |
| 26px / 800 | Hero name; avatar initial | → `.detailTitle` (26) ✅ exact |
| 19px / 800 | Sync headline, export headline | → `.cardTitle` (17). `.dayNumber` is 19/bold/rounded and matches numerically, but it means "the day number on a timeline group header" and reusing it here would make the role a lie. |
| 17px / 400 | Row label | → `.body` (16). The export sets row labels at 17 **regular**; the nearest 17 role, `.cardTitle`, is semibold. |
| 17px / 600 | Action-row label, sign-out | → `.body` for rows (weight carried by terracotta, as shipped) · `.cardTitle` for sign-out ✅ shipped |
| 16px / 400 | Row value | → `.body` (16) ✅ exact |
| 14.5px | Hero sub, export body, sync body | → `.metadata` (13) |
| 13.5px | Row sub-line | → `.metadata` (13) |
| 13px | Closing note | → `.metadata` (13) ✅ near-exact |
| 12.5px / **mono** | Sync counter, export meta | → `.metadata`, **not** monospaced (D5) |
| 11.5px / 600 / `.09em` / uppercase | Section label, eyebrow | → `.label` (12, +0.6 tracking, uppercase) ✅ |
| 11px / 700 | Tab bar labels | `FloatingTabBar` — out of scope |
| 10.5px | Stat key labels | dropped with the stats strip (D1) |

### 2f. Shadow

| Export | Element | Resolution |
|---|---|---|
| `0 2px 8px rgba(0,0,0,.04)` | Every card | ✅ **exact** — `Layout.Shadow` is y 2, blur 8, opacity 0.04 |
| `0 2px 10px rgba(0,0,0,.05)` | Hero | → `Layout.Shadow` |
| `0 1px 3px rgba(0,0,0,.2)` | Toggle knob | dropped with the custom toggle |
| `0 4px 20px rgba(0,0,0,.10)` | Tab bar | `FloatingTabBar` — out of scope |
| `0 4px 14px rgba(192,90,43,.34)` | FAB | `FloatingTabBar` — out of scope |
| `0 8px 24px rgba(35,37,60,.20)` | Navy card | 1b only |
| `0 24px 60px` / `0 3px 10px` | Phone bezel | canvas furniture |

The card shadow matching to the digit is worth stating plainly: the export and the shipped
`Layout.Shadow` agree exactly, which is the strongest signal in the bundle that this design was
drawn against the app rather than beside it.

### 2g. Motion

The export is static HTML with no transition, animation, or `@keyframes` of any kind. `tokens/motion.css`
exists in the bundle and the Settings file does not import or reference it. **Nothing to
reconcile**; the shipped `Motion.tapScale` / `TapScaleButtonStyle` continue to carry every
interaction.

---

## 3. Deviations — every place the export disagrees with the design system

### D1 — The hero's three-stat strip requires counts nothing serves

`412 entries · 1,204 photos · 3 sealed`.

- `ChildResponse` carries `id, name, birthdate, familyTimezone, ageMonths, role`. **No counts.**
- `docs/api-contract.md` has no endpoint returning archive-wide totals for a child.
- The local SwiftData cache is *paged and partial* by construction, so counting it answers "how
  much of the archive has this phone happened to page in", not "how big is the archive".
- `design-system.md` already settles the rule this breaks, for `TimelineHeader`: *"The count
  **never claims to know the size of the archive**. Until the last page has landed it reads
  '412 so far'."*
- `sealed` is `unlock_at_age`, which per `design-system.md` and `docs/blocked.md` the server has
  no filter for at all.

~~**Resolution: dropped.**~~ **Built Aug 15, 2026, once a source of truth existed.** Phase 28 added
`GET /children/{id}/stats`, which counts server-side — so the strip no longer means the client
asserting the size of the archive, which was the entire objection. The Timeline header rule is
untouched and still right: it governs a *paged list*, and this is a counted total.

Three copy decisions came with it, all the owner's. **The middle cell counts photographs, not
media** — the response carries video and audio too, and "1,287 files" is a computer's word for a
shoebox of memories. **The strip does not render until the server answers**, because nil is not
zero and a placeholder reading "0" or "—" mid-flight is exactly the assertion this was dropped
over; offline, the hero is what it always was. **An empty archive shows nothing**, since three
zeros greeting somebody on the day they signed up is the closest thing to a score this app would
print. Q1 is closed.

### D2 — The hero's gradient is a reserved token, and it fails contrast anyway

The export washes the hero `linear-gradient(142deg, #FBEDE2, #E2E5F7, #FBF6EF)` over a `#DFE2F0`
hairline. The palette's `Gradients.wash` is `#FDE8DC → #F7DDE8 → #FBF6EF` — same warm-to-cream
arc, same third stop to the digit, a periwinkle rather than pink middle.

Two things rule it out, and the second is the decisive one:

1. `design-system.md`: *"Reserved for emotional beats only — onboarding, all-caught-up, throwback
   headers, sealed entries … never a background for ordinary content."* The enumerated list
   predates this screen and does not name it.
2. **Measured, it fails.** The hero's sub-line is `inkMuted`, and `inkMuted` over `Gradients.wash`
   measures **4.55:1** on the first stop and **4.22:1** on the middle stop — under AA for normal
   text, on a gradient where the text crosses both. Adopting it would put a new sub-AA foreground
   pairing on a new surface, which is precisely the `KindBadge` mistake the brief asks not to
   repeat.

**Resolution: the hero is a `Color.terracottaSoft` card with a `Color.border` hairline.** That is
the flattest honest reduction of the export's own gradient — `#FBEDE2` **is** its first stop, to
the digit, and is `terracottaSoft` exactly — and it is the tinted-card pairing the app already
ships (`PromptCard`, via `AssignmentPresentation.softTint` / `tintBorder`, where terracotta
deliberately keeps the cream `border`). Measured: `ink` on `terracottaSoft` **13.07:1**, `inkMuted`
**4.69:1**, both clear AA. No reserved token is spent and no new one is added. Recorded as **Q2**.

### D3 — The export card's motif is three rotated cards, which is a Rejected bullet

`transform:rotate(-9deg)`, `rotate(5deg)`, `rotate(-2deg)` — three stacked, rotated rounded
rectangles suggesting a pile of photos.

`design-system.md`, Anti-patterns: *"Passport stamps, receipt-spike stacks, **rotated cards**"*,
and *"Rejected twice already — don't drift back."*

**Resolution: dropped.** Not snapped, not softened — the bullet names the exact construction. The
three unmapped warm neutrals it needed (`#EEE1D0`, `#E5D8C6`, `#DCCFBE`) go with it. The export
card keeps its terracotta headline, its body, and its meta line, which is what carries the
"keepsake rather than menu item" intent the design note describes.

### D4 — The sync card's progress bar has no honest denominator

The header draws a bar at `width:64%`. Settings knows `EntrySync.Outstanding` — counts of entries,
deletions and media still to push — and **nothing to divide them by.** The archive's total size is
unknown (D1), and total bytes outstanding is not tracked at the screen level.

**Resolution: dropped.** `ArchiveExport` keeps its bar, because that one is a real measurement —
the server sends `content-length` because it assembles the zip before streaming it. A bar that
animates to a number the app made up is worse than no bar. Recorded as **Q3**.

### D5 — Monospace for the counter and the meta line

`font-family:ui-monospace,Menlo,monospace` on the sync counter and, in the bundle's type
guidelines, on "metadata only — dates, counters, spec keys". `design-system.md` names **two**
families and neither is mono.

**Resolution: held `.metadata`.** Identical to Today v2's D4. The one monospaced surface in the
app — `SyncReportSheet` — stays monospaced, because there the counts table is column-aligned and a
proportional face turns it into a smear. A three-word counter is not that.

### D6 — Chevrons at `#C4BAAE`, and the ink ramp at seven steps

`design-system.md`: *"The ink ramp is three steps, not two"* — `ink`, `inkMuted`, `inkFaint`. The
export uses seven: `#23253C`, `#6E6A63`, `#8C8279`, `#B4ADA3`, `#C0A79B`, `#C4BAAE`, `#B07A5A`.

Four collapse cleanly onto `inkMuted` / `inkFaint`. The chevrons are the one judgment call:
`#C4BAAE` and `#C0A79B` are both *lighter* than `inkFaint`, so the design wants chevrons quieter
than the quietest step the system has.

**Resolution: held `Color.inkMuted`, as shipped.** `inkFaint` on `surface` measures **2.19:1**,
and the export's own `#C4BAAE` measures **1.88:1** — both below the 3:1 WCAG asks of a non-text UI
component. The chevron is redundant to VoiceOver (each row is one combined element with
`.isButton`), so neither value would *lose* information, but moving a control **down** toward 2:1
to match a mockup is the `KindBadge` mistake in a new surface, and §"Accessibility hook" asks
explicitly that it not be repeated. `inkMuted` on `surface` measures **5.29:1**.

### D7 — A hand-drawn toggle

The export draws a 50×30 pill with a 24px knob and its own off-state track `#E4DACD`.

**Resolution: held the stock `Toggle`, tinted `.terracotta`, as shipped.** It is already correct
for VoiceOver, for Switch Control, for Full Keyboard Access, and for the "on/off" state
announcement, none of which a hand-drawn pill gets for free. The tint is the one thing the design
actually asks for that a stock toggle can honour, and it already does.

### D8 — `Recompute ages` sits inside `Advanced`, beside two lighter actions

The export's `Advanced` group is `Run a dry run` · `Reset sync position` · `Recompute ages from
birthday` — three rows, one card, hairlines between them.

This collides with two settled things at once:

1. The phase brief: *"Recompute ages … must stay deliberate and explicit — a redesign must not
   make it a one-tap row that sits next to benign ones."*
2. `SettingsScreen`'s own structural rule, written into the file: *"irreversible actions live in
   their own card at the bottom, separated by whitespace, never adjacent to an ordinary edit row.
   A divider between two rows says 'these belong together'; a gap says 'these do not'."*

**Resolution: split.** `Advanced` becomes dry run + reset, in the design's group treatment.
Recompute keeps its own card under its own `Corrections` label with whitespace above it, and keeps
its confirmation dialog. The design's grouping is otherwise adopted verbatim. Recorded as **Q4**.

### D9 — The design's claim that the tab bar hides "Sign out"

The export's closing paragraph: *"Every screen now clears the tab bar — the live build hides 'Sign
out' behind it."*

**Checked, and it is not true of the current build.** `RootView.swift:234` applies
`.safeAreaPadding(.bottom, 84)` to every tab, and `SettingsScreen` adds `.padding(.bottom, 20)`
inside its `ScrollView` — 104pt of runway under the last element, against a `FloatingTabBar` that
is ~68pt tall sitting 4pt off the safe area. The claim was true of some earlier build; it is
recorded here so the next reader does not "fix" a bug that is already fixed.

### D10 — Paper grain

The screen background carries an inline `feTurbulence` fractal-noise SVG at `opacity:0.055`, and
`tokens/base.css` states *"Paper grain is part of the identity, not decoration — every RASCAL
surface sits on it."*

**Resolution: dropped, and not resolved.** Per the standing instruction, this is an open design
decision that predates this phase — `design-system.md` opens its anti-patterns with "screen-print
texture", defines no grain token, and neither decisions file mentions grain at all. Handled exactly
as Today v2 handled it (`decisions-log.md:1017`). No compromise was invented.

### D11 — `KindBadge` contrast

**Not touched, and not propagated.** The Settings export uses the tint-on-12%-wash pattern in one
place only: 1b's periwinkle label tag (`#5566D6` on `#E9EBFB`), which is in the direction that is
not rendered and not built. **No new surface in this phase carries that pattern.** The pre-existing
defect on `PromptCard` is untouched, per the brief.

### D12 — "First entry — 21 Jun 2022"

~~Same root cause as D1: the app cannot know the oldest entry in the archive from a partial, paged
cache, and no endpoint reports it. **Dropped.**~~ **Built Aug 15, 2026** — `/stats` returns
`first_entry_on` as a calendar day in the child's own timezone. It renders under the born-date
rather than as a row or a fourth cell, because two dates about the same child belong together:
when they arrived, then when somebody started writing it down. It reads *"Archive starts 21 June
2022"* rather than "First entry", which names a row in a list. Nil when the archive is empty — an
empty archive has no first day and inventing one would be the same lie as a zero-filled strip.
Q5 is closed.

---

## 4. Open questions

Numbered, each with the resolution taken and the basis for it. All five are reversible.

| # | Question | Resolution taken | Basis |
|---|---|---|---|
| **Q1** | The hero's three stats need archive-wide counts. Drop them, ask Lane A for a counts endpoint, or count the partial cache? | **Dropped.** | Counting the cache would have the client assert the size of the archive — the exact thing `design-system.md`'s `TimelineHeader` rule forbids. A counts endpoint is an API-lane conversation, and this phase may not open one. |
| **Q2** | Is the child hero an "emotional beat", making `Gradients.wash` legal there? | **Moot — used `terracottaSoft` + `border` instead.** | The question never had to be answered: `inkMuted` over the wash measures 4.22–4.55:1, under AA, so the gradient was unusable on contrast grounds before the "reserved" rule was even reached. `terracottaSoft` is the wash's own first stop and clears AA at 4.69:1. |
| **Q3** | The sync progress bar has no denominator. Drop it, or track outstanding bytes? | **Dropped.** | Tracking outstanding bytes is new state and new plumbing through `EntrySync`, which is "new Settings functionality" and out of scope. |
| **Q4** | The design puts recompute-ages in `Advanced` beside dry run and reset. | **Split — recompute keeps its own card.** | The brief and `SettingsScreen`'s own documented structural rule both forbid the adjacency. |
| **Q5** | `First entry` row needs the archive's oldest `occurred_at`. | **Dropped.** | Same as Q1. |
| **Q6** | The transcription backlog has **no home in the design at all.** | **Kept, inside the sync card, restyled to the new vocabulary.** | The brief: *"If the design has no home for it, that is an inventory question, not a licence to drop it."* It is unusual content — a count, a battery caveat, a progress run, a report — that stock rows serve badly, which is why it has its own section rather than a row. |
| **Q7** | The design shows only `Last pull`; the shipped `SyncPullSection` also shows `Position` and `Last attempt`. | **Kept both.** | Existing behaviour. `Last attempt` is the only place in the entire app that reports a sync failure, and the group vocabulary takes a value row without modification. |
| **Q8** | Direction 1b is fully authored and never rendered. Build it, or ignore it? | **Ignored.** | `renderVals()` returns `1a` alone. Implementing an unreferenced constant would be building something the designer's own file does not draw. |
| **Q9** | The export's closing note is new copy the app does not currently show. | **Adopted.** | It is a design element, not new functionality — one `.metadata` line in `inkFaint` — and it is true and on-voice. |
| **Q10** | Section labels: the export sets them `#B4ADA3` (`inkFaint`); `SectionLabel` ships `inkMuted`. | **Held `inkMuted`.** | `design-system.md` says section headers are `inkMuted`, and `SectionLabel` is shared with Timeline, Today and Moments — restyling it here would restyle them. |
| **Q11** | Row dividers: the export runs them full-bleed; `SettingsDivider` insets them to the text. | **Held the inset.** | `SettingsRow.swift` documents the inset as deliberate — "so the rows read as a list rather than as stacked boxes". |
| **Q12** | The sign-out button: the export draws a 22px rounded rectangle; the app ships a `Capsule`. | **Held the `Capsule`.** | `design-system.md`: "Chip / pill radius: fully rounded", and `PrimaryButtonStyle` is a capsule. |
| **Q13** | The export card's third line, `Last export — never`. | **Dropped.** | Nothing records when an export last ran. Tracking it is new persisted state, which is "new Settings functionality" and out of scope; inventing a timestamp is worse than omitting the line. |

---

## 5. Stop conditions

§2 of the brief lists four. **One trips.**

| Condition | Verdict |
|---|---|
| MCP import fails **and** the export directory is unreadable | **Not tripped.** The MCP import succeeded and matches the local bundle byte-for-byte. |
| The export needs a `Palette` token that does not exist and the rule cannot resolve | **Not tripped.** Eleven values are unmapped; every one resolves by snapping, and the rule settled in advance covers all of them. No token was added. |
| The export needs a capability the app lacks and this phase does not scope | **TRIPPED — three times.** Archive-wide counts (D1/Q1), the oldest entry date (D12/Q5), and a denominator for the sync bar (D4/Q3). All three need either an API change or new client state, and both are out of scope. |
| The design conflicts with a settled decision in `docs/decisions.md` | **Not tripped by `decisions.md`.** It conflicts with `design-system.md` in four places — the rotated-card motif (D3), the reserved gradient (D2), a third type family (D5), and a seven-step ink ramp (D6). **All four resolved toward the design system**, and D2 turned out to be over-determined: the gradient failed a contrast measurement independently of the rule that forbids it. |

The tripped condition was **resolved by dropping the three elements**, following the Today v2
precedent, rather than by halting: nothing was invented, no endpoint was assumed, and each drop is
recorded above with its numbered question. Every "what must survive" behaviour is intact.

---

## 6. What must survive — verified

| Behaviour | Where it is now | Reachability |
|---|---|---|
| **Sync dry-run entry point** | `Advanced` card, first row | Settings tab → scroll → `Run a dry run`. Same depth as before: **1 tap**, no drill-in, no sheet. The report stays behind `Read the report` → `SyncReportSheet`, monospaced and copyable. |
| **The flip path** (dry run → read → toggle → pull to refresh) | Sync card toggle sits *above* `Advanced` | Unchanged in order and in depth. |
| **Transcription backlog** | Inside the sync card, its own section | Appears only when `waiting > 0 || failed > 0`, as before. |
| **Recompute ages** | Its own `Corrections` card, whitespace above, confirmation dialog | 1 tap to the dialog, 2 to run. Deliberately **not** in `Advanced` (D8). |
| **Export** | Its own card, four states | 1 tap. |
| **Birthdate edit does not recompute** | `EditChildModel.save()` untouched | Pinned by `birthdateSaveDoesNotRecompute`, which asserts exactly one request and that it is the `PATCH`. |

---

## 7. Dropped, and why — the short list

| Dropped | Why |
|---|---|
| Hero stats strip (`412 entries · 1,204 photos · 3 sealed`) | No source of truth (D1/Q1) |
| `First entry` row | No source of truth (D12/Q5) |
| `Last export — never` line | No source of truth (Q13) |
| Sync progress bar | No denominator (D4/Q3) |
| Export card's three rotated tiles | Named anti-pattern (D3) |
| Paper grain | Open decision that predates this phase; dropped and left open (D10) |
| Monospace counter | Third type family (D5) |
| Hand-drawn toggle | Stock `Toggle` is more accessible (D7) |
| Direction 1b entirely | The file never renders it (Q8) |
| Row dot swatches, `4y 1m` label tag, navy card, "What's new" row, `Advanced` drill-in row | 1b only |
| `valueTone` ok/warn, row `bg` | Unexercised branches of the prototype's own helper |
| Tab bar, FAB, status bar, notch, bezel | `FloatingTabBar` / canvas furniture — out of scope |

---

## 8. What shipped

| File | Change |
|---|---|
| `Settings/ChildHeroCard.swift` | **New.** The subject-led header — avatar disc, name, age, born date, chevron into `EditChildSheet`, plus its not-yet-loaded state. |
| `Settings/SettingsRow.swift` | `SettingsSectionHeader` (label + rule) and `SettingsCardHeader` (the sync card's summary) added; `SettingsCard` gained a `fill` and now clips; the dead `valueIsMuted` flag removed from both row types. |
| `Settings/SettingsScreen.swift` | Restructured to the import's block order; `syncSummary` lifted out of the view body as a testable value; export idle became a card; the closing note adopted; `syncStatus` construction moved off `.task`. |
| `Settings/SyncPullSection.swift` | Split — `SyncPullSection` keeps the status rows and the switch, new `SyncAdvancedSection` carries the dry run and the reset into their own labelled card. |
| `RascalTests/SettingsV2Tests.swift` | **New.** 17 tests in 4 suites. |

Untouched, deliberately: `ArchiveExport`, `RecomputeAgesModel`, `SyncStatusModel`, `EditChildModel`,
`EditChildSheet`, `EditProfileModel`, `EditProfileSheet`, `TranscriptionBacklogSection`,
`SyncReportSheet`. This was a design pass; the models and the two edit sheets did not need one.

## 9. The adversarial re-read — what a second pass found

Run as a distinct pass after the suite was green, against the phase's own diff. **Six findings, all six fixed** — four on the
first pass, two more on a second verification pass that re-read the tests as adversarially as
the code. Three of the six could not have been caught by any test, which is the point of the pass.

### F1 — The hero's outer 16pt was dead to touch — *fixed*

`ChildHeroCard` was built on `.cardSurface(fill:border:)`, which pads and *then* fills. That put the
padding **outside** the `Button`, so a ring of card 16pt wide — including the top-left corner, where
a thumb reaching for a 56pt avatar naturally lands — did nothing at all. Not a crash, not a visual
defect, and invisible to every test in the suite: the card looked right in both screenshots.

Fixed by giving `SettingsCard` a `fill` parameter and building the hero on it, so the content pads
*itself* inside the button — which is how every row on the screen already worked.

### F2 — `Advanced` could vanish for the life of a session — *fixed* (pre-existing, amplified)

`syncStatus` was built in `.task`, guarded on `syncEngine` being non-nil. `RootView` builds the
engine in *its* `.task`, so a render that reached Settings first left `syncEngine` nil, `.task`
never ran again, and `syncStatus` stayed nil permanently. The dry run, the reset, the pull toggle
and the position rows were then absent for the whole session with nothing on screen saying so —
a failure that is both terminal and silent.

**Found by running the app, not by reading it.** The screenshot harness sets Settings as the launch
tab, which is exactly the race, and the first frame came back with no `Advanced` card. Pre-existing
since PR #21, but the redesign makes it worse: it used to be some missing rows inside a card that
still had other content, and it is now an entire labelled card that is simply not there. Fixed with
`.onChange(of: syncEngine != nil, initial: true)`, which covers both orderings.

### F3 — VoiceOver read the outstanding count twice — *fixed*

`SettingsCardHeader`'s combined label was `[eyebrow, headline, detail, counter]`, which spoke
"…3 files still to upload. They'll finish on their own… **3 left**". The counter is the same number
the headline spells out in words. Dropped from the spoken label; it stays on screen, where it is a
glanceable summary rather than a repetition.

### F4 — A card summary was claiming to be a heading — *fixed*

`SettingsCardHeader` used `SectionLabel` for its eyebrow, and `SectionLabel` carries
`.accessibilityAddTraits(.isHeader)`. Combined into one element, that made the whole sync summary
appear in VoiceOver's heading rotor beside the real section names — so rotor navigation offered
"Uploading. 3 files still to upload…" as a landmark. The eyebrow is now a plain `Text` with the same
type role and no header trait. `SettingsSectionHeader`, which *is* a heading, still uses
`SectionLabel` and keeps the trait.

### F5 — `sync` had the identical late-arrival bug, and the redesign made it lie — *fixed*

Found on a second verification pass, by asking what *else* was captured the way `syncEngine` was.
`sync: EntrySync?` is handed down from the same `RootView` `@State`, and `refreshOutstanding()`
was called from the same run-once `.task`. Reach Settings before `RootView`'s task completes and
`outstanding` kept its default — all zeroes — which `syncSummary` reads as **clear**.

So the card said **"Everything's uploaded."** on the strength of never having looked, until
something backgrounded and foregrounded the app. That was survivable while it was a quiet
`SettingsValueRow`; F2's redesign promotes the same claim to the card's headline. Fixed the same
way: `.onChange(of: sync != nil, initial: true) { refreshOutstanding() }`.

Fixing one half of a two-instance bug and writing up the other half as "pre-existing, left alone"
was the wrong call the first time round. Both are fixed.

### F6 — Three defects in this phase's *own* tests — *fixed*

Found by re-reading the tests as adversarially as the code.

1. **An assertion that could not see the bug it was named for.** `birthdateDoesNotSlip` claimed to
   pin the timezone slip that once drew a June 1st birthday as May 31st, and asserted
   `rendered.contains("\(day)")`. For `2021-06-01` the slipped rendering is `May 31, 2021` — and
   `"May 31, 2021".contains("1")` is **true**, because of the "1" in "31". The test passed on the
   exact case it existed for. Now the day is matched as a whole numeric **token**
   (`text.split(whereSeparator: { !$0.isNumber })`) and the month is matched by name, derived
   through `FormatStyle` rather than the `DateFormatter` template the implementation uses.
   **Verified by breaking the code**: with a deliberate `-1 day`, all five cases now fail, and the
   `2021-06-01` case fails on both the day token and the month name independently.
2. **`try!` inside a non-throwing test.** Four of them. `#require` throws on failure, so `try!`
   turns a clean failure into a **crash that takes the process down** rather than a recorded
   issue. The function is `throws` and uses `try #require` now, which is what every other suite in
   this repo does.
3. **A test whose name described something it never did.** `noDoubleRun` — "a second run while one
   is running is refused" — ran once, checked the result, and dismissed. It never attempted a
   concurrent run. Split: `concurrentRunsAreRefused` now genuinely races two `run` calls with
   `async let` and asserts one request reaches the wire (deterministic, because `run` is
   `@MainActor` and claims `state = .running` synchronously before its first `await`), and
   `dismissReturnsToIdle` covers what the old test actually tested.

### Checked and clean

- **Cancellation under a real `URLSession`.** No async path was added or moved. `retry()`,
  `export.start`, `runDryRun()` and `RecomputeAgesModel.run` are untouched, so the phase introduces
  no new cancellation surface and nothing that behaves differently under a stub than under the real
  session.
- **Reachability, counted rather than assumed.** `EditChildSheet` had three entry points before
  (Name, Birthday, Timezone) and has three now (hero, Birthday, Timezone). The dry run was one tap
  from the Settings tab and still is. Nothing gained or lost a tap.
- **The `Retry now` row.** Present only while something is outstanding, and `outstanding` is
  refreshed *after* the sweep — so the row is still on screen, disabled and reading "Retrying",
  for the whole of the sweep, and disappears only once the sweep has actually cleared the queue.
- **`SettingsCard`'s new clip.** Applied before the border overlay, so the hairline is not clipped
  by its own card; the shadow is applied after and is unaffected.
- **One pre-existing condition, left alone and named.** With `sync` nil the card asserts
  "Everything's uploaded." from a default-constructed `Outstanding` — a claim it has not checked.
  The redesign makes it louder (a headline rather than a row value) but does not introduce it, and
  `RootView` always supplies a `sync`. Not changed, because changing it is behaviour rather than
  design and would need its own reasoning about what an unknown sync state should say.
