// Prosogram adapter for Gallery's /main player.
//
// The notation is drawn **between a line and its translation**, inside the player's own bilingual view, not in a panel
// of its own. Each "thought" is a `.txc` cell holding `.txs` (the original language) over `.txe` (the translation);
// a lane canvas is appended inside `.txs`, after the words, so it lands between the two and — because
// `:root.prom .tx .txc>.txs` carries `opacity:var(--po)` — it **fades with the original language on the crossfade**
// with no JavaScript wiring at all. Two thoughts per frame, scaling and wrapping are the player's; this follows them.
//
// Word positions come from the real `.txw` spans' rects, so the figure sits under the glyphs that are actually drawn,
// at whatever size the window gives them. That is also why prosody.js is handed these measurements rather than a
// canvas default: syllable windows must match the text on screen (prosody.js refuses a hidden default).
//
// Time bases (the thing that silently breaks if you get it wrong):
//   · the clock is the player's own (gallery.js publishes `GalleryClock` for the item on stage): the time being
//     HEARD, which on Safari is its deck's position and elsewhere currentTime less the output latency, times the
//     speed. The captions run on it too, so the notation can't lead or trail them at any speed. Without that hook
//     (another host), the element's currentTime.
//   · transcript word times are ALREADY shifted into this file's time by the Worker (corrections.js `present`),
//     so they compare directly against that clock. With the player's hook they are its own lines, timed to the
//     voice (cadence.js) and corrected as shown; the figure is drawn again whenever they change (`version`).
//   · features frames are in the TRANSCRIPT's time, and the response carries `shift` unapplied.
//     So frame index = (fileTime - shift) / HOP.
//
// Known limit: on a line a human rewrote (`fixed`), the Worker sends the corrected `text` but the ORIGINAL `words`
// array (corrections.js `present`), so those lines are analysed pre-correction. Unfixed lines are exact.
(() => {
  "use strict";

  // ---- the only DOM coupling to Gallery, kept in one place ------------------------------------------------------
  const STAGE = "#stage";            // the viewer's stage
  const MBOX = ".mbox";              // the media's wrapper; it carries an OPEN shadow root
  const MEDIA = "video, audio";
  const CELL = ".txc";               // one thought: the original over its translation
  const SRC = ".txs";                // the original language inside a cell (carries --po)
  const WORD = ".txw";               // one word
  const LANE = "pg-lane";            // the canvas this module appends inside .txs

  const HOP = 0.01;                  // features are measured every 10 ms (Recense Features)
  const LANE_H = 1.45;               // lane height, × the line's font size: the ribbon, its swell and a link's sound
  const BASE = 0;                    // the ribbon's row starts right under the words

  const clamp = (v, a = 0, b = 1) => (v < a ? a : v > b ? b : v);

  // The media element usually lives inside .mbox's shadow root, so document.querySelector cannot reach it — this
  // mirrors the player's own stageMedia() (gallery.js:56), including its no-attachShadow fallback.
  function findMedia() {
    const stage = document.querySelector(STAGE) || document;
    const box = stage.querySelector ? stage.querySelector(MBOX) : null;
    const root = box && box.shadowRoot ? box.shadowRoot : stage;
    return root.querySelector(MEDIA) || document.querySelector(MEDIA);
  }

  // ---- which item is on stage -------------------------------------------------------------------------------------
  // This core knows no owner-only routes: a participant's page must not contain them (routes.test.mjs "invites"
  // asserts the rendered HTML carries no owner file route). Route knowledge lives in strategies; the owner's is
  // registered by prosogram-main.js, which the page inlines only for the owner.
  const STRATEGIES = [];

  /** Undo urlPath(): per-segment encodeURIComponent joined by "/" (common.js:199). */
  const decodeSegments = (s) =>
    s.split("/").map((x) => { try { return decodeURIComponent(x); } catch { return x; } }).join("/");

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
  const reset = (key) => { if (cache.key !== key) { cache.key = key; cache.transcript = null; cache.features = null; } };

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

  // an older Worker sends no `lang`: French by its little words, so liaisons still show
  const frenchLooking = (t) => {
    const ws = (t.lines || []).flatMap((l) => (l.words || []).map((w) => String(w.t || "").toLowerCase()));
    const fr = ws.filter((w) => /^(le|la|les|des|et|est|un|une|du|qui|que|nous|vous|je|tu|il|elle|ce|dans|pour|pas|ne|on|où|à)$/.test(w)).length;
    return ws.length >= 4 && fr / ws.length > 0.15;
  };
  const langOf = (t) => {
    // the language sung (the Worker's `lang`); `langs` lists only the translations, never this
    const l = typeof t.lang === "string" && t.lang ? t.lang : frenchLooking(t) ? "fr" : "";
    return typeof l === "string" && l.length >= 2 ? l.slice(0, 2).toLowerCase() : "";
  };

  // ---- signals ----------------------------------------------------------------------------------------------------
  // The prototype ships nine precomputed curves in its data.json (E A S P V Vp F C B, derive.py). features.json has
  // none of them — only db, onset, pitch, clarity, voiced, floor. Two are recoverable and are computed to derive.py's
  // own definitions; the other seven have no source and the sampler returns null, so a consumer hides what it cannot
  // draw instead of being handed a flat zero.
  //   E (derive.py:28)  loudness over the floor, against the voice's own 95th percentile
  //   B (derive.py:116) belt — loud, clear and high in the song's own range, 150 ms one-pole
  const pctOf = (arr, q) => {
    if (!arr.length) return 0;
    const s = Float64Array.from(arr).sort();
    return s[Math.min(s.length - 1, Math.floor(s.length * q))];
  };
  const smoothstep = (x) => { const v = clamp(x); return v * v * (3 - 2 * v); };

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

    const loud = [];
    for (let i = 0; i < n; i++) if (!voiced || voiced[i] === 1) loud.push(db[i] / 10);
    const top = Math.max(floor + 1, pctOf(loud, 0.95));
    const span = Math.max(1, top - floor);
    const E = new Float32Array(n);
    for (let i = 0; i < n; i++) E[i] = clamp((db[i] / 10 - floor) / span);

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

    const sampler = (sig, t) => {
      const src = sig === "E" ? E : sig === "B" ? B : null;
      if (!src) return null;
      const k = Math.round((t - shift) / HOP);
      if (k < 0 || k >= n) return null;
      return src[k];
    };
    sampler.have = { E: true, B: !!B };
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

  // ---- the lane: one canvas per thought, inside .txs so it rides --po ---------------------------------------------
  const COLORS = { ahead: "rgb(150,148,140)", pale: "rgb(228,224,214)" };

  function laneIn(src) {
    let cv = src.querySelector("canvas." + LANE);
    if (!cv) {
      cv = document.createElement("canvas");
      cv.className = LANE;
      // display:block puts it on its own line under the words but still inside .txs, so it sits between the original
      // and the translation and inherits the original's opacity.
      cv.style.cssText = "display:block;width:100%;pointer-events:none";
      cv.setAttribute("aria-hidden", "true");
      src.appendChild(cv);
    }
    return cv;
  }

  /** Walks the flattened words in order, matching them to the spans as they appear.
   *  ONE walker per frame, shared by every cell in document order: the thoughts on screen are consecutive slices of
   *  the same word list, so it must keep advancing. A walker per cell restarts at word 0 and only ever matches the
   *  first thought — every later lane then comes out empty. */
  function walker(words) {
    let i = 0;
    // a span carrying its start (data-s) is matched on it: the two places take turns, so the page order isn't
    // time order, and a repeated word ("le", "la") matched by text alone took another occurrence's figure
    const at = new Map();
    for (const w of words) at.set(Math.round(w.s * 1000) + "|" + w.text.trim(), w);
    return (text, s) => {
      const want = (text || "").trim();
      if (!want) return null;
      if (s != null && s !== "") {
        const w = at.get(Math.round(Number(s) * 1000) + "|" + want);
        if (w) return w;
      }
      for (let j = i; j < words.length; j++) {
        if (words[j].text.trim() === want) { i = j + 1; return words[j]; }
      }
      // not ahead of us (a repeat, or the view jumped back): look from the start before giving up
      for (let j = 0; j < i; j++) {
        if (words[j].text.trim() === want) { i = j + 1; return words[j]; }
      }
      return null;
    };
  }

  /** The block prosogram.js wants, built from where the words really are on screen. */
  // what the toggle under the vertical bar asks for (gallery.js GalleryNotation; another host: the ribbon alone)
  const notationNow = () => {
    const N = globalThis.GalleryNotation;
    const m = N && typeof N.mode === "function" ? N.mode() : "p";
    return { ribbon: m.includes("p"), chords: m.includes("c") ? N.chords || [] : null, notes: m.includes("n") && N ? N.noteName : null };
  };
  const ABOVE = 0.38;                // room above the ribbon for a line of chord or note names, × font size
  const BARE = 0.15;                 // a lane with labels but no ribbon

  function blockFor(src, next, size, nt) {
    const spans = [...src.querySelectorAll(WORD)];
    if (!spans.length) return null;
    const base = src.getBoundingClientRect();
    const cells = [], rowsY = [];
    for (const sp of spans) {
      const w = next(sp.textContent || "", sp.dataset.s);
      if (!w) continue;
      const r = sp.getBoundingClientRect();
      if (!r.width) continue;
      let row = rowsY.findIndex((y) => Math.abs(y - r.top) < r.height * 0.6);
      if (row < 0) { rowsY.push(r.top); row = rowsY.length - 1; }
      cells.push({ w, x: r.left - base.left, width: r.width, row, y: 0, top: 0 });
    }
    if (!cells.length) return null;
    const above = nt ? (nt.chords ? ABOVE : 0) + (nt.notes ? ABOVE : 0) : 0;   // a line of names each
    const laneH = size * ((nt && !nt.ribbon ? BARE : LANE_H) + above);
    for (const c of cells) { c.top = c.row * laneH; c.y = c.top + size * (BASE + above); }
    const byFlat = new Map();
    for (const c of cells) byFlat.set(c.w.flat, c);
    return {
      block: {
        line: { words: cells.map((c) => c.w) }, index: 0, slot: 0, alpha: 1,
        cells, byFlat, lineHeight: laneH, size, font: getComputedStyle(src).font || size + "px sans-serif",
      },
      rows: rowsY.length,
      laneH,
    };
  }

  // ---- drawing ----------------------------------------------------------------------------------------------------
  /** The player's hook when it publishes one for this element (gallery.js: GalleryClock), else null. */
  function shared(media) {
    const c = globalThis.GalleryClock;
    return c && c.media === media ? c : null;
  }

  /** The time being heard: the player's clock when it publishes one for this element, else currentTime. */
  function heardTime(media) {
    const c = shared(media);
    if (c && typeof c.now === "function") {
      const t = c.now();
      if (Number.isFinite(t)) return t;
    }
    return media.currentTime;
  }

  function run(media, plugin, pro, words, at, progress) {
    let raf = 0;

    const paintOne = (src, t, next) => {
      const size = parseFloat(getComputedStyle(src).fontSize) || 17;
      const nt = notationNow();
      const built = nt.ribbon || nt.chords || nt.notes ? blockFor(src, next, size, nt) : null;
      const cv = laneIn(src);
      if (!built) { cv.width = 0; cv.height = 0; cv.style.height = "0px"; return; }
      const w = Math.max(1, Math.round(src.getBoundingClientRect().width));
      const h = Math.max(1, Math.round(built.rows * built.laneH));
      const dpr = Math.min(3, window.devicePixelRatio || 1);
      if (cv.width !== Math.round(w * dpr) || cv.height !== Math.round(h * dpr)) {
        cv.width = Math.round(w * dpr); cv.height = Math.round(h * dpr);
      }
      cv.style.height = h + "px";
      const ctx = cv.getContext("2d");
      ctx.save();
      ctx.setTransform(dpr, 0, 0, dpr, 0, 0);
      ctx.clearRect(0, 0, w, h);
      plugin.draw(ctx, {
        t, dt: 0, W: w, H: h, dpr,
        pro, words, page: [built.block], lines: null,
        at, progress,
        signals: at.have || { E: true },
        glyphs: false,                 // Gallery draws the words as DOM text; only the figure belongs here
        ribbon: nt.ribbon, chords: nt.chords, noteName: nt.notes,
        expr: 1, colors: COLORS, playing: !media.paused, hop: HOP,
      });
      ctx.restore();
    };

    const frame = () => {
      raf = 0;
      const t = heardTime(media);
      const next = walker(words);            // one walker for the whole frame, advancing across the thoughts
      for (const cell of document.querySelectorAll(CELL)) {
        const src = cell.querySelector(SRC);
        if (!src) continue;
        const r = src.getBoundingClientRect();
        if (!r.width || r.bottom < -200 || r.top > innerHeight + 200) continue;   // off-screen: skip
        try { paintOne(src, t, next); } catch (e) { stop(); console.warn("prosogram: draw failed, lanes stopped", e); return; }
      }
      if (!media.paused) tick();
    };

    const tick = () => { if (!raf) raf = requestAnimationFrame(frame); };
    const stop = () => { if (raf) cancelAnimationFrame(raf); raf = 0; };

    for (const ev of ["play", "playing", "seeked", "ratechange", "timeupdate"]) media.addEventListener(ev, tick);
    media.addEventListener("pause", tick);
    window.addEventListener("resize", tick);
    tick();
    return { stop };
  }

  // ---- mount -----------------------------------------------------------------------------------------------------
  let live = null, busy = false;

  function teardown() {
    if (!live) return;
    live.stop();
    for (const cv of document.querySelectorAll("canvas." + LANE)) cv.remove();
    live = null;
  }

  async function tryMount() {
    if (busy) return;
    const media = findMedia();
    if (!media) return teardown();
    if (!globalThis.Prosody || !globalThis.Prosogram) return;
    if (!document.querySelector(CELL + " " + SRC + " " + WORD)) return;   // the lyrics are not up yet
    const ident = identify(media);
    if (!ident) return teardown();
    const hook = shared(media);
    if (live && live.key === ident.key && live.version === (hook ? hook.version : -1)) return;
    busy = true;
    try { await mountFor(media, ident); } finally { busy = false; }
  }

  async function mountFor(media, ident) {
    const [t, f] = await Promise.all([getTranscript(ident), getFeatures(ident)]);
    if (cache.key !== ident.key) return;
    if (!t || !f) return teardown();
    teardown();

    // the very lines the captions show, timed to the voice as they are (cadence.js), when the player shares them
    const hook = shared(media);
    const version = hook ? hook.version : -1;
    const own = hook && typeof hook.lines === "function" ? hook.lines() : null;
    const words = flatWords(Array.isArray(own) && own.length ? own : t.lines);
    if (!words.length) return;

    const shift = typeof f.shift === "number" ? f.shift : 0;
    const at = signalFor(f, shift);
    const progress = progressFor(f, shift);

    const data = {
      features: { db: f.db, onset: f.onset, pitch: f.pitch, clarity: f.clarity, voiced: f.voiced, floor: f.floor },
      hop: HOP,
      frames: f.db.length,
      lang: langOf(t),
      kind: f.source === "vocals" ? "song" : "speech",
    };

    let pro;
    try {
      // the glyph metrics this host draws with: the player's own text, measured where it is drawn
      const el = document.querySelector(CELL + " " + SRC);
      const font = el ? getComputedStyle(el).font : "";
      const measure = (font && Prosody.canvasMeasure(font)) || Prosody.evenMeasure();
      pro = Prosody.analyze(data, { at, progress, words, measure });
    } catch (e) {
      console.warn("prosogram: Prosody.analyze failed, not mounting", e);
      return;
    }

    let plugin = null;
    Prosogram.mount({ start: (p) => { plugin = p; } });
    if (!plugin || typeof plugin.draw !== "function") return;

    const handle = run(media, plugin, pro, words, at, progress);
    live = { stop: handle.stop, key: ident.key, version };
  }

  const again = () => { tryMount().catch(() => {}); };

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

  globalThis.ProsogramHost = {
    /** Register a route strategy: (pathname, decodeSegments) => { key, url } | null. Later wins over earlier. */
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
