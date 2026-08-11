# Phase 14 — Push Notifications (client) — plan

**Branch:** `phase-14/push-notifications` off `main`
**Lane:** iOS only. Nothing under `api/` is touched.
**Baseline:** 588 tests in 60 suites, passed, cold from a deleted `DerivedData`, zero compiler
warnings. Command:

```
xcodebuild test -project ios/Rascal/Rascal.xcodeproj -scheme Rascal \
  -destination 'platform=iOS Simulator,name=iPhone 17 Pro' CODE_SIGNING_ALLOWED=NO
```

The single `warning:` in the log is `appintentsmetadataprocessor … No AppIntents.framework
dependency found` — a tool notice, not a source warning. No `.swift` file produced one.

---

## Preflight results

| # | Check | Result |
|---|-------|--------|
| 1 | `main` green, tree clean | Yes. Settings v2 (PR #37) and onboarding (PR #27) both merged. |
| 2 | Cold suite, counted | 588 tests / 60 suites |
| 3 | Zero warnings baseline | Yes |
| 4 | `docs/decisions.md` read | Yes |
| 5 | Device + notify endpoints live | **Not on `main`** — implemented in open PR #38. See DECISIONS D-002. |
| 6 | Widget deep-link route read | `WidgetDeepLink` (parse) + `TodayBoard.route(forAssignment:)` (resolve). Reused, not duplicated. |
| 7 | `OnboardingGate` / step sequence / Settings v2 read | Yes |

### The contract, read from PR #38 source rather than inferred

- `POST /v1/devices` — body `{ token, platform: "ios", environment: "sandbox"|"production" }`
  → `DeviceOut`. Idempotent on `(token, environment)`; a revoked token comes back live.
- `DELETE /v1/devices/{token}` → `204`. Soft delete, revokes across both environments,
  idempotent, `404` for a token this account never registered.
- `PATCH /v1/me` — `{ display_name?, notify_enabled?, notify_local_time? }`. Absent key means
  "no opinion"; an explicit `null` is a rejection. So the request model must omit, not null.
- `UserOut` gains `notify_enabled: bool` and `notify_local_time: time` (`"HH:MM:SS"`).
- APNs payload: `{"aps":{"alert":{"title","body"},"sound":"default"},"assignment_id":"<uuid>"}`

---

## Files

### New — `ios/Rascal/Rascal/Push/`

| File | Why |
|------|-----|
| `PushEnvironment.swift` | `sandbox` in Debug, `production` otherwise. One property, asserted in both configurations. |
| `NotificationAuthorization.swift` | Protocol over `UNUserNotificationCenter` + live impl. Lets every permission assertion run without the system prompt. |
| `NotificationPreference.swift` | **The state machine.** Owns soft-ask → system-prompt ordering, the single re-offer, and the never-again-after-denial rule. All the logic in this phase lives here; the views are dumb. |
| `PushRegistrar.swift` | APNs registration, `POST /v1/devices` on launch, `DELETE` before sign-out. |
| `NotificationPayload.swift` | APNs userInfo → `WidgetDeepLink`. Reuses the widget's route; adds no second router. |

### New — `ios/Rascal/Rascal/Onboarding/NotificationStep.swift`

The final onboarding step. Inline time picker, two equally weighted actions.

### Modified

| File | Change |
|------|--------|
| `Onboarding/OnboardingDraft.swift` | `OnboardingStep` gains `.notifications` after `.avatar`. Draft gains the chosen time. |
| `Onboarding/ChildSetupFlow.swift` | Route the new step. |
| `Onboarding/AvatarStep.swift` | Advance to the new step instead of creating the child. |
| `Onboarding/OnboardingGate.swift` | `createChild()` moves to the end of the new step; sign-out revokes the device first. |
| `Networking/APIClient.swift` | `UserResponse` gains the two notify fields, decoded tolerantly. |
| `Networking/SettingsAPI.swift` | `updateMe` becomes all-optional so a notify write does not resend a display name. |
| `Networking/DevicesAPI.swift` (new) | The two device routes. |
| `Settings/SettingsScreen.swift` | Toggle + time picker row, and the denied state. |
| `App/RootView.swift` | Notification tap → existing pending-link path. |
| `App/AppEnvironment.swift` | Foreground re-check; registration on launch. |
| `RascalApp.swift` | `AppDelegate` gains the APNs token callbacks + foreground presentation. |
| `ios/CLAUDE.md` | Remove push from "out of scope" — it is now shipped. See DECISIONS D-004. |

---

## Order of work

1. Wire types and the two API calls (no UI) — smallest thing that compiles.
2. `PushEnvironment` + tests.
3. `NotificationPreference` state machine + tests. **This is the phase.**
4. `PushRegistrar` + sign-out ordering + tests.
5. `NotificationPayload` routing + tests.
6. Onboarding step (view) + step-sequence changes + tests.
7. Settings row + tests.
8. `simctl push` payload file and a real delivery against the simulator.
9. Break-the-code verification of the "Not now" assertion and one more.
10. Adversarial re-read (Phase E), accessibility artifacts, docs.

## Rules I am holding myself to

- **Nothing schedules locally.** No `UNUserNotificationCenter` scheduling API is called
  anywhere. The server owns the schedule.
- Every path to the system prompt goes through the soft ask.
- A system denial is terminal. No mechanism re-prompts.
- Registration failure is silent and non-fatal.
