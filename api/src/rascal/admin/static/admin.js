/* The Vellum admin console.
 *
 * Vanilla ES modules, no build step, no dependency. That is a deliberate constraint rather
 * than an aesthetic one: `CLAUDE.md` settles the stack and this lane has no npm, no bundler
 * and no CI step that would run one. A console that needs `npm install` before anybody can
 * read a number is a console that rots the first time nobody runs it.
 *
 * The charts are hand-rolled SVG for the same reason, and it costs less than it sounds — a
 * column chart is a loop over rects. What it buys is a page with no third-party script on it
 * at all, which is what lets the CSP in index.html be `default-src 'self'` with no exceptions.
 */

// --- Bearer token ---------------------------------------------------------------------------
//
// `localStorage`, not a cookie. A cookie would be sent automatically on every same-origin
// request, which would make this the first surface in the service with ambient authority and
// would need CSRF protection the JSON API does not otherwise want. An explicit
// `Authorization` header keeps the console exactly as privileged as the iOS app: it holds a
// token and attaches it on purpose.

import * as cards from "/admin/static/cards.js";

const TOKEN_KEY = "vellum.admin.token";
const REFRESH_KEY = "vellum.admin.refresh";
let token = localStorage.getItem(TOKEN_KEY) || "";
let refreshToken = localStorage.getItem(REFRESH_KEY) || "";

const $ = (id) => document.getElementById(id);
const body = document.body;

const state = {
  days: 60,
  snapshot: null,
  library: null,
  filters: {},
  editing: null,
  studio: null,
  chat: [],
  concepts: [],
  composing: null,
  // Which provider's series the costs chart is showing. More than one vendor has a series
  // since phase 100, and they are not all denominated in money.
  chart: null,
};

// --- API ------------------------------------------------------------------------------------

class ApiError extends Error {
  constructor(status, payload) {
    const detail = payload?.error?.message || `HTTP ${status}`;
    super(detail);
    this.status = status;
    this.code = payload?.error?.code || null;
    this.field = payload?.error?.field || null;
  }
}

const send = (path, options) =>
  fetch(`/v1${path}`, {
    ...options,
    headers: {
      "content-type": "application/json",
      ...(token ? { authorization: `Bearer ${token}` } : {}),
      ...(options.headers || {}),
    },
  });

/**
 * Rotate the pair. Returns true if there is a usable access token afterwards.
 *
 * **Without this the console is unusable in production.** Access tokens last fifteen minutes,
 * and re-authenticating there is not a button — `dev-login` does not exist, so it is a magic
 * link, an email, and a token exchange. Being thrown out of a dashboard every quarter of an
 * hour and made to do that is the difference between a tool and a demo.
 *
 * `/auth/refresh` revokes the presented token and issues a new pair, so the new refresh token
 * must be stored even when only the access token gets used. Dropping it would work once and
 * fail on the next rotation, which is the worst shape of bug: fine in testing, broken tomorrow.
 */
let refreshing = null;
async function refreshSession() {
  if (!refreshToken) return false;
  // One rotation at a time. The dashboard fires several requests per tab switch, and each
  // getting a 401 would otherwise start its own refresh — the first would succeed and the rest
  // would present a token the first had already revoked, which reads as a reuse attack.
  refreshing ??= (async () => {
    try {
      const response = await fetch("/v1/auth/refresh", {
        method: "POST",
        headers: { "content-type": "application/json" },
        body: JSON.stringify({ refresh_token: refreshToken }),
      });
      if (!response.ok) return false;
      const pair = await response.json();
      keepSession(pair);
      return true;
    } catch {
      return false;
    } finally {
      refreshing = null;
    }
  })();
  return refreshing;
}

async function api(path, options = {}) {
  let response = await send(path, options);
  if (response.status === 401 && refreshToken && !path.startsWith("/auth/")) {
    if (await refreshSession()) response = await send(path, options);
  }
  let payload = null;
  if (response.status !== 204) {
    payload = await response.json().catch(() => null);
  }
  if (!response.ok) throw new ApiError(response.status, payload);
  return payload;
}

// --- Formatting -------------------------------------------------------------------------------

const nf = new Intl.NumberFormat("en-US");
const num = (value) => nf.format(value ?? 0);

/** Compact for a hero or tile; exact everywhere a number is compared to another number. */
function compact(value) {
  if (value == null) return "—";
  if (Math.abs(value) < 10000) return nf.format(value);
  return new Intl.NumberFormat("en-US", { notation: "compact", maximumFractionDigits: 1 }).format(
    value,
  );
}

function money(cents) {
  if (cents == null) return "—";
  return new Intl.NumberFormat("en-US", { style: "currency", currency: "USD" }).format(cents / 100);
}

function bytes(count) {
  if (!count) return "0 B";
  const units = ["B", "KB", "MB", "GB", "TB"];
  let size = count;
  let unit = 0;
  while (size >= 1024 && unit < units.length - 1) {
    size /= 1024;
    unit += 1;
  }
  return `${unit === 0 ? size : size.toFixed(1)} ${units[unit]}`;
}

const dayLabel = (iso) =>
  new Date(`${iso}T12:00:00Z`).toLocaleDateString("en-US", {
    month: "short",
    day: "numeric",
    timeZone: "UTC",
  });

function when(iso) {
  if (!iso) return "never";
  const then = new Date(iso);
  const minutes = Math.round((Date.now() - then.getTime()) / 60000);
  if (minutes < 1) return "just now";
  if (minutes < 60) return `${minutes}m ago`;
  if (minutes < 60 * 36) return `${Math.round(minutes / 60)}h ago`;
  return `${Math.round(minutes / 1440)}d ago`;
}

const escape = (value) =>
  String(value ?? "").replace(
    /[&<>"']/g,
    (ch) => ({ "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;", "'": "&#39;" })[ch],
  );

/** Prompt bodies ship with `{their}` intact. Mark the tokens rather than hiding them. */
const markTokens = (text) =>
  escape(text).replace(/\{([a-zA-Z_]+)\}/g, '<span class="token">{$1}</span>');

function toast(message) {
  const el = $("toast");
  el.textContent = message;
  el.hidden = false;
  clearTimeout(toast.timer);
  toast.timer = setTimeout(() => {
    el.hidden = true;
  }, 4200);
}

function banner(message) {
  const el = $("banner");
  el.hidden = !message;
  el.textContent = message || "";
}

// --- Charts -----------------------------------------------------------------------------------
//
// Six specs, applied everywhere: bars cap at 24px and carry a 4px rounded data-end square at
// the baseline; a 2px surface gap separates touching marks; lines are 2px; gridlines are a
// recessive hairline; text never wears the series colour; and no chart here has a second
// y-axis, because two measures on two scales are two charts.

const SVG = "http://www.w3.org/2000/svg";
const svgEl = (name, attrs = {}) => {
  const node = document.createElementNS(SVG, name);
  for (const [key, value] of Object.entries(attrs)) node.setAttribute(key, String(value));
  return node;
};

const tip = $("tooltip");
function showTip(event, html) {
  tip.innerHTML = html;
  tip.hidden = false;
  const box = tip.getBoundingClientRect();
  const left = Math.min(Math.max(event.clientX - box.width / 2, 8), window.innerWidth - box.width - 8);
  tip.style.left = `${left}px`;
  tip.style.top = `${Math.max(event.clientY - box.height - 12, 8)}px`;
}
const hideTip = () => {
  tip.hidden = true;
};

/** A top-rounded bar: square where it meets the baseline, 4px radius at the data end. */
function barPath(x, y, width, height, radius = 4) {
  const r = Math.max(0, Math.min(radius, width / 2, height));
  const bottom = y + height;
  return `M${x},${bottom} L${x},${y + r} Q${x},${y} ${x + r},${y} L${x + width - r},${y} Q${
    x + width
  },${y} ${x + width},${y + r} L${x + width},${bottom} Z`;
}

/**
 * Daily columns with a hover tooltip. One series, so no legend — the title names it.
 *
 * Every day in the range gets a slot even when it is zero, because the server gap-fills and a
 * chart that closes its own gaps draws a straight line through an outage.
 */
function columnChart(mount, points, { color = "var(--series-1)", format = num } = {}) {
  mount.replaceChildren();
  if (!points.length) {
    mount.innerHTML = '<p class="chart-empty">Nothing yet.</p>';
    return;
  }
  const W = 900;
  const H = 200;
  const pad = { top: 14, right: 8, bottom: 22, left: 40 };
  const plotW = W - pad.left - pad.right;
  const plotH = H - pad.top - pad.bottom;
  const peak = Math.max(1, ...points.map((p) => p.value));
  const slot = plotW / points.length;
  const width = Math.min(24, Math.max(2, slot - 2)); // the 2px surface gap

  const svg = svgEl("svg", { viewBox: `0 0 ${W} ${H}`, role: "img" });
  svg.setAttribute("aria-label", `${points.length} days, peak ${format(peak)}`);

  for (const frac of [0, 0.5, 1]) {
    const y = pad.top + plotH * (1 - frac);
    svg.append(
      svgEl("line", {
        x1: pad.left,
        x2: W - pad.right,
        y1: y,
        y2: y,
        stroke: "var(--border)",
        "stroke-width": 1,
      }),
    );
    const text = svgEl("text", {
      x: pad.left - 8,
      y: y + 4,
      "text-anchor": "end",
      fill: "var(--ink-faint)",
      "font-size": 11,
    });
    text.textContent = format(Math.round(peak * frac));
    svg.append(text);
  }

  points.forEach((point, index) => {
    const height = (point.value / peak) * plotH;
    const x = pad.left + index * slot + (slot - width) / 2;
    const y = pad.top + plotH - height;
    if (point.value > 0) {
      svg.append(
        svgEl("path", { d: barPath(x, y, width, height), fill: color, class: "heat-cell" }),
      );
    }
    // The hit target is the whole slot, not the bar: a one-pixel column on a quiet day is
    // impossible to hover, and an unhoverable data point may as well not be plotted.
    const hit = svgEl("rect", {
      x: pad.left + index * slot,
      y: pad.top,
      width: slot,
      height: plotH,
      fill: "transparent",
    });
    hit.addEventListener("mousemove", (event) =>
      showTip(event, `${dayLabel(point.day)}<br /><b>${format(point.value)}</b> ${point.unit || ""}`),
    );
    hit.addEventListener("mouseleave", hideTip);
    svg.append(hit);
  });

  const first = svgEl("text", {
    x: pad.left,
    y: H - 4,
    fill: "var(--ink-faint)",
    "font-size": 11,
  });
  first.textContent = dayLabel(points[0].day);
  const last = svgEl("text", {
    x: W - pad.right,
    y: H - 4,
    "text-anchor": "end",
    fill: "var(--ink-faint)",
    "font-size": 11,
  });
  last.textContent = dayLabel(points[points.length - 1].day);
  svg.append(first, last);
  mount.append(svg);
}

/** A 2px line with a filled end-dot carrying a 2px surface ring. */
function sparkline(values, color = "var(--series-1)") {
  const W = 160;
  const H = 34;
  // The end-dot is 4px plus a 2px surface ring, so the last point stops 6px short of the box.
  // Drawn at the full width it is half-clipped by the viewBox, which reads as a rendering
  // glitch rather than as the mark it is.
  const inset = 6;
  const peak = Math.max(1, ...values);
  const step = values.length > 1 ? (W - inset) / (values.length - 1) : W - inset;
  const points = values.map((value, index) => [index * step, H - (value / peak) * (H - 6) - 3]);
  const svg = svgEl("svg", { viewBox: `0 0 ${W} ${H}`, "aria-hidden": "true" });
  svg.append(
    svgEl("path", {
      d: points.map(([x, y], i) => `${i ? "L" : "M"}${x.toFixed(1)},${y.toFixed(1)}`).join(" "),
      fill: "none",
      stroke: color,
      "stroke-width": 2,
      "stroke-linejoin": "round",
      "stroke-linecap": "round",
    }),
  );
  const [ex, ey] = points[points.length - 1];
  svg.append(
    svgEl("circle", {
      cx: ex,
      cy: ey,
      r: 4,
      fill: color,
      stroke: "var(--surface)",
      "stroke-width": 2,
    }),
  );
  return svg;
}

/** Horizontal magnitude bars with the value direct-labelled at the tip. */
function barChart(mount, rows, { color = "var(--series-1)" } = {}) {
  mount.replaceChildren();
  if (!rows.length) {
    mount.innerHTML = '<p class="chart-empty">Nothing yet.</p>';
    return;
  }
  const rowH = 30;
  const W = 640;
  const labelW = 132;
  const valueW = 58;
  const plotW = W - labelW - valueW;
  const peak = Math.max(1, ...rows.map((r) => r.value));
  const svg = svgEl("svg", { viewBox: `0 0 ${W} ${rows.length * rowH}`, role: "img" });

  rows.forEach((row, index) => {
    const y = index * rowH;
    const width = Math.max(2, (row.value / peak) * plotW);
    const label = svgEl("text", {
      x: 0,
      y: y + 19,
      fill: "var(--ink)",
      "font-size": 13,
    });
    label.textContent = row.label;
    // 4px radius at the data end, square at the baseline — a horizontal bar's baseline is its
    // left edge, so the rounding goes on the right.
    const path = `M${labelW},${y + 7} L${labelW + width - 4},${y + 7} Q${labelW + width},${
      y + 7
    } ${labelW + width},${y + 11} L${labelW + width},${y + 19} Q${labelW + width},${y + 23} ${
      labelW + width - 4
    },${y + 23} L${labelW},${y + 23} Z`;
    const value = svgEl("text", {
      x: labelW + width + 8,
      y: y + 19,
      fill: "var(--ink-muted)",
      "font-size": 12.5,
    });
    value.textContent = num(row.value);
    svg.append(label, svgEl("path", { d: path, fill: color }), value);
  });
  mount.append(svg);
}

/**
 * Slot × day grid for the scheduler. A sequential ramp — one hue, light to dark — because the
 * value is magnitude, not identity; a categorical palette here would imply the days differ in
 * kind.
 */
function heatGrid(mount, span, slots) {
  mount.replaceChildren();
  if (!slots.length) {
    mount.innerHTML = '<p class="chart-empty">No assignments in the window.</p>';
    return;
  }
  const cell = 30;
  const gap = 4;
  const labelW = 110;
  const W = labelW + span.length * (cell + gap);
  const H = slots.length * (cell + gap) + 18;
  const peak = Math.max(1, ...slots.flatMap((s) => s.days));
  const svg = svgEl("svg", { viewBox: `0 0 ${W} ${H}`, role: "img" });
  svg.setAttribute("aria-label", "Assignments served per slot per day");
  // A grid of fixed cells is not a chart that should stretch: `width: 100%` on a 446-unit
  // viewBox scaled it 2.7x on a desktop card and rendered the slot names at 28px. Capping at
  // the natural width keeps the type at the size it was specified in and still lets the whole
  // thing shrink on a narrow window.
  svg.style.maxWidth = `${W}px`;

  slots.forEach((slot, row) => {
    const y = row * (cell + gap);
    const label = svgEl("text", {
      x: 0,
      y: y + cell / 2 + 4,
      "font-size": 12,
      fill: slot.silent ? "var(--danger)" : "var(--ink)",
      "font-weight": slot.silent ? 600 : 400,
    });
    label.textContent = slot.slot;
    svg.append(label);

    slot.days.forEach((count, column) => {
      const x = labelW + column * (cell + gap);
      const rect = svgEl("rect", {
        x,
        y,
        width: cell,
        height: cell,
        rx: 5,
        class: "heat-cell",
        fill: count ? "var(--terracotta)" : "var(--chip)",
        "fill-opacity": count ? (0.28 + 0.72 * (count / peak)).toFixed(2) : 1,
      });
      rect.addEventListener("mousemove", (event) =>
        showTip(event, `${slot.slot} · ${dayLabel(span[column])}<br /><b>${count}</b> served`),
      );
      rect.addEventListener("mouseleave", hideTip);
      svg.append(rect);
    });
  });

  const from = svgEl("text", { x: labelW, y: H - 3, "font-size": 11, fill: "var(--ink-faint)" });
  from.textContent = dayLabel(span[0]);
  const to = svgEl("text", {
    x: W,
    y: H - 3,
    "text-anchor": "end",
    "font-size": 11,
    fill: "var(--ink-faint)",
  });
  to.textContent = dayLabel(span[span.length - 1]);
  svg.append(from, to);
  mount.append(svg);
}

// --- Today ------------------------------------------------------------------------------------

function renderToday(data) {
  const { overview: o, growth, themes, signups } = data;

  $("hero-entries").textContent = compact(o.entries.total);
  $("hero-sub").textContent =
    `${num(o.entries.new_7d)} in the last week · ${num(o.entries.backdated)} backdated · ` +
    `${num(o.entries.deleted)} deleted`;

  const days = growth.days;
  columnChart(
    $("chart-entries"),
    days.map((d) => ({ day: d.day, value: d.new_entries, unit: "entries" })),
  );

  const rate = o.assignments.completion_rate_30d;
  const tiles = [
    {
      label: "Households",
      value: compact(o.households.total),
      note: `${num(o.households.by_tier.subscribed || 0)} subscribed · ${num(
        o.households.by_tier.free || 0,
      )} free`,
      spark: days.map((d) => d.active_households),
      color: "var(--series-2)",
    },
    {
      label: "Kids on file",
      value: compact(o.children.total),
      note: `${num(o.devices.active)} device${o.devices.active === 1 ? "" : "s"} registered`,
    },
    {
      label: "Signed in this week",
      value: compact(o.users.signed_in_7d),
      note:
        o.users.never_signed_in > 0
          ? `${num(o.users.never_signed_in)} never observed — the column postdates them`
          : "of " + num(o.users.total) + " accounts",
      spark: days.map((d) => d.new_users),
      color: "var(--series-3)",
    },
    {
      label: "Prompts answered",
      value: rate == null ? "—" : `${Math.round(rate * 100)}%`,
      note:
        rate == null
          ? "nothing has resolved in 30 days"
          : `${num(o.assignments.resolved_30d)} resolved in 30 days`,
    },
    {
      label: "Stored",
      value: bytes(o.media.bytes),
      note:
        o.media.pending_upload > 0
          ? `${num(o.media.pending_upload)} upload${
              o.media.pending_upload === 1 ? "" : "s"
            } never completed`
          : `${num(o.media.total)} files, all uploaded`,
      spark: days.map((d) => d.new_bytes),
      color: "var(--series-1)",
    },
    {
      label: "Library",
      value: compact(o.library.active),
      note:
        o.library.overrides > 0
          ? `${num(o.library.overrides)} console override${
              o.library.overrides === 1 ? "" : "s"
            } held against the seed file`
          : `${num(o.library.total)} bodies, ${num(o.library.total - o.library.active)} retired`,
    },
  ];

  const mount = $("tiles");
  mount.replaceChildren();
  for (const tile of tiles) {
    const node = document.createElement("div");
    node.className = "tile";
    node.innerHTML =
      `<p class="label">${escape(tile.label)}</p>` +
      `<p class="tile-value">${escape(tile.value)}</p>` +
      `<p class="tile-note">${escape(tile.note)}</p>`;
    if (tile.spark && tile.spark.some(Boolean)) {
      const holder = document.createElement("div");
      holder.className = "tile-spark";
      holder.append(sparkline(tile.spark, tile.color));
      node.append(holder);
    }
    mount.append(node);
  }

  barChart(
    $("chart-types"),
    Object.entries(o.entries.by_type)
      .sort((a, b) => b[1] - a[1])
      .map(([label, value]) => ({ label, value })),
  );
  barChart(
    $("chart-themes"),
    themes.map((t) => ({ label: t.theme, value: t.count })),
    { color: "var(--series-2)" },
  );

  $("signups").innerHTML = signups.length
    ? `<table><thead><tr><th>Account</th><th>Tier</th><th class="num">Entries</th>
       <th>Joined</th><th>Last seen</th></tr></thead><tbody>${signups
         .map(
           (row) => `<tr>
             <td>${escape(row.display_name || row.email || "—")}${
               row.display_name && row.email
                 ? `<br /><span class="tile-note">${escape(row.email)}</span>`
                 : ""
             }</td>
             <td><span class="chip ${
               row.tier === "subscribed" ? "chip-ok" : "chip-plain"
             }">${escape(row.tier)}</span></td>
             <td class="num">${num(row.entries)}</td>
             <td>${escape(when(row.created_at))}</td>
             <td>${escape(when(row.last_sign_in_at))}</td>
           </tr>`,
         )
         .join("")}</tbody></table>`
    : '<p class="chart-empty">No accounts yet.</p>';
}

// --- Library ------------------------------------------------------------------------------------

const KINDS = ["question", "photo", "video", "audio", "activity", "measurement", "letter"];
const CADENCES = ["daily", "weekly", "monthly"];
const COMPLETIONS = ["did_it", "media", "text"];
const SOURCES = ["seeded", "user", "llm"];

function renderLibrary(data) {
  state.library = data;
  $("library-count").textContent =
    `${num(data.total)} bodies. Editing a seeded body forks it — the words move to a new ` +
    `prompt and the original is retired through an override, because the seed file would ` +
    `otherwise put it back on the next deploy.`;

  fillSelect($("f-theme"), data.themes, "Every theme");
  fillDatalist($("theme-list"), data.themes);

  $("library").innerHTML = data.prompts.length
    ? `<table><thead><tr>
         <th>Body</th><th>Kind</th><th>Theme</th><th>Ages</th>
         <th class="num">Served</th><th class="num">Done</th><th>State</th>
       </tr></thead><tbody>${data.prompts
         .map(
           (p) => `<tr class="is-clickable ${p.active ? "" : "is-off"}" data-id="${p.id}">
             <td class="body-cell">${markTokens(p.body)}</td>
             <td>${escape(p.kind)}<br /><span class="tile-note">${escape(p.cadence)}</span></td>
             <td>${escape(p.theme)}</td>
             <td class="num">${p.min_age_months}–${p.max_age_months}</td>
             <td class="num">${num(p.served)}</td>
             <td class="num">${num(p.completed)}${
               p.served ? `<br /><span class="tile-note">${Math.round((p.completed / p.served) * 100)}%</span>` : ""
             }</td>
             <td>${stateChips(p)}</td>
           </tr>`,
         )
         .join("")}</tbody></table>`
    : '<p class="chart-empty">Nothing matches those filters.</p>';

  for (const row of $("library").querySelectorAll("tr[data-id]")) {
    row.addEventListener("click", () =>
      openDrawer(data.prompts.find((p) => p.id === row.dataset.id)),
    );
  }
}

function stateChips(prompt) {
  const chips = [
    `<span class="chip ${prompt.active ? "chip-ok" : "chip-plain"}">${
      prompt.active ? "active" : "retired"
    }</span>`,
  ];
  if (prompt.source !== "seeded") {
    chips.push(`<span class="chip chip-peri">${escape(prompt.source)}</span>`);
  }
  if (prompt.override) {
    chips.push('<span class="chip chip-warn">override</span>');
  }
  return chips.join(" ");
}

function fillSelect(select, values, blank) {
  const current = select.value;
  select.replaceChildren();
  const first = document.createElement("option");
  first.value = "";
  first.textContent = blank;
  select.append(first);
  for (const value of values) {
    const option = document.createElement("option");
    option.value = value;
    option.textContent = value;
    select.append(option);
  }
  select.value = current;
}

function fillDatalist(list, values) {
  list.replaceChildren();
  for (const value of values) {
    const option = document.createElement("option");
    option.value = value;
    list.append(option);
  }
}

async function loadLibrary() {
  const params = new URLSearchParams();
  for (const [key, value] of Object.entries(state.filters)) if (value) params.set(key, value);
  renderLibrary(await api(`/admin/library?${params}`));
}

// --- The prompt editor ---------------------------------------------------------------------

function openDrawer(prompt) {
  state.editing = prompt || null;
  const isNew = !prompt;
  $("drawer-title").textContent = isNew ? "Write a prompt" : "Edit prompt";

  const warn = $("drawer-warning");
  if (!isNew && prompt.source === "seeded") {
    warn.hidden = false;
    warn.innerHTML =
      "<strong>This body came from <code>docs/mission-library.md</code>.</strong> " +
      "Changing the words here forks it: a new prompt carries them and this one is retired " +
      "through an override the re-seed will honour. Assignments and entries already pointing " +
      "at this row keep pointing at it — that is what keeps eighteen years of foreign keys " +
      "resolving. Editing the file itself is still the tidier path when you have the repo open.";
  } else if (!isNew && prompt.override) {
    warn.hidden = false;
    warn.textContent = `An override is holding this prompt ${
      prompt.override.active ? "active" : "retired"
    } against the seed file. ${prompt.override.note || ""}`;
  } else {
    warn.hidden = true;
  }

  $("p-body").value = prompt?.body || "";
  fillSelect($("p-kind"), KINDS, "question");
  fillSelect($("p-cadence"), CADENCES, "daily");
  fillSelect($("p-completion"), COMPLETIONS, "text");
  $("p-kind").value = prompt?.kind || "question";
  $("p-cadence").value = prompt?.cadence || "daily";
  $("p-completion").value = prompt?.completion_mode || "text";
  $("p-theme").value = prompt?.theme || "";
  $("p-min").value = prompt?.min_age_months ?? 24;
  $("p-max").value = prompt?.max_age_months ?? 216;
  $("p-months").value = (prompt?.month_tags || []).join(", ");
  $("form-error").hidden = true;

  const retire = $("p-retire");
  retire.hidden = isNew;
  if (!isNew) retire.textContent = prompt.active ? "Retire this prompt" : "Bring it back";
  $("p-release").hidden = isNew || !prompt.override;

  $("drawer").hidden = false;
  refreshPreview();
  $("p-body").focus();
}

const closeDrawer = () => {
  $("drawer").hidden = true;
  state.editing = null;
};

let previewTimer;
function refreshPreview() {
  clearTimeout(previewTimer);
  previewTimer = setTimeout(async () => {
    const text = $("p-body").value.trim();
    const mount = $("preview");
    if (!text) {
      mount.replaceChildren();
      return;
    }
    try {
      const result = await api("/prompts/preview", {
        method: "POST",
        body: JSON.stringify({ body: text, name: "Miles" }),
      });
      if (result.unknown_tokens.length) {
        mount.innerHTML = `<div class="preview-bad"><strong>{${escape(
          result.unknown_tokens[0],
        )}}</strong> is not a prompt token. Every client would render it as literal braces — on a
        card, in an export, and in a printed book.</div>`;
        return;
      }
      // All three columns, because a body can be grammatical in one and broken in another and
      // the author is usually picturing exactly one child while writing.
      mount.innerHTML = [
        ["he/him", result.he_him],
        ["she/her", result.she_her],
        ["they/them, and what an unset pronoun gets", result.they_them],
      ]
        .map(
          ([label, line]) =>
            `<p class="preview-row"><b>${escape(label)}</b>${escape(line)}</p>`,
        )
        .join("");
    } catch (error) {
      mount.innerHTML = `<div class="preview-bad">${escape(error.message)}</div>`;
    }
  }, 220);
}

function readForm() {
  const months = $("p-months")
    .value.split(",")
    .map((part) => Number.parseInt(part.trim(), 10))
    .filter((value) => Number.isInteger(value) && value >= 1 && value <= 12);
  return {
    kind: $("p-kind").value,
    cadence: $("p-cadence").value,
    completion_mode: $("p-completion").value,
    body: $("p-body").value.trim(),
    theme: $("p-theme").value.trim(),
    min_age_months: Number($("p-min").value),
    max_age_months: Number($("p-max").value),
    month_tags: months,
  };
}

async function submitPrompt(event) {
  event.preventDefault();
  const error = $("form-error");
  error.hidden = true;
  const payload = readForm();
  try {
    if (!state.editing) {
      await api("/prompts", { method: "POST", body: JSON.stringify(payload) });
      toast("Written. It is a `user` prompt, so no re-seed will touch it.");
    } else {
      const result = await api(`/prompts/${state.editing.id}`, {
        method: "PATCH",
        body: JSON.stringify(payload),
      });
      toast(
        result.action === "superseded"
          ? "Forked. The new body is live and the original is retired through an override."
          : "Saved.",
      );
    }
    closeDrawer();
    await loadLibrary();
  } catch (err) {
    error.hidden = false;
    error.textContent = err.message;
  }
}

async function toggleRetire() {
  const prompt = state.editing;
  try {
    await api(`/prompts/${prompt.id}/active`, {
      method: "PUT",
      body: JSON.stringify({
        active: !prompt.active,
        note: prompt.active ? "Retired from the admin console." : "Revived from the admin console.",
      }),
    });
    toast(
      prompt.source === "seeded"
        ? "Done, and recorded as an override so the next deploy will not undo it."
        : "Done.",
    );
    closeDrawer();
    await loadLibrary();
  } catch (err) {
    $("form-error").hidden = false;
    $("form-error").textContent = err.message;
  }
}

async function releaseOverride() {
  try {
    await api(`/prompts/${state.editing.id}/override`, { method: "DELETE" });
    toast("Handed back. The next re-seed restores whatever mission-library.md says.");
    closeDrawer();
    await loadLibrary();
  } catch (err) {
    $("form-error").hidden = false;
    $("form-error").textContent = err.message;
  }
}

// --- Costs --------------------------------------------------------------------------------

function renderCosts(data) {
  // `$0.00` with nothing connected is a lie of the most confident kind — it reads as "we spent
  // nothing this month" when it means "no provider has told us anything". Say which it is.
  const reporting = data.providers.filter((p) => p.amount_cents != null);
  $("hero-spend").textContent = reporting.length ? money(data.total_known_cents) : "not connected";
  $("hero-spend").classList.toggle("is-none", !reporting.length);
  $("hero-spend-sub").textContent = !reporting.length
    ? "No provider is reporting a figure yet. Anthropic and GitHub are the two of seven that " +
      "publish a cost API — connect either below and this becomes a real number."
    : data.providers_without_pricing.length
      ? `${data.providers_without_pricing.join(", ")} publish no billing API, so their spend is ` +
        "not in this number. Nothing here is estimated on their behalf."
      : "Across every connected provider.";

  renderChartPicker(data);

  const mount = $("providers");
  mount.replaceChildren();
  for (const provider of data.providers) {
    const card = document.createElement("article");
    card.className = "card";
    const amount =
      provider.amount_cents != null
        ? `<span class="provider-amount">${money(provider.amount_cents)}</span>`
        : `<span class="provider-amount is-none">${
            provider.status === "ok" ? "no billing API" : provider.status
          }</span>`;
    card.innerHTML =
      `<div class="provider-head"><p class="label">${escape(provider.label)}</p>${amount}</div>` +
      (provider.period_label
        ? `<p class="card-note">${escape(provider.period_label)}</p>`
        : "") +
      (provider.detail ? `<p class="card-note">${escape(provider.detail)}</p>` : "") +
      (provider.metrics.length
        ? `<ul class="metric-list">${provider.metrics
            .map(
              (m) => `<li class="metric">
                <span class="metric-dot" data-tone="${escape(m.tone)}"></span>
                <span class="metric-label">${escape(m.label)}${
                  m.detail ? `<span class="metric-detail">${escape(m.detail)}</span>` : ""
                }</span>
                <span class="metric-value">${escape(m.value)}</span>
              </li>`,
            )
            .join("")}</ul>`
        : "") +
      (provider.setup ? `<div class="setup">${escape(provider.setup)}</div>` : "") +
      (provider.console_url
        ? `<a class="provider-link" href="${escape(
            provider.console_url,
          )}" target="_blank" rel="noreferrer noopener">Open the invoice →</a>`
        : "");
    mount.append(card);
  }
}

// A costs chart is not always a chart of money. Anthropic and GitHub report cents; Neon
// reports compute unit hours and no dollars at all. `series_unit` says which, and the
// provider is picked rather than hardcoded because there is now more than one.
function renderChartPicker(data) {
  const charted = data.providers.filter((p) => (p.series || []).length);
  state.chart = charted.some((p) => p.key === state.chart) ? state.chart : charted[0]?.key || null;
  drawSeries(data);

  const picker = $("chart-picker");
  picker.replaceChildren();
  if (charted.length < 2) return; // one series needs no chooser, and none needs no row
  for (const provider of charted) {
    const button = document.createElement("button");
    button.type = "button";
    button.className = "chart-tab";
    // A data attribute, not `style=` — the CSP is `style-src 'self'` with no 'unsafe-inline',
    // so an inline style is dropped silently. Same pattern as `.metric-dot[data-tone]`.
    button.dataset.active = String(provider.key === state.chart);
    button.textContent = provider.label;
    button.addEventListener("click", () => {
      state.chart = provider.key;
      renderChartPicker(data);
    });
    picker.append(button);
  }
}

function drawSeries(data) {
  const provider = data.providers.find((p) => p.key === state.chart);
  $("chart-spend-label").textContent = provider?.series_label || "Nothing charted yet";
  const isMoney = provider?.series_unit === "cents";
  columnChart(
    $("chart-spend"),
    (provider?.series || []).map((point) => ({
      day: point.day,
      value: (isMoney ? point.cents : point.value) || 0,
    })),
    {
      color: isMoney ? "var(--series-1)" : "var(--series-2)",
      format: isMoney
        ? (cents) => money(cents)
        : (value) => `${value.toLocaleString(undefined, { maximumFractionDigits: 1 })}`,
    },
  );
}

const toneColor = (tone) =>
  ({
    ok: "var(--sage-ink)",
    warn: "var(--warn)",
    bad: "var(--danger)",
  })[tone] || "var(--ink-faint)";

// --- Ops ----------------------------------------------------------------------------------

function renderOps(data) {
  $("env-chip").textContent = data.environment;
  $("env-chip").className = `chip ${data.environment === "prod" ? "chip-bad" : "chip-plain"}`;
  renderDatabaseChip(data.database);

  heatGrid($("scheduler"), data.scheduler.span, data.scheduler.slots);
  const silent = data.scheduler.slots.filter((s) => s.silent).map((s) => s.slot);
  banner(
    silent.length
      ? `Daily slot${silent.length > 1 ? "s" : ""} ${silent.join(", ")} served nothing in the ` +
          "last fortnight. Read the rows before trusting a green deploy — that is exactly how " +
          "the photo slot went missing for a month."
      : "",
  );

  $("flags").innerHTML = data.flags
    .map(
      (flag) => `<div class="flag">
        <span class="flag-key">${escape(flag.key)}</span>
        <span class="chip chip-${flag.tone === "plain" ? "plain" : flag.tone}">${escape(
          flag.value ?? (flag.on ? "on" : "off"),
        )}</span>
        <span class="flag-means">${escape(flag.means)}</span>
      </div>`,
    )
    .join("");

  const jobs = data.jobs;
  const lines = [
    ["Migration", jobs.migration || "unknown"],
    ["Last assignment written", when(data.scheduler.last_assignment_at)],
    ["Notifications sent, 7d", `${num(jobs.notifications.sends_7d)}`],
    ["Delivered to a device, 7d", `${num(jobs.notifications.delivered_7d)}`],
    [
      "Deletions pending",
      jobs.deletion_queue.length
        ? `${jobs.deletion_queue.length}${
            jobs.deletion_queue.some((d) => d.overdue) ? " — some overdue" : ""
          }`
        : "none",
    ],
  ];
  $("jobs").innerHTML =
    lines
      .map(
        ([label, value]) =>
          `<div class="job-line"><span>${escape(label)}</span><span>${escape(value)}</span></div>`,
      )
      .join("") +
    (jobs.broadcasts.length
      ? `<div class="table-wrap"><table><thead><tr><th>Broadcast</th><th>Status</th></tr></thead>
         <tbody>${jobs.broadcasts
           .map(
             (b) => `<tr><td>${escape(b.send_date)}<br /><span class="tile-note">${escape(
               b.subject,
             )}</span></td><td><span class="chip chip-${
               { sent: "ok", skipped: "plain", failed: "bad" }[b.status] || "plain"
             }">${escape(b.status)}</span></td></tr>`,
           )
           .join("")}</tbody></table></div>`
      : '<p class="card-note">The daily broadcast has never written a ledger row.</p>');
}


// --- Studio -------------------------------------------------------------------------------
//
// The honest shape of this screen, stated once: Claude writes the words and picks the layout,
// `cards.js` draws the pixels, and a third-party provider renders a photograph if one is
// configured. There is no Anthropic image endpoint, so a "generate image" button wired to the
// Anthropic key would be a spinner attached to nothing.
//
// Nothing here posts anywhere. Generate, review, download.

function renderStudioState(state) {
  state && (window.__studio = state);
  const ledger = state.library_ledger;
  const pct = Math.min(100, (ledger.featured / Math.max(1, ledger.cap)) * 100);
  $("studio-state").innerHTML =
    `<div class="chart-head"><div>
       <p class="label">The studio</p>
       <p class="card-note">${escape(state.director.cannot)}</p>
     </div></div>
     <div class="provider-strip">${state.renderers
       .map(
         (r) => `<span class="provider-pill ${r.configured ? "is-on" : ""}" title="${escape(
           r.configured ? r.note : r.setup,
         )}"><span class="metric-dot" data-tone="${
           r.configured ? "ok" : "plain"
         }"></span>${escape(r.label)}</span>`,
       )
       .join("")}</div>
     ${
       state.director.configured
         ? ""
         : `<div class="setup">${escape(state.director.setup)}</div>`
     }
     <p class="card-note ledger-note">
       <strong>${ledger.featured} of ${ledger.library_size}</strong> library prompts have been put
       into posts, against a cap of ${ledger.cap}. ${escape(ledger.why)}
     </p>
     <div class="ledger-bar"><span id="ledger-fill"></span></div>`;
  // Set through the CSSOM rather than a `style=` attribute: the page's CSP is
  // `style-src 'self'` with no `unsafe-inline`, which blocks the attribute silently. The fill
  // then inherited its track's width and an empty budget drew as a full one.
  $("ledger-fill").style.width = `${pct}%`;

  fillSelect($("c-platform"), state.platforms, "instagram");
  $("c-platform").value = "instagram";
  fillSelect($("m-template"), state.templates, "quote");
  fillSelect($("m-palette"), state.palettes, "cream");
  fillSelect($("m-platform"), state.platforms, "instagram");
  $("c-ledger").textContent = ledger.remaining
    ? `${ledger.remaining} more prompts may be featured before the cap.`
    : "The cap is reached. Raise SOCIAL_FEATURED_PROMPT_CAP to feature another.";
}

async function loadStudio() {
  const state = await api("/social/studio");
  state.director.configured || banner("");
  renderStudioState(state);
  state.__loaded = true;
  window.__studio = state;

  // The prompt picker is the only route by which a library body reaches a post, and it is
  // deliberately a manual choice rather than something the model can reach for.
  if (!state.__prompts) {
    const library = await api("/admin/library?active=true&limit=400");
    const select = $("c-prompt");
    select.replaceChildren();
    const blank = document.createElement("option");
    blank.value = "";
    blank.textContent = "Nothing attached";
    select.append(blank);
    for (const prompt of library.prompts) {
      const option = document.createElement("option");
      option.value = prompt.id;
      option.textContent =
        prompt.body.length > 78 ? `${prompt.body.slice(0, 78)}…` : prompt.body;
      select.append(option);
    }
  }
  await loadAssets();
}

function pushTurn(role, text) {
  const log = $("chat-log");
  if (log.querySelector(".chat-empty")) log.replaceChildren();
  const node = document.createElement("div");
  node.className = `turn turn-${role}`;
  node.textContent = text;
  log.append(node);
  log.scrollTop = log.scrollHeight;
  return node;
}

async function sendChat(event) {
  event.preventDefault();
  const input = $("chat-input");
  const text = input.value.trim();
  if (!text) return;
  input.value = "";
  state.chat.push({ role: "user", content: text });
  pushTurn("user", text);

  const node = pushTurn("assistant", "");
  node.classList.add("turn-thinking");
  let reply = "";
  try {
    // `fetch` with a ReadableStream rather than EventSource: EventSource cannot set an
    // Authorization header, and this API takes bearer tokens like every other route.
    const response = await fetch("/v1/social/chat", {
      method: "POST",
      headers: { "content-type": "application/json", authorization: `Bearer ${token}` },
      body: JSON.stringify({ messages: state.chat }),
    });
    if (!response.ok) {
      const payload = await response.json().catch(() => null);
      throw new ApiError(response.status, payload);
    }
    const reader = response.body.getReader();
    const decoder = new TextDecoder();
    for (;;) {
      const { value, done } = await reader.read();
      if (done) break;
      reply += decoder.decode(value, { stream: true });
      node.textContent = reply;
      $("chat-log").scrollTop = $("chat-log").scrollHeight;
    }
    state.chat.push({ role: "assistant", content: reply });
  } catch (error) {
    node.textContent = error.message;
  } finally {
    node.classList.remove("turn-thinking");
  }
}

async function writeConcepts(event) {
  event.preventDefault();
  const error = $("c-error");
  error.hidden = true;
  const button = event.target.querySelector("button[type=submit]");
  button.disabled = true;
  button.textContent = "Thinking…";
  try {
    const result = await api("/social/concepts", {
      method: "POST",
      body: JSON.stringify({
        brief: $("c-brief").value.trim(),
        count: Number($("c-count").value),
        platform: $("c-platform").value,
        featured_prompt_id: $("c-prompt").value || null,
      }),
    });
    state.concepts = result.concepts.map((concept) => ({
      ...concept,
      platform: $("c-platform").value,
      model: result.model,
      featured_prompt_id: result.featured_prompt_id,
    }));
    renderConcepts();
  } catch (err) {
    error.hidden = false;
    error.textContent = err.message;
  } finally {
    button.disabled = false;
    button.textContent = "Write concepts";
  }
}

function renderConcepts() {
  const mount = $("concepts");
  mount.replaceChildren();
  state.concepts.forEach((concept, index) => {
    const card = document.createElement("article");
    card.className = "card concept";
    card.innerHTML =
      `<p class="label">${escape(concept.template)} · ${escape(concept.palette)}</p>
       <p class="concept-angle">${escape(concept.angle)}</p>
       <p class="concept-headline">${escape(concept.headline)}</p>
       <p class="concept-caption">${escape(concept.caption)}</p>
       <div class="concept-meta">${(concept.hashtags || [])
         .slice(0, 4)
         .map((tag) => `<span class="chip chip-plain">${escape(tag)}</span>`)
         .join("")}</div>`;
    card.addEventListener("click", () => openComposer(state.concepts[index]));
    mount.append(card);
  });
}

async function writeShotList() {
  const brief = $("v-brief").value.trim();
  if (!brief) return;
  const button = $("v-go");
  button.disabled = true;
  button.textContent = "Writing…";
  try {
    const result = await api("/social/shot-list", {
      method: "POST",
      body: JSON.stringify({ brief, seconds: 30 }),
    });
    // Saved immediately rather than shown and discarded: a shot list is the thing somebody
    // takes out to a park with a phone, and it should survive closing the tab.
    const asset = await api("/social/assets", {
      method: "POST",
      body: JSON.stringify({
        platform: "instagram_story",
        format: "video",
        angle: result.premise,
        headline: result.title,
        caption: result.shots
          .map((s, i) => `${i + 1}. (${s.seconds}s) ${s.visual}\n   “${s.on_screen_text}”`)
          .join("\n"),
        shot_list: { shots: result.shots },
        caption_track: result.caption_track,
        duration_seconds: result.duration_seconds,
        model: result.model,
      }),
    });
    toast(`Shot list saved — ${result.shots.length} shots, ${result.duration_seconds}s.`);
    await loadAssets();
    openComposer(null, asset);
  } catch (err) {
    banner(err.message);
  } finally {
    button.disabled = false;
    button.textContent = "Shot list";
  }
}

async function loadAssets() {
  const filter = $("a-filter").value;
  const { assets } = await api(`/social/assets${filter ? `?status=${filter}` : ""}`);
  const mount = $("assets");
  mount.replaceChildren();
  if (!assets.length) {
    mount.innerHTML = '<p class="chart-empty">Nothing saved yet.</p>';
    return;
  }
  for (const asset of assets) {
    const node = document.createElement("div");
    node.className = "asset";
    const canvas = document.createElement("canvas");
    const [w, h] = cards.SIZES[asset.platform] || cards.SIZES.generic;
    canvas.width = 320;
    canvas.height = Math.round((320 * h) / w);
    cards.drawCard(canvas.getContext("2d"), specOf(asset), canvas.width, canvas.height, 1);
    node.append(canvas);
    const line = document.createElement("p");
    line.className = "asset-line";
    line.innerHTML =
      `<span class="chip chip-${
        { published: "ok", exported: "peri", discarded: "plain" }[asset.status] || "plain"
      }">${escape(asset.status)}</span>` +
      `<span>${escape(asset.platform)}</span>` +
      (asset.featured_body ? '<span class="chip chip-warn">library prompt</span>' : "");
    node.append(line);
    node.addEventListener("click", () => openComposer(null, asset));
    mount.append(node);
  }
}

/** The renderer's view of an asset or a concept — the one shape `cards.js` understands. */
const specOf = (source) => ({
  template: source.template || "quote",
  palette: source.palette || "cream",
  eyebrow: source.eyebrow || "",
  headline: source.headline || "",
  subhead: source.subhead || "",
});

function openComposer(concept, asset) {
  const source = asset || concept || {};
  state.composing = {
    id: asset?.id || null,
    platform: source.platform || "instagram",
    featured_prompt_id: source.featured_prompt_id || null,
    format: source.format || "card",
    angle: source.angle || "",
    image_prompt: source.image_prompt || "",
    model: source.model || null,
  };
  $("composer-title").textContent = asset ? "Edit post" : "Compose";
  $("m-template").value = source.template || "quote";
  $("m-palette").value = source.palette || "cream";
  $("m-platform").value = source.platform || "instagram";
  $("m-eyebrow").value = source.eyebrow || "";
  $("m-headline").value = source.headline || "";
  $("m-subhead").value = source.subhead || "";
  $("m-caption").value = source.caption || "";
  $("m-alt").value = source.alt_text || "";
  $("m-tags").value = (source.hashtags || []).join(", ");
  $("m-error").hidden = true;
  $("m-webm").hidden = !cards.canRecord();
  $("card-note").textContent = cards.canRecord()
    ? "WebM records the card settling in — an animated post, not generated footage."
    : "This browser cannot record WebM from a canvas. PNG still works.";
  $("composer").hidden = false;
  paintPreview();
}

const closeComposer = () => {
  $("composer").hidden = true;
  state.composing = null;
};

function composerSpec() {
  return {
    template: $("m-template").value,
    palette: $("m-palette").value,
    eyebrow: $("m-eyebrow").value.trim(),
    headline: $("m-headline").value.trim(),
    subhead: $("m-subhead").value.trim(),
  };
}

function paintPreview() {
  const canvas = $("card-canvas");
  const platform = $("m-platform").value;
  const [w, h] = cards.SIZES[platform] || cards.SIZES.generic;
  // Drawn at a preview scale rather than full size and shrunk with CSS: a 1080x1920 canvas in
  // a drawer is four megabytes of pixels redrawn on every keystroke.
  canvas.width = 380;
  canvas.height = Math.round((380 * h) / w);
  cards.drawCard(canvas.getContext("2d"), composerSpec(), canvas.width, canvas.height, 1);
}

function composerPayload() {
  const spec = composerSpec();
  return {
    platform: $("m-platform").value,
    format: state.composing.format,
    angle: state.composing.angle || null,
    template: spec.template,
    palette: spec.palette,
    headline: spec.headline || null,
    subhead: spec.subhead || null,
    caption: $("m-caption").value.trim() || null,
    alt_text: $("m-alt").value.trim() || null,
    hashtags: $("m-tags")
      .value.split(",")
      .map((tag) => tag.trim().replace(/^#/, ""))
      .filter(Boolean),
    image_prompt: state.composing.image_prompt || null,
  };
}

async function saveComposer(event) {
  event.preventDefault();
  const error = $("m-error");
  error.hidden = true;
  try {
    if (state.composing.id) {
      await api(`/social/assets/${state.composing.id}`, {
        method: "PATCH",
        body: JSON.stringify(composerPayload()),
      });
    } else {
      const created = await api("/social/assets", {
        method: "POST",
        body: JSON.stringify({
          ...composerPayload(),
          featured_prompt_id: state.composing.featured_prompt_id,
          model: state.composing.model,
        }),
      });
      state.composing.id = created.id;
    }
    toast("Saved.");
    await Promise.all([loadAssets(), loadStudio()]);
  } catch (err) {
    error.hidden = false;
    error.textContent = err.message;
  }
}

async function markExported() {
  const error = $("m-error");
  error.hidden = true;
  if (!state.composing.id) {
    error.hidden = false;
    error.textContent = "Save it first.";
    return;
  }
  try {
    await api(`/social/assets/${state.composing.id}`, {
      method: "PATCH",
      body: JSON.stringify({ status: "exported", alt_text: $("m-alt").value.trim() || null }),
    });
    toast("Marked exported. Posting it is still your job — nothing here posts.");
    await loadAssets();
  } catch (err) {
    error.hidden = false;
    error.textContent = err.message;
  }
}

const slug = () =>
  ($("m-headline").value.trim() || "vellum")
    .toLowerCase()
    .replace(/[^a-z0-9]+/g, "-")
    .replace(/^-|-$/g, "")
    .slice(0, 48) || "vellum";

async function downloadPng() {
  const blob = await cards.toPngBlob(composerSpec(), $("m-platform").value);
  cards.download(blob, `${slug()}.png`);
}

async function downloadWebm() {
  const button = $("m-webm");
  button.disabled = true;
  button.textContent = "Recording…";
  try {
    const blob = await cards.recordCard(composerSpec(), $("m-platform").value, 4);
    cards.download(blob, `${slug()}.webm`);
  } finally {
    button.disabled = false;
    button.textContent = "Download WebM";
  }
}

/**
 * Which database the numbers came from, on every screen.
 *
 * Shown always, not only when it is unusual. Six rows of local fixtures look exactly like six
 * real customers until something says which they are — that ambiguity is what sent somebody
 * looking for their wife's account in a database she had never touched.
 */
function renderDatabaseChip(database) {
  const chip = $("db-chip");
  if (!database) {
    chip.hidden = true;
    return;
  }
  chip.hidden = false;
  const remote = database.reading === "remote";
  chip.textContent = remote ? `${database.host} · read-only` : `local · ${database.host}`;
  chip.className = `chip ${remote ? "chip-peri" : "chip-plain"}`;
  chip.title = database.note;
  // Read-only mode disables every write in the console, so the buttons that would fail go
  // away rather than waiting to explain themselves after a click.
  document.body.dataset.readonly = String(remote);
}

// --- Loading ------------------------------------------------------------------------------

let currentTab = "today";

async function load(tab = currentTab) {
  currentTab = tab;
  try {
    if (tab === "today") {
      state.snapshot = await api(`/admin/snapshot?days=${state.days}`);
      renderToday(state.snapshot);
    } else if (tab === "library") {
      await loadLibrary();
    } else if (tab === "studio") {
      await loadStudio();
    } else if (tab === "costs") {
      renderCosts(await api("/admin/costs"));
    } else if (tab === "ops") {
      renderOps(await api("/admin/ops"));
    }
    $("stamp").textContent = `updated ${new Date().toLocaleTimeString("en-US", {
      hour: "numeric",
      minute: "2-digit",
    })}`;
  } catch (error) {
    if (error.status === 401) return signOut("That token is not valid any more.");
    if (error.status === 403) {
      return signOut("That account is not an admin. Set `is_admin` on the user row.");
    }
    banner(error.message);
  }
}

function showTab(tab) {
  for (const button of document.querySelectorAll(".tab")) {
    button.classList.toggle("is-on", button.dataset.tab === tab);
    button.setAttribute("aria-selected", String(button.dataset.tab === tab));
  }
  for (const panel of document.querySelectorAll(".panel")) {
    panel.hidden = panel.id !== `panel-${tab}`;
  }
  load(tab);
}

// --- Sign in / out --------------------------------------------------------------------------

function signedIn() {
  body.dataset.view = "console";
  $("console").hidden = false;
  // Ops first: it is the cheapest call and it is what fills the environment chip, so the
  // top bar is never briefly wrong about which database is being looked at.
  api("/admin/ops")
    .then(renderOps)
    .catch(() => {});
  showTab("today");
}

function signOut(message) {
  token = "";
  refreshToken = "";
  localStorage.removeItem(TOKEN_KEY);
  localStorage.removeItem(REFRESH_KEY);
  body.dataset.view = "signin";
  $("console").hidden = true;
  const error = $("signin-error");
  error.hidden = !message;
  error.textContent = message || "";
}

/** Store whatever half of a token pair we were given. */
function keepSession(pair) {
  if (pair.access_token) {
    token = pair.access_token;
    localStorage.setItem(TOKEN_KEY, token);
  }
  if (pair.refresh_token) {
    refreshToken = pair.refresh_token;
    localStorage.setItem(REFRESH_KEY, refreshToken);
  }
}

function useToken(value) {
  keepSession({ access_token: value });
  signedIn();
}

/**
 * Exchange a magic-link token for a session.
 *
 * The link in the email points at `/signin?token=…`, which is a universal link the iOS app
 * claims and, on a laptop, a page that says to open it on a phone. That page deliberately does
 * not carry the token into a web flow — it was written when there was no web client. There is
 * one now, so the token is taken from the address bar and exchanged here rather than that page
 * being changed: a parent opening a sign-in link on a laptop should still be told to use their
 * phone, and only somebody deliberately in the console should land in the console.
 */
async function useMagicLink(raw) {
  const error = $("signin-error");
  error.hidden = true;
  // Paste the whole URL or just the token — reading the address bar and copying exactly the
  // opaque part is a needless way to get this wrong.
  let value = raw.trim();
  try {
    if (value.includes("://")) value = new URL(value).searchParams.get("token") || value;
  } catch {
    /* not a URL; treat it as the token */
  }
  try {
    const response = await fetch("/v1/auth/email/complete", {
      method: "POST",
      headers: { "content-type": "application/json" },
      body: JSON.stringify({ token: value }),
    });
    const payload = await response.json().catch(() => null);
    if (!response.ok) throw new ApiError(response.status, payload);
    keepSession(payload);
    signedIn();
  } catch (err) {
    error.hidden = false;
    error.textContent =
      err.status === 401
        ? "That link is expired, already used, or not valid. Sign-in links last fifteen " +
          "minutes and work once — request another."
        : err.message;
  }
}

/** Ask for a sign-in link. Always answers 202, whether or not the address matched anything. */
async function requestMagicLink(address) {
  const error = $("signin-error");
  error.hidden = true;
  try {
    await fetch("/v1/auth/email/start", {
      method: "POST",
      headers: { "content-type": "application/json" },
      body: JSON.stringify({ email: address }),
    });
    // The API answers 202 either way on purpose — anything else would say whether an address
    // has an account. So this message has to be true in both cases, and says nothing about
    // whether anything was sent.
    error.hidden = false;
    error.textContent =
      `If ${address} can sign in to Vellum, a link is on its way. Open it, copy the whole ` +
      "URL out of the address bar, and paste it below. The page it lands on will tell you to " +
      "use your iPhone — ignore that, it is for parents rather than for this.";
  } catch (err) {
    error.hidden = false;
    error.textContent = err.message;
  }
}

$("dev-login").addEventListener("click", async () => {
  const error = $("signin-error");
  error.hidden = true;
  try {
    const result = await api("/auth/dev-login", { method: "POST", body: "{}" });
    keepSession(result);
    signedIn();
  } catch (err) {
    error.hidden = false;
    error.textContent =
      err.status === 404
        ? "dev-login is not mounted. It only exists when ENVIRONMENT=local — paste an access token instead."
        : err.message;
  }
});

$("token-form").addEventListener("submit", (event) => {
  event.preventDefault();
  const value = $("token-input").value.trim();
  if (value) useToken(value);
});


$("link-form").addEventListener("submit", (event) => {
  event.preventDefault();
  const address = $("link-email").value.trim();
  if (address) requestMagicLink(address);
});
$("magic-form").addEventListener("submit", (event) => {
  event.preventDefault();
  const value = $("magic-input").value.trim();
  if (value) useMagicLink(value);
});
$("signout").addEventListener("click", () => signOut(""));
$("refresh").addEventListener("click", () => load());

for (const button of document.querySelectorAll(".tab")) {
  button.addEventListener("click", () => showTab(button.dataset.tab));
}
for (const button of document.querySelectorAll(".range-btn")) {
  button.addEventListener("click", () => {
    for (const other of document.querySelectorAll(".range-btn")) {
      other.classList.toggle("is-on", other === button);
    }
    state.days = Number(button.dataset.days);
    load("today");
  });
}

for (const [id, key] of [
  ["f-q", "q"],
  ["f-kind", "kind"],
  ["f-cadence", "cadence"],
  ["f-theme", "theme"],
  ["f-source", "source"],
  ["f-active", "active"],
]) {
  const el = $(id);
  const handler = () => {
    state.filters[key] = el.value;
    loadLibrary().catch((error) => banner(error.message));
  };
  el.addEventListener(el.tagName === "SELECT" ? "change" : "input", debounce(handler, 260));
}

function debounce(fn, ms) {
  let timer;
  return (...args) => {
    clearTimeout(timer);
    timer = setTimeout(() => fn(...args), ms);
  };
}

fillSelect($("f-kind"), KINDS, "Every kind");
fillSelect($("f-cadence"), CADENCES, "Every cadence");
fillSelect($("f-source"), SOURCES, "Every source");

$("new-prompt").addEventListener("click", () => openDrawer(null));
$("prompt-form").addEventListener("submit", submitPrompt);
$("p-body").addEventListener("input", refreshPreview);
$("p-retire").addEventListener("click", toggleRetire);
$("p-release").addEventListener("click", releaseOverride);
for (const node of document.querySelectorAll("[data-close]")) {
  node.addEventListener("click", closeDrawer);
}
document.addEventListener("keydown", (event) => {
  if (event.key !== "Escape") return;
  if (!$("composer").hidden) closeComposer();
  else if (!$("drawer").hidden) closeDrawer();
});


$("chat-form").addEventListener("submit", sendChat);
$("chat-input").addEventListener("keydown", (event) => {
  // Enter sends, shift+enter breaks the line. A chat box that needs a mouse to send is a chat
  // box nobody uses twice.
  if (event.key === "Enter" && !event.shiftKey) {
    event.preventDefault();
    $("chat-form").requestSubmit();
  }
});
$("concepts-form").addEventListener("submit", writeConcepts);
$("v-go").addEventListener("click", writeShotList);
$("a-filter").addEventListener("change", () => loadAssets().catch((e) => banner(e.message)));
$("composer-form").addEventListener("submit", saveComposer);
$("m-png").addEventListener("click", downloadPng);
$("m-webm").addEventListener("click", downloadWebm);
$("m-export").addEventListener("click", markExported);
for (const id of ["m-template", "m-palette", "m-platform", "m-eyebrow", "m-headline", "m-subhead"]) {
  $(id).addEventListener("input", paintPreview);
  $(id).addEventListener("change", paintPreview);
}
for (const node of document.querySelectorAll("[data-close-composer]")) {
  node.addEventListener("click", closeComposer);
}
$("chat-log").innerHTML =
  '<p class="chat-empty">Ask for angles, a caption, a rewrite, or an opinion on an idea.</p>';

if (token) signedIn();
