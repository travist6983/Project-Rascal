# RASCAL iOS — standing rules

The client for the archive. This is the iOS lane of a two-lane repo: **never edit `api/`.**
If a screen needs something the API does not serve, that is a conversation, not a patch to
the backend — say so and stop.

`docs/api-contract.md` is the contract, and it is authoritative. Read it rather than
guessing, and prefer `ios/Fixtures/*.json` — real captured responses, refreshed by
`make fixtures` from the repo root — when you need to know the exact JSON shape.

## The rules. Violating any of these is a defect.

1. **The server is the source of truth.** SwiftData is a local cache and nothing more. It
   never computes what was assigned, whether something expired, or what day it is — those
   are server answers rendered in the child's `family_timezone`. A client that decides "it
   is a new day" has already broken the archive.
2. **`occurred_at` and `created_at` are never conflated.** Backdating is a first-class flow,
   not an edge case. The timeline sorts by `occurred_at`; sync filters on `updated_at`. A
   view that shows "when it was uploaded" where the parent expects "when it happened" is
   wrong.
3. **Three completion shapes: did it, captured it, wrote it.** Any model, schema, or view
   that assumes an entry has media is wrong. "Get on the floor for ten minutes" is a
   complete, legitimate entry with no artifact, and it must render as one — not as an empty
   photo frame.
4. **No third-party dependencies.** No SPM packages, no CocoaPods, no vendored source.
   URLSession, SwiftUI, SwiftData, and the standard library. If that seems impossible for
   something, it is a signal the something is out of scope.
5. **Config comes from `Config.xcconfig` via Info.plist.** No hardcoded base URL, no
   hardcoded UUID, no `#if DEBUG let host = "..."` anywhere in Swift source. Copy
   `Config.xcconfig.example` to start; the real file is gitignored.

## Tone — these are product rules, not preferences

- **No streaks, no confetti, no guilt copy, no red urgency states.** A missed day is not a
  failure and the app never says it was. Nothing counts down, nothing scolds, nothing
  celebrates compliance. A parent who opens this after two weeks away should feel welcomed
  back, not audited.
- **Never pure black, never pure white.** `#000` and `#FFF` are not in the palette. The
  canvas is cream `#FDFAF4` and the ink is navy-charcoal `#23253C`.
- **The design system lives in `docs/design-system.md` and it is the authority for writing
  SwiftUI.** Read it before styling anything. It defines the full palette, type scale,
  shape and elevation, the component specs (`PromptCard`, `EntryCard`, `Chip`,
  `FloatingTabBar`, `DatePill`, `AudioRecorder`, `CompletionCheck`), motion, layout, copy
  rules, and an explicit anti-pattern list. Do not invent a token it already defines, and
  ask rather than improvise one it does not.
- **Color carries meaning, it is not decoration.** Terracotta is missions, photo/video,
  primary action. Periwinkle is questions, voice, secondary. Sage is did-it entries. A
  question card styled terracotta "because it's the brand color" is a defect.

## Settled — do not relitigate

`docs/decisions.md` is closed. SwiftUI, SwiftData, no dependencies, and the tone rules above
are decisions, not opening positions. If one seems wrong, raise it — do not route around it.

## Out of scope — stop if you find yourself building one

An Android or web client, a design system package, push notifications, offline media
transcoding, analytics, a login screen for anything other than Sign in with Apple and
`dev-login`, multi-kid switching UI beyond what `GET /children` already returns.

## Working here

Auth for phase one is `POST /v1/auth/dev-login`, documented in `docs/api-contract.md`. It
returns a token pair and a user — **not a child.** Get the child from `GET /v1/children`.
It exists only when the API runs with `ENVIRONMENT=local` and is `404` in production, so
nothing that ships may depend on it.
