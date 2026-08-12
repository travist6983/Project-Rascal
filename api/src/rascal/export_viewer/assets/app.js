/*
 * The archive, read from disk.
 *
 * Constraints, all of which are about 2040 rather than about today:
 *
 *   - No network. Nothing in this file may cause a request off this machine.
 *   - No build step. What is in the repository is what ships.
 *   - No framework. A framework loaded from a CDN is a dead archive; a framework vendored
 *     into the zip is a maintenance burden for a page that renders a list.
 *   - No module syntax. `<script type="module">` is fetched under CORS rules a file://
 *     page cannot satisfy, which is the precise way this page would come up blank.
 *   - Nothing newer than ES2015/2017. No optional chaining, no `??`, no `Array#at`.
 *     Costs nothing, and removes the question of whether a browser is new enough.
 *
 * The DOM is built with createElement and textContent, never innerHTML. A body containing
 * `<script>` is a thing a parent might reasonably type, and it must render as those nine
 * characters.
 */
(function () {
  "use strict";

  var EXPECTED_FORMAT = "rascal-export";
  var SUPPORTED_VERSION = 1;

  var manifest = window.RASCAL_MANIFEST;
  var rawEntries = window.RASCAL_ENTRIES;

  var app = document.getElementById("app");

  // ---------------------------------------------------------------------------------
  // Small DOM helpers. Everything below builds nodes; nothing assigns markup.
  // ---------------------------------------------------------------------------------

  function el(tag, className, text) {
    var node = document.createElement(tag);
    if (className) { node.className = className; }
    if (text !== undefined && text !== null) { node.textContent = String(text); }
    return node;
  }

  function add(parent, child) { parent.appendChild(child); return child; }

  /** Text, with every occurrence of `needle` wrapped in a <mark>. Never markup. */
  function textWithMarks(parent, text, needle) {
    if (!needle) { parent.appendChild(document.createTextNode(text)); return parent; }
    var hay = text.toLowerCase();
    var find = needle.toLowerCase();
    var at = 0;
    var hit = hay.indexOf(find, at);
    while (hit !== -1) {
      if (hit > at) { parent.appendChild(document.createTextNode(text.slice(at, hit))); }
      parent.appendChild(el("mark", null, text.slice(hit, hit + find.length)));
      at = hit + find.length;
      hit = hay.indexOf(find, at);
    }
    parent.appendChild(document.createTextNode(text.slice(at)));
    return parent;
  }

  function fail(heading, detail) {
    app.textContent = "";
    var box = add(app, el("div", "bare"));
    add(box, el("h1", null, heading));
    add(box, el("p", null, detail));
    var where = add(box, el("p"));
    where.appendChild(document.createTextNode("The archive itself is fine and does not need this page. "));
    where.appendChild(el("code", null, "entries.json"));
    where.appendChild(document.createTextNode(" in this folder holds every entry as plain text, and the photos, video and audio are in "));
    where.appendChild(el("code", null, "media"));
    where.appendChild(document.createTextNode("."));
  }

  // ---------------------------------------------------------------------------------
  // The data has to be here before anything else is worth doing.
  // ---------------------------------------------------------------------------------

  if (!manifest || !rawEntries) {
    fail(
      "This page could not find the archive data.",
      "It expects entries.js and manifest.js in the same folder. If you copied index.html " +
        "out of the export on its own, copy the whole folder instead."
    );
    return;
  }

  var warnings = [];

  if (manifest.format !== EXPECTED_FORMAT) {
    warnings.push(
      'This archive says its format is "' + String(manifest.format) + '", and this page was ' +
        'written to read "' + EXPECTED_FORMAT + '". It is shown below anyway; some of it may ' +
        "be laid out wrongly."
    );
  } else if (!(manifest.format_version <= SUPPORTED_VERSION)) {
    warnings.push(
      "This archive is format version " + String(manifest.format_version) + ", and this page " +
        "reads version " + SUPPORTED_VERSION + ". Anything newer than this page understands " +
        "is still in entries.json — it just may not appear below."
    );
  }

  var child = manifest.child || {};
  var childName = child.name ? String(child.name) : "the archive";

  // ---------------------------------------------------------------------------------
  // Dates. Every one of them is rendered in the child's family timezone, because that is
  // the zone the archive was recorded against and occurred_at is serialized in UTC — an
  // evening entry formatted in the reader's own zone lands on the wrong day.
  // ---------------------------------------------------------------------------------

  var zone = child.family_timezone || null;
  if (zone) {
    try {
      new Intl.DateTimeFormat("en-US", { timeZone: zone }).format(new Date());
    } catch (err) {
      warnings.push(
        'This computer does not recognise the timezone "' + String(zone) + '", so dates below ' +
          "are shown in this computer's own timezone instead. A late-evening entry may appear " +
          "on the following day."
      );
      zone = null;
    }
  }

  function formatter(options) {
    var opts = {};
    for (var key in options) {
      if (Object.prototype.hasOwnProperty.call(options, key)) { opts[key] = options[key]; }
    }
    if (zone) { opts.timeZone = zone; }
    return new Intl.DateTimeFormat("en-US", opts);
  }

  var partsFmt = formatter({ year: "numeric", month: "numeric", day: "numeric" });
  var monthFmt = formatter({ month: "long" });
  var weekdayFmt = formatter({ weekday: "short" });
  var timeFmt = formatter({ hour: "numeric", minute: "2-digit" });
  var fullFmt = formatter({
    weekday: "long", year: "numeric", month: "long", day: "numeric",
    hour: "numeric", minute: "2-digit"
  });

  /** {y, m, d} for a Date, in the archive's timezone. formatToParts, so no locale guessing. */
  function ymd(date) {
    var parts = partsFmt.formatToParts(date);
    var out = { y: 0, m: 0, d: 0 };
    for (var i = 0; i < parts.length; i++) {
      if (parts[i].type === "year") { out.y = parseInt(parts[i].value, 10); }
      else if (parts[i].type === "month") { out.m = parseInt(parts[i].value, 10); }
      else if (parts[i].type === "day") { out.d = parseInt(parts[i].value, 10); }
    }
    return out;
  }

  function dayKey(p) {
    return p.y + "-" + (p.m < 10 ? "0" : "") + p.m + "-" + (p.d < 10 ? "0" : "") + p.d;
  }

  // birthdate is "YYYY-MM-DD". Parsed by hand: `new Date("2021-06-01")` is UTC midnight and
  // shifts a day west of Greenwich, which would make a birthday-eve entry read a year young.
  var birth = null;
  if (typeof child.birthdate === "string") {
    var bits = child.birthdate.split("-");
    if (bits.length === 3) {
      var by = parseInt(bits[0], 10), bm = parseInt(bits[1], 10), bd = parseInt(bits[2], 10);
      if (by > 0 && bm > 0 && bd > 0) { birth = { y: by, m: bm, d: bd }; }
    }
  }

  /** Whole years and leftover months between the birthdate and a {y,m,d}. Null if unknown. */
  function ageAt(p) {
    if (!birth) { return null; }
    var months = (p.y - birth.y) * 12 + (p.m - birth.m);
    if (p.d < birth.d) { months -= 1; }
    if (months < 0) { return null; }
    return { years: Math.floor(months / 12), months: months % 12 };
  }

  function ageLabel(age) {
    if (!age) { return null; }
    return age.years + "y " + age.months + "m";
  }

  var todayAge = ageAt(ymd(new Date()));

  function duration(seconds) {
    if (typeof seconds !== "number" || seconds < 0) { return null; }
    var mins = Math.floor(seconds / 60);
    var secs = Math.floor(seconds % 60);
    return mins + ":" + (secs < 10 ? "0" : "") + secs;
  }

  // ---------------------------------------------------------------------------------
  // View models. Built once, so search is a scan over strings already lowercased.
  // ---------------------------------------------------------------------------------

  var TYPE_LABEL = {
    photo: "Photo", video: "Video", audio: "Voice", text: "Written", did_it: "Did it"
  };

  function typeLabel(entryType) {
    if (Object.prototype.hasOwnProperty.call(TYPE_LABEL, entryType)) {
      return TYPE_LABEL[entryType];
    }
    // An entry type from a server release this page has never heard of still gets a chip.
    return entryType ? String(entryType) : "Entry";
  }

  function promptKindClass(entry) {
    var kind = entry.prompt && entry.prompt.kind ? entry.prompt.kind : "";
    if (kind === "question" || kind === "audio") { return "k-question"; }
    if (kind === "activity") { return "k-activity"; }
    return "k-photo";
  }

  function build(raw) {
    var when = new Date(raw.occurred_at);
    var valid = !isNaN(when.getTime());
    var parts = valid ? ymd(when) : { y: 0, m: 0, d: 0 };

    var hay = [];
    function push(value) { if (value) { hay.push(String(value).toLowerCase()); } }
    push(raw.title);
    push(raw.body);
    if (raw.prompt) { push(raw.prompt.body); push(raw.prompt.theme); }
    var tags = raw.tags || [];
    for (var t = 0; t < tags.length; t++) { push(tags[t].name); }
    var media = raw.media || [];
    for (var m = 0; m < media.length; m++) {
      push(media[m].transcript);
      push(media[m].caption);
    }

    return {
      raw: raw,
      id: String(raw.id),
      when: when,
      valid: valid,
      parts: parts,
      key: valid ? dayKey(parts) : "unknown",
      sort: valid ? when.getTime() : -Infinity,
      deleted: raw.is_deleted === true || !!raw.deleted_at,
      hay: hay.join("\n")
    };
  }

  var entries = [];
  for (var i = 0; i < rawEntries.length; i++) { entries.push(build(rawEntries[i])); }
  entries.sort(function (a, b) {
    if (b.sort !== a.sort) { return b.sort - a.sort; }
    return a.id < b.id ? 1 : -1;
  });

  // ---------------------------------------------------------------------------------
  // Sealed letters.
  //
  // The bodies are in entries.json in the clear, three inches from this file, and they
  // stay that way — an export you cannot read is not a backup. So the seal here is an
  // honesty affordance and not security: it says this was meant for later, and then it
  // opens when you ask it to.
  // ---------------------------------------------------------------------------------

  function sealState(entry) {
    var age = entry.raw.unlock_at_age;
    if (typeof age !== "number") { return null; }
    if (!todayAge) { return { sealed: true, unlock: age, unknownAge: true }; }
    return { sealed: todayAge.years < age, unlock: age, unknownAge: false };
  }

  var revealed = {};

  // ---------------------------------------------------------------------------------
  // Media.
  // ---------------------------------------------------------------------------------

  function noun(kind) {
    if (kind === "photo") { return "photo"; }
    if (kind === "video") { return "video"; }
    return "recording";
  }

  /**
   * The metadata for a file that is not here, and a sentence saying which kind of not-here.
   *
   * `export` means the export itself recorded that the bytes were missing — the row has a
   * null path and the manifest names it. `folder` means the archive says the file is here
   * and it is not, which is what happens when somebody unzips it and moves things around.
   * Either way it renders as words, never as a broken image icon: the icon reads as "this
   * archive is damaged", and neither of these is that.
   */
  function absentBlock(item, why) {
    var box = el("div", "absent");
    add(box, el(
      "p", null,
      why === "folder"
        ? "This " + noun(item.kind) + " is listed in the archive, but its file is not in " +
          "this folder. If the archive was unzipped, check that the whole media folder came " +
          "with it. Everything the archive knows about it is below."
        : "This " + noun(item.kind) + " is not in this archive — its file was missing when " +
          "the export was made. Everything the archive knows about it is below."
    ));
    var facts = [];
    if (typeof item.bytes === "number") { facts.push(item.bytes + " bytes"); }
    if (item.captured_at) { facts.push("captured " + item.captured_at); }
    if (item.upload_status) { facts.push("upload " + item.upload_status); }
    if (facts.length) { add(box, el("p", null, facts.join(" · "))); }
    if (item.s3_key) { add(box, el("p", "absent-key", String(item.s3_key))); }
    return box;
  }

  function transcriptBlock(item, query) {
    if (!item.transcript && !item.caption) { return null; }
    var wrap = el("div");
    if (item.caption) {
      var cap = el("p", "transcript");
      add(cap, el("span", "transcript-label", "Caption"));
      textWithMarks(cap, String(item.caption), query);
      add(wrap, cap);
    }
    if (item.transcript) {
      var tr = el("p", "transcript");
      add(tr, el("span", "transcript-label", "Transcript"));
      textWithMarks(tr, String(item.transcript), query);
      add(wrap, tr);
    }
    return wrap;
  }

  /**
   * Swap a player for its metadata if the file will not load.
   *
   * The export writes a path only for bytes it actually put in the zip, so a path that
   * fails here means the folder changed after the export — a partial unzip, a move, a
   * sync that dropped the big files. The archive should say that rather than leave a
   * broken-image icon that reads as data loss.
   */
  function degradeOnError(node, item) {
    node.addEventListener("error", function () {
      var parent = node.parentNode;
      if (parent) { parent.replaceChild(absentBlock(item, "folder"), node); }
    });
    return node;
  }

  function playerFor(item) {
    if (item.kind === "video") {
      var video = el("video");
      video.setAttribute("controls", "");
      video.setAttribute("preload", "metadata");
      video.setAttribute("playsinline", "");
      video.src = item.path;
      return degradeOnError(video, item);
    }
    var img = el("img");
    img.src = item.path;
    img.alt = item.caption ? String(item.caption) : "";
    img.setAttribute("loading", "lazy");
    return degradeOnError(img, item);
  }

  /** Everything visual for one entry's media, card or detail. */
  function mediaBlock(entry, opts) {
    var full = opts && opts.full;
    var query = (opts && opts.query) || "";
    var showDeleted = opts && opts.showDeleted;

    var items = [];
    var raws = entry.raw.media || [];
    for (var n = 0; n < raws.length; n++) {
      var row = raws[n];
      var gone = row.is_deleted === true || !!row.deleted_at;
      if (gone && !showDeleted) { continue; }
      items.push(row);
    }
    if (!items.length) { return null; }

    var box = el("div");

    // Voice and video get their own block each, because each carries a transcript under it.
    var visual = [];
    for (var v = 0; v < items.length; v++) {
      var item = items[v];
      if (!item.path) {
        add(box, absentBlock(item, "export"));
        var absentText = transcriptBlock(item, query);
        if (absentText) { add(box, absentText); }
      } else if (item.kind === "audio") {
        var band = el("div", "voice");
        var meta = ["Voice"];
        var dur = duration(item.duration_seconds);
        if (dur) { meta.push(dur); }
        add(band, el("p", "voice-meta", meta.join(" · ")));
        var audio = el("audio");
        audio.setAttribute("controls", "");
        audio.setAttribute("preload", "metadata");
        audio.src = item.path;
        add(band, degradeOnError(audio, item));
        var voiceText = transcriptBlock(item, query);
        if (voiceText) { add(band, voiceText); }
        add(box, band);
      } else {
        visual.push(item);
      }
    }

    if (visual.length) {
      // The card shows at most four tiles and counts the rest, so nine photos and four
      // photos produce the same card height. The detail view shows every one.
      var shown = full ? visual : visual.slice(0, 4);
      var grid = el("div", "media-grid n-" + Math.min(shown.length, 4));
      for (var g = 0; g < shown.length; g++) { add(grid, playerFor(shown[g])); }
      add(box, grid);

      if (!full && visual.length > shown.length) {
        var more = el("div", "chips");
        add(more, el("span", "chip", "+" + (visual.length - shown.length) + " more"));
        add(box, more);
      }
      if (full) {
        for (var f = 0; f < shown.length; f++) {
          var extra = transcriptBlock(shown[f], query);
          if (extra) { add(box, extra); }
        }
      }
    }

    return box.childNodes.length ? box : null;
  }

  // ---------------------------------------------------------------------------------
  // Chips.
  // ---------------------------------------------------------------------------------

  function chipRow(entry, showDeleted) {
    var row = el("div", "chips");
    var raw = entry.raw;

    add(row, el("span", "chip t-" + String(raw.entry_type), typeLabel(raw.entry_type)));

    var seal = sealState(entry);
    if (seal) {
      add(row, el("span", "chip t-sealed", "Letter · opens at " + seal.unlock));
    }
    if (entry.deleted) {
      add(row, el("span", "chip t-removed", "Removed"));
    }

    var tags = raw.tags || [];
    for (var t = 0; t < tags.length; t++) {
      var gone = !!tags[t].deleted_at;
      if (gone && !showDeleted) { continue; }
      add(row, el("span", "chip" + (gone ? " t-removed" : ""), tags[t].name));
    }
    return row;
  }

  // ---------------------------------------------------------------------------------
  // The card.
  // ---------------------------------------------------------------------------------

  function cardFor(entry, state) {
    var raw = entry.raw;
    var seal = sealState(entry);
    var open = !seal || !seal.sealed || revealed[entry.id];

    // A div and not a button, on purpose. A card contains `<audio controls>` and
    // `<video controls>`, and interactive content inside a button is invalid — today it
    // renders anyway, and in fifteen years it is exactly the kind of thing a browser
    // tightens up and turns into a play button that cannot be pressed.
    var card = el("div", "card");
    card.setAttribute("role", "link");
    card.setAttribute("tabindex", "0");
    card.setAttribute(
      "aria-label",
      (raw.title ? String(raw.title) + " — " : "") +
        (entry.valid ? fullFmt.format(entry.when) : "undated entry")
    );
    if (raw.entry_type === "did_it") { card.className += " is-didit"; }
    if (seal && seal.sealed) { card.className += " is-sealed"; }
    if (entry.deleted) { card.className += " is-deleted"; }
    card.setAttribute("data-entry", entry.id);

    if (open) {
      var media = mediaBlock(entry, { query: state.query, showDeleted: state.showDeleted });
      if (media) { add(card, media); }

      if (raw.prompt && raw.prompt.body) {
        var quote = el("p", "quote " + promptKindClass(entry));
        textWithMarks(quote, String(raw.prompt.body), state.query);
        add(card, quote);
      }

      if (raw.title) {
        var title = el("p", "card-title");
        textWithMarks(title, String(raw.title), state.query);
        add(card, title);
      }

      if (raw.body) {
        var body = el("p", "card-body is-clamped");
        textWithMarks(body, String(raw.body), state.query);
        add(card, body);
      }

      // A did-it entry has no artifact and no words, and it is a complete entry. It gets
      // the prompt it answered and a plain sentence — never an empty frame.
      if (!raw.body && !raw.title && raw.entry_type === "did_it") {
        add(card, el("p", "card-body", "Did it."));
      }

      if (seal && !seal.sealed) {
        add(card, el(
          "p", "opened-note",
          seal.unknownAge
            ? "Written as a sealed letter."
            : "This was sealed until " + seal.unlock + ". It is open now."
        ));
      }
    } else {
      var sealBox = el("div", "seal");
      add(sealBox, el("p", "seal-mark", "✉"));
      add(sealBox, el("p", "seal-title", raw.title ? String(raw.title) : "A sealed letter"));
      add(sealBox, el(
        "p", "seal-note",
        seal.unknownAge
          ? "Meant to be opened at " + seal.unlock + "."
          : "Written for you to read at " + seal.unlock + ". You are " +
            todayAge.years + "."
      ));
      var reveal = el("button", "seal-open", "It is yours — read it now");
      reveal.type = "button";
      reveal.setAttribute("data-reveal", entry.id);
      add(sealBox, reveal);
      add(card, sealBox);
    }

    add(card, chipRow(entry, state.showDeleted));
    return card;
  }

  // ---------------------------------------------------------------------------------
  // The timeline.
  // ---------------------------------------------------------------------------------

  function matching(state) {
    var out = [];
    var q = state.query.toLowerCase();
    for (var n = 0; n < entries.length; n++) {
      var entry = entries[n];
      if (entry.deleted && !state.showDeleted) { continue; }
      if (q && entry.hay.indexOf(q) === -1) { continue; }
      out.push(entry);
    }
    return out;
  }

  function dayHeader(entry) {
    var header = el("div", "day-header");
    if (!entry.valid) {
      add(header, el("span", "day-month", "Undated"));
      return header;
    }
    add(header, el("span", "day-num", String(entry.parts.d)));
    add(header, el("span", "day-month", monthFmt.format(entry.when) + " " + entry.parts.y));
    add(header, el("span", "day-weekday", weekdayFmt.format(entry.when)));
    var label = ageLabel(ageAt(entry.parts));
    if (label) { add(header, el("span", "day-age", label)); }
    return header;
  }

  function renderTimeline(state) {
    var list = matching(state);
    var frag = document.createDocumentFragment();

    if (state.query) {
      add(frag, el(
        "p", "result-note",
        list.length + (list.length === 1 ? " entry matches " : " entries match ") + '"' + state.query + '"'
      ));
    }

    if (!list.length) {
      add(frag, el("p", "empty", state.query
        ? "Nothing in the archive matches that."
        : "This archive has no entries in it."));
      return frag;
    }

    var lastDay = null;
    var lastYear = null;
    for (var n = 0; n < list.length; n++) {
      var entry = list[n];
      if (entry.valid && entry.parts.y !== lastYear) {
        add(frag, el("div", "year-rule", String(entry.parts.y)));
        lastYear = entry.parts.y;
      }
      if (entry.key !== lastDay) {
        add(frag, dayHeader(entry));
        lastDay = entry.key;
      }
      add(frag, cardFor(entry, state));
    }

    add(frag, colophon(list.length));
    return frag;
  }

  function colophon(shown) {
    var box = el("div", "colophon");
    var counts = manifest.counts || {};
    var line = [];
    if (typeof counts.entries === "number") { line.push(counts.entries + " entries"); }
    if (typeof counts.media === "number") { line.push(counts.media + " photos, videos and recordings"); }
    if (shown !== counts.entries) { line.push(shown + " shown"); }
    add(box, el("p", null, line.join(" · ")));

    var made = el("p");
    made.appendChild(document.createTextNode("Exported "));
    made.appendChild(document.createTextNode(
      manifest.generated_at ? String(manifest.generated_at).slice(0, 10) : "at an unrecorded time"
    ));
    made.appendChild(document.createTextNode(". The data behind this page is in "));
    made.appendChild(el("code", null, "entries.json"));
    made.appendChild(document.createTextNode(" and "));
    made.appendChild(el("code", null, "manifest.json"));
    made.appendChild(document.createTextNode(
      ", in this folder, as plain text. Nothing here needs the internet or any particular program."
    ));
    add(box, made);

    var missing = manifest.missing_media || [];
    if (missing.length) {
      add(box, el("p", null,
        missing.length + (missing.length === 1 ? " file was" : " files were") +
        " missing when this export was made. The entries they belong to are still here, and say so."
      ));
    }
    return box;
  }

  // ---------------------------------------------------------------------------------
  // One entry, on its own, at #entry/<id>.
  // ---------------------------------------------------------------------------------

  function findEntry(id) {
    for (var n = 0; n < entries.length; n++) {
      if (entries[n].id === id) { return entries[n]; }
    }
    return null;
  }

  function renderDetail(entry, state) {
    var raw = entry.raw;
    var seal = sealState(entry);
    var open = !seal || !seal.sealed || revealed[entry.id];

    var frag = document.createDocumentFragment();

    var back = el("a", "back", "← Back to the timeline");
    back.href = "#";
    add(frag, back);

    var wrap = el("div", "detail");

    if (raw.title) { add(wrap, el("h2", "detail-title", String(raw.title))); }

    var dateLine = entry.valid ? fullFmt.format(entry.when) : "Undated";
    var age = ageLabel(ageAt(entry.parts));
    if (age && entry.valid) { dateLine += " · " + age; }
    add(wrap, el("p", "detail-date", dateLine));

    if (raw.prompt && raw.prompt.body) {
      var quote = el("div", "quote-block " + promptKindClass(entry));
      add(quote, el("span", "quote-label", "The prompt"));
      quote.appendChild(document.createTextNode(String(raw.prompt.body)));
      add(wrap, quote);
    }

    if (open) {
      var media = mediaBlock(entry, { full: true, query: "", showDeleted: state.showDeleted });
      if (media) { add(wrap, media); }

      if (raw.body) {
        var body = el("p", "detail-body");
        body.style.marginTop = "1rem";
        body.textContent = String(raw.body);
        add(wrap, body);
      } else if (raw.entry_type === "did_it") {
        add(wrap, el("p", "detail-body", "Did it."));
      }

      if (seal && !seal.sealed) {
        add(wrap, el("p", "opened-note",
          seal.unknownAge
            ? "Written as a sealed letter."
            : "This was sealed until " + seal.unlock + ". It is open now."));
      }
    } else {
      var sealBox = el("div", "seal");
      add(sealBox, el("p", "seal-mark", "✉"));
      add(sealBox, el("p", "seal-title", "Sealed"));
      add(sealBox, el("p", "seal-note",
        "This was written for you to read at " + seal.unlock +
        ". It is not locked and it never was — it is your letter, and you can read it now."));
      var reveal = el("button", "seal-open", "Read it now");
      reveal.type = "button";
      reveal.setAttribute("data-reveal", entry.id);
      add(sealBox, reveal);
      add(wrap, sealBox);
    }

    add(wrap, chipRow(entry, state.showDeleted));

    // The two dates, never conflated. occurred_at is when it happened; created_at is when
    // somebody sat down and wrote it in, which for a backdated entry is a different day.
    var facts = el("div", "detail-facts");
    var dl = el("dl");
    function fact(term, value) {
      if (!value) { return; }
      add(dl, el("dt", null, term));
      add(dl, el("dd", null, value));
    }
    fact("Happened", entry.valid ? fullFmt.format(entry.when) : String(raw.occurred_at));
    fact("Logged", raw.created_at ? fullFmt.format(new Date(raw.created_at)) : null);
    if (entry.deleted) {
      fact("Removed", raw.deleted_at ? fullFmt.format(new Date(raw.deleted_at)) : "yes");
    }
    fact("Kind", typeLabel(raw.entry_type));
    if (raw.prompt && raw.prompt.theme) { fact("Theme", String(raw.prompt.theme)); }
    fact("Entry id", entry.id);
    add(facts, dl);
    add(wrap, facts);

    add(frag, wrap);
    return frag;
  }

  // ---------------------------------------------------------------------------------
  // Shell and routing.
  // ---------------------------------------------------------------------------------

  var state = { query: "", showDeleted: false };
  var listNode = null;
  var searchInput = null;
  var timelineScroll = 0;

  function buildShell() {
    app.textContent = "";

    var head = add(app, el("header", "masthead"));
    var inner = add(head, el("div", "masthead-inner"));
    add(inner, el("p", "eyebrow", "Rascal archive"));
    var h1 = add(inner, el("h1"));
    h1.appendChild(document.createTextNode(childName));

    var bits = [];
    var counts = manifest.counts || {};
    if (typeof counts.entries === "number") {
      bits.push(counts.entries + (counts.entries === 1 ? " entry" : " entries"));
    }
    if (entries.length) {
      var newest = entries[0];
      var oldest = entries[entries.length - 1];
      if (newest.valid && oldest.valid) {
        bits.push(oldest.parts.y === newest.parts.y
          ? String(newest.parts.y)
          : oldest.parts.y + "–" + newest.parts.y);
      }
    }
    // Second person and no pronoun. The manifest does not carry the child's pronouns, and
    // this page is read by the person it is about — see the standing rule about not writing
    // new copy that assumes a child's gender.
    if (todayAge) { bits.push("you are " + todayAge.years + " today"); }
    add(inner, el("p", "masthead-meta", bits.join(" · ")));

    var controls = add(inner, el("div", "controls"));
    searchInput = el("input", "search");
    searchInput.type = "search";
    searchInput.placeholder = "Search everything — words, prompts, tags, transcripts";
    searchInput.setAttribute("aria-label", "Search the archive");
    searchInput.value = state.query;
    add(controls, searchInput);

    var toggle = el("label", "toggle");
    var box = el("input");
    box.type = "checkbox";
    box.checked = state.showDeleted;
    add(toggle, box);
    toggle.appendChild(document.createTextNode("Show removed"));
    add(controls, toggle);

    for (var w = 0; w < warnings.length; w++) {
      add(inner, el("div", "banner", warnings[w]));
    }

    var wrap = add(app, el("main", "wrap"));
    listNode = add(wrap, el("div"));

    searchInput.addEventListener("input", function () {
      state.query = searchInput.value.trim();
      if (location.hash && location.hash !== "#") { location.hash = ""; }
      else { route(); }
    });
    box.addEventListener("change", function () {
      state.showDeleted = box.checked;
      route();
    });
  }

  function route() {
    var hash = location.hash || "";
    var id = null;
    if (hash.indexOf("#entry/") === 0) { id = decodeURIComponent(hash.slice(7)); }

    listNode.textContent = "";

    if (id) {
      var entry = findEntry(id);
      if (entry) {
        listNode.appendChild(renderDetail(entry, state));
        window.scrollTo(0, 0);
        return;
      }
      listNode.appendChild(el("p", "empty", "No entry in this archive has that id."));
      return;
    }

    listNode.appendChild(renderTimeline(state));
    window.scrollTo(0, timelineScroll);
    timelineScroll = 0;
  }

  // One listener for the whole list, so a rerender never leaves handlers behind.
  //
  // The walk goes upward from whatever was clicked, and it stops at the first thing that
  // owns the click itself. That is what keeps pressing play on a recording from also
  // opening the entry it sits in — the <audio> is reached before the card is.
  var OWNS_ITS_CLICK = { AUDIO: true, VIDEO: true, A: true, INPUT: true, LABEL: true };

  function activate(event) {
    var node = event.target;
    while (node && node !== app) {
      var tag = node.tagName ? node.tagName.toUpperCase() : "";
      if (Object.prototype.hasOwnProperty.call(OWNS_ITS_CLICK, tag)) { return; }
      if (node.getAttribute) {
        var reveal = node.getAttribute("data-reveal");
        if (reveal) {
          event.preventDefault();
          revealed[reveal] = true;
          route();
          return;
        }
        var entryId = node.getAttribute("data-entry");
        if (entryId) {
          event.preventDefault();
          timelineScroll = window.pageYOffset || 0;
          location.hash = "#entry/" + encodeURIComponent(entryId);
          return;
        }
      }
      node = node.parentNode;
    }
  }

  app.addEventListener("click", activate);

  // A card is not a button, so Enter and Space have to be wired by hand.
  app.addEventListener("keydown", function (event) {
    if (event.key !== "Enter" && event.key !== " " && event.key !== "Spacebar") { return; }
    var node = event.target;
    if (node && node.tagName && node.tagName.toUpperCase() === "BUTTON") { return; }
    if (node && node.getAttribute && (node.getAttribute("data-entry") || node.getAttribute("data-reveal"))) {
      event.preventDefault();
      activate(event);
    }
  });

  window.addEventListener("hashchange", route);

  try {
    document.title = childName + " — Rascal archive";
    buildShell();
    route();
  } catch (err) {
    fail(
      "This page could not lay out the archive.",
      "Something went wrong reading it: " + (err && err.message ? err.message : String(err))
    );
  }
})();
