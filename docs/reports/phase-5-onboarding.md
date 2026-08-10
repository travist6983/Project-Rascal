# iOS — Onboarding & account creation

Branch `ios/phase-5-onboarding`, off `main` at `2a8d802`. Written **Aug 9, 2026.**

**Read this section first if you read nothing else.** The design export at
`docs/mobile-app-design-onboarding/` describes a *different flow* from the one this run built,
and the difference was settled by you mid-run rather than by me guessing. Sign in with Apple has
never been executed against Apple — not once, on any device — because enrollment has not cleared.
Everything below distinguishes what was run from what was reasoned.

---

## What the run had to resolve before it could start

The build prompt (§3, §6) and the design export disagree about the shape of onboarding.

| | Design export | Build prompt §3/§6 |
|---|---|---|
| Sequence | cold open → name → birthdate → motive fork → tonight's mission → record audio → payoff → **soft wall (Apple, deferred)** → notification permission → home | welcome → **Apple first** → name → birthdate → **timezone** → **avatar** → Today |
| Account | Optional. "Keep going without it" keeps everything on-device | Required before anything is created |
| Timezone | absent | its own step |
| Avatar | absent | its own step |

Building the export as drawn would have required four things the prompt forbids or the project
rules prohibit: anonymous local-first entries, **client-side prompt selection** (standing rule 1 —
the server owns assignment), a push-notification permission screen (§3 out of scope, and
`ios/CLAUDE.md` out of scope), and audio capture during onboarding (§3 out of scope).

**You chose the prompt's scope with the design's skin.** That is what was built. Dropped from the
export: the motive fork, the mission and record beats, the notification screen, and the anonymous
path. Kept: its visual language, its sequencing idiom, the progress rail, the birthdate wheel with
a live age chip, and its cold-open copy.

---

## Preflight

Every gate passed. Recorded because §2 asks for the results, not the verdict.

| # | Check | Result |
|---|---|---|
| 1 | Tree clean, base up to date | `main` was stale locally; fast-forwarded to `origin/main` `2a8d802` |
| 2 | CI green on `main` | iOS ✅ and CI ✅ at `2a8d802` |
| 3 | Phase 4 merged | PR #19, Aug 9 |
| 4 | `docs/decisions.md` read | in full |
| 5 | `DESIGN_SOURCE_PATH` | `docs/mobile-app-design-onboarding/`, **101 files**, supplied by you rather than guessed |
| 6 | Zero warnings before any change | **0**, from a deleted `DerivedData` |
| 7 | Existing suite | **354 passing**, 42 suites |
| 8 | API reachable | `/health` 200; `POST /v1/auth/dev-login` returned a session |
| 9 | **Avatar upload endpoint** | **Absent** — see below |
| 10 | `Palette` exists | `DesignSystem/Palette.swift`, incl. `Gradients.wash` already reserved for onboarding |
| 11 | **`display_name` write semantics** | **Confirmed correct** — see below |

### #11 — `POST /v1/auth/apple`, read and confirmed

**This is a confirmed reading of the source, not an inference.** Nothing under `api/` was
modified; the handler was read only.

`api/src/rascal/routers/auth.py:38` delegates to `user_for_credential` in
`api/src/rascal/services/auth.py:20-53`, which satisfies all three requirements of §4.2:

1. **Looks up by credential first** — `select(Credential).where(Credential.provider == provider,
   Credential.subject_id == subject_id)`, and only constructs a `User` when that returns nothing.
2. **First-write-wins** — `if user.display_name is None and display_name:` (line 43). An existing
   non-null value is never reassigned.
3. **Never null-overwrites** — the same `and display_name` guard means an absent or null
   `display_name` in the request body leaves the stored value untouched.

No `docs/blocked.md` entry was needed for §4.2. The client-side half is built to match, and is
the part this run is responsible for.

### #9 — there is no way to upload an avatar

`children.avatar_key` exists (`0001_initial.py:73`, `models/child.py:21`) and
`PATCH /children/{id}` accepts it (`schemas/child.py:33`). **Nothing mints a key.** The only
presign route is `POST /media/upload-url`, whose `UploadUrlRequest.entry_id` is required
(`schemas/media.py:16`) and whose access check is `entry_access_from_body`, so every presigned
destination belongs to an entry. Registered routers were enumerated from `main.py:58-73`; there is
no child-scoped upload route.

Phase D therefore took the **endpoint-absent** branch. Avatar bytes were **not** sent through the
entry-scoped route — doing so would file a picture of a child in the archive as an entry's
artifact, which is worse than not uploading it. Written up in `docs/blocked.md`.

---

## What was built

Nine new files under `ios/Rascal/Rascal/Onboarding/` (1,679 lines) and two test files (896 lines).

**Phase A — the gate.** `SessionState` is the four cases §4 specifies — `loading`, `signedOut`,
`needsChild`, `ready(ChildResponse)` — and no failure case. A failure here is never a *place* the
app is in; it is something that just happened at the step the parent is already standing on. So
failures ride alongside as `notice` and `resolveFailed`, which is what lets a lost connection
leave every typed character where it was.

- **One session object.** `OnboardingGate` owns the single `AppSession` and hands the same
  instance to `RootView`. There is no second `APIClient` and no second refresh path — two would
  race a rotating refresh token against itself, which is the forced-logout bug `APIClient`'s own
  comments are about.
- **`loading` does not flash.** The indicator is *scheduled* for 150ms and cancelled if the answer
  beats it, so a warm launch shows the launch canvas and then Today.
- **Revocation** is checked with `getCredentialState` on every launch that has a stored Apple
  subject. `.revoked`/`.notFound` return to `signedOut` cleanly. `.unknown` deliberately **keeps**
  the session — that call needs the network, and signing someone out of their own archive because
  a train went into a tunnel is the worse failure.

**Phase A/4.1 — the `fullName` problem.** `.fullName` and `.email` are requested on *every*
authorization. `display_name` is forwarded when present and the key is **omitted entirely** when
not — never null, never `""`. A blank `PersonNameComponents` (which Apple does return) is
converted to `nil` at the boundary in `AppleCredentialInput.init?`. The full request payload is
held in memory as `pendingExchange` and retried verbatim on failure; re-prompting Apple would
return `fullName: nil` and lose the name permanently. It is cleared on success and never written
to disk — there is a test that greps UserDefaults to prove it. No "what's your name?" screen was
added.

**Phase C — child creation.** Name trimmed and capped at the server's 200. Birthdate is a
`yyyy-MM-dd` string end to end. Future dates are refused inline, quietly, with the Continue button
disabled — the picker is deliberately **not** range-limited, because a control that cannot express
a wrong answer cannot tell the parent they gave one. Timezone defaults to
`TimeZone.current.identifier`, is presented as a confirmation with a Change affordance, and is
sent as an IANA identifier.

The **duplicate-child guard** is the part worth reviewing. `POST /children` has no
`Idempotency-Key` (unlike `POST /entries`), so a create whose *response* is lost has still created
a child. Before surfacing a retry, `createChild` asks `GET /children`; if a child is there, the
create worked and only the answer went missing, so it is adopted. Both halves are tested.

**Phase D — avatar.** `PhotosPicker` plus camera, centre square crop, and HEIC→JPEG through the
**existing** `ImagePipeline` (not reimplemented). Persisted locally by `LocalAvatarStore`.
Deliberately *not* in `StagingStore`: that directory is excluded from iCloud backup because it
holds transient copies of photos the library already has, and an avatar with nowhere to upload to
is the only copy in existence. Same conventions, reverse backup flag.

---

## Verified by running it

### Tests — 392 passing in 44 suites, zero warnings

354 before, **38 added**. Run cold from a deleted `DerivedData`; the log contains **zero**
occurrences of `: warning:` from any source.

Three of the new tests failed on first run and all three were real:

1. **The guard did not adopt the child.** My fixture fed `GET /children` a single object where it
   returns a *list*, so decoding failed inside the `try?` and the adopt silently did nothing. That
   is exactly how this guard fails in production, so the two shapes now have separate fixtures and
   the test asserts the observed method sequence rather than trusting it.
2. **Byte-for-byte payload comparison.** `JSONEncoder` makes no promise about key *order*, so two
   encodings of identical values differed as bytes. The assertion now compares the decoded fields
   and the key set, which is what "identical payload" actually means.
3. **A state assertion of mine was wrong about the setup**, not the code — the test called
   `signIn` without first calling `resume`, so it was asserting from `.loading` rather than from
   the welcome screen a parent would really be on. The setup was corrected; the assertion stands.

No assertion was weakened to make the suite green.

**A fourth was found by CI, and my machine could not have found it.** The first CI run failed on
`the default timezone is a resolvable IANA identifier`. The runner's simulator is in **GMT**, where
`TimeZone.current.identifier` is the string `"GMT"` — and the test asserted that no identifier
starts with `"GMT"`, that none contains a hyphen, and that all are longer than four characters.

All three are false. `GMT` is a real IANA zone; `America/Port-au-Prince` is hyphenated, so that
rule would have failed for anyone actually living there; and the length rule fails for every legacy
singleton. Worse, the assertion those three were propping up was the weak one —
`TimeZone(identifier:)` returns a zone for `GMT-4`, `PST` and `UTC+1`, so a non-nil check passes for
exactly the offsets and abbreviations it was supposed to exclude.

Verified empirically rather than guessed a second time: membership in `knownTimeZoneIdentifiers` is
the only check that discriminates, and it draws the same line the server does — `zone()` accepts
`GMT` and rejects `EDT`. The test is now that membership check plus a second test pinning both
sides, including the fact that most of the wrong values *do* resolve. **The product code was never
wrong and is unchanged**: §6 says default to `TimeZone.current.identifier`, and it does.

Local runs cannot reproduce this — my machine is in `America/Detroit`, so the GMT path is
unreachable here. That is worth knowing for the next timezone-adjacent test.

### On the simulator, against the live API

Driven by a temporary harness (deleted before commit; `RascalApp.swift` was backed up with `cp`
and restored from it) because the simulator cannot be tapped from the command line.

- **Fresh-install first run** — a brand-new dev-login account with no child: `resume` →
  `needsChild` → `createChild` → `ready`. The server answered `ageMonths: 49`, independently
  matching the client's "4 years, 1 month" echo. Landed on a working Today. `e2e-fresh-today.png`
- **Returning user** — the `dev@rascal.local` fixture account: `resume` → `ready(Hendrix,
  ca5dda95…)` directly. **Child creation was skipped entirely**, and `POST /children` was never
  called.
- **Cold relaunch, real app, no harness** — installed **over** the existing app rather than
  uninstalling, which is also the `ios/CLAUDE.md` rule 6 in-place migration check. Launched
  straight onto Today with the stored session, five waiting assignments, no sign-in prompt and no
  flash of onboarding. `real-cold-relaunch.png`
- **`dev-login` still works and is still reachable** — it is the "Use the development account"
  button on the welcome screen, and it is what both runs above used.

### Dynamic Type XXL — five screenshots, and I looked at all five

`content_size extra-extra-large`. Attached: `xxl-welcome.png`, `xxl-name.png`,
`xxl-birthdate.png`, `xxl-timezone.png`, `xxl-avatar.png`.

**No clipped or truncated text on any screen.** Headings wrap to two lines and the layouts absorb
it. Looking at them caught one real defect that no test would have: the timezone card printed the
region "America" directly under the sentence "We'll use America/Detroit for daily prompts." That
was fixed by dropping the redundant line.

---

## Verified by reading, not by running — be suspicious of these

**Sign in with Apple has never run.** Not on a device, not in the simulator, not once. Apple
Developer Program enrollment has not cleared, so the entitlement does not exist and
`ASAuthorizationController` cannot succeed. Everything below the `AppleCredentialInput` seam is
asserted against constructed values; everything above it — the real `ASAuthorizationAppleIDCredential`
mapping, `getCredentialState`, and whether Apple's JWKS verification accepts our token — is
**unverified**. This is the largest untested surface in the run and it is the whole point of the
feature.

**The VoiceOver audit is a source audit.** I read every view's modifiers and enumerated the
controls below. I did **not** run VoiceOver and capture what it speaks — there is no UI test
target to drive it from and no CLI that reports the accessibility tree. Treat this as "the labels
are set" and not as "the labels sound right".

| Screen | Interactive controls and their labels | Marked decorative |
|---|---|---|
| Welcome | Sign in with Apple (system-provided label); "Use the development account"; "Try again" when an exchange is held | gradient wash `.accessibilityHidden` |
| Name | text field → "Your kid's first name"; "Continue" | terracotta underline `.accessibilityHidden` |
| Birthdate | "Back"; date picker → "Birthdate"; "Continue" | — |
| Timezone | "Back"; "Change" + hint "Pick a different timezone"; "Continue" | — |
| Avatar | "Back"; "Choose a photo"/"Choose another"; "Take a photo"; "Finish setup"/"Save and finish"; "Skip for now"/"Remove photo" | preview circle `.accessibilityHidden` |
| Failure | "Try again" | glyph `.accessibilityHidden` |

Non-obvious ones worth naming: the progress rail is one element labelled "Setup progress" with
value "Step 2 of 4" rather than four unlabelled bars; the age chip is `children: .ignore` with
label "Today, 4 years 1 month old", because "4y 1m" read literally is noise; headings carry
`.isHeader`.

**No XCUITest was written.** The project has exactly two targets — the app and a unit-test bundle
(`project.pbxproj:98,121`) — and no UI-test target exists. Creating one is `project.pbxproj`
surgery, which `ios/CLAUDE.md` warns about specifically. §8's "UI test covering the full first-run
flow" is instead covered at the model level by `firstRunEndToEnd`, which drives the real
`OnboardingSession` through sign-in, all four steps and one create, and by the simulator runs
above. **This is a substitution, not a completion.** Adding an XCUITest target is a reasonable
follow-up and it is not in this branch.

---

## Deviations from the design export

`docs/design-system.md` says in its own second paragraph that it wins over a mockup, and
`ios/CLAUDE.md` names it the authority for writing SwiftUI. So tokens came from the design system
and layout/copy/sequencing/motion came from the export. Every substitution:

| Export | Used instead | Why |
|---|---|---|
| `#D9CFC2` disabled button fill | `chipPlain` under `inkFaint` | **No `Palette` equivalent.** §5 says report rather than add a token. Nearest existing pair; reads the same — waiting, not an error |
| `#F6EEE6` wheel selection band | system `DatePicker` wheel | No `Palette` equivalent (`chipPlain` is `#F4EEE5`, two values away). Using the system picker also gets Dynamic Type and VoiceOver for free |
| 40px / 32px headlines | `.display` (34) / `.screenTitle` (29) | The type scale is tokenized and authoritative |
| 19px button padding | existing `PrimaryButtonStyle` geometry | Consistency with every other button in the shipped app |
| 30px screen margin | `OnboardingLayout.margin = 28` | `Layout.screenMargin` is 16 and tuned for card lists; a 34pt headline needs more. Kept local to onboarding rather than added as a global token |

**Copy that was changed, and why — flagged rather than silently rewritten.**

- **The export's copy is he/him throughout** — "What's *his* name?", "stamps every entry with
  *his* exact age", "hear *him* at four". The API lane's rules are explicit that the *seeded
  library* is he/him on purpose but "client-side strings are already neutral and stay that way".
  All onboarding copy was written neutral. The export's headline and subhead were already neutral
  and were kept verbatim.
- **"No account yet. Nothing to set up."** was dropped. Under the chosen sequencing it would be a
  lie — the welcome screen's only action *is* signing in. Replaced with "Your archive is tied to
  your Apple ID. There's nothing else to set up."
- Nothing in the export used *precious*, *cherish*, *treasure*, or *little moments*. The soft
  wall's "it won't survive a new phone until you sign in" is mild loss-aversion, which is the
  closest thing to a tone conflict in the file — moot here, since that screen was not built.

---

## Defects and open items

1. **`SignInWithAppleButton` uses `.black`, and the palette says never pure black.** It is a
   system-mandated control whose styling Apple restricts to black / white / white-outline; the
   export drew it in ink `#23253C`, which is not an option the API offers. Flagged rather than
   worked around — tinting it would be a HIG violation on the one control Apple polices.
2. **`dev-login` is visible in Release builds.** It is *reachable*, which is what §3 and the
   completion criteria require, and the route 404s anywhere that is not `ENVIRONMENT=local`. It
   was deliberately not `#if DEBUG`-gated, because that would have changed existing behaviour and
   removed the only way into a TestFlight build before enrollment clears. **It must be gated
   before App Store submission.** Not done here; out of scope.
3. **One redundant `GET /children` at the handoff.** The gate resolves the child, then `RootView`
   runs its own unchanged `AppSession.start()` and resolves it again. This is the price of keeping
   `RootView` at a one-line change and `MeTests`' assertions untouched. One request on a launch
   that is already making several.
4. **Open item 10 (pronouns) is *not* closed, and `docs/decisions.md` says onboarding is where it
   should be.** It cannot be closed from this lane: `children` has no pronouns column
   (`models/child.py`), so there is nowhere to put the answer. Adding one is a Lane A change.
   Recorded in `docs/blocked.md`. Onboarding copy is neutral in the meantime, so nothing regressed
   — but the unlock that item 10 is waiting for did not happen.
5. **Nothing displays the avatar.** It is captured, cropped, converted and stored — and no screen
   reads it back. §3 scopes Phase D to "capture, crop, and local persistence" and does not include
   rendering it, so this run did not widen to Today or Settings to show it. The effect is that a
   parent can add a photo during setup and never see it again. Deliberate scope discipline rather
   than an oversight, but it is a real product gap and it is one small change to close — the store
   is `LocalAvatarStore(...).load(for: childId)` and it returns JPEG bytes.
6. **Phase 5 is a name collision.** PR #22 already shipped as "iOS Phase 5 — Audio capture". This
   branch is `ios/phase-5-onboarding` as specified, but the phase numbering in this repo now has
   two fives.

---

## Files touched outside `Onboarding/`

Four files, **31 insertions and 3 deletions**, of which 20 lines are comments.

| File | Change |
|---|---|
| `RascalApp.swift` | `RootView()` → `OnboardingGate()`. One line |
| `App/RootView.swift` | `@State private var session = AppSession.live()` → `let session: AppSession`, so the gate owns the one session. One line |
| `Networking/APIClient.swift` | Added `signInWithApple`. It lives here rather than in an extension because `tokens` is file-private and this is where `devLogin` saves a pair |
| `Networking/RascalAPI.swift` | `ChildResponse` gains `Equatable, Sendable`, so `SessionState` can be compared. One line |

`docs/roadmap-status.md` is modified in the working tree by something other than this run and was
deliberately left alone and out of the commit.
