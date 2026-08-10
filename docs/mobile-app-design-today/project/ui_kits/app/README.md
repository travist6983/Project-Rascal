# UI kit — RASCAL iOS app (v2)

A click-through recreation of the shipped app. Open `index.html`: it boots on
**Today**, and the tab bar plus the FAB move between all four surfaces. The
capture screen records (fake), the take lands on the timeline with the settle
animation, and the entry keeps its age stamp.

## Fidelity

| Screen | Source | Confidence |
| --- | --- | --- |
| `Today.jsx` | Founder screenshot (`uploads/IMG_2116.png`) | Measured — tints, badge fills, 22px gutter, floating tab bar, 38px title |
| `Capture.jsx` | Founder screenshot (`uploads/IMG_2117.png`) + the onboarding flow | Measured for chrome; the waveform's exact bar count is approximate |
| `TimelineScreen.jsx` | **Inferred.** No screenshot exists. | Composed from `TimelineEntry`, the age-stamp rule, and the marketing site's timeline section |
| `Settings.jsx` | **Inferred.** No screenshot exists. | Composed from system rules; the notification row reflects the real one-nudge policy |

Two screens are inferred rather than copied — they are marked above and should be
replaced the moment real screens exist. Nothing here invents a new visual idea;
inferred screens only recombine documented parts.

## Notes

- Every screen sits inside `AppShell`, which supplies the 393×852 frame, the
  paper grain, the iOS status bar, and `position: relative` for the tab bar.
- Screens compose `components/` primitives; nothing is re-implemented locally.
- No empty, error, or loading states — none exist in any source (see root readme
  CAVEATS).
