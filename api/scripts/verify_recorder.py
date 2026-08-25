"""Prove the Studio's video recorder actually works, in a real browser. Not a checklist.

    uv run --with websockets python scripts/verify_recorder.py

**Why this exists.** Phase 120 moved the video renderer into the browser: `admin/static/cards.js`
draws every frame and `MediaRecorder` captures the canvas. There is no JavaScript test runner in
this repository and this does not add one — `pytest` cannot reach a `requestAnimationFrame` loop,
a `visibilitychange` race, or a `MediaRecorder` that never fires `onstop`, and those are precisely
the paths where the failure is *silent*: a file with the right container, the right codec, playable,
and missing however many seconds the tab spent behind something else.

So this drives the real modules in a real Chrome over the DevTools protocol and asserts on what
came back. Nine cases, in the order a failure is cheapest to understand:

  1. **happy** — an ordinary two-scene recording resolves with a non-empty WebM.
  2. **progress_throws** — a caller's `onProgress` that throws must not take the recording down.
     A progress line is cosmetic; the file is the deliverable.
  3. **hidden_midway** — a tab hidden mid-record must *reject*. This is the whole reason the
     guard exists: rAF does not fire in a background tab, so the alternative is a short file
     nothing downstream can distinguish from a correct one.
  4. **hidden_at_the_end** — a tab hidden in the one frame between the final draw and `stop()`
     must **not** abort: that recording is complete. Fired from inside `onProgress` on the tick
     where `elapsed >= total`, because a wall-clock timer cannot target that window.
  5. **watchdog** — a recorder whose `stop()` never fires must be abandoned with an error rather
     than leaving the console stuck on "Recording…" for the life of the tab. It must **reject**;
     resolving with whatever chunks arrived is the silently-short file again.
  6. **construction_fails** — a `captureStream` that throws must come back as a rejected promise,
     not a synchronous throw out of a function documented to return one.
  7. **guards_reject** — too few scenes, and an already-hidden tab, are refusals with sentences.
  8. **hidden_at_the_end_with_raf_parked** — the case above, but with `requestAnimationFrame`
     genuinely parked the way a hidden tab parks it. Stubbing `visibilityState` alone is not
     enough and is how an earlier version of this file passed while the bug was live: the
     trailing `stop()` sits in an rAF callback, so a tab that stops running them leaves the
     recorder going until the watchdog abandons a **complete** recording fifteen seconds later.
  9. **no_leaks** — three recordings in a row must add and remove the same number of
     `visibilitychange` listeners and leave no live capture track.

**It needs a running API and a Chrome on this machine.** The modules are ES modules served from
the admin origin, so they have to be imported from a page on that origin — `file://` will not do
and neither will Node. Chrome is launched headless and killed on the way out; headless reports
`visibilityState: "visible"`, which is the honest condition the recorder requires.

**`websockets` is not a project dependency and is not being made one.** The DevTools protocol is
websocket-only, so it comes in through `uv run --with` for the length of one invocation and the
lockfile is untouched.
"""

from __future__ import annotations

import argparse
import asyncio
import json
import shutil
import subprocess
import sys
import tempfile
import time
import urllib.error
import urllib.request

try:
    import websockets
except ModuleNotFoundError:  # pragma: no cover - the invocation is the fix
    sys.exit(
        "This needs the `websockets` package, which is deliberately not a project dependency.\n"
        "Run it as:  uv run --with websockets python scripts/verify_recorder.py"
    )

CHROME_PATHS = (
    "/Applications/Google Chrome.app/Contents/MacOS/Google Chrome",
    "/usr/bin/google-chrome",
    "/usr/bin/chromium",
    "/usr/bin/chromium-browser",
)

#: Two scenes of 1500ms. Short enough that eight cases run in about a minute, long enough that the
#: rAF loop ticks ~90 times and the transitions actually run.
SCENES = (
    '[{template:"quote",palette:"cream",eyebrow:"",headline:"one",subhead:"",'
    'duration_ms:1500,transition:"cut"},'
    '{template:"stat",palette:"ink",eyebrow:"",headline:"two",subhead:"",'
    'duration_ms:1500,transition:"fade"}]'
)

CASES: dict[str, str] = {
    "happy": """(async () => {
        const c = await import("/admin/static/cards.js");
        const blob = await c.recordTreatment(SCENES, "instagram_story");
        return { ok: blob instanceof Blob && blob.size > 0, size: blob.size, type: blob.type };
    })()""",
    "progress_throws": """(async () => {
        const c = await import("/admin/static/cards.js");
        let calls = 0;
        const blob = await c.recordTreatment(SCENES, "instagram_story", {
            onProgress: () => { calls++; throw new Error("caller bug"); },
        });
        return { ok: blob instanceof Blob && blob.size > 0 && calls > 10, size: blob.size, calls };
    })()""",
    "hidden_midway": """(async () => {
        const c = await import("/admin/static/cards.js");
        let vis = "visible";
        Object.defineProperty(document, "visibilityState", { configurable: true, get: () => vis });
        const p = c.recordTreatment(SCENES, "instagram_story");
        setTimeout(() => {
            vis = "hidden";
            document.dispatchEvent(new Event("visibilitychange"));
        }, 400);
        try { const b = await p; return { ok: false, wrongly_resolved: b.size }; }
        catch (e) { return { ok: /background/.test(e.message), message: e.message }; }
        finally { delete document.visibilityState; }
    })()""",
    "hidden_at_the_end": """(async () => {
        const c = await import("/admin/static/cards.js");
        let vis = "visible", fired = false;
        Object.defineProperty(document, "visibilityState", { configurable: true, get: () => vis });
        const p = c.recordTreatment(SCENES, "instagram_story", {
            onProgress: ({ elapsed, total }) => {
                if (elapsed >= total && !fired) {
                    fired = true;
                    vis = "hidden";
                    document.dispatchEvent(new Event("visibilitychange"));
                }
            },
        });
        try { const b = await p; return { ok: fired && b.size > 0, fired, size: b.size }; }
        catch (e) { return { ok: false, fired, wrongly_rejected: e.message }; }
        finally { delete document.visibilityState; }
    })()""",
    "watchdog": """(async () => {
        const c = await import("/admin/static/cards.js");
        const realStop = MediaRecorder.prototype.stop;
        MediaRecorder.prototype.stop = function () { /* wedged: never fires onstop */ };
        const began = performance.now();
        try {
            const b = await c.recordTreatment(SCENES, "instagram_story");
            return { ok: false, wrongly_resolved: b.size };
        } catch (e) {
            return {
                ok: /stopped responding/.test(e.message),
                message: e.message,
                seconds: Math.round((performance.now() - began) / 1000),
            };
        } finally { MediaRecorder.prototype.stop = realStop; }
    })()""",
    "construction_fails": """(async () => {
        const c = await import("/admin/static/cards.js");
        const real = HTMLCanvasElement.prototype.captureStream;
        HTMLCanvasElement.prototype.captureStream = function () {
            throw new Error("no stream here");
        };
        let threwSynchronously = false, rejected = null;
        try {
            const p = c.recordTreatment(SCENES, "instagram_story");
            try { await p; } catch (e) { rejected = e.message; }
        } catch (e) { threwSynchronously = true; rejected = e.message; }
        finally { HTMLCanvasElement.prototype.captureStream = real; }
        return { ok: !threwSynchronously && /could not start/.test(rejected || ""),
                 threwSynchronously, rejected };
    })()""",
    "guards_reject": """(async () => {
        const c = await import("/admin/static/cards.js");
        const out = {};
        try { await c.recordTreatment([SCENES[0]], "instagram_story"); out.oneScene = "resolved"; }
        catch (e) { out.oneScene = e.message; }
        let vis = "hidden";
        Object.defineProperty(document, "visibilityState", { configurable: true, get: () => vis });
        try { await c.recordTreatment(SCENES, "instagram_story"); out.hidden = "resolved"; }
        catch (e) { out.hidden = e.message; }
        delete document.visibilityState;
        return { ok: /two scenes/.test(out.oneScene) && /front/.test(out.hidden), ...out };
    })()""",
    "hidden_at_the_end_with_raf_parked": """(async () => {
        const c = await import("/admin/static/cards.js");
        let vis = "visible", fired = false, parked = false;
        Object.defineProperty(document, "visibilityState", { configurable: true, get: () => vis });

        // **A hidden tab parks callbacks that are ALREADY QUEUED, and that is the whole case.**
        // Reassigning window.requestAnimationFrame only affects future calls, so a naive stub
        // lets the trailing stop() run and the test passes while the bug is live — which is
        // exactly how an earlier version of this file passed. This wrapper holds a callback at
        // the moment it would have fired, which is what the browser does.
        const realRaf = window.requestAnimationFrame.bind(window);
        const held = [];
        window.requestAnimationFrame = (cb) =>
            realRaf((t) => { if (parked) held.push(cb); else cb(t); });

        const p = c.recordTreatment(SCENES, "instagram_story", {
            onProgress: ({ elapsed, total }) => {
                if (elapsed >= total && !fired) {
                    fired = true;
                    vis = "hidden";
                    parked = true;
                    document.dispatchEvent(new Event("visibilitychange"));
                }
            },
        });
        const began = performance.now();
        try {
            const b = await p;
            const seconds = Math.round((performance.now() - began) / 1000);
            // Under the bug nothing stops the recorder here — the stop() is in `held` — so the
            // watchdog settles it ~15s later, with a rejection, blaming the recorder for a
            // complete recording. Correct behaviour is a resolve, promptly.
            return { ok: fired && parked && b.size > 0 && seconds < 10,
                     fired, held: held.length, size: b.size, seconds };
        } catch (e) {
            return { ok: false, fired, held: held.length,
                     seconds: Math.round((performance.now() - began) / 1000),
                     wrongly_rejected: e.message };
        } finally {
            window.requestAnimationFrame = realRaf;
            delete document.visibilityState;
        }
    })()""",
    "no_leaks": """(async () => {
        const c = await import("/admin/static/cards.js");
        let added = 0, removed = 0;
        const realAdd = document.addEventListener.bind(document);
        const realRemove = document.removeEventListener.bind(document);
        document.addEventListener = (t, f, o) => {
            if (t === "visibilitychange") added++;
            return realAdd(t, f, o);
        };
        document.removeEventListener = (t, f, o) => {
            if (t === "visibilitychange") removed++;
            return realRemove(t, f, o);
        };
        const streams = [];
        const realCapture = HTMLCanvasElement.prototype.captureStream;
        HTMLCanvasElement.prototype.captureStream = function (fps) {
            const s = realCapture.call(this, fps); streams.push(s); return s;
        };
        try { for (let i = 0; i < 3; i++) await c.recordTreatment(SCENES, "instagram_story"); }
        finally {
            document.addEventListener = realAdd;
            document.removeEventListener = realRemove;
            HTMLCanvasElement.prototype.captureStream = realCapture;
        }
        const live = streams
            .flatMap((s) => s.getTracks())
            .filter((t) => t.readyState === "live").length;
        return {
            ok: added === removed && live === 0,
            added, removed, streams: streams.length, live,
        };
    })()""",
}


class Page:
    """One CDP session against one page target."""

    def __init__(self, ws) -> None:
        self.ws = ws
        self.n = 0

    async def send(self, method: str, **params):
        self.n += 1
        ident = self.n
        await self.ws.send(json.dumps({"id": ident, "method": method, "params": params}))
        while True:
            message = json.loads(await self.ws.recv())
            if message.get("id") == ident:
                if "error" in message:
                    raise RuntimeError(f"{method}: {message['error']}")
                return message.get("result", {})

    async def evaluate(self, expression: str, timeout: float):
        result = await asyncio.wait_for(
            self.send(
                "Runtime.evaluate",
                expression=expression,
                awaitPromise=True,
                returnByValue=True,
                userGesture=True,
            ),
            timeout,
        )
        if result.get("exceptionDetails"):
            return {"threw": json.dumps(result["exceptionDetails"])[:400]}
        return result["result"].get("value")


def find_chrome() -> str:
    for path in CHROME_PATHS:
        if shutil.which(path) or shutil.os.path.exists(path):
            return path
    sys.exit("No Chrome or Chromium found. Install one, or edit CHROME_PATHS.")


def wait_for(url: str, seconds: int) -> None:
    deadline = time.monotonic() + seconds
    while time.monotonic() < deadline:
        try:
            urllib.request.urlopen(url, timeout=2).read()
            return
        except (urllib.error.URLError, OSError):
            time.sleep(0.5)
    sys.exit(f"Timed out waiting for {url}")


async def run(base_url: str, port: int) -> int:
    with urllib.request.urlopen(f"http://127.0.0.1:{port}/json/list") as response:
        target = next(t for t in json.load(response) if t["type"] == "page")

    failures = []
    async with websockets.connect(target["webSocketDebuggerUrl"], max_size=None) as ws:
        page = Page(ws)
        await page.send("Page.enable")
        await page.send("Runtime.enable")
        await page.send("Page.navigate", url=f"{base_url}/admin/")
        await asyncio.sleep(3)

        # Wrapped in an async IIFE like every case below: `Runtime.evaluate` does not accept a
        # bare top-level `await`, and an unwrapped probe fails as a SyntaxError that reads like
        # the module is broken rather than the probe.
        probe = '(async () => typeof (await import("/admin/static/cards.js")).recordTreatment)()'
        served = await page.evaluate(probe, 30)
        if served != "function":
            sys.exit(
                f"{base_url}/admin/static/cards.js did not export recordTreatment "
                f"({served!r}) — is the app serving this checkout?"
            )

        for name, body in CASES.items():
            # `SCENES` is spliced in rather than passed, so each case is one self-contained
            # expression and a failure names the case rather than a shared fixture.
            outcome = await page.evaluate(body.replace("SCENES", SCENES), 180)
            ok = isinstance(outcome, dict) and outcome.get("ok") is True
            if not ok:
                failures.append(name)
            print(f"{'PASS' if ok else 'FAIL'}  {name:20s} {json.dumps(outcome)[:180]}")

    print()
    if failures:
        print(f"{len(failures)} of {len(CASES)} failed: {', '.join(failures)}")
        return 1
    print(f"All {len(CASES)} recorder checks passed.")
    return 0


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--base-url", default="http://127.0.0.1:8000")
    parser.add_argument("--port", type=int, default=9444, help="Chrome's DevTools port.")
    args = parser.parse_args()

    wait_for(f"{args.base_url}/health", seconds=15)

    with tempfile.TemporaryDirectory(prefix="rascal-recorder-") as profile:
        # Fixed argv, no shell, and every value is one this file wrote.
        chrome = subprocess.Popen(
            [
                find_chrome(),
                "--headless=new",
                f"--remote-debugging-port={args.port}",
                f"--user-data-dir={profile}",
                "--no-first-run",
                "--no-default-browser-check",
                "--disable-gpu",
                "--window-size=1400,1000",
                "about:blank",
            ],
            stdout=subprocess.DEVNULL,
            stderr=subprocess.DEVNULL,
        )
        try:
            wait_for(f"http://127.0.0.1:{args.port}/json/version", seconds=20)
            return asyncio.run(run(args.base_url.rstrip("/"), args.port))
        finally:
            chrome.terminate()
            try:
                chrome.wait(timeout=10)
            except subprocess.TimeoutExpired:
                chrome.kill()


if __name__ == "__main__":
    raise SystemExit(main())
