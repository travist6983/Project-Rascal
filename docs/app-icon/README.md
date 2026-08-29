# The identity kit is superseded — Aug 27, 2026

**Everything in this directory whose filename starts `vellum-` draws a name this product no longer
has.** Phase 130 renamed Vellum to **Pocket Chronicle** on an attorney's trademark-conflict finding.

**Aug 29, 2026 — the app icon half of "what is owed" below is done.** `pocket-chronicle-icon-fan.svg`
(wordless) and `pocket-chronicle-icon-fan-lockup.svg` (wordmark drawn into the front card, full
"pocket chronicle" in the same monoline stroke style as the old six-letter mark) both exist now.
The rest of the kit — `vellum-wordmark.svg`, `vellum-mark.svg`, the logo lockups — is untouched and
still superseded; only the icon was in scope for this pass. See the updated table and "What is
owed" below for what that leaves open.

## Why the files were not renamed

A file called `pocket-chronicle-wordmark.svg` whose path spells *Vellum* is worse than one named
`vellum-wordmark.svg` that spells *Vellum*. The wordmark is **geometry, not type** — six letterforms
across a `531.5 × 126` viewBox — so it cannot be re-lettered by editing a string. Renaming the files
without redrawing them would make the tree *look* renamed and hand the next reader a lockup that
contradicts its own filename.

So the names stay until somebody draws the new mark. **Treat every `vellum-*` file here as a
historical artefact of the Vellum identity, not as current brand assets.**

| File | Status |
|---|---|
| `vellum-wordmark.svg`, `vellum-wordmark-options.svg` | Superseded. Spells the dead name. |
| `vellum-mark.svg`, `vellum-mark-compact.svg` | Superseded. |
| `vellum-logo-{horizontal,stacked,mono}.svg`, `vellum-logo-hover.html` | Superseded — all lockups pair the mark with the dead wordmark. |
| `vellum-icon-fan.{svg,png}`, `vellum-icon-alt-{v,monogram}.svg` | Superseded, kept as a historical record of the Vellum identity. The fan carries the wordmark in the front card. |
| `generate-vellum.mjs` | Generates the **SVGs** above — its own header says it *"writes `vellum-*.svg` in this directory and nothing else"*, so `vellum-icon-fan.png` is **not** its output and must be re-exported by hand. Regenerating reproduces the dead name. |
| `index.html` | The identity page. Presents the above. Still shows the Vellum kit — not updated by this pass. |
| `rascal-icon-{fan,tinted,tonal}.svg` | **Gone.** Deleted Aug 29, 2026 (`dac8b64`, "remove old icons") along with two other now-dead-name files. Superseded by the two `pocket-chronicle-icon-fan*.svg` files below, not restored. |
| `pocket-chronicle-icon-fan.svg` | **New, Aug 29, 2026.** Wordless — the same five-card fan, no lettering. `render-appicon.mjs` reads this now. |
| `pocket-chronicle-icon-fan-lockup.svg` | **New, Aug 29, 2026.** Same fan, with "pocket chronicle" drawn into the front card in the original mark's monoline stroke style (scaled down to fit two words where the old mark drew six letters). Identity-kit asset only — not read by any build step. |
| `render-appicon.mjs`, `generate.mjs` | `render-appicon.mjs` repointed at `pocket-chronicle-icon-fan.svg` Aug 29, 2026. `generate.mjs` unaffected. |

## What actually ships

**The app icon on every phone carries no lettering at all.** `render-appicon.mjs` reads
`pocket-chronicle-icon-fan.svg` — five fanned cards on terracotta, no wordmark, no type — and
writes `ios/Rascal/Rascal/Assets.xcassets/AppIcon.appiconset/AppIcon-1024.png`. That file stayed
name-neutral through the Dogear→Vellum rename and this one, which is the third time it's paid off —
but note the *source* changed today: it used to be `rascal-icon-fan.svg`, which no longer exists
(deleted in the same commit that made this repointing necessary). **This pass did not re-run
`render-appicon.mjs`** — the script is fixed and ready, but running it rewrites a committed iOS
asset while a build is sitting "Ready for Review" in App Store Connect (`decisions.md` item 18), so
that's left for whoever owns that submission to trigger deliberately.

**Do not repoint `render-appicon.mjs` at a `vellum-*` file as a tidy-up.** `vellum-icon-fan.svg` is
the variant *with the dead name* scaled into the front card; wiring it up would put "Vellum" into
the shipped pixels. The equivalent worded file for the current name is
`pocket-chronicle-icon-fan-lockup.svg`, and it isn't wired up either — see below.

## What is owed

**The icon is drawn now** (`pocket-chronicle-icon-fan-lockup.svg`), but a lockup existing here isn't
the same as it being used. `WordmarkView` (`ios/Rascal/Rascal/DesignSystem/Wordmark.swift`) and the
admin console's `.wordmark` still both **set the name as type at the display weight** — deliberately,
and flagged in both files as a stopgap — because porting a hand-drawn path into either one is real
code work in a lane this pass didn't touch. What's left:

1. ~~Draw it, export beside these files under a `pocket-chronicle-` prefix.~~ Done Aug 29, 2026.
2. Port the path into `Wordmark.swift` as a `Shape`, keeping `WordmarkView(width:tint:)`. **iOS-lane
   work, not done.**
3. Port the same path into `api/src/rascal/admin/static/index.html` and `cards.js`. **API-lane
   work, not done.**
4. Once 2 and 3 ship, decide whether `render-appicon.mjs` should move to the lockup variant or stay
   wordless — that's a design call for whoever's holding the icon at that point, not a foregone
   conclusion just because a mark now exists.
5. Delete this notice and the superseded `vellum-*` files together, in one phase — not yet, since
   the kit as a whole (wordmark, mark, logo lockups) is still undrawn.
