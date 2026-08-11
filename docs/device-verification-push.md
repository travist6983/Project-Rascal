# Push notifications — device verification

**Nothing in this feature has been delivered by APNs.** Not once, not in development. The suite
proves the permission ordering, the token lifecycle, the payload routing, the preference writes
and the sandbox/production split — and every one of those assertions runs against a stub, a
simulator, or a `#if`. `xcrun simctl push` injects a payload locally and never touches Apple's
infrastructure, so it proves the app *handles* a notification and says nothing about whether one
would ever *arrive*.

**This is the first checklist blocked on both open items at once.** It cannot be started until
Apple Developer Program enrollment clears **and** the API is deployed. Enrollment gates the push
credential and the provisioning profile; the deployed API gates there being any server able to
send. Running it against `localhost` is not possible — APNs pushes come from Apple, not from your
machine.

Tick each line or write down what happened instead. A line that "seemed fine" is not ticked.

---

## 0. Before anything: the entitlement, and whether a token appears at all

Phase 14 added `aps-environment` to `Rascal.entitlements`. **Signing now requires a provisioning
profile with the Push Notifications capability enabled.** If enrollment has cleared but the
capability was never added to the App ID, the build fails to sign — which is the good outcome.
The bad one is a build that signs against a profile without it and then silently mints no token.

- [ ] The App ID has Push Notifications enabled, and the profile was regenerated **after** it was
      added. A stale profile is the usual reason this fails.
- [ ] Install a signed build on a real device and complete onboarding, choosing **Turn it on**.
- [ ] The system permission prompt appears **exactly once**.
- [ ] `POST /v1/devices` arrives at the server. Check the row: `platform = ios`,
      `environment = sandbox` for an Xcode build, and `last_seen_at` set.
- [ ] Kill and relaunch. A second `POST /v1/devices` arrives and **updates the same row** rather
      than creating a second one.

## 1. The one that matters most, and no test can tell you

**Does a notification actually arrive, on a locked phone, hours later, with the app terminated?**
Everything else in this feature is plumbing around that question.

- [ ] Set the send time to a few minutes out. Lock the phone. Put it down and do not touch it.
- [ ] It arrives. Note the delay between the configured time and the actual delivery.
- [ ] Force-quit the app entirely, set another time, and repeat. **It still arrives.** A
      terminated app is the normal state for this notification — the whole point is that it
      reaches someone who has not opened the app today.
- [ ] Read the lock-screen presentation as a stranger would. Does the body carry enough of the
      mission to be worth tapping, without giving away so much that tapping is pointless?

## 2. The sandbox/production split — the silent one

**This is the failure with no error message on either side.** A token minted under one
environment and sent to the other is accepted by APNs and delivered to nobody.

- [ ] A **TestFlight** build registers with `environment = production`. Check the row on the
      server, not the client log.
- [ ] A notification sent to that TestFlight device arrives.
- [ ] The Xcode build on the same phone registered a **separate** row with `environment =
      sandbox`, and both rows exist simultaneously. The same token string legitimately appears
      twice.

> `docs/api-contract.md` describes TestFlight as `sandbox`. **That is wrong** — TestFlight ships
> through App Store infrastructure and addresses the production host. The client sends
> `production` for every non-Debug build. If this section fails, this is the first thing to
> re-read, and the contract's description is what needs correcting.

## 3. The tap

The simulator cannot tap a notification, so the whole of this section is unverified.

- [ ] Tapping a notification for a **live** assignment opens the composer for that assignment.
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
