// VELLUM — the wordmark, the fan mark, the lockups, and the app-icon candidates.
//
//   node docs/app-icon/generate-vellum.mjs
//
// Writes `vellum-*.svg` in this directory and nothing else. It never touches
// `rascal-icon-fan.svg`, the two exploration SVGs beside it, `generate.mjs` or
// `index.html`. The trap next door is documented in `generate.mjs`'s own header;
// this file is deliberately not a second one.
//
// ── why the letters are drawn rather than set ──────────────────────────────
// A logo that says `font-family` renders differently on every machine that opens it,
// and the machine that matters is a stranger's browser. So the wordmark is geometry: a
// monolinear skeleton stroked at a constant weight with round caps and joins. The
// curves are true circular arcs, which is why they are smooth — there is no bezier
// here to get subtly wrong, and no hinting to lose.
//
// It also settles the licensing question by not having one. Nothing is outlined from a
// typeface, so nothing here is anybody's to license. That matters more than it sounds:
// a wordmark cut from a system font is a trademark built on somebody else's EULA.
//
// The construction is geometric-humanist — circular `e`, semicircular arches on `m`, a
// `u` whose right stem runs to the baseline. Round terminals, because the app's own
// type is SF Rounded and the cards in the mark carry a 52/252 corner radius. A
// flat-cut wordmark beside that art reads as a different company's.

import { readFileSync, writeFileSync } from 'node:fs';
import { dirname, join } from 'node:path';
import { fileURLToPath, pathToFileURL } from 'node:url';

const OUT = dirname(fileURLToPath(import.meta.url));
const n = (v) => (Math.round(v * 1000) / 1000).toString();

/* ── palette — docs/design-system.md, not the mockups ─────────────────── */

export const C = {
  terracotta: '#C05A2B',
  terracottaDeep: '#9A431E',
  peach: '#FBEDE2',
  peri: '#5566D6',
  lav: '#E9EBFB',
  sage: '#E8F0E6',
  sageInk: '#4B7A4F',
  ink: '#23253C',
  inkMuted: '#6E6A63',
  canvas: '#FDFAF4',
  surface: '#FFFDF9',
  handle: '#DCD2C4',
  track: '#E6DCCE',
};

export const mix = (a, b, t) => {
  const p = (s) => [1, 3, 5].map((i) => parseInt(s.slice(i, i + 2), 16));
  const [ar, ag, ab] = p(a);
  const [br, bg, bb] = p(b);
  const c = (x, y) => Math.round(x + (y - x) * t).toString(16).padStart(2, '0');
  return `#${c(ar, br)}${c(ag, bg)}${c(ab, bb)}`.toUpperCase();
};

/* ── the letters ──────────────────────────────────────────────────────────
   Design space: baseline at y=0, x-height rising to -xh, ascenders to -asc.
   Every coordinate below is a *skeleton* coordinate. Round caps put another w/2 of ink
   outside the skeleton in every direction, so a skeleton extreme sits w/2 inside the
   intended edge — that inset is why `-xh + h` appears everywhere and not `-xh`.      */

// Chosen by the owner, Aug 17 2026 — build 5 of the eight, the short-ascender cut. The
// l's clear the x-height by 26 rather than 42, which keeps the word compact and level
// instead of letting two stems run away with it. Everything downstream reads these, so
// the lockups and the icon are the chosen build by construction rather than by copying.
const M = (o = {}) => {
  const m = { xh: 100, asc: 126, w: 19.5, track: 1, ...o };
  m.h = m.w / 2;
  m.cap = m.asc - 4;
  return m;
};

const A = (r, large, sweep, x, y) => `A ${n(r)} ${n(r)} 0 ${large} ${sweep} ${n(x)} ${n(y)}`;

// v — two strokes to a rounded vertex. The apex skeleton sits h above the baseline so
// the round join's own outer edge lands exactly on it.
const glyphV = (x0, m, { width = 92 } = {}) => {
  const half = (width - m.w) / 2;
  return {
    d: `M ${n(x0 + m.h)} ${n(-m.xh + m.h)} L ${n(x0 + m.h + half)} ${n(-m.h)} L ${n(x0 + m.h + 2 * half)} ${n(-m.xh + m.h)}`,
    w: width,
  };
};

// V — the same letter with cap-height legs, for the title-case setting.
const glyphCapV = (x0, m, { width = 112 } = {}) => {
  const half = (width - m.w) / 2;
  return {
    d: `M ${n(x0 + m.h)} ${n(-m.cap + m.h)} L ${n(x0 + m.h + half)} ${n(-m.h)} L ${n(x0 + m.h + 2 * half)} ${n(-m.cap + m.h)}`,
    w: width,
  };
};

// e — a circle with a bar across it and the aperture at lower right. One continuous
// stroke: the bar west→east, then the ring the long way back round to the terminal.
// The gap is the whole letter; without it this is a theta.
//
// The bar sits *below* the centre, not on it. On a true circle a centred bar leaves an
// upper counter visibly smaller than the lower one and the bowl reads top-heavy;
// dropping it a few units evens them. It also shortens the bar, because both ends
// still have to land on the circle.
const glyphE = (x0, m, { apertureDeg = 42, drop = 4 } = {}) => {
  const r = (m.xh - m.w) / 2;
  const cx = x0 + m.h + r;
  const cy = -m.xh / 2;
  const at = (deg) => {
    const a = (deg * Math.PI) / 180;
    return [cx + r * Math.cos(a), cy - r * Math.sin(a)];
  };
  const barHalf = Math.sqrt(r * r - drop * drop);
  const [nx, ny] = at(90);
  const [tx, ty] = at(-apertureDeg);
  return {
    d:
      `M ${n(cx - barHalf)} ${n(cy + drop)} L ${n(cx + barHalf)} ${n(cy + drop)} ` +
      A(r, 0, 0, nx, ny) +   // the bar's east end → north; a quarter and a little, never the aperture
      A(r, 1, 0, tx, ty),    // north → the terminal, the long way through west and south
    w: 2 * r + m.w,
  };
};

// l — one stem. The whole letter, and the reason the word has a spine.
const glyphL = (x0, m) => ({
  d: `M ${n(x0 + m.h)} ${n(-m.asc + m.h)} L ${n(x0 + m.h)} ${n(-m.h)}`,
  w: m.w,
});

// u — two stems and a bowl. The right stem runs past the bowl to the baseline, which is
// the humanist half of this: both stems stopping at the arc is an upside-down n.
const glyphU = (x0, m, { width = 95 } = {}) => {
  const r = (width - m.w) / 2;
  const lx = x0 + m.h;
  const rx = x0 + width - m.h;
  const by = -m.h - r;
  return {
    d:
      `M ${n(lx)} ${n(-m.xh + m.h)} L ${n(lx)} ${n(by)} ` +
      A(r, 0, 0, rx, by) +
      ` M ${n(rx)} ${n(-m.xh + m.h)} L ${n(rx)} ${n(-m.h)}`,
    w: width,
  };
};

// m — a stem, then two semicircular arches each landing on a stem of its own. The
// arches carry the x-height; the stems begin where the arches spring, which is the
// geometric construction rather than the grotesque one.
const glyphM = (x0, m, { arch = 32 } = {}) => {
  const s1 = x0 + m.h;
  const s2 = s1 + 2 * arch;
  const s3 = s2 + 2 * arch;
  const ay = -m.xh + m.h + arch;
  return {
    d:
      `M ${n(s1)} ${n(-m.h)} L ${n(s1)} ${n(ay)} ` +
      A(arch, 0, 1, s2, ay) +
      ` M ${n(s2)} ${n(ay)} L ${n(s2)} ${n(-m.h)}` +
      ` M ${n(s2)} ${n(ay)} ` +
      A(arch, 0, 1, s3, ay) +
      ` M ${n(s3)} ${n(ay)} L ${n(s3)} ${n(-m.h)}`,
    w: 4 * arch + m.w,
  };
};

// Fitting, not spacing. Two flat stems facing each other need the same gap wherever it
// happens, so `ll`, `lu` and `um` are one number. A round beside a flat needs less; a
// diagonal beside a round needs least, because the v's lower right is empty space the
// e is already standing in. Every number here was set against a render.
const FLAT = 15;
const KERN = { Ve: 1, ve: 5, el: 8, ll: FLAT, lu: FLAT, um: FLAT };

export function wordmark({
  fill = C.ink,
  caps = false,       // "Vellum" rather than "vellum"
  metrics = {},
} = {}) {
  const m = M(metrics);
  const letters = caps
    ? [['V', glyphCapV], ['e', glyphE], ['l', glyphL], ['l', glyphL], ['u', glyphU], ['m', glyphM]]
    : [['v', glyphV], ['e', glyphE], ['l', glyphL], ['l', glyphL], ['u', glyphU], ['m', glyphM]];

  let x = 0;
  const parts = [];
  letters.forEach(([ch, fn], i) => {
    const g = fn(x, m);
    parts.push(g.d);
    x += g.w;
    if (i < letters.length - 1) x += (KERN[ch + letters[i + 1][0]] ?? 12) * m.track;
  });

  const top = caps ? -m.cap : -m.asc;
  return {
    width: x,
    top,
    height: -top,
    metrics: m,
    body: `<path d="${parts.join(' ')}" fill="none" stroke="${fill}" stroke-width="${n(m.w)}" stroke-linecap="round" stroke-linejoin="round"/>`,
  };
}

/* ── the fan ──────────────────────────────────────────────────────────────
   Five cards, one per entry kind. The shipped RASCAL icon rotates each card about its
   own centre and offsets it sideways, which pivots the hand at the top and splays it
   downward. Everything here rotates about a single pivot instead: `drop` is how far
   below a card's centre that pivot sits, so a positive drop opens the hand upward the
   way a hand of cards actually opens, and a negative one reproduces the shipped
   direction. Small values fan from a tight knot; large ones approach a parallel stack. */

const FAN_ORDER = [-2, 2, -1, 1, 0];   // back to front — z-order is the only depth there is

export function mark({
  hue = C.terracotta,
  ground = C.canvas,
  count = 5,
  step = 16,
  drop = 120,
  scale = 1,
  sheet = null,      // null for solid tonal cards; a number for translucent sheets
  edge = 6,          // the gap between one card and the next
  knockout = false,  // cut the gap out of the card behind instead of painting it in
  id = 'v',          // mask ids have to be unique when two marks share a document
  tones = null,
} = {}) {
  const w = 100 * scale;
  const h = 150 * scale;
  const r = 22 * scale;
  const e = edge * scale;
  const pivot = drop * scale;
  const spread = count === 5 ? [-2, -1, 0, 1, 2] : [-1, 0, 1];
  const order = count === 5 ? [-2, 2, -1, 1, 0] : [-1, 1, 0];   // back to front
  const tone = tones ?? { 2: mix(hue, ground, 0.72), 1: mix(hue, ground, 0.42), 0: hue };

  const xf = (k) => `rotate(${n(k * step)}) translate(0 ${n(-pivot)})`;
  const rect = (extra, grow = 0) =>
    `<rect x="${n(-w / 2 - grow)}" y="${n(-h / 2 - grow)}" width="${n(w + 2 * grow)}" height="${n(h + 2 * grow)}" rx="${n(r + grow)}" ${extra}/>`;

  // Where the ground is unknown there is nothing to draw the gap *in*, so the gap is cut
  // out of the card behind: each card is masked against grown copies of everything in
  // front of it. That is the only separation that survives on both a cream page and an
  // ink one, and it is why the one-colour lockup is a mask rather than an opacity ramp —
  // translucent sheets compound where they overlap and go muddy on a dark ground.
  const defs = [];
  const body = order
    .map((k, i) => {
      const front = order.slice(i + 1);
      let mask = '';
      if (knockout && front.length) {
        const mid = `${id}-k${i}`;
        defs.push(
          `<mask id="${mid}" maskUnits="userSpaceOnUse" x="-400" y="-400" width="800" height="800">` +
            `<rect x="-400" y="-400" width="800" height="800" fill="#fff"/>` +
            front.map((f) => `<g transform="${xf(f)}">${rect('fill="#000"', e)}</g>`).join('') +
            `</mask>`,
        );
        mask = ` mask="url(#${mid})"`;
      }
      const paint =
        sheet == null ? `fill="${tone[Math.abs(k)]}"` : `fill="${hue}" fill-opacity="${n(sheet)}"`;
      const rim = !knockout && edge ? ` stroke="${ground}" stroke-width="${n(e)}"` : '';
      const card = `<g transform="${xf(k)}">${rect(`${paint}${rim}`)}</g>`;
      // The mask goes on a wrapper with no transform of its own. `userSpaceOnUse` resolves
      // against the referencing element's user space, so hanging it on the rotated card
      // would interpret the mask's coordinates inside that card's rotated frame — which
      // renders as one solid silhouette with no gaps, and looks like the mask being
      // ignored rather than being applied in the wrong place.
      return mask ? `<g${mask}>${card}</g>` : card;
    })
    .join('\n    ');

  // The ink box, measured rather than guessed: every corner of every card through its own
  // transform. A viewBox eyeballed off the widest card is a logo with a limp.
  let x0 = Infinity, y0 = Infinity, x1 = -Infinity, y1 = -Infinity;
  const pad = knockout ? 0 : e / 2;
  spread.forEach((k) => {
    const a = (k * step * Math.PI) / 180;
    const cx = -Math.sin(a) * pivot;
    const cy = -Math.cos(a) * pivot;
    [[-w / 2 - pad, -h / 2 - pad], [w / 2 + pad, -h / 2 - pad],
     [-w / 2 - pad, h / 2 + pad], [w / 2 + pad, h / 2 + pad]].forEach(([lx, ly]) => {
      const rx = lx * Math.cos(a) - ly * Math.sin(a) + cx;
      const ry = lx * Math.sin(a) + ly * Math.cos(a) + cy;
      x0 = Math.min(x0, rx); x1 = Math.max(x1, rx);
      y0 = Math.min(y0, ry); y1 = Math.max(y1, ry);
    });
  });

  return {
    body: defs.length ? `<defs>${defs.join('')}</defs>\n    ${body}` : body,
    box: { x: x0, y: y0, w: x1 - x0, h: y1 - y0 },
  };
}

/* ── the icon ─────────────────────────────────────────────────────────────
   The five cards and their motifs are lifted out of `rascal-icon-fan.svg` rather than
   redrawn. That file is the mark the owner decided on Aug 16, 2026, and the point of
   these candidates is *the decided mark plus one change* — a redraw would quietly put a
   dozen changes on the table and call them one.

   What is read out: each card's fill, and the motif drawn inside its clip. What is
   re-authored: where the cards sit. Nothing else moves.                              */

export function shippedFan() {
  const src = readFileSync(join(OUT, 'rascal-icon-fan.svg'), 'utf8');
  const groups = [
    ...src.matchAll(
      /<g transform="translate\(([-\d.]+) ([-\d.]+)\) rotate\(([-\d.]+)\)" filter="url\(#lift\)">\s*<rect[^>]*?fill="([^"]+)"\/>\s*<g clip-path="url\(#clipCard\)">([\s\S]*?)<\/g><\/g>/g,
    ),
  ].map((m) => ({ x: +m[1], y: +m[2], rot: +m[3], fill: m[4], motif: m[5].trim() }));
  if (groups.length !== 5) {
    throw new Error(`expected 5 cards in rascal-icon-fan.svg, parsed ${groups.length} — the file changed shape`);
  }
  // The file lists them in *drawing* order — back to front — with the front card last at
  // rotation 0. Sorting by tilt puts them left to right, which is the order every layout
  // below indexes by. Reading the file's order as positional is the bug this sort exists
  // to prevent, and when it happened it looked like a z-order problem.
  return groups.sort((a, b) => a.rot - b.rot);
}

const CARD = { w: 252, h: 424, r: 52 };

// The defs the lifted motifs depend on. `shotF` is the front card's photograph and
// `clipCard` is what keeps every motif inside its own card; both are quoted from the
// shipped file, because a motif drawn without its clip bleeds across the whole icon.
const ICON_DEFS = `
    <linearGradient id="ground" x1="0" y1="0" x2="1" y2="1">
      <stop offset="0" stop-color="#C96335"/><stop offset="1" stop-color="#A4441C"/>
    </linearGradient>
    <filter id="lift" x="-30%" y="-30%" width="160%" height="160%">
      <feDropShadow dx="0" dy="9" stdDeviation="13" flood-color="#5E2107" flood-opacity="0.30"/>
    </filter>
    <linearGradient id="shotF" x1="0.1" y1="0" x2="0.8" y2="1">
      <stop offset="0" stop-color="#F7DAB2"/><stop offset="1" stop-color="#C8783F"/>
    </linearGradient>
    <clipPath id="clipCard"><rect x="-126" y="-212" width="252" height="424" rx="52" fill="#000"/></clipPath>`;

const iconShell = (inner, label) =>
  `<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 1024 1024" width="1024" height="1024" role="img" aria-label="${label}">
  <defs>${ICON_DEFS}
  </defs>
  <rect width="1024" height="1024" fill="url(#ground)"/>
${inner}
</svg>
`;

const cardGroup = (transform, fill, motif) =>
  `<g transform="${transform}" filter="url(#lift)"><rect x="-126" y="-212" width="252" height="424" rx="52" fill="${fill}"/><g clip-path="url(#clipCard)">
    ${motif}</g></g>`;

/* CHOSEN, Aug 17 2026 — the shipped fan, and the front card says the name.
   Geometry untouched to the decimal. The front card's entry title — a 138x15 bar standing
   in for a line of type — becomes the actual line of type it was standing in for. This is
   the literal reading of "put the name in the icon", and it is the one that loses the word
   first as the icon shrinks: by 87pt the title is a smudge, which is exactly what the bar
   it replaced always was. */
export function iconWordmark(cards) {
  const wm = wordmark({ fill: C.ink, metrics: { w: 21 } });
  const target = 34;                       // ascender-to-baseline on the card, in icon units
  const s = target / wm.height;
  const inner = [0, 4, 1, 3, 2]
    .map((i) => {
      const c = cards[i];
      let motif = c.motif;
      if (i === 2) {
        const bar = '<rect x="-100" y="70" width="138" height="15" rx="7.5" fill="#23253C" opacity="0.86"/>';
        if (!motif.includes(bar)) throw new Error('the front card title bar moved — the icon needs re-aiming');
        motif = motif.replace(
          bar,
          `<g transform="translate(-100 ${n(70 + target * 0.86)}) scale(${n(s)})">${wm.body}</g>`,
        );
      }
      return cardGroup(`translate(${c.x} ${c.y}) rotate(${c.rot})`, c.fill, motif);
    })
    .join('\n');
  return iconShell(inner, 'Vellum app icon');
}

/* Not chosen — the hand opens upward, and the silhouette is a V.
   Same five cards, same tilts, same order. The only change is where they turn: about a
   single pivot below the hand rather than about each card's own centre, which is how a
   hand of cards opens when a person holds one. Nothing is added and no letter appears. */
export function iconVFan(cards, { step = 14, drop = 300, fit = 812 } = {}) {
  const angles = [-2, -1, 0, 1, 2].map((k) => k * step);

  // Measure, then fit, then centre — in that order. The fan's own ink box decides the
  // scale and the pivot; picking 512 by eye is how art ends up sitting low in the mask
  // with a card corner outside it.
  let x0 = Infinity, y0 = Infinity, x1 = -Infinity, y1 = -Infinity;
  angles.forEach((deg) => {
    const a = (deg * Math.PI) / 180;
    const cx = -Math.sin(a) * drop;
    const cy = -Math.cos(a) * drop;
    [[-CARD.w / 2, -CARD.h / 2], [CARD.w / 2, -CARD.h / 2], [-CARD.w / 2, CARD.h / 2], [CARD.w / 2, CARD.h / 2]]
      .forEach(([lx, ly]) => {
        const rx = lx * Math.cos(a) - ly * Math.sin(a) + cx;
        const ry = lx * Math.sin(a) + ly * Math.cos(a) + cy;
        x0 = Math.min(x0, rx); x1 = Math.max(x1, rx);
        y0 = Math.min(y0, ry); y1 = Math.max(y1, ry);
      });
  });
  const k = Math.min(fit / (x1 - x0), fit / (y1 - y0));
  const px = 512 - ((x0 + x1) / 2) * k;
  const py = 512 - ((y0 + y1) / 2) * k;

  const inner = [0, 4, 1, 3, 2]
    .map((i) => cardGroup(
      `translate(${n(px)} ${n(py)}) scale(${n(k)}) rotate(${n(angles[i])}) translate(0 ${n(-drop)})`,
      cards[i].fill, cards[i].motif,
    ))
    .join('\n');
  return iconShell(inner, 'Vellum app icon — the fan opens into a V');
}

/* Not chosen — the front card is the letter.
   The photograph, the sheet and the lines come off the front card and a v takes its whole
   face. The only candidate still legible at 60pt, and the only one where the front card
   stops being an entry and becomes a badge. */
export function iconMonogram(cards) {
  // A v is only a v if it is taller than it is wide. The first pass drew one at x-height
  // against a 168 width and it read as a check mark — a glyph this product already uses,
  // on the did-it card, three cards to the left.
  const m = M({ w: 38, xh: 232 });
  const g = glyphV(0, m, { width: 150 });
  const letter =
    `<path d="${g.d}" fill="none" stroke="${C.terracotta}" stroke-width="${n(m.w)}" stroke-linecap="round" stroke-linejoin="round"/>`;
  const inner = [0, 4, 1, 3, 2]
    .map((i) => {
      const c = cards[i];
      const motif =
        i === 2
          ? `<rect x="-126" y="-212" width="252" height="424" rx="52" fill="${C.peach}"/>
    <g transform="translate(${n(-g.w / 2)} 116)">${letter}</g>`
          : c.motif;
      return cardGroup(`translate(${c.x} ${c.y}) rotate(${c.rot})`, i === 2 ? 'none' : c.fill, motif);
    })
    .join('\n');
  return iconShell(inner, 'Vellum app icon — the front card is the letter');
}

/* ── lockups ──────────────────────────────────────────────────────────────
   One mark, one word, and the three arrangements everything else is cropped from. The
   numbers that matter are the two relationships: how tall the mark stands against the
   word, and how far it stands off. Both are expressed in x-heights so they survive
   being scaled to a favicon or a billboard.                                          */

// Knockout rather than a stroke in the ground colour. A cream stroke is invisible on the
// cream canvas and correct there, but the marketing site is white, and on white it reads as
// a warm halo around every card — the mark looks soft-edged rather than crisp, which is the
// one thing a logo cannot afford. Cutting the gap out of the card behind makes it true
// transparency, so the same file is right on white, on cream, and on anything else.
//
// The cost is that the gaps are frozen: the mask is built from where the cards *are*. That
// is fine for a static file and wrong for an animated one, which is why the hover component
// below goes back to a stroke — see the note there.
const MARK_OPTS = { step: 16, drop: 120, sheet: null, edge: 6, knockout: true };

const svgDoc = ({ w, h, vb, body, title, extra = '' }) =>
  `<svg xmlns="http://www.w3.org/2000/svg" viewBox="${vb}" width="${n(w)}" height="${n(h)}" role="img" aria-label="${title}"${extra}>
  ${body}
</svg>
`;

export function lockupHorizontal({ ink = C.ink, hue = C.terracotta, ground = C.canvas } = {}) {
  const wm = wordmark({ fill: ink });
  const mk = mark({ ...MARK_OPTS, hue, ground, id: 'lh' });
  const m = wm.metrics;

  const markH = m.asc * 1.30;                 // the mark stands a little over the ascenders
  const k = markH / mk.box.h;
  const gap = m.xh * 0.62;

  const mw = mk.box.w * k;
  const width = mw + gap + wm.width;
  const top = -markH / 2 - m.asc / 2;         // both centred on one optical axis
  const body =
    `<g transform="translate(${n(-mk.box.x * k)} ${n(-mk.box.y * k - markH)}) scale(${n(k)})">${mk.body}</g>\n  ` +
    `<g transform="translate(${n(mw + gap)} 0)">${wm.body}</g>`;

  // The box: the mark hangs below the baseline, the ascenders rise above it.
  const y0 = Math.min(-markH, top);
  const h = Math.max(0, -y0);
  void h;
  return {
    body,
    box: { x: 0, y: -markH, w: width, h: markH },
    doc: svgDoc({
      w: width, h: markH, vb: `0 ${n(-markH)} ${n(width)} ${n(markH)}`,
      body, title: 'Vellum',
    }),
  };
}

export function lockupStacked({ ink = C.ink, hue = C.terracotta, ground = C.canvas } = {}) {
  const wm = wordmark({ fill: ink });
  const mk = mark({ ...MARK_OPTS, hue, ground, id: 'ls' });
  const m = wm.metrics;

  const markH = m.asc * 1.62;
  const k = markH / mk.box.h;
  const mw = mk.box.w * k;
  const gap = m.xh * 0.52;

  const width = Math.max(mw, wm.width);
  const height = markH + gap + m.asc;
  const body =
    `<g transform="translate(${n((width - mw) / 2 - mk.box.x * k)} ${n(-mk.box.y * k)}) scale(${n(k)})">${mk.body}</g>\n  ` +
    `<g transform="translate(${n((width - wm.width) / 2)} ${n(height)})">${wm.body}</g>`;
  return {
    body,
    box: { x: 0, y: 0, w: width, h: height },
    doc: svgDoc({ w: width, h: height, vb: `0 0 ${n(width)} ${n(height)}`, body, title: 'Vellum' }),
  };
}

/* ── the website component ────────────────────────────────────────────────
   A logo that opens when you point at it, built for a white ground.

   Two things here are deliberate and easy to get wrong.

   **It strokes rather than knocks out.** Every static file in this directory cuts the gap
   between cards out of the card behind, so it needs to know nothing about the ground. That
   cannot animate: the mask is built from where the cards *are*, so the moment a card
   rotates away its notch stays behind and the mark tears. A stroke moves with the card it
   belongs to. It costs the file its ground-independence — which is exactly the trade worth
   making here, because a site header has one known background and this one is white.

   **The rest position is in the markup, the motion is in CSS.** Each card carries a real
   `transform` attribute, so with the stylesheet stripped the fan is still a fan rather than
   five cards piled on one point.                                                          */

export function hoverComponent({ ground = '#FFFFFF' } = {}) {
  const wm = wordmark({ fill: C.ink });
  const m = wm.metrics;
  const step = 16, drop = 120, w = 100, h = 150, r = 22, edge = 6;
  const spread = [-2, -1, 0, 1, 2];
  const order = [-2, 2, -1, 1, 0];
  const tone = { 2: mix(C.terracotta, C.canvas, 0.72), 1: mix(C.terracotta, C.canvas, 0.42), 0: C.terracotta };

  const probe = mark({ step, drop, sheet: null, edge, knockout: false });
  const markH = m.asc * 1.3;
  const k = markH / probe.box.h;
  const mw = probe.box.w * k;
  const gap = m.xh * 0.62;
  const width = mw + gap + wm.width;

  const cards = order
    .map((kk) => {
      const deg = kk * step;
      return (
        `        <g class="vl-card" style="--a:${n(deg)};--i:${Math.abs(kk)}" ` +
        `transform="rotate(${n(deg)}) translate(0 ${n(-drop)})">\n` +
        `          <rect x="${n(-w / 2)}" y="${n(-h / 2)}" width="${w}" height="${h}" rx="${r}" ` +
        `fill="${tone[Math.abs(kk)]}" stroke="${ground}" stroke-width="${edge}"/>\n` +
        `        </g>`
      );
    })
    .join('\n');

  const snippet = `<a class="vellum-logo" href="/" aria-label="Vellum">
  <svg viewBox="0 ${n(-markH)} ${n(width)} ${n(markH)}" aria-hidden="true" focusable="false">
    <g transform="translate(${n(-probe.box.x * k)} ${n(-probe.box.y * k - markH)}) scale(${n(k)})">
${cards}
    </g>
    <g transform="translate(${n(mw + gap)} 0)">
      ${wm.body}
    </g>
  </svg>
</a>`;

  const css = `.vellum-logo {
  display: inline-block;
  line-height: 0;                 /* an inline-block wrapping an svg gets a descender gap */
  border-radius: 6px;
}
.vellum-logo svg {
  display: block;
  height: 44px;                   /* the only size you set — width follows the viewBox */
  width: auto;
  overflow: visible;              /* the fan opens past its box; see the note below */
}
.vellum-logo .vl-card {
  transform: rotate(calc(var(--a) * 1deg)) translateY(-120px);
  transition: transform 260ms cubic-bezier(.4, 0, .2, 1);
}
/* Opening staggers from the middle outward; closing does not, so the hand snaps shut
   rather than unravelling. The delay lives in the hover rule for exactly that reason. */
.vellum-logo:hover .vl-card,
.vellum-logo:focus-visible .vl-card {
  transform: rotate(calc(var(--a) * 1.45deg)) translateY(-127px);
  transition: transform 460ms cubic-bezier(.22, .9, .28, 1);
  transition-delay: calc(var(--i) * 45ms);
}
.vellum-logo:focus-visible {
  outline: 2px solid ${C.terracotta};
  outline-offset: 6px;
}
@media (prefers-reduced-motion: reduce) {
  .vellum-logo .vl-card,
  .vellum-logo:hover .vl-card,
  .vellum-logo:focus-visible .vl-card {
    transform: rotate(calc(var(--a) * 1deg)) translateY(-120px);
    transition: none;
  }
}`;

  const esc = (t) => t.replace(/&/g, '&amp;').replace(/</g, '&lt;').replace(/>/g, '&gt;');

  return `<!doctype html>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>Vellum — the logo, on white, with its hover state</title>
<style>
  body {
    margin: 0; background: ${ground}; color: ${C.ink};
    font: 400 16px/1.6 "Source Sans 3", system-ui, -apple-system, sans-serif;
  }
  .bar {
    display: flex; align-items: center; justify-content: space-between;
    padding: 22px clamp(20px, 5vw, 56px); border-bottom: 1px solid #ECE7E0;
  }
  .bar nav { display: flex; gap: 30px; color: ${C.inkMuted}; font-size: 15px; }
  .stage { padding: clamp(40px, 7vw, 90px) clamp(20px, 5vw, 56px); max-width: 860px; }
  h1 { font: 600 27px/1.25 "Source Sans 3", system-ui, sans-serif; margin: 0 0 10px; letter-spacing: -.01em; }
  p { color: ${C.inkMuted}; max-width: 62ch; margin: 0 0 18px; }
  .sizes { display: flex; gap: 54px; align-items: flex-end; flex-wrap: wrap; margin: 34px 0 0; }
  .sizes .vellum-logo svg { height: 64px; }
  .sizes .s2 .vellum-logo svg { height: 34px; }
  .sizes .s3 .vellum-logo svg { height: 24px; }
  .cap { font: 11px/1.4 ui-monospace, Menlo, monospace; color: #A8A096; margin-top: 12px;
         letter-spacing: .07em; text-transform: uppercase; }
  h2 { font: 600 15px/1.3 "Source Sans 3", sans-serif; margin: 54px 0 10px;
       letter-spacing: .09em; text-transform: uppercase; color: ${C.terracotta}; font-size: 12px; }
  pre {
    background: #FAF7F2; border: 1px solid #ECE7E0; border-radius: 12px;
    padding: 20px 22px; overflow-x: auto; font: 12.5px/1.65 ui-monospace, Menlo, monospace;
    color: #3A3C52;
  }
  .note { border-left: 3px solid ${C.terracotta}; padding-left: 16px; margin: 26px 0; }

${css.split('\n').map((l) => (l ? '  ' + l : l)).join('\n')}
</style>

<div class="bar">
  ${snippet.split('\n').join('\n  ')}
  <nav><span>How it works</span><span>Pricing</span><span>Sign in</span></nav>
</div>

<div class="stage">
  <h1>Point at it.</h1>
  <p>The hand opens — outer cards last, on a 45ms stagger, so it reads as a fan rather than
  as a scale. Closing has no stagger, so it snaps shut instead of unravelling. Keyboard users
  get the same thing on <code>:focus-visible</code>, and anyone who has asked their system for
  less motion gets none.</p>

  <div class="sizes">
    <div><div>${snippet.split('\n').join('\n    ')}</div><div class="cap">64 — hero</div></div>
    <div class="s2"><div>${snippet.split('\n').join('\n    ')}</div><div class="cap">34 — header</div></div>
    <div class="s3"><div>${snippet.split('\n').join('\n    ')}</div><div class="cap">24 — footer</div></div>
  </div>

  <div class="note">
    <p><strong>One caveat worth knowing.</strong> The fan opens past the edge of its own box,
    so the svg is set <code>overflow: visible</code> and the layout does not shift when it
    moves. A parent with <code>overflow: hidden</code> will clip the open state — if the header
    has one, give this element room rather than turning the overflow off.</p>
  </div>

  <h2>The markup</h2>
  <pre>${esc(snippet)}</pre>

  <h2>The CSS</h2>
  <pre>${esc(css)}</pre>

  <div class="note">
    <p><strong>Why this one strokes its card gaps in white</strong> when every other file in
    this directory cuts them out. A knockout needs to know nothing about the background, which
    is what makes the static files safe anywhere — but the mask is built from where the cards
    are, so the moment one rotates away its notch stays behind and the mark tears. A stroke
    moves with its card. That trades ground-independence for motion, which is the right trade
    here and the wrong one everywhere else.</p>
  </div>
</div>
`;
}

/* ── what gets written ───────────────────────────────────────────────────
   `index.html` is deliberately NOT written from here. The script next door regenerates
   the contact sheet from its own variant list, and doing that is what deleted the only
   page that mentioned the shipped icon — see `generate.mjs`'s header. The sheet is
   hand-kept; this file only produces artwork.                                        */

const write = (name, body) => {
  writeFileSync(join(OUT, name), body);
  console.log('  ', name);
};

const files = {
  'vellum-wordmark.svg': () => {
    const wm = wordmark();
    return svgDoc({
      w: wm.width, h: wm.height, vb: `0 ${n(wm.top)} ${n(wm.width)} ${n(wm.height)}`,
      body: wm.body, title: 'Vellum',
    });
  },

  'vellum-mark.svg': () => {
    const mk = mark({ ...MARK_OPTS, id: 'mk' });
    return svgDoc({
      w: mk.box.w, h: mk.box.h,
      vb: `${n(mk.box.x)} ${n(mk.box.y)} ${n(mk.box.w)} ${n(mk.box.h)}`,
      body: mk.body, title: 'Vellum',
    });
  },

  // Three cards rather than five. Below about 24px the five-card fan stops being five
  // of anything, and a favicon that is honestly three cards beats one that is a smudge
  // claiming to be five.
  'vellum-mark-compact.svg': () => {
    const mk = mark({ ...MARK_OPTS, count: 3, step: 21, drop: 108, edge: 7, id: 'mc' });
    return svgDoc({
      w: mk.box.w, h: mk.box.h,
      vb: `${n(mk.box.x)} ${n(mk.box.y)} ${n(mk.box.w)} ${n(mk.box.h)}`,
      body: mk.body, title: 'Vellum',
    });
  },

  'vellum-logo-horizontal.svg': () => lockupHorizontal().doc,
  'vellum-logo-stacked.svg': () => lockupStacked().doc,

  // One colour, and the colour is the caller's. `currentColor` everywhere plus a `color`
  // presentation attribute on the root means an <img> renders it ink, while inline use
  // takes whatever CSS `color` the page sets — so the same file reverses out on a dark
  // ground without a second file existing to drift from this one.
  //
  // Depth cannot come from tone here, because there is only one tone, and it cannot come
  // from translucency either — overlapping sheets compound and go muddy the moment the
  // ground is dark. It comes from a knockout: the gap is cut out of the card behind.
  'vellum-logo-mono.svg': () => {
    const wm = wordmark({ fill: 'currentColor' });
    const mk = mark({ ...MARK_OPTS, hue: 'currentColor', knockout: true, id: 'mono', tones: { 0: 'currentColor', 1: 'currentColor', 2: 'currentColor' } });
    const m = wm.metrics;
    const markH = m.asc * 1.3;
    const k = markH / mk.box.h;
    const mw = mk.box.w * k;
    const gap = m.xh * 0.62;
    const width = mw + gap + wm.width;
    const body =
      `<g transform="translate(${n(-mk.box.x * k)} ${n(-mk.box.y * k - markH)}) scale(${n(k)})">${mk.body}</g>\n  ` +
      `<g transform="translate(${n(mw + gap)} 0)">${wm.body}</g>`;
    return svgDoc({
      w: width, h: markH, vb: `0 ${n(-markH)} ${n(width)} ${n(markH)}`,
      body, title: 'Vellum', extra: ` color="${C.ink}"`,
    });
  },

  // Eight builds of one word on one sheet, so the choice is made by comparison rather
  // than by memory. This file is scaffolding: once a build is chosen it should be
  // deleted, and `vellum-wordmark.svg` regenerated with the winning metrics.
  'vellum-wordmark-options.svg': () => {
    const opts = [
      ['1  weight 19.5, ascender 142', { metrics: { asc: 142 } }],
      ['2  lighter — weight 15.5', { metrics: { asc: 142, w: 15.5 } }],
      ['3  heavier — weight 24', { metrics: { asc: 142, w: 24 } }],
      ['4  tall ascenders — 168', { metrics: { asc: 168 } }],
      ['5  short ascenders — 126   ← chosen', {}],
      ['6  tight fitting — tracking x0.45', { metrics: { asc: 142, track: 0.45 } }],
      ['7  airy fitting — tracking x1.7', { metrics: { asc: 142, track: 1.7 } }],
      ['8  title case', { metrics: { asc: 142 }, caps: true }],
    ];
    const ROW = 128, W = 1120, PAD = 54, BIG = 62 / 142, SMALL = 19 / 142;
    const rows = opts.map(([label, o], i) => {
      const wm = wordmark({ ...o, fill: C.ink });
      const y = i * ROW + 44;
      const won = label.includes('chosen');
      return (
        (won ? `<rect x="${PAD - 22}" y="${n(y - 10)}" width="6" height="${n(ROW - 24)}" rx="3" fill="${C.terracotta}"/>` : '') +
        `<text x="${PAD}" y="${n(y + 4)}" font-family="ui-monospace, monospace" font-size="12.5" fill="${won ? C.terracotta : '#A8A096'}">${label}</text>` +
        `<g transform="translate(${PAD} ${n(y + 84)}) scale(${n(BIG)})">${wm.body}</g>` +
        `<g transform="translate(${n(W - PAD - wm.width * SMALL)} ${n(y + 84)}) scale(${n(SMALL)})">${wm.body}</g>` +
        (i < opts.length - 1
          ? `<line x1="${PAD}" y1="${n(y + ROW - 20)}" x2="${W - PAD}" y2="${n(y + ROW - 20)}" stroke="${C.border}"/>`
          : '')
      );
    });
    const H = ROW * opts.length + 36;
    return svgDoc({
      w: W, h: H, vb: `0 0 ${W} ${n(H)}`, title: 'Eight builds of the vellum wordmark',
      body: `<rect width="${W}" height="${n(H)}" fill="${C.canvas}"/>\n  ` + rows.join('\n  '),
    });
  },

  // The owner chose candidate 2 on Aug 17 2026. It takes the unqualified name; the two
  // that lost keep descriptive ones and stay in the tree, because a candidate nobody can
  // look at again is a decision nobody can revisit.
  'vellum-logo-hover.html': () => hoverComponent(),

  'vellum-icon-fan.svg': () => iconWordmark(shippedFan()),
  'vellum-icon-alt-v.svg': () => iconVFan(shippedFan()),
  'vellum-icon-alt-monogram.svg': () => iconMonogram(shippedFan()),
};

// Only when run, never when imported. A module that writes nine files as a side effect
// of `import` is a module you cannot borrow a function from, and the contact sheet's
// build does exactly that.
if (import.meta.url === pathToFileURL(process.argv[1] ?? '').href) {
  console.log('vellum artwork →');
  for (const [name, make] of Object.entries(files)) write(name, make());
  console.log('\nindex.html is hand-kept and was not written.');
}
