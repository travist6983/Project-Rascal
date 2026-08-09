# Device session — Phase 2 capture, plus Phase 2.5

**Step 4 remains the outstanding item from last time** — cold launch triggered by a background
callback. Nothing about it changed in 2.5, and it is still the case a simulator cannot produce.

New in 2.5, run these after the originals:

## 8. A completion shows done immediately, offline

The defect this phase exists to fix.

1. Airplane mode **on**
2. Complete a **photo** mission — pick one from the library, Save
3. **It must move to Done Today the instant the sheet closes**, with a ring showing the upload
   outstanding
4. Force quit, relaunch, still in airplane mode

**Expected:** still done. The card is drawn from SwiftData, not from the server's opinion.

**What to watch for:** the card snapping back to Today on relaunch. That would mean the merge is
reading memory rather than the store.

## 9. The ring counts down, and failures list individually

1. Airplane mode off, pick **three** photos, Save
2. Watch the ring: **3 → 2 → 1**, filling as bytes land, finishing into the check

Then the failure path:

3. Pick three more, Save, and **turn airplane mode on immediately**
4. Wait out the retries (about two minutes to exhaust the cap)

**Expected:** each failed photo is its own row with its own **Upload it**, plus **Upload all**.
Not "1 of 3 uploaded".

**What to watch for:** anything that reads as data loss. Nothing is lost — the files are staged
and the entry exists — and the copy must not suggest otherwise.

## 10. Completion feels like something

Complete anything and watch the check. It should **draw** rather than appear, the card should
settle into Done Today rather than jump, and the haptic should be the warmer `.success` one.

Then: Settings → Accessibility → Motion → **Reduce Motion on**, and do it again. The check should
still fill, just without the spring.

**Subjective, and that's the point.** If it still feels flat, say so — that's the whole item.

## 11. The four composer fixes

1. Attach a photo, tap the **+** tile → the picker opens (it did nothing before)
2. Centre **+** in the tab bar → a freeform entry that **can attach a photo**
3. Expand the date picker → **every date legible**, not just the selected one. Check it in
   daylight, which is where it failed
4. No **video** option anywhere

## 12. Done cards

1. A completed **question** card is **periwinkle**, a completed **mission** is **terracotta**,
   a completed **did-it** is **sage**
2. **Tap a done card** → it opens for editing. Change the date, save, reopen → the change stuck

---


One sitting, iPhone 15 Pro Max. Everything reachable in the simulator is already green;
what's left is the three classes of behaviour a simulator cannot produce — a real camera, a
genuinely suspended process, and a radio that is actually off.

Budget about 30 minutes. Do them in order; #4 depends on #2 having happened.

---

## Before you start

**1. Point the app at this Mac.** `localhost` on a phone means the phone.

```bash
ipconfig getifaddr en0        # en1 on Ethernet
```

In `ios/Rascal/Config.xcconfig`:

```
API_HOST = 192.168.1.x:8000
```

Leave `API_SCHEME` as `http:$()/$()/` — do not collapse it; `//` starts a comment in xcconfig
and the URL truncates to the scheme.

**2. Serve on all interfaces.** `make dev` already does; by hand, `--host 0.0.0.0`.

Confirm from the phone's browser: `http://192.168.1.x:8000/health` → `{"status":"ok","db":"ok"}`.

**3. Build to the device from Xcode**, Debug configuration. Release has no ATS exception by
design and will refuse plain HTTP.

**Watch for**: the app asks for photo and camera permission on first use. The strings should
read like sentences, not like a legal notice. If either prompt doesn't appear, the
corresponding usage key is missing from `Info-Debug.plist` and capture will crash rather than
fail.

---

## 1. Camera capture, end to end

The simulator has no camera at all, so this path has never executed.

1. Today → a **Capture it** card → **Take one**
2. Take a photo, confirm
3. It appears in the preview row within a second or two
4. **Save** — the sheet should close **immediately**, not spin

**What should happen:** the entry appears under Done Today. The upload happens behind it.

**What to watch for:** any pause between tapping Save and the sheet closing. Save must never
block on the network. If it hesitates, that's a defect regardless of what else works.

Confirm server-side:

```bash
TOKEN=$(curl -s -X POST localhost:8000/v1/auth/dev-login -H 'content-type: application/json' -d '{}' \
  | python3 -c 'import json,sys; print(json.load(sys.stdin)["access_token"])')
CHILD=ca5dda95-6712-4a1b-a818-f1c1f2e9b40b

curl -s "localhost:8000/v1/entries?child_id=$CHILD" -H "authorization: Bearer $TOKEN" \
  | python3 -m json.tool | head -40
```

Look for `entry_type: "photo"` — **derived by the server**, not sent by the client.

---

## 2. Background upload while genuinely suspended

Backgrounded and suspended are different states, and only the second exercises the background
session.

1. Pick **three** photos from the library, Save
2. Immediately press the **side button** to lock the phone
3. Wait **60 seconds** — long enough for the system to suspend the process, not just background it
4. Unlock, reopen the app

**Expected:** all three are complete. The "N entries still saving" row on Today is gone.

**What to watch for:** if the row still shows a count and it doesn't clear within a few
seconds of foregrounding, the background session isn't carrying tasks while suspended — check
that `isDiscretionary` is false and `sessionSendsLaunchEvents` is true.

---

## 3. Force quit mid-upload

The one that proves the staged file plus disk state is genuinely sufficient.

1. Turn **Wi-Fi off, cellular on** — a slower link widens the window
2. Pick three photos, Save
3. While the count still shows, **double-swipe up and force quit the app**
4. Wait 30 seconds. **Do not reopen it.**
5. Reopen

**Expected:** uploads resume and finish on their own. You may find them already complete on
launch — the system continues a background session across a force quit, which is the entire
reason this is built on one.

**What to watch for:** a photo stuck at "still saving" that never clears, or a count that
*grows*. Growth would mean a duplicate media row per relaunch — the idempotency discipline
failing.

---

## 4. Cold launch triggered by a background callback

**This is the case I most want checked**, and the one the prompt flagged as the likeliest
defect in C-3. It cannot be produced in a simulator.

The delegate makes its own `ModelContext` from `LocalStore.shared` as its first act, precisely
so a callback arriving into a process that has restored nothing still lands somewhere. This is
where that either works or doesn't.

1. Do step 3 above, but after force-quitting, **wait until you're confident an upload
   finished while the app was dead** — 2–3 minutes on cellular with three photos
2. Reopen the app

**Expected:** the photos are already `complete` on the first render. No spinner, no count, no
work happening after you look at it.

**What to watch for:** the count clearing only *after* you open the app rather than being
clear on arrival. That means the callback landed and did nothing, and the row was fixed by the
foreground sweep instead — the upload completed without ever being marked, which is exactly
the failure this design is meant to prevent. It looks fine from the outside and isn't.

If you can, check Console.app filtered to the app while it relaunches.

---

## 5. Cellular, multi-photo

1. Wi-Fi **off**, cellular on
2. Five photos on one entry, Save
3. Watch the count go down

**Expected:** it decreases steadily. Not necessarily in order — the sweep is ordered by when
rows became due, and jitter deliberately spreads retries.

**What to watch for:** the count sticking at one photo for a long time while others finish.
That's fine and expected if it's retrying. What's *not* fine is the count freezing entirely,
which would mean the queue is blocked behind a single row.

---

## 6. Airplane mode, both halves

1. Airplane mode **on**
2. Write a text entry, Save → appears immediately, no error
3. Add a photo entry, Save → same
4. Today shows the count for both
5. Airplane mode **off**, background the app, foreground it

**Expected:** everything clears through the one sweep. Entries first, then their photos.

**What to watch for:** any wording that reads like an error or a loss. Nothing is lost — the
files are staged and the entries exist. If it says otherwise, the copy is wrong even if the
behaviour is right.

---

## 7. Backdating from EXIF

The camera-roll backfill story, and the reason `occurred_at` and `created_at` are separate.

1. Pick a photo you took **months ago**
2. Before saving, look at the DatePill — it should already show that photo's date, not today
3. Save

```bash
curl -s "localhost:8000/v1/entries?child_id=$CHILD" -H "authorization: Bearer $TOKEN" \
  | python3 -c '
import json,sys
for e in json.load(sys.stdin).get("items", [])[:3]:
    print(e["occurred_at"], "|", e["created_at"], "|", e["entry_type"])'
```

**Expected:** `occurred_at` is months ago, `created_at` is today. Two different values on the
same row is the whole point.

---

## What I could not verify, and why

- **Everything above.** The simulator has no camera, cannot truly suspend a process, and its
  "offline" is not a radio being off.
- **The haptic** on completion. Simulators have no taptic engine.
- **Whether `isDiscretionary = false` is right on cellular.** It's set so uploads go promptly
  rather than waiting for Wi-Fi and power, on the reasoning that a parent expects their photo
  to be safe now. If step 5 drains the battery noticeably or you'd rather it waited for
  Wi-Fi, that's a one-line change and a real product decision I made by default.

## Report anything unexpected as-is

Don't infer a cause. "The count stuck at 2 for a minute then cleared" is more useful than "the
retry seems broken" — the first is an observation and the second is a diagnosis, and I'd
rather do the diagnosing against the real numbers.
