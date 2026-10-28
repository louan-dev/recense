// Prosogram adapter for Gallery's /main player.
//
// It satisfies the host contract at the top of prosogram.js without touching gallery.js: the playback clock comes from
// the media element itself, the data from the same endpoints the player uses, and the figure is drawn on this module's
// own canvas in its own container beside the player. Everything app-specific lives here, so when the C0/D1 session
// lands a real hook in gallery.js this file switches to it and nothing else changes.
//
// Time bases (the thing that silently breaks if you get it wrong):
//   · transcript word times are ALREADY shifted into this file's time by the Worker (corrections.js `present`),
//     so they compare directly against media.currentTime.
//   · features frames are in the TRANSCRIPT's time, and the response carries `shift` unapplied.
//     So frame index = (fileTime - shift) / HOP.
//
// Known limit, worth stating: on a line a human rewrote (`fixed`), the Worker sends the corrected `text` but the
// ORIGINAL `words` array (corrections.js `present`). Prosody therefore analyses the pre-correction words on those
// lines. Unfixed lines — the great majority — are exact.
(() => {
  "use strict";

  // ---- the only DOM coupling to Gallery, kept in one place ------------------------------------------------------
  const ANCHOR = ".p-ctrl";          // the player's control block; the panel is inserted as its sibling
  const STAGE = "#stage";            // the viewer's stage
  const MBOX = ".mbox";              // the media's wrapper; it carries an OPEN shadow root
  const MEDIA = "video, audio";
  const PANEL = "p-proso";

  // The media element usually lives inside .mbox's shadow root, so document.querySelector cannot reach it — this
  // mirrors the player's own stageMedia() (gallery.js:56), including its no-attachShadow fallback. Getting this wrong
  // is silent: the panel simply never appears.
  function findMedia() {
    const stage = document.querySelector(STAGE) || document;
    const box = stage.querySelector ? stage.querySelector(MBOX) : null;
    const root = box && box.shadowRoot ? box.shadowRoot : stage;
    return root.querySelector(MEDIA) || document.querySelector(MEDIA);
  }

  const HOP = 0.01;                  // features are measured every 10 ms (Recense Features)
  const MIN_W = 320;

  const clamp = (v, a = 0, b = 1) => (v < a ? a : v > b ? b : v);

  // ---- which item is on stage, read off the media element ---------------------------------------------------------
  // This core knows no owner-only routes: a participant's page must not contain them
  // (routes.test.mjs "invites" asserts the rendered HTML carries no owner file route — not even quoted in a comment,
  // which is why this one describes it instead of spelling it). So route knowledge lives in strategies.
  // A strategy takes the media element's pathname and returns { key, url } or null; the first match wins.
  // The share-link strategy ships here because its routes are public and safe on every page. The owner's strategy is
  // registered by prosogram-main.js, which the page inlines only for the owner.
  const STRATEGIES = [];

  /** Undo urlPath(): per-segment encodeURIComponent joined by "/" (common.js:199). */
  const decodeSegments = (s) =>
    s.split("/").map((x) => { try { return decodeURIComponent(x); } catch { return x; } }).join("/");

  // Share links: "/f/<id>/<name>" (gallery.js:22) → the public transcript route.
  STRATEGIES.push((p) => {
    const m = p.match(/^\/f\/([^/]+)\/(.+)$/);
    if (!m) return null;
    const id = decodeURIComponent(m[1]), n = decodeSegments(m[2]);
    return { key: "share:" + id + "/" + n, url: "/api/transcript?" + new URLSearchParams({ id, n }) };
  });

  function identify(media) {
    const raw = media.currentSrc || media.src || "";
    if (!raw) return null;
    let p;
    try { p = new URL(raw, location.href).pathname; } catch { return null; }
    for (const s of STRATEGIES) {
      let r = null;
      try { r = s(p, decodeSegments); } catch { r = null; }
      if (r && r.key && r.url) return r;
    }
    return null;
  }

  // ---- data, behind cached getters -------------------------------------------------------------------------------
  const cache = { key: null, transcript: null, features: null };

  const reset = (key) => {
    if (cache.key !== key) { cache.key = key; cache.transcript = null; cache.features = null; }
  };

  async function getTranscript(ident) {
    reset(ident.key);
    if (cache.transcript) return cache.transcript;
    const r = await fetch(ident.url, { headers: { "x-gallery": "1" } });
    if (!r.ok) return null;
    const t = await r.json();
    if (!t || !Array.isArray(t.lines) || !t.lines.length) return null;
    cache.transcript = t;
    return t;
  }

  async function getFeatures(ident) {
    reset(ident.key);
    if (cache.features) return cache.features;
    const r = await fetch(ident.url + "&f=features", { headers: { "x-gallery": "1" } });
    if (!r.ok) return null;
    const f = await r.json();
    if (!f || f.none || !Array.isArray(f.db)) return null;
    cache.features = f;
    return f;
  }

  /** The corrected words, flattened in order. `flat` is the index Prosody keys its per-word results by. */
  function flatWords(lines) {
    const out = [];
    for (const l of lines) {
      if (!Array.isArray(l.words)) continue;
      for (const w of l.words) {
        if (!w || typeof w.t !== "string") continue;
        out.push({ text: w.t, s: w.s, e: w.e, flat: out.length, line: l.id });
      }
    }
    return out;
  }

  /** Which language Prosody should use: the transcript's own, else generic. */
  const langOf = (t) => {
    const l = Array.isArray(t.langs) ? t.langs[0] : t.lang;
    return typeof l === "string" && l.length >= 2 ? l.slice(0, 2).toLowerCase() : "";
  };

  // ---- signals ----------------------------------------------------------------------------------------------------
  // The prototype ships nine precomputed curves in its data.json (E A S P V Vp F C B, derive.py). features.json has
  // none of them — only db, onset, pitch, clarity, voiced, floor. Two are recoverable from those, and are computed here
  // to derive.py's own definitions; the other seven have no source and the sampler returns **null** for them, so a
  // consumer can hide what it cannot draw instead of being handed a flat zero.
  //   E (derive.py:28)  loudness over the floor, against the voice's own 95th percentile
  //   B (derive.py:116) belt — loud, clear and high in the song's own range, smoothed with a 150 ms one-pole
  const pctOf = (arr, q) => {
    if (!arr.length) return 0;
    const s = Float64Array.from(arr).sort();
    return s[Math.min(s.length - 1, Math.floor(s.length * q))];
  };
  const smoothstep = (x) => { const v = clamp(x); return v * v * (3 - 2 * v); };

  /** A one-pole smoother over a frame array, time constant in ms (derive.py `onepole`). */
  function onepole(a, ms) {
    const k = Math.exp(-(HOP * 1000) / ms), out = new Float32Array(a.length);
    let y = 0;
    for (let i = 0; i < a.length; i++) { y = a[i] + k * (y - a[i]); out[i] = y; }
    return out;
  }

  function signalFor(f, shift) {
    const db = f.db, n = db.length;
    const floor = typeof f.floor === "number" ? f.floor : -60;
    const clar = Array.isArray(f.clarity) ? f.clarity : null;
    const pitch = Array.isArray(f.pitch) ? f.pitch : null;
    const voiced = Array.isArray(f.voiced) ? f.voiced : null;

    // E: against the voice's own 95th percentile, not its maximum (one loud frame must not flatten the rest).
    const loud = [];
    for (let i = 0; i < n; i++) if (!voiced || voiced[i] === 1) loud.push(db[i] / 10);
    const top = Math.max(floor + 1, pctOf(loud, 0.95));
    const span = Math.max(1, top - floor);
    const E = new Float32Array(n);
    for (let i = 0; i < n; i++) E[i] = clamp((db[i] / 10 - floor) / span);

    // B: belt. Needs pitch and clarity; without either there is no signal and the sampler says so.
    let B = null;
    if (clar && pitch) {
      const note = (k) => (!voiced || voiced[k] === 1) && pitch[k] > 0;
      const pp = [];
      for (let k = 0; k < n; k++) if (note(k)) pp.push(pitch[k]);
      if (pp.length > 8) {
        const lo = pctOf(pp, 0.6), hi = pctOf(pp, 0.95);
        const raw = new Float32Array(n);
        for (let k = 0; k < n; k++) {
          raw[k] = note(k) ? E[k] * (clar[k] / 100) * smoothstep((pitch[k] - lo) / Math.max(1, hi - lo)) : 0;
        }
        B = onepole(raw, 150);
      }
    }

    const have = { E: true, B: !!B };
    const sampler = (sig, t) => {
      const src = sig === "E" ? E : sig === "B" ? B : null;
      if (!src) return null;                              // no source: null, never a flat zero
      const k = Math.round((t - shift) / HOP);
      if (k < 0 || k >= n) return null;
      return src[k];
    };
    sampler.have = have;
    return sampler;
  }

  /** How far the voice has crossed a word: its loudness spent so far, as Cadence does, else linear. */
  function progressFor(f, shift) {
    const db = f.db, voiced = f.voiced, n = db.length;
    const floor = typeof f.floor === "number" ? f.floor : -60;
    const w8 = (k) => (voiced && voiced[k] !== 1 ? 0 : Math.max(0, db[k] / 10 - floor));
    const sums = new Map();
    return (w, t) => {
      const dur = w.e - w.s;
      if (!(dur > 0)) return clamp(t >= w.e ? 1 : 0);
      const k0 = Math.round((w.s - shift) / HOP), k1 = Math.round((w.e - shift) / HOP);
      if (k0 < 0 || k1 > n || k1 <= k0) return clamp((t - w.s) / dur);
      let total = sums.get(w.flat);
      if (total == null) { total = 0; for (let k = k0; k < k1; k++) total += w8(k); sums.set(w.flat, total); }
      if (!(total > 0)) return clamp((t - w.s) / dur);
      const kt = Math.min(k1, Math.max(k0, Math.round((t - shift) / HOP)));
      let spent = 0;
      for (let k = k0; k < kt; k++) spent += w8(k);
      return clamp(spent / total);
    };
  }

  // ---- the panel: its own container, its own canvas, its own text layout -----------------------------------------
  function makePanel(anchor) {
    const host = document.createElement("div");
    host.className = PANEL;
    host.style.cssText = "position:relative;width:100%;overflow:hidden";
    const cv = document.createElement("canvas");
    cv.style.cssText = "display:block;width:100%";
    host.appendChild(cv);
    anchor.parentNode.insertBefore(host, anchor);
    return { host, cv, ctx: cv.getContext("2d") };
  }

  const FONT = (px) => '500 ' + px + 'px -apple-system, "SF Pro Display", "Helvetica Neue", sans-serif';
  const COLORS = { ahead: "rgb(150,148,140)", pale: "rgb(228,224,214)" };

  // The layout prosogram.js expects, matching the prototype harness exactly (harness.js:100, 126, 128):
  //   f.page = [{ line: { words }, index, slot, alpha, cells, byFlat, lineHeight, size, font }]
  //   cells  = [{ w, x, width, row, y, top }]   row = the wrapped visual row inside that block
  // One block per transcript line; blocks stack down the canvas. prosogram.js draws the glyphs itself from
  // `ln.font` and `c.x/c.y`, so nothing here paints text — this only supplies geometry.
  function layout(ctx, lines, allWords, width, size, plugin) {
    const lineHeight = size * (plugin.lineGap || 2.65);
    const slotGap = size * (plugin.slotGap || 0.9);
    ctx.font = FONT(size);
    const page = [];
    let top = 0;
    lines.forEach((l, li) => {
      const ws = allWords.filter((w) => w.line === l.id);
      if (!ws.length) return;
      const rows = [];
      let row = [], x = 0;
      for (const w of ws) {
        const wide = ctx.measureText(w.text).width;
        const adv = ctx.measureText(w.text + " ").width;
        if (row.length && x + adv > width - size) { rows.push(row); row = []; x = 0; }
        row.push({ w, x, width: wide });
        x += adv;
      }
      if (row.length) rows.push(row);
      const cells = [];
      rows.forEach((r, ri) => r.forEach((c) => cells.push({
        w: c.w, x: c.x, width: c.width, row: ri,
        y: top + ri * lineHeight + size * 1.05,
        top: top + ri * lineHeight,
      })));
      const byFlat = new Map();
      for (const c of cells) byFlat.set(c.w.flat, c);
      page.push({
        line: { words: ws }, index: li, slot: li, alpha: 1,
        cells, byFlat, lineHeight, size, font: FONT(size),
      });
      top += rows.length * lineHeight + slotGap;
    });
    return { page, height: Math.max(lineHeight, top + size) };
  }

  // ---- the clock: the media element is the source of truth -------------------------------------------------------
  function run(media, panel, plugin, pro, lines, words, at, progress, lang) {
    let raf = 0, last = 0, size = 17, laid = null, w = 0, dpr = 1;
    const ctx = panel.ctx;

    const relayout = () => {
      w = Math.max(MIN_W, panel.host.clientWidth || MIN_W);
      dpr = Math.min(3, window.devicePixelRatio || 1);
      laid = layout(ctx, lines, words, w, size, plugin);
      panel.cv.width = Math.round(w * dpr);
      panel.cv.height = Math.round(laid.height * dpr);
      panel.cv.style.height = laid.height + "px";
    };

    const frame = (now) => {
      raf = 0;
      if (!laid || w !== Math.max(MIN_W, panel.host.clientWidth || MIN_W)) relayout();
      const t = media.currentTime;
      const dt = last ? Math.max(0, (now - last) / 1000) : 0;
      last = now;
      ctx.save();
      ctx.setTransform(dpr, 0, 0, dpr, 0, 0);
      ctx.clearRect(0, 0, w, laid.height);
      try {
        plugin.draw(ctx, {
          t, dt, W: w, H: laid.height, dpr,
          pro, words, page: laid.page, lines: null,
          at, progress,
          // which signals exist here, so a consumer hides what it cannot draw rather than drawing a flat zero
          signals: at.have || { E: true },
          expr: 1, colors: COLORS, playing: !media.paused, hop: HOP, lang,
        });
      } catch (e) {
        ctx.restore();
        stop();
        console.warn("prosogram: draw failed, panel stopped", e);
        return;
      }
      ctx.restore();
      if (!media.paused) tick();
    };

    const tick = () => { if (!raf) raf = requestAnimationFrame(frame); };
    const stop = () => { if (raf) cancelAnimationFrame(raf); raf = 0; };

    for (const ev of ["play", "playing", "seeked", "ratechange", "timeupdate"]) media.addEventListener(ev, tick);
    media.addEventListener("pause", () => { tick(); });        // one last frame so the marker lands where it stopped
    window.addEventListener("resize", () => { laid = null; tick(); });

    relayout();
    tick();
    return { stop };
  }

  // ---- mount -----------------------------------------------------------------------------------------------------
  let live = null;        // { stop, host, key } for the item currently drawn
  let busy = false;

  function teardown() {
    if (!live) return;
    live.stop();
    live.host.remove();
    live = null;
  }

  async function tryMount() {
    if (busy) return;
    const anchor = document.querySelector(ANCHOR);
    const media = findMedia();
    if (!anchor || !media || !anchor.parentNode) return teardown();
    if (!globalThis.Prosody || !globalThis.Prosogram) return;

    const ident = identify(media);
    if (!ident) return teardown();
    if (live && live.key === ident.key) return;             // same item, already drawn
    busy = true;
    try { await mountFor(anchor, media, ident); } finally { busy = false; }
  }

  async function mountFor(anchor, media, ident) {
    const [t, f] = await Promise.all([getTranscript(ident), getFeatures(ident)]);
    if (cache.key !== ident.key) return;                    // the item changed while we were fetching
    if (!t || !f) return teardown();                        // no transcript or no measured voice: draw nothing
    teardown();

    const words = flatWords(t.lines);
    if (!words.length) return;

    const shift = typeof f.shift === "number" ? f.shift : 0;
    const at = signalFor(f, shift);
    const progress = progressFor(f, shift);
    const lang = langOf(t);

    const data = {
      features: { db: f.db, onset: f.onset, pitch: f.pitch, clarity: f.clarity, voiced: f.voiced, floor: f.floor },
      hop: HOP,
      frames: f.db.length,
      lang,
      kind: f.source === "vocals" ? "song" : "speech",
    };

    let pro;
    try {
      pro = Prosody.analyze(data, { at, progress, words });
    } catch (e) {
      console.warn("prosogram: Prosody.analyze failed, not mounting", e);
      return;
    }

    let plugin = null;
    Prosogram.mount({ start: (p) => { plugin = p; } });
    if (!plugin || typeof plugin.draw !== "function") return;

    const panel = makePanel(anchor);
    const handle = run(media, panel, plugin, pro, t.lines, words, at, progress, lang);
    live = { stop: handle.stop, host: panel.host, key: ident.key };
  }

  const again = () => { tryMount().catch(() => {}); };

  // The player swaps items on the same element, so the source is watched as well as the DOM.
  const watchMedia = () => {
    const media = findMedia();
    if (!media || media.__prosoWatched) return;
    media.__prosoWatched = true;
    for (const ev of ["loadedmetadata", "loadstart", "emptied"]) media.addEventListener(ev, again);
  };

  const observer = new MutationObserver(() => { watchMedia(); again(); });

  const begin = () => {
    observer.observe(document.body, { childList: true, subtree: true });
    watchMedia();
    again();
  };

  // How a page teaches this core about its own routes, without the core naming any.
  globalThis.ProsogramHost = {
    /** Register a strategy: (pathname, decodeSegments) => { key, url } | null. Later wins over earlier. */
    use(strategy) {
      if (typeof strategy !== "function") return;
      STRATEGIES.unshift(strategy);
      again();
    },
    decodeSegments,
  };

  if (document.readyState === "loading") document.addEventListener("DOMContentLoaded", begin, { once: true });
  else begin();
})();
