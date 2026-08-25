/* Brand cards, drawn on a canvas.
 *
 * This is the renderer that makes "generate an image with our Anthropic key" a true sentence
 * rather than a hopeful one. Claude cannot produce pixels — there is no image endpoint on any
 * model — so it does the part it is good at, which is picking a layout and writing the words,
 * and this file draws them in the Vellum design system at whatever size the platform wants.
 *
 * Canvas rather than SVG-then-rasterize, for three reasons that all showed up in the first
 * attempt. Fonts resolve reliably here and do not silently fall back inside a data-URL SVG.
 * The same code paints the on-screen preview and the exported file, so what you approve is
 * literally what downloads. And `canvas.captureStream()` turns a draw loop into a WebM with no
 * extra machinery, which is the only honest way this feature ships video tonight.
 *
 * Claude never authors markup. It fills a template. A model returning raw SVG would be an
 * injection surface and an off-brand-output surface at the same time; a template can only draw
 * things that are in the design system.
 */

import { sceneAt, totalMs } from "/admin/static/timeline.js";

const IS_TEST = typeof window === "undefined";

export const PALETTES = {
  cream: { bg: "#FDFAF4", ink: "#23253C", muted: "#6E6A63", accent: "#C05A2B", rule: "#EBD8C8" },
  terracotta: { bg: "#C05A2B", ink: "#FFFDF9", muted: "#F6DFD1", accent: "#FFFDF9", rule: "#E8B99C" },
  periwinkle: { bg: "#5566D6", ink: "#FFFDF9", muted: "#DDE1FA", accent: "#FFFDF9", rule: "#A9B3EE" },
  sage: { bg: "#E8F0E6", ink: "#23253C", muted: "#5B6B5C", accent: "#2E7D4F", rule: "#B7CDB3" },
  ink: { bg: "#23253C", ink: "#FDFAF4", muted: "#A8AAC0", accent: "#E39B6F", rule: "#4A4C63" },
};

export const SIZES = {
  instagram: [1080, 1350],
  instagram_story: [1080, 1920],
  x: [1200, 675],
  threads: [1080, 1350],
  facebook: [1200, 630],
  linkedin: [1200, 627],
  generic: [1080, 1080],
};

// The app's own type ramp, scaled to a 1080-wide card. Rounded for display, system text for
// reading copy — the same line docs/design-system.md draws, and for the same reason: a rounded
// body reads as a toy and a non-rounded headline reads as a form.
const ROUNDED = '600 {size}px ui-rounded, "SF Pro Rounded", "Nunito", -apple-system, sans-serif';
const ROUNDED_BOLD = '700 {size}px ui-rounded, "SF Pro Rounded", "Nunito", -apple-system, sans-serif';
const TEXT = '400 {size}px -apple-system, BlinkMacSystemFont, "Segoe UI", Helvetica, sans-serif';
const LABEL = '600 {size}px -apple-system, BlinkMacSystemFont, "Segoe UI", Helvetica, sans-serif';

const font = (spec, size) => spec.replace("{size}", String(Math.round(size)));

/** Greedy word wrap. Returns the lines; the caller decides whether they fit. */
function wrap(ctx, text, maxWidth) {
  const lines = [];
  for (const paragraph of String(text || "").split("\n")) {
    let line = "";
    for (const word of paragraph.split(/\s+/).filter(Boolean)) {
      const candidate = line ? `${line} ${word}` : word;
      if (ctx.measureText(candidate).width > maxWidth && line) {
        lines.push(line);
        line = word;
      } else {
        line = candidate;
      }
    }
    lines.push(line);
  }
  return lines;
}

/**
 * Shrink until it fits, rather than clipping.
 *
 * A headline that overflows its card is the one failure mode that makes an export unusable,
 * and it is the failure a model writing free-form copy will produce eventually however clearly
 * the brief states a word count. So the geometry wins: the renderer drops a step at a time
 * until the block fits the box it was given. `marks-and-anatomy.md` says a label that will not
 * fit does not get clipped — measure first. This measures.
 */
function fitBlock(ctx, text, { maxWidth, maxHeight, spec, start, min, lineHeight }) {
  let size = start;
  while (size > min) {
    ctx.font = font(spec, size);
    const lines = wrap(ctx, text, maxWidth);
    if (lines.length * size * lineHeight <= maxHeight) return { size, lines };
    size -= Math.max(1, Math.round(size * 0.06));
  }
  ctx.font = font(spec, min);
  return { size: min, lines: wrap(ctx, text, maxWidth) };
}

function drawLines(ctx, lines, x, y, size, lineHeight) {
  let cursor = y;
  for (const line of lines) {
    ctx.fillText(line, x, cursor);
    cursor += size * lineHeight;
  }
  return cursor;
}

/** The wordmark, as geometry rather than type — the same path the app draws. */
function wordmark(ctx, x, y, height, color) {
  const path = new Path2D(
    "M 9.75 -90.25 L 46 -9.75 L 82.25 -90.25 M 106.949 -46 L 187.051 -46 A 40.25 40.25 0 0 0 147 -90.25A 40.25 40.25 0 1 0 176.912 -23.067 M 214.75 -116.25 L 214.75 -9.75 M 249.25 -116.25 L 249.25 -9.75 M 283.75 -90.25 L 283.75 -47.5 A 37.75 37.75 0 0 0 359.25 -47.5 M 359.25 -90.25 L 359.25 -9.75 M 393.75 -9.75 L 393.75 -58.25 A 32 32 0 0 1 457.75 -58.25 M 457.75 -58.25 L 457.75 -9.75 M 457.75 -58.25 A 32 32 0 0 1 521.75 -58.25 M 521.75 -58.25 L 521.75 -9.75",
  );
  const scale = height / 126;
  ctx.save();
  ctx.translate(x, y + height);
  ctx.scale(scale, scale);
  ctx.strokeStyle = color;
  ctx.lineWidth = 19.5;
  ctx.lineCap = "round";
  ctx.lineJoin = "round";
  ctx.stroke(path);
  ctx.restore();
}

/**
 * Draw one card.
 *
 * `progress` runs 0 → 1 and is what makes the animated export possible: the still export calls
 * this once at 1, the recorder calls it sixty times. Everything that moves reads from it, and
 * nothing else in the function knows whether it is drawing a frame or a poster.
 */
export function drawCard(ctx, spec, width, height, progress = 1) {
  const p = PALETTES[spec.palette] || PALETTES.cream;
  const scale = width / 1080;
  const margin = 96 * scale;
  const inner = width - margin * 2;

  ctx.save();
  ctx.fillStyle = p.bg;
  ctx.fillRect(0, 0, width, height);

  // Every `cursor` below is the top of a block, so the whole function measures in one
  // direction. Set once, not per-branch: an eyebrow-less card left on the default alphabetic
  // baseline drew its headline a full ascender above where the layout put it.
  ctx.textBaseline = "top";

  const eased = progress >= 1 ? 1 : 1 - Math.pow(1 - progress, 3);
  ctx.globalAlpha = Math.min(1, eased * 1.15);
  // A small settle upward rather than a slide: the card is a page, not a slide deck.
  ctx.translate(0, (1 - eased) * 24 * scale);

  const top = margin * 1.35;
  const bottom = height - margin * 1.35;
  let cursor = top;

  if (spec.eyebrow) {
    ctx.font = font(LABEL, 26 * scale);
    ctx.fillStyle = p.accent;
    const tracked = String(spec.eyebrow).toUpperCase();
    // Letter-spacing by hand: canvas has `letterSpacing` only in newer Chrome, and the
    // design system's +0.6 tracking on a label is not optional decoration — it is what keeps
    // an uppercase run from reading as a shout.
    let x = margin;
    for (const ch of tracked) {
      ctx.fillText(ch, x, cursor);
      x += ctx.measureText(ch).width + 1.6 * scale;
    }
    cursor += 26 * scale * 2.1;
  }

  const template = spec.template || "quote";

  if (template === "stat") {
    const fitted = fitBlock(ctx, spec.headline || "", {
      maxWidth: inner,
      maxHeight: (bottom - cursor) * 0.5,
      spec: ROUNDED_BOLD,
      start: 220 * scale,
      min: 72 * scale,
      lineHeight: 1.02,
    });
    ctx.fillStyle = p.ink;
    ctx.font = font(ROUNDED_BOLD, fitted.size);
    cursor = drawLines(ctx, fitted.lines, margin, cursor, fitted.size, 1.02);
    cursor += 22 * scale;
    if (spec.subhead) {
      const sub = fitBlock(ctx, spec.subhead, {
        maxWidth: inner,
        maxHeight: bottom - cursor - 90 * scale,
        spec: TEXT,
        start: 44 * scale,
        min: 24 * scale,
        lineHeight: 1.4,
      });
      ctx.fillStyle = p.muted;
      ctx.font = font(TEXT, sub.size);
      drawLines(ctx, sub.lines, margin, cursor, sub.size, 1.4);
    }
  } else if (template === "prompt") {
    // The app's PromptCard, at poster scale: a 2pt rule down the left of the quoted prompt,
    // tinted to the kind. Here it is always the accent, because a social card has no kind.
    const ruleX = margin;
    const textX = margin + 34 * scale;
    const fitted = fitBlock(ctx, spec.headline || "", {
      maxWidth: inner - 34 * scale,
      maxHeight: (bottom - cursor) * 0.62,
      spec: ROUNDED,
      start: 92 * scale,
      min: 40 * scale,
      lineHeight: 1.3,
    });
    ctx.fillStyle = p.ink;
    ctx.font = font(ROUNDED, fitted.size);
    const blockTop = cursor;
    const blockEnd = drawLines(ctx, fitted.lines, textX, cursor, fitted.size, 1.3);
    ctx.fillStyle = p.rule;
    ctx.fillRect(ruleX, blockTop, 6 * scale, (blockEnd - blockTop) * eased);
    cursor = blockEnd + 26 * scale;
    if (spec.subhead) {
      const sub = fitBlock(ctx, spec.subhead, {
        maxWidth: inner,
        maxHeight: bottom - cursor - 90 * scale,
        spec: TEXT,
        start: 40 * scale,
        min: 22 * scale,
        lineHeight: 1.45,
      });
      ctx.fillStyle = p.muted;
      ctx.font = font(TEXT, sub.size);
      drawLines(ctx, sub.lines, margin, cursor, sub.size, 1.45);
    }
  } else {
    // `quote` and `announcement` share a shape and differ in weight — a quote is the sentence
    // itself, an announcement is news about it.
    const isNews = template === "announcement";
    const fitted = fitBlock(ctx, spec.headline || "", {
      maxWidth: inner,
      maxHeight: (bottom - cursor) * (spec.subhead ? 0.62 : 0.9),
      spec: isNews ? ROUNDED_BOLD : ROUNDED,
      start: (isNews ? 104 : 116) * scale,
      min: 44 * scale,
      lineHeight: 1.22,
    });
    ctx.fillStyle = p.ink;
    ctx.font = font(isNews ? ROUNDED_BOLD : ROUNDED, fitted.size);
    cursor = drawLines(ctx, fitted.lines, margin, cursor, fitted.size, 1.22);
    cursor += 28 * scale;
    if (spec.subhead) {
      const sub = fitBlock(ctx, spec.subhead, {
        maxWidth: inner,
        maxHeight: bottom - cursor - 90 * scale,
        spec: TEXT,
        start: 44 * scale,
        min: 24 * scale,
        lineHeight: 1.45,
      });
      ctx.fillStyle = p.muted;
      ctx.font = font(TEXT, sub.size);
      drawLines(ctx, sub.lines, margin, cursor, sub.size, 1.45);
    }
  }

  ctx.globalAlpha = 1;
  ctx.setTransform(1, 0, 0, 1, 0, 0);
  wordmark(ctx, margin, height - margin - 44 * scale, 44 * scale, p.ink);
  ctx.restore();
}

/** A full-size offscreen canvas with the card on it. */
export function renderToCanvas(spec, platform) {
  const [width, height] = SIZES[platform] || SIZES.generic;
  const canvas = document.createElement("canvas");
  canvas.width = width;
  canvas.height = height;
  drawCard(canvas.getContext("2d"), spec, width, height, 1);
  return canvas;
}

export async function toPngBlob(spec, platform) {
  const canvas = renderToCanvas(spec, platform);
  return new Promise((resolve) => canvas.toBlob(resolve, "image/png"));
}

/**
 * The same card as a JPEG, which is the only thing Instagram will publish.
 *
 * **Not a preference and not a size optimisation.** Meta's content-publishing documentation
 * says JPEG is the only supported image format, and a PNG does not fail in a way anybody could
 * act on — the container comes back in `ERROR` state rather than with a message naming the
 * format. So the download button keeps handing you a PNG, which is the better file to keep, and
 * anything on its way to a feed goes through here.
 *
 * Quality 0.92 rather than 1.0: above about 0.95 a JPEG of flat colour and type gains file size
 * without gaining anything a person can see, and the card is flat colour and type.
 *
 * The canvas is opaque — `drawCard` fills the background before it draws anything — so there is
 * no alpha to lose. A transparent canvas encoded as JPEG comes out with a black background, and
 * that is the bug this comment exists to stop somebody reintroducing by "simplifying" the fill.
 */
export async function toJpegBlob(spec, platform, quality = 0.92) {
  const canvas = renderToCanvas(spec, platform);
  const blob = await new Promise((resolve) => canvas.toBlob(resolve, "image/jpeg", quality));
  // `toBlob` hands back null rather than throwing when it cannot encode. Left alone that
  // becomes an empty POST body and a server error reading "that is not a JPEG", which sends
  // the next person to the wrong file entirely.
  if (!blob) throw new Error("the browser could not encode the card as a JPEG");
  return blob;
}

/**
 * Record the same card as a short WebM.
 *
 * **This is the only video this feature can produce without a vendor**, and it is worth being
 * precise about what it is: an animated brand card, not generated footage. It is genuinely
 * useful — a card that settles in is a Reel or a Story that stops a thumb — and it is not a
 * substitute for the diffusion-model video a provider would render.
 *
 * `captureStream` + `MediaRecorder` is a browser API with no polyfill and no fallback here;
 * Chrome and Edge support it, Safari does not record WebM. The console checks and says so
 * rather than handing back a zero-byte file.
 */
export function canRecord() {
  return (
    !IS_TEST &&
    typeof MediaRecorder !== "undefined" &&
    typeof HTMLCanvasElement.prototype.captureStream === "function" &&
    MediaRecorder.isTypeSupported("video/webm")
  );
}

export function recordCard(spec, platform, seconds = 4) {
  const [width, height] = SIZES[platform] || SIZES.generic;
  const canvas = document.createElement("canvas");
  canvas.width = width;
  canvas.height = height;
  const ctx = canvas.getContext("2d");
  const fps = 30;
  const stream = canvas.captureStream(fps);
  const recorder = new MediaRecorder(stream, { mimeType: "video/webm", videoBitsPerSecond: 8e6 });
  const chunks = [];
  recorder.ondataavailable = (event) => event.data.size && chunks.push(event.data);

  return new Promise((resolve) => {
    let settled = false;
    const finish = () => {
      if (settled) return;
      settled = true;
      clearInterval(painter);
      clearTimeout(stopper);
      clearTimeout(deadline);
      resolve(new Blob(chunks, { type: "video/webm" }));
    };
    recorder.onstop = finish;

    // The first frame is painted before `start()` so the stream never opens on a blank canvas
    // — a recorder that captures one empty frame produces a clip that begins with a flash.
    drawCard(ctx, spec, width, height, 0);
    recorder.start();

    const started = performance.now();
    const total = seconds * 1000;
    // `setInterval`, not `requestAnimationFrame`. rAF does not fire in a background tab, and
    // a recorder driven by it hangs forever with the button stuck on "Recording…" — which is
    // exactly what happened the first time this was exercised from a tab that had lost focus.
    const painter = setInterval(() => {
      const elapsed = performance.now() - started;
      // The card settles over the first third and then holds. Holding matters more than the
      // motion: a post still animating when the thumb arrives is a post nobody read.
      drawCard(ctx, spec, width, height, Math.min(1, elapsed / (total / 3)));
    }, 1000 / fps);

    const stopper = setTimeout(() => recorder.state !== "inactive" && recorder.stop(), total);
    // Belt and braces. `onstop` not firing is a browser bug rather than a state this code can
    // reach, and the cost of being wrong about that is a spinner that never stops.
    const deadline = setTimeout(finish, total + 4000);
  });
}

/* --- The treatment recorder -----------------------------------------------------------------
 *
 * A scene graph, drawn card by card and captured as one WebM. **This is the whole video
 * renderer for this product** — phase 120 removed the vendor that used to generate footage, and
 * this section plus `drawCard` above are what replaced it.
 *
 * **The browser is the renderer, and that is a constraint rather than an accident.** `drawCard`
 * is the only implementation of the Vellum card in existence. A second one server-side would be
 * a second thing to keep in step with the design system, and it would put Chromium in a Python
 * image to run it. So the timeline lives next to the renderer and the pixels are made where the
 * pixels are already made.
 *
 * Every scene is drawn **once**, into its own full-size offscreen canvas, before recording
 * starts. A card is static within its scene — `drawCard(..., 1)` is the finished poster — so
 * re-running the type fitter sixty times a second would be the same work repeated for nothing,
 * and at 1080x1920 it is enough work to drop frames. Each recorded frame is then one or two
 * `drawImage` calls, which is the cheapest thing a canvas does.
 */

/** 12–16px at 1080 wide, scaled with the card. The whole amplitude of the only translate here. */
const RISE_PX = 14;

/** How much room the recording is given per second. Flat colour and type land far under this. */
const BITS_PER_SECOND = 5e6;

/** How long past a treatment's own runtime the recorder may go before it is abandoned.
 *
 * Generous: the encode happens after `stop()`, and a long treatment on a slow machine can take
 * a second or two to flush its last chunks. Short enough that a wedged recorder does not leave
 * the console stuck for the life of the tab. */
const WATCHDOG_GRACE_MS = 15_000;

/** The best WebM the browser will actually record, or null if it will not record one at all. */
function pickMimeType() {
  if (IS_TEST || typeof MediaRecorder === "undefined") return null;
  for (const type of ["video/webm;codecs=vp9", "video/webm;codecs=vp8", "video/webm"]) {
    if (MediaRecorder.isTypeSupported(type)) return type;
  }
  return null;
}

/** Every scene as a finished still, at the real output size. */
function paintScenes(scenes, width, height) {
  return scenes.map((scene) => {
    const canvas = document.createElement("canvas");
    canvas.width = width;
    canvas.height = height;
    drawCard(canvas.getContext("2d"), scene, width, height, 1);
    return canvas;
  });
}

/**
 * One frame of the timeline, composited from the pre-painted stills.
 *
 * Exported because the recorder is not necessarily its only caller — anything that wants to show
 * the treatment at a moment in time must paint through this rather than reimplementing it, or a
 * preview can be wrong about the thing it is previewing. **There is no such caller today**; the
 * composer shows the scene list and the still card and has no scrubber.
 */
export function paintFrame(ctx, scenes, stills, tMs, width, height) {
  const at = sceneAt(scenes, tMs);
  if (at.index < 0) return at;

  ctx.setTransform(1, 0, 0, 1, 0, 0);
  ctx.globalAlpha = 1;
  // The incoming card's own background, so a fade or a rise comes up out of the page rather
  // than out of black. `drawCard` fills this too; painting it here is what covers the strip a
  // rise opens at the **top** — the offset is positive, so the card starts low and settles up,
  // leaving rows [0, dy) uncovered — and what a crossfade needs when there is nothing beneath.
  ctx.fillStyle = (PALETTES[scenes[at.index].palette] || PALETTES.cream).bg;
  ctx.fillRect(0, 0, width, height);

  if (at.previous >= 0) ctx.drawImage(stills[at.previous], 0, 0);

  ctx.globalAlpha = at.enterAlpha;
  ctx.drawImage(stills[at.index], 0, at.rise * RISE_PX * (width / 1080));
  ctx.globalAlpha = 1;
  return at;
}

/**
 * Record a scene graph and hand back the WebM.
 *
 * **It refuses to start in a hidden tab, and aborts loudly if the tab is hidden mid-record.**
 * This is the single most likely user-facing defect in the whole feature and the reason it is
 * handled here rather than mentioned in a comment. `requestAnimationFrame` does not fire in a
 * backgrounded tab; a recorder driven by it in one produces a file that is *silently short* —
 * the right container, the right codec, playable, and missing however many seconds the tab
 * spent behind something else. There is nothing downstream that can tell that file from a
 * correct one, so the only place it can be caught is before it exists.
 *
 * `requestAnimationFrame` and not `setInterval`, for the visible-tab case: `setInterval` drifts
 * against the compositor, and a frame handed to `captureStream` at a time the compositor did
 * not paint is a frame the recorder duplicates or drops.
 */
export function recordTreatment(scenes, platform, { onProgress } = {}) {
  const mimeType = pickMimeType();
  if (!mimeType) {
    return Promise.reject(
      new Error("This browser cannot record WebM from a canvas. Chrome and Edge can; Safari cannot."),
    );
  }
  if (typeof HTMLCanvasElement.prototype.captureStream !== "function") {
    return Promise.reject(new Error("This browser cannot capture a canvas as a video stream."));
  }
  if (!scenes || scenes.length < 2) {
    return Promise.reject(new Error("A treatment needs at least two scenes to record."));
  }
  if (document.visibilityState !== "visible") {
    return Promise.reject(
      new Error("Bring this tab to the front before recording — a background tab records a short file."),
    );
  }

  const [width, height] = SIZES[platform] || SIZES.generic;
  const total = totalMs(scenes);

  // **Every step that can throw is in here, and the stream is stopped if a later one does.**
  // `paintScenes` throws on a canvas the browser will not allocate, `captureStream` throws on a
  // detached canvas, and the `MediaRecorder` constructor throws on a mime type the browser
  // accepted from `isTypeSupported` but will not actually record. Left bare, the first two threw
  // *synchronously* out of a function documented to return a promise, and the third left a live
  // capture stream behind with nothing holding a reference to stop it.
  let canvas, ctx, stills, stream, recorder;
  try {
    canvas = document.createElement("canvas");
    canvas.width = width;
    canvas.height = height;
    ctx = canvas.getContext("2d");
    stills = paintScenes(scenes, width, height);
    stream = canvas.captureStream(30);
    recorder = new MediaRecorder(stream, { mimeType, videoBitsPerSecond: BITS_PER_SECOND });
  } catch (error) {
    if (stream) for (const track of stream.getTracks()) track.stop();
    return Promise.reject(new Error(`The recorder could not start: ${error.message}`));
  }

  const chunks = [];
  recorder.ondataavailable = (event) => event.data.size && chunks.push(event.data);

  return new Promise((resolve, reject) => {
    let settled = false;
    let frame = 0;
    let watchdog = 0;
    let aborted = null;
    // Set the moment the last frame has been drawn and the recorder is about to be stopped.
    // Everything after that point is a complete recording waiting on `onstop`.
    let finishing = false;

    const teardown = () => {
      document.removeEventListener("visibilitychange", onHidden);
      cancelAnimationFrame(frame);
      clearTimeout(watchdog);
      for (const track of stream.getTracks()) track.stop();
    };
    const fail = (error) => {
      if (settled) return;
      settled = true;
      teardown();
      if (recorder.state !== "inactive") recorder.stop();
      reject(error);
    };

    recorder.onstop = () => {
      if (settled) return;
      settled = true;
      teardown();
      if (aborted) reject(aborted);
      else resolve(new Blob(chunks, { type: mimeType }));
    };
    recorder.onerror = (event) =>
      fail(new Error(`The recorder failed: ${event.error?.name || "unknown"}.`));

    function onHidden() {
      if (document.visibilityState === "visible" || settled || aborted) return;
      // **Two ways this is already over, and neither is an abort.** `stop()` sets `state` to
      // "inactive" synchronously and only *queues* the stop event, so a recording that ended a
      // moment ago is inactive with its `onstop` in flight; and `finishing` covers the one frame
      // between the last draw and that `stop()`, where the state is still "recording" but every
      // frame has already been drawn. Without both, hiding the tab in that frame throws away a
      // complete file.
      //
      // **Before `finishing` is set, aborting is correct rather than over-eager.** At wall-clock
      // `total` the loop has usually not ticked yet, so frames really are still owed — and no
      // threshold could tell "five milliseconds short" from "five seconds short" without being
      // exactly the fudge that lets a silently-short file through.
      if (recorder.state === "inactive") return;
      if (finishing) {
        // **Stop it here, because the `stop()` this was waiting for cannot run.** Every frame is
        // drawn and the trailing `requestAnimationFrame` holds the `stop()` — and rAF is parked
        // in a hidden tab, which is the whole premise of this guard. Returning early would leave
        // the recorder running until the watchdog abandoned a *complete* recording fifteen
        // seconds later, blaming the recorder for the tab.
        recorder.stop();
        return;
      }
      // Abort rather than pause and resume. The frames the tab missed cannot be recovered —
      // `captureStream` samples the canvas in real time — so a resumed recording is a file with
      // a hole in it, which is the thing this whole guard exists to make impossible.
      aborted = new Error(
        "The tab went to the background mid-recording, so the file would have been short. " +
          "Nothing was uploaded — bring this tab to the front and record again.",
      );
      recorder.stop();
    }
    document.addEventListener("visibilitychange", onHidden);

    // **Belt and braces, and it rejects rather than resolving.** `onstop` not firing is a browser
    // bug rather than a state this code can reach, and the cost of being wrong about that is a
    // button stuck on "Recording…" for the life of the tab — which is why `recordCard`, above,
    // has had a deadline timer since it was written. This one differs from that one on purpose: a
    // deadline that *resolved* would hand back however many chunks had arrived, which is the
    // silently-short file this whole function exists to make impossible.
    watchdog = setTimeout(
      () =>
        fail(
          new Error(
            "The recorder stopped responding and the recording was abandoned. Nothing was " +
              "uploaded. Reload the console and try again.",
          ),
        ),
      total + WATCHDOG_GRACE_MS,
    );

    // The first frame is painted before `start()` so the stream never opens on a blank canvas —
    // a recorder that captures one empty frame produces a clip that begins with a flash.
    try {
      paintFrame(ctx, scenes, stills, 0, width, height);
      recorder.start();
    } catch (error) {
      fail(new Error(`The recorder could not start: ${error.message}`));
      return;
    }
    const began = performance.now();

    const tick = () => {
      if (settled || aborted) return;
      let at;
      try {
        const elapsed = performance.now() - began;
        at = paintFrame(ctx, scenes, stills, Math.min(elapsed, total), width, height);
        if (elapsed < total) {
          frame = requestAnimationFrame(tick);
        } else {
          finishing = true;
          // **One more frame after the last one is drawn.** `captureStream` samples the canvas
          // when the compositor paints it, so stopping in the same turn as the final draw ends
          // the recording before that frame has been sampled and the last scene loses its
          // ending.
          frame = requestAnimationFrame(() => {
            if (settled) return;
            if (recorder.state !== "inactive") recorder.stop();
          });
        }
      } catch (error) {
        // A throw inside a `requestAnimationFrame` callback escapes silently and schedules no
        // successor, so without this the loop simply stops: the recorder runs on, `onstop` never
        // comes, and the promise never settles. Reject instead.
        fail(error instanceof Error ? error : new Error(String(error)));
        return;
      }
      // **The caller's callback runs last and cannot take the recording down with it.** It is
      // cosmetic — a line of text in the composer — and the recording is the deliverable, so a
      // bug in it must not be the reason a good file is lost. Deliberately silent: there is
      // nowhere in this module to report it that is not itself the caller's problem.
      try {
        onProgress?.({ index: at.index, of: scenes.length, elapsed: performance.now() - began, total });
      } catch {
        /* a broken progress reporter is not a broken recording */
      }
    };
    frame = requestAnimationFrame(tick);
  });
}

export function download(blob, filename) {
  const url = URL.createObjectURL(blob);
  const link = document.createElement("a");
  link.href = url;
  link.download = filename;
  link.click();
  // Revoked on the next tick rather than immediately: Chrome needs the URL to survive the
  // click it just handled, and revoking synchronously produces an empty file about a third
  // of the time.
  setTimeout(() => URL.revokeObjectURL(url), 1000);
}
