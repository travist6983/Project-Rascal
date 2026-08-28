> **⚠️ SUPERSEDED — added Aug 18, 2026. Do not follow the instruction below as written.**
> *"There is no logo image in any RASCAL source. Do not draw one"* was true on Aug 16, 2026 and is
> false now. **Phase 70 drew the mark and phase 77 drew the wordmark**, both in
> `docs/app-icon/`, and the app renders it as `WordmarkView` — drawn geometry, no font file.
> **Phase 78 adds the owner's rule, which this component's 0.14em tracked capitals now violate:
> the name is never set in capitals, and it is `Vellum`, not `RASCAL`.** Setting the letters is
> what phase 77 removed from the welcome screen precisely because a logo impersonated by type is
> the one spelling a case-sensitive rename cannot find. Kept unedited as a dated record.

> **⚠️ SUPERSEDED AGAIN, Aug 27, 2026 — appended below the Aug 18 note, which stands unedited.**
> **The name is `Pocket Chronicle`**, not `Vellum`; an attorney found a trademark conflict. The
> owner's no-capitals rule is unchanged and still forbids this component's 0.14em tracked capitals.
> **Two corrections to the note above, which is otherwise a true record of Aug 18, 2026:**
> `WordmarkView` is **no longer drawn geometry** — the mark spelled the retired name in six
> letterforms and cannot be re-lettered into two words, so it sets type at the display weight until
> a real lockup is drawn (`ios/Rascal/Rascal/DesignSystem/Wordmark.swift`); and the assets under
> `docs/app-icon/` are superseded wholesale, per the README there.

The wordmark. Use this instead of typing the letters — it pins the 0.14em tracking.

```jsx
<Wordmark size={19} />
```

There is no logo image in any RASCAL source. Do not draw one, and do not
substitute an icon; where a mark would go, this component goes.
