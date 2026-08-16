// Renders the chosen app icon SVG into the iOS asset catalogue.
//
//   node docs/app-icon/render-appicon.mjs
//
// `rascal-icon-fan.svg` is the source of truth and the PNG is a build product — never edit
// `AppIcon-1024.png` by hand, re-run this instead. What the App Store requires of that file is
// 1024x1024, **no alpha channel**, and sRGB; all three are asserted below rather than assumed,
// because an icon with alpha is rejected at upload time and nothing before that says so.
//
// The render goes through headless Chrome. That is not a preference — this SVG uses `feDropShadow`
// on five separate `clip-path` groups, and the lightweight rasterisers either drop the filter or
// resolve the clip in the wrong user space, which quietly flattens the fan into one card.
//
// It draws at 2048 and halves it. Chrome antialiases a 4pt scrubber track poorly at 1024 native;
// supersampling costs one extra second and is the difference between a clean edge and a fringe.
//
// This is the only step between the SVG and the phone. There is no separate 60pt or 76pt asset —
// `actool` derives every home-screen size from this one file.

import { execFileSync } from 'node:child_process';
import { existsSync, mkdtempSync, readdirSync, rmSync, writeFileSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { dirname, join, resolve } from 'node:path';
import { fileURLToPath } from 'node:url';

const HERE = dirname(fileURLToPath(import.meta.url));
const REPO = resolve(HERE, '..', '..');

const SVG = join(HERE, 'rascal-icon-fan.svg');
const DEST = join(REPO, 'ios/Rascal/Rascal/Assets.xcassets/AppIcon.appiconset/AppIcon-1024.png');

const SIZE = 1024;
const SCALE = 2;

/* ── finding a browser ───────────────────────────────────────────────── */
// Playwright's headless shell first because it is the smaller download and the one most likely to
// be present already; a full Chrome works identically for `--screenshot`.

function findChrome() {
  const cache = join(process.env.HOME ?? '', 'Library/Caches/ms-playwright');
  if (existsSync(cache)) {
    const shells = readdirSync(cache)
      .filter((d) => d.startsWith('chromium_headless_shell-'))
      .sort((a, b) => Number(b.split('-')[1]) - Number(a.split('-')[1]));
    for (const shell of shells) {
      const bin = join(cache, shell, 'chrome-headless-shell-mac-arm64', 'chrome-headless-shell');
      if (existsSync(bin)) return bin;
    }
  }
  for (const app of [
    '/Applications/Google Chrome.app/Contents/MacOS/Google Chrome',
    '/Applications/Chromium.app/Contents/MacOS/Chromium',
  ]) {
    if (existsSync(app)) return app;
  }
  throw new Error(
    'No Chrome found. Install Google Chrome, or run `npx playwright install chromium-headless-shell`.'
  );
}

/* ── render ──────────────────────────────────────────────────────────── */
// Chrome centres a standalone SVG document in the viewport and leaves a margin, so the SVG is
// framed in a zero-margin page at an exact pixel size and the whole viewport is captured.

const work = mkdtempSync(join(tmpdir(), 'rascal-icon-'));
try {
  const page = join(work, 'frame.html');
  writeFileSync(
    page,
    `<!doctype html><meta charset="utf-8">
<style>html,body{margin:0;padding:0}img{display:block;width:${SIZE}px;height:${SIZE}px}</style>
<img src="file://${SVG}">
`
  );

  const shot = join(work, 'icon@2x.png');
  execFileSync(
    findChrome(),
    [
      '--headless',
      '--disable-gpu',
      '--hide-scrollbars',
      `--force-device-scale-factor=${SCALE}`,
      `--window-size=${SIZE},${SIZE}`,
      `--screenshot=${shot}`,
      `file://${page}`,
    ],
    { stdio: ['ignore', 'ignore', 'pipe'] }
  );

  if (!existsSync(shot)) throw new Error('Chrome produced no screenshot.');

  execFileSync('/usr/bin/sips', ['-z', String(SIZE), String(SIZE), shot, '--out', DEST], {
    stdio: ['ignore', 'ignore', 'pipe'],
  });

  /* ── assert what the App Store checks ──────────────────────────────── */

  const read = (key) =>
    execFileSync('/usr/bin/sips', ['-g', key, DEST], { encoding: 'utf8' }).trim().split(/:\s*/).pop();

  const got = {
    width: read('pixelWidth'),
    height: read('pixelHeight'),
    alpha: read('hasAlpha'),
  };

  const problems = [];
  if (got.width !== String(SIZE) || got.height !== String(SIZE)) {
    problems.push(`expected ${SIZE}x${SIZE}, got ${got.width}x${got.height}`);
  }
  if (got.alpha !== 'no') {
    problems.push('the PNG carries an alpha channel — App Store Connect rejects that on upload');
  }
  if (problems.length) throw new Error(problems.join('; '));

  console.log(`wrote ${DEST.replace(`${REPO}/`, '')} — ${got.width}x${got.height}, no alpha`);
} finally {
  rmSync(work, { recursive: true, force: true });
}
