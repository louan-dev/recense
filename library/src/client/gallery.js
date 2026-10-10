
(() => {
  "use strict";

  const $ = (id) => document.getElementById(id);

  const grid = $("grid");
  const lb = $("lb");
  const stage = $("stage");
  const strip = $("strip");
  const meta = $("meta");
  const hero = $("hero");
  const dl = $("dl");
  const del = $("del");
  const up = $("up");
  const upin = $("upin");
  const note = $("note");

  // Every item the uploader promised: ready ones, and ones still uploading.
  const items = (G.items || []).slice();
  let complete = !!G.complete;

  const src = (f) => f.src || "/f/" + G.id + "/" + f.n;
  const clamp = (v, a = 0, b = 1) => Math.min(b, Math.max(a, v));

  const mkEl = (t, c) => {
    const e = document.createElement(t);
    if (c) e.className = c;
    return e;
  };

  const mkBtn = (c, label, html) => {
    const b = mkEl("button", c);
    b.type = "button";
    b.setAttribute("aria-label", label);
    b.innerHTML = html;
    return b;
  };

  const kind = (f) => {
    if (f.type.startsWith("image/")) return "img";
    if (f.type.startsWith("video/")) return "vid";
    if (f.type.startsWith("audio/")) return "aud";

    const name = f.name.toLowerCase();

    if (/\.(mp3|m4a|m4b|aac|flac|wav|wave|aif|aiff|ogg|oga|opus)$/.test(name)) return "aud";
    if (/\.(mp4|m4v|mov|webm)$/.test(name)) return "vid";

    return "doc";
  };

  const D = (t, o) => new Date(t).toLocaleDateString("en-GB", o);

  const T = (t) =>
    new Date(t).toLocaleTimeString("en-GB", { hour: "2-digit", minute: "2-digit" });

  const dur = (s) => {
    if (!isFinite(s) || s < 0) return "0:00";

    const h = Math.floor(s / 3600);
    const m = Math.floor((s % 3600) / 60);
    const sec = Math.floor(s % 60);
    const pad = (n) => String(n).padStart(2, "0");

    return h > 0 ? pad(h) + ":" + pad(m) + ":" + pad(sec) : m + ":" + pad(sec);
  };

  const sz = (b) =>
    b < 1048576
      ? Math.max(1, Math.round(b / 1024)) + " KB"
      : (b / 1048576).toFixed(1) + " MB";

  const ext = (f) => {
    const i = f.name.lastIndexOf(".");
    const e = i > 0 && i < f.name.length - 1 ? f.name.slice(i + 1).toUpperCase() : "";
    return e && e.length <= 4 ? e : "FILE";
  };

  const icon = (e) => {
    const s = mkEl("span", "fi");

    s.innerHTML =
      '<svg viewBox="0 0 40 50" fill="none">' +
      '<path d="M4 0C1.79 0 0 1.79 0 4V46C0 48.21 1.79 50 4 50H36C38.21 50 40 48.21 40 46V15L25 0H4Z" fill="currentColor" opacity="0.12"/>' +
      '<path d="M25 0V11C25 13.21 26.79 15 29 15H40L25 0Z" fill="currentColor" opacity="0.35"/>' +
      '<path d="M25.5 0.5V11C25.5 12.933 27.067 14.5 29 14.5H39.5L25.5 0.5ZM4.5 0.5C2.567 0.5 1 2.067 1 4V46C1 47.933 2.567 49.5 4.5 49.5H35.5C37.433 49.5 39 47.933 39 46V15.5H29C26.239 15.5 24 13.261 24 10.5V0.5H4.5Z" stroke="currentColor"/>' +
      "</svg><i></i>";

    s.lastChild.textContent = e;

    return s;
  };

  const SVG = (inner, fill, cls) =>
    "<svg" +
    (cls ? ' class="' + cls + '"' : "") +
    ' viewBox="0 0 24 24" fill="' +
    (fill ? "currentColor" : "none") +
    '" stroke="' +
    (fill ? "none" : "currentColor") +
    '" stroke-width="2" stroke-linecap="round" stroke-linejoin="round">' +
    inner +
    "</svg>";

  const artSrc = (f) => {
    if (f.art && !f.noart) return f.art;
    if (kind(f) !== "aud") return null;

    const dot = f.name.lastIndexOf(".");
    const baseName = dot > 0 ? f.name.substring(0, dot) : f.name;

    const paired = items.find((x) => {
      if (x.pending || kind(x) !== "img") return false;
      const xd = x.name.lastIndexOf(".");
      const xb = xd > 0 ? x.name.substring(0, xd) : x.name;
      return xb.toLowerCase() === baseName.toLowerCase();
    });

    return paired ? src(paired) : null;
  };

  // ---------- PDF: first-page thumbnails + scrollable viewer ----------

  const PDFJS = "https://cdnjs.cloudflare.com/ajax/libs/pdf.js/3.11.174/";

  let pdfLib = null;
  let pdfWorker = null;
  let killPdf = null;

  const isPdf = (f) =>
    f.type === "application/pdf" || /\.pdf$/i.test(f.name);

  // pdf.js is only downloaded when a gallery actually contains a PDF.
  const loadPdfJs = () =>
    pdfLib ||
    (pdfLib = new Promise((res, rej) => {
      const s = document.createElement("script");
      s.src = PDFJS + "pdf.min.js";
      s.onload = () => {
        try {
          const lib = window.pdfjsLib;
          lib.GlobalWorkerOptions.workerSrc = PDFJS + "pdf.worker.min.js";
          pdfWorker = new lib.PDFWorker(); // one worker shared by every PDF
          res(lib);
        } catch (e) {
          pdfLib = null;
          rej(e);
        }
      };
      s.onerror = () => {
        pdfLib = null;
        rej(new Error("pdf.js did not load"));
      };
      document.head.appendChild(s);
    }));

  const openPdf = (f) =>
    loadPdfJs().then((lib) =>
      lib.getDocument({ url: src(f), worker: pdfWorker })
    );

  // Page 1 rendered once to a small JPEG; the grid tile and the
  // filmstrip thumbnail both reuse it.
  const thumbCache = {};

  const pdfThumb = (f) =>
    thumbCache[f.n] ||
    (thumbCache[f.n] = openPdf(f).then(async (task) => {
      try {
        const doc = await task.promise;
        const page = await doc.getPage(1);
        const v1 = page.getViewport({ scale: 1 });
        const vp = page.getViewport({ scale: 420 / v1.width });
        const c = document.createElement("canvas");
        c.width = Math.floor(vp.width);
        c.height = Math.floor(vp.height);
        await page.render({
          canvasContext: c.getContext("2d"),
          viewport: vp
        }).promise;
        return c.toDataURL("image/jpeg", 0.82);
      } finally {
        task.destroy();
      }
    }));

  // Shown when a non-previewable file is opened, or when a PDF fails.
  const docView = (f) => {
    const d = document.createElement("div");
    d.className = "dv";
    d.appendChild(icon(ext(f)));
    const b = document.createElement("b");
    b.textContent = f.name;
    d.appendChild(b);
    return d;
  };

  const buildPdf = (f) => {
    const wrap = document.createElement("div");
    wrap.className = "pdfw";

    const spin = document.createElement("div");
    spin.className = "spin";
    wrap.appendChild(spin);

    let dead = false;
    let task = null;
    let io = null;
    let ro = null;
    let hideT = 0;

    killPdf = () => {
      dead = true;
      clearTimeout(hideT);
      if (io) io.disconnect();
      if (ro) ro.disconnect();
      if (task) task.destroy();
    };

    const start = (doc, first) => {
      const mk = (cls) => {
        const e = document.createElement("div");
        e.className = cls;
        return e;
      };

      const v1 = first.getViewport({ scale: 1 });
      const ratio = v1.width + " / " + v1.height;

      const scroller = mk("pdfv");
      const col = mk("pdfd");
      const pill = mk("pg");
      const pages = [];

      let z = 1; // 1 = fit width, 2 = zoomed
      let gen = 0; // bumps whenever pages must be re-rendered

      scroller.tabIndex = 0;

      for (let n = 1; n <= doc.numPages; n++) {
        const el = mk("pdfp");
        el.style.aspectRatio = ratio;

        const p = {
          n,
          el,
          vis: false,
          busy: false,
          job: null,
          drawn: -1,
          failed: -1
        };

        el._p = p;
        pages.push(p);
        col.appendChild(el);
      }

      scroller.appendChild(col);
      wrap.replaceChildren(scroller, pill);

      const draw = async (p) => {
        if (dead || p.busy || p.drawn === gen) return;

        p.busy = true;
        const my = gen;

        try {
          const page = await doc.getPage(p.n);
          const pv = page.getViewport({ scale: 1 });

          p.el.style.aspectRatio = pv.width + " / " + pv.height;

          // Sharp on retina, but never past the mobile canvas limit.
          const dpr = Math.min(window.devicePixelRatio || 1, 2);
          let s = (p.el.clientWidth / pv.width) * dpr;
          const px = pv.width * s * pv.height * s;
          if (px > 14e6) s *= Math.sqrt(14e6 / px);

          const vp = page.getViewport({ scale: s });
          const c = document.createElement("canvas");
          c.width = Math.floor(vp.width);
          c.height = Math.floor(vp.height);

          p.job = page.render({
            canvasContext: c.getContext("2d"),
            viewport: vp
          });
          await p.job.promise;

          if (dead || !p.vis || my !== gen) {
            c.width = c.height = 0;
            return;
          }

          const had = p.el.firstChild;
          p.el.replaceChildren(c);

          if (had) {
            c.classList.add("ok"); // re-render after zoom: swap silently
          } else {
            requestAnimationFrame(() => c.classList.add("ok"));
          }

          p.drawn = my;
        } catch (e) {
          p.failed = my;
        } finally {
          p.busy = false;
          p.job = null;

          if (!dead && p.vis && p.drawn !== gen && p.failed !== gen) {
            draw(p);
          }
        }
      };

      // Pages far off-screen give their canvas back (matters on iPhone).
      const release = (p) => {
        if (p.job) p.job.cancel();

        const c = p.el.firstChild;
        if (c) {
          c.width = c.height = 0;
          p.el.replaceChildren();
        }

        p.drawn = -1;
      };

      io = new IntersectionObserver(
        (entries) =>
          entries.forEach((e) => {
            const p = e.target._p;
            p.vis = e.isIntersecting;
            if (p.vis) draw(p);
            else release(p);
          }),
        { root: scroller, rootMargin: "100% 0px" }
      );

      pages.forEach((p) => io.observe(p.el));

      // "3 of 12" appears while scrolling, then fades.
      const updatePill = () => {
        if (pages.length < 2) return;

        const mid = scroller.getBoundingClientRect().top + scroller.clientHeight / 2;
        let cur = pages.length;

        for (const p of pages) {
          if (p.el.getBoundingClientRect().bottom > mid) {
            cur = p.n;
            break;
          }
        }

        pill.textContent = cur + " of " + pages.length;
        pill.classList.add("on");

        clearTimeout(hideT);
        hideT = setTimeout(() => pill.classList.remove("on"), 1400);
      };

      let ticking = false;

      scroller.addEventListener(
        "scroll",
        () => {
          if (ticking) return;
          ticking = true;

          requestAnimationFrame(() => {
            ticking = false;
            updatePill();
          });
        },
        { passive: true }
      );

      const zoom = (nz) => {
        const cy =
          (scroller.scrollTop + scroller.clientHeight / 2) /
          scroller.scrollHeight;

        z = nz;
        gen++;

        col.style.setProperty("--z", z);
        scroller.classList.toggle("z", z > 1);

        scroller.scrollTop = cy * scroller.scrollHeight - scroller.clientHeight / 2;
        scroller.scrollLeft = (scroller.scrollWidth - scroller.clientWidth) / 2;

        pages.forEach((p) => {
          if (p.vis) draw(p);
        });
      };

      // Double-tap (or double-click) toggles fit-width / zoomed.
      let lastT = 0;
      let lastX = 0;
      let lastY = 0;

      scroller.addEventListener("pointerup", (e) => {
        const now = performance.now();

        if (
          now - lastT < 300 &&
          Math.hypot(e.clientX - lastX, e.clientY - lastY) < 30
        ) {
          lastT = 0;
          zoom(z === 1 ? 2 : 1);
        } else {
          lastT = now;
          lastX = e.clientX;
          lastY = e.clientY;
        }
      });

      // Rotating a phone changes the page width: re-render sharp.
      let w0 = 0;

      ro = new ResizeObserver(() => {
        const w = scroller.clientWidth;

        if (!w0) {
          w0 = w;
        } else if (Math.abs(w - w0) > 24) {
          w0 = w;
          gen++;
          pages.forEach((p) => {
            if (p.vis) draw(p);
          });
        }
      });

      ro.observe(scroller);

      updatePill();
      scroller.focus({ preventScroll: true });
    };

    openPdf(f)
      .then(async (t) => {
        task = t;

        if (dead) {
          t.destroy();
          return;
        }

        const doc = await t.promise;
        if (dead) return;

        const first = await doc.getPage(1);
        if (dead) return;

        start(doc, first);
      })
      .catch(() => {
        if (!dead) wrap.replaceChildren(docView(f));
      });

    return wrap;
  };


  // ---------- the player ----------
  //
  // Direction carries meaning. HORIZONTAL is time and its relatives (position, speed, A to B);
  // VERTICAL is tone (the EQ). Three separate pieces, none of them boxed in:
  //
  //                       ───────          the HOME BAR: a thin stroke, centred above the
  //                                        transport. At rest it is nothing but the line.
  //            ↻ Loop         A ●───● B  ×   hover (mouse) or first tap (touch): Loop · A–B
  //        ─────────────────────────────────
  //          0.5×  0.75×  1×  1.25×  1.5×  2×  click (mouse) or second tap (touch): Speed
  //
  //        0:00     5:00     10:00     15:00   press and HOLD: Time Seeking. The line becomes a
  //        ────┬───────┬────────┬────────┬───   temporary ruler with the playhead where you are;
  //                        ● 19:03             slide to move from there; let go and it is gone.
  //                                            Two fingers swiping along it do the same, no hold
  //                                            needed (two fingers on a screen, or on a trackpad).
  //
  //   [ 0:00 ━━━━━━━━━━━━━━ -0:45 ]   (EQ)   the transport bar, with the EQ at its far right
  //
  //   Track Loop  repeat the whole track.            on / off
  //   A–B         repeat between two captured points. Needs Track Loop, so turning A–B on turns
  //               Track Loop on; turning Track Loop off turns A–B off. Never the other way round.
  //   Speed       six detents, 0.5x to 2x, left (slower) to right (faster). It has no permanent
  //               place in the bar. Whenever it isn't 1x the value hangs under the unfolded
  //               stroke, and one tap on that value puts it back.
  //   Seeking     the ruler is as long as the media, ticks and labels chosen to fit the width, and
  //               one pixel of finger is one pixel of ruler. Sliding up zooms it around where you
  //               are, to settle on an exact second.
  //
  // Three things are kept strictly apart, and none of them ever touches the media element
  // (no pause, no seek, no currentTime, no reload):
  //   disable A–B   stop looping between the points, keep the points
  //   clear A/B     forget the points; Track Loop is left as it is
  //   Track Loop    on / off
  // (Only Time Seeking moves the playhead, because moving the playhead is what it is for.)

  const prefs = {
    speed: 1,
    loop: "off",
    eq: { low: 0, mid: 0, high: 0 },
    key: 0, // semitones, -12 to +12; 0 is the original key
    space: { mix: 0, on: false, room: "room" }, // reverb: wet amount 0-100, bypass, which room
  };
  const SPEEDS = [0.5, 0.75, 1, 1.25, 1.5, 2];

  // one audio context for the whole viewer, created the first time you touch the EQ
  // (a user gesture, so it is allowed to run) and reused for every later player
  let audioCtx = null;

  const EQ_MAX = 15;

  const EQ_BANDS = [
    { id: "low", label: "Low", type: "lowshelf", f: 160, q: 0.7 },
    { id: "mid", label: "Mid", type: "peaking", f: 1000, q: 0.7 },
    { id: "high", label: "High", type: "highshelf", f: 5000, q: 0.7 },
  ];

  // Key: transposition in semitones, by a phase vocoder in an AudioWorklet (see keyProcessor in
  // the Worker). Tempo and Speed are untouched by it. Loaded once per viewer, on first use.
  const KEY_MAX = 12;
  let keyModule = null;

  const workletReady = () => {
    if (!window.AudioWorkletNode || !audioCtx.audioWorklet) return Promise.reject(new Error("no worklet"));

    if (!keyModule) {
      keyModule = audioCtx.audioWorklet.addModule("/player/key.js?v=" + G.version).catch((e) => {
        keyModule = null;
        throw e;
      });
    }

    return keyModule;
  };

  // Space: a convolution reverb whose impulse responses are synthesised here (decaying,
  // darkening noise), so nothing is downloaded. Two rooms; one per viewer, built on first use.
  const ROOMS = {
    room: { label: "Room", rt: 0.9, pre: 0.008, dark: 0.55 },
    hall: { label: "Hall", rt: 2.4, pre: 0.022, dark: 0.75 },
  };
  const roomIRs = {};

  // The same noise every time (a fixed seed), so a download has exactly the room you heard.
  const irData = (id, sr) => {
    const r = ROOMS[id];
    const pre = Math.round(r.pre * sr);
    const len = pre + Math.round(r.rt * 1.1 * sr);
    const out = [];

    for (let c = 0; c < 2; c++) {
      const d = new Float32Array(len);
      let seed = 0x9e3779b9 ^ (c + 1) * 0x85ebca6b;
      let lp = 0;

      const rnd = () => {
        seed = (seed + 0x6d2b79f5) | 0;
        let t = Math.imul(seed ^ (seed >>> 15), 1 | seed);
        t = (t + Math.imul(t ^ (t >>> 7), 61 | t)) ^ t;
        return ((t ^ (t >>> 14)) >>> 0) / 4294967296;
      };

      for (let i = pre; i < len; i++) {
        const t = (i - pre) / sr;
        // the tail closes down as it decays, the way air and walls swallow the highs first
        const k = 0.12 + r.dark * Math.min(1, t / r.rt) * 0.8;
        lp += (1 - k) * (rnd() * 2 - 1 - lp);
        d[i] = lp * Math.pow(10, (-3 * t) / r.rt) * Math.min(1, t / 0.004); // -60 dB at rt
      }

      out.push(d);
    }

    return out;
  };

  const irBuffer = (ctx, id) => {
    const d = irData(id, ctx.sampleRate);
    const buf = ctx.createBuffer(2, d[0].length, ctx.sampleRate);

    d.forEach((x, c) => buf.getChannelData(c).set(x));
    return buf;
  };

  const roomIR = (id) => roomIRs[id] || (roomIRs[id] = irBuffer(audioCtx, id));

  const spaceOn = () => prefs.space.on && prefs.space.mix > 0;

  // ----- reading a file's sound directly (Safari's deck, and downloads with the sound baked in) -----
  //
  // Safari, and every browser on iPhone and iPad (all Safari underneath), feeds a media element
  // into Web Audio at the file's 1x pace whatever the playback speed: above 1x the sound comes out
  // cut up, skipping ahead, and what piled up is still being let out after a pause. There the
  // player's sound comes from the deck (see DeckProcessor in the Worker) and the element plays
  // muted. Elsewhere the element feeds Web Audio as before.
  const DECK =
    (() => {
      const u = navigator.userAgent;
      if (/iPad|iPhone|iPod/.test(u) || (/Macintosh/.test(u) && navigator.maxTouchPoints > 1)) return true;
      return /Safari\//.test(u) && !/Chrome|Chromium|CriOS|Edg|OPR|Firefox|FxiOS/.test(u);
    })() || !!window.__pdcDeck;

  const CHUNK = 65536; // frames per chunk: about 1.4 s
  const BIG_DECODE = 150e6; // bytes: a compressed file larger than this isn't decoded whole
  const LONG_DECODE = 20 * 60; // seconds: nor one longer than this (it would not fit in a phone)

  // PCM WAV and AIFF: where the samples start and how they're laid out, from the file's header
  const parsePcm = (b, size) => {
    const dv = new DataView(b.buffer, b.byteOffset, b.byteLength);
    const tag = (o) => String.fromCharCode(b[o], b[o + 1], b[o + 2], b[o + 3]);

    const fmt = (f, off, bytes) => {
      const B = f.bits / 8;
      const ok = f.float ? B === 4 || B === 8 : B >= 1 && B <= 4 && B === Math.floor(B);

      if (!ok || !f.nch || !f.sr || f.align !== f.nch * B) return null;
      if (off + bytes > size) bytes = size - off;

      return Object.assign(f, { off, frames: Math.floor(bytes / f.align) });
    };

    if (b.length < 12) return null;

    if (tag(0) === "RIFF" && tag(8) === "WAVE") {
      let o = 12;
      let f = null;

      while (o + 8 <= b.length) {
        const id = tag(o);
        const len = dv.getUint32(o + 4, true);

        if (id === "fmt " && o + 24 <= b.length) {
          let code = dv.getUint16(o + 8, true);
          if (code === 0xfffe && len >= 26 && o + 34 <= b.length) code = dv.getUint16(o + 32, true);
          if (code !== 1 && code !== 3) return null;

          f = {
            nch: dv.getUint16(o + 10, true),
            sr: dv.getUint32(o + 12, true),
            align: dv.getUint16(o + 20, true),
            bits: dv.getUint16(o + 22, true),
            float: code === 3,
            le: true,
            u8: true,
          };
        } else if (id === "data") {
          if (!f) return null;
          return fmt(f, o + 8, !len || len === 0xffffffff ? size - o - 8 : len);
        }

        o += 8 + len + (len & 1);
      }

      return null;
    }

    if (tag(0) === "FORM" && (tag(8) === "AIFF" || tag(8) === "AIFC")) {
      let o = 12;
      let f = null;

      while (o + 8 <= b.length) {
        const id = tag(o);
        const len = dv.getUint32(o + 4);

        if (id === "COMM" && o + 26 <= b.length) {
          const comp = tag(8) === "AIFC" && len >= 22 && o + 30 <= b.length ? tag(o + 26) : "NONE";
          const ex = dv.getUint16(o + 16) & 0x7fff;
          const sr = (dv.getUint32(o + 18) * 4294967296 + dv.getUint32(o + 22)) * Math.pow(2, ex - 16383 - 63);
          const bits = dv.getInt16(o + 14);
          const nch = dv.getInt16(o + 8);

          if (!/^(NONE|sowt|fl32|FL32)$/.test(comp)) return null;

          f = {
            nch,
            sr: Math.round(sr),
            bits: comp === "fl32" || comp === "FL32" ? 32 : Math.ceil(bits / 8) * 8,
            float: comp === "fl32" || comp === "FL32",
            le: comp === "sowt",
            u8: false,
          };
          f.align = nch * (f.bits / 8);
        } else if (id === "SSND" && o + 16 <= b.length) {
          if (!f) return null;
          return fmt(f, o + 16 + dv.getUint32(o + 8), len - 8 - dv.getUint32(o + 8));
        }

        o += 8 + len + (len & 1);
      }
    }

    return null;
  };

  // raw bytes to one or two channels of floats
  const pcmFloats = (f, ab, frames) => {
    const dv = new DataView(ab);
    const u = new Uint8Array(ab);
    const nc = Math.min(2, f.nch);
    const B = f.bits / 8;
    const out = [];

    for (let c = 0; c < nc; c++) out.push(new Float32Array(frames));

    for (let i = 0; i < frames; i++) {
      for (let c = 0; c < nc; c++) {
        const o = i * f.align + c * B;
        let v;

        if (f.float) v = B === 4 ? dv.getFloat32(o, f.le) : dv.getFloat64(o, f.le);
        else if (B === 2) v = dv.getInt16(o, f.le) / 32768;
        else if (B === 3) {
          v = f.le ? u[o] | (u[o + 1] << 8) | (u[o + 2] << 16) : (u[o] << 16) | (u[o + 1] << 8) | u[o + 2];
          if (v & 0x800000) v -= 0x1000000;
          v /= 8388608;
        } else if (B === 4) v = dv.getInt32(o, f.le) / 2147483648;
        else v = f.u8 ? (u[o] - 128) / 128 : dv.getInt8(o) / 128;

        out[c][i] = v;
      }
    }

    return out;
  };

  // A file's sound, a chunk of frames at a time. PCM WAV and AIFF are read in byte ranges, so even
  // an hour of it only ever holds a few seconds. Anything else is decoded whole, within limits.
  // Resolves to null for a file that can't be read this way.
  const openSound = async (url, ctx) => {
    const head = await fetch(url, { headers: { range: "bytes=0-131071" } });
    if (!head.ok) return null;

    const first = new Uint8Array(await head.arrayBuffer());
    const cr = head.headers.get("content-range") || "";
    const m = /\/(\d+)$/.exec(cr);
    const size = head.status === 206 && m ? Number(m[1]) : first.length;
    const f = parsePcm(first, size);

    if (f && f.frames > 0) {
      return {
        sr: f.sr,
        nch: Math.min(2, f.nch),
        total: f.frames,
        pcm: f,
        get: async (i) => {
          const a = i * CHUNK;
          const n = Math.min(CHUNK, f.frames - a);
          if (n <= 0) return [new Float32Array(0)];

          const from = f.off + a * f.align;
          const r = await fetch(url, { headers: { range: "bytes=" + from + "-" + (from + n * f.align - 1) } });
          if (r.status !== 206) throw new Error("range");

          const ab = await r.arrayBuffer();
          if (ab.byteLength < n * f.align) throw new Error("short");
          return pcmFloats(f, ab, n);
        },
      };
    }

    if (size > BIG_DECODE) return null;

    const all = head.status === 200 ? first.buffer : await (await fetch(url)).arrayBuffer();
    const ab = await new Promise((ok, no) => ctx.decodeAudioData(all, ok, no));
    if (ab.duration > LONG_DECODE) return null;

    const ch = [];
    for (let c = 0; c < Math.min(2, ab.numberOfChannels); c++) ch.push(ab.getChannelData(c));

    return {
      sr: ab.sampleRate,
      nch: ch.length,
      total: ab.length,
      pcm: null,
      get: async (i) => ch.map((d) => d.slice(i * CHUNK, Math.min(ab.length, (i + 1) * CHUNK))),
    };
  };

  const soundOn = () => !!prefs.key || !!(prefs.eq.low || prefs.eq.mid || prefs.eq.high) || spaceOn();

  // The level (dB) one EQ band adds at frequency f: the Audio EQ Cookbook formulas, which are
  // the ones Web Audio's BiquadFilterNode uses, so the curve drawn is the sound you hear.
  const bandDb = (b, gain, f) => {
    if (!gain) return 0;

    const fs = 48000;
    const [b0, b1, b2, a0, a1, a2] = coefs(b, gain, fs);
    const w = (2 * Math.PI * clamp(f, 20, 20000)) / fs;
    const c1 = Math.cos(w);
    const s1 = Math.sin(w);
    const c2 = Math.cos(2 * w);
    const s2 = Math.sin(2 * w);
    const nr = b0 + b1 * c1 + b2 * c2;
    const ni = b1 * s1 + b2 * s2;
    const dr = a0 + a1 * c1 + a2 * c2;
    const di = a1 * s1 + a2 * s2;

    return 10 * Math.log10((nr * nr + ni * ni) / (dr * dr + di * di));
  };

  const coefs = (b, gain, fs) => {
    const A = Math.pow(10, gain / 40);
    const w0 = (2 * Math.PI * b.f) / fs;
    const cs = Math.cos(w0);
    const sn = Math.sin(w0);
    let b0, b1, b2, a0, a1, a2;

    if (b.type === "peaking") {
      const al = sn / (2 * b.q);
      b0 = 1 + al * A;
      b1 = -2 * cs;
      b2 = 1 - al * A;
      a0 = 1 + al / A;
      a1 = -2 * cs;
      a2 = 1 - al / A;
    } else {
      const sq = 2 * Math.sqrt(A) * (sn / 2) * Math.SQRT2; // shelf slope 1, as in Web Audio
      const lo = b.type === "lowshelf" ? 1 : -1;
      b0 = A * (A + 1 - lo * (A - 1) * cs + sq);
      b1 = lo * 2 * A * (A - 1 - lo * (A + 1) * cs);
      b2 = A * (A + 1 - lo * (A - 1) * cs - sq);
      a0 = A + 1 + lo * (A - 1) * cs + sq;
      a1 = -lo * 2 * (A - 1 + lo * (A + 1) * cs);
      a2 = A + 1 + lo * (A - 1) * cs - sq;
    }

    return [b0, b1, b2, a0, a1, a2];
  };

  let playerN = 0;

  let activePlayer = null;

  const endPlayer = () => {
    if (activePlayer) {
      activePlayer.kill();
      activePlayer = null;
    }
  };

  const TEN =
    '<text x="12" y="16" font-size="7" font-weight="bold" fill="currentColor" text-anchor="middle" stroke="none">10</text>';

  const PLAY_PATH =
    '<path d="M8 5.14v13.72a1 1 0 0 0 1.5.86l11-6.86a1 1 0 0 0 0-1.72l-11-6.86A1 1 0 0 0 8 5.14z"/>';

  const PAUSE_PATH =
    '<rect x="6" y="4.5" width="4.2" height="15" rx="1.4"/><rect x="13.8" y="4.5" width="4.2" height="15" rx="1.4"/>';

  const I_BACK10 = SVG(
    '<path d="M3 12a9 9 0 1 0 9-9 9.75 9.75 0 0 0-6.74 2.74L3 8"/><path d="M3 3v5h5"/>' + TEN
  );

  const I_FWD10 = SVG(
    '<path d="M21 12a9 9 0 1 1-9-9 9.75 9.75 0 0 1 6.74 2.74L21 8"/><path d="M21 3v5h-5"/>' + TEN
  );

  const I_PIP = SVG(
    '<path d="M21 9V6a2 2 0 0 0-2-2H4a2 2 0 0 0-2 2v10c0 1.1.9 2 2 2h4"/><rect width="10" height="7" x="12" y="13" rx="2"/>'
  );

  const I_REPEAT = SVG(
    '<path d="m17 2 4 4-4 4"/><path d="M3 11v-1a4 4 0 0 1 4-4h14"/><path d="m7 22-4-4 4-4"/><path d="M21 13v1a4 4 0 0 1-4 4H3"/>'
  );

  const I_X = SVG('<path d="M18 6 6 18"/><path d="m6 6 12 12"/>');

  const buildMedia = (tag, mediaSrc, artUrl) => {
    const w = mkEl("div", tag === "video" ? "vw" : "aw");
    const el = mkEl(tag === "video" ? "video" : "audio");

    if (tag === "video") {
      el.setAttribute("playsinline", "");
    } else if (artUrl) {
      const im = mkEl("img");
      im.src = artUrl;
      im.alt = "";
      im.decoding = "async";
      im.onerror = () => im.remove();
      w.appendChild(im);
    }

    el.preload = "metadata";
    el.src = mediaSrc;

    // ----- state -----
    //
    // Two facts and one rule:
    //   track  = repeat the whole track
    //   abEn   = loop between A and B   (needs both points)
    //   rule   = A–B can only be on while Track Loop is on
    // A and B are remembered while A–B is off, so it can be switched back on.

    let speed = prefs.speed;
    let track = prefs.loop === "track";
    let abEn = false;
    let A = null;
    let B = null;
    let dragging = false;

    el.playbackRate = speed;

    const ready = () => A !== null && B !== null;

    // ----- centre controls -----

    const center = mkEl("div", "p-center-controls");
    const bBack = mkBtn("p-center-btn", "Back 10 seconds", I_BACK10);
    const bPlay = mkBtn(
      "p-center-play",
      "Play",
      SVG(PLAY_PATH, true, "pl") + SVG(PAUSE_PATH, true, "pa")
    );
    const bFwd = mkBtn("p-center-btn", "Forward 10 seconds", I_FWD10);

    center.append(bBack, bPlay, bFwd);

    const toggle = () => {
      if (el.paused) el.play().catch(() => {});
      else el.pause();
    };

    bPlay.onclick = (e) => {
      e.stopPropagation();
      toggle();
      wake();
    };

    bBack.onclick = (e) => {
      e.stopPropagation();
      el.currentTime = Math.max(0, el.currentTime - 10);
      wake();
    };

    bFwd.onclick = (e) => {
      e.stopPropagation();
      el.currentTime = Math.min(el.duration || 0, el.currentTime + 10);
      wake();
    };

    const sync = () => {
      bPlay.classList.toggle("playing", !el.paused);
      bPlay.setAttribute("aria-label", el.paused ? "Play" : "Pause");
    };

    // ----- the transport row -----
    //
    // Just the EQ, at the right. There is no progress rail and no running clock: where you are in
    // time shows only when you ask for it (Time Seeking on the home bar), so the player stays
    // quiet and the picture stays the picture. Speed shows (and resets) on the home bar itself.

    const ctrl = mkEl("div", "p-ctrl");

    const fracOf = (node, e) => {
      const r = node.getBoundingClientRect();
      return r.width ? clamp((e.clientX - r.left) / r.width) : 0;
    };

    // ----- toast -----

    const toast = mkEl("div", "p-toast");
    let toastT;

    const say = (t) => {
      toast.textContent = t;
      toast.classList.add("on");
      clearTimeout(toastT);
      toastT = setTimeout(() => toast.classList.remove("on"), 1300);
    };

    // ----- the home bar -----
    //
    //   [ Loop · A–B ]   or   [ 0.5× … 2× ]     only while unfolded; speed only when asked for
    //   ─────────────────────────────────       the stroke itself
    //            1.25×                          under the stroke, when speed isn't 1×
    //
    // Collapsed, only the stroke is there: no box, no border, no label. Its colour and its
    // end-beads quietly say what is on, so state is never lost.

    const hb = mkEl("div", "p-hb");
    const box = mkEl("div", "p-hbbox");
    const scrim = mkEl("div", "p-hbscrim");
    const line = mkBtn("p-hline", "Open loop controls", "<i></i>");
    const bead = mkEl("i", "p-sbead");
    const sval = mkBtn("p-hbval", "Speed — tap to reset to 1×", "");

    // Time Seeking (see below): playhead bead, A and B markers, the span between them, the time
    // that hangs under the stroke after you let go, and the ruler itself
    const tbead = mkEl("i", "p-tbead");
    const mkA = mkEl("i", "p-skmark");
    const mkB = mkEl("i", "p-skmark");
    const skReg = mkEl("i", "p-skreg");
    const tval = mkEl("span", "p-hbtime");
    const seekL = mkEl("div", "p-hbseek");
    const skTrack = mkEl("div", "p-sktrack");
    const skHint = mkEl("div", "p-skhint");
    const skRead = mkEl("div", "p-skread");
    const skTicks = mkEl("div", "p-skticks");
    const row = mkEl("div", "p-hbrow");
    const speedRow = mkEl("div", "p-hbspeed");

    const loopBtn = mkBtn("p-hloop", "Track loop", I_REPEAT + '<span class="n">Loop</span>');
    const abG = mkEl("div", "p-hab");
    const aBtn = mkBtn("p-pa", "Set loop start A", '<span class="l">A</span><i class="dot"></i>');
    const conn = mkBtn("p-pc", "A–B loop", "<i></i>");
    const bBtn = mkBtn("p-pb", "Set loop end B", '<i class="dot"></i><span class="l">B</span>');
    const clearBtn = mkBtn("p-px", "Clear A and B", I_X);
    const sTrack = mkEl("div", "p-strack");

    const cells = SPEEDS.map((v) => {
      const c = mkEl("span", "p-sv");
      c.textContent = v + "×";
      return c;
    });

    row.setAttribute("role", "group");
    row.setAttribute("aria-label", "Track loop and A–B loop");
    row.setAttribute("aria-hidden", "true");
    speedRow.setAttribute("role", "group");
    speedRow.setAttribute("aria-label", "Playback speed");
    speedRow.setAttribute("aria-hidden", "true");
    line.setAttribute("aria-expanded", "false");
    hb.dataset.open = "false";
    hb.dataset.mode = "loop";
    clearBtn.disabled = true;

    sTrack.tabIndex = 0;
    sTrack.setAttribute("role", "slider");
    sTrack.setAttribute("aria-label", "Playback speed");
    sTrack.setAttribute("aria-valuemin", String(SPEEDS[0]));
    sTrack.setAttribute("aria-valuemax", String(SPEEDS[SPEEDS.length - 1]));

    cells.forEach((c) => sTrack.appendChild(c));
    speedRow.appendChild(sTrack);

    abG.append(aBtn, conn, bBtn, clearBtn);
    row.append(loopBtn, mkEl("i", "p-sep"), abG);

    // the stroke goes in before the rows, so a control in a row always sits on top of it
    mkA.innerHTML = "<b>A</b>";
    mkB.innerHTML = "<b>B</b>";
    skTrack.append(skHint, skRead, skTicks);
    seekL.appendChild(skTrack);
    seekL.setAttribute("aria-hidden", "true"); // visual only: the stroke itself takes the arrow keys (below)

    box.append(scrim, line, skReg, bead, tbead, mkA, mkB, sval, tval, row, speedRow, seekL);
    hb.appendChild(box);

    // ----- the EQ island -----

    const eqWrap = mkEl("div", "p-eqwrap");
    const eqBtn = mkBtn("p-eqbtn", "Sound", "<i></i>");
    const eq = mkEl("div", "p-eq");
    const eqIn = mkEl("div", "p-eqin");
    const eqTop = mkEl("div", "p-eqtop");
    const eqFlat = mkBtn("p-eqflat", "Reset the EQ to flat", "Flat");
    const eqCols = mkEl("div", "p-eqcols");
    const graph = mkEl("div", "p-eqgraph");
    const bands = {};

    eq.hidden = true;
    eqFlat.hidden = true;
    eqBtn.setAttribute("aria-haspopup", "true");
    eqBtn.setAttribute("aria-expanded", "false");
    eqBtn.title = "Sound: EQ, Key, Space";

    eqTop.append(eqFlat);

    // the curve the three bands make together
    const SVGNS = "http://www.w3.org/2000/svg";
    const gradId = "p-eqgrad" + ++playerN;
    const curve = document.createElementNS(SVGNS, "svg");
    curve.setAttribute("class", "p-eqcurve");
    curve.setAttribute("aria-hidden", "true");
    curve.innerHTML =
      '<defs><linearGradient id="' + gradId + '" x1="0" y1="0" x2="0" y2="1">' +
      '<stop offset="0" stop-color="#0a84ff" stop-opacity=".34"/>' +
      '<stop offset=".5" stop-color="#0a84ff" stop-opacity=".06"/>' +
      '<stop offset="1" stop-color="#0a84ff" stop-opacity=".34"/></linearGradient></defs>' +
      '<path class="z"/><path class="f" fill="url(#' + gradId + ')"/><path class="l"/>';
    const [cZero, cFill, cLine] = curve.querySelectorAll("path");

    EQ_BANDS.forEach((b) => {
      const col = mkEl("div", "p-band");
      const val = mkEl("span", "p-bval");
      const trkB = mkEl("div", "p-btrack");
      const inn = mkEl("div", "p-bin");
      const base = mkEl("div", "p-bbase");
      const zero = mkEl("i", "p-bzero");
      const fillB = mkEl("div", "p-bfill");
      const knob = mkEl("i", "p-bknob");
      const lab = mkBtn("p-blabel", "Reset " + b.label, b.label);

      trkB.tabIndex = 0;
      trkB.setAttribute("role", "slider");
      trkB.setAttribute("aria-orientation", "vertical");
      trkB.setAttribute("aria-label", b.label + " (dB)");
      trkB.setAttribute("aria-valuemin", String(-EQ_MAX));
      trkB.setAttribute("aria-valuemax", String(EQ_MAX));

      inn.append(base, zero, fillB, knob);
      trkB.appendChild(inn);
      col.append(val, trkB, lab);
      graph.appendChild(col);

      bands[b.id] = { col, val, trk: trkB, inn, fill: fillB, knob, lab };
    });

    graph.appendChild(curve);
    eqCols.appendChild(graph);

    // Key: a ladder of semitones, up is higher, as on a stave or a piano roll. Drag up or down
    // to climb it (relative to where you are, a semitone every few pixels, so it is precise
    // under a thumb); tap above or below the bead for one semitone; tap the value to go home.
    const key = (() => {
      const col = mkEl("div", "p-band key");
      const val = mkBtn("p-bval", "Key", "");
      const trk = mkEl("div", "p-btrack");
      const inn = mkEl("div", "p-bin");
      const fill = mkEl("div", "p-bfill");
      const knob = mkEl("i", "p-bknob");
      const lab = mkEl("span", "p-blabel");

      lab.textContent = "Key";
      trk.tabIndex = 0;
      trk.setAttribute("role", "slider");
      trk.setAttribute("aria-orientation", "vertical");
      trk.setAttribute("aria-label", "Key (semitones)");
      trk.setAttribute("aria-valuemin", String(-KEY_MAX));
      trk.setAttribute("aria-valuemax", String(KEY_MAX));

      inn.append(mkEl("i", "p-kticks"), mkEl("i", "p-bzero"), fill, knob);
      trk.appendChild(inn);
      col.append(val, trk, lab);
      eqCols.appendChild(col);

      return { col, val, trk, inn, fill, knob };
    })();

    // Space: the same vertical slider as a band, filling from the bottom (dry) up. Its value is the
    // bypass (tap: dry, tap again: back to where it was); its name is the room (tap: the other one).
    const sp = (() => {
      const col = mkEl("div", "p-band space");
      const val = mkBtn("p-bval", "Space", "");
      const trk = mkEl("div", "p-btrack");
      const inn = mkEl("div", "p-bin");
      const fill = mkEl("div", "p-bfill");
      const knob = mkEl("i", "p-bknob");
      const lab = mkBtn("p-blabel", "Room", "");

      trk.tabIndex = 0;
      trk.setAttribute("role", "slider");
      trk.setAttribute("aria-orientation", "vertical");
      trk.setAttribute("aria-label", "Space (reverb amount)");
      trk.setAttribute("aria-valuemin", "0");
      trk.setAttribute("aria-valuemax", "100");

      inn.append(mkEl("div", "p-bbase"), fill, knob);
      trk.appendChild(inn);
      col.append(val, trk, lab);
      eqCols.appendChild(col);

      return { col, val, trk, inn, fill, knob, lab };
    })();

    eqIn.append(eqTop, eqCols);
    eq.appendChild(eqIn);
    eqWrap.append(eqBtn, eq);

    // The curve: x is frequency (low to high, each band's column at its own frequency), y is
    // level on the same ±15 dB scale as the beads. Drawn from the real filter response.
    let shown = { low: 0, mid: 0, high: 0 }; // the gains the curve is drawn with right now
    let curveRaf = 0;

    const drawCurve = (g) => {
      const gr = graph.getBoundingClientRect();
      if (!gr.width) return;

      const ins = EQ_BANDS.map((b) => bands[b.id].inn.getBoundingClientRect());
      const top = ins[0].top - gr.top;
      const h = ins[0].height;
      const xs = ins.map((r) => r.left + r.width / 2 - gr.left);
      const lf = EQ_BANDS.map((b) => Math.log(b.f));
      const W = gr.width;
      const yOf = (db) => top + ((EQ_MAX - clamp(db, -EQ_MAX, EQ_MAX)) / (EQ_MAX * 2)) * h;
      let d = "";

      for (let k = 0; k <= 64; k++) {
        const x = (W * k) / 64;
        const i = x < xs[1] ? 0 : 1;
        const f = Math.exp(lf[i] + ((x - xs[i]) / (xs[i + 1] - xs[i])) * (lf[i + 1] - lf[i]));
        let db = 0;

        EQ_BANDS.forEach((b) => {
          db += bandDb(b, g[b.id], f);
        });

        d += (k ? "L" : "M") + x.toFixed(1) + " " + yOf(db).toFixed(1);
      }

      const y0 = yOf(0).toFixed(1);

      curve.setAttribute("viewBox", "0 0 " + W.toFixed(1) + " " + gr.height.toFixed(1));
      cZero.setAttribute("d", "M0 " + y0 + "H" + W.toFixed(1));
      cLine.setAttribute("d", d);
      cFill.setAttribute("d", d + "L" + W.toFixed(1) + " " + y0 + "L0 " + y0 + "Z");
    };

    // the curve eases from one shape to another (opening: from the flat line it was folded as)
    const morph = (to, ms) => {
      cancelAnimationFrame(curveRaf);

      const from = { ...shown };
      const t0 = performance.now();

      const step = (now) => {
        const t = Math.min(1, (now - t0) / ms);
        const e = 1 - Math.pow(1 - t, 3);

        EQ_BANDS.forEach((b) => {
          shown[b.id] = from[b.id] + (to[b.id] - from[b.id]) * e;
        });

        drawCurve(shown);
        if (t < 1) curveRaf = requestAnimationFrame(step);
      };

      curveRaf = requestAnimationFrame(step);
    };

    ctrl.append(eqWrap);

    // ----- painting -----

    const paintSpeed = () => {
      const i = Math.max(0, SPEEDS.indexOf(speed));

      cells.forEach((c, k) => c.classList.toggle("on", k === i));
      hb.style.setProperty("--sf", String((i + 0.5) / SPEEDS.length)); // where the bead rides the stroke
      sval.textContent = speed + "×";
      sTrack.setAttribute("aria-valuenow", String(speed));
      sTrack.setAttribute("aria-valuetext", speed + "×");

      // when speed isn't 1x its value hangs under the stroke, and one tap on it puts it back
      sval.tabIndex = speed === 1 ? -1 : 0;
      hb.classList.toggle("sp", speed !== 1);
    };

    // The only place the home bar's state is painted.
    //   hb.lp   Track Loop is on      → the bar turns blue
    //   hb.pa   A is set              → a bead at the left end
    //   hb.pb   B is set              → a bead at the right end
    //   hb.ab   A–B is on             → both beads lit and the connector glows (Track Loop is on too)
    //   hb.kept A and B are remembered but A–B is off → hollow beads, dashed connector
    const paintLoop = () => {
      if (abEn && !ready()) abEn = false; // A–B needs both points…
      if (abEn) track = true; //           …and needs Track Loop
      prefs.loop = track ? "track" : "off";

      hb.classList.toggle("lp", track);
      hb.classList.toggle("pa", A !== null);
      hb.classList.toggle("pb", B !== null);
      hb.classList.toggle("ab", abEn);
      hb.classList.toggle("kept", !abEn && ready());

      loopBtn.classList.toggle("on", track);
      loopBtn.setAttribute("aria-pressed", String(track));
      loopBtn.setAttribute("aria-label", track ? "Track loop on — press to turn off" : "Track loop off — press to turn on");

      aBtn.classList.toggle("set", A !== null);
      bBtn.classList.toggle("set", B !== null);
      aBtn.setAttribute("aria-label", A === null ? "Set loop start A" : "A is " + dur(A) + " — press to set again");
      bBtn.setAttribute("aria-label", B === null ? "Set loop end B" : "B is " + dur(B) + " — press to set again");
      aBtn.title = A === null ? "Set A" : "A " + dur(A);
      bBtn.title = B === null ? "Set B" : "B " + dur(B);

      conn.classList.toggle("on", abEn);
      conn.classList.toggle("kept", !abEn && ready());
      conn.setAttribute("aria-pressed", String(abEn));
      conn.setAttribute(
        "aria-label",
        abEn ? "A–B loop on — press to turn off" : ready() ? "A–B loop off — press to turn on" : "A–B loop: set A and B first"
      );
      conn.title = ready() ? dur(A) + " – " + dur(B) : "A–B loop";

      clearBtn.disabled = A === null && B === null;

      // A–B does its own looping (it jumps at B); the native repeat is for the whole track only.
      // This flag is the only thing painted onto the media element.
      el.loop = track && !abEn;

    };

    // a quick glow on whatever just changed, so a selection can never go unnoticed
    const flash = (...nodes) => {
      nodes.forEach((node) => {
        node.classList.remove("ripple");
        void node.offsetWidth; // restart the animation
        node.classList.add("ripple");
        setTimeout(() => node.classList.remove("ripple"), 800);
      });
    };

    // ----- speed: a slider with six detents -----
    // Changing it only sets the playback rate: no pause, no seek, no restart.

    const setSpeed = (v) => {
      // see startDeck: a file Safari plays through the element itself, with Sound on
      if (v !== 1 && DECK && nodes && nodes.mode === "tap") {
        say("Speed is 1× with Sound on, for this file");
        v = 1;
      }

      speed = v;
      prefs.speed = v;
      el.playbackRate = v;
      paintSpeed();
    };

    let sDrag = false;

    const speedFrom = (e) => {
      const f = fracOf(sTrack, e);
      setSpeed(SPEEDS[Math.min(SPEEDS.length - 1, Math.floor(f * SPEEDS.length))]);
    };

    // Dragging along the speed ruler. Capture keeps every move and the release coming here
    // wherever the finger goes. Should a browser ever drop it mid-drag, the window picks up the
    // rest, but only while this drag is on, only for this finger, and never twice (events that do
    // reach the ruler are skipped there). Without that, a lost capture stalls the drag and leaves
    // it stuck on.
    let sPid = -1;

    const endSpeedDrag = (e) => {
      if (!sDrag || (e && e.pointerId !== sPid)) return;

      sDrag = false;
      sPid = -1;
      window.removeEventListener("pointermove", sWinMove);
      window.removeEventListener("pointerup", endSpeedDrag);
      window.removeEventListener("pointercancel", endSpeedDrag);
      bumpHb();
    };

    const sWinMove = (e) => {
      if (!sDrag || e.pointerId !== sPid || sTrack.contains(e.target)) return;
      speedFrom(e);
      bumpHb();
    };

    sTrack.onpointerdown = (e) => {
      sDrag = true;
      sPid = e.pointerId;

      try {
        sTrack.setPointerCapture(e.pointerId);
      } catch (x) {}

      window.addEventListener("pointermove", sWinMove);
      window.addEventListener("pointerup", endSpeedDrag);
      window.addEventListener("pointercancel", endSpeedDrag);

      speedFrom(e);
      bumpHb();
      wake();
    };

    sTrack.onpointermove = (e) => {
      if (!sDrag || e.pointerId !== sPid) return;

      // a mouse that moves with no button down: the release was missed, so the drag is over
      if (e.pointerType === "mouse" && e.buttons === 0) {
        endSpeedDrag(e);
        return;
      }

      speedFrom(e);
      bumpHb();
    };

    sTrack.onpointerup = sTrack.onpointercancel = endSpeedDrag;

    // capture dropped while the finger is still down: take it back
    sTrack.onlostpointercapture = (e) => {
      if (!sDrag || e.pointerId !== sPid) return;

      try {
        sTrack.setPointerCapture(e.pointerId);
      } catch (x) {}
    };

    sTrack.onkeydown = (e) => {
      const i = SPEEDS.indexOf(speed);
      let n = null;

      if (e.key === "ArrowLeft" || e.key === "ArrowDown") n = i - 1;
      else if (e.key === "ArrowRight" || e.key === "ArrowUp") n = i + 1;
      else if (e.key === "Home") n = 0;
      else if (e.key === "End") n = SPEEDS.length - 1;

      if (n === null) return;

      e.preventDefault();
      e.stopPropagation();
      setSpeed(SPEEDS[clamp(n, 0, SPEEDS.length - 1)]);
      bumpHb();
    };

    sval.onclick = (e) => {
      e.stopPropagation();
      setSpeed(1);
      flash(line);
      say("Speed 1×");
      bumpHb();
      wake();
    };

    // ----- looping -----
    //
    // Nothing in this section may pause, seek, reload or recreate the media. The ONLY places
    // that move the playhead are tick() / onended, and only while A–B is ON.

    let raf = 0;

    const tick = () => {
      if (abEn && !el.paused) {
        if (!dragging && el.currentTime >= B) el.currentTime = A; // (not while you are seeking)
        raf = requestAnimationFrame(tick);
      }
    };

    const watch = () => {
      cancelAnimationFrame(raf);
      if (abEn && !el.paused) raf = requestAnimationFrame(tick);
    };

    el.onended = () => {
      if (abEn) {
        el.currentTime = A;
        el.play().catch(() => {});
      }
    };

    // repaint after any change of loop state (pure bookkeeping + painting)
    const changed = (...nodes) => {
      paintLoop();
      watch();
      flash(line, ...nodes);
    };

    // Track Loop on / off. Turning it off also switches A–B off, but keeps the points.
    const pressLoop = () => {
      if (track) {
        track = false;
        abEn = false;
        say("Loop off");
      } else {
        track = true;
        say("Loop on");
      }

      changed(loopBtn);
    };

    // DISABLE A–B: stop looping between the points. The points stay. Track Loop stays.
    const disableAB = () => {
      abEn = false;
    };

    // ENABLE A–B: needs both points; switches Track Loop on as its prerequisite.
    const enableAB = () => {
      if (!ready()) return;
      abEn = true;
      track = true;
    };

    // CLEAR A/B: forget both points. A–B is off; Track Loop is left exactly as it was.
    const clearAB = () => {
      A = null;
      B = null;
      abEn = false;
    };

    // the little line between A and B
    const pressConn = () => {
      if (abEn) {
        disableAB();
        say("A–B off");
      } else if (ready()) {
        enableAB();
        say("A–B on · " + dur(A) + "–" + dur(B));
      } else {
        say(A === null ? "Set A and B first" : "Now set B");
        return;
      }

      changed(conn);
    };

    const pressClear = () => {
      clearAB();
      say("A–B cleared");
      changed(clearBtn);
    };

    const captureA = () => {
      A = el.currentTime;
      if (B !== null && B <= A + 0.3) B = null;

      if (ready()) enableAB(); // both points are there: A–B starts
      else abEn = false;

      say("A set · " + dur(A));
      changed(aBtn);
    };

    const captureB = () => {
      const now = el.currentTime;

      if (A === null) {
        // B first means "loop from the start up to here"
        if (now <= 0.5) {
          say("Play a little, then tap B");
          return;
        }

        A = 0;
        B = now;
        say("Looping 0:00–" + dur(now));
      } else if (now <= A + 0.5) {
        say("B must come after A");
        return;
      } else {
        B = now;
        say("Looping A–B");
      }

      enableAB();
      changed(bBtn);
    };

    // ----- the sound: EQ, then Key, then Space, one chain on the media element -----
    //
    //   media → Low → Mid → High ─┬─ keyDry ───────────────┬─ mix ─┬─ spDry ──────────────── out
    //                             └─ Key (worklet) ─ keyWet ┘       └─ Space (convolver) ─ wet ┘
    //
    // On Safari "media" is the deck instead (below), which also does Key and Speed itself; the
    // Key stage of the chain stays dry there.
    //
    // Built the first time you touch the EQ, Key or Space (a user gesture, so the context may run).
    // Until then the audio plays natively and untouched. With Key at 0 and Space off, the dry
    // gains are 1 and the wet stages are silent or not there at all, so what you hear is exactly
    // what the EQ alone made before.

    let nodes = null;

    const eqIsFlat = () => !prefs.eq.low && !prefs.eq.mid && !prefs.eq.high;

    const ensureEq = () => {
      if (nodes) return true;

      const AC = window.AudioContext || window.webkitAudioContext;
      if (!AC) return false;

      try {
        if (!audioCtx) {
          // iPhone: keep Web Audio audible with the ringer switch on silent
          if (navigator.audioSession) navigator.audioSession.type = "playback";
          audioCtx = new AC();
        }

        // Safari: the deck plays into this once it has sound, and the element stays as it is until
        // then. Elsewhere: the element itself.
        const src = DECK ? audioCtx.createGain() : audioCtx.createMediaElementSource(el);
        const f = {};
        let prev = src;

        EQ_BANDS.forEach((b) => {
          const n = audioCtx.createBiquadFilter();
          n.type = b.type;
          n.frequency.value = b.f;
          n.Q.value = b.q;
          n.gain.value = prefs.eq[b.id];
          prev.connect(n);
          prev = n;
          f[b.id] = n;
        });

        const keyDry = audioCtx.createGain();
        const keyWet = audioCtx.createGain();
        const mix = audioCtx.createGain();
        const spDry = audioCtx.createGain();

        keyWet.gain.value = 0;
        prev.connect(keyDry);
        keyDry.connect(mix);
        keyWet.connect(mix);
        mix.connect(spDry);
        spDry.connect(audioCtx.destination);

        nodes = { src, mode: DECK ? "deck" : "tap", tap: null, f, last: prev, keyDry, keyWet, mix, spDry, key: null, keyState: "off", sp: null };

        if (audioCtx.state !== "running") audioCtx.resume().catch(() => {});
        if (DECK) startDeck();

        // a later player picks Key and Space up where you left them
        if (prefs.key) applyKey();
        if (spaceOn()) applySpace();

        return true;
      } catch (e) {
        return false;
      }
    };

    // ----- the deck (Safari) -----
    //
    // The element keeps playing, muted, as the clock: Loop, A–B, seeking and the picture all
    // stay its own. The deck follows it: it is started, stopped, moved and sped up with it, and
    // set right again should it ever drift. It is fed the chunks around where the element is,
    // about twenty seconds ahead, and lets go of what's behind.

    let deck = null;

    const deckPost = (m) => {
      if (deck && deck.live) deck.node.port.postMessage(m);
    };

    const deckGo = () =>
      deckPost({ seek: el.currentTime, play: !el.paused && !el.seeking && !el.ended, speed: el.playbackRate });

    const chunkAt = (t) => Math.floor((t * deck.s.sr) / CHUNK);

    const goLive = () => {
      if (!deck || deck.live) return;

      deck.live = true;
      el.muted = true;
      deckGo();
    };

    const feed = () => {
      const d = deck;
      if (!d) return;

      const cur = chunkAt(el.currentTime);
      const last = Math.ceil(d.s.total / CHUNK) - 1;
      const ahead = Math.ceil(14 * Math.max(1, el.playbackRate));
      const drop = [];

      d.have.forEach((i) => {
        if (i < cur - 2 || i > cur + ahead + 2) {
          d.have.delete(i);
          drop.push(i);
        }
      });

      if (drop.length) d.node.port.postMessage({ drop });

      for (let i = Math.max(0, cur); i <= Math.min(last, cur + ahead) && d.loading.size < 2; i++) {
        if (d.have.has(i) || d.loading.has(i)) continue;

        d.loading.add(i);

        d.s.get(i).then(
          (data) => {
            d.loading.delete(i);
            if (deck !== d) return;

            d.have.add(i);
            d.node.port.postMessage({ chunk: i, data }, data.map((x) => x.buffer));
            if (!d.live && i === chunkAt(el.currentTime)) goLive();
            feed();
          },
          () => {
            d.loading.delete(i);
            if (deck === d) setTimeout(feed, 1000);
          }
        );
      }
    };

    const deckTick = (m) => {
      const d = deck;
      if (!d || !d.live || typeof m.at !== "number") return;

      if (!el.paused && !el.seeking && m.playing && Math.abs(m.at - el.currentTime) > 0.3 + 0.15 * el.playbackRate) {
        deckPost({ seek: el.currentTime });
      }

      const ci = chunkAt(el.currentTime);

      if (ci !== d.lastCi || m.miss >= 0) {
        d.lastCi = ci;
        feed();
      }
    };

    const startDeck = () => {
      const n = nodes;

      Promise.all([workletReady(), openSound(mediaSrc, audioCtx)])
        .then(([, s]) => {
          if (nodes !== n) return;
          if (!s) throw new Error("unreadable");

          const node = new AudioWorkletNode(audioCtx, "pdc-deck", {
            numberOfInputs: 0,
            numberOfOutputs: 1,
            outputChannelCount: [2],
            processorOptions: { chunk: CHUNK, total: s.total, sr: s.sr },
          });

          node.port.onmessage = (e) => deckTick(e.data || {});
          node.port.postMessage({ speed: el.playbackRate, key: prefs.key });
          node.connect(n.src);
          deck = { node, s, have: new Set(), loading: new Set(), live: false, lastCi: -1 };
          feed();
        })
        .catch(() => {
          if (nodes !== n || deck) return;

          // A file the deck can't read (too big to decode whole, say): the element feeds the
          // chain itself, at 1x, the one speed Safari passes on whole.
          try {
            const t = audioCtx.createMediaElementSource(el);
            t.connect(n.src);
            n.tap = t;
          } catch (x) {
            return;
          }

          n.mode = "tap";

          if (speed !== 1) {
            setSpeed(1);
            say("Speed is 1× with Sound on, for this file");
          }

          if (prefs.key) applyKey();
        });
    };

    ["play", "playing", "seeked"].forEach((ev) =>
      el.addEventListener(ev, () => {
        deckGo();
        feed();
      })
    );

    ["pause", "waiting", "seeking", "ended"].forEach((ev) =>
      el.addEventListener(ev, () => {
        deckPost({ play: false });
        feed();
      })
    );

    el.addEventListener("ratechange", () => {
      deckPost({ speed: el.playbackRate });
      feed();
    });

    // --- Key ---
    //
    // The processor is crossfaded in only once it has had one frame of sound to work on, and
    // crossfaded out to the untouched dry path at 0, after which it idles. The media element is
    // never paused, seeked or reloaded for any of this, and its playbackRate is never touched.

    const keyNode = () => {
      if (nodes.key) return Promise.resolve(nodes.key);

      return workletReady().then(() => {
        if (!nodes) throw new Error("gone");

        if (!nodes.key) {
          const k = new AudioWorkletNode(audioCtx, "pdc-key", {
            numberOfInputs: 1,
            numberOfOutputs: 1,
            outputChannelCount: [2],
            channelCount: 2,
            channelCountMode: "explicit",
            channelInterpretation: "speakers",
          });

          nodes.last.connect(k);
          k.connect(nodes.keyWet);
          nodes.key = k;
        }

        return nodes.key;
      });
    };

    const applyKey = () => {
      const st = prefs.key;
      const n = nodes;

      if (n.mode === "deck") {
        if (deck) deck.node.port.postMessage({ key: st });
        return;
      }

      if (!st) {
        if (n.keyState === "off") return;

        n.keyState = "off";
        n.keyDry.gain.setTargetAtTime(1, audioCtx.currentTime, 0.012);
        n.keyWet.gain.setTargetAtTime(0, audioCtx.currentTime, 0.012);

        setTimeout(() => {
          if (nodes === n && n.keyState === "off" && n.key) n.key.port.postMessage({ on: false });
        }, 150);

        return;
      }

      keyNode().then(
        (k) => {
          if (nodes !== n || !prefs.key) return;

          k.port.postMessage({ ratio: Math.pow(2, prefs.key / 12) });

          if (n.keyState !== "off") return;

          n.keyState = "warming";
          k.port.postMessage({ reset: true, on: true });

          setTimeout(() => {
            if (nodes !== n || n.keyState !== "warming") return;

            n.keyState = "on";
            n.keyDry.gain.setTargetAtTime(0, audioCtx.currentTime, 0.012);
            n.keyWet.gain.setTargetAtTime(1, audioCtx.currentTime, 0.012);
          }, 90);
        },
        () => {
          if (nodes !== n) return;

          prefs.key = 0;
          paintKey();
          paintEq();
          say("Key isn’t available in this browser");
        }
      );
    };

    const setKey = (st) => {
      st = Math.round(clamp(st, -KEY_MAX, KEY_MAX));
      if (st === prefs.key) return;

      prefs.key = st;

      if (!ensureEq()) {
        prefs.key = 0;
        say("Key isn’t available in this browser");
      } else {
        applyKey();
      }

      paintKey();
      paintEq();
    };

    // --- Space ---
    //
    // Off, the convolver is taken out of the chain, so it costs nothing. Changing the room builds
    // a new convolver and lets the old one's tail ring out on its own (no click, no gap).

    const dropRoom = (r, after) => {
      setTimeout(() => {
        try {
          r.conv.disconnect();
          r.wet.disconnect();
        } catch (x) {}
      }, after);
    };

    const applySpace = () => {
      const n = nodes;
      const t = audioCtx.currentTime;
      const m = spaceOn() ? prefs.space.mix / 100 : 0;

      if (m > 0 && (!n.sp || n.sp.room !== prefs.space.room)) {
        const old = n.sp;

        try {
          const conv = audioCtx.createConvolver();
          const wet = audioCtx.createGain();

          conv.buffer = roomIR(prefs.space.room);
          wet.gain.value = 0;
          n.mix.connect(conv);
          conv.connect(wet);
          wet.connect(audioCtx.destination);
          n.sp = { conv, wet, room: prefs.space.room };
        } catch (e) {
          say("Space isn’t available in this browser");
          return;
        }

        if (old) {
          try {
            n.mix.disconnect(old.conv);
          } catch (x) {}

          dropRoom(old, ROOMS[old.room].rt * 1200);
        }
      }

      // a little less dry as the room grows, so the whole stays about as loud
      n.spDry.gain.setTargetAtTime(1 - 0.35 * m, t, 0.02);

      if (!n.sp) return;

      if (m > 0) {
        n.sp.wet.gain.setTargetAtTime(m * 0.85, t, 0.02);
      } else {
        const r = n.sp;

        n.sp = null;
        r.wet.gain.setTargetAtTime(0, t, 0.03);

        try {
          n.mix.disconnect(r.conv);
        } catch (x) {}

        dropRoom(r, 400);
      }
    };

    const setSpace = (mix, on) => {
      const old = { ...prefs.space };

      prefs.space.mix = Math.round(clamp(mix, 0, 100));
      prefs.space.on = on;

      if (!ensureEq()) {
        prefs.space = old;
        say("Space isn’t available in this browser");
      } else {
        applySpace();
      }

      paintSpace();
      paintEq();
    };

    const paintBand = (id) => {
      const db = prefs.eq[id];
      const b = bands[id];
      const pct = ((EQ_MAX - db) / (EQ_MAX * 2)) * 100;

      b.knob.style.top = pct + "%";

      if (db >= 0) {
        b.fill.style.top = pct + "%";
        b.fill.style.height = 50 - pct + "%";
      } else {
        b.fill.style.top = "50%";
        b.fill.style.height = pct - 50 + "%";
      }

      b.val.textContent = (db > 0 ? "+" : db < 0 ? "−" : "") + Math.abs(db);
      b.col.classList.toggle("on", db !== 0);
      b.trk.setAttribute("aria-valuenow", String(db));
      b.trk.setAttribute("aria-valuetext", (db > 0 ? "+" : "") + db + " dB");
    };

    const paintKey = () => {
      const st = prefs.key;
      const txt = (st > 0 ? "+" : st < 0 ? "−" : "") + Math.abs(st);
      const pct = ((KEY_MAX - st) / (KEY_MAX * 2)) * 100;

      key.knob.style.top = pct + "%";
      key.fill.style.top = Math.min(pct, 50) + "%";
      key.fill.style.height = Math.abs(50 - pct) + "%";
      key.val.textContent = txt;
      key.val.setAttribute(
        "aria-label",
        st ? "Key " + txt + " semitones — tap to return to the original key" : "Key: original"
      );
      key.val.title = st ? "Tap for the original key" : "Original key";
      key.col.classList.toggle("on", st !== 0);
      key.trk.setAttribute("aria-valuenow", String(st));
      key.trk.setAttribute("aria-valuetext", st ? txt + " semitones" : "original key");
    };

    const paintSpace = () => {
      const m = prefs.space.mix;
      const on = spaceOn();
      const room = ROOMS[prefs.space.room].label;

      sp.knob.style.top = 100 - m + "%";
      sp.fill.style.top = 100 - m + "%";
      sp.fill.style.height = m + "%";
      sp.val.textContent = on ? m + "%" : "Off";
      sp.val.setAttribute(
        "aria-label",
        on ? "Space " + m + "% — tap to bypass" : m ? "Space bypassed — tap to bring it back" : "Space off"
      );
      sp.lab.textContent = room;
      sp.lab.setAttribute("aria-label", room + " — tap for " + (room === "Room" ? "Hall" : "Room"));
      sp.col.classList.toggle("on", on);
      sp.trk.setAttribute("aria-valuenow", String(on ? m : 0));
      sp.trk.setAttribute("aria-valuetext", on ? room + " " + m + "%" : "off");
    };

    // keepCurve: leave the curve to an animation that is under way
    const paintEq = (keepCurve) => {
      EQ_BANDS.forEach((b) => paintBand(b.id));

      const flat = eqIsFlat();
      const plain = flat && !prefs.key && !spaceOn();

      eqBtn.classList.toggle("on", !plain);
      eqFlat.hidden = flat;
      graph.classList.toggle("on", !flat);
      eqBtn.setAttribute("aria-label", plain ? "Sound (untouched)" : "Sound (shaped)");

      if (!keepCurve && !eq.hidden) {
        cancelAnimationFrame(curveRaf);
        shown = { ...prefs.eq };
        drawCurve(shown);
      }
    };

    const setBand = (id, db) => {
      db = Math.round(clamp(db, -EQ_MAX, EQ_MAX));

      const old = prefs.eq[id];
      prefs.eq[id] = db;

      if (!ensureEq()) {
        prefs.eq[id] = old;
        paintEq();
        say("EQ isn’t available in this browser");
        return;
      }

      nodes.f[id].gain.setTargetAtTime(db, audioCtx.currentTime, 0.015);
      paintEq();
    };

    let bDrag = null;

    EQ_BANDS.forEach((b) => {
      const o = bands[b.id];

      const from = (e) => {
        const r = o.inn.getBoundingClientRect();
        const f = r.height ? clamp((e.clientY - r.top) / r.height) : 0.5;
        setBand(b.id, EQ_MAX - f * EQ_MAX * 2);
      };

      o.trk.onpointerdown = (e) => {
        bDrag = b.id;

        try {
          o.trk.setPointerCapture(e.pointerId);
        } catch (x) {}

        from(e);
        bumpEq();
        wake();
      };

      o.trk.onpointermove = (e) => {
        if (bDrag !== b.id) return;
        from(e);
        bumpEq();
      };

      o.trk.onpointerup = o.trk.onpointercancel = () => {
        bDrag = null;
        bumpEq();
      };

      o.trk.onkeydown = (e) => {
        const db = prefs.eq[b.id];
        let n = null;

        if (e.key === "ArrowUp") n = db + 1;
        else if (e.key === "ArrowDown") n = db - 1;
        else if (e.key === "PageUp") n = db + 3;
        else if (e.key === "PageDown") n = db - 3;
        else if (e.key === "Home") n = EQ_MAX;
        else if (e.key === "End") n = -EQ_MAX;
        else if (e.key === "0" || e.key === "Backspace") n = 0;

        if (n === null) return;

        e.preventDefault();
        e.stopPropagation();
        setBand(b.id, n);
        bumpEq();
      };

      // tap a band's name to put just that band back to flat
      o.lab.onclick = (e) => {
        e.stopPropagation();
        setBand(b.id, 0);
        flash(o.col);
        bumpEq();
      };
    });

    eqFlat.onclick = (e) => {
      e.stopPropagation();
      EQ_BANDS.forEach((b) => setBand(b.id, 0));
      say("EQ flat");
      bumpEq();
    };

    const KEY_PX = 9; // finger travel per semitone
    let kg = null;

    key.trk.onpointerdown = (e) => {
      kg = { id: e.pointerId, y: e.clientY, st: prefs.key, moved: false };
      bDrag = "key";

      try {
        key.trk.setPointerCapture(e.pointerId);
      } catch (x) {}

      bumpEq();
      wake();
    };

    key.trk.onpointermove = (e) => {
      if (!kg || e.pointerId !== kg.id) return;

      const dy = kg.y - e.clientY;

      if (!kg.moved && Math.abs(dy) < 5) return;

      kg.moved = true;
      setKey(kg.st + Math.round(dy / KEY_PX));
      bumpEq();
    };

    key.trk.onpointerup = (e) => {
      if (kg && !kg.moved) {
        // a tap: one semitone towards where you tapped
        const r = key.knob.getBoundingClientRect();
        const mid = r.top + r.height / 2;

        if (e.clientY < mid - 3) setKey(prefs.key + 1);
        else if (e.clientY > mid + 3) setKey(prefs.key - 1);
      }

      kg = null;
      bDrag = null;
      bumpEq();
    };

    key.trk.onpointercancel = () => {
      kg = null;
      bDrag = null;
    };

    key.trk.onkeydown = (e) => {
      let n = null;

      if (e.key === "ArrowUp") n = prefs.key + 1;
      else if (e.key === "ArrowDown") n = prefs.key - 1;
      else if (e.key === "PageUp") n = prefs.key + 12;
      else if (e.key === "PageDown") n = prefs.key - 12;
      else if (e.key === "0" || e.key === "Backspace" || e.key === "Home") n = 0;

      if (n === null) return;

      e.preventDefault();
      e.stopPropagation();
      setKey(n);
      bumpEq();
    };

    key.val.onclick = (e) => {
      e.stopPropagation();
      if (!prefs.key) return;
      say("Original key");
      setKey(0);
      flash(key.col);
      bumpEq();
    };

    const spFrom = (e) => {
      const r = sp.inn.getBoundingClientRect();
      const f = r.height ? clamp((e.clientY - r.top) / r.height) : 1;
      setSpace((1 - f) * 100, true);
    };

    sp.trk.onpointerdown = (e) => {
      bDrag = "space";

      try {
        sp.trk.setPointerCapture(e.pointerId);
      } catch (x) {}

      spFrom(e);
      bumpEq();
      wake();
    };

    sp.trk.onpointermove = (e) => {
      if (bDrag !== "space") return;
      spFrom(e);
      bumpEq();
    };

    sp.trk.onpointerup = sp.trk.onpointercancel = () => {
      bDrag = null;
      bumpEq();
    };

    sp.trk.onkeydown = (e) => {
      const m = spaceOn() ? prefs.space.mix : 0;
      let n = null;

      if (e.key === "ArrowUp") n = m + 5;
      else if (e.key === "ArrowDown") n = m - 5;
      else if (e.key === "PageUp") n = m + 20;
      else if (e.key === "PageDown") n = m - 20;
      else if (e.key === "Home") n = 100;
      else if (e.key === "End" || e.key === "0" || e.key === "Backspace") n = 0;

      if (n === null) return;

      e.preventDefault();
      e.stopPropagation();
      setSpace(n, true);
      bumpEq();
    };

    // the value is the bypass: dry and back, keeping the amount
    sp.val.onclick = (e) => {
      e.stopPropagation();
      if (!prefs.space.mix) return;
      setSpace(prefs.space.mix, !prefs.space.on);
      say(spaceOn() ? "Space on" : "Space bypassed");
      flash(sp.col);
      bumpEq();
    };

    // the name is the room
    sp.lab.onclick = (e) => {
      e.stopPropagation();
      prefs.space.room = prefs.space.room === "room" ? "hall" : "room";
      if (nodes && spaceOn()) applySpace();
      paintSpace();
      say(ROOMS[prefs.space.room].label);
      flash(sp.col);
      bumpEq();
    };

    // ----- the gestures on the home bar -----
    //
    //                  mouse (macOS, or any pointer)       touch (iPhone, iPad, pen)
    //   rest           just the stroke                     just the stroke
    //   hover          unfolds to Loop · A–B               (no hover)
    //   click / tap    Speed (click again: Loop · A–B)     1st tap: Loop · A–B
    //                                                      2nd tap: Speed   3rd tap: Loop · A–B
    //   press and hold  Time Seeking (ruler opens at now)   Time Seeking (ruler opens at now)
    //   two fingers     swipe on the trackpad: Time Seeking  two fingers on the stroke, swipe: Time Seeking
    //
    // Hover never changes anything but the fold. A tap or click never seeks: seeking needs a press
    // that is held (0.22s with a mouse, 0.4s with a finger), which opens the ruler where you are,
    // and then slides along the stroke; or two fingers swiping along it. A single finger that moves
    // before the hold is a swipe and is ignored. The bar folds itself after a few
    // quiet seconds, when you tap elsewhere, or on Escape; Speed hands back to Loop · A–B after a
    // few quiet seconds of its own. < and > on the keyboard bring Speed up too.

    let hbOpen = false;
    let hbMode = "loop"; // what the bar shows: "loop" (Track Loop · A–B), "speed", or "seek" (the ruler)
    let modeT = 0;
    let hbT = 0;
    let hbEnterT = 0;
    let hbEnterArmed = false;
    let hbHover = false;

    let g = null; // the press that is on the stroke right now
    let holdT = 0;
    let ptype = ""; // who pressed last: "mouse", "touch", or "" for the keyboard
    let suppressClick = false; // a press that turned into a seek (or a swipe) is not also a click
    let tDrag = false; // a time seek is under way
    let sk = null; // the seek session (ruler geometry, window, position)
    let seekT = 0;
    let liveT = 0;
    let lastSeekAt = 0;
    let tFlashT = 0;
    let seekEndAt = -1e9;

    let eqOpen = false;
    let eqT = 0;
    let eqEnterT = 0;
    let hoverEqBtn = false;
    let hoverEq = false;

    // paint which of the two layers is showing, and what tapping the stroke would do next
    const paintMode = () => {
      hb.dataset.mode = hbMode;
      row.setAttribute("aria-hidden", String(!hbOpen || hbMode !== "loop"));
      speedRow.setAttribute("aria-hidden", String(!hbOpen || hbMode !== "speed"));

      line.setAttribute(
        "aria-label",
        !hbOpen
          ? "Open loop controls"
          : hbMode === "loop"
          ? "Playback speed"
          : hbMode === "speed"
          ? "Back to loop controls"
          : "Seeking"
      );
    };

    const setHb = (on) => {
      hbOpen = on;
      hb.dataset.open = on ? "true" : "false";
      line.setAttribute("aria-expanded", String(on));
      w.classList.toggle("tools", on);
      paintMode();
    };

    // Speed hands the bar back to Loop · A–B after a few quiet seconds (never mid-drag).
    const armMode = () => {
      clearTimeout(modeT);

      modeT = setTimeout(() => {
        if (sDrag) armMode();
        else setMode("loop");
      }, 5200);
    };

    const setMode = (m) => {
      hbMode = m;
      clearTimeout(modeT);
      paintMode();
      if (m === "speed") armMode();
    };

    const hideHb = () => {
      clearTimeout(hbT);
      clearTimeout(modeT); // the mode is left as it is while the bar folds; the next unfold resets it
      setHb(false);
      wake();
    };

    // Opening: the stroke rises to the height of what it holds; the controls are uncovered
    // leftwards out of it; the beads travel up from rest and the curve swells out of the flat
    // line, so the shaping you left reappears as if it had been inside the stroke all along.
    // Closing runs the same story backwards, quicker.
    let eqShowT = 0;
    let travels = [];
    const still = () => !!(window.matchMedia && matchMedia("(prefers-reduced-motion: reduce)").matches);
    const EASE = "cubic-bezier(.2,.9,.25,1.04)";

    // every bead (and the fills that follow Key and Space), with where it rests when folded
    const beads = () => [
      ...EQ_BANDS.map((b) => [bands[b.id].knob, { top: "50%" }]),
      [key.knob, { top: "50%" }],
      [key.fill, { top: "50%", height: "0%" }],
      [sp.knob, { top: "100%" }],
      [sp.fill, { top: "100%", height: "0%" }],
    ];

    const stopTravels = () => {
      travels.forEach((a) => a.cancel());
      travels = [];
    };

    // the beads travel between rest and where they were left (Web Animations, so the browser
    // can never skip the starting point the way a style change on a just-shown element can be)
    const travel = (rising, ms) => {
      stopTravels();
      if (!document.body.animate) return;

      beads().forEach(([el, rest]) => {
        const left = {};
        Object.keys(rest).forEach((k) => {
          left[k] = el.style[k] || rest[k];
        });

        travels.push(
          el.animate(rising ? [rest, left] : [left, rest], { duration: ms, easing: EASE, fill: rising ? "none" : "forwards" })
        );
      });
    };

    const paintSound = (keepCurve) => {
      paintEq(keepCurve);
      paintKey();
      paintSpace();
    };

    const setEq = (on) => {
      if (on === eqOpen) return;

      eqOpen = on;
      hb.classList.toggle("away", on);
      eqBtn.setAttribute("aria-expanded", String(on));
      clearTimeout(eqShowT);

      const calm = still();

      if (on) {
        stopTravels();
        eq.hidden = false;
        paintSound(true);
        eqWrap.style.setProperty("--sph", eqIn.offsetHeight + "px");

        if (calm) {
          paintEq();
        } else {
          cancelAnimationFrame(curveRaf);
          shown = { low: 0, mid: 0, high: 0 };
          drawCurve(shown);
          travel(true, 520);
          morph(prefs.eq, 520);
        }

        eqWrap.classList.add("open");
        return;
      }

      eqWrap.classList.remove("open");

      if (!calm) {
        travel(false, 240);
        morph({ low: 0, mid: 0, high: 0 }, 240);
      }

      eqShowT = setTimeout(() => {
        if (eqOpen) return;
        cancelAnimationFrame(curveRaf);
        stopTravels();
        eq.hidden = true;
      }, calm ? 0 : 320);
    };

    // a finger on a bead mid-flight takes it from there
    eq.addEventListener("pointerdown", () => stopTravels(), true);

    // ----- two fingers on a trackpad, upright -----
    //
    // The vertical twin of the swipe on the home bar, at the same sensitivity: one pixel of
    // fingers is one pixel of control, exactly as one pixel is one pixel of ruler there. Over a
    // band, Key or Space, swiping up raises it and down lowers it, following the fingers whatever
    // "natural scrolling" is set to. Over the folded stroke, swiping up unfolds it. The swipe is
    // over when the wheel events stop coming. Sideways swipes are left alone.

    let vs = null; // { col, from, sum, t }

    const colOf = (t) => {
      const c = t && t.closest && t.closest(".p-band");
      if (!c) return null;
      if (c === key.col) return "key";
      if (c === sp.col) return "space";
      const b = EQ_BANDS.find((x) => bands[x.id].col === c);
      return b ? b.id : null;
    };

    const valueOf = (c) => (c === "key" ? prefs.key : c === "space" ? (spaceOn() ? prefs.space.mix : 0) : prefs.eq[c]);

    const wheelUp = (e) => {
      const k = e.deltaMode === 1 ? 16 : e.deltaMode === 2 ? 400 : 1;
      const inverted = e.webkitDirectionInvertedFromDevice !== false;
      return { up: (inverted ? e.deltaY : -e.deltaY) * k, side: Math.abs(e.deltaX) > Math.abs(e.deltaY) * 1.2 };
    };

    eqWrap.addEventListener(
      "wheel",
      (e) => {
        if (e.ctrlKey) return; // a pinch

        const w2 = wheelUp(e);

        if (!eqOpen) {
          if (w2.side || !e.target.closest(".p-eqbtn")) return;
          e.preventDefault();
          if (w2.up > 8) showEq(4000);
          return;
        }

        if (!vs) {
          if (w2.side) return;
          const c = colOf(e.target);
          if (!c) return;
          vs = { col: c, from: valueOf(c), sum: 0, t: 0 };
        }

        e.preventDefault(); // (also keeps the page from scrolling, or going Back)
        if (w2.side) return;

        vs.sum += w2.up;

        if (vs.col === "key") {
          setKey(vs.from + Math.round(vs.sum / KEY_PX));
        } else {
          const h = (vs.col === "space" ? sp.inn : bands[vs.col].inn).getBoundingClientRect().height || 100;

          if (vs.col === "space") setSpace(vs.from + (vs.sum / h) * 100, true);
          else setBand(vs.col, vs.from + (vs.sum / h) * EQ_MAX * 2);
        }

        bumpEq();
        wake();
        clearTimeout(vs.t);
        vs.t = setTimeout(() => {
          vs = null;
        }, 180);
      },
      { passive: false }
    );

    const hideEq = () => {
      clearTimeout(eqT);
      setEq(false);
      wake();
    };

    const showHb = (ms = 4500, mode) => {
      if (eqOpen) hideEq(); // one tray at a time
      if (!hbOpen) hbMode = "loop"; // every unfold starts with Loop · A–B…
      if (mode) hbMode = mode; //      …unless speed is what was asked for
      setHb(true);
      if (mode === "speed") armMode();
      clearTimeout(hbT);

      hbT = setTimeout(() => {
        if (hbHover || sDrag || tDrag) showHb(1200);
        else hideHb();
      }, ms);

      wake();
    };

    const showEq = (ms = 4000) => {
      if (hbOpen) hideHb();
      setEq(true);
      clearTimeout(eqT);

      eqT = setTimeout(() => {
        if (hoverEqBtn || hoverEq || bDrag) showEq(1200);
        else hideEq();
      }, ms);

      wake();
    };

    const bumpHb = () => {
      if (!hbOpen) return;
      showHb(4500);
      if (hbMode === "speed") armMode();
    };

    const bumpEq = () => {
      if (eqOpen) showEq(4000);
    };

    // Resting on the bar unfolds it a moment later. (One timer at a time.)
    const armEnter = () => {
      if (hbEnterArmed) return;

      hbEnterArmed = true;

      hbEnterT = setTimeout(() => {
        hbEnterArmed = false;
        if (hbHover && !sk) showHb(4500);
      }, 130);
    };

    const cancelEnter = () => {
      clearTimeout(hbEnterT);
      hbEnterArmed = false;
    };

    box.addEventListener("pointerenter", (e) => {
      if (e.pointerType !== "mouse") return;

      hbHover = true;
      cancelEnter();
      armEnter();
    });

    box.addEventListener("pointerleave", (e) => {
      if (e.pointerType !== "mouse") return;

      hbHover = false;
      cancelEnter();
      if (hbOpen && !sk) showHb(900);
    });

    // Browsers only report "entered" and "left" when they next look under the pointer, and the bar
    // changes size under a resting pointer (the ruler collapses when a seek ends), so those
    // reports can be stale. Any movement over the bar is proof the pointer is on it.
    box.addEventListener("pointermove", (e) => {
      if (e.pointerType !== "mouse" || sk || g) return;

      hbHover = true;

      if (!hbOpen && performance.now() - seekEndAt > 250) armEnter();
    });

    // ----- Time Seeking -----
    //
    // Press and hold the stroke and it becomes a temporary time ruler for the media's own length,
    // showing where you are right now. Keep holding and slide along it to move through time from
    // there. It is not a progress bar: it exists only while you hold, and is put away when you let
    // go, leaving the media where you left it (or, if you never moved, exactly where it was).
    //
    //   - until you move, the ruler is LIVE: the playhead follows the playback, so holding still
    //     just shows you where you are, and letting go changes nothing
    //   - the first movement hands the playhead to your finger, measured from where you are then
    //   - the ruler is as wide as the screen sensibly allows, with ticks and labels chosen to fit
    //     (0:00 5:00 10:00 … for a concerto, 0:00 0:30 1:00 … for a clip, 0:00 20:00 40:00 … for a film)
    //   - one pixel of finger is one pixel of ruler, starting from where the media is now
    //   - slide up and the ruler zooms in around where you are (4×, 16×, 64×), so a long recording
    //     can be settled on to the second: coarse first, then fine
    //   - A and B show up on it, and the playhead is drawn to them like a magnet when it passes

    const NICE = [1, 2, 5, 10, 15, 30, 60, 120, 300, 600, 900, 1200, 1800, 3600, 7200, 14400, 28800];
    const MINOR = { 1: 1, 2: 2, 5: 5, 10: 5, 15: 3, 30: 6, 60: 6, 120: 4, 300: 5, 600: 5, 900: 3, 1200: 4, 1800: 6, 3600: 6, 7200: 4, 14400: 4, 28800: 4 };
    const ZOOMS = [1, 4, 16, 64];
    // how long a press has to last to be a hold: longer than any ordinary click or tap, so those
    // never get taken for one
    const HOLD = { mouse: 220, touch: 400 };

    // ticks and labels for whatever stretch of time the ruler is showing right now
    const buildRuler = () => {
      // Pick the smallest "nice" step whose labels still fit: each label needs its own width plus
      // some air, and a ruler never carries more than about eight stretches however wide it is.
      // (A little tolerance, because a 30:00 file is often 1800.04 seconds long.)
      const lblW = dur(sk.win0 + sk.L).length * 6.6 + 18;
      const maxStretches = clamp(Math.floor(sk.W / lblW), 3, 8);
      let step = NICE[NICE.length - 1];

      for (let i = 0; i < NICE.length; i++) {
        if (sk.L / NICE[i] <= maxStretches * 1.02) {
          step = NICE[i];
          break;
        }
      }

      const sub = step / (MINOR[step] || 1);
      const end = sk.win0 + sk.L;
      const frag = document.createDocumentFragment();

      for (let k = Math.ceil(sk.win0 / sub - 1e-9); k * sub <= end + 1e-9; k++) {
        const t = k * sub;
        const major = Math.abs(t / step - Math.round(t / step)) < 1e-6;

        if (!major && (sk.W * sub) / sk.L < 6) continue; // too crowded to be worth drawing

        const at = ((t - sk.win0) / sk.L) * 100 + "%";
        const tk = mkEl("i", major ? "p-sktk M" : "p-sktk");
        tk.style.left = at;
        frag.appendChild(tk);

        if (major) {
          const lb = mkEl("span", "p-sklb");
          lb.textContent = dur(t);
          lb.style.left = at;
          frag.appendChild(lb);
        }
      }

      skTicks.replaceChildren(frag);
    };

    const paintHint = () => {
      skHint.textContent = sk.live
        ? "slide to seek"
        : sk.maxLvl === 0
        ? ""
        : sk.lvl === 0
        ? "slide up for finer control"
        : "finer · " + ZOOMS[sk.lvl] + "×";
    };

    const markOnRuler = (node, t) => {
      const x = t === null ? -1 : (t - sk.win0) / sk.L;
      const on = x >= 0 && x <= 1;

      node.classList.toggle("on", on);
      if (on) node.style.setProperty("--x", String(x));
    };

    // the playhead, the readout that follows it, A and B, and the span between them
    const paintSeek = () => {
      const f = clamp((sk.t - sk.win0) / sk.L);
      const half = 42;

      hb.style.setProperty("--tx", String(f));
      skRead.textContent = (sk.snap ? sk.snap + " · " : "") + dur(sk.t);
      skRead.style.left = clamp(f * sk.W, half - sk.pad + 4, sk.W + sk.pad - half - 4) + "px";

      markOnRuler(mkA, A);
      markOnRuler(mkB, B);

      const both = A !== null && B !== null && B > A;

      if (both) {
        const x0 = clamp((A - sk.win0) / sk.L);
        const x1 = clamp((B - sk.win0) / sk.L);

        skReg.style.setProperty("--x0", String(x0));
        skReg.style.setProperty("--w", String(Math.max(0, x1 - x0)));
      }

      hb.classList.toggle("hasreg", both);
    };

    // the media itself is asked to move at most every 90ms, and always lands on the last value
    const applySeek = (t, force) => {
      const now = performance.now();

      clearTimeout(seekT);

      if (force || now - lastSeekAt > 90) {
        lastSeekAt = now;
        el.currentTime = t;
      } else {
        seekT = setTimeout(() => {
          lastSeekAt = performance.now();
          el.currentTime = t;
        }, 90);
      }
    };

    // sliding up zooms the ruler around the playhead; the playhead keeps its place on screen
    const rezoom = (lvl, clientX) => {
      const f = clamp((sk.t - sk.win0) / sk.L);

      sk.lvl = lvl;
      sk.L = lvl === 0 ? sk.d : sk.d / ZOOMS[lvl];
      sk.win0 = lvl === 0 ? 0 : clamp(sk.t - f * sk.L, 0, sk.d - sk.L);
      sk.x0 = clientX; // from here the finger is measured against the new scale
      sk.t0 = sk.t;

      buildRuler();
      paintHint();
    };

    const seekMove = (e) => {
      if (sk.live) {
        // A held finger is never perfectly still. Movement smaller than this is the finger
        // settling, not you sliding: ignore it, and the ruler stays live.
        const slop = g && g.kind === "mouse" ? 3 : 6;

        if (Math.abs(e.clientX - sk.x0) < slop && Math.abs(e.clientY - g.y0) < slop) return;

        // the first real movement: from here your finger decides where we are, measured from where
        // the playback is at this moment (so nothing jumps)
        sk.live = false;
        clearInterval(liveT);
        sk.t = sk.t0 = el.currentTime;
        sk.x0 = e.clientX;
        paintHint();
      }

      const up = Math.max(0, sk.lineY - e.clientY);
      const want = up < sk.u ? 0 : up < sk.u * 2.4 ? 1 : up < sk.u * 4 ? 2 : 3;
      const lvl = Math.min(want, sk.maxLvl);

      if (lvl !== sk.lvl) rezoom(lvl, e.clientX);

      let t = clamp(sk.t0 + ((e.clientX - sk.x0) * sk.L) / sk.W, sk.win0, sk.win0 + sk.L);

      sk.snap = "";

      [["A", A], ["B", B]].forEach((m) => {
        if (m[1] !== null && (Math.abs(m[1] - t) * sk.W) / sk.L < 7) {
          t = m[1];
          sk.snap = m[0];
        }
      });

      sk.t = t;
      paintSeek();
      applySeek(t);
    };

    // Opens the ruler. Every way of seeking (a held press, two fingers, a trackpad swipe) comes
    // through here, so they all get the same ruler, zoom and snapping. x0 is where the finger
    // (or the pretend finger of a swipe) is when it starts. Returns false if there is no time to
    // move through (a live stream, or nothing loaded yet).
    const beginSeek = (x0, live) => {
      const d = el.duration;

      if (!isFinite(d) || d <= 0) return false;

      tDrag = true;
      dragging = true; // A–B stops jumping back while you are seeking
      clearTimeout(modeT);
      clearTimeout(hbT);
      clearTimeout(tFlashT);
      hb.classList.remove("tshow");

      if (eqOpen) hideEq();

      // The ruler's geometry comes from the width the stroke is about to have, not from measuring
      // it mid-animation.
      const cs = getComputedStyle(hb);
      const padL = parseFloat(cs.paddingLeft) || 0;
      const padR = parseFloat(cs.paddingRight) || 0;
      const room = hb.clientWidth - padL - padR;
      const target = Math.min(parseFloat(cs.getPropertyValue("--hbs")) || 640, room);
      const pad = Math.max(26, Math.ceil(dur(d).length * 3.6) + 10);
      const lr = line.getBoundingClientRect();

      sk = {
        d: d,
        pad: pad,
        W: Math.max(120, target - pad * 2),
        lvl: 0,
        win0: 0,
        L: d,
        maxLvl: ZOOMS.reduce((m, z, i) => (d / z >= 10 ? i : m), 0),
        t: el.currentTime,
        t0: el.currentTime,
        x0: x0,
        lineY: lr.top + lr.height / 2,
        u: clamp(innerHeight * 0.1, 34, 64),
        snap: "",
        live: !!live,
      };

      hb.style.setProperty("--skpad", pad + "px");
      hbMode = "seek";
      setHb(true);
      hb.classList.add("seeking");

      buildRuler();
      paintHint();
      paintSeek();
      wake();

      // held still: the playhead keeps following the playback until you move
      clearInterval(liveT);

      if (sk.live) {
        liveT = setInterval(() => {
          if (!sk || !sk.live) return;
          sk.t = sk.t0 = el.currentTime;
          paintSeek();
        }, 100);
      }

      return true;
    };

    // a press that was held (the ruler opens where you are), or a mouse that clearly dragged
    const startSeek = (live) => {
      suppressClick = true;

      if (beginSeek(g.x0, live)) g.seeking = true;
      else g.dead = true;
    };

    // the time you landed on hangs under the stroke for a moment, then goes
    const flashTime = (t) => {
      tval.textContent = dur(t);
      hb.classList.add("tshow");
      clearTimeout(tFlashT);
      tFlashT = setTimeout(() => hb.classList.remove("tshow"), 1700);
    };

    const finishSeek = () => {
      const s = sk;

      sk = null;
      clearTimeout(seekT);
      clearInterval(liveT);

      // land exactly where the finger let go. (Held still and let go: nothing to do at all, the
      // media has just carried on playing.)
      if (!s.live) el.currentTime = clamp(s.t, 0, s.d);
      tDrag = false;
      dragging = false;
      seekEndAt = performance.now();

      hb.classList.remove("seeking", "hasreg");
      hbHover = false; // the bar is about to shrink under the pointer: don't trust the old hover
      cancelEnter();
      hideHb(); // back to the quiet stroke

      flashTime(s.live ? el.currentTime : s.t);
    };

    // ----- the press itself -----

    // where the fingers (or the one finger) on the stroke are, as one point
    const centroid = () => {
      const p = Object.keys(g.pos).map((k) => g.pos[k]);

      return {
        clientX: p.reduce((a, q) => a + q.x, 0) / p.length,
        clientY: p.reduce((a, q) => a + q.y, 0) / p.length,
      };
    };

    line.addEventListener("pointerdown", (e) => {
      if (e.button) return; // the main button, or a touch contact

      // A second finger on the stroke: two fingers swiping along it are the same as hold-and-drag,
      // with no hold needed. The two fingers count as one point, halfway between them.
      if (g && g.kind === "touch" && e.pointerType !== "mouse" && !g.two && !ws) {
        const c0 = centroid();

        g.pos[e.pointerId] = { x: e.clientX, y: e.clientY };
        g.two = true;
        suppressClick = true; // two fingers are never a tap
        clearTimeout(holdT);

        try {
          line.setPointerCapture(e.pointerId);
        } catch (x) {}

        const c = centroid();

        g.cx0 = c.clientX;
        g.cy0 = c.clientY;

        // already seeking with the first finger: carry on from here, without a jump
        if (g.seeking) {
          sk.x0 = c.clientX;
          sk.t0 = sk.t;
        }

        return;
      }

      ptype = e.pointerType === "mouse" ? "mouse" : "touch"; // a pen behaves like a finger
      suppressClick = false;
      clearTimeout(holdT);

      g = {
        id: e.pointerId,
        kind: ptype,
        x0: e.clientX,
        y0: e.clientY,
        seeking: false,
        dead: false,
        two: false,
        pos: {},
      };

      g.pos[e.pointerId] = { x: e.clientX, y: e.clientY };

      try {
        line.setPointerCapture(e.pointerId);
      } catch (x) {}

      window.addEventListener("pointermove", winMove);
      window.addEventListener("pointerup", winEnd);
      window.addEventListener("pointercancel", winEnd);

      holdT = setTimeout(() => {
        if (!g || g.dead || g.seeking || g.two) return;
        startSeek(true); // held: the ruler opens right here, at where you are
      }, HOLD[ptype]);
    });

    const onLineMove = (e) => {
      if (!g || !g.pos[e.pointerId]) return;

      // a mouse that moves with no button down: the release was missed, so the press is over
      if (e.pointerType === "mouse" && e.buttons === 0) {
        endPress(e);
        return;
      }

      g.pos[e.pointerId] = { x: e.clientX, y: e.clientY };

      if (g.two) {
        const c = centroid();

        // the two fingers have to actually travel along the stroke before the ruler opens
        if (!g.seeking && !g.dead && Math.abs(c.clientX - g.cx0) >= 6) {
          suppressClick = true;

          if (beginSeek(g.cx0)) g.seeking = true;
          else g.dead = true;
        }

        if (g.seeking) {
          seekMove(c);
          wake();
        }

        return;
      }

      if (e.pointerId !== g.id) return;

      if (g.seeking) {
        seekMove(e);
        wake();
        return;
      }

      if (g.dead) return;

      const dx = e.clientX - g.x0;
      const dy = e.clientY - g.y0;

      if (g.kind === "mouse") {
        // a mouse that clearly drags is seeking, held or not
        if (Math.abs(dx) >= 14) {
          startSeek(false);
          if (g.seeking) seekMove(e);
        }
      } else if (Math.hypot(dx, dy) > 12) {
        // a finger that moves before the hold is a swipe, not a hold: leave it alone
        g.dead = true;
        suppressClick = true;
        clearTimeout(holdT);
      }
    };

    line.addEventListener("pointermove", onLineMove);

    // Capture keeps every move and the release coming to the stroke wherever the finger goes.
    // Should a browser ever drop it mid-press, these pick up the rest from the window: only while a
    // press is on, and never twice (events that do reach the stroke are skipped here).
    const winMove = (e) => {
      if (g && !line.contains(e.target)) onLineMove(e);
    };

    const winEnd = (e) => {
      if (g && !line.contains(e.target)) endPress(e);
    };

    // lifting any finger is letting go
    const endPress = (e) => {
      if (!g || !g.pos[e.pointerId]) return;

      const was = g;

      g = null;
      clearTimeout(holdT);
      window.removeEventListener("pointermove", winMove);
      window.removeEventListener("pointerup", winEnd);
      window.removeEventListener("pointercancel", winEnd);

      if (was.seeking) finishSeek();
      else if (was.dead || was.two) suppressClick = true;

      Object.keys(was.pos).forEach((id) => {
        try {
          line.releasePointerCapture(Number(id));
        } catch (x) {}
      });
    };

    line.addEventListener("pointerup", endPress);
    line.addEventListener("pointercancel", endPress);
    line.addEventListener("lostpointercapture", (e) => {
      if (!g || !g.pos[e.pointerId]) return; // after a normal release the press has already ended

      // dropped while the finger is still down: take it back, a few times at most
      g.recaptured = (g.recaptured || 0) + 1;

      if (g.recaptured <= 3) {
        try {
          line.setPointerCapture(e.pointerId);
          return;
        } catch (x) {}
      }

      endPress(e); // it really is gone
    });
    line.addEventListener("contextmenu", (e) => e.preventDefault());

    // ----- two fingers on a trackpad -----
    //
    // Two fingers swiping sideways over the bar do what hold-and-drag does: left moves earlier,
    // right moves later, and the swipe's own speed gives coarse and fine for free (a slow swipe
    // moves a little, a fast one a lot). Two fingers swiping up zoom the ruler, as sliding up does.
    // The swipe is over when the wheel events stop coming.
    //
    // It follows the fingers, not the scroll direction: the same swipe goes the same way whichever
    // way "natural scrolling" is set. Chrome and Safari report which way it is; elsewhere (Firefox)
    // the macOS default, natural scrolling, is assumed.

    let ws = null; // the swipe in progress: { sum, up, x0, seeking, t }

    const endWheel = () => {
      if (!ws) return;

      const w = ws;

      ws = null;
      clearTimeout(w.t);

      if (w.seeking) finishSeek();
    };

    box.addEventListener(
      "wheel",
      (e) => {
        if (e.ctrlKey || g) return; // a pinch arrives as ctrl+wheel; a press is already in charge

        const k = e.deltaMode === 1 ? 16 : e.deltaMode === 2 ? 400 : 1;
        const dx = e.deltaX * k;
        const dy = e.deltaY * k;
        const inverted = e.webkitDirectionInvertedFromDevice !== false;
        const fingerX = inverted ? -dx : dx; // + = the fingers moved right
        const fingerUp = inverted ? dy : -dy; // + = the fingers moved up
        const sideways = Math.abs(dx) > Math.abs(dy) * 1.2;

        if (!ws) {
          if (!sideways) return; // plain vertical scrolling is none of our business

          const d = el.duration;

          if (!isFinite(d) || d <= 0) return;

          ws = { sum: 0, up: 0, x0: 0, seeking: false, t: 0 };
        }

        // (this also stops the browser turning a two-finger swipe into Back / Forward)
        e.preventDefault();

        if (sideways) ws.sum += fingerX;
        else if (Math.abs(dy) > Math.abs(dx) * 0.6) ws.up = clamp(ws.up + fingerUp, 0, 400);

        if (!ws.seeking && Math.abs(ws.sum) >= 8) {
          const lr = line.getBoundingClientRect();

          ws.x0 = lr.left + lr.width / 2;

          if (beginSeek(ws.x0)) ws.seeking = true;
          else {
            ws = null;
            return;
          }
        }

        if (ws.seeking) {
          seekMove({ clientX: ws.x0 + ws.sum, clientY: sk.lineY - ws.up });
          wake();
        }

        clearTimeout(ws.t);
        ws.t = setTimeout(endWheel, 180);
      },
      { passive: false }
    );

    // Keyboard: with the stroke focused, ← and → move 5 seconds and Home and End go to the ends.
    // (The old scrubber was the keyboard's way to seek; the stroke is the one time surface now.)
    line.addEventListener("keydown", (e) => {
      const d = el.duration;

      if (!isFinite(d) || !d) return;

      let t = null;

      if (e.key === "ArrowLeft") t = el.currentTime - 5;
      else if (e.key === "ArrowRight") t = el.currentTime + 5;
      else if (e.key === "Home") t = 0;
      else if (e.key === "End") t = d;

      if (t === null) return;

      e.preventDefault();
      e.stopPropagation(); // arrows seek here instead of changing file
      t = clamp(t, 0, d);
      el.currentTime = t;
      flashTime(t);
      wake();
    });

    // A click is a tap that did not turn into anything else. With a pointer, hovering already
    // showed Loop · A–B, so a click asks for Speed. With a finger (or the keyboard) the first tap
    // unfolds Loop · A–B, the second asks for Speed, and the third goes back.
    line.onclick = (e) => {
      e.stopPropagation();

      const kind = ptype;

      ptype = "";

      if (suppressClick) {
        suppressClick = false;
        return;
      }

      if (kind === "mouse") {
        if (hbOpen && hbMode === "speed") {
          setMode("loop");
          bumpHb();
        } else {
          showHb(4500, "speed");
        }
      } else if (!hbOpen) {
        showHb(4500);
      } else {
        setMode(hbMode === "loop" ? "speed" : "loop");
        bumpHb();
      }

      wake();
    };

    // every control inside: do its job, keep the bar open a little longer
    const act = (fn) => (e) => {
      e.stopPropagation();
      fn();
      bumpHb();
      wake();
    };

    loopBtn.onclick = act(pressLoop);
    conn.onclick = act(pressConn);
    clearBtn.onclick = act(pressClear);
    aBtn.onclick = act(captureA);
    bBtn.onclick = act(captureB);

    eqBtn.addEventListener("pointerenter", (e) => {
      if (e.pointerType !== "mouse") return;

      hoverEqBtn = true;
      clearTimeout(eqEnterT);
      eqEnterT = setTimeout(() => showEq(4000), 200);
    });

    eqBtn.addEventListener("pointerleave", (e) => {
      if (e.pointerType !== "mouse") return;

      hoverEqBtn = false;
      clearTimeout(eqEnterT);
      if (eqOpen) showEq(1200);
    });

    eq.addEventListener("pointerenter", (e) => {
      if (e.pointerType === "mouse") hoverEq = true;
    });

    eq.addEventListener("pointerleave", (e) => {
      if (e.pointerType !== "mouse") return;

      hoverEq = false;
      if (eqOpen) showEq(1200);
    });

    eqBtn.onclick = (e) => {
      e.stopPropagation();
      if (eqOpen) hideEq();
      else showEq(5000);
    };

    // ----- picture in picture: lives in the top bar -----

    const canPip =
      tag === "video" &&
      (!!document.pictureInPictureEnabled || typeof el.webkitSetPresentationMode === "function");

    let pipBtn = null;

    if (canPip) {
      pipBtn = mkBtn("p-pip", "Picture in picture", I_PIP);

      pipBtn.onclick = async (e) => {
        e.stopPropagation();

        try {
          if (document.pictureInPictureElement) {
            await document.exitPictureInPicture();
          } else if (el.requestPictureInPicture) {
            await el.requestPictureInPicture();
          } else {
            el.webkitSetPresentationMode(
              el.webkitPresentationMode === "picture-in-picture" ? "inline" : "picture-in-picture"
            );
          }
        } catch (x) {}
      };

      $("topr").appendChild(pipBtn);
    } else if (tag === "video") {
      // hides Firefox's own black PiP toggle, which can't be styled
      el.disablePictureInPicture = true;
      el.setAttribute("disablepictureinpicture", "");
    }

    // ----- chrome fades while playing; it stays up while a tray is open or you drag -----

    const chrome = [ctrl, center, hb];
    let hideT;

    const wake = () => {
      chrome.forEach((c) => {
        c.style.opacity = "1";
      });

      clearTimeout(hideT);

      if (!el.paused && !dragging && !sDrag && !bDrag && !hbOpen && !eqOpen) {
        hideT = setTimeout(() => {
          chrome.forEach((c) => {
            c.style.opacity = "0";
          });
        }, 2500);
      }
    };

    el.onplay = () => {
      sync();
      watch();

      // a suspended context would silence a connected element: wake it on the play gesture
      if (nodes && audioCtx && audioCtx.state !== "running") audioCtx.resume().catch(() => {});

      wake();
    };

    el.onpause = () => {
      sync();
      cancelAnimationFrame(raf);
      wake();
    };

    // (with the CSS above) a held finger never becomes a text selection or a callout menu
    w.addEventListener("selectstart", (e) => e.preventDefault());
    w.addEventListener("contextmenu", (e) => {
      if (e.target.closest(".p-eqwrap") || e.target.closest(".p-hb")) e.preventDefault();
    });

    w.onmousemove = wake;
    w.ontouchstart = wake;

    w.onclick = (e) => {
      if (performance.now() - seekEndAt < 450) return; // the tail of a seek drag is not a tap

      const inTools = e.target.closest(".p-hb") || e.target.closest(".p-eq") || e.target.closest(".p-eqbtn");

      if ((hbOpen || eqOpen) && !inTools) {
        // tapping away only folds the trays back
        if (hbOpen) hideHb();
        if (eqOpen) hideEq();
        return;
      }

      if (!e.target.closest(".p-ctrl") && !e.target.closest(".p-center-controls") && !inTools) {
        toggle();
      }

      wake();
    };

    w.append(el, center, hb, ctrl, toast);

    // a later player picks the EQ up where you left it (the context already runs)
    if (audioCtx && (!eqIsFlat() || prefs.key || spaceOn())) ensureEq();

    paintSpeed();
    paintKey();
    paintSpace();
    paintLoop();
    paintEq();
    sync();

    activePlayer = {
      toggle,
      note: say,
      toggleLoop: () => {
        pressLoop();
        wake();
      },
      captureA: () => {
        captureA();
        wake();
      },
      captureB: () => {
        captureB();
        wake();
      },
      speedStep: (dir) => {
        setSpeed(SPEEDS[clamp(SPEEDS.indexOf(speed) + dir, 0, SPEEDS.length - 1)]);
        // speed appears where you can see it, then folds away; a bar you already had open on
        // Loop · A–B keeps its usual time
        showHb(hbOpen && hbMode !== "speed" ? 4500 : 2400, "speed");
      },
      // Escape folds an open tray first; returns true if it did, so the viewer stays open
      closeTools: () => {
        if (hbOpen) {
          hideHb();
          return true;
        }

        if (eqOpen) {
          hideEq();
          return true;
        }

        return false;
      },
      kill: () => {
        clearTimeout(hideT);
        clearTimeout(toastT);
        clearTimeout(hbT);
        clearTimeout(modeT);
        clearTimeout(hbEnterT);
        clearTimeout(holdT);
        clearTimeout(seekT);
        clearInterval(liveT);
        window.removeEventListener("pointermove", winMove);
        window.removeEventListener("pointerup", winEnd);
        window.removeEventListener("pointercancel", winEnd);
        window.removeEventListener("pointermove", sWinMove);
        window.removeEventListener("pointerup", endSpeedDrag);
        window.removeEventListener("pointercancel", endSpeedDrag);
        if (ws) clearTimeout(ws.t);
        clearTimeout(tFlashT);
        clearTimeout(eqT);
        clearTimeout(eqEnterT);
        cancelAnimationFrame(raf);
        if (pipBtn) pipBtn.remove();

        if (deck) {
          try {
            deck.node.port.postMessage({ end: true });
            deck.node.disconnect();
          } catch (x) {}

          deck = null;
        }

        if (nodes) {
          const n = nodes;

          nodes = null;

          try {
            if (n.tap) n.tap.disconnect();
            n.src.disconnect();
            Object.keys(n.f).forEach((k) => n.f[k].disconnect());
            [n.keyDry, n.keyWet, n.mix, n.spDry].forEach((x) => x.disconnect());

            if (n.key) {
              n.key.port.postMessage({ end: true });
              n.key.disconnect();
            }

            if (n.sp) {
              n.sp.conv.disconnect();
              n.sp.wet.disconnect();
            }
          } catch (x) {}
        }
      },
    };

    return w;
  };


  // ---------- thumbnails / media ----------

  const media = (f, mini) => {
    const k = kind(f);

    if (k === "img") {
      const i = new Image();
      i.src = src(f);
      i.alt = "";
      i.loading = "lazy";
      i.decoding = "async";
      return i;
    }

    if (k === "vid") {
      const v = document.createElement("video");
      v.muted = true;
      v.setAttribute("muted", "");
      v.setAttribute("playsinline", "");
      v.preload = "metadata";
      v.src = src(f) + "#t=0.1";
      return v;
    }

    const ph = () => {
      const d = mkEl("span", mini ? "doc mini" : "doc");

      if (!mini) {
        d.appendChild(icon(ext(f)));

        const s = document.createElement("small");
        s.textContent = f.name;
        d.appendChild(s);
      }

      return d;
    };

    if (k === "aud") {
      const artwork = artSrc(f);

      if (artwork) {
        const i = new Image();
        i.className = "art";
        i.src = artwork;
        i.alt = "";
        i.loading = "lazy";
        i.decoding = "async";

        // no embedded cover: try a same-named image, else show the file icon
        let retried = false;

        i.onerror = () => {
          if (!retried) {
            retried = true;
            if (f.art === artwork) f.noart = true;

            const next = artSrc(f);

            if (next && next !== artwork) {
              i.src = next;
              return;
            }
          }

          i.replaceWith(ph());
        };

        return i;
      }
    }

    const d = ph();

    if (isPdf(f)) {
      pdfThumb(f)
        .then((u) => {
          const im = new Image();
          im.src = u;
          im.alt = "";
          im.className = "pdfimg";
          im.decoding = "async";
          d.replaceWith(im);
        })
        .catch(() => {});
    }

    return d;
  };

  // ---------- tiles (ready ones and still-uploading ones) ----------

  const CIRC = 2 * Math.PI * 18;

  const GLY = {
    img: '<rect x="3" y="3" width="18" height="18" rx="3"/><circle cx="9" cy="9" r="1.8"/><path d="m21 15-3.1-3.1a2 2 0 0 0-2.8 0L6 21"/>',
    vid: '<path d="M9 6.5v11l9-5.5z"/>',
    aud: '<path d="M9 18V5l12-2v13"/><circle cx="6" cy="18" r="3"/><circle cx="18" cy="16" r="3"/>',
    doc: '<path d="M14.5 2H6a2 2 0 0 0-2 2v16a2 2 0 0 0 2 2h12a2 2 0 0 0 2-2V7.5z"/><path d="M14 2v6h6"/>',
  };

  const noun = (f) =>
    ({ img: "photo", vid: "video", aud: "audio file", doc: isPdf(f) ? "document" : "file" })[kind(f)];

  const ringHTML = (f) =>
    '<span class="ring"><svg class="rsvg" viewBox="0 0 44 44"><circle class="rt" cx="22" cy="22" r="18"/><circle class="rp" cx="22" cy="22" r="18"/></svg>' +
    SVG(GLY[kind(f)], false, "gly") +
    "</span>";

  const paintPending = (b, f) => {
    const ring = b.querySelector(".ring");
    const rp = b.querySelector(".rp");
    const pct = b.querySelector(".dur");

    if (!ring) return;

    const p = typeof f.progress === "number" ? clamp(f.progress) : null;

    b.classList.toggle("failed", !!f.failed);
    b.classList.toggle("stalled", !!f.stalled && !f.failed);
    ring.classList.toggle("indet", p === null && !f.failed && !f.stalled);

    rp.style.strokeDasharray = String(CIRC);
    rp.style.strokeDashoffset = String(CIRC * (1 - (p === null ? 0.28 : p)));

    // a failed upload is a full red ring with an exclamation mark, not a partial arc
    if (f.failed) {
      rp.style.strokeDashoffset = "0";
      const g = b.querySelector(".gly");
      if (g) g.innerHTML = '<path d="M12 7.5v6.5"/><path d="M12 17.5h.01"/>';
    }

    pct.hidden = p === null || !!f.failed;
    pct.textContent = Math.round((p || 0) * 100) + "%";

    b.setAttribute(
      "aria-label",
      (f.failed ? "Couldn’t upload " : f.stalled ? "Upload paused: " : "Uploading ") + f.name
    );
  };

  const fillTile = (b, f) => {
    b.replaceChildren();
    b.classList.toggle("pending", !!f.pending);
    b.classList.remove("failed", "stalled");
    b.setAttribute("aria-label", f.name);

    if (f.pending) {
      b.innerHTML = '<span class="shim"></span>' + ringHTML(f) + '<span class="dur" hidden></span>';
      paintPending(b, f);
      return;
    }

    const m = media(f);
    b.appendChild(m);

    if (kind(f) === "vid") {
      const d = mkEl("span", "dur");

      m.addEventListener("loadedmetadata", () => {
        if (isFinite(m.duration)) d.textContent = dur(m.duration);
      });

      b.appendChild(d);
    }

    b.appendChild(mkEl("span", "chk"));
  };

  const picked = new Set();
  let selecting = false;

  const readyItems = () => items.filter((f) => !f.pending);

  const label = () => {
    dl.textContent = picked.size ? "Download (" + picked.size + ")" : "Download";
    dl.disabled = !readyItems().length;
    del.textContent = selecting && picked.size ? "Delete (" + picked.size + ")" : "Delete";
    del.classList.toggle("on", selecting && picked.size > 0);
    del.disabled = !readyItems().length;
  };

  const tapTile = (f, b) => {
    if (!selecting) return openAt(items.indexOf(f));
    if (f.pending) return;

    if (picked.has(f.n)) picked.delete(f.n);
    else picked.add(f.n);

    b.classList.toggle("on", picked.has(f.n));
    label();
  };

  const buildTile = (f) => {
    const b = mkEl("button", "tile");
    b.type = "button";
    b.dataset.n = f.n;
    fillTile(b, f);
    b.onclick = () => tapTile(f, b);
    return b;
  };

  const tileOf = (f) => grid.querySelector('[data-n="' + f.n + '"]');

  // ---------- header card, footer, hero ----------

  const refreshInfo = () => {
    const ready = readyItems();
    const pend = items.filter((f) => f.pending);
    const total = items.length;
    const noun1 = total === 1 ? " item" : " items";

    let txt = pend.length && ready.length ? ready.length + " of " + total + noun1 : total + noun1;

    if (pend.length) {
      txt += pend.every((f) => f.failed)
        ? " · upload failed"
        : pend.every((f) => f.stalled)
        ? " · paused"
        : " · uploading…";
    }

    $("owner").textContent = G.heading || "Shared by " + G.owner;
    $("count").textContent = txt;
    $("exp").textContent = G.exp ? "Expires " + D(G.exp, { day: "numeric", month: "long" }) : "";

    const c = { img: 0, vid: 0, aud: 0, doc: 0 };
    ready.forEach((f) => c[kind(f)]++);

    $("foot").textContent = [["Photo", c.img], ["Video", c.vid], ["Audio", c.aud], ["File", c.doc]]
      .filter((x) => x[1])
      .map((x) => x[1] + " " + x[0] + (x[1] > 1 ? "s" : ""))
      .join(", ");

    label();
  };

  let heroBuilt = false;

  const ensureHero = () => {
    if (heroBuilt) return;

    const i = items.findIndex((f) => !f.pending && kind(f) !== "doc");
    if (i < 0) return;

    heroBuilt = true;

    const f = items[i];

    hero.hidden = false;
    hero.prepend(media(f));
    $("hdate").textContent = D(f.taken, { day: "numeric", month: "short" });
    hero.onclick = () => openAt(items.indexOf(f));
  };

  // ---------- viewer ----------

  let cur = 0;
  let thumbs = null;
  let x0 = null;

  const build = () => {
    if (thumbs) return;

    thumbs = items.map((f, i) => {
      const b = mkEl("button", "th" + (f.pending ? " pending" : ""));
      b.type = "button";
      b.setAttribute("aria-label", f.name);
      if (!f.pending) b.appendChild(media(f, true));
      b.onclick = () => show(i);
      strip.appendChild(b);
      return b;
    });
  };

  // the iCloud message: shown when you open something that's still uploading
  const pendingText = (f) =>
    f.failed
      ? ["Upload unavailable.", G.owner + "’s shared " + noun(f) + " didn’t finish uploading."]
      : ["Please check back soon.", G.owner + " is uploading a shared " + noun(f) + "…"];

  const paintPendingView = (d, f) => {
    const t = pendingText(f);
    const p = typeof f.progress === "number" ? Math.round(clamp(f.progress) * 100) : null;

    d.children[0].textContent = t[0];
    d.children[1].textContent = t[1];
    d.children[2].hidden = !!f.failed || p === null;
    d.children[2].textContent = p === null ? "" : p >= 100 ? "Finishing…" : p + "% uploaded";
  };

  const pendingView = (f) => {
    const d = mkEl("div", "pw");
    d.innerHTML = "<b></b><span></span><small></small>";
    paintPendingView(d, f);
    return d;
  };

  const show = (i) => {
    if (!items.length) return;

    cur = (i + items.length) % items.length;

    const f = items[cur];
    const k = kind(f);
    const s = src(f);

    if (killPdf) {
      killPdf();
      killPdf = null;
    }

    endPlayer();
    stage.replaceChildren();
    meta.hidden = true;

    $("t1").textContent =
      Date.now() - f.taken < 6 * 864e5
        ? D(f.taken, { weekday: "long" })
        : D(f.taken, { day: "numeric", month: "short", year: "numeric" });

    $("t2").textContent = T(f.taken);

    if (f.pending) {
      stage.appendChild(pendingView(f));
    } else if (k === "img") {
      const im = new Image();
      im.src = s;
      im.alt = f.name;
      im.decoding = "async";
      stage.appendChild(im);
    } else if (k === "vid") {
      stage.appendChild(buildMedia("video", s));
    } else if (k === "aud") {
      stage.appendChild(buildMedia("audio", s, artSrc(f)));
    } else if (isPdf(f)) {
      stage.appendChild(buildPdf(f));
    } else {
      stage.appendChild(docView(f));
    }

    if (thumbs) {
      thumbs.forEach((t, j) => t.classList.toggle("on", j === cur));
      strip.scrollLeft = thumbs[cur].offsetLeft - (strip.clientWidth - 30) / 2;
    }
  };

  const openAt = (i) => {
    if (i < 0) return;

    build();
    lb.hidden = false;
    document.body.style.overflow = "hidden";
    history.pushState({ lb: 1 }, "");
    show(i);
  };

  const hide = () => {
    lb.hidden = true;

    if (killPdf) {
      killPdf();
      killPdf = null;
    }

    endPlayer();
    stage.replaceChildren();
    document.body.style.overflow = "";
  };

  $("sel").onclick = () => {
    selecting = !selecting;
    picked.clear();

    document.body.classList.toggle("selecting", selecting);
    $("sel").textContent = selecting ? "Cancel" : "Select";

    grid.querySelectorAll(".on").forEach((t) => t.classList.remove("on"));
    label();
  };

  dl.onclick = async () => {
    const list = picked.size ? readyItems().filter((f) => picked.has(f.n)) : readyItems();

    if (!list.length) return;

    if (list.length === 1) {
      location.href = src(list[0]) + "?dl=1";
      return;
    }

    // a folder can hold far more than a browser can zip in memory
    if (list.reduce((t, f) => t + (f.size || 0), 0) > 2e9) {
      alert("That's more than 2 GB. Select fewer files to download them as a zip.");
      return;
    }

    dl.textContent = "Zipping...";

    try {
      const mod = await import("https://cdn.jsdelivr.net/npm/client-zip@2.5.0/index.js");
      const seen = {};
      const entries = [];

      for (const f of list) {
        let nm = f.name;

        seen[nm] = (seen[nm] || 0) + 1;
        if (seen[nm] > 1) nm = seen[nm] + "-" + nm;

        entries.push({
          name: nm,
          lastModified: new Date(f.taken),
          input: await fetch(src(f)),
        });
      }

      const blob = await mod.downloadZip(entries).blob();
      const a = document.createElement("a");

      a.href = URL.createObjectURL(blob);
      a.download = G.zip || "Gallery.zip";
      a.click();
    } catch (e) {
      alert("Download failed. Open a file to download it on its own.");
    }

    label();
  };

  // ---------- owner controls: Upload (Main) and Delete (everywhere) ----------
  //
  // Visitors never see these. On Main the owner is known; on a public link the page asks
  // /main/api/whoami, which only answers once the owner has signed in to Main.

  const say = (text, bad) => {
    note.textContent = text || "";
    note.hidden = !text;
    note.classList.toggle("bad", !!bad);
  };

  const showOwner = () => {
    del.hidden = false;
    if (G.main) up.hidden = false;
    label();
  };

  if (G.main) showOwner();
  else
    fetch("/main/api/whoami", { redirect: "manual", cache: "no-store" })
      .then((r) => r.ok && showOwner())
      .catch(() => {});

  del.onclick = async () => {
    if (!selecting) return $("sel").onclick();

    const list = readyItems().filter((f) => picked.has(f.n));
    if (!list.length) return;

    const what = list.length === 1 ? "“" + list[0].name + "”" : list.length + " items";
    const ask = G.main
      ? "Delete " + what + "? Deleted files stay in the trash for 30 days."
      : "Delete " + what + " from this link? This can't be undone.";

    if (!confirm(ask)) return;

    del.disabled = true;
    let done = 0;

    try {
      if (G.main) {
        for (const f of list) {
          const r = await fetch("/main/api/file?" + new URLSearchParams({ key: f.path }), { method: "DELETE" });
          if (!r.ok) throw new Error((await r.text()) || "Delete failed");
          done++;
        }
      } else {
        const q = new URLSearchParams({ id: G.id });
        list.forEach((f) => q.append("item", f.path || f.n));
        const r = await fetch("/main/api/link?" + q, { method: "DELETE" });
        if (!r.ok) throw new Error((await r.text()) || "Delete failed");
        done = list.length;
      }

      location.reload();
    } catch (e) {
      say("Stopped after " + done + " of " + list.length + ": " + (e.message || e), true);
      del.disabled = false;
    }
  };

  up.onclick = () => upin.click();

  upin.onchange = async () => {
    const files = Array.from(upin.files || []);
    upin.value = "";
    if (!files.length) return;

    const big = files.filter((f) => f.size > G.uploadMax);

    if (big.length) {
      say(
        (big.length === 1 ? big[0].name + " is" : big.length + " files are") +
          " too big for the browser. Add " +
          (big.length === 1 ? "it" : "them") +
          " through the Gallery folder on your Mac.",
        true
      );
      return;
    }

    const keyOf = (f) => (G.dir ? G.dir + "/" : "") + f.name;
    const clash = files.filter((f) => items.some((x) => x.path === keyOf(f)));

    if (
      clash.length &&
      !confirm((clash.length === 1 ? "“" + clash[0].name + "” is" : clash.length + " files are") + " already here. Replace?")
    ) {
      return;
    }

    up.disabled = true;
    let done = 0;

    try {
      for (const file of files) {
        say("Uploading " + (done + 1) + " of " + files.length + "…");

        const q = new URLSearchParams({ key: keyOf(file), mtime: String(file.lastModified || Date.now()) });
        const r = await fetch("/main/api/file?" + q, {
          method: "PUT",
          headers: { "content-type": file.type || "application/octet-stream" },
          body: file,
        });

        if (!r.ok) throw new Error((await r.text()) || "Upload failed");
        done++;
      }

      location.reload();
    } catch (e) {
      say("Upload stopped after " + done + " of " + files.length + ": " + (e.message || e), true);
      up.disabled = false;
    }
  };

  $("back").onclick = () => history.back();
  $("prev").onclick = () => show(cur - 1);
  $("next").onclick = () => show(cur + 1);


  // ----- downloads with the sound baked in -----
  //
  // With Key, EQ or Space on, downloading an audio file gives it as you hear it: EQ, then Key,
  // then Space, the same stages and settings as the player, worked out here a stretch at a time
  // (so a long recording never has to be held whole) into a WAV at the file's own sample rate
  // and length. EQ and Key run straight in this page, carrying on from one stretch to the next
  // (Key with the player's own phase vocoder); Space is rendered by the browser, each stretch
  // given the sound before it so the room's tail carries over. Speed isn't baked in: the file
  // keeps its length. Video always downloads as it is.
  const OAC = window.OfflineAudioContext || window.webkitOfflineAudioContext;
  let keyClass = null;

  // the player's Key processor, run here instead of in an AudioWorklet
  const pageKey = async (sr) => {
    if (!keyClass) {
      const code = await (await fetch("/player/key.js?v=" + G.version)).text();

      class Shim {
        constructor() {
          this.port = { postMessage() {}, onmessage: null };
        }
      }

      new Function("AudioWorkletProcessor", "registerProcessor", "sampleRate", code)(
        Shim,
        (name, c) => {
          if (name === "pdc-key") keyClass = c;
        },
        sr
      );
    }

    return keyClass;
  };

  const bakeName = (f, set) => {
    const bits = [];

    if (set.key) bits.push("Key " + (set.key > 0 ? "+" : "−") + Math.abs(set.key));
    if (set.eq.low || set.eq.mid || set.eq.high) bits.push("EQ");
    if (set.mix) bits.push(ROOMS[set.room].label + " " + Math.round(set.mix * 100) + "%");

    return f.name.replace(/\.[^.]+$/, "") + " (" + bits.join(", ") + ").wav";
  };

  const bake = async (f, set, progress) => {
    const s = await openSound(src(f), audioCtx || new OAC(2, 1, 44100));
    if (!s) return null;

    const sr = s.sr;
    const total = s.total;
    const bytes = s.pcm && (s.pcm.bits >= 24 || s.pcm.float) ? 3 : 2;
    const SEG = 4 * CHUNK;

    // EQ: the same biquads as Web Audio's, carried across stretches
    const eqs = EQ_BANDS.filter((b) => set.eq[b.id]).map((b) => {
      const [b0, b1, b2, a0, a1, a2] = coefs(b, set.eq[b.id], sr);
      return { k: [b0 / a0, b1 / a0, b2 / a0, a1 / a0, a2 / a0], z: [new Float64Array(4), new Float64Array(4)] };
    });

    const eq = (x, c) => {
      eqs.forEach((q) => {
        const [b0, b1, b2, a1, a2] = q.k;
        const z = q.z[c];
        let [x1, x2, y1, y2] = z;

        for (let i = 0; i < x.length; i++) {
          const y = b0 * x[i] + b1 * x1 + b2 * x2 - a1 * y1 - a2 * y2;
          x2 = x1;
          x1 = x[i];
          y2 = y1;
          y1 = y;
          x[i] = y;
        }

        z.set([x1, x2, y1, y2]);
      });
    };

    // Key: its output runs LAT frames behind, so the first LAT are skipped and LAT of silence
    // pushed through at the end
    const LAT = 2048 - 256;
    let kp = null;
    let skip = 0;

    if (set.key) {
      const K = await pageKey(sr);
      kp = new K({ processorOptions: { ratio: Math.pow(2, set.key / 12), on: true } });
      skip = LAT;
    }

    const key = (L, R) => {
      if (!kp) return [L, R];

      const oL = new Float32Array(L.length);
      const oR = new Float32Array(L.length);

      kp.process([[L, R]], [[oL, oR]]);

      const k = Math.min(skip, oL.length);
      skip -= k;
      return [oL.subarray(k), oR.subarray(k)];
    };

    // Space: each stretch rendered after the room's length of what came before it
    const PRE = set.mix ? Math.ceil((ROOMS[set.room].rt * 1.1 + ROOMS[set.room].pre) * sr) + 128 : 0;
    const hist = [new Float32Array(PRE), new Float32Array(PRE)];
    const ir = set.mix ? irData(set.room, sr) : null;

    const space = async (L, R) => {
      if (!set.mix || !L.length) return [L, R];

      const len = PRE + L.length;
      const oc = new OAC(2, len, sr);
      const buf = oc.createBuffer(2, len, sr);
      const irb = oc.createBuffer(2, ir[0].length, sr);

      [L, R].forEach((x, c) => {
        const d = buf.getChannelData(c);
        d.set(hist[c]);
        d.set(x, PRE);

        // what comes before the next stretch
        if (len >= PRE) hist[c].set(d.subarray(len - PRE));

        irb.getChannelData(c).set(ir[c]);
      });

      const bs = oc.createBufferSource();
      const dry = oc.createGain();
      const conv = oc.createConvolver();
      const wet = oc.createGain();

      bs.buffer = buf;
      conv.buffer = irb;
      dry.gain.value = 1 - 0.35 * set.mix;
      wet.gain.value = 0.85 * set.mix;
      bs.connect(dry);
      dry.connect(oc.destination);
      bs.connect(conv);
      conv.connect(wet);
      wet.connect(oc.destination);
      bs.start(0);

      const r = await new Promise((ok, no) => {
        oc.oncomplete = (e) => ok(e.renderedBuffer);
        const pr = oc.startRendering();
        if (pr && pr.catch) pr.catch(no);
      });

      return [r.getChannelData(0).slice(PRE), r.getChannelData(1).slice(PRE)];
    };

    let parts = [];
    let done = new Blob([]); // folded into a Blob as it goes, which the browser may keep on disk
    let written = 0;

    const write = (L, R) => {
      const n = Math.min(L.length, total - written);
      if (n <= 0) return;

      const out = new Uint8Array(n * 2 * bytes);
      let o = 0;

      const full = bytes === 2 ? 32767 : 8388607;

      for (let i = 0; i < 2 * n; i++) {
        const x = (i & 1 ? R : L)[i >> 1];
        const q = Math.round((x > 1 ? 1 : x < -1 ? -1 : x) * full);

        out[o++] = q & 255;
        out[o++] = (q >> 8) & 255;
        if (bytes === 3) out[o++] = (q >> 16) & 255;
      }

      parts.push(out);
      written += n;

      if (parts.length >= 16) {
        done = new Blob([done].concat(parts));
        parts = [];
      }
    };

    for (let a = 0; a < total; a += SEG) {
      const ch = [[], []];
      const end = Math.min(total, a + SEG);

      for (let i = a / CHUNK; i * CHUNK < end; i++) {
        const d = await s.get(i);
        ch[0].push(d[0]);
        ch[1].push(d[1] || d[0]);
      }

      const join = (list) => {
        const x = new Float32Array(end - a);
        let o = 0;
        list.forEach((y) => {
          x.set(y.subarray(0, x.length - o), o);
          o += y.length;
        });
        return x;
      };

      const L = join(ch[0]);
      const R = join(ch[1]);

      eq(L, 0);
      eq(R, 1);

      const [kL, kR] = key(L, R);
      const [sL, sR] = await space(kL, kR);

      write(sL, sR);
      progress(end / total);
      await new Promise((ok) => setTimeout(ok, 0)); // let the page breathe between stretches
    }

    if (kp) {
      const [kL, kR] = key(new Float32Array(LAT), new Float32Array(LAT));
      const [sL, sR] = await space(kL, kR);
      write(sL, sR);
    }

    const h = new DataView(new ArrayBuffer(44));
    const str = (o, t) => [...t].forEach((c, i) => h.setUint8(o + i, c.charCodeAt(0)));
    const size = written * 2 * bytes;

    str(0, "RIFF");
    h.setUint32(4, 36 + size, true);
    str(8, "WAVE");
    str(12, "fmt ");
    h.setUint32(16, 16, true);
    h.setUint16(20, 1, true);
    h.setUint16(22, 2, true);
    h.setUint32(24, sr, true);
    h.setUint32(28, sr * 2 * bytes, true);
    h.setUint16(32, 2 * bytes, true);
    h.setUint16(34, bytes * 8, true);
    str(36, "data");
    h.setUint32(40, size, true);

    return new Blob([h.buffer, done].concat(parts), { type: "audio/wav" });
  };

  let baking = false;
  let baked = null; // the last one, so tapping download again doesn't work it all out again

  const bakeDownload = async (f) => {
    const set = { key: prefs.key, eq: Object.assign({}, prefs.eq), mix: spaceOn() ? prefs.space.mix / 100 : 0, room: prefs.space.room };
    const id = f.n + JSON.stringify(set);
    const btn = $("save");
    const tell = (t) => activePlayer && activePlayer.note(t);

    const give = (b) => {
      const a = document.createElement("a");
      a.href = URL.createObjectURL(b.blob);
      a.download = b.name;
      document.body.appendChild(a);
      a.click();
      a.remove();
      setTimeout(() => URL.revokeObjectURL(a.href), 60000);
    };

    if (baked && baked.id === id) return give(baked);
    if (baking) return;

    baking = true;
    btn.classList.add("busy");
    tell("Preparing the download with your sound");

    try {
      const blob = await bake(f, set, (p) => tell("Preparing the download… " + Math.round(p * 100) + "%"));

      if (!blob) {
        tell("Too long to bake the sound into, so here’s the original");
        location.href = src(f) + "?dl=1";
      } else {
        baked = { id, blob, name: bakeName(f, set) };
        give(baked);
        tell("Downloaded with your sound");
      }
    } catch (e) {
      tell("Couldn’t bake the sound in, so here’s the original");
      location.href = src(f) + "?dl=1";
    } finally {
      baking = false;
      btn.classList.remove("busy");
    }
  };

  $("save").onclick = () => {
    const f = items[cur];
    if (!f || f.pending) return;

    if (kind(f) === "aud" && soundOn() && OAC) {
      bakeDownload(f);
      return;
    }

    location.href = src(f) + "?dl=1";
  };

  $("info").onclick = () => {
    const f = items[cur];
    if (!f) return;

    meta.replaceChildren();

    const b = document.createElement("b");
    const s = document.createElement("span");

    b.textContent = f.name;
    s.textContent = f.pending ? "Uploading…" : f.type + ", " + sz(f.size);

    meta.append(b, s);
    meta.hidden = !meta.hidden;
  };

  addEventListener("popstate", hide);

  addEventListener("keydown", (e) => {
    if (lb.hidden) return;

    const inField = e.target.closest && e.target.closest("button");

    if (e.key === "Escape") {
      if (activePlayer && activePlayer.closeTools()) return; // fold an open tray first
      history.back();
    } else if (e.key === "ArrowLeft") {
      show(cur - 1);
    } else if (e.key === "ArrowRight") {
      show(cur + 1);
    } else if (e.key === " " && activePlayer && !inField) {
      e.preventDefault();
      activePlayer.toggle();
    } else if ((e.key === "<" || e.key === ",") && activePlayer) {
      activePlayer.speedStep(-1);
    } else if ((e.key === ">" || e.key === ".") && activePlayer) {
      activePlayer.speedStep(1);
    } else if ((e.key === "a" || e.key === "A") && activePlayer) {
      activePlayer.captureA();
    } else if ((e.key === "b" || e.key === "B") && activePlayer) {
      activePlayer.captureB();
    } else if ((e.key === "l" || e.key === "L") && activePlayer) {
      activePlayer.toggleLoop(); // L = the bottom bar: loop track on / off
    }
  });

  stage.addEventListener(
    "touchstart",
    (e) => {
      x0 = e.touches[0].clientX;
    },
    { passive: true }
  );

  stage.addEventListener(
    "touchend",
    (e) => {
      if (x0 === null) return;

      const dx = e.changedTouches[0].clientX - x0;
      x0 = null;

      if (
        Math.abs(dx) > 50 &&
        !e.target.closest(".p-hb") &&
        !e.target.closest(".p-eq") &&
        !e.target.closest(".pdfv")
      ) {
        show(cur + (dx < 0 ? 1 : -1));
      }
    }
  );

  // ---------- live updates: no reloads, items just arrive ----------

  const becameReady = (it, di) => {
    const idx = items.indexOf(it);

    Object.assign(it, di);
    delete it.pending;
    delete it.progress;
    delete it.stalled;
    delete it.failed;

    const b = tileOf(it);

    if (b) {
      fillTile(b, it);
      b.classList.add("appear");
      setTimeout(() => b.classList.remove("appear"), 700);
    }

    if (thumbs && thumbs[idx]) {
      thumbs[idx].className = "th" + (idx === cur ? " on" : "");
      thumbs[idx].replaceChildren(media(it, true));
    }

    ensureHero();

    // you were looking at the "please check back soon" message: it becomes the real thing
    if (!lb.hidden && idx === cur) show(cur);
  };

  const rebuildGrid = () => {
    grid.replaceChildren(...items.map(buildTile));

    if (thumbs) {
      thumbs = null;
      strip.replaceChildren();
      if (!lb.hidden) build();
    }
  };

  const merge = (d) => {
    if (d.exp) G.exp = d.exp;

    let structural = false;

    (d.items || []).forEach((di) => {
      const it = items.find((f) => f.n === di.n);

      if (!it) {
        items.push(di);
        structural = true;
        return;
      }

      if (it.pending && !di.pending) {
        becameReady(it, di);
        return;
      }

      if (it.pending && di.pending) {
        const changed =
          it.progress !== di.progress || it.stalled !== di.stalled || it.failed !== di.failed;

        it.progress = di.progress;
        it.stalled = di.stalled;
        it.failed = di.failed;

        if (changed) {
          const b = tileOf(it);
          if (b) paintPending(b, it);

          if (!lb.hidden && items[cur] === it) {
            const pv = stage.querySelector(".pw");
            if (pv) paintPendingView(pv, it);
          }
        }
      }
    });

    if (structural) {
      items.sort((a, b) => (a.n < b.n ? -1 : a.n > b.n ? 1 : 0));
      rebuildGrid();
    }

    complete = !!d.complete;
    ensureHero();
    refreshInfo();

    const open = items.filter((f) => f.pending);
    if (complete || (open.length && open.every((f) => f.failed))) stopPolling();
  };

  let timer = null;
  let busy = false;

  const poll = async () => {
    if (busy || document.hidden) return;

    busy = true;

    try {
      const r = await fetch("/api/gallery?id=" + encodeURIComponent(G.id), { cache: "no-store" });

      if (r.status === 404 || r.status === 410) {
        stopPolling();
        return;
      }

      if (r.ok) merge(await r.json());
    } catch (e) {
      // offline for a moment: keep the page, try again next tick
    } finally {
      busy = false;
    }
  };

  const stopPolling = () => {
    clearInterval(timer);
    timer = null;
  };

  document.addEventListener("visibilitychange", () => {
    if (!document.hidden && timer) poll();
  });

  // ---------- go ----------

  items.forEach((f) => grid.appendChild(buildTile(f)));
  ensureHero();
  refreshInfo();

  if (!complete) timer = setInterval(poll, 2000);
})();
