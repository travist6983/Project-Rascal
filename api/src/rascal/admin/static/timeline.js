/* Where a scene graph is at a given millisecond. Pure, and alone in this file on purpose.
 *
 * There is no JavaScript test runner in this repository and this phase does not add one, so the
 * only assurance available for the browser half is that the part whose correctness actually
 * matters can be read and reasoned about without running it. That part is this: a function of
 * (scenes, t) with no canvas, no clock, no DOM and no state, whose output is the whole input to
 * the painter. Everything above it is drawing.
 *
 * **Its boundaries must equal the server's caption cue boundaries exactly.** `scenes.py` walks
 * the same running sum of `duration_ms` in the same order with the same integer arithmetic, and
 * that is what makes "the captions line up with the cards" a property rather than a hope. If
 * this function ever starts rounding, interpolating, or skipping a scene with no headline, the
 * two drift and nothing in the system notices — the cue times would still be internally
 * consistent and would describe a different video.
 *
 * A scene boundary belongs to the scene that starts there: at exactly 1500ms of a 1500ms first
 * scene, you are in scene two at localMs 0. That is the same half-open convention WebVTT uses,
 * and picking the other one would put every cue one frame out.
 */

/** Cumulative scene ends, in order. The one place the running sum is written. */
export function boundaries(scenes) {
  const ends = [];
  let clock = 0;
  for (const scene of scenes) {
    clock += Math.max(0, Math.trunc(scene.duration_ms) || 0);
    ends.push(clock);
  }
  return ends;
}

/** The whole runtime, in milliseconds. */
export function totalMs(scenes) {
  return boundaries(scenes).at(-1) || 0;
}

/* How long a transition takes to complete, from the moment its scene begins.
 *
 * **Motion doctrine: high density, low amplitude.** Three transitions and no more. `cut` is a
 * hard switch with no window at all. `fade` is a crossfade under 300ms. `rise` is a fade plus a
 * small upward settle of the whole card, under 400ms. No scale, no rotation, no parallax, no
 * per-character animation — the card is the thing and the motion is punctuation. These numbers
 * are short deliberately: a post still animating when the thumb arrives is a post nobody read.
 */
export const ENTER_MS = { cut: 0, fade: 260, rise: 340 };

/** Ease-out cubic. The same curve `drawCard` uses for its own settle, so nothing reads as two systems. */
const eased = (t) => 1 - Math.pow(1 - t, 3);

/**
 * Where the graph is at `tMs`.
 *
 * Returns:
 *   `index`      — which scene is on screen
 *   `previous`   — the scene index underneath it during a crossfade, or -1
 *   `localMs`    — milliseconds into that scene
 *   `progress`   — 0 to 1 through the scene, for anything that wants the whole span
 *   `enterAlpha` — 0 to 1, the incoming card's opacity; 1 once the transition is done
 *   `rise`       — 0 to 1, how much of the upward settle is left to travel; 0 unless `rise`
 *   `done`       — whether `tMs` is at or past the end of the graph
 *
 * `rise` is unit-free rather than a pixel count. The painter multiplies it by the card's own
 * scale, so the motion is the same fraction of the card at 1080x1920 as at any other size —
 * a fixed pixel offset would be a different gesture on a different platform.
 */
export function sceneAt(scenes, tMs) {
  if (!scenes || !scenes.length) {
    return { index: -1, previous: -1, localMs: 0, progress: 0, enterAlpha: 1, rise: 0, done: true };
  }
  const ends = boundaries(scenes);
  const total = ends.at(-1);
  const t = Math.max(0, Math.min(tMs, total));

  // The first scene whose end is strictly past `t`. At an exact boundary that is the next
  // scene, which is the half-open convention the module comment describes. Past the end it
  // finds nothing and we hold the last frame rather than going blank.
  let index = ends.findIndex((end) => t < end);
  if (index === -1) index = scenes.length - 1;

  const start = index === 0 ? 0 : ends[index - 1];
  const duration = Math.max(1, ends[index] - start);
  const localMs = Math.min(t - start, duration);

  // **The scene's own transition, including on the opening scene.** This used to floor scene 0
  // at `ENTER_MS.fade`, on the reasoning that an opening card has nothing to come in over — but
  // that is an argument about what it fades *from*, which `paintFrame` already answers by
  // filling the palette background first. It is not a reason to override a `cut` the author
  // asked for, and a graph that opens on a hard cut is a legitimate thing to write. The module
  // comment says `cut` is a hard switch with no window at all; now it is.
  const window = ENTER_MS[scenes[index].transition] ?? 0;
  const entering = window > 0 && localMs < window;
  const raw = window > 0 ? Math.min(1, localMs / window) : 1;

  return {
    index,
    // **Only `fade` has something underneath it.** A `rise` is a fade *from the background*
    // plus a translate: the incoming card is drawn a few pixels **down** and settles up, so the
    // uncovered strip is at the top of the frame. Crossfading would show the outgoing card
    // through it — a band of the previous scene along the top edge — which is not the gesture.
    previous: entering && index > 0 && scenes[index].transition === "fade" ? index - 1 : -1,
    localMs,
    progress: localMs / duration,
    enterAlpha: entering ? eased(raw) : 1,
    rise: scenes[index].transition === "rise" && entering ? 1 - eased(raw) : 0,
    done: tMs >= total,
  };
}
