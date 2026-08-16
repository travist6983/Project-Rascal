// RASCAL app icon explorations.
//
// The stacked-layer silhouette comes from the reference Travis shared. What each
// layer *contains* is lifted from Entry Detail (docs/entry-detail/…dc.html) — the
// motif that identifies a kind on its own screen, at icon scale:
//
//   photo    the media field with the cream sheet resting on it, grab handle and all
//   video    the play disc, and the scrubber that lives in the sheet not on the picture
//   audio    the waveform — played bars solid, the rest at a third
//   written  the lavender question block, then the words
//   did it   the cream disc with the sage check: no artifact, so the mark is the artifact
//
// A band across the bottom of a layer is the right shape for these: a scrubber, a
// waveform and three lines of text are horizontal already.
//
// Colours are docs/design-system.md, not the mockups.
//
//   node docs/app-icon/generate.mjs

import { writeFileSync } from 'node:fs';
import { dirname, join } from 'node:path';
import { fileURLToPath } from 'node:url';

const OUT = dirname(fileURLToPath(import.meta.url));

/* ── palette ─────────────────────────────────────────────────────────── */

const C = {
  terracotta: '#C05A2B',
  peach: '#FBEDE2',
  peri: '#5566D6',
  lav: '#E9EBFB',
  sage: '#E8F0E6',
  sageInk: '#4B7A4F',
  ink: '#23253C',
  canvas: '#FDFAF4',
  surface: '#FFFDF9',
  handle: '#DCD2C4',
  track: '#E6DCCE',
};

const n = (v) => (Math.round(v * 100) / 100).toString();

/* ── geometry ────────────────────────────────────────────────────────── */
// Five layers, each wider and lower than the one in front. What shows of a back
// layer is a full-width band plus a sliver down each side. Bands are deliberately
// fat — a 95pt band is what lets a waveform stay a waveform at 120px.

const LAYERS = [
  { key: 'didit',   x: 144, y: 324, w: 736, h: 528, r: 110, spin: -3.0 },
  { key: 'written', x: 186, y: 286, w: 652, h: 471, r: 102, spin:  2.2 },
  { key: 'audio',   x: 228, y: 248, w: 568, h: 414, r:  94, spin: -1.7 },
  { key: 'video',   x: 270, y: 210, w: 484, h: 357, r:  86, spin:  1.4 },
  { key: 'photo',   x: 312, y: 172, w: 400, h: 300, r:  78, spin:  0 },
];

const byKey = Object.fromEntries(LAYERS.map((l) => [l.key, l]));
const bot = (l) => l.y + l.h;

// The band of a back layer: from the bottom edge of the layer in front of it
// down to its own bottom edge.
function band(key) {
  const i = LAYERS.findIndex((l) => l.key === key);
  const me = LAYERS[i];
  const front = LAYERS[i + 1];
  const top = front ? bot(front) : me.y;
  return { ...me, top, bottom: bot(me), mid: (top + bot(me)) / 2 };
}

// How far the layer's side edge has bowed inward at a given y, so a motif can be
// kept clear of the corner curve.
function bow(l, y) {
  const d = Math.min(y - l.y, bot(l) - y);
  return d >= l.r ? 0 : l.r - Math.sqrt(Math.max(0, l.r ** 2 - (l.r - d) ** 2));
}

/* ── primitives ──────────────────────────────────────────────────────── */

const rr = (x, y, w, h, r, fill, extra = '') =>
  `<rect x="${n(x)}" y="${n(y)}" width="${n(w)}" height="${n(h)}" rx="${n(r)}" fill="${fill}"${extra}/>`;

const dot = (cx, cy, r, fill, extra = '') =>
  `<circle cx="${n(cx)}" cy="${n(cy)}" r="${n(r)}" fill="${fill}"${extra}/>`;

function play(cx, cy, size, fill) {
  const h = size, w = size * 0.86, x0 = cx - w * 0.44;
  const j = size * 0.16;
  return `<path d="M ${n(x0)} ${n(cy - h / 2)} L ${n(x0 + w)} ${n(cy)} L ${n(x0)} ${n(cy + h / 2)} Z" fill="${fill}" stroke="${fill}" stroke-width="${n(j)}" stroke-linejoin="round"/>`;
}

function tick(cx, cy, size, stroke) {
  const s = size / 2;
  return `<path d="M ${n(cx - s * 0.8)} ${n(cy + s * 0.04)} L ${n(cx - s * 0.16)} ${n(cy + s * 0.66)} L ${n(cx + s * 0.84)} ${n(cy - s * 0.6)}" fill="none" stroke="${stroke}" stroke-width="${n(size * 0.23)}" stroke-linecap="round" stroke-linejoin="round"/>`;
}

const lines = ({ x, y, gap, thickness, widths, color, fades }) =>
  widths.map((w, i) =>
    rr(x, y + i * gap - thickness / 2, w, thickness, thickness / 2, color, ` opacity="${fades[i]}"`)
  ).join('');

// Entry Detail draws its bars off a cheap trig function and splits them at the
// playhead: played solid, the rest at a third. Both halves matter — a flat
// waveform is decoration, this one is a recording part-way through being heard.
function waveform({ x, y, width, height, bars, color, played }) {
  const pitch = width / bars, w = pitch * 0.55;
  let out = '';
  for (let i = 0; i < bars; i++) {
    const v = Math.abs(Math.sin(i * 0.7) * Math.cos(i * 0.31));
    const h = height * (0.26 + v * 0.74);
    out += rr(x + i * pitch, y - h / 2, w, h, w / 2, color, ` opacity="${i < played ? 0.92 : 0.34}"`);
  }
  return out;
}

function scrubber({ x, y, width, frac, track, fill }) {
  const h = 12;
  return rr(x, y - h / 2, width, h, h / 2, track)
    + rr(x, y - h / 2, width * frac, h, h / 2, fill)
    + dot(x + width * frac, y, 20, fill);
}

/* ── the four bands, in either colour scheme ─────────────────────────── */

function bands(S) {
  const v = band('video'), a = band('audio'), w = band('written'), d = band('didit');

  const vLeft = v.x + bow(v, v.mid) + 34;
  const video =
      dot(vLeft + 33, v.mid, 33, S.disc)
    + play(vLeft + 35, v.mid, 30, S.discInk)
    + scrubber({ x: vLeft + 90, y: v.mid, width: 300, frac: 0.3, track: S.track, fill: S.scrub });

  const aLeft = a.x + bow(a, a.mid) + 40;
  const aWidth = a.w - 2 * (bow(a, a.mid) + 40);
  const audio = waveform({ x: aLeft, y: a.mid, width: aWidth, height: 84, bars: 24, color: S.wave, played: 7 });

  const wLeft = w.x + bow(w, w.mid) + 48;
  const written =
      rr(wLeft, w.mid - 31, 224, 62, 20, S.quoteFill)
    + lines({ x: wLeft + 24, y: w.mid - 11, gap: 22, thickness: 9, widths: [128, 168], color: S.quoteInk, fades: [0.92, 0.5] })
    + lines({ x: wLeft + 254, y: w.mid - 25, gap: 25, thickness: 12, widths: [266, 296, 178], color: S.bodyInk, fades: [0.84, 0.42, 0.42] });

  const dLeft = d.x + bow(d, d.mid) + 36;
  const didit =
      dot(dLeft + 38, d.mid, 38, S.disc)
    + tick(dLeft + 38, d.mid, 38, S.tickInk)
    + rr(dLeft + 100, d.mid - 7, 300, 14, 7, S.tickInk, ' opacity="0.4"');

  return { video, audio, written, didit };
}

/* ── the front card ──────────────────────────────────────────────────── */

// Tinted: the entry screen itself — media field, then the cream sheet resting on
// it with the grab handle, a title and the periwinkle age chip.
function photoSheet(p) {
  const sheetTop = 382;
  return `<g clip-path="url(#clipPhoto)">
    ${rr(p.x, p.y, p.w, p.h, p.r, 'url(#shot)')}
    <path d="M ${p.x} ${sheetTop} L ${p.x} 330 Q ${p.x + 96} 276 ${p.x + 184} 328 Q ${p.x + 278} 376 ${p.x + p.w} 320 L ${p.x + p.w} ${sheetTop} Z" fill="#A0512A" opacity="0.45"/>
    ${dot(p.x + 306, 244, 32, '#FFF4E6', ' opacity="0.94"')}
    ${rr(p.x, sheetTop, p.w, bot(p) - sheetTop, 40, C.canvas)}
    ${rr(477, 398, 70, 10, 5, C.handle)}
    ${rr(p.x + 36, 426, 200, 17, 8.5, C.ink, ' opacity="0.86"')}
    ${rr(p.x + 266, 420, 98, 28, 14, C.lav)}
  </g>`;
}

// Tonal: the reference's own front card — a light face carrying one clean glyph.
function photoGlyph(p) {
  const b = { x: p.x + 46, y: p.y + 46, w: p.w - 92, h: p.h - 92, r: 46 };
  return rr(p.x, p.y, p.w, p.h, p.r, 'url(#face)')
    + rr(b.x, b.y, b.w, b.h, b.r, C.surface)
    + dot(612, 258, 21, C.terracotta)
    + `<path d="M 416 396 L 472 322 L 514 372 L 546 336 L 604 396 Z" fill="${C.terracotta}" stroke="${C.terracotta}" stroke-width="18" stroke-linejoin="round"/>`;
}

/* ── schemes ─────────────────────────────────────────────────────────── */

// Each layer keeps its kind tint. Depth is the shadow one layer drops on the next,
// not a shaded tint — a warmed-down lavender stops being lavender.
const TINT = {
  ground: ['#C96335', '#A4441C'],
  fills: { didit: C.sage, written: C.surface, audio: C.lav, video: C.peach },
  disc: C.surface, discInk: C.terracotta, track: C.track, scrub: C.terracotta,
  wave: C.peri, quoteFill: C.lav, quoteInk: C.peri, bodyInk: C.ink,
  tickInk: C.sageInk,
  front: photoSheet,
  defs: `<linearGradient id="shot" x1="0.1" y1="0" x2="0.85" y2="1">
      <stop offset="0" stop-color="#F6D6AC"/><stop offset="1" stop-color="#C0703A"/>
    </linearGradient>`,
};

// One colour, depth by tone, motifs as light marks. The reference read.
const TONE = {
  ground: ['#D3763F', '#AF4C1F'],
  fills: { didit: '#7E3111', written: '#93401A', audio: '#A64D22', video: '#BB5B2B' },
  disc: '#FAE1CA', discInk: '#B0521F', track: '#FAE1CA', scrub: '#FAE1CA',
  wave: '#FAE1CA', quoteFill: '#FAE1CA', quoteInk: '#FAE1CA', bodyInk: '#FAE1CA',
  tickInk: '#7E3111',
  front: photoGlyph,
  defs: `<linearGradient id="face" x1="0" y1="0" x2="0" y2="1">
      <stop offset="0" stop-color="#F8DFC9"/><stop offset="1" stop-color="#EDC6A6"/>
    </linearGradient>`,
};

// The tonal scheme wants its quote block as a wash rather than a solid.
TONE.quoteWash = true;

/* ── assembly ────────────────────────────────────────────────────────── */

function stack(S, { spin = false } = {}) {
  const art = bands(S);
  const p = byKey.photo;

  const body = LAYERS.map((l) => {
    const inner = l.key === 'photo'
      ? S.front(p)
      : rr(l.x, l.y, l.w, l.h, l.r, S.fills[l.key],
          S === TONE ? '' : '') + art[l.key];
    const t = spin && l.spin
      ? ` transform="rotate(${l.spin} ${n(l.x + l.w / 2)} ${n(l.y + l.h / 2)})"`
      : '';
    return `  <g filter="url(#lift)"${t}>${inner}</g>`;
  }).join('\n');

  return `<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 1024 1024" width="1024" height="1024" role="img" aria-label="RASCAL app icon">
  <defs>
    <linearGradient id="ground" x1="0" y1="0" x2="1" y2="1">
      <stop offset="0" stop-color="${S.ground[0]}"/><stop offset="1" stop-color="${S.ground[1]}"/>
    </linearGradient>
    <filter id="lift" x="-30%" y="-30%" width="160%" height="160%">
      <feDropShadow dx="0" dy="11" stdDeviation="9" flood-color="#63250A" flood-opacity="0.42"/>
    </filter>
    <clipPath id="clipPhoto">${rr(p.x, p.y, p.w, p.h, p.r, '#000')}</clipPath>
    ${S.defs}
  </defs>
  <rect width="1024" height="1024" fill="url(#ground)"/>
${body}
</svg>
`;
}

/* ── contact sheet ───────────────────────────────────────────────────── */

const VARIANTS = [
  { id: 'tinted', title: 'Tinted stack', svg: stack(TINT),
    note: 'Every layer keeps its own kind tint — peach, lavender, cream, sage — the way the entry screens do. The motifs are full strength: periwinkle waveform, terracotta scrubber, sage check.' },
  { id: 'tonal', title: 'Tonal stack', svg: stack(TONE),
    note: 'The reference read: one colour, depth by tone, the motifs as light marks pressed into each layer. Quieter on a home screen; the five kinds are texture rather than statement.' },
  { id: 'scattered', title: 'Scattered stack', svg: stack(TINT, { spin: true }),
    note: 'The tinted stack with a degree or three of rotation on each layer — stacked by hand rather than machined. The motifs tilt with their card.' },
];

const SIZES = [180, 120, 87, 60, 40];

const sheet = () => `<!doctype html>
<meta charset="utf-8">
<title>RASCAL — app icon</title>
<style>
  :root { color-scheme: light; }
  body { margin:0; padding:56px 64px 96px; background:#EFE9DF; color:#23253C;
         font:16px/1.5 "Source Sans 3", system-ui, -apple-system, sans-serif; }
  h1 { font-size:40px; letter-spacing:-.03em; margin:0 0 10px; }
  .lede { color:#6E6A63; max-width:640px; margin:0 0 48px; }
  .v { margin-bottom:58px; padding-bottom:52px; border-bottom:1px solid #DFD6C8; }
  .v:last-child { border:0; }
  h2 { font-size:23px; letter-spacing:-.02em; margin:0 0 6px; }
  header p { color:#6E6A63; max-width:660px; margin:0 0 26px; font-size:15px; }
  .row { display:flex; gap:44px; align-items:flex-start; flex-wrap:wrap; }
  img { display:block; border-radius:22.37%; }
  .big img { width:300px; height:300px; box-shadow:0 18px 44px rgba(35,37,60,.20); }
  .scale { display:flex; gap:24px; align-items:flex-end; padding-top:8px; }
  figcaption { margin-top:9px; font:12px ui-monospace,Menlo,monospace; color:#A8A096; text-align:center; }
  .dark { background:#1B1A21; border-radius:22px; padding:22px 26px; display:flex;
          gap:24px; align-items:flex-end; }
  .dark figcaption { color:#6E6A78; }
</style>
<h1>RASCAL — app icon</h1>
<p class="lede">Three readings of the stacked-layer silhouette. The layers are the five entry kinds,
and each carries the motif that identifies it on its own Entry Detail screen.</p>
${VARIANTS.map((v) => `
<section class="v">
  <header><h2>${v.title}</h2><p>${v.note}</p></header>
  <div class="row">
    <figure class="big"><img src="rascal-icon-${v.id}.svg" alt="${v.title}"><figcaption>1024</figcaption></figure>
    <div class="scale">${SIZES.map((s) =>
      `<figure><img src="rascal-icon-${v.id}.svg" style="width:${s}px;height:${s}px"><figcaption>${s}</figcaption></figure>`).join('')}</div>
    <div class="dark">${[87, 60, 40].map((s) =>
      `<figure><img src="rascal-icon-${v.id}.svg" style="width:${s}px;height:${s}px"><figcaption>${s}</figcaption></figure>`).join('')}</div>
  </div>
</section>`).join('')}
`;

for (const v of VARIANTS) writeFileSync(join(OUT, `rascal-icon-${v.id}.svg`), v.svg);
writeFileSync(join(OUT, 'index.html'), sheet());
console.log(`wrote ${VARIANTS.length} icons + index.html`);
