repo: travist6983/Rascal-Marketing
branch: main

## Last sync

date: 2026-08-09T17:21:34Z

### Updated in this project

- Lifted the full token set (palette, type scale, easings, radii, shadows) from the marketing site's `styles.css` into `tokens/`.
- Copied both self-hosted variable webfonts (Nunito, Source Sans 3, latin subset) into `fonts/`.
- Built the RASCAL design system — guidelines, 16 components, and an app UI kit — on those tokens.
- Confirmed the repo contains no logo or icon assets; the system uses a type wordmark only.

## Screen map

| Screen / artifact | Built from |
| --- | --- |
| `tokens/*.css` | `styles.css`, `index.html` |
| `fonts/*.woff2` | `fonts/` |
| `guidelines/*.html` | `styles.css` |
| `components/**` | `styles.css` + the two founder app screenshots |
| `ui_kits/app/**` | Founder app screenshots (`assets/reference/`) + `RASCAL Onboarding.dc.html` |
