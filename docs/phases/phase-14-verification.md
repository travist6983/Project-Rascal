# Phase 14 — certainty pass

> "please go back through and anything you are not 100% sure about please make sure you are 100%
> certain about all of the code in this phase"

Run as its own pass after the suite was green. Every file touched this phase was re-read top to
bottom. Below is what I had assumed rather than confirmed, how each was settled, and what it
changed.

---

## Findings that changed the code

### 1. The `aps-environment` entitlement was missing — the feature could not have worked at all

**Assumed:** that adding push code was sufficient.
**Checked:** read `ios/Rascal/Rascal.entitlements` in full. It carried `applesignin` and the app
group, and no `aps-environment` key.
**Consequence had it shipped:** `registerForRemoteNotifications()` fails on a real device with
"no valid aps-environment entitlement string found for application". No token is ever minted, so
`POST /v1/devices` is never called, and because registration failure is deliberately silent there
is **nothing anywhere to say why**. The simulator does not need the entitlement and the test
suite never signs, so no assertion in this repo could have caught it.
**Fixed:** added `aps-environment = development`. Flagged in `docs/blocked.md` that signing now
requires a profile with the Push Notifications capability, which needs the enrollment that has
not cleared.

### 2. The "Not now" assertion passed vacuously — found by breaking the code, not by reading it

**Assumed:** that `#expect(authorizer.promptCount == 0)` after `declineSoftAsk()` proved the
system prompt had not fired.
**Checked:** broke `declineSoftAsk` to fire the prompt from a detached `Task` and re-ran.
**The test passed.** `declineSoftAsk` is synchronous, so the only way it could accidentally fire
a prompt is from a `Task` — and that `Task` lands *after* the assertion has already read the
counter. The single most important assertion in this phase was blind to the only realistic way
of breaking it.
**Fixed:** the stub authorizer now carries a tripwire (`forbidPrompts()`) that records an issue
from **inside** the call, so it fires wherever and whenever the call comes from, and the test
drains pending work with `Task.yield()` before reading the counter. Re-broken afterwards: the
test now fails on both the tripwire and the counter.

### 3. `TestFlight` is `production`, and the server's own field description says otherwise

**Assumed:** nothing — this was a documented conflict between the phase file and PR #38's
`schemas/device.py`.
**Checked:** APNs environment follows the `aps-environment` entitlement in the embedded
provisioning profile. TestFlight builds are signed with a distribution profile and address the
production host; there is no separate TestFlight APNs environment.
**Settled:** the phase file is right and the server's description string is wrong. Recorded as
DECISIONS D-003 and flagged for Lane A as a doc-string-only correction.

### 4. `UserResponse` is persisted, so two new non-optional fields would have broken the upgrade

**Assumed:** that adding fields to a response model was free.
**Checked:** read `Networking/UserRecordStore.swift` and the `UserResponse` declaration — it is
`Codable`, not `Decodable`, precisely because the record is written to disk so Settings can name
the account on a cold offline start.
**Consequence had it shipped:** the stored record from the previous build has no `notify_*` keys,
synthesized decoding throws, the store reads the account as absent, and the first cold launch
after the update shows a nameless parent.
**Fixed:** hand-written `init(from:)` using `decodeIfPresent` with the server's own defaults, plus
a regression test (`decodesLegacyRecord`) that decodes a record with the keys absent.

---

## Assumptions confirmed against source, not memory

| Assumption | How it was confirmed |
|---|---|
| Swift's synthesized encoder omits nil optionals rather than sending `null` | Not taken on trust — asserted directly in `MeUpdateEncodingTests.unsetFieldsAreOmitted`, which fails if a `null` ever appears. This is load-bearing: the server reads `model_fields_set`, and an explicit `null` is a rejection. |
| `send(..., as: EmptyResponse.self)` tolerates a `204` with no body | Read `APIClient.send`: it returns early for `EmptyResponse` *before* attempting to decode. |
| The APNs payload puts `assignment_id` at the top level, not inside `aps` | Read `services/push.py` `PushMessage.payload()` on the PR #38 branch. Confirmed: `{"aps": {...}, "assignment_id": "..."}`. Apple reserves `aps`, so this is also the only correct place for it. |
| `notify_local_time` arrives as `"HH:MM:SS"` | `UserOut.notify_local_time` is `dt.time`; Pydantic serialises it as `HH:MM:SS`. `NotifyTime(wire:)` accepts both two- and three-part forms, and both are asserted. |
| The server's default send time is 19:00 | Read `constants.py`: `DEFAULT_NOTIFY_LOCAL_TIME = dt.time(19, 0)`. `NotifyTime.default` matches it, asserted. |
| `DELETE /v1/devices/{token}` is `204` and idempotent | Read `routers/devices.py` on the PR branch — `status_code=204`, and a token this account never registered is `404`. |
| The widget's deep-link rule is reused rather than reimplemented | `NotificationPayload.link` returns a `WidgetDeepLink`; the stale-id rule stays in `TodayBoard.route(forAssignment:)`. Asserted end to end in `staleIdResolvesToTodayThroughSharedRouter`. |
| Sign-out revokes before the session is cleared | Read `OnboardingSession.signOut`: `notifications.revokeDevice()` precedes `account.signOut()`. Routed through the injected backend rather than `PushCenter.shared` specifically so it is assertable. |
| Nothing schedules locally | `grep` for `UNUserNotificationCenter` across the target returns the authorization seam and the delegate assignment only. No `add(_:)`, no `UNNotificationRequest`, no trigger of any kind is constructed anywhere. |
| New `@Model` properties need declaration defaults | Not applicable — this phase adds no `@Model` property. `NotificationAskRecord` and the token are `UserDefaults`, not SwiftData, so the store-refuses-to-open failure mode is not in play. |

## Things I could not confirm, stated plainly

- **No real notification has been delivered by APNs.** Enrollment has not cleared and the API is
  not deployed. Everything about real delivery is unverified.
- **The sandbox/production split is verified by reading, not by receiving.** `PushEnvironment`
  is asserted against the build configuration; that the resulting token is addressable on the
  matching APNs host is not something a simulator can answer.
- **The tap-to-composer path is asserted, not tapped.** `simctl push` delivers the payload and
  the app handles it without crashing, but the CLI cannot tap a notification. Routing is proven
  by `NotificationPayloadTests`, not by a real tap.
- **Foreground suppression is asserted by reading**, not by watching a banner not appear.
