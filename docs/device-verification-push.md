# Push notifications — device verification

> **Aug 12, 2026 — this checklist is no longer blocked, and it is partly run.** A real
> notification was delivered: `api.push.apple.com` answered `HTTP/2 200`, it arrived on a locked
> phone, and tapping it deep-linked to the assignment. Ticked lines below are the ones that run
> actually proved. **The unticked ones are still unticked** — in particular the force-quit case,
> the two-environment case, and everything in §4–§7. See `docs/blocked.md` §1a.
>
> One line was proved *wrong* rather than confirmed: see the note under §2.

**Everything below was originally written against a stub.** The suite proves the permission
ordering, the token lifecycle, the payload routing, the preference writes and the
sandbox/production split — and every one of those assertions runs against a stub, a simulator,
or a `#if`. `xcrun simctl push` injects a payload locally and never touches Apple's
infrastructure, so it proves the app *handles* a notification and says nothing about whether one
would ever *arrive*. That gap is why this file exists, and why a green test suite never closed it.

**This was the first checklist blocked on both open items at once**, needing Apple Developer
Program enrollment *and* a deployed API. Both cleared. Running it against `localhost` is still
not possible — APNs pushes come from Apple, not from your machine.

Tick each line or write down what happened instead. A line that "seemed fine" is not ticked.

---

## 0. Before anything: the entitlement, and whether a token appears at all

Phase 14 added `aps-environment` to `Rascal.entitlements`. **Signing now requires a provisioning
profile with the Push Notifications capability enabled.** If enrollment has cleared but the
capability was never added to the App ID, the build fails to sign — which is the good outcome.
The bad one is a build that signs against a profile without it and then silently mints no token.

- [x] The App ID has Push Notifications enabled, and the profile was regenerated **after** it was
      added. A stale profile is the usual reason this fails. — *Proved indirectly and
      conclusively: the device minted a production token that Apple accepted with a `200`, which
      is not possible without the capability on the App ID.*
- [x] Install a signed build on a real device and complete onboarding, choosing **Turn it on**.
      — *`users.notify_enabled = true`, one `devices` row.*
- [ ] The system permission prompt appears **exactly once**. — *Not observed; the install
      predates this run.*
- [x] `POST /v1/devices` arrives at the server. Check the row: `platform = ios`,
      `environment = sandbox` for an Xcode build, and `last_seen_at` set. — *Row present:
      `platform = ios`, `environment = production` (a TestFlight build, which is correct — see
      §2), `revoked_at` null, `last_seen_at` set.*
- [x] Kill and relaunch. A second `POST /v1/devices` arrives and **updates the same row** rather
      than creating a second one. — *`last_seen_at` advanced to `00:38:08Z` on foreground while
      the table still held exactly one row.*

## 1. The one that matters most, and no test can tell you

**Does a notification actually arrive, on a locked phone, hours later, with the app terminated?**
Everything else in this feature is plumbing around that question.

- [x] Set the send time to a few minutes out. Lock the phone. Put it down and do not touch it.
      — *Set to `20:40` America/Detroit at `00:38:01Z`, two minutes out.*
- [x] It arrives. Note the delay between the configured time and the actual delivery.
      — *Delivered `00:40:34Z` against a `00:40:00` window: **34 seconds**, and that is the
      manual-trigger figure, not the product's. The hourly machine fires at `:36` past, so a
      window at `:40` is served by the **next** hour's run — expect ~56 minutes in normal
      operation, bounded by the two-hour staleness tolerance. Choosing a send time just after
      the machine's minute is what makes this small.*
- [ ] Force-quit the app entirely, set another time, and repeat. **It still arrives.** A
      terminated app is the normal state for this notification — the whole point is that it
      reaches someone who has not opened the app today.
- [ ] Read the lock-screen presentation as a stranger would. Does the body carry enough of the
      mission to be worth tapping, without giving away so much that tapping is pointless?

## 2. The sandbox/production split — the silent one

**This is the failure with no error message on either side.** A token minted under one
environment and sent to the other is accepted by APNs and delivered to nobody.

- [x] A **TestFlight** build registers with `environment = production`. Check the row on the
      server, not the client log. — *Read off the `devices` row on the server.*
- [x] A notification sent to that TestFlight device arrives. — *`HTTP/2 200` from
      `api.push.apple.com`, `delivered_count = 1`, and it arrived.*
- [ ] The Xcode build on the same phone registered a **separate** row with `environment =
      sandbox`, and both rows exist simultaneously. The same token string legitimately appears
      twice. — *Not exercised. Only the production half is proven.*

> `docs/api-contract.md` describes TestFlight as `sandbox`. **That is wrong** — TestFlight ships
> through App Store infrastructure and addresses the production host. The client sends
> `production` for every non-Debug build. If this section fails, this is the first thing to
> re-read, and the contract's description is what needs correcting.
>
> **Both halves are closed as of Aug 12, 2026, and they closed independently.**
>
> The behaviour was confirmed by evidence stronger than an inspection: the `200` came from the
> *production* host, and APNs rejects a sandbox token there with `400 BadDeviceToken`, so Apple
> accepting it proves the token is genuinely production and the client's mapping is right.
>
> **The descriptions were already corrected** in commit `39fb97f`, before that run — both
> `schemas/device.py` and `docs/api-contract.md` now say `production` covers "**TestFlight and the
> App Store alike**". The paragraph above is kept because it is the reasoning, and because a
> reader who finds a stale copy of it elsewhere should be able to see it was answered twice.

## 3. The tap

The simulator cannot tap a notification, so this section was entirely unverified until
Aug 12, 2026. The primary case is now proved on a real device; the edge cases are not.

- [x] Tapping a notification for a **live** assignment opens the composer for that assignment.
      — *Confirmed on the `mission_b` notification delivered at `00:40:34Z`.*
- [ ] Tapping one for an assignment already completed opens the entry it produced, or Today.
- [ ] Tapping one whose assignment no longer exists — delete it server-side first — lands on
      **Today**, not on an empty composer.
- [ ] Tapping from a **cold** launch works. This is the normal case: the app is not running when
      the notification arrives. A tap that lands on Today because the app was still starting is
      a defect, not a race you tolerate.

## 4. Foreground presentation

The app suppresses the banner in the foreground, on the grounds that it would be telling a parent
looking at Today about the thing on Today.

- [ ] With the app open on Today, a notification arriving shows **no banner**.
- [ ] It is still in Notification Centre afterwards. Suppressed is not discarded.
- [ ] Judge it: with the app open on **Timeline** rather than Today, does suppressing still feel
      right, or did it swallow something useful? Write down which, because this is a judgment
      call recorded in `docs/decisions.md` and it is reversible.

## 5. Sign-out

- [ ] Sign out. `DELETE /v1/devices/{token}` reaches the server **before** the session is cleared,
      and the row comes back with `revoked_at` set.
- [ ] Trigger a send. **Nothing arrives on the signed-out phone.** This is the defect the ordering
      exists to prevent and the only way to confirm it is to try.
- [ ] Sign back in. The same row comes back live rather than a duplicate appearing.

## 6. Permission states that cannot be reached twice

**iOS shows the permission prompt once per install.** Each of these needs a fresh install —
delete the app, do not just sign out.

- [ ] Fresh install, choose **Not now**. No system prompt appears at all.
- [ ] Complete one entry. The single re-offer appears.
- [ ] Decline it. Complete more entries. **It never appears again.**
- [ ] Fresh install, choose **Turn it on**, then **deny** the system prompt. Settings shows the
      row as unavailable with the iOS location named, and the toggle does not move.
- [ ] From that denied state, turn notifications on in iOS Settings, then foreground the app.
      A token registers and **nothing asks you anything**.

## 7. Battery and volume

- [ ] Over a week, exactly seven notifications arrive. Not eight, not one that repeats.
- [ ] No measurable battery cost. There is no local scheduling and no background wake in this
      feature, so anything visible here means something is wrong.
