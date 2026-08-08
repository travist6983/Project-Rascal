# Verifying on a real phone

Simulator-only is not done. The simulator shares the Mac's network stack and its keychain is a
file on disk, so three whole classes of bug — reachability, ATS, and keychain accessibility —
cannot fail there and routinely do on a device.

## Before you build to the phone

**1. Point the app at the Mac's LAN address.** `localhost` on a phone means the phone.

```bash
ipconfig getifaddr en0        # Wi-Fi. en1 if you're on Ethernet.
```

Put that in `ios/Rascal/Config.xcconfig`:

```
API_HOST = 192.168.1.10:8000
```

Leave `API_SCHEME` as `http:$()/$()/`. Do not collapse it — `//` starts a comment in xcconfig
and the URL truncates to `http:` silently.

**2. Bind the API to all interfaces.** `make dev` already serves on `0.0.0.0`, but if you start
uvicorn by hand, `--host 127.0.0.1` refuses the phone:

```bash
cd api && uv run uvicorn rascal.main:app --host 0.0.0.0 --port 8000
```

Confirm from another machine, or from the phone's browser: `http://192.168.1.10:8000/health`
should return `{"status":"ok","db":"ok"}`.

**3. Same Wi-Fi, and check the firewall.** macOS may prompt the first time. A phone on cellular
or a guest network cannot reach your Mac at all.

**4. ATS.** `NSAllowsLocalNetworking` is already in `Info-Debug.plist` and covers private
address ranges, so a `192.168.x.x` host works in a Debug build. A **Release** build has no ATS
exception by design and will fail against plain HTTP — that is intentional, not a bug to work
around.

---

## What to verify, and why the simulator can't

| # | Check | Why it needs a device |
|---|---|---|
| 1 | App launches and Today loads over the LAN | Reachability and ATS are real here; the simulator borrows the Mac's stack and never exercises either |
| 2 | Force quit, relaunch — still signed in | Keychain with `kSecAttrAccessibleAfterFirstUnlock`. The simulator keychain is an unprotected file and will pass even when device behaviour would not |
| 3 | Relaunch after a **reboot, before unlocking** | The one case `AfterFirstUnlock` exists for. Cannot be simulated |
| 4 | Complete a wrote-it entry; check the Timeline of the API (`GET /v1/entries`) | Confirms the round trip over a real network |
| 5 | Airplane mode → save an entry → it appears immediately, no error | Local-first save. The simulator's "offline" is not the same code path as a radio that is actually down |
| 6 | Airplane mode off, background the app, foreground it → entry syncs | Retry on foreground |
| 7 | Backdate an entry via the DatePill, then confirm `occurred_at` ≠ `created_at` on the server | The rule this whole archive rests on |
| 8 | The completion haptic fires | Simulators have no taptic engine — this is silent there and cannot be checked |
| 9 | Dynamic Type at accessibility sizes (Settings → Accessibility → Display & Text Size) | Worth doing on the device you actually hold |
| 10 | Reduce Motion on → the completion check fills without springing | |

### Checking the server side from the phone's entries

```bash
TOKEN=$(curl -s -X POST http://localhost:8000/v1/auth/dev-login \
  -H 'content-type: application/json' -d '{}' \
  | python3 -c 'import json,sys; print(json.load(sys.stdin)["access_token"])')

curl -s "http://localhost:8000/v1/entries?child_id=$CHILD" \
  -H "authorization: Bearer $TOKEN" | python3 -m json.tool
```

Look for `occurred_at` differing from `created_at` on a backdated entry, and `entry_type`
holding the server's derivation rather than anything the client sent.

---

## Known device-only gaps this phase

- **Media cards open a coming-soon composer.** Photo, video, and audio capture is next phase.
  The cards deliberately still render — the Today screen must not lie about what the scheduler
  served.
- **Sign in with Apple is not wired.** `dev-login` is the only path, and it 404s in production,
  so a TestFlight build against a deployed API cannot sign in at all yet. That is expected.
- **No push, no background refresh.** Sync happens on foreground and on pull-to-refresh only.
