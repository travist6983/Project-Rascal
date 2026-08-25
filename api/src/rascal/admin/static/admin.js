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
  candidates: [],
  composing: null,
  // The in-flight poll for a video render, so closing the composer stops it.
  renderPoll: null,
  // Bumped whenever the poll should stop. `clearTimeout` cannot cancel a poll that is already
  // awaiting its fetch, and that poll would otherwise reschedule itself after the composer
  // closed — two loops, one cancellable slot.
  renderPollEpoch: 0,
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

/**
 * A date that may be in the future, which `when` cannot render.
 *
 * `when` measures `now - then` and floors at "just now", so a trial ending in a fortnight
 * came out as **"just now"** — a confident wrong answer on the one column somebody would
 * read to decide whether to move it. Found by loading the console, not by a test.
 *
 * Absolute date first because that is what you act on, distance second because that is what
 * you scan for.
 */
function deadline(iso) {
  if (!iso) return "—";
  const then = new Date(iso);
  // **The last day the trial is still active, not the instant it stops.** `trial_ends_at` is an
  // exclusive end — `access_for` compares `now < trial_ends_at` — and `endOfDayIso` stores local
  // midnight *after* the chosen day. Rendering the instant meant picking "Sep 4" and being told
  // "Sep 5", which contradicts both the date you typed and the runbook's "the date you pick is
  // the last day of the trial". One millisecond back lands inside the last active day, in local
  // time, for any value: one the lever set, one the migration backfilled, or one already past.
  const lastDay = new Date(then.getTime() - 1);
  const on = lastDay.toLocaleDateString("en-US", { month: "short", day: "numeric" });
  const days = Math.round((then.getTime() - Date.now()) / 86400000);
  if (days > 0) return `${on} · in ${days}d`;
  if (days === 0) return `${on} · today`;
  return `${on} · ${Math.abs(days)}d ago`;
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

  // `access` is the computed answer — `subscribed` | `trial` | `free` — and `tier` is the
  // column. Both are shown because they answer different questions: `tier` says whether Apple
  // has told us somebody is paying, `access` says what a phone will actually be served today.
  // A console showing only one of them would make a trial look like a lapse.
  $("signups").innerHTML = signups.length
    ? `<table><thead><tr><th>Account</th><th>Access</th><th>Tier</th><th>Trial ends</th>
       <th class="num">Entries</th><th>Joined</th><th>Last seen</th></tr></thead><tbody>${signups
         .map(
           (row) => `<tr>
             <td>${escape(row.display_name || row.email || "—")}${
               row.display_name && row.email
                 ? `<br /><span class="tile-note">${escape(row.email)}</span>`
                 : ""
             }</td>
             <td><span class="chip ${accessChip(row.access)}">${escape(
               row.access || "free",
             )}</span></td>
             <td><span class="chip ${
               row.tier === "subscribed" ? "chip-ok" : "chip-plain"
             }">${escape(row.tier)}</span>${
               // **Why a `free` household can read `subscribed` one column to the left.**
               // Without this the two columns look like a bug rather than like a grant.
               row.granted ? ' <span class="chip chip-peri">granted</span>' : ""
             }</td>
             <td>${escape(deadline(row.trial_ends_at))}</td>
             <td class="num">${num(row.entries)}</td>
             <td>${escape(when(row.created_at))}</td>
             <td>${escape(when(row.last_sign_in_at))}</td>
           </tr>`,
         )
         .join("")}</tbody></table>`
    : '<p class="chart-empty">No accounts yet.</p>';

  fillHouseholds(signups);
}

function accessChip(access) {
  if (access === "subscribed") return "chip-ok";
  if (access === "trial") return "chip-warn";
  return "chip-plain";
}

// --- The one entitlement lever -----------------------------------------------------------------
//
// Set or clear a household's `trial_ends_at`. There is deliberately no control that writes
// `tier`: App Store Server Notifications are its only writer, and a button here that could
// disagree with Apple about who is paying would be worse than no button at all.

function fillHouseholds(signups) {
  const select = $("t-family");
  const previous = select.value;
  // One option per household rather than per account — a two-parent family is one
  // entitlement row, and offering it twice invites setting it twice and wondering which won.
  const households = new Map();
  for (const row of signups) {
    if (!row.family_id || households.has(row.family_id)) continue;
    households.set(row.family_id, row);
  }
  select.replaceChildren();
  for (const [familyId, row] of households) {
    const option = document.createElement("option");
    option.value = familyId;
    // **The short family id is not decoration.** Two households whose accounts share a display
    // name — which two dev-login fixtures do — produced two visually identical options, and
    // picking the wrong one moves the wrong household's trial. Found by loading the console.
    option.textContent = `${row.display_name || row.email || "unnamed"} · ${familyId.slice(
      0,
      8,
    )} — ${row.access || "free"}`;
    select.append(option);
  }
  // **Restore the selection, or say it is gone — never silently pick a different household.**
  // `replaceChildren` leaves a `<select>` on its first option, so a household that dropped out
  // of the list between renders would hand the next click a *different* family than the one on
  // screen a moment ago. That is the same harm as two identically-labelled options above, by a
  // different route: the button moves the wrong household's trial and looks like it worked.
  // `recent_signups` returns the newest twelve, so this is reachable the day there is a
  // thirteenth account.
  if (previous && !households.has(previous)) {
    select.selectedIndex = -1;
    $("trial-state").textContent =
      "The household you had selected is no longer in this list. Pick again.";
    return;
  }
  if (households.has(previous)) select.value = previous;
  $("trial-state").textContent = households.size ? "" : "No households yet — nothing to move.";
}

function endOfDayIso(value) {
  const [year, month, day] = value.split("-").map(Number);
  // Local midnight *after* the chosen day, so picking today leaves the household in its trial
  // for the rest of today rather than dropping it the moment the date is saved. `day + 1`
  // rolls the month and the year on its own.
  return new Date(year, month - 1, day + 1).toISOString();
}

async function writeTrial(trialEndsAt) {
  const familyId = $("t-family").value;
  // Deliberately not named `state` — that is a module-level object in this file, and shadowing
  // it inside an async function is the kind of thing that reads fine and breaks the next edit.
  const status = $("trial-state");
  if (!familyId) {
    status.textContent = "Pick a household first.";
    return;
  }
  try {
    const result = await api(`/admin/families/${familyId}/trial`, {
      method: "PUT",
      body: JSON.stringify({ trial_ends_at: trialEndsAt }),
    });
    toast(trialEndsAt ? "Trial moved." : "Trial cleared.");
    // Repaint from the server rather than from what we just sent, so the Access column and
    // the household dropdown agree with the row that actually exists.
    //
    // **The confirmation is written after the repaint, not before.** `load()` runs
    // `fillHouseholds`, which resets this line — so writing it first put the sentence on
    // screen for exactly as long as the request took and then wiped it. The toast survived
    // and hid the fact that the more useful message did not. Found by driving the console,
    // not by a test.
    await load();
    // **Say why nothing moved, at the moment it did not move.** A subscribed household reads
    // `subscribed` whatever this writes, because `subscribed` beats `trial`. Reporting only
    // "Access is now subscribed" is accurate and reads like a control that failed silently.
    //
    // **Three explanations now, not two, and phase 121 is why the third matters.** A household
    // that stays "subscribed" after this writes is either paying or granted, and sending
    // somebody to runbook-deploy.md §7a to fix a tier that was never the reason is a worse
    // outcome than saying nothing. `entitlement_source` is what tells the two apart.
    if (result.entitlement_source === "receipt") {
      status.textContent =
        `Saved, but access stays “subscribed” — the tier outranks the trial. Set tier back to ` +
        `“free” (runbook-deploy.md §7a) to see the free tier.`;
    } else if (result.entitlement_source === "grant") {
      status.textContent =
        `Saved, but access stays “subscribed” — a grant is holding this household open. ` +
        `Revoke it in Grants below to see the free tier. The tier is “${result.tier}” and ` +
        `nothing here changed it.`;
    } else {
      status.textContent = `Access is now “${result.access}”. Tier is unchanged at “${result.tier}”.`;
    }
  } catch (error) {
    status.textContent = error.message;
  }
}

// --- Grants ------------------------------------------------------------------------------------
//
// Entitle a household by decision rather than by payment. **Nothing here writes `tier`**, and
// there is no control that could: App Store Server Notifications are its only writer, and a
// grant is a second, additive source of entitlement computed beside it.
//
// The search is over account metadata — email, display name, family id — and nothing else. No
// admin route can reach a child's name, an entry or a transcript, and `tests/test_admin.py`
// plants distinctive strings in an archive and greps every one of them for it.

/** Debounce, so typing an email is one request rather than one per keystroke. */
let grantSearchTimer = null;

/**
 * Which household search is the current one.
 *
 * **Two `loadHouseholds` calls can be in flight at once** — the debounced search and the repaint
 * `load()` runs after every write — and nothing orders their responses. Without this, a slow
 * earlier response lands last and repaints the picker with results for a query that is no longer
 * in the box, leaving a `<select>` whose selected option does not match what was searched for.
 * On this control the next click *grants* whatever is selected, so a stale repaint is a wrong
 * household, not a cosmetic flicker.
 *
 * A monotonic token rather than an AbortController: the request is cheap and already sent, and
 * what matters is only that a superseded response does not touch the DOM.
 */
let householdSearchToken = 0;

/**
 * Fill the household picker.
 *
 * **`keepSelection` is the whole subtlety, and it was found by driving the page.**
 *
 * The trial picker guards against a repaint quietly moving the selection: `replaceChildren`
 * leaves a `<select>` on its first option, so a household that dropped out of the list between
 * renders hands the next click a *different* family than the one that was on screen a moment
 * ago. That guard is right, and it is right here too — a grant is a write to a table nobody
 * re-reads.
 *
 * But it is wrong on a **search**, where changing the result set is the whole point of what the
 * user just did. The first version applied the guard to both and the symptom was immediate:
 * typing "tester" narrowed the list to exactly one household, blanked the box, and printed
 * "pick again" above a control with one thing in it. A guard that fires on every keystroke is a
 * guard somebody works around.
 *
 * So: a search selects the first result and says nothing; a repaint preserves the selection or
 * says it is gone. It is left off on a search and passed everywhere `load()` reaches this.
 */
async function loadHouseholds(query, { keepSelection = false } = {}) {
  const q = (query || "").trim();
  const token = ++householdSearchToken;
  const result = await api(`/admin/households?q=${encodeURIComponent(q)}`);
  // Superseded while this was in flight. Return before touching the DOM — including
  // `grant-state`, because "no household matches that" from an abandoned query is as wrong as a
  // stale option list.
  if (token !== householdSearchToken) return;
  const select = $("g-family");
  const previous = select.value;
  select.replaceChildren();
  for (const row of result.households) {
    const option = document.createElement("option");
    option.value = row.family_id;
    // The short family id for the same reason the trial picker carries one: two households whose
    // accounts share a display name produce two visually identical options, and picking the
    // wrong one grants the wrong household.
    option.textContent =
      `${row.label} · ${row.family_id.slice(0, 8)} — ${row.access}` +
      (row.grants ? ` · ${row.grants} grant${row.grants === 1 ? "" : "s"}` : "");
    select.append(option);
  }

  if (!result.households.length) {
    $("grant-state").textContent = q
      ? "No household matches that. Search an email, a display name, or a family id."
      : "No households yet — nothing to grant.";
    return;
  }

  if (keepSelection && previous) {
    if (result.households.some((row) => row.family_id === previous)) {
      select.value = previous;
    } else {
      select.selectedIndex = -1;
      $("grant-state").textContent =
        "The household you had selected is no longer in this list. Pick again.";
    }
    return;
  }
  // A search, or a first paint. The `<select>` is already on its first option; saying so keeps
  // `value` and what is rendered in agreement whatever the browser does with an empty list.
  select.selectedIndex = 0;
}

/**
 * The `Ends` column, which has to say three different things.
 *
 * **A revoked row gets the date without the countdown**, and that is the whole reason this is a
 * function. `deadline()` appends "in 38d" because it exists to stop a *live* future date reading
 * as "just now" — but on a grant somebody revoked in March it reads as a clock still running,
 * which is the same confident-wrong-answer failure one column to the left. Found by revoking one
 * and looking at the row.
 */
function grantEnds(row) {
  if (!row.expires_at) return "no end date";
  if (row.revoked_at) {
    // One millisecond back, for the reason `deadline` gives: the stored value is an exclusive
    // end, so the last day it covered is the day before the instant.
    return new Date(new Date(row.expires_at).getTime() - 1).toLocaleDateString("en-US", {
      month: "short",
      day: "numeric",
    });
  }
  return deadline(row.expires_at);
}

function grantChip(status) {
  if (status === "active") return "chip-ok";
  if (status === "revoked") return "chip-plain";
  return "chip-warn";
}

async function loadGrantLedger() {
  const result = await api("/admin/grants");
  $("grant-ledger").innerHTML = result.grants.length
    ? `<table><thead><tr>
         <th>Household</th><th>Reason</th><th>State</th><th>Ends</th>
         <th>Issued</th><th>By</th><th></th>
       </tr></thead><tbody>${result.grants
         .map(
           (row) => `<tr>
             <td>${escape(row.household)}<br /><span class="tile-note">${escape(
               row.family_id.slice(0, 8),
             )}</span></td>
             <td>${escape(row.reason)}</td>
             <td><span class="chip ${grantChip(row.status)}">${escape(row.status)}</span></td>
             <td>${escape(grantEnds(row))}</td>
             <td>${escape(when(row.granted_at))}</td>
             <td>${escape(row.granted_by || "account deleted")}</td>
             <td>${
               row.revoked_at
                 ? ""
                 : `<button class="btn btn-quiet g-revoke" data-grant="${escape(
                     row.id,
                   )}">Revoke</button>`
             }</td>
           </tr>`,
         )
         .join("")}</tbody></table>`
    : '<p class="chart-empty">No grants yet.</p>';
}

async function loadGrants() {
  // The ledger first: it is the half that still renders in read-only mode, so a failure to
  // populate the picker does not leave the card empty.
  await loadGrantLedger();
  await loadHouseholds($("g-search").value, { keepSelection: true });
}

async function issueGrant() {
  const familyId = $("g-family").value;
  const reason = $("g-reason").value.trim();
  const status = $("grant-state");
  if (!familyId) {
    status.textContent = "Pick a household first.";
    return;
  }
  if (!reason) {
    status.textContent = "A grant needs a reason — it is what the ledger is for.";
    return;
  }
  const date = $("g-date").value;
  try {
    const result = await api("/admin/grants", {
      method: "POST",
      // **No `granted_by` here and there is no field for it.** The server takes the issuer from
      // the bearer token; a body carrying one is ignored, and a test asserts that.
      body: JSON.stringify({
        family_id: familyId,
        reason,
        // `endOfDayIso` gives local midnight *after* the chosen day, so picking today leaves
        // the household entitled for the rest of today — the same rule the trial date follows,
        // and the same rule `deadline()` renders back.
        expires_at: date ? endOfDayIso(date) : null,
      }),
    });
    toast("Grant issued.");
    $("g-reason").value = "";
    $("g-date").value = "";
    // Repaint from the server rather than from what was sent, so the Access column, the picker
    // and the ledger all agree with the rows that actually exist. `load()` runs after, because
    // it resets this line — the trial lever learned that the hard way.
    await load();
    status.textContent =
      `${result.household} is entitled ` +
      (result.expires_at ? `until ${deadline(result.expires_at)}` : "with no end date") +
      ". The tier is unchanged — nothing here writes it.";
  } catch (error) {
    status.textContent = error.message;
  }
}

async function revokeGrant(grantId) {
  const status = $("grant-state");
  try {
    await api(`/admin/grants/${grantId}/revoke`, { method: "POST" });
    toast("Grant revoked.");
    await load();
    // **Say that it is immediate**, because the obvious worry after revoking something is
    // whether it has actually stopped. Every entitlement surface computes the answer per
    // request; there is no cached boolean and no job to wait for.
    status.textContent =
      "Revoked. It stops entitling on the next read — there is nothing to wait for. " +
      "The row stays in the ledger, which is the point of a ledger.";
  } catch (error) {
    status.textContent = error.message;
  }
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

// Two shapes, and using the wrong one is a bug you can see: a filter's blank option means
// "no filter" and needs a label saying so, while a value picker has no such state — every
// option is a real value. `fillSelect` was doing both, so the composer's palette list opened
// with a blank option *labelled* "cream" sitting above the real "cream". Picking the top one
// looked identical and saved `palette: ""`, which no renderer can draw.
function fillSelect(select, values, blank) {
  const current = select.value;
  select.replaceChildren();
  const first = document.createElement("option");
  first.value = "";
  first.textContent = blank;
  select.append(first);
  appendOptions(select, values);
  select.value = current;
}

/** A picker with no empty state. `fallback` is preselected, and is one of `values`. */
function fillChoices(select, values, fallback) {
  const current = select.value;
  select.replaceChildren();
  appendOptions(select, values);
  select.value = values.includes(current) ? current : fallback;
}

function appendOptions(select, values) {
  for (const value of values) {
    const option = document.createElement("option");
    option.value = value;
    option.textContent = value;
    select.append(option);
  }
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
  fillChoices($("g-kind"), GENERATABLE_KINDS, "question");
  // The server's full distinct theme list, not the themes surviving the table's filters. The
  // page above is capped and filtered; suggesting only what it happens to show would quietly
  // narrow the generator's vocabulary whenever a filter is set.
  fillDatalist($("g-themes"), state.library?.themes || []);
  refreshQueueCount();
}

// --- Prompt candidates ----------------------------------------------------------------------
//
// Generate, pick, queue. Three things here are deliberate and were each a defect in an earlier
// draft of this screen:
//
// 1. **A second batch appends rather than replaces.** `writeConcepts` replaces `state.concepts`
//    wholesale, which is right for concepts — you are choosing one. Here you are assembling a
//    set, and a generate that silently discarded the five you had just approved would be the
//    most expensive misclick on the screen.
// 2. **A rejected candidate can still be kept.** The filters are a spam trap, not an editor;
//    `ASSUMES_INCOME` fires on the bare word "buy". The reason is shown and the decision is the
//    reader's. The server re-checks only the two failures that are permanent and invisible —
//    a bare gendered pronoun and an unknown token — and refuses those whatever the console says.
// 3. **The waiting count has its own catch.** It shares no error surface with the form, because
//    a transient failure counting the queue must not report a generation that worked as failed.

//: The kinds `services/candidates.py` has a shape for. `measurement` is absent from both, and
//: absent here for that reason rather than by oversight.
const GENERATABLE_KINDS = ["question", "photo", "video", "audio", "activity", "letter"];

async function refreshQueueCount() {
  try {
    const page = await api("/admin/library?source=llm&active=false&limit=1");
    const waiting = page.total ?? 0;
    $("g-queue").textContent = waiting
      ? `${num(waiting)} candidate${waiting === 1 ? "" : "s"} waiting in the queue`
      : "Nothing waiting in the queue";
  } catch {
    // Deliberately silent. This is a nicety beside the form, and the form's own error line
    // belongs to the generate call.
    $("g-queue").textContent = "";
  }
}

function readGenerateForm() {
  return {
    kind: $("g-kind").value,
    theme: $("g-theme").value.trim() || null,
    count: Number($("g-count").value),
    min_age_months: Number($("g-min").value),
    max_age_months: Number($("g-max").value),
    guidance: $("g-guidance").value.trim() || null,
  };
}

async function writeCandidates(event) {
  event.preventDefault();
  const error = $("g-error");
  error.hidden = true;
  const button = event.target.querySelector("button[type=submit]");
  button.disabled = true;
  button.textContent = "Writing…";
  try {
    const result = await api("/prompts/generate", {
      method: "POST",
      body: JSON.stringify(readGenerateForm()),
    });
    // Append. See note 1 above.
    const known = new Set(state.candidates.map((c) => c.content_hash));
    const fresh = result.candidates.filter((c) => !known.has(c.content_hash));
    for (const candidate of fresh) {
      // Unpicked. Every candidate arrives needing a decision, including the ones that
      // passed every filter — 'pick which we like and don't' is the job, and a batch that
      // arrives pre-picked makes the default action 'queue all five without reading them'.
      state.candidates.push({ ...candidate, picked: false, model: result.model });
    }
    const dropped = result.candidates.length - fresh.length;
    $("g-summary").hidden = false;
    $("g-summary").textContent =
      `${result.accepted} of ${result.candidates.length} passed the filters` +
      (dropped ? `, ${dropped} already in this batch` : "") +
      ` · ${result.model}`;
    renderCandidates();
  } catch (err) {
    error.hidden = false;
    error.textContent = err.message;
  } finally {
    button.disabled = false;
    button.textContent = "Write candidates";
  }
}

function renderCandidates() {
  const mount = $("candidates");
  mount.replaceChildren();

  state.candidates.forEach((candidate, index) => {
    const card = document.createElement("article");
    card.className = "card candidate";
    card.dataset.picked = String(candidate.picked);
    card.dataset.verdict = candidate.accepted ? "accepted" : "rejected";

    // The skip leads, because it is why the card is still here. The filter reasons follow and
    // survive it, so an overridden rejection still shows what it was rejected for.
    const reasons = [...(candidate.skip ? [candidate.skip] : []), ...(candidate.reasons || [])]
      .map((reason) => `<span class="chip chip-warn">${escape(reason)}</span>`)
      .join("");

    card.innerHTML =
      `<p class="label">${escape(candidate.theme)} · ${escape(candidate.kind)} · ` +
      `${candidate.min_age_months}\u2013${candidate.max_age_months} months</p>
       <p class="candidate-body">${markTokens(candidate.body)}</p>
       <p class="candidate-why">${escape(candidate.rationale || "")}</p>
       <div class="candidate-meta">${reasons}</div>`;

    const actions = document.createElement("div");
    actions.className = "drawer-actions";
    const toggle = document.createElement("button");
    toggle.type = "button";
    toggle.className = candidate.picked ? "btn btn-primary" : "btn btn-quiet";
    toggle.textContent = candidate.picked ? "Picked" : "Pick";
    // A rejected candidate is pickable. See note 2 above.
    toggle.setAttribute(
      "aria-label",
      `${candidate.picked ? "Unpick" : "Pick"} "${candidate.body}"`,
    );
    toggle.addEventListener("click", () => {
      state.candidates[index].picked = !state.candidates[index].picked;
      renderCandidates();
    });
    const drop = document.createElement("button");
    drop.type = "button";
    drop.className = "btn btn-quiet";
    drop.textContent = "Discard";
    drop.setAttribute("aria-label", `Discard "${candidate.body}"`);
    drop.addEventListener("click", () => {
      state.candidates.splice(index, 1);
      renderCandidates();
    });
    actions.append(toggle, drop);
    card.append(actions);
    mount.append(card);
  });

  // The button always names the action it performs. It used to read "Nothing picked" when
  // disabled, which describes the state rather than the action and reads like a button that
  // does something — the hint beside it carries the state instead.
  const picked = state.candidates.filter((candidate) => candidate.picked).length;
  $("g-actions").hidden = state.candidates.length === 0;
  $("g-queue-picked").disabled = picked === 0;
  $("g-queue-picked").textContent = picked
    ? `Queue ${picked} candidate${picked === 1 ? "" : "s"}`
    : "Queue the picked ones";
  $("g-hint").hidden = picked !== 0;
  $("g-hint").textContent = `Pick the ones worth keeping — ${state.candidates.length} to read through.`;
}

async function queuePicked() {
  const picked = state.candidates.filter((candidate) => candidate.picked);
  if (!picked.length) return;
  const error = $("g-error");
  error.hidden = true;
  const button = $("g-queue-picked");
  button.disabled = true;
  button.textContent = "Queueing…";
  try {
    const result = await api("/prompts/candidates", {
      method: "POST",
      body: JSON.stringify({
        candidates: picked.map((candidate) => ({
          kind: candidate.kind,
          body: candidate.body,
          theme: candidate.theme,
          min_age_months: candidate.min_age_months,
          max_age_months: candidate.max_age_months,
          month_tags: candidate.month_tags || [],
          default_unlock_age: candidate.default_unlock_age ?? null,
        })),
      }),
    });
    // Only the ones that actually landed leave the batch. A skipped body stays on screen with
    // the reason attached, because "it collided with a row you already have" is something to
    // read rather than a silent no-op.
    const queued = new Set(result.inserted.map((prompt) => prompt.body));
    const skipped = new Map(result.skipped.map((row) => [row.body, row.reason]));
    state.candidates = state.candidates.filter((candidate) => !queued.has(candidate.body));
    for (const candidate of state.candidates) {
      if (skipped.has(candidate.body)) {
        candidate.picked = false;
        // Its own field rather than overwriting `reasons`. The filter verdict is the thing this
        // screen exists to show, and destroying it to say "duplicate" loses it for good — the
        // batch would have to be regenerated to see why the candidate was flagged.
        candidate.skip = skipped.get(candidate.body);
      }
    }
    renderCandidates();
    await loadLibrary();
    toast(
      `${result.inserted.length} queued, ${result.queued_total} waiting. ` +
        "Nothing is being served until you make one active.",
    );
  } catch (err) {
    error.hidden = false;
    error.textContent = err.message;
  } finally {
    button.disabled = false;
    renderCandidates();
  }
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
  fillChoices($("p-kind"), KINDS, "question");
  fillChoices($("p-cadence"), CADENCES, "daily");
  fillChoices($("p-completion"), COMPLETIONS, "text");
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
// Instagram posts from here since phase 104, and nothing else does — a post aimed at any other
// platform is still generate, review, download, put it out yourself.

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

  fillChoices($("c-platform"), state.platforms, "instagram");
  $("c-platform").value = "instagram";
  fillChoices($("m-template"), state.templates, "quote");
  fillChoices($("m-palette"), state.palettes, "cream");
  fillChoices($("m-platform"), state.platforms, "instagram");
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
  setProse(node, text);
  log.append(node);
  log.scrollTop = log.scrollHeight;
  return node;
}

// Claude answers in Markdown, and this panel's whole output is copy somebody is about to
// paste somewhere. Rendering it as a text node meant reading `**Absolution.**` and `> caption`
// with the punctuation still in — the reader doing the parsing, on the one screen whose job is
// to make copy easy to judge.
//
// **Built as DOM nodes, never `innerHTML`.** This is model output rendered in a console that
// holds a bearer token; the markup surface stays exactly zero, which also means nothing here
// depends on the CSP allowing anything it currently does not.
// `\*(?!\s)…(?<!\s)\*` rather than `\*[^*]+\*`: the loose form turns "3 * 4 * 5" into
// italics, which is the failure you only meet once somebody writes a number in a brief.
const INLINE = /(\*\*[^*]+\*\*|`[^`]+`|\*(?!\s)[^*]+(?<!\s)\*)/g;

function setProse(node, text) {
  node.replaceChildren();
  // Fences first, and before the blank-line split: a code block may contain a blank line, and
  // splitting on those would tear it in half. Odd trailing segment means an unclosed fence —
  // rendering it as code is friendlier than printing the backticks.
  String(text)
    .split("```")
    .forEach((segment, index) => {
      if (index % 2 === 1) {
        const pre = document.createElement("pre");
        const code = document.createElement("code");
        code.textContent = segment.replace(/^[\w-]*\n/, "").replace(/\n$/, "");
        pre.append(code);
        node.append(pre);
      } else {
        appendBlocks(node, segment);
      }
    });
  if (!node.childNodes.length) node.textContent = text;
}

function appendBlocks(node, text) {
  for (const block of String(text).split(/\n{2,}/)) {
    const line = block.trim();
    if (!line) continue;
    if (/^---+$/.test(line)) {
      node.append(document.createElement("hr"));
      continue;
    }
    const heading = line.match(/^(#{1,4})\s+(.*)$/);
    if (heading) {
      const el = document.createElement(`h${Math.min(heading[1].length + 2, 6)}`);
      el.className = "prose-h";
      appendInline(el, heading[2]);
      node.append(el);
      continue;
    }
    if (line.split("\n").every((l) => /^>\s?/.test(l))) {
      const quote = document.createElement("blockquote");
      appendInline(quote, line.replace(/^>\s?/gm, ""));
      node.append(quote);
      continue;
    }
    if (line.split("\n").every((l) => /^\s*([-*]|\d+\.)\s+/.test(l))) {
      const ordered = /^\s*\d+\./.test(line);
      const list = document.createElement(ordered ? "ol" : "ul");
      for (const item of line.split("\n")) {
        const li = document.createElement("li");
        appendInline(li, item.replace(/^\s*([-*]|\d+\.)\s+/, ""));
        list.append(li);
      }
      node.append(list);
      continue;
    }
    const para = document.createElement("p");
    appendInline(para, line);
    node.append(para);
  }
}

function appendInline(parent, text) {
  const lines = String(text).split("\n");
  lines.forEach((line, i) => {
    if (i) parent.append(document.createElement("br"));
    // `String.split` with one capturing group interleaves [text, capture, text, capture, …],
    // so **the odd indices are exactly the pieces `INLINE` matched**. Deciding from the index
    // rather than from the piece's first and last characters is what keeps the guards in the
    // pattern meaningful: `* b *` is refused by the lookahead, and inspecting characters would
    // have italicised it anyway on the way back out.
    line.split(INLINE).forEach((piece, index) => {
      if (!piece) return;
      if (index % 2 === 0) {
        parent.append(document.createTextNode(piece));
        return;
      }
      const tag = piece.startsWith("**") ? "strong" : piece.startsWith("`") ? "code" : "em";
      const el = document.createElement(tag);
      el.textContent = piece.slice(tag === "strong" ? 2 : 1, tag === "strong" ? -2 : -1);
      parent.append(el);
    });
  });
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
      // Plain text while it streams, on purpose: re-parsing Markdown on every chunk would
      // flicker through half-formed syntax — `**bol` is not bold yet — and would re-render the
      // whole answer a hundred times a second to show it.
      node.textContent = reply;
      $("chat-log").scrollTop = $("chat-log").scrollHeight;
    }
    setProse(node, reply);
    $("chat-log").scrollTop = $("chat-log").scrollHeight;
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
    // A card that opens the composer has to look like it does. It was `cursor: pointer` and
    // nothing else — no label, no focus ring, and unreachable from a keyboard.
    card.setAttribute("role", "button");
    card.setAttribute("tabindex", "0");
    card.setAttribute("aria-label", `Open "${concept.headline}" in the composer`);
    const open = () => openComposer(state.concepts[index]);
    card.addEventListener("click", open);
    card.addEventListener("keydown", (event) => {
      if (event.key === "Enter" || event.key === " ") {
        event.preventDefault();
        open();
      }
    });
    const hint = document.createElement("p");
    hint.className = "concept-open";
    hint.textContent = "Open in composer →";
    card.append(hint);
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
    // Same affordance rule as the concept cards: this reopens the composer, so it announces
    // itself and answers a keyboard.
    node.setAttribute("role", "button");
    node.setAttribute("tabindex", "0");
    node.setAttribute("aria-label", `Edit ${asset.status} post: ${asset.headline || "untitled"}`);
    const reopen = () => openComposer(null, asset);
    node.addEventListener("click", reopen);
    node.addEventListener("keydown", (event) => {
      if (event.key === "Enter" || event.key === " ") {
        event.preventDefault();
        reopen();
      }
    });
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

// A shot list was written to the database and read back by nothing. The Studio would call
// Claude, get seven shots and a caption track, save them — and then there was no screen in the
// console that could show them. Generating something nobody can read is the same defect as not
// generating it, so the treatment renders here, beside the post it belongs to.
function renderTreatment(source) {
  const shots = (source.shot_list || {}).shots || [];
  const track = source.caption_track || "";
  $("m-treatment").hidden = !shots.length && !track;
  // The treatment's own runtime, next to its title. Worth showing because the WebM button a
  // few lines below is hardcoded to four seconds and has nothing to do with this number — a
  // thirty-second treatment above a four-second export is the confusion this label heads off.
  const runtime =
    source.duration_seconds || shots.reduce((total, shot) => total + (shot.seconds || 0), 0);
  $("m-runtime").textContent = shots.length
    ? `· ${runtime}s across ${shots.length} shot${shots.length === 1 ? "" : "s"}`
    : "";
  const list = $("m-shots");
  list.replaceChildren();
  for (const shot of shots) {
    const item = document.createElement("li");
    item.className = "shot";

    const head = document.createElement("p");
    head.className = "shot-head";
    const seconds = document.createElement("span");
    seconds.className = "chip chip-plain";
    seconds.textContent = `${shot.seconds ?? "?"}s`;
    head.append(seconds);
    if (shot.on_screen_text) {
      const onScreen = document.createElement("span");
      onScreen.className = "shot-super";
      onScreen.textContent = shot.on_screen_text;
      head.append(onScreen);
    }
    item.append(head);

    if (shot.visual) {
      const visual = document.createElement("p");
      visual.className = "shot-visual";
      visual.textContent = shot.visual;
      item.append(visual);
    }
    if (shot.voiceover) {
      const voice = document.createElement("p");
      voice.className = "shot-voice";
      voice.textContent = shot.voiceover;
      item.append(voice);
    }
    list.append(item);
  }
  $("m-vtt").textContent = track;
  $("m-vtt").hidden = !track;

  // The render button lives with the shots because that is what it renders. It is hidden for a
  // post with no treatment: a card has nothing to turn into footage.
  const seconds = shots.reduce((total, shot) => total + (shot.seconds || 0), 0);
  $("m-render").hidden = !shots.length;
  $("m-render-note").textContent = shots.length
    ? `${shots.length} generations, about ${seconds}s of video. Each shot is generated ` +
      "separately and joined here — nothing renders thirty seconds in one call."
    : "";
  stopRenderPoll();
  $("m-render-state").hidden = true;
  // One button element is reused for every post, so its disabled state has to be reset here
  // or a render started on one post leaves it stuck for the next.
  $("m-render").disabled = false;
  if (state.composing?.id) pollRender(state.composing.id, { once: true });
}

// --- Rendering a treatment ------------------------------------------------------------------
//
// Seven generations and a concatenation take minutes, so the button gets a 202 and a row id
// and everything after that is polling. `shots_done` counts clips that actually landed in the
// bucket, so the bar is progress rather than an animation.

function stopRenderPoll() {
  if (state.renderPoll) {
    clearTimeout(state.renderPoll);
    state.renderPoll = null;
  }
  // Invalidates any poll already in flight: it will see a stale epoch when its fetch returns
  // and decline to reschedule.
  state.renderPollEpoch += 1;
}

function renderStateNode(render) {
  const box = $("m-render-state");
  box.hidden = false;
  box.dataset.state = render.status;
  box.replaceChildren();

  const line = document.createElement("p");
  line.className = "card-note";
  line.style.marginTop = "0";
  const done = render.shots_done ?? 0;
  const total = render.shots_total || 0;
  line.textContent =
    {
      queued: "Queued.",
      running: `Rendering shot ${Math.min(done + 1, total)} of ${total}.`,
      succeeded: `Done — ${total} shots joined into one file.`,
      failed: "Failed.",
      cancelled: "Cancelled.",
    }[render.status] || render.status;
  if (render.cost_cents) {
    // "so far" is only true while it is still spending.
    const live = render.status === "queued" || render.status === "running";
    line.textContent += ` ${money(render.cost_cents)} ${live ? "spent so far" : "spent"}.`;
  }
  box.append(line);

  if (render.status === "queued" || render.status === "running") {
    const bar = document.createElement("div");
    bar.className = "render-bar";
    const fill = document.createElement("span");
    // A width is a measurement, not a decoration — CSSOM, which the CSP permits, rather than a
    // `style=` attribute, which it drops.
    fill.style.width = `${total ? Math.round((done / total) * 100) : 0}%`;
    bar.append(fill);
    box.append(bar);
  }
  if (render.status === "succeeded" && render.render_key) {
    // Otherwise the one thing this feature pays money to produce is unreachable from the
    // console that produced it.
    const link = document.createElement("button");
    link.type = "button";
    link.className = "btn btn-quiet";
    link.textContent = "Open the film →";
    link.addEventListener("click", () => openRender(render.id));
    box.append(link);
  }
  if (render.error) {
    const why = document.createElement("p");
    why.className = "card-note";
    why.textContent = render.error;
    box.append(why);
  }
}

async function openRender(renderId) {
  try {
    const { url } = await api(`/social/renders/${renderId}/file`);
    window.open(url, "_blank", "noopener");
  } catch (error) {
    toast(error.message);
  }
}

async function pollRender(assetId, { once = false } = {}) {
  const epoch = state.renderPollEpoch;
  let payload;
  try {
    payload = await api(`/social/assets/${assetId}/video`);
  } catch {
    return; // a poll that fails is not worth a banner; the next one will say so
  }
  // The composer may have closed, or moved to another post, while that request was open.
  if (epoch !== state.renderPollEpoch || state.composing?.id !== assetId) return;

  const render = payload.render;
  if (!render) return;
  renderStateNode(render);
  const live = render.status === "queued" || render.status === "running";
  $("m-render").disabled = live;
  // `once` is the snapshot taken when the composer opens; it still resumes the loop if the
  // render is live, or the progress box would freeze at whatever it happened to catch.
  if (live) {
    state.renderPoll = setTimeout(() => pollRender(assetId), 4000);
  } else if (render.render_key) {
    loadAssets().catch(() => {});
  }
}

async function startRender() {
  const assetId = state.composing?.id;
  if (!assetId) {
    toast("Save this post first — a render is recorded against a saved post.");
    return;
  }
  $("m-render").disabled = true;
  try {
    const render = await api(`/social/assets/${assetId}/video`, { method: "POST" });
    renderStateNode(render);
    state.renderPoll = setTimeout(() => pollRender(assetId), 3000);
  } catch (error) {
    $("m-render").disabled = false;
    const box = $("m-render-state");
    box.hidden = false;
    box.dataset.state = "failed";
    box.replaceChildren();
    const why = document.createElement("p");
    why.className = "card-note";
    why.textContent = error.message;
    box.append(why);
  }
}

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
  renderTreatment(source);
  $("card-note").textContent = cards.canRecord()
    ? "WebM records the card settling in — an animated post, not generated footage."
    : "This browser cannot record WebM from a canvas. PNG still works.";
  $("composer").hidden = false;
  paintPreview();
  refreshPublish();
}

const closeComposer = () => {
  $("composer").hidden = true;
  state.composing = null;
  // Otherwise the poll keeps running against a post nobody is looking at, forever, and a
  // second open starts a second one beside it.
  stopRenderPoll();
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

async function saveComposer(event, { rethrow = false } = {}) {
  event?.preventDefault?.();
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
    // A submit shows the message and stops. A save that something else is waiting on has to
    // fail loudly, or the caller carries on with what it thinks it saved.
    if (rethrow) throw err;
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
    toast("Marked exported. For anywhere but Instagram, posting it is still your job.");
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

/* --- Publishing ---------------------------------------------------------------------------
 *
 * The console can put a card on Instagram. Three things about the shape of this code, all of
 * which are the design rather than the implementation:
 *
 * **The account is shared with the marketing repository**, which posts to the same feed on its
 * own schedule and cannot see this database. So "is it too soon to post" is a question for
 * Instagram, answered by `GET /social/account`, and it is shown before the button rather than
 * after the click.
 *
 * **Publishing is confirmed, and the confirmation shows the thing.** The handle it is going to
 * and the caption that will go out, because "publish" and "publish *this* to *there*" are
 * different promises and only the second one is what the button does.
 *
 * **The image is uploaded before the publish call.** Instagram does not accept an upload — it
 * fetches a URL — so the card the browser drew has to exist in the bucket first. It goes as
 * JPEG, which is the only format Meta will publish.
 */

/** The publish section's own state. Reset every time the composer opens. */
const publishState = { account: null, pending: null, generation: 0 };

function assetId() {
  return state.composing?.id || null;
}

/**
 * Instagram is the only platform with a publisher; the section hides for the others.
 *
 * **This list is `publishing.PUBLISHABLE` written a second time**, and a test asserts the two
 * match — the same guard `test_social.py` puts on `cards.js`'s platform sizes. Getting it from
 * the server instead would need the answer before the first request, which is the one moment
 * there is nothing to ask.
 */
function canPublish() {
  return ["instagram", "instagram_story"].includes($("m-platform").value);
}

async function refreshPublish() {
  const section = $("m-publish");
  hidePublishConfirm();
  // A concept that has never been saved has no id, so there is nothing to publish yet.
  section.hidden = !assetId() || !canPublish();
  if (section.hidden) return;

  // Open one composer, then another before the first request lands, and the slower response
  // paints the wrong post's queue underneath the right post's card. Only the newest caller
  // gets to write to the DOM.
  const generation = ++publishState.generation;
  const current = () => generation === publishState.generation;

  $("m-publish-account").textContent = "Checking the account…";
  $("m-publish-hold").hidden = true;
  await Promise.all([loadPublishAccount(current), loadPublications(current)]);
}

async function loadPublishAccount(current = () => true) {
  try {
    const account = await api("/social/account");
    if (!current()) return;
    publishState.account = account;
    if (!account.configured) {
      $("m-publish-account").textContent = account.setup;
      setPublishEnabled(false);
      return;
    }
    const last = account.last_post_at
      ? `last post ${new Date(account.last_post_at).toLocaleString()}`
      : "nothing posted yet";
    $("m-publish-account").textContent =
      `@${account.username} · ${account.media_count} posts · ${last} · ` +
      `${account.posts_in_last_24h} in the last 24h`;

    // Two different reasons the button might not work, and they are not the same sentence.
    if (!account.publish_enabled) {
      showHold("Publishing is switched off — SOCIAL_PUBLISH_ENABLED is false. Nothing here can post.");
      setPublishEnabled(false);
      return;
    }
    if (account.blocked_reason) {
      showHold(account.blocked_reason);
      setPublishEnabled(false, { scheduleStillAllowed: true });
      return;
    }
    setPublishEnabled(true);
  } catch (err) {
    if (!current()) return;
    $("m-publish-account").textContent = `Could not reach Instagram — ${err.message}`;
    setPublishEnabled(false);
  }
}

function showHold(message) {
  const hold = $("m-publish-hold");
  hold.hidden = false;
  hold.textContent = message;
}

/** Scheduling stays available when the only problem is that it is too soon to post *now*. */
function setPublishEnabled(enabled, { scheduleStillAllowed = false } = {}) {
  $("m-publish-now").disabled = !enabled;
  $("m-publish-schedule").disabled = !enabled && !scheduleStillAllowed;
}

async function loadPublications(current = () => true) {
  const mount = $("m-publications");
  mount.replaceChildren();
  const id = assetId();
  if (!id) return;
  let rows = [];
  try {
    ({ publications: rows } = await api(`/social/publications?asset_id=${id}`));
  } catch {
    return;
  }
  if (!current()) return;
  for (const row of rows) {
    const li = document.createElement("li");
    const chip = document.createElement("span");
    chip.className = `chip chip-${
      { published: "ok", failed: "warn", cancelled: "plain", scheduled: "peri" }[row.status] ||
      "plain"
    }`;
    chip.textContent = row.status;
    li.append(chip);

    const when = document.createElement("span");
    when.textContent = row.published_at
      ? new Date(row.published_at).toLocaleString()
      : row.scheduled_for
        ? `for ${new Date(row.scheduled_for).toLocaleString()}`
        : "as soon as it can";
    li.append(when);

    if (row.permalink) {
      const link = document.createElement("a");
      link.href = row.permalink;
      link.target = "_blank";
      link.rel = "noreferrer";
      link.textContent = "view";
      li.append(link);
    }
    if (row.error) {
      const why = document.createElement("span");
      why.className = "publication-error";
      why.textContent = row.error;
      li.append(why);
    }
    if (row.status === "scheduled") {
      const cancel = document.createElement("button");
      cancel.type = "button";
      cancel.className = "btn btn-quiet";
      cancel.textContent = "Cancel";
      cancel.addEventListener("click", () => cancelPublication(row.id));
      li.append(cancel);
    }
    mount.append(li);
  }
}

async function cancelPublication(id) {
  try {
    await api(`/social/publications/${id}/cancel`, { method: "POST" });
    toast("Taken out of the queue.");
    await refreshPublish();
  } catch (err) {
    showHold(err.message);
  }
}

/**
 * Put the card where Instagram can be pointed at it.
 *
 * The card goes to our own API rather than straight to the bucket. A presigned PUT was the
 * first version and a browser cannot use one here: the bucket is a different origin, so the
 * PUT needs a CORS policy on the bucket — and that bucket holds the archive. Confirmed in
 * Chrome rather than assumed: `TypeError: Failed to fetch`, no request leaving the browser.
 *
 * JPEG, because Instagram publishes nothing else and reports a PNG as an unreadable error.
 */
async function uploadCard() {
  const id = assetId();
  const blob = await cards.toJpegBlob(composerSpec(), $("m-platform").value);
  const stored = await api(`/social/assets/${id}/image`, {
    method: "POST",
    body: blob,
    headers: { "content-type": "image/jpeg" },
  });
  return stored.key;
}

/** Step one of two. Nothing has happened yet; this only shows what would. */
function askToPublish(scheduledFor) {
  const account = publishState.account;
  const when = scheduledFor
    ? `on ${new Date(scheduledFor).toLocaleString()}`
    : "right now";
  publishState.pending = { scheduledFor };
  $("m-publish-confirm-text").textContent =
    `This posts to @${account?.username ?? "the account"} ${when}. ` +
    "It goes out publicly and cannot be taken down from here.";
  $("m-publish-confirm-caption").textContent = captionPreview();
  $("m-publish-confirm").hidden = false;
  $("m-publish-go").focus();
}

/**
 * What the caption will look like once the server composes it.
 *
 * **This has to match `publishing._full_caption` exactly.** It is the same string built twice —
 * here to show you what you are about to post, there to actually post it — and a confirmation
 * that does not match the post is worse than no confirmation. The rule in both places: strip
 * whitespace, strip any leading hashes, add exactly one. `replace(/^#/, "")` removed only the
 * first of them while the server removed all, so `##vellum` disagreed.
 */
function captionPreview() {
  const tags = $("m-tags")
    .value.split(",")
    .map((tag) => tag.trim().replace(/^#+/, "").trim())
    .filter(Boolean)
    .map((tag) => `#${tag}`)
    .join(" ");
  const caption = $("m-caption").value.trim();
  return tags ? `${caption}\n\n${tags}` : caption;
}

function hidePublishConfirm() {
  publishState.pending = null;
  $("m-publish-confirm").hidden = true;
}

/** Step two of two. **This is the irreversible one.** */
async function confirmPublish() {
  const pending = publishState.pending;
  if (!pending) return;
  const button = $("m-publish-go");
  button.disabled = true;
  button.textContent = pending.scheduledFor ? "Queueing…" : "Posting…";
  try {
    // Save first: the caption about to go out is whatever is in the form, and the server
    // reads the row rather than the form.
    await saveComposer(null, { rethrow: true });
    await uploadCard();
    const body = pending.scheduledFor
      ? { scheduled_for: new Date(pending.scheduledFor).toISOString() }
      : {};
    const result = await api(`/social/assets/${assetId()}/publish`, {
      method: "POST",
      body: JSON.stringify(body),
    });
    hidePublishConfirm();
    toast(
      result.status === "published"
        ? `Posted. ${result.permalink || ""}`.trim()
        : "Queued. The scheduled runner will post it.",
    );
    await Promise.all([refreshPublish(), loadAssets()]);
  } catch (err) {
    hidePublishConfirm();
    showHold(err.message);
    // **A failure here does not always mean nothing happened.** The too-soon 409 leaves the
    // attempt queued and the hourly runner posts it later, so showing the message and leaving
    // a stale queue on screen would say "that did nothing" about something still pending.
    await loadPublications();
  } finally {
    button.disabled = false;
    button.textContent = "Yes — post it";
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
      // After `renderToday`, not before: it runs `fillHouseholds`, which writes to
      // `#trial-state`, and the grant panel's own status line has the same relationship to
      // its repaint. Awaited rather than fired and forgotten so `load()` still means "the
      // screen is painted" to everything that awaits it.
      await loadGrants();
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

$("trial-form").addEventListener("submit", (event) => {
  event.preventDefault();
  const value = $("t-date").value;
  if (!value) {
    $("trial-state").textContent = "Pick a date, or use Clear trial.";
    return;
  }
  writeTrial(endOfDayIso(value));
});
$("t-clear").addEventListener("click", () => writeTrial(null));

$("grant-form").addEventListener("submit", (event) => {
  event.preventDefault();
  issueGrant();
});

$("g-search").addEventListener("input", () => {
  clearTimeout(grantSearchTimer);
  grantSearchTimer = setTimeout(() => loadHouseholds($("g-search").value), 250);
});

// Delegated, because the ledger's rows are replaced wholesale on every repaint and a listener
// bound to a button would be bound to a button that no longer exists.
$("grant-ledger").addEventListener("click", (event) => {
  const button = event.target.closest(".g-revoke");
  if (button) revokeGrant(button.dataset.grant);
});
$("new-prompt").addEventListener("click", () => openDrawer(null));
$("prompt-form").addEventListener("submit", submitPrompt);
$("generate-form").addEventListener("submit", writeCandidates);
$("g-queue-picked").addEventListener("click", queuePicked);
$("g-clear").addEventListener("click", () => {
  state.candidates = [];
  $("g-summary").hidden = true;
  renderCandidates();
});
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
$("m-publish-now").addEventListener("click", () => askToPublish(null));
$("m-publish-schedule").addEventListener("click", () => {
  const when = $("m-publish-at").value;
  if (!when) {
    showHold("Pick a date and time first, or use Publish now.");
    return;
  }
  askToPublish(when);
});
$("m-publish-go").addEventListener("click", confirmPublish);
$("m-publish-cancel").addEventListener("click", hidePublishConfirm);
// The publish section only applies to platforms with a publisher, and the platform is a field
// somebody can change with the composer open.
$("m-platform").addEventListener("change", refreshPublish);
$("m-export").addEventListener("click", markExported);
$("m-render").addEventListener("click", startRender);
$("m-copy-vtt").addEventListener("click", async () => {
  // `toast`, not `banner`: banner is the red `role="alert"` strip with no dismissal timer, so
  // a success message there is an error-coloured alert pinned to the console until somebody
  // happens to load the Ops tab. Every other confirmation in this file uses `toast`.
  try {
    await navigator.clipboard.writeText($("m-vtt").textContent);
    toast("Caption track copied.");
  } catch {
    // Clipboard permission can be refused, and an unhandled rejection here would be silent.
    toast("Could not reach the clipboard — select the text and copy it.");
  }
});
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
