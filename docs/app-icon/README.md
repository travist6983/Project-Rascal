# The identity kit is superseded — Aug 27, 2026

**Everything in this directory whose filename starts `vellum-` draws a name this product no longer
has.** Phase 130 renamed Vellum to **Pocket Chronicle** on an attorney's trademark-conflict finding.

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
| `vellum-icon-fan.{svg,png}`, `vellum-icon-alt-{v,monogram}.svg` | Superseded. The fan carries the wordmark in the front card. |
| `generate-vellum.mjs` | Generates the **SVGs** above — its own header says it *"writes `vellum-*.svg` in this directory and nothing else"*, so `vellum-icon-fan.png` is **not** its output and must be re-exported by hand. Regenerating reproduces the dead name. |
| `index.html` | The identity page. Presents the above. |
| `rascal-icon-{fan,tinted,tonal}.svg`, `render-appicon.mjs`, `generate.mjs` | **Unaffected.** |

## What actually ships is unaffected

**The app icon on every phone carries no lettering at all.** `render-appicon.mjs:29` reads
`rascal-icon-fan.svg` — five fanned cards on terracotta, no wordmark, no type — and writes
`ios/Rascal/Rascal/Assets.xcassets/AppIcon.appiconset/AppIcon-1024.png`. That file is
name-neutral and needed no change for this rename, which is the third time that has paid off.

**Do not repoint `render-appicon.mjs` at a `vellum-*` file as a tidy-up.** `vellum-icon-fan.svg` is
the variant *with* the wordmark scaled into the front card; wiring it up would newly put the dead
name into the shipped pixels.

## What is owed

A drawn Pocket Chronicle lockup. Until it exists, `WordmarkView` (`ios/Rascal/Rascal/DesignSystem/
Wordmark.swift`) and the admin console's `.wordmark` both **set the name as type at the display
weight** — deliberately, and flagged in both files as a stopgap. When a mark arrives:

1. Draw it, export beside these files under a `pocket-chronicle-` prefix.
2. Port the path into `Wordmark.swift` as a `Shape`, keeping `WordmarkView(width:tint:)`.
3. Port the same path into `api/src/rascal/admin/static/index.html` and `cards.js`.
4. Delete this notice and the superseded files together, in one phase.
