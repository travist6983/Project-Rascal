# Claude Code — iOS Phase 14: Push Notifications (client)

**Repo:** `travist6983/Project-Rascal`
**Branch:** `ios/phase-14-push`, **off `main`**
**Lane:** iOS only. **No `api/` changes** — the endpoints ship in the Lane A push branch.
**Run mode:** fully autonomous, unattended. Resolve ambiguity by matching existing code, record every such call in the PR under **Judgment calls**, and keep going.

---

## Mission

The last unbuilt P1 retention lever. The widget shows today's mission if you look; the notification is what makes you look.

The server decides *when* and *whether*. The client asks for permission, registers a token, and handles what arrives. **It computes nothing** — no scheduling, no local notifications, no client-side "today."

This phase touches two surfaces: **onboarding**, which gains a final permission step, and **Settings v2**, which gains a preference row.

---

## Preflight — hard stop

Any failure: stop, write `docs/blocked.md` with exact output, open a draft PR, do not proceed.

1. `main` green, **working tree clean.** Settings v2 (phase 13) and onboarding (PR #27) must both be merged — this phase modifies both.
2. **The iOS workflow is dispatch-only** since PR #33. Run the suite locally, cold, from a deleted `DerivedData`, with `CODE_SIGNING_ALLOWED=NO`. Record test and suite counts. Do not carry a count forward and do not assume CI ran.
3. Baseline builds with **zero warnings** before any change. An incremental build under-reports warnings.
4. Read `docs/decisions.md` in full.
5. **`POST /v1/devices`, `DELETE /v1/devices/{token}`, and the notification preference fields on `GET /me` and `PATCH /v1/me` are live.** If any is absent, stop — do not build against a shape you inferred, and do not ship UI behind a flag with nothing behind it.
6. Read the widget's URL-scheme and deep-link handling. **You are reusing it, not writing a second router.**
7. Read `OnboardingGate` and the onboarding step sequence, and read the Settings v2 structure and its inventory doc, before changing either.

---

## Phase A — The permission ask

### The rule that governs everything here

**iOS grants exactly one system permission prompt, ever.** A denial is effectively permanent — recovery requires the parent finding the toggle in iOS Settings, which almost nobody does.

So the system prompt is **never fired directly.** It is fired only after the parent has already said yes to an in-app screen. This is not a dark pattern; it is what keeps a "not right now" from becoming a permanent no.

### Where it goes

**The last step of onboarding**, after avatar, before landing on Today.

One screen, in the onboarding design's existing vocabulary:

- Plain statement of what happens: one notification a day, carrying that day's mission. Not two. Off whenever you want.
- The default send time shown **inline**, with a change affordance. Do not add a second screen for the time picker.
- State that the time resolves in the child's timezone — a parent travelling will otherwise think it broke.
- Two actions: **Turn it on** and **Not now**, given equal visual weight. No urgency, no guilt copy, no "you'll miss out."

### What each action does

- **Turn it on** → fire the system prompt. If granted, register and `PATCH /v1/me` with `notify_enabled = true` and the chosen time. If the system prompt is denied, record that and proceed to Today. Do not retry, do not explain, do not soften it.
- **Not now** → **do not fire the system prompt.** The one-shot is preserved. Proceed to Today with `notify_enabled` false.

### Re-offering

- **"Not now" may be offered again exactly once**, after the first completed entry, in the same soft form. The parent has now experienced the loop and the offer means something.
- The Settings row can always fire the soft ask, and through it the system prompt, as long as the system prompt has never been denied.
- **Once the system prompt itself has been denied, never ask again by any mechanism** — not in Settings, not after an entry, not ever. Settings explains where the iOS toggle is and the app behaves identically otherwise. A denied permission is a valid steady state, not a funnel to recover.
- Re-check authorization status on foreground. A parent who enables it in iOS Settings later should have the token registered without being asked anything.

### Skipping is free

Onboarding completes identically whether they turned it on or not. No step is blocking, no screen is un-dismissable, and nothing about the app degrades.

---

## Phase B — Token registration

- Register with APNs on launch when authorized, and post the token to `POST /v1/devices`.
- **Send the correct `environment`.** Debug builds are `sandbox`; TestFlight and App Store are `production`. Derive it from the build configuration, never a hardcoded value. Getting this wrong produces a feature that works in development and silently fails in TestFlight, with nothing in the logs to explain it.
- Tokens rotate. Re-register on every launch; the endpoint is idempotent.
- **On sign-out, call `DELETE /v1/devices/{token}` before clearing the session.** A signed-out device still receiving notifications is a real defect.
- Registration failure is non-fatal and silent. It never blocks launch, never blocks onboarding, and never shows an error.

---

## Phase C — Handling and deep link

- Foreground presentation: today's mission arriving while the parent is looking at Today should not banner over it. Suppress in the foreground, or present quietly — pick one and justify it in `docs/decisions.md`.
- Tapping opens the composer for the assignment in the payload. **Reuse the widget's deep-link route.**
- **A stale or unknown assignment ID lands on Today, never on a broken composer.** The widget already has this rule; do not implement a second version of it.
- A notification tapped for an already-completed assignment opens the entry it produced if that is cheap, otherwise Today.

---

## Phase D — The Settings row

Settings v2 just landed. Add the minimum that belongs there, in its vocabulary — **do not restructure it.**

- A toggle bound to `notify_enabled`.
- A time picker bound to `notify_local_time`, stating which timezone it resolves in.
- If the parent chose "Not now" during onboarding, the toggle fires the soft ask, then the system prompt.
- If the **system** prompt was denied, the toggle reads as unavailable and explains where the iOS setting lives — it must not appear on and silently do nothing.
- Writes go through `PATCH /v1/me`. **No local scheduling, no `UNUserNotificationCenter` scheduling of any kind.** The server owns this.

---

## Explicitly out of scope

- Any `api/` change.
- Local notifications, badges, sounds beyond default, rich notifications, actions, categories, provisional authorization.
- More than one notification per day under any name.
- Timeline, Moments, Today, the composer, capture, `Sync/`, the widget, the share extension — beyond reusing the deep-link route.
- Any change to onboarding beyond adding the final permission step.
- Re-prompting after a system-level denial, by any mechanism.
- The name decision, structured extraction, video audio tracks.

---

## Tests

Put the logic in testable types and keep the views dumb.

- **"Not now" does not fire the system prompt** — the single most important assertion in this phase.
- "Turn it on" fires it exactly once.
- Onboarding completes and lands on Today in all three cases: granted, denied, and "not now."
- "Not now" is re-offered exactly once, after the first completed entry, and not again.
- **A system-level denial is never re-prompted** by onboarding, by the post-entry offer, or by the Settings toggle.
- A parent who enables it in iOS Settings later gets a token registered on foreground without being asked.
- `environment` resolves to `sandbox` in debug and `production` in release — asserted, not assumed.
- Sign-out revokes the device before clearing the session, in that order.
- Registration failure blocks neither launch nor onboarding and surfaces no error.
- A payload with a valid assignment ID routes to the composer; unknown and stale IDs route to Today.
- The Settings toggle reflects a denied system permission rather than showing an enabled state that does nothing.
- Preference writes go through `PATCH /v1/me` and nothing schedules locally.

Verify handling with `xcrun simctl push` against a payload file matching the server's shape. **This is the one part of push a simulator genuinely exercises** — use it, and attach the payload file to the PR.

**Assertions over implementations.** If a test fails and the code disagrees, assume the assertion is right, stop, and report both sides. Do not edit an assertion to make a test pass.

**Verify at least two assertions by breaking the code** and confirming the test fails. The "Not now" assertion is a required one of the two — it is exactly the kind that passes vacuously if the wiring is wrong.

**Any test that waits must poll for a condition, never sleep a fixed interval.** Timer-based tests have already passed alone and failed inside the full suite here.

---

## Phase E — Adversarial re-read

A distinct pass after the build is green, reported whether or not it finds anything. It has caught real defects in two phases now.

Look specifically for:

- Any path that reaches the system prompt without passing through the soft ask.
- Any path that re-prompts after a system denial.
- Branches unreachable after a state change.
- Anything behaving differently under a real `URLSession` than under a stub, particularly around cancellation.
- Failures that become terminal and silent.
- A signed-out device retaining a live token.

---

## Accessibility hook

Dynamic Type **XXL** screenshots of the onboarding permission screen and the Settings row — including the denied state — with nothing clipped, plus a VoiceOver audit of both actions, the toggle, and the time picker. The two onboarding actions must be equally reachable and equally described; neither may be presented as the default. State which artifacts you generated versus assumed.

---

## Docs

- `docs/decisions.md`: the soft pre-prompt and why, permission as the final onboarding step, the single re-offer after first entry, never re-prompting after system denial, and foreground presentation.
- `docs/roadmap-status.md`: what landed, and **rewrite the "Recommended next phase" section rather than leaving it** — it has gone stale twice.
- `docs/device-verification-push.md`: new. Real APNs delivery, TestFlight's production environment, lock-screen presentation, and delivery while terminated — **none of which a simulator can answer.** Note that this checklist cannot be run at all until enrollment clears and the API is deployed, making it the first one blocked on both.

---

## Done when

- [ ] Suite green locally, cold from a deleted `DerivedData`, zero warnings, count grown, no existing test modified
- [ ] Onboarding completes in all three permission outcomes
- [ ] `simctl push` payload delivers and routes correctly, payload file attached
- [ ] Two assertions verified by breaking the code, one of them the "Not now" assertion
- [ ] Adversarial re-read performed and reported
- [ ] Dynamic Type XXL screenshots and VoiceOver audit attached
- [ ] Docs and the new device checklist written
- [ ] PR opened against `main`, listing every onboarding and Settings file touched and why

PR must include: what shipped, **Judgment calls**, **Blocked**, test counts before and after with the command used, **verification honesty** — no real notification has been delivered by APNs, and the sandbox/production split in particular is verified by reading rather than by receiving — and a ranked list of what you are least confident about, ordered by what would hurt most if wrong.
