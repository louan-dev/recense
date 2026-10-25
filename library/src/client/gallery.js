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

  // The player's <audio>/<video> lives in a shadow root of its own. Add-ons that take over every
  // media element on a page (Firefox's Audio Controller) find them with querySelectorAll and a
  // MutationObserver, and neither looks inside one. A taken element plays only through the add-on's
  // AudioContext, made before any click; on some Macs that never starts, so the track ran on in
  // silence. play/pause don't leave a shadow root, so they are handed to mediaWatch (set below).
  const mediaWatch = { play() {}, pause() {} };
  const MEDIA_CSS =
    "video{display:block;width:100%;height:auto;max-height:100%;object-fit:contain;background:#000}audio{display:none}";

  const shelter = (el) => {
    const box = mkEl("span", "mbox");
    el.addEventListener("play", () => mediaWatch.play(el));
    el.addEventListener("pause", () => mediaWatch.pause(el));
    if (!box.attachShadow) {
      box.appendChild(el);
      return box;
    }
    const root = box.attachShadow({ mode: "open" });
    const st = mkEl("style");
    st.textContent = MEDIA_CSS;
    root.append(st, el);
    return box;
  };

  // the player's element on stage, inside its shelter or not
  const stageMedia = () => {
    const box = stage.querySelector(".mbox");
    return (box && box.shadowRoot ? box.shadowRoot : stage).querySelector("video, audio");
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
    if (f.nocover) return null; // the owner deleted its cover: the file tile, not a same-named picture
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

  // ----- text documents, shown in the PDF viewer's layout: white pages on the dark stage -----
  // Markdown is drawn as formatted text, Word (.docx) through mammoth (loaded only when one is opened), and
  // plain-text kinds (text, CSV, JSON, logs, code, RTF with its markup taken out) as they are.
  const MD_RE = /\.(md|markdown|mdown|mkd)$/i;
  const DOCX_RE = /\.docx$/i;
  const TEXT_RE = /\.(txt|text|csv|tsv|json|log|xml|yaml|yml|ini|conf|srt|vtt|rtf|js|mjs|ts|py|swift|sh|zsh|css|html?|c|h|cpp|java|go|rs|rb|sql|tex)$/i;
  const isTextDoc = (f) =>
    MD_RE.test(f.name) || DOCX_RE.test(f.name) || TEXT_RE.test(f.name) ||
    /^text\//.test(f.type || "") || /officedocument\.wordprocessingml/.test(f.type || "");
  const MAMMOTH = "https://cdnjs.cloudflare.com/ajax/libs/mammoth/1.6.0/mammoth.browser.min.js";
  let mammothLib = null;
  const loadMammoth = () =>
    mammothLib ||
    (mammothLib = new Promise((res, rej) => {
      const sc = document.createElement("script");
      sc.src = MAMMOTH;
      sc.onload = () => (window.mammoth ? res(window.mammoth) : rej(new Error("mammoth did not load")));
      sc.onerror = () => {
        mammothLib = null;
        rej(new Error("mammoth did not load"));
      };
      document.head.appendChild(sc);
    }));

  const escHtml = (t) => t.replace(/&/g, "&amp;").replace(/</g, "&lt;").replace(/>/g, "&gt;");
  // a small Markdown: headings, lists, quotes, code, rules, tables, emphasis, links and images (escaped first)
  const mdHtml = (md) => {
    const inline = (t) =>
      escHtml(t)
        .replace(/`([^`]+)`/g, "<code>$1</code>")
        .replace(/!\[([^\]]*)\]\(([^)\s]+)[^)]*\)/g, (m, a, u) => (/^(https?:|\/)/.test(u) ? '<img alt="' + a + '" src="' + u + '">' : a))
        .replace(/\[([^\]]+)\]\(([^)\s]+)[^)]*\)/g, (m, a, u) => (/^(https?:|\/|#|mailto:)/.test(u) ? '<a href="' + u + '" target="_blank" rel="noopener">' + a + "</a>" : a))
        .replace(/\*\*([^*]+)\*\*|__([^_]+)__/g, (m, a, b) => "<strong>" + (a || b) + "</strong>")
        .replace(/\*([^*]+)\*|\b_([^_]+)_\b/g, (m, a, b) => "<em>" + (a || b) + "</em>")
        .replace(/~~([^~]+)~~/g, "<del>$1</del>");
    const out = [];
    const L = md.replace(/\r\n?/g, "\n").split("\n");
    for (let i = 0; i < L.length; ) {
      const l = L[i];
      let m;
      if (/^```/.test(l)) {
        const code = [];
        for (i++; i < L.length && !/^```/.test(L[i]); i++) code.push(L[i]);
        i++;
        out.push("<pre><code>" + escHtml(code.join("\n")) + "</code></pre>");
      } else if ((m = l.match(/^(#{1,6})\s+(.*)$/))) {
        out.push("<h" + m[1].length + ">" + inline(m[2].replace(/\s#+$/, "")) + "</h" + m[1].length + ">");
        i++;
      } else if (/^\s*([-*_])(\s*\1){2,}\s*$/.test(l)) {
        out.push("<hr>");
        i++;
      } else if (/^\s*>/.test(l)) {
        const q = [];
        for (; i < L.length && /^\s*>/.test(L[i]); i++) q.push(L[i].replace(/^\s*>\s?/, ""));
        out.push("<blockquote>" + mdHtml(q.join("\n")) + "</blockquote>");
      } else if (/^\s*([-*+]|\d+[.)])\s+/.test(l)) {
        const ordered = /^\s*\d/.test(l);
        const items = [];
        for (; i < L.length && /^\s*([-*+]|\d+[.)])\s+/.test(L[i]); i++) {
          const t = L[i].replace(/^\s*([-*+]|\d+[.)])\s+/, "");
          const box = t.match(/^\[([ xX])\]\s+(.*)$/);
          items.push("<li>" + (box ? '<input type="checkbox" disabled' + (box[1] !== " " ? " checked" : "") + "> " + inline(box[2]) : inline(t)) + "</li>");
        }
        out.push((ordered ? "<ol>" : "<ul>") + items.join("") + (ordered ? "</ol>" : "</ul>"));
      } else if (/\|/.test(l) && i + 1 < L.length && /^\s*\|?\s*:?-{2,}/.test(L[i + 1])) {
        const cells = (r) => r.trim().replace(/^\||\|$/g, "").split("|").map((c) => c.trim());
        const head = cells(l);
        const rows = [];
        for (i += 2; i < L.length && /\|/.test(L[i]) && L[i].trim(); i++) rows.push(cells(L[i]));
        out.push("<table><thead><tr>" + head.map((c) => "<th>" + inline(c) + "</th>").join("") + "</tr></thead><tbody>" +
          rows.map((r) => "<tr>" + r.map((c) => "<td>" + inline(c) + "</td>").join("") + "</tr>").join("") + "</tbody></table>");
      } else if (!l.trim()) {
        i++;
      } else {
        const para = [];
        for (; i < L.length && L[i].trim() && !/^(#{1,6}\s|```|\s*>|\s*([-*+]|\d+[.)])\s+)/.test(L[i]); i++) para.push(L[i]);
        out.push("<p>" + para.map(inline).join("<br>") + "</p>");
      }
    }
    return out.join("\n");
  };
  const rtfText = (r) =>
    r.replace(/\\par[d]?/g, "\n").replace(/\{\\\*[^{}]*\}/g, "").replace(/\\'([0-9a-f]{2})/gi, (m, h) => String.fromCharCode(parseInt(h, 16)))
      .replace(/\\[a-z]+-?\d* ?/gi, "").replace(/[{}]/g, "").replace(/\n{3,}/g, "\n\n").trim();

  const buildTextDoc = (f) => {
    const wrap = mkEl("div", "pdfw");
    const spin = mkEl("div", "spin");
    wrap.appendChild(spin);
    (async () => {
      const r = await fetch(src(f));
      if (!r.ok) throw new Error("couldn’t load");
      let html;
      if (DOCX_RE.test(f.name) || /wordprocessingml/.test(f.type || "")) {
        const lib = await loadMammoth();
        const res = await lib.convertToHtml({ arrayBuffer: await r.arrayBuffer() });
        html = res.value;
      } else {
        const text = await r.text();
        if (MD_RE.test(f.name) || f.type === "text/markdown") html = mdHtml(text);
        else html = "<pre>" + escHtml(/\.rtf$/i.test(f.name) ? rtfText(text) : text) + "</pre>";
      }
      const scroller = mkEl("div", "pdfv");
      const col = mkEl("div", "pdfd");
      const page = mkEl("div", "pdfp txtdoc");
      page.innerHTML = html;
      // nothing from a document runs: scripts and handlers out (mammoth and the Markdown above write none, but a .docx can carry odd HTML)
      page.querySelectorAll("script, iframe, object, embed").forEach((e) => e.remove());
      page.querySelectorAll("*").forEach((e) => [...e.attributes].forEach((a) => /^on/i.test(a.name) && e.removeAttribute(a.name)));
      scroller.tabIndex = 0;
      col.appendChild(page);
      scroller.appendChild(col);
      wrap.replaceChildren(scroller);
    })().catch(() => wrap.replaceChildren(docView(f)));
    return wrap;
  };

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
    key: 0, // semitones, -12 to +12; 0 is the original key (halves in Key state 8, cents in state 9)
    keyNotation: 0, // the Key slider's label state, 0–9 (see keylabel.js); kept in this browser
    nativeLang: "en", // the trailing language, "en" | "vi" | "fr": the second line of Key state 0
    vol: 1, // playback level, 0 to 1
    space: { mix: 0, on: false, room: "room" }, // reverb, -100 to +100: + is the room, − the same room reversed; 0 is dry
    txScale: 1, // subtitle size, times the base size (the a|A pill, Info › Text Size, a pinch over the lyrics)
  };
  const SPEEDS = [0.5, 0.75, 1, 1.25, 1.5, 2];
  const KEY_NOTATION = "gallery.keyNotation";

  // the native language (spec §1)
  const NATIVE_LANG = "gallery.nativeLang";
  const NATIVE_LANGS = [
    ["en", "English"],
    ["vi", "Vietnamese"],
    ["fr", "French"],
  ];
  const isLang = (l) => NATIVE_LANGS.some((x) => x[0] === l);
  const isNotation = (n) => Number.isInteger(n) && n >= 0 && n < GalleryKey.STATES;

  // Notation follows the language where the two are one thing: the solfège captions are Ton. (French)
  // and Tông (Vietnamese), so a language change moves one to the other; English goes back to Key.
  // Every other notation (Tonart, 調 …) is left as chosen.
  const LANG_NOTATION = { en: 0, fr: 1, vi: 2 };
  const notationFor = (lang, n) => ((n === 1 || n === 2) && LANG_NOTATION[lang] !== undefined ? LANG_NOTATION[lang] : n);

  // Main keeps both in this browser. A share link (public /s/ or a room /m/) carries the sharer's
  // own, written into the link when it was made (G.view), and never reads this browser's: the same
  // link looks the same on every device. Changes made on a share link last for the visit.
  const SHARED = !G.main;
  if (SHARED) {
    const v = G.view || {};
    const q = new URLSearchParams(location.search).get("lang"); // links made before G.view
    prefs.nativeLang = isLang(v.lang) ? v.lang : isLang(q) ? q : "en";
    prefs.keyNotation = isNotation(v.notation) ? v.notation : LANG_NOTATION[prefs.nativeLang] || 0;
  } else {
    try {
      const n = parseInt(localStorage.getItem(KEY_NOTATION), 10);
      if (isNotation(n)) prefs.keyNotation = n;
      const l = localStorage.getItem(NATIVE_LANG);
      if (isLang(l)) prefs.nativeLang = l;
    } catch (e) {}
  }
  prefs.keyNotation = notationFor(prefs.nativeLang, prefs.keyNotation);
  // what a share link made from here carries (page script: Create Share Link, Share, Invite)
  window.galleryView = () => ({ lang: prefs.nativeLang, notation: prefs.keyNotation });

  // Subtitle size: one value, kept in this browser (a share link's visitor keeps their own), and
  // every control that shows it repaints when it changes, wherever the change came from.
  const TEXT_SCALE = "gallery.textScale";
  const TXS_MIN = 0.7;
  const TXS_MAX = 1.8;
  const TXS_STEP = 0.1;
  const txsViews = new Set(); // (live) => repaint
  try {
    const v = parseFloat(localStorage.getItem(TEXT_SCALE));
    if (v >= TXS_MIN && v <= TXS_MAX) prefs.txScale = v;
  } catch (e) {}
  document.documentElement.style.setProperty("--txs", String(prefs.txScale));

  // live: a pinch still under way (shown, not yet kept)
  const setTextScale = (v, live) => {
    v = Math.round(clamp(v, TXS_MIN, TXS_MAX) * 100) / 100;
    prefs.txScale = v;
    document.documentElement.style.setProperty("--txs", String(v));
    txsViews.forEach((f) => f(live));
    if (!live) {
      try {
        localStorage.setItem(TEXT_SCALE, String(v));
      } catch (e) {}
    }
  };

  // one audio context for the whole viewer, created the first time you touch the EQ
  // (a user gesture, so it is allowed to run) and reused for every later player
  let audioCtx = null;

  // Firefox: once Web Audio has taken an element, its sound only comes out through the context,
  // and on some Macs that context goes quiet while the track plays on. When that's seen, Sound is
  // left off for the rest of the visit and the player is rebuilt as plain playback.
  let webAudioDead = false;
  const sayAll = (t) => say(t); // the viewer's own toast, which outlives the player

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

  // Firefox keeps an output stream open for as long as a context runs. With an audio routing app on
  // the Mac (SoundSource) one that got stuck silenced every Gallery tab in the browser (one site,
  // one process), share links and Main alike, while their time bars moved on. So the context runs
  // only while a player plays through it, sleeps a few seconds after the last pause, and is closed,
  // not left behind, once no player uses it or its sound died. (Safari's deck keeps its own.)
  const ctxEls = new Set();
  let ctxSleepT = 0;
  const ctxSleep = () => {
    clearTimeout(ctxSleepT);
    ctxSleepT = setTimeout(() => {
      if (audioCtx && audioCtx.state === "running" && ![...ctxEls].some((e) => !e.paused)) audioCtx.suspend().catch(() => {});
    }, 4000);
  };
  const ctxClose = () => {
    const c = audioCtx;
    audioCtx = null;
    keyModule = null;
    Object.keys(roomIRs).forEach((k) => delete roomIRs[k]);
    ctxEls.clear();
    clearTimeout(ctxSleepT);
    if (c && c.state !== "closed") c.close().catch(() => {});
  };
  addEventListener("pagehide", (e) => {
    if (!e.persisted && !DECK) ctxClose();
  });

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

  // a negative Space is the room played backwards: the tail swells up instead of dying away.
  // Only the first half of the tail is turned round, so the swell arrives sooner (the whole of
  // it would peak a full second after the sound).
  const reverseIR = (d) => d.map((x) => x.slice(0, Math.round(x.length * 0.5)).reverse());

  // how much dry stays and how much room comes in, for an amount from 0 to 1. The same
  // numbers are used live and when a download is baked, so the file is what you heard.
  const spaceGain = (m) => ({ dry: 1 - 0.35 * m, wet: Math.min(1.3, 1.25 * Math.pow(m, 0.7)) });

  const irBuffer = (ctx, id, rev) => {
    let d = irData(id, ctx.sampleRate);

    if (rev) d = reverseIR(d);
    const buf = ctx.createBuffer(2, d[0].length, ctx.sampleRate);

    d.forEach((x, c) => buf.getChannelData(c).set(x));
    return buf;
  };

  const roomIR = (id, rev) => {
    const k = id + (rev ? "~" : "");
    return roomIRs[k] || (roomIRs[k] = irBuffer(audioCtx, id, rev));
  };

  const spaceOn = () => prefs.space.on && prefs.space.mix !== 0;

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
  // a short note on the open player (Info, comments, covers, keys); nothing when no player is open
  const tell = (t) => activePlayer && activePlayer.note(t);

  // ----- the shell: another folder opens in a frame over this page while sound plays -----
  //
  // The top page keeps a stack of frames. Following a link while something plays opens the link in a
  // new frame and keeps the playing page alive, hidden; a play anywhere stops every other page. Back
  // past a frame's first page closes it. Same origin only; files (/f/) and downloads are left alone.
  const SHELL = (() => {
    let top = null;
    try {
      top = window.top !== window && window.top.__galleryShell ? window.top.__galleryShell : null;
    } catch (x) {}
    if (top) return { framed: true, played: (w) => top.played(w), go: (u, w) => top.go(u, w) };

    const frames = []; // { fr, win }
    const docs = () => [window, ...frames.map((x) => x.fr.contentWindow)].filter(Boolean);
    const playingIn = (w) => {
      try {
        return !!(w.__galleryPlaying && w.__galleryPlaying());
      } catch (x) {
        return false;
      }
    };
    const shell = {
      framed: false,
      played(src) {
        if (src !== window && window.__galleryRemoteClear) window.__galleryRemoteClear();
        for (const w of docs()) {
          if (w === src) continue;
          try {
            if (w.__galleryStop) w.__galleryStop();
          } catch (x) {}
        }
        // hidden frames kept only for their sound go once nothing plays in them
        for (const x of frames.slice()) {
          if (x.fr.style.visibility === "hidden" && x.fr.contentWindow !== src && !playingIn(x.fr.contentWindow)) {
            x.fr.remove();
            frames.splice(frames.indexOf(x), 1);
          }
        }
      },
      go(url, from) {
        const fr = document.createElement("iframe");
        fr.className = "shellfr";
        fr.src = url;
        fr.setAttribute("allow", "autoplay; fullscreen; picture-in-picture");
        // the page we leave: kept, hidden, if it plays; else dropped
        const last = frames[frames.length - 1];
        if (last && last.fr.contentWindow === from) {
          if (playingIn(from)) {
            last.fr.style.visibility = "hidden";
            try {
              window.__galleryRemote(from, from.__galleryPlayingName());
            } catch (x) {}
          }
          else {
            last.fr.remove();
            frames.pop();
          }
        }
        frames.push({ fr });
        document.body.appendChild(fr);
        document.body.classList.add("shelled");
        fr.addEventListener("load", () => {
          try {
            const w = fr.contentWindow;
            history.replaceState(history.state, "", w.location.href);
            document.title = w.document.title;
          } catch (x) {}
        });
        history.pushState({ shell: frames.length }, "", url);
      },
    };
    addEventListener("popstate", () => {
      const vis = frames.filter((x) => x.fr.style.visibility !== "hidden");
      const want = (history.state && history.state.shell) || 0;
      if (vis.length > want) {
        const x = vis[vis.length - 1];
        if (!playingIn(x.fr.contentWindow)) {
          x.fr.remove();
          frames.splice(frames.indexOf(x), 1);
        } else x.fr.style.visibility = "hidden";
        const still = frames.filter((y) => y.fr.style.visibility !== "hidden");
        if (still.length) still[still.length - 1].fr.style.visibility = "";
        else document.body.classList.remove("shelled");
      }
    });
    window.__galleryShell = shell;
    return shell;
  })();

  // a link followed while sound plays (or with frames up) opens over this page instead of replacing it
  document.addEventListener("click", (e) => {
    if (e.defaultPrevented || e.button || e.metaKey || e.ctrlKey || e.shiftKey || e.altKey) return;
    const a = e.target.closest && e.target.closest("a[href]");
    if (!a || a.target || a.hasAttribute("download")) return;
    const u = new URL(a.href, location.href);
    if (u.origin !== location.origin || /^\/(f|player)\//.test(u.pathname) || u.search.includes("dl=1")) return;
    if (u.pathname === location.pathname && u.hash) return;
    const shelled = !SHELL.framed && document.body.classList.contains("shelled");
    if (!window.__galleryPlaying() && !shelled) return;
    e.preventDefault();
    SHELL.go(u.href, window);
  }, true);
  const PAUSE_PATH_EARLY =
    '<rect x="6" y="4.5" width="4.2" height="15" rx="1.4"/><rect x="13.8" y="4.5" width="4.2" height="15" rx="1.4"/>';

  // ----- playback that outlives the viewer -----
  //
  // A playing track keeps playing when the viewer closes, moves to another item (a PDF, a photo) or
  // the page goes to another folder; it stops only on Pause or when another track plays. Its player
  // is parked, whole, in a hidden dock; opening its item again puts it back on stage. Another folder
  // opens in a frame over this page (shell, below), so this page and its sound stay alive.
  let parked = null;
  const dock = mkEl("div", "dock");
  dock.hidden = true;
  document.body.appendChild(dock);
  const pill = mkEl("div", "nowpl");
  pill.hidden = true;
  pill.innerHTML = '<button type="button" class="nowpl-t"></button><button type="button" class="nowpl-p" aria-label="Pause">' + SVG(PAUSE_PATH_EARLY, true) + "</button>";
  document.body.appendChild(pill);

  const stopParked = () => {
    if (!parked) return;
    const p = parked;
    parked = null;
    pill.hidden = true;
    try {
      p.el.pause();
    } catch (x) {}
    p.kill();
    p.wrap.remove();
  };

  const playingHere = () => !!((parked && !parked.el.paused) || (activePlayer && activePlayer.el && !activePlayer.el.paused));
  const stopHere = () => {
    stopParked();
    if (activePlayer && activePlayer.el) activePlayer.el.pause();
  };
  window.__galleryPlaying = playingHere;
  window.__galleryStop = stopHere;

  const endPlayer = () => {
    if (!activePlayer) return;
    const p = activePlayer;
    activePlayer = null;
    if (p.el && !p.el.paused && !p.el.ended) {
      stopParked();
      parked = p;
      dock.appendChild(p.wrap);
      pill.querySelector(".nowpl-t").textContent = "♪ " + (p.item ? p.item.name : "");
      pill.hidden = false;
      return;
    }
    p.kill();
  };

  let remote = null; // a hidden frame, under this page's frames, whose track still plays
  pill.querySelector(".nowpl-p").onclick = (e) => {
    e.stopPropagation();
    if (remote) {
      try {
        remote.__galleryStop();
      } catch (x) {}
      remote = null;
      pill.hidden = true;
    } else stopParked();
  };
  window.__galleryRemote = (w, name) => {
    if (parked) stopParked();
    remote = w;
    pill.querySelector(".nowpl-t").textContent = "♪ " + (name || "");
    pill.hidden = false;
  };
  // a rename anywhere: retitle the pill if it names that file
  window.__galleryRetitle = (oldPath, newPath, newName) => {
    if (parked && parked.item && parked.item.path === oldPath) {
      parked.item.path = newPath;
      parked.item.name = newName;
    }
    const t = pill.querySelector(".nowpl-t");
    if (!pill.hidden && (parked ? parked.item && parked.item.path === newPath : remote && remote.__galleryPlayingPath && remote.__galleryPlayingPath() === newPath))
      t.textContent = "♪ " + newName;
  };
  window.__galleryRemoteClear = () => {
    if (!remote) return;
    remote = null;
    pill.hidden = true;
  };
  window.__galleryPlayingPath = () => (parked && parked.item ? parked.item.path : activePlayer && activePlayer.item ? activePlayer.item.path : "");
  window.__galleryPlayingName = () => (parked && parked.item ? parked.item.name : activePlayer && activePlayer.item ? activePlayer.item.name : "");
  pill.querySelector(".nowpl-t").onclick = () => {
    const i = parked ? items.indexOf(parked.item) : -1;
    if (i >= 0) openAt(i);
  };

  // any media starting anywhere (this page, a frame over it, or the page under it) stops the others
  mediaWatch.play = (m) => {
    if (parked && parked.el !== m) stopParked();
    if (remote) {
      remote = null;
      pill.hidden = true;
    }
    SHELL.played(window);
  };
  mediaWatch.pause = (m) => {
    if (parked && parked.el === m) stopParked(); // Pause (lock screen, keys) ends it
  };
  document.addEventListener(
    "play",
    (e) => {
      if (e.target instanceof HTMLMediaElement) mediaWatch.play(e.target);
    },
    true
  );
  document.addEventListener(
    "pause",
    (e) => {
      if (e.target instanceof HTMLMediaElement) mediaWatch.pause(e.target);
    },
    true
  );

  const TEN =
    '<text x="12" y="16" font-size="7" font-weight="bold" fill="currentColor" text-anchor="middle" stroke="none">10</text>';

  const PLAY_PATH =
    '<path d="M8 5.14v13.72a1 1 0 0 0 1.5.86l11-6.86a1 1 0 0 0 0-1.72l-11-6.86A1 1 0 0 0 8 5.14z"/>';

  const PAUSE_PATH =
    '<rect x="6" y="4.5" width="4.2" height="15" rx="1.4"/><rect x="13.8" y="4.5" width="4.2" height="15" rx="1.4"/>';

  const I_BACK15 = SVG(
    '<path d="M3 12a9 9 0 1 0 9-9 9.75 9.75 0 0 0-6.74 2.74L3 8"/><path d="M3 3v5h5"/>' + TEN.replace(">10<", ">15<")
  );

  const I_FWD15 = SVG(
    '<path d="M21 12a9 9 0 1 1-9-9 9.75 9.75 0 0 1 6.74 2.74L21 8"/><path d="M21 3v5h-5"/>' + TEN.replace(">10<", ">15<")
  );

  const I_PIP = SVG(
    '<path d="M21 9V6a2 2 0 0 0-2-2H4a2 2 0 0 0-2 2v10c0 1.1.9 2 2 2h4"/><rect width="10" height="7" x="12" y="13" rx="2"/>'
  );

  const I_REPEAT = SVG(
    '<path d="m17 2 4 4-4 4"/><path d="M3 11v-1a4 4 0 0 1 4-4h14"/><path d="m7 22-4-4 4-4"/><path d="M21 13v1a4 4 0 0 1-4 4H3"/>'
  );

  const I_X = SVG('<path d="M18 6 6 18"/><path d="m6 6 12 12"/>');

  const buildMedia = (tag, mediaSrc, artUrl) => {
    const item = items[cur]; // whose original key the Key labels spell
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
    // a video shows its first frame instead of black before play (iOS paints nothing at t=0)
    el.src = tag === "video" ? mediaSrc + "#t=0.001" : mediaSrc;

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

    el.preservesPitch = true;   // speed changes tempo, never pitch
    el.playbackRate = speed;

    const ready = () => A !== null && B !== null;

    // ----- transport: laid along the home bar (hover, or first tap), see below -----

    const bPlay = mkBtn(
      "p-hloop p-hplay",
      "Play",
      SVG(PLAY_PATH, true, "pl") + SVG(PAUSE_PATH, true, "pa") + '<span class="n">Play</span>'
    );
    const bBack = mkBtn("p-pa", "Back 15 seconds", I_BACK15);
    const bFwd = mkBtn("p-pb", "Forward 15 seconds", I_FWD15);

    const toggle = () => {
      if (el.paused) el.play().catch(() => {});
      else el.pause();
    };

    bPlay.onclick = (e) => {
      e.stopPropagation();
      toggle();
      bumpHb();
      wake();
    };

    bBack.onclick = (e) => {
      e.stopPropagation();
      el.currentTime = Math.max(0, el.currentTime - 15);
      wake();
    };

    bFwd.onclick = (e) => {
      e.stopPropagation();
      el.currentTime = Math.min(el.duration || 0, el.currentTime + 15);
      wake();
    };

    const sync = () => {
      bPlay.classList.toggle("playing", !el.paused);
      bPlay.setAttribute("aria-label", el.paused ? "Play" : "Pause");
      bPlay.querySelector(".n").textContent = el.paused ? "Play" : "Pause";
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
    const line = mkBtn("p-hline", "Open play controls", "<i></i>");
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
    const playRow = mkEl("div", "p-hbrow p-hbplay");
    const playG = mkEl("div", "p-hab");

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
    playRow.setAttribute("role", "group");
    playRow.setAttribute("aria-label", "Play and skip");
    playRow.setAttribute("aria-hidden", "true");
    speedRow.setAttribute("role", "group");
    speedRow.setAttribute("aria-label", "Playback speed");
    speedRow.setAttribute("aria-hidden", "true");
    line.setAttribute("aria-expanded", "false");
    hb.dataset.open = "false";
    hb.dataset.mode = "play";
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
    // ghosts of the A–B line and × so ±15 sit exactly where A and B do
    const ghost = (c) => { const g = mkEl("i", c + " p-ghost"); g.setAttribute("aria-hidden", "true"); return g; };
    playG.append(bBack, ghost("p-pc"), bFwd, ghost("p-px"));
    playRow.append(bPlay, mkEl("i", "p-sep"), playG);

    // the stroke goes in before the rows, so a control in a row always sits on top of it
    mkA.innerHTML = "<b>A</b>";
    mkB.innerHTML = "<b>B</b>";
    skTrack.append(skHint, skRead, skTicks);
    seekL.appendChild(skTrack);
    seekL.setAttribute("aria-hidden", "true"); // visual only: the stroke itself takes the arrow keys (below)

    box.append(scrim, line, skReg, bead, tbead, mkA, mkB, sval, tval, playRow, row, speedRow, seekL);
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
      '<stop offset="0" stop-color="#0a84ff" stop-opacity=".16"/>' +
      '<stop offset=".5" stop-color="#0a84ff" stop-opacity=".02"/>' +
      '<stop offset="1" stop-color="#0a84ff" stop-opacity=".16"/></linearGradient></defs>' +
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
    // under a thumb); tap above or below the bead for one step. The value above names the key in
    // the notation the caption below shows; the caption is the one tap target that changes it
    // (tap: next, right-click / two-finger tap / two fingers down: back; the whole list: hold, press and swipe up,
    // point at it, or two fingers up).
    const key = (() => {
      const col = mkEl("div", "p-band key");
      const val = mkEl("span", "p-bval kval");
      const trk = mkEl("div", "p-btrack");
      const inn = mkEl("div", "p-bin");
      const fill = mkEl("div", "p-bfill");
      const knob = mkEl("i", "p-bknob");
      const lab = mkBtn("p-blabel kcap", "Key notation", "");
      const pop = mkEl("div", "kpop");

      pop.hidden = true;
      pop.setAttribute("role", "listbox");
      pop.setAttribute("aria-label", "Key notation");
      GalleryKey.CAPTIONS.forEach((c, i) => {
        const row = mkBtn("krow", c, "");
        row.textContent = c;
        row.dataset.state = String(i);
        row.setAttribute("role", "option");
        pop.appendChild(row);
      });

      lab.setAttribute("aria-haspopup", "listbox");
      trk.tabIndex = 0;
      trk.setAttribute("role", "slider");
      trk.setAttribute("aria-orientation", "vertical");
      trk.setAttribute("aria-label", "Key (semitones)");
      trk.setAttribute("aria-valuemin", String(-KEY_MAX));
      trk.setAttribute("aria-valuemax", String(KEY_MAX));

      inn.append(mkEl("i", "p-kticks"), mkEl("i", "p-bzero"), fill, knob);
      trk.appendChild(inn);
      col.append(val, trk, lab, pop);
      graph.appendChild(col);

      return { col, val, trk, inn, fill, knob, lab, pop };
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
      const lab = mkBtn("p-blabel", "Reset Reverb", "Reverb");

      trk.tabIndex = 0;
      trk.setAttribute("role", "slider");
      trk.setAttribute("aria-orientation", "vertical");
      trk.setAttribute("aria-label", "Space (reverb: positive is the room, negative is the room reversed)");
      trk.setAttribute("aria-valuemin", "-100");
      trk.setAttribute("aria-valuemax", "100");

      inn.append(mkEl("div", "p-bbase"), mkEl("i", "p-bzero"), fill, knob);
      trk.appendChild(inn);
      col.append(val, trk, lab);
      graph.appendChild(col);

      return { col, val, trk, inn, fill, knob, lab };
    })();

    eqIn.append(eqTop, eqCols);
    eq.appendChild(eqIn);
    eqWrap.append(eqBtn, eq);

    // The curve: x is frequency (low to high, each band's column at its own frequency), y is
    // level on the same ±15 dB scale as the beads. Drawn from the real filter response.
    const FLAT = { low: 0, mid: 0, high: 0, key: 0, space: 0 };
    const curveNow = () => ({ ...prefs.eq, key: prefs.key, space: spaceOn() ? prefs.space.mix : 0 });
    let shown = { ...FLAT }; // what the curve is drawn with right now
    let curveRaf = 0;

    const drawCurve = (g) => {
      const gr = graph.getBoundingClientRect();
      if (!gr.width) return;

      // five columns, one line: Low, Mid, High, Key, Space. Everything at rest is the same
      // height, so the line opens perfectly level.
      const ins = [...EQ_BANDS.map((b) => bands[b.id].inn), key.inn, sp.inn].map((c) => c.getBoundingClientRect());
      const top = ins[0].top - gr.top;
      const h = ins[0].height;
      const xs = ins.map((r) => r.left + r.width / 2 - gr.left);
      const lf = EQ_BANDS.map((b) => Math.log(b.f));
      const W = gr.width;
      const yOf = (db) => top + ((EQ_MAX - clamp(db, -EQ_MAX, EQ_MAX)) / (EQ_MAX * 2)) * h;
      const yKey = (st) => top + ((KEY_MAX - clamp(st, -KEY_MAX, KEY_MAX)) / (KEY_MAX * 2)) * h;
      const ySp = (m) => top + ((100 - clamp(m, -100, 100)) / 200) * h;
      const pts = [];

      // Low to High: the real filter response, so the curve is the sound you hear
      // The curve goes through the five beads exactly: a smooth, non-overshooting curve through
      // (Low, Mid, High, Key, Space), so a bead can never come off it whatever the amplitude.
      {
        const vy = [yOf(g.low), yOf(g.mid), yOf(g.high), yKey(g.key), ySp(g.space)];
        const X = [0].concat(xs);
        const Y = [vy[0]].concat(vy);
        const n = X.length;
        const d = [];
        const m = [];

        for (let i = 0; i < n - 1; i++) d.push((Y[i + 1] - Y[i]) / (X[i + 1] - X[i] || 1));

        m[0] = d[0];
        m[n - 1] = d[n - 2];

        for (let i = 1; i < n - 1; i++) m[i] = d[i - 1] * d[i] <= 0 ? 0 : (2 * d[i - 1] * d[i]) / (d[i - 1] + d[i]);

        for (let i = 0; i < n - 1; i++) {
          const h = X[i + 1] - X[i];

          for (let k = i ? 1 : 0; k <= 14; k++) {
            const t = k / 14;
            const t2 = t * t;
            const t3 = t2 * t;

            pts.push([
              X[i] + t * h,
              (2 * t3 - 3 * t2 + 1) * Y[i] + (t3 - 2 * t2 + t) * h * m[i] + (-2 * t3 + 3 * t2) * Y[i + 1] + (t3 - t2) * h * m[i + 1],
            ]);
          }
        }

        const pct = (v, max) => ((max - clamp(v, -max, max)) / (max * 2)) * 100 + "%";

        EQ_BANDS.forEach((b) => {
          bands[b.id].knob.style.top = pct(g[b.id], EQ_MAX);
        });

        key.knob.style.top = pct(g.key, KEY_MAX);
        sp.knob.style.top = pct(g.space, 100);
      }

      for (let k = 0; k <= -1; k++) {
        const x = (xs[2] * k) / 48;
        const i = x < xs[1] ? 0 : 1;
        const f = Math.exp(lf[i] + ((x - xs[i]) / (xs[i + 1] - xs[i])) * (lf[i + 1] - lf[i]));
        let db = 0;

        EQ_BANDS.forEach((b) => {
          db += bandDb(b, g[b.id], f);
        });

        pts.push([x, yOf(db)]);
      }

      // High on through Key and Space: one smooth stroke, so all five read as a single curve
      const knots = [pts[pts.length - 1], [xs[3], yKey(g.key)], [xs[4], ySp(g.space)]];
      const cr = (a, b, c, d, t) =>
        0.5 * (2 * b + (-a + c) * t + (2 * a - 5 * b + 4 * c - d) * t * t + (-a + 3 * b - 3 * c + d) * t * t * t);

      for (let s2 = 0; s2 < 0; s2++) {
        const p0 = knots[Math.max(0, s2 - 1)];
        const p1 = knots[s2];
        const p2 = knots[s2 + 1];
        const p3 = knots[Math.min(2, s2 + 2)];

        for (let k = 1; k <= 16; k++) {
          const t = k / 16;
          pts.push([cr(p0[0], p1[0], p2[0], p3[0], t), cr(p0[1], p1[1], p2[1], p3[1], t)]);
        }
      }

      pts.push([W, ySp(g.space)]);

      const d = pts.map((q, k) => (k ? "L" : "M") + q[0].toFixed(1) + " " + q[1].toFixed(1)).join("");
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

        Object.keys(FLAT).forEach((k) => {
          shown[k] = from[k] + (to[k] - from[k]) * e;
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

    // Volume: a gentle taper (level squared) so equal steps sound equal. With the graph running it
    // is a master gain at the very end; before that it is the element's own volume. (iPhone keeps
    // the element at full and ignores changes to it, so there the graph is started on the first
    // change and the gain does the work.)
    const volGain = () => prefs.vol * prefs.vol;

    const applyVol = () => {
      if (nodes && nodes.master) {
        nodes.master.gain.setTargetAtTime(volGain(), audioCtx.currentTime, 0.015);
        return;
      }

      try {
        el.volume = volGain();
      } catch (x) {}
    };

    const setVol = (v) => {
      prefs.vol = clamp(v);
      applyVol();

      if (!nodes && Math.abs(el.volume - volGain()) > 0.02 && ensureEq()) applyVol();
    };

    // the gain that takes back the EQ's highest peak (1 when nothing is boosted), worked out from
    // the bands as they will be, across the audible range
    const TRIM_F = new Float32Array(96).map((_, i) => 20 * Math.pow(1000, i / 95));
    const eqTrim = () => {
      if (!audioCtx || !EQ_BANDS.some((b) => prefs.eq[b.id] > 0)) return 1;

      const sum = new Float32Array(TRIM_F.length);
      const mag = new Float32Array(TRIM_F.length);
      const ph = new Float32Array(TRIM_F.length);

      try {
        const probe = audioCtx.createBiquadFilter();
        EQ_BANDS.forEach((b) => {
          probe.type = b.type;
          probe.frequency.value = b.f;
          probe.Q.value = b.q;
          probe.gain.value = prefs.eq[b.id];
          probe.getFrequencyResponse(TRIM_F, mag, ph);
          mag.forEach((m, i) => (sum[i] += 20 * Math.log10(Math.max(m, 1e-6))));
        });
      } catch (x) {
        return Math.pow(10, -Math.max(...EQ_BANDS.map((b) => prefs.eq[b.id])) / 20);
      }

      return Math.min(1, Math.pow(10, -Math.max(0, ...sum) / 20));
    };

    const eqIsFlat = () => !prefs.eq.low && !prefs.eq.mid && !prefs.eq.high;

    let ctxWait = false;

    const ensureEq = () => {
      if (nodes) return true;
      if (webAudioDead && !DECK) return false;

      const AC = window.AudioContext || window.webkitAudioContext;
      if (!AC) return false;

      try {
        if (!audioCtx) {
          // iPhone: keep Web Audio audible with the ringer switch on silent
          if (navigator.audioSession) navigator.audioSession.type = "playback";
          audioCtx = new AC();
        }

        // Firefox: an element taken into a context that isn't running goes silent, and on some Macs
        // the context never starts. So the element stays as it is until the context runs; the
        // graph is built then, with every setting as it is by that time.
        if (!DECK && audioCtx.state !== "running") {
          if (!ctxWait) {
            ctxWait = true;
            const c = audioCtx;
            const go = () => {
              if (c !== audioCtx) {
                // closed meanwhile: the next play makes a new one
                ctxWait = false;
                return c.removeEventListener("statechange", go);
              }
              if (c.state !== "running" || !ctxWait) return;
              ctxWait = false;
              c.removeEventListener("statechange", go);
              if (!nodes && (!eqIsFlat() || prefs.key || spaceOn()) && ensureEq()) applyVol();
            };
            audioCtx.addEventListener("statechange", go);
            audioCtx.resume().then(go, () => {});
          }
          return "wait";
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

        // headroom: as much as the EQ raises its loudest frequency is taken off again, so a boost
        // never clips (clipping is the crackle); flat EQ leaves it at exactly 1
        const trim = audioCtx.createGain();
        trim.gain.value = eqTrim();
        prev.connect(trim);
        prev = trim;

        const keyDry = audioCtx.createGain();
        const keyWet = audioCtx.createGain();
        const mix = audioCtx.createGain();
        const spDry = audioCtx.createGain();
        const master = audioCtx.createGain();

        keyWet.gain.value = 0;
        master.gain.value = volGain();
        prev.connect(keyDry);
        keyDry.connect(mix);
        keyWet.connect(mix);
        mix.connect(spDry);
        spDry.connect(master);
        master.connect(audioCtx.destination);

        if (!DECK) ctxEls.add(el);
        nodes = { src, mode: DECK ? "deck" : "tap", tap: null, f, trim, last: prev, keyDry, keyWet, mix, spDry, master, key: null, keyState: "off", sp: null };

        // the master gain carries the level from here on
        if (!DECK) {
          try {
            el.volume = 1;
          } catch (x) {}
        }

        if (audioCtx.state !== "running") audioCtx.resume().catch(() => {});
        if (!DECK) {
          const n = nodes;
          const an = audioCtx.createAnalyser();
          const buf = new Float32Array(512);
          let quiet = 0;
          let stuck = 0;
          let last = -1;
          let lastCtx = -1;
          let waiting = 0;

          an.fftSize = 512;
          n.master.connect(an);

          const watch = setInterval(() => {
            if (nodes !== n) return clearInterval(watch);
            if (el.paused || el.ended) {
              quiet = stuck = waiting = 0;
              last = el.currentTime;
              lastCtx = audioCtx.currentTime;
              return;
            }

            if (!audioCtx) return clearInterval(watch);
            if (audioCtx.state !== "running") {
              audioCtx.resume().catch(() => {});
              // waking from its sleep after a pause takes a moment; only a context that stays down is said
              if (++waiting >= 2) say("Sound engine is waiting: press play once more");
              return;
            }
            waiting = 0;

            an.getFloatTimeDomainData(buf);

            let peak = 0;
            for (const x of buf) peak = Math.max(peak, Math.abs(x));

            const moving = el.currentTime !== last;
            last = el.currentTime;
            quiet = moving && peak < 1e-5 && prefs.vol > 0 ? quiet + 1 : 0;

            // the context says it runs but its clock stands still: nothing is being played out
            stuck = moving && audioCtx.currentTime === lastCtx ? stuck + 1 : 0;
            lastCtx = audioCtx.currentTime;

            if (stuck >= 2 || quiet >= 6) {
              clearInterval(watch);
              soundDied();
            }
          }, 1000);
        }

        if (DECK) startDeck();

        // a later player picks Key and Space up where you left them
        if (prefs.key) applyKey();
        if (spaceOn()) applySpace();

        return true;
      } catch (e) {
        return false;
      }
    };

    // the graph went silent: carry on from here as plain playback, in a fresh element
    const soundDied = () => {
      if (webAudioDead) return;
      webAudioDead = true;
      ctxClose(); // a dead context still holds the browser's output: let it go

      const at = el.currentTime;
      const go = !el.paused;
      const item = items[cur];

      show(cur);
      if (items[cur] !== item) return;

      const n = stageMedia();
      if (!n) return;

      const resume = () => {
        try {
          n.currentTime = at;
        } catch (x) {}
        if (go) n.play().catch(() => {});
      };

      if (n.readyState >= 1) resume();
      else n.addEventListener("loadedmetadata", resume, { once: true });

      sayAll("Sound effects stopped working in this browser: playing without them");
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

      // where the deck is, and when we heard so: the transcript runs on this, the sound you hear
      d.at = m.at;
      d.atWall = performance.now();
      d.playing = !!m.playing;

      // kept within a beat of the picture; at speed a drift grows faster, so it is caught sooner
      if (!el.paused && !el.seeking && m.playing && Math.abs(m.at - el.currentTime) > 0.2 + 0.05 * el.playbackRate) {
        deckPost({ seek: el.currentTime });
      }

      const ci = chunkAt(el.currentTime);

      if (ci !== d.lastCi || m.miss >= 0) {
        d.lastCi = ci;
        feed();
      }
    };

    // The media time being heard right now. With the deck (Safari) that is the deck's own position,
    // carried forward from its last report, less its vocoder delay and the device's output latency;
    // otherwise the element's clock, less the output latency once Web Audio carries the sound.
    const heard = () => {
      const r = el.playbackRate || 1;
      const out = audioCtx ? (audioCtx.outputLatency || 0) + (audioCtx.baseLatency || 0) : 0;
      const d = deck;

      if (d && d.live && typeof d.at === "number" && !el.paused && !el.seeking) {
        const ran = d.playing ? (performance.now() - d.atWall) / 1000 : 0;
        const t = d.at + (Math.min(ran, 0.5) - out - 1792 / audioCtx.sampleRate) * r;
        if (Math.abs(t - el.currentTime) < 1.5) return Math.max(0, t);
      }

      return Math.max(0, el.currentTime - (nodes && !el.paused ? out * r : 0));
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

    // snapped to the active Key state's step: whole semitones, halves (state 8) or cents (state 9)
    const setKey = (st) => {
      st = GalleryKey.quantize(clamp(st, -KEY_MAX, KEY_MAX), prefs.keyNotation);
      if (st === prefs.key) return;

      prefs.key = st;

      if (!st && !nodes) {
        // back to 0 with no Web Audio yet: just the setting
      } else if (!ensureEq()) {
        prefs.key = 0;
        say("Key isn’t available in this browser");
      } else if (nodes) {
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
      const m = spaceOn() ? Math.abs(prefs.space.mix) / 100 : 0;
      const rev = prefs.space.mix < 0;

      if (m > 0 && (!n.sp || n.sp.room !== prefs.space.room || n.sp.rev !== rev)) {
        const old = n.sp;

        try {
          const conv = audioCtx.createConvolver();
          const wet = audioCtx.createGain();

          conv.buffer = roomIR(prefs.space.room, rev);
          wet.gain.value = 0;
          n.mix.connect(conv);
          conv.connect(wet);
          wet.connect(n.master);
          n.sp = { conv, wet, room: prefs.space.room, rev };
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
      n.spDry.gain.setTargetAtTime(spaceGain(m).dry, t, 0.012);

      if (!n.sp) return;

      if (m > 0) {
        n.sp.wet.gain.setTargetAtTime(spaceGain(m).wet, t, 0.012);
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

      prefs.space.mix = Math.round(clamp(mix, -100, 100));
      prefs.space.on = on;

      if (!ensureEq()) {
        prefs.space = old;
        say("Space isn’t available in this browser");
      } else if (nodes) {
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

    // a label never widens the column: each line shrinks (to 8px at least) until it fits
    // (the caption too, so "Maqam¼" fits a narrow column)
    const fitKey = () => {
      const w = key.val.clientWidth;
      if (!w) return;

      const r = document.createRange();
      const wide = (s) => {
        r.selectNodeContents(s);
        return r.getBoundingClientRect().width > w - (s === key.lab ? 4 : 0);
      };

      [...key.val.querySelectorAll("span"), key.lab].forEach((s) => {
        s.style.fontSize = "";
        let px = parseFloat(getComputedStyle(s).fontSize) || 12;
        while (wide(s) && px > 8) {
          px = Math.max(8, px - 0.5);
          s.style.fontSize = px + "px";
        }
      });
    };

    const paintKey = () => {
      const st = prefs.key;
      const L = GalleryKey.label(st, prefs.keyNotation, (item && item.key) || "", prefs.nativeLang);
      const said = L.lines.join(" ");
      const pct = ((KEY_MAX - st) / (KEY_MAX * 2)) * 100;

      key.knob.style.top = pct + "%";
      key.fill.style.top = Math.min(pct, 50) + "%";
      key.fill.style.height = Math.abs(50 - pct) + "%";

      if (key.val.dataset.said !== said) {
        key.val.dataset.said = said;
        key.val.classList.toggle("two", L.lines.length > 1);
        key.val.replaceChildren(
          ...L.lines.map((t) => {
            const s = mkEl("span");
            s.textContent = t;
            return s;
          })
        );
        fitKey();
      }

      key.val.setAttribute("aria-label", "Key " + said);
      if (key.lab.textContent !== L.caption) {
        key.lab.textContent = L.caption;
        fitKey();
      }
      key.lab.setAttribute("aria-label", "Key notation: " + L.caption + ". Tap to reset the key; hold, swipe up or point at it for the list");
      key.pop.querySelectorAll(".krow").forEach((r) => {
        const on = Number(r.dataset.state) === prefs.keyNotation;
        r.classList.toggle("on", on);
        r.setAttribute("aria-selected", String(on));
      });
      key.col.classList.toggle("on", st !== 0);
      key.trk.setAttribute("aria-valuenow", String(st));
      key.trk.setAttribute("aria-valuetext", st ? said : "original key, " + said);
    };

    const paintSpace = () => {
      const m = prefs.space.mix;
      const on = spaceOn();
      const room = ROOMS[prefs.space.room].label;
      const pct = ((100 - m) / 200) * 100;
      const txt = (m > 0 ? "+" : m < 0 ? "−" : "") + Math.abs(m) + "%";

      sp.knob.style.top = pct + "%";

      if (m >= 0) {
        sp.fill.style.top = pct + "%";
        sp.fill.style.height = 50 - pct + "%";
      } else {
        sp.fill.style.top = "50%";
        sp.fill.style.height = pct - 50 + "%";
      }

      sp.val.textContent = !m ? "0" : on ? txt : "Off";
      sp.val.setAttribute(
        "aria-label",
        on ? "Space " + txt + " — tap to bypass" : m ? "Space bypassed — tap to bring it back" : "Space off"
      );
      sp.lab.textContent = "Reverb";
      sp.lab.setAttribute("aria-label", "Reset Reverb");
      sp.col.classList.toggle("on", on);
      sp.trk.setAttribute("aria-valuenow", String(on ? m : 0));
      sp.trk.setAttribute("aria-valuetext", on ? (m < 0 ? "Reversed " : "") + room + " " + Math.abs(m) + "%" : "off");
    };

    // keepCurve: leave the curve to an animation that is under way
    const paintEq = (keepCurve) => {
      EQ_BANDS.forEach((b) => paintBand(b.id));

      const flat = eqIsFlat();
      const plain = flat && !prefs.key && !spaceOn();

      eqBtn.classList.toggle("on", !plain);
      eqFlat.hidden = flat;
      graph.classList.toggle("on", !plain);
      eqBtn.setAttribute("aria-label", plain ? "Sound (untouched)" : "Sound (shaped)");

      if (!keepCurve && !eq.hidden) {
        cancelAnimationFrame(curveRaf);
        shown = curveNow();
        drawCurve(shown);
      }
    };

    const setBand = (id, db) => {
      db = Math.round(clamp(db, -EQ_MAX, EQ_MAX));

      const old = prefs.eq[id];
      prefs.eq[id] = db;

      // back to flat with no Web Audio yet: nothing to change but the setting
      if (!db && !nodes) return paintEq();

      if (!ensureEq()) {
        prefs.eq[id] = old;
        paintEq();
        say("EQ isn’t available in this browser");
        return;
      }

      if (!nodes) return paintEq(); // taken up with the graph once the sound engine runs

      // the trim comes down with the boost, never after it, and goes back up as the boost eases
      const t = audioCtx.currentTime;
      const g = eqTrim();
      nodes.f[id].gain.cancelScheduledValues(t);
      nodes.f[id].gain.setTargetAtTime(db, t, 0.03);
      nodes.trim.gain.cancelScheduledValues(t);
      nodes.trim.gain.setTargetAtTime(g, t, g < nodes.trim.gain.value ? 0.005 : 0.06);
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
      setKey(kg.st + dy / KEY_PX); // (setKey snaps it to the state's step)
      bumpEq();
    };

    const keyStep = () => GalleryKey.STEPS[prefs.keyNotation];

    key.trk.onpointerup = (e) => {
      if (kg && !kg.moved) {
        // a tap: one step towards where you tapped
        const r = key.knob.getBoundingClientRect();
        const mid = r.top + r.height / 2;

        if (e.clientY < mid - 3) setKey(prefs.key + keyStep());
        else if (e.clientY > mid + 3) setKey(prefs.key - keyStep());
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

      if (e.key === "ArrowUp") n = prefs.key + keyStep();
      else if (e.key === "ArrowDown") n = prefs.key - keyStep();
      else if (e.key === "PageUp") n = prefs.key + 12;
      else if (e.key === "PageDown") n = prefs.key - 12;
      else if (e.key === "0" || e.key === "Backspace" || e.key === "Home") n = 0;

      if (n === null) return;

      e.preventDefault();
      e.stopPropagation();
      setKey(n);
      bumpEq();
    };

    // ----- the Key caption: which notation the value above is spelled in -----
    //
    // Tap or click: the next state. Right-click / two-finger tap: the one before. Two fingers
    // across it on a trackpad: one state per swipe. Hold 350 ms: the list, picked by lifting and
    // tapping a row, or by sliding onto one and letting go. All of it wraps around the 10 states.
    // Changing state snaps the key to the new step at once (sound, thumb and label).
    const setKeyNotation = (n) => {
      n = ((n % GalleryKey.STATES) + GalleryKey.STATES) % GalleryKey.STATES;
      prefs.keyNotation = n;

      if (!SHARED) {
        try {
          localStorage.setItem(KEY_NOTATION, String(n));
        } catch (e) {}
      }

      const snapped = GalleryKey.quantize(prefs.key, n);
      if (snapped !== prefs.key) setKey(snapped);
      paintKey();
      bumpEq();
    };

    const KEY_HOLD_MS = 350;
    let capHold = 0; // the long-press timer
    let capHeld = false; // it fired: the click that follows is not a tap
    let capTouch = false; // the last press was a finger (its long-press contextmenu is not "back")
    let capWheelAt = 0;

    const openKeyPop = () => {
      key.pop.hidden = false;
      eqWrap.classList.add("kpop");
      bDrag = "keypop"; // keeps the tray open while the list is up

      // each row shrinks to fit the pill; if one still can't fit at 9px, the pill widens instead
      key.pop.style.width = "";
      let wide = false;
      key.pop.querySelectorAll(".krow").forEach((r) => {
        r.style.fontSize = "";
        let px = parseFloat(getComputedStyle(r).fontSize) || 11;
        while (r.scrollWidth > r.clientWidth && px > 9) {
          px = Math.max(9, px - 0.5);
          r.style.fontSize = px + "px";
        }
        if (r.scrollWidth > r.clientWidth) wide = true;
      });
      key.pop.style.width = "";

      paintKey();
      // the barrel rolls to the notation in use
      const on = key.pop.querySelector(".krow.on");
      if (on) key.pop.scrollLeft = on.offsetLeft + on.offsetWidth / 2 - key.pop.clientWidth / 2;
    };

    function closeKeyPop() {
      if (key.pop.hidden) return;
      key.pop.hidden = true;
      eqWrap.classList.remove("kpop");
      if (bDrag === "keypop") bDrag = null;
      bumpEq();
    }

    const rowAt = (x, y) => {
      const t = document.elementFromPoint(x, y);
      const r = t && t.closest && t.closest(".krow");
      return r && key.pop.contains(r) ? r : null;
    };

    // The list opens four ways: hold the caption (touch), press it and swipe up with one finger, rest the pointer
    // on it, or swipe up over it with two fingers on a trackpad.
    const KEY_SWIPE_PX = 24;
    const KEY_HOVER_MS = 280;
    let capY = null; // where the press started, for the swipe up
    let hoverOpen = 0;
    let hoverClose = 0;

    key.lab.addEventListener("pointerdown", (e) => {
      capTouch = e.pointerType === "touch";
      capHeld = false;
      capY = e.button === 0 ? e.clientY : null;
      clearTimeout(capHold);
      if (e.button !== 0) return;

      try {
        key.lab.setPointerCapture(e.pointerId);
      } catch (x) {}

      capHold = setTimeout(() => {
        capHeld = true;
        openKeyPop();
      }, KEY_HOLD_MS);
      wake();
    });

    key.lab.addEventListener("pointermove", (e) => {
      if (!capHeld && capY !== null && e.pointerType !== "mouse" && capY - e.clientY > KEY_SWIPE_PX) {
        clearTimeout(capHold);
        capHeld = true;
        openKeyPop();
      }
      if (!capHeld || key.pop.hidden) return;
      const r = rowAt(e.clientX, e.clientY);
      key.pop.querySelectorAll(".krow").forEach((x) => x.classList.toggle("hover", x === r));
    });

    key.lab.addEventListener("pointerup", (e) => {
      clearTimeout(capHold);
      capY = null;
      if (!capHeld || key.pop.hidden) return;

      // press, slide onto a row, let go: that row. Let go elsewhere: the list stays for a tap.
      const r = rowAt(e.clientX, e.clientY);
      if (r) {
        setKeyNotation(Number(r.dataset.state));
        closeKeyPop();
      }
    });

    key.lab.addEventListener("pointercancel", () => {
      clearTimeout(capHold);
      capY = null;
    });

    // a mouse or trackpad pointer resting on the caption opens the list; leaving both closes it
    const hoverIn = (e) => {
      if (e.pointerType !== "mouse") return;
      clearTimeout(hoverClose);
      if (key.pop.hidden) hoverOpen = setTimeout(openKeyPop, KEY_HOVER_MS);
    };
    const hoverOut = (e) => {
      if (e.pointerType !== "mouse") return;
      clearTimeout(hoverOpen);
      hoverClose = setTimeout(() => {
        if (!key.lab.matches(":hover") && !key.pop.matches(":hover")) closeKeyPop();
      }, KEY_HOVER_MS);
    };
    key.lab.addEventListener("pointerenter", hoverIn);
    key.lab.addEventListener("pointerleave", hoverOut);
    key.pop.addEventListener("pointerenter", hoverIn);
    key.pop.addEventListener("pointerleave", hoverOut);

    key.lab.addEventListener("click", (e) => {
      e.stopPropagation();

      if (capHeld) {
        capHeld = false; // the click that ends a long press
        return;
      }

      // tap: Key back to 0, as a band's name puts it back to flat
      closeKeyPop();
      setKey(0);
      flash(key.col);
      bumpEq();
    });

    key.lab.addEventListener("contextmenu", (e) => {
      e.preventDefault();
      e.stopPropagation();
      if (capTouch || capHeld) return; // a finger held down, not a right-click
      closeKeyPop();
      setKeyNotation(prefs.keyNotation - 1);
    });

    key.lab.addEventListener(
      "wheel",
      (e) => {
        e.preventDefault();
        e.stopPropagation(); // not the slider's own wheel
        if (e.ctrlKey || !e.deltaY) return;

        // one swipe, however many events (and momentum) it brings, is one state
        const now = performance.now();
        const fresh = now - capWheelAt > 120;
        capWheelAt = now;
        if (!fresh) return;
        // two fingers up (natural scrolling: content moves down, deltaY > 0) opens the list; down closes it, or
        // with it closed steps back a notation
        if (e.deltaY > 0) {
          if (key.pop.hidden) openKeyPop();
        } else if (!key.pop.hidden) closeKeyPop();
        else setKeyNotation(prefs.keyNotation - 1);
      },
      { passive: false }
    );

    key.pop.addEventListener("click", (e) => {
      e.stopPropagation();
      const r = e.target.closest(".krow");
      if (!r) return;
      setKeyNotation(Number(r.dataset.state));
      closeKeyPop();
    });

    key.pop.addEventListener("contextmenu", (e) => e.preventDefault());

    // a tap anywhere else closes the list with no change
    const keyPopAway = (e) => {
      if (key.pop.hidden || key.pop.contains(e.target) || key.lab.contains(e.target)) return;
      closeKeyPop();
    };
    document.addEventListener("pointerdown", keyPopAway, true);

    const spFrom = (e) => {
      const r = sp.inn.getBoundingClientRect();
      const f = r.height ? clamp((e.clientY - r.top) / r.height) : 0.5;
      setSpace(100 - f * 200, true);
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
      else if (e.key === "End") n = -100;
      else if (e.key === "0" || e.key === "Backspace") n = 0;

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

    // tap the name to put the reverb back to 0
    sp.lab.onclick = (e) => {
      e.stopPropagation();
      // nothing to undo without Web Audio: just the setting (no AudioContext for a reset)
      if (nodes) setSpace(0, prefs.space.on);
      else prefs.space.mix = 0;
      paintSpace();
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
    let hbMode = "play"; // what the bar shows: "play" (Play · ±15s), "loop" (Track Loop · A–B), "speed", or "seek" (the ruler)
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
      playRow.setAttribute("aria-hidden", String(!hbOpen || hbMode !== "play"));
      row.setAttribute("aria-hidden", String(!hbOpen || hbMode !== "loop"));
      speedRow.setAttribute("aria-hidden", String(!hbOpen || hbMode !== "speed"));

      line.setAttribute(
        "aria-label",
        !hbOpen
          ? "Open play controls"
          : hbMode === "play"
          ? "Loop controls"
          : hbMode === "loop"
          ? "Playback speed"
          : hbMode === "speed"
          ? "Back to play controls"
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

    // Speed hands the bar back to Play · ±15s after a few quiet seconds (never mid-drag).
    const armMode = () => {
      clearTimeout(modeT);

      modeT = setTimeout(() => {
        if (sDrag) armMode();
        else setMode("play");
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
      [sp.knob, { top: "50%" }],
      [sp.fill, { top: "50%", height: "0%" }],
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
        fitKey();
        eqWrap.style.setProperty("--sph", eqIn.offsetHeight + "px");

        if (calm) {
          paintEq();
        } else {
          cancelAnimationFrame(curveRaf);
          shown = { ...FLAT };
          drawCurve(shown);
          // (the beads follow the curve: see drawCurve)
          morph(curveNow(), 520);
        }

        eqWrap.classList.add("open");
        return;
      }

      eqWrap.classList.remove("open");
      closeKeyPop();

      if (!calm) {
        // (the beads follow the curve: see drawCurve)
        morph(FLAT, 240);
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

    // ----- Volume: two fingers along the stroke -----
    //
    // The stroke's own twin of Time Seeking, at the same sensitivity: two fingers (on a screen, or
    // on a trackpad) sliding along it lay a temporary ruler of 0 to 100% beside it, with the
    // level where you are. Up raises, down lowers, one pixel of fingers for one pixel of ruler.
    // The ruler is put away a moment after the fingers stop.

    const VOL_PX = 160;
    const volEl = mkEl("span", "p-vol");

    volEl.append(mkEl("span", "p-vt"), mkEl("span", "p-vf"), mkEl("span", "p-vb"));
    eqBtn.appendChild(volEl);

    let volT = 0;
    let volTouch = null; // two fingers down on the stroke: { y0, v0 }
    let volWheel = null; // a trackpad swipe on it: { v0, sum, t }
    let volEndAt = -1e9;

    const showVol = () => {
      volEl.style.setProperty("--v", String(prefs.vol));
      volEl.classList.add("on");
      clearTimeout(volT);
      volT = setTimeout(() => volEl.classList.remove("on"), 900);
      wake();
    };

    const avgY = (ts) => (ts[0].clientY + ts[1].clientY) / 2;

    eqBtn.addEventListener(
      "touchstart",
      (e) => {
        if (e.touches.length !== 2) return;

        volTouch = { y0: avgY(e.touches), v0: prefs.vol };
        e.preventDefault();
      },
      { passive: false }
    );

    eqBtn.addEventListener(
      "touchmove",
      (e) => {
        if (!volTouch || e.touches.length !== 2) return;

        e.preventDefault();
        setVol(volTouch.v0 + (volTouch.y0 - avgY(e.touches)) / VOL_PX);
        showVol();
      },
      { passive: false }
    );

    // Safari and iPhone only let a context start (or restart) on a finger lifting or a click, so
    // the end of a volume swipe is where a graph the swipe had to start is brought to life.
    const unlockAudio = () => {
      if (audioCtx && audioCtx.state !== "running") audioCtx.resume().catch(() => {});
    };

    const endVolTouch = (e) => {
      if (!volTouch || e.touches.length >= 2) return;

      volTouch = null;
      volEndAt = performance.now();
      unlockAudio();
    };

    eqBtn.addEventListener("touchend", endVolTouch);
    eqBtn.addEventListener("touchcancel", endVolTouch);

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

        // two fingers along the stroke itself: the volume ruler
        if (e.target.closest(".p-eqbtn")) {
          if (w2.side) return;
          e.preventDefault();

          if (!volWheel) volWheel = { v0: prefs.vol, sum: 0, t: 0 };

          volWheel.sum += w2.up;
          setVol(volWheel.v0 + volWheel.sum / VOL_PX);
          showVol();
          clearTimeout(volWheel.t);
          volWheel.t = setTimeout(() => {
            volWheel = null;
          }, 180);
          return;
        }

        if (!eqOpen) return;

        // two fingers on the notation barrel only roll the barrel, never the Key
        if (e.target.closest(".kpop")) {
          if (vs && vs.col === "key") vs = null;
          if (!w2.side) {
            e.preventDefault();
            key.pop.scrollLeft += e.deltaX * (e.deltaMode === 1 ? 16 : e.deltaMode === 2 ? 400 : 1);
          }
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
          setKey(vs.from + vs.sum / KEY_PX); // (setKey snaps it to the state's step)
        } else {
          const h = (vs.col === "space" ? sp.inn : bands[vs.col].inn).getBoundingClientRect().height || 100;

          if (vs.col === "space") setSpace(vs.from + (vs.sum / h) * 200, true);
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
      if (!hbOpen) hbMode = "play"; // every unfold starts with Play · ±15s…
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
    // showed Play · ±15s, so a click asks for Loop · A–B, the next for Speed, then back to Play.
    // With a finger (or the keyboard) the first tap unfolds Play · ±15s, then the same cycle.
    line.onclick = (e) => {
      e.stopPropagation();

      const kind = ptype;

      ptype = "";

      if (suppressClick) {
        suppressClick = false;
        return;
      }

      const next = { play: "loop", loop: "speed", speed: "play" };

      if (!hbOpen) {
        showHb(4500, kind === "mouse" ? "loop" : undefined);
      } else {
        setMode(next[hbMode] || "play");
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

    // Pressing the stroke while the sound is shaped (it glows blue) puts everything back to
    // the original, and the stroke turns white again. Pressing it flat opens and closes the tray.
    const resetSound = () => {
      const was = { ...shown };

      EQ_BANDS.forEach((b) => {
        if (prefs.eq[b.id]) setBand(b.id, 0);
      });

      setKey(0);
      if (prefs.space.mix) setSpace(0, false);

      shown = was;
      morph(FLAT, 380);
      say("Sound reset");
    };

    eqBtn.onclick = (e) => {
      e.stopPropagation();
      if (performance.now() - volEndAt < 450) return; // the end of a volume swipe is not a press

      if (eqOpen && eqBtn.classList.contains("on")) {
        resetSound();
        bumpEq();
      } else if (eqOpen) {
        hideEq();
      } else {
        showEq(5000);
      }
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

    const chrome = [ctrl, hb];
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
      // Web Audio only once Sound needs it: on some Macs (Firefox, audio routing apps) creating an
      // AudioContext blocks the page for good, and plain playback never needs one
      if (!DECK && !nodes && (!eqIsFlat() || prefs.key || spaceOn())) ensureEq();
      sync();
      watch();

      // a suspended (or sleeping) context would silence a connected element: wake it on the play gesture
      clearTimeout(ctxSleepT);
      if (nodes && audioCtx && audioCtx.state !== "running") audioCtx.resume().catch(() => {});

      wake();
    };

    el.onpause = () => {
      sync();
      if (nodes && !DECK) ctxSleep();
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

      if (!e.target.closest(".p-ctrl") && !inTools) {
        toggle();
      }

      wake();
    };

    w.append(shelter(el), hb, ctrl, toast);

    // a later player picks the EQ up where you left it (the context already runs)
    if (audioCtx && (!eqIsFlat() || prefs.key || spaceOn())) ensureEq();
    if (prefs.vol !== 1) setVol(prefs.vol);

    paintSpeed();
    paintKey();
    paintSpace();
    paintLoop();
    paintEq();
    sync();

    activePlayer = {
      el,
      wrap: w,
      item,
      toggle,
      heard,
      note: say,
      repaintKey: paintKey, // after the item's original key, or the native language, changes
      setNotation: (n) => setKeyNotation(n),
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
        clearTimeout(capHold);
        document.removeEventListener("pointerdown", keyPopAway, true);
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
            [n.keyDry, n.keyWet, n.mix, n.spDry, n.master].forEach((x) => x && x.disconnect());

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

        // the last player off the context closes it (the next play with Sound on makes a new one)
        ctxEls.delete(el);
        if (!DECK && audioCtx && !ctxEls.size) ctxClose();
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
    ({ img: "photo", vid: "video", aud: "audio file", doc: isPdf(f) || isTextDoc(f) ? "document" : "file" })[kind(f)];

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
  let footBase = "";

  const readyItems = () => items.filter((f) => !f.pending);

  // what is picked in Select mode, for the "…" menu's Create Share Link
  window.gallerySelection = () => (selecting ? readyItems().filter((f) => picked.has(f.n)) : []);

  const label = () => {
    const n = picked.size;
    const sel = selecting && n > 0;

    dl.textContent = n ? "Download (" + n + ")" : "Download";
    dl.disabled = !readyItems().length;
    dl.classList.toggle("glow", sel);

    $("selall").hidden = !selecting;
    $("selall").textContent = n ? "Deselect All" : "Select All";

    $("ftxt").textContent = sel ? n + (n === 1 ? " Item Selected" : " Items Selected") : footBase;
    $("foot").classList.toggle("sel", sel);

    del.hidden = !(owner && sel);
    del.disabled = !readyItems().length;
    $("mv").hidden = !(G.main && owner && sel);
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
    $("count").hidden = !!G.main && total === 0;
    $("exp").textContent = G.exp ? "Expires " + D(G.exp, { day: "numeric", month: "long" }) : "";

    const c = { img: 0, vid: 0, aud: 0, doc: 0 };
    ready.forEach((f) => c[kind(f)]++);

    footBase = [["Photo", c.img], ["Video", c.vid], ["Audio", c.aud], ["File", c.doc]]
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
  let y0 = 0;

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
    txsPill.hidden = true; // back once this item's subtitles are up
    paintCap();

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
    } else if (parked && parked.item === f) {
      // the track still playing from before: back on stage as it is
      const p = parked;
      parked = null;
      pill.hidden = true;
      stage.appendChild(p.wrap);
      activePlayer = p;
    } else if (k === "vid") {
      stage.appendChild(buildMedia("video", s));
      showTranscript(f);
    } else if (k === "aud") {
      stage.appendChild(buildMedia("audio", s, artSrc(f)));
      showTranscript(f);
      autoKey(f);
    } else if (isPdf(f)) {
      stage.appendChild(buildPdf(f));
    } else if (isTextDoc(f)) {
      stage.appendChild(buildTextDoc(f));
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
    document.body.classList.add("lbopen");
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
    document.body.classList.remove("lbopen", "comments-open");
    thread.hidden = true;
  };

  $("sel").onclick = () => {
    selecting = !selecting;
    picked.clear();

    document.body.classList.toggle("selecting", selecting);
    $("sel").textContent = selecting ? "Cancel" : "Select";

    grid.querySelectorAll(".on").forEach((t) => t.classList.remove("on"));
    label();
  };

  $("selall").onclick = () => {
    if (picked.size) picked.clear();
    else readyItems().forEach((f) => picked.add(f.n));

    grid.querySelectorAll(".tile").forEach((b) => b.classList.toggle("on", picked.has(b.dataset.n)));
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

  // ---------- comments: a thread per item (README §3, §4.4) ----------
  //
  // COLLAPSED: one blue label in the bottom bar ("Add a comment…" / "3 comments").
  // EXPANDED (body.comments-open): the media shrinks to the top, the thread fills the rest,
  // oldest first, with the field directly under the newest comment. Tap the label or swipe up
  // on the media to open; Hide Comments, swipe down, Delete or Cancel close it.
  // Who may write: Main = the owner; an invite = the participant (if allowed); a public link =
  // the owner only. The server enforces the same rules.

  const cmEl = $("cm");
  const botBar = document.querySelector(".bot");
  const ownerName = String(G.owner || "").split(" ")[0] || "Owner";
  const me = G.invite ? G.invite.name : G.owner;
  const API = G.api || "/main/api";
  let owner = false;
  let draft = "";

  const thread = mkEl("div", "thread");
  thread.id = "thread";
  thread.hidden = true;
  lb.appendChild(thread);

  // the bottom bar's height drives the media padding; keep it current
  const sizeBar = () => {
    if (botBar && !lb.hidden && botBar.offsetHeight) lb.style.setProperty("--bb", botBar.offsetHeight + "px");
  };

  if (window.ResizeObserver && botBar) new ResizeObserver(sizeBar).observe(botBar);

  const commentScope = (f) =>
    G.main || G.invite ? { kind: "main", path: f.path || f.name } : { kind: "link", id: G.id, key: f.path || f.n };

  const canWrite = () => (G.invite ? !!(G.invite.perms && G.invite.perms.comment) : owner);
  const listOf = (f) => (f && Array.isArray(f.comments) ? f.comments : f && f.caption ? [{ id: "c0", text: f.caption, at: f.capAt, by: G.owner }] : []);
  const mine = (c) => (G.invite ? c.by === me : !c.by || c.by === G.owner);
  const nameOf = (c) => (mine(c) ? "You" : c.by === G.owner || !c.by ? ownerName : c.by);
  const postedAt = (t) => D(t, { day: "numeric", month: "short", year: "numeric" }) + " at " + T(t);
  const isOpen = () => document.body.classList.contains("comments-open");

  const send = async (f, body) => {
    const r = await fetch(API + "/caption", {
      method: "PUT",
      headers: { "content-type": "application/json", "x-gallery": "1" },
      body: JSON.stringify({ ...commentScope(f), ...body }),
    });

    if (!r.ok) throw new Error((await r.text()) || "Couldn’t save the comment");

    const j = await r.json();
    f.comments = j.comments || [];
    f.caption = j.caption || "";
    f.capAt = j.capAt || 0;
  };

  const setOpen = (o) => {
    const f = items[cur];
    if (o && (!f || f.pending || (!listOf(f).length && !canWrite()))) return;

    document.body.classList.toggle("comments-open", !!o);
    thread.hidden = !o;
    if (!o) draft = "";
    paintComment();
  };

  // the collapsed label in the bottom bar
  const paintLabel = (f) => {
    const n = listOf(f).length;

    cmEl.replaceChildren();
    cmEl.hidden = !f || f.pending || (!n && !canWrite());
    if (cmEl.hidden) return;

    const label = mkEl("button", "cmlabel");
    label.type = "button";
    label.textContent = n ? n + (n === 1 ? " comment" : " comments") : "Add a comment…";
    label.onclick = () => setOpen(true);
    cmEl.appendChild(label);
  };

  // Swipe to reveal Delete at a comment's right end (spec §7). Touch: a swipe leftward that starts on
  // the right half of the comment. Trackpad: a two-finger swipe right to left while the pointer is
  // over it (a horizontal wheel). The other way, a tap elsewhere or Escape folds it back.
  let swOpen = null;
  const swFold = () => {
    if (swOpen) swOpen.classList.remove("open");
    swOpen = null;
  };
  const swSet = (row, on) => {
    if (on && swOpen !== row) swFold();
    row.classList.toggle("open", on);
    swOpen = on ? row : swOpen === row ? null : swOpen;
  };

  const swipeToDelete = (row, rm) => {
    const slide = mkEl("div", "cslide");
    slide.append(...row.childNodes);
    row.classList.add("sw");
    row.append(slide, rm);
    const W = () => rm.offsetWidth || 88;

    let t0 = null; // { x, y, open, h } while a finger is down
    row.addEventListener(
      "touchstart",
      (e) => {
        const r = row.getBoundingClientRect();
        const x = e.touches[0].clientX;
        const open = row.classList.contains("open");
        t0 = open || x > r.left + r.width / 2 ? { x, y: e.touches[0].clientY, open, h: null } : null;
      },
      { passive: true }
    );
    row.addEventListener(
      "touchmove",
      (e) => {
        if (!t0) return;
        const dx = e.touches[0].clientX - t0.x;
        const dy = e.touches[0].clientY - t0.y;
        if (t0.h === null && (Math.abs(dx) > 8 || Math.abs(dy) > 8)) t0.h = Math.abs(dx) > Math.abs(dy);
        if (!t0.h) return;
        e.preventDefault();
        row.classList.add("drag");
        const off = clamp((t0.open ? -W() : 0) + dx, -W(), 0);
        slide.style.transform = "translateX(" + off + "px)";
      },
      { passive: false }
    );
    row.addEventListener("touchend", (e) => {
      if (!t0) return;
      const dx = e.changedTouches[0].clientX - t0.x;
      const h = t0.h;
      const open = t0.open;
      t0 = null;
      row.classList.remove("drag");
      slide.style.transform = "";
      if (h) swSet(row, open ? dx < W() / 2 : dx < -W() / 2);
    });

    // the keyboard reaches it too: focusing Delete shows it
    rm.addEventListener("focus", () => swSet(row, true));
  };

  // the trackpad: one listener on the thread, for whichever comment the pointer is over
  let swAcc = 0;
  let swAccT = 0;
  thread.addEventListener(
    "wheel",
    (e) => {
      const row = e.target.closest && e.target.closest(".crow.sw");
      if (!row || Math.abs(e.deltaX) <= Math.abs(e.deltaY)) return;
      e.preventDefault(); // not the browser's back and forward
      if (e.timeStamp - swAccT > 300) swAcc = 0;
      swAccT = e.timeStamp;
      swAcc += e.deltaX;
      if (swAcc > 40) {
        swSet(row, true);
        swAcc = 0;
      } else if (swAcc < -40) {
        swSet(row, false);
        swAcc = 0;
      }
    },
    { passive: false }
  );

  document.addEventListener("pointerdown", (e) => {
    if (swOpen && !swOpen.contains(e.target)) swFold();
  });
  document.addEventListener("keydown", (e) => {
    if (e.key !== "Escape" || !swOpen) return;
    e.stopPropagation(); // fold Delete away, not the viewer
    swFold();
  });

  const paintThread = (f) => {
    const list = listOf(f);
    const can = canWrite();

    thread.replaceChildren();
    swOpen = null;

    const actions = mkEl("div", "tact");
    const hideBtn = mkEl("button", "lnk");
    hideBtn.type = "button";
    hideBtn.textContent = "Hide Comments";
    hideBtn.onclick = () => setOpen(false);
    actions.appendChild(hideBtn);
    thread.appendChild(actions);

    for (const c of list) {
      const row = mkEl("div", "crow");
      const p = mkEl("p", "ctext");
      const by = mkEl("p", "cmeta");
      const b = mkEl("b");

      p.textContent = c.text;
      b.textContent = nameOf(c);
      by.append(b, " " + (c.at ? postedAt(c.at) : "") + (c.edited ? " · Edited" : ""));
      row.append(p, by);

      // your own comments can be edited or deleted, any of them, at any time; Delete is revealed by
      // a swipe to the left (spec §7)
      if (can && mine(c) && c.id) {
        const ed = { disabled: false }; // tapping the text edits it; a deliberate tap only, never a scroll or swipe
        const rm = mkBtn("cdel", "Delete comment", "Delete");
        p.classList.add("cmine");
        p.title = "Tap to edit";
        swipeToDelete(row, rm);
        let tap = null;
        p.addEventListener("pointerdown", (e) => {
          tap = e.isPrimary && e.button === 0 ? { x: e.clientX, y: e.clientY, t: e.timeStamp, st: thread.scrollTop } : null;
        });
        p.addEventListener("pointermove", (e) => {
          if (tap && Math.hypot(e.clientX - tap.x, e.clientY - tap.y) > 6) tap = null;
        });
        p.addEventListener("pointercancel", () => (tap = null));
        thread.addEventListener("scroll", () => (tap = null), { passive: true });
        p.addEventListener("pointerup", (e) => {
          const t = tap;
          tap = null;
          if (!t || ed.disabled || row.classList.contains("open")) return;
          if (e.timeStamp - t.t > 450 || Math.hypot(e.clientX - t.x, e.clientY - t.y) > 6) return;
          if (Math.abs(thread.scrollTop - t.st) > 1) return;
          const sel = window.getSelection && String(window.getSelection());
          if (sel) return;
          // let any momentum scroll settle; a tap that only stopped a fling doesn't edit
          setTimeout(() => {
            if (Math.abs(thread.scrollTop - t.st) <= 1 && p.isConnected) ed.onclick();
          }, 120);
        });

        rm.onclick = async () => {
          if (!confirm("Delete this comment?")) return;
          ed.disabled = rm.disabled = true;
          try {
            await send(f, { op: "del", cid: c.id });
            paintComment();
          } catch (e) {
            ed.disabled = rm.disabled = false;
            tell(e.message || "Couldn’t delete the comment", true);
          }
        };

        ed.onclick = () => {
          const box = mkEl("textarea", "cedit");
          const bar = mkEl("div", "cbtns");
          const save = mkBtn("lnk", "Save comment", "Save");
          const back = mkBtn("lnk", "Cancel editing", "Cancel");
          const fitE = () => {
            box.style.height = "auto";
            box.style.height = box.scrollHeight + "px";
            save.disabled = !box.value.trim() || box.value.trim() === c.text;
          };

          box.maxLength = 4000;
          box.value = c.text;
          bar.append(save, back);
          row.classList.remove("sw", "open");
          row.replaceChildren(box, bar);
          box.oninput = fitE;
          fitE();
          box.focus();

          back.onclick = () => paintComment();
          const doSave = async () => {
            const text = box.value.trim();
            if (!text || text === c.text) return paintComment();
            save.disabled = back.disabled = true;
            try {
              await send(f, { op: "edit", cid: c.id, text });
              paintComment();
            } catch (e) {
              save.disabled = back.disabled = false;
              tell(e.message || "Couldn’t save the comment", true);
            }
          };
          save.onclick = doSave;
          box.onkeydown = (e) => {
            if (e.key === "Enter" && !e.shiftKey && !e.isComposing) {
              e.preventDefault();
              doSave();
            } else if (e.key === "Escape") paintComment();
          };
        };
      }

      thread.appendChild(row);
    }

    if (!can) return;

    // the field, always directly under the newest comment
    const field = mkEl("div", "cfield");
    const ta = mkEl("textarea");
    const btns = mkEl("div", "cbtns");
    const post = mkBtn("lnk", "Post comment", "Post");
    const del = mkBtn("lnk", "Delete my last comment", "Delete");
    const cancel = mkBtn("lnk", "Cancel", "Cancel");
    const last = [...list].reverse().find(mine);

    ta.rows = 1;
    ta.maxLength = 4000;
    ta.placeholder = "Add a comment…";
    ta.value = draft;
    ta.setAttribute("enterkeyhint", "send");

    const fit = () => {
      ta.style.height = "auto";
      ta.style.height = ta.scrollHeight + "px";
      post.disabled = !ta.value.trim();
    };

    del.disabled = !last;
    btns.append(post, del, cancel);
    // always shown: after a post iPhone won't focus the new field by itself, which used to leave
    // no way to delete or cancel
    field.append(ta, btns);
    thread.appendChild(field);

    ta.oninput = () => {
      draft = ta.value;
      fit();
    };
    ta.onfocus = () => {
      field.scrollIntoView({ block: "end", behavior: "smooth" });
    };

    const busy = (on) => {
      [post, del, cancel].forEach((b) => (b.disabled = on));
      if (!on) {
        del.disabled = !last;
        fit();
      }
    };

    const doPost = async () => {
      const text = ta.value.trim();
      if (!text) return;

      busy(true);

      try {
        await send(f, { op: "add", text });
        draft = "";
        paintComment();
        // stay expanded with a fresh field under the new comment
        const nta = thread.querySelector("textarea");
        if (nta) nta.focus();
        thread.scrollTop = thread.scrollHeight;
      } catch (e) {
        busy(false);
        fit();
        tell(e.message || "Couldn’t save the comment", true);
      }
    };

    post.onclick = doPost;
    ta.onkeydown = (e) => {
      // Return posts (Shift+Return is a new line), like Messages
      if (e.key === "Enter" && !e.shiftKey && !e.isComposing) {
        e.preventDefault();
        doPost();
      }
    };

    del.onclick = async () => {
      if (!last) return;

      busy(true);

      try {
        await send(f, { op: "del", cid: last.id });
        setOpen(false);
      } catch (e) {
        busy(false);
        tell(e.message || "Couldn’t delete the comment", true);
      }
    };

    cancel.onclick = () => setOpen(false);

    fit();
  };

  const paintComment = () => {
    if (!cmEl) return;

    const f = items[cur];

    // the thread belongs to one item: moving on closes it
    if (isOpen() && (!f || f.pending || (!listOf(f).length && !canWrite()))) {
      document.body.classList.remove("comments-open");
      thread.hidden = true;
    }

    paintLabel(f);
    if (isOpen()) paintThread(f);
    sizeBar();
  };

  const paintCap = paintComment;

  // swipe down on the thread (when it is scrolled to the top) closes it
  let ty0 = null;
  thread.addEventListener("touchstart", (e) => (ty0 = thread.scrollTop <= 0 ? e.touches[0].clientY : null), { passive: true });
  thread.addEventListener("touchend", (e) => {
    if (ty0 !== null && e.changedTouches[0].clientY - ty0 > 70 && !thread.contains(document.activeElement)) setOpen(false);
    ty0 = null;
  });

  // ---------- transcripts from Recense (lyrics and speech, timed word by word) ----------
  //
  // Recense on the Mac transcribes Main's audio and video while it is idle; the Worker hands the
  // result over (transcript.js). Shown the way Recense's Learn mode shows it: the original is lit
  // word by word as it is heard, and about 0.3 s after a phrase of three or four words has been
  // heard, a soft edge sweeps across it and its translation (the native language, prefs.nativeLang)
  // surfaces in the same slot. Nothing slides or reflows. Lines take turns in two places, one over
  // the other, so the end of a thought stays put, translated, while the next line plays. Everything
  // runs on the time being heard (the deck's own clock on Safari), so it keeps in step at any
  // speed. Tap a line to go to it.

  const txUrl = (f) =>
    G.main
      ? "/main/api/transcript?" + new URLSearchParams({ path: f.path })
      : G.invite
      ? API + "/transcript?" + new URLSearchParams({ name: String(f.path || f.name).split("/").pop() })
      : /^\d{3}$/.test(f.n || "")
      ? "/api/transcript?" + new URLSearchParams({ id: G.id, n: f.n })
      : null;

  const txFetch = (f) => {
    if (!f.tx) {
      const u = txUrl(f);
      f.tx = u
        ? fetch(u, { headers: { "x-gallery": "1" }, cache: "no-store" })
            .then((r) => (r.ok ? r.json() : null))
            .catch(() => null)
        : Promise.resolve(null);
    }
    return f.tx;
  };

  // --- corrections (spec §9): anyone viewing on Main or a share link fixes a line in place ---
  //
  // Tap a line to go to it and correct it. Saved a second after the last change (PUT with the version
  // the page has); on a conflict the saved corrections are fetched, merged per line (the later
  // correction wins) and sent once more. No transcript yet: Recense is asked for one, under a lock
  // shared by everyone viewing, and the page waits for it.

  const txWrite = (f) => {
    const q = G.main ? { path: f.path } : !G.invite && /^\d{3}$/.test(f.n || "") ? { id: G.id, n: f.n } : null;
    if (!q) return null;
    const base = G.main ? "/main/api/transcript" : "/api/transcript";
    const qs = "?" + new URLSearchParams(q);
    return { put: base + qs, run: base + "/run" + qs, changes: base + "/changes" + qs };
  };

  const txSend = (url, method, body) =>
    fetch(url, { method, headers: { "content-type": "application/json", "x-gallery": "1" }, body: JSON.stringify(body) }).catch(() => null);

  const txQueues = new Map(); // file -> { edits: Map, timer, busy, onLines }

  const queueEdit = (f, edit) => {
    let q = txQueues.get(f);
    if (!q) txQueues.set(f, (q = { edits: new Map(), timer: 0, busy: false, onLines: null }));
    q.edits.set(edit.segId + "|" + edit.field, edit);
    clearTimeout(q.timer);
    q.timer = setTimeout(() => flushEdits(f), 1000);
    return q;
  };

  const flushEdits = async (f) => {
    const q = txQueues.get(f);
    const w = txWrite(f);
    if (!q || !w || !q.edits.size) return;
    if (q.busy) {
      q.timer = setTimeout(() => flushEdits(f), 500);
      return;
    }
    const edits = [...q.edits.values()];
    q.edits.clear();
    q.busy = true;
    let r = await txSend(w.put, "PUT", { version: f.txv || 0, edits });
    let kept = edits;
    if (r && r.status === 409) {
      // someone saved first: keep each of ours unless what they saved for that line is newer, and try once more
      const c = await r.json().catch(() => null);
      if (c) {
        f.txv = c.version;
        kept = edits.filter((e) => !(c.overrides || []).some((o) => o.segId === e.segId && o.field === e.field && o.updatedAt > e.updatedAt));
        r = kept.length ? await txSend(w.put, "PUT", { version: c.version, edits: kept }) : null;
      }
    }
    q.busy = false;
    const back = () => kept.forEach((e) => !q.edits.has(e.segId + "|" + e.field) && q.edits.set(e.segId + "|" + e.field, e));
    if (r && r.ok) {
      const j = await r.json();
      f.txv = j.version;
      if (!q.edits.size) {
        const t = { lines: j.lines, version: j.version };
        f.tx = Promise.resolve(t);
        if (q.onLines) q.onLines(j.lines);
      }
      say("");
    } else if (!r && !kept.length) {
      // all of ours were older than what is saved: show what is saved
      f.tx = null;
      const t = await txFetch(f);
      if (t && t.lines && q.onLines) q.onLines(t.lines);
    } else if (r && r.status === 429) {
      back();
      say("Too many corrections for now; saving again in a minute", true);
      q.timer = setTimeout(() => flushEdits(f), 60000);
    } else {
      back();
      say("Couldn’t save the correction", true);
    }
  };

  // words for a corrected line until the server's timing arrives: spread over the line's own time
  const spreadWords = (text, l) => {
    const ws = text.split(/\s+/).filter(Boolean);
    const span = Math.max(0.05 * ws.length, l.e - l.s);
    return ws.map((t, i) => ({ t, s: l.s + (span * i) / ws.length, e: l.s + (span * (i + 1)) / ws.length }));
  };

  // No transcript yet: ask Recense for one (unless someone already has) and wait for it, with Retry when it fails.
  const awaitTranscript = (f, el, host, t) => {
    const w = txWrite(f);
    if (!w || host.querySelector(".txst")) return;
    const st = mkEl("div", "tx txst");
    const msg = mkEl("span", "txmsg");
    const retry = mkEl("button", "lnk txbtn");
    retry.type = "button";
    retry.textContent = "Retry";
    retry.hidden = true;
    st.append(msg, retry);
    host.appendChild(st);
    let timer = 0;
    const alive = () => items[cur] === f && el.isConnected && st.isConnected;
    const showRun = (run) => {
      const failed = !run || run.state === "failed";
      msg.textContent = failed
        ? "Transcription failed"
        : run.state === "running"
        ? "Transcribing… " + Math.round((run.progress || 0) * 100) + "%"
        : "Waiting for the transcript…";
      retry.hidden = !failed;
    };
    const poll = () => {
      clearTimeout(timer);
      timer = setTimeout(async () => {
        if (!alive()) return;
        const u = txUrl(f);
        const j = await fetch(u, { headers: { "x-gallery": "1" }, cache: "no-store" }).then((r) => (r.ok ? r.json() : null)).catch(() => null);
        if (!alive()) return;
        // done once there are lines and no run under way (a retranscription keeps the old lines meanwhile)
        if (j && Array.isArray(j.lines) && j.lines.length && !(j.run && j.run.state !== "failed")) {
          st.remove();
          f.tx = Promise.resolve(j);
          if (j.run) say("Retranscribing failed; this is the transcript as it was", true);
          showTranscript(f);
          return;
        }
        showRun(j && j.run);
        if (j && j.run && j.run.state !== "failed") poll();
      }, 5000);
    };
    const start = async (body) => {
      msg.textContent = "Waiting for the transcript…";
      retry.hidden = true;
      const r = await txSend(w.run, "POST", body);
      const j = r && r.ok ? await r.json().catch(() => null) : null;
      if (!alive()) return;
      if (j && j.state === "done") return poll();
      showRun(j);
      if (j && j.state !== "failed") poll();
    };
    retry.onclick = (ev) => {
      ev.stopPropagation();
      start({ retry: true });
    };
    // opened for the first time: start it, unless it's under way or failed (then Retry is the viewer's call)
    if (!t.run) start({});
    else {
      showRun(t.run);
      if (t.run.state !== "failed") poll();
    }
  };

  // --- Learn mode, ported from Recense (main.swift: phrases, readBy, learningPlaces, ink) ---

  const TURN = 0.3; // how long a heard phrase takes to turn into its English

  const endsClause = (w) => /[,.;:?!…]$/.test(String(w).replace(/["'»”’)]+$/, ""));
  const leansOn = (w) => !endsClause(w) && (String(w).match(/\p{L}/gu) || []).length <= 3;
  const LEAN_EN = new Set(
    ("a an the of to in on at by for from with into about as and or but if than that which who whose this these those " +
      "my your his her its our their i you he she it we they is are was were be been am do does did have has had will " +
      "would shall should can could may might must not no").split(" ")
  );
  const leansOnEnglish = (w) => !endsClause(w) && LEAN_EN.has(String(w).toLowerCase().replace(/[^\p{L}']/gu, ""));
  const readingTime = (n) => 0.7 + 0.28 * n;

  // a line's words as beats: each lasts until the next one starts
  const sourceBeats = (l) =>
    l.words.map((w, i) => {
      const next = i + 1 < l.words.length ? l.words[i + 1].s : Infinity;
      // a short pause before the next word is bridged, so the light never drops out between words
      const e = next - w.e < 0.6 ? next : w.e;
      return { t: w.t, s: w.s, e: Math.max(w.s + 0.05, Math.min(e, next)) };
    });

  // the original words an English word translates; one claiming most of a long line is a misread alignment
  const sourcesOf = (w, m) => {
    const s = (w.s || []).filter((x) => x >= 0 && x < m);
    return m > 3 && s.length > Math.max(2, Math.floor(m / 2)) ? [] : s;
  };

  const translated = (l) => Array.isArray(l.enw) && l.enw.length > 0 && !(l.enw.length === 1 && l.enw[0].w === "…");

  // A line's phrases: a run of original words and the run of English that translates it. Cut where
  // the speech pauses or a clause ends, rarely on a short word that leans on the next, with the
  // English cut at the same share of the English, a little behind rather than ahead.
  const phrasesOf = (l) => {
    const words = l.words.map((w) => w.t);
    const en = l.enw;
    const m = words.length;
    const n = en.length;
    if (m <= 1 || n <= 1) return [{ src: [0, m], en: [0, n] }];

    const s = en.map((w) => sourcesOf(w, m));
    const aligned = s.every((x) => x.length) && !s.every((x, i) => x.length === 1 && x[0] === i);
    const shares = (w) => {
      const c = [0];
      for (const x of w) c.push(c[c.length - 1] + x.length + 1);
      return c.map((v) => v / c[c.length - 1]);
    };
    const po = shares(words);
    const pe = shares(en.map((w) => w.w));
    const cut = new Map();

    for (let i = 1; i < m; i++) {
      let best = null;
      for (let k = 1; k < n; k++) {
        if (aligned && (s.slice(0, k).some((x) => Math.max(...x) >= i) || s.slice(k).some((x) => Math.min(...x) < i))) continue;
        let c = Math.abs(pe[k] - (po[i] - 0.04)) * 4 + (leansOnEnglish(en[k - 1].w) ? 0.6 : 0);
        if (endsClause(words[i - 1]) && endsClause(en[k - 1].w)) c -= 0.5;
        if (!best || c < best.cost) best = { k, cost: c };
      }
      if (!best) continue;
      if (endsClause(words[i - 1])) best.cost -= 1.2;
      if (l.words[i].s - l.words[i - 1].e >= 0.25) best.cost -= 0.8;
      if (leansOn(words[i - 1])) best.cost += 0.8;
      if (!aligned) best.cost += 0.5; // a guessed cut can be a word out: fewer of them
      cut.set(i, best);
    }

    // the cheapest run of cuts, with phrases of three or four words where it can
    const size = [0, 2, 0.5, 0, 0.1, 0.7];
    const path = [{ at: 0, k: 0, cost: 0, from: -1 }];
    for (const j of [...[...cut.keys()].sort((x, y) => x - y), m]) {
      const k = j < m ? cut.get(j).k : n;
      const c = j < m ? cut.get(j).cost : 0;
      let best = null;
      path.forEach((p, i) => {
        if (p.k >= k) return;
        const len = j - p.at;
        const cost = p.cost + (len < size.length ? size[len] : 0.7 + (len - 5)) + c;
        if (!best || cost < best.cost) best = { from: i, cost };
      });
      if (best) path.push({ at: j, k, cost: best.cost, from: best.from });
    }

    const out = [];
    for (let i = path.length - 1; i > 0; ) {
      const p = path[i];
      const q = path[p.from];
      out.unshift({ src: [q.at, p.at], en: [q.k, p.k] });
      i = p.from;
    }
    return out;
  };

  // The trailing language: the native language set in the viewer (spec §1), English until then.
  const nativeLang = () => prefs.nativeLang || "en";

  // A line's translation in the native language (Recense's tr/<lang>.json, or a correction of it),
  // whole; else the English: phrase by phrase when it is aligned word by word, else the whole line in
  // one piece. Never another language. null: none (yet).
  const nativeOf = (l) => {
    const lang = nativeLang();
    const tr = l.tr || {};
    const ok = (x) => typeof x === "string" && x.trim() && x.trim() !== "…";
    if (lang !== "en" && ok(tr[lang])) return { text: tr[lang] };
    if (translated(l)) return { phrases: true };
    const any = [tr.en, l.en].find(ok);
    return any ? { text: any } : null;
  };

  // per line, worked out once (again when the native language changes): its beats, phrases and when it has been read
  const learnOf = (l) => {
    const lang = nativeLang();
    if (!l._learn || l._learn.lang !== lang) {
      const beats = sourceBeats(l);
      const nat = beats.length ? nativeOf(l) : null;
      const parts = !nat ? null : nat.phrases ? phrasesOf(l) : [{ src: [0, beats.length], en: null, text: nat.text }];
      const end = beats.length ? beats[beats.length - 1].e : l.e;
      const last = parts && parts[parts.length - 1];
      const read = last ? end + TURN + readingTime(last.en ? last.en[1] - last.en[0] : last.text.split(/\s+/).length) : l.e + 0.6;
      l._learn = { lang, beats, parts, read };
    }
    return l._learn;
  };

  // Learn's two places, one over the other, which the lines take in turn (karaoke's way). A line
  // takes the place of the line before last once that one has been read and the line between has
  // begun, and always a moment before it is spoken itself. A place changes lines with a short
  // fade, out then in. A silence clears both; paused, the screen never clears.
  const learningPlaces = (lines, t, held) => {
    const n = lines.length;
    const lead = 0.5;
    const fadeOut = 0.15;
    const fadeIn = 0.2;
    if (!n) return [];

    const opens = (k) => k === 0 || lines[k].s - lines[k - 1].e >= 12;
    const place = (j) => {
      let k = j;
      while (!opens(k)) k--;
      return (j - k) % 2;
    };
    const readAt = (j) => learnOf(lines[j]).read;
    const clears = (j) => Math.max(lines[j].e + 2.5, readAt(j));
    const from = (j) => {
      if (opens(j)) return lines[j].s - 4;
      const freed = opens(j - 1) ? -Infinity : readAt(j - 2);
      const spoken = opens(j - 1) ? -Infinity : Math.min(lines[j - 2].e, lines[j].s - fadeOut - fadeIn);
      return Math.max(Math.min(Math.max(lines[j - 1].s, freed), lines[j].s - lead), spoken);
    };
    const until = (j) => {
      if (j + 1 === n || opens(j + 1)) return clears(j);
      if (j + 2 === n || opens(j + 2)) return clears(j + 1);
      return from(j + 2);
    };

    let now = 0;
    for (let lo = 0, hi = n - 1; lo <= hi; ) {
      const m = (lo + hi) >> 1;
      if (lines[m].s <= t) {
        now = m;
        lo = m + 1;
      } else hi = m - 1;
    }

    const shown = [];
    for (let j = Math.max(0, now - 2); j <= Math.min(n - 1, now + 2); j++) {
      const a = Math.min((t - from(j) - fadeOut) / fadeIn, (until(j) + fadeOut - t) / fadeOut);
      if (a > 0) shown.push({ line: j, place: place(j), alpha: Math.min(1, a) });
    }
    // paused: keep the line just heard up, but not one from far off (an instrumental's stray "you.")
    if (!shown.length && held && t >= lines[now].s && t <= clears(now) + 3) return [{ line: now, place: place(now), alpha: 1 }];
    return shown;
  };

  // A word against media time, so the motion scales with playback speed on its own: it brightens
  // just before it is spoken, a light wipes across it over exactly the time it is spoken, its onset
  // flashes gold and settles, then it eases into white.
  const SPOKEN = [255, 255, 255, 1];
  const GOLD = [255, 214, 51, 1];
  const UPCOMING = [255, 255, 255, 0.42];
  const AHEAD = [255, 255, 255, 0.6];
  const mix = (a, b, f) => {
    f = Math.max(0, Math.min(1, f));
    return a.map((v, i) => v + (b[i] - v) * f);
  };
  const rgba = (c) => "rgba(" + Math.round(c[0]) + "," + Math.round(c[1]) + "," + Math.round(c[2]) + "," + c[3].toFixed(3) + ")";

  // Styles are only written when they change: a page that rewrites them every frame keeps style-watching
  // extensions (Dark Reader, translators) recomputing the whole page, which froze Firefox.
  const paintWord = (sp, b, t) => {
    const st = sp.style;
    if (t >= b.e || t < b.s) {
      const c = t >= b.e ? mix(GOLD, SPOKEN, (t - b.e) / 0.45) : mix(UPCOMING, AHEAD, 1 - (b.s - t) / 0.2);
      const col = rgba(c);
      if (sp._c !== col) st.color = sp._c = col;
      if (sp._bg) {
        st.backgroundImage = st.textShadow = sp._bg = sp._sh = "";
      }
      return;
    }
    // the light stays full gold for the whole word and wipes across all of it, with a soft edge
    const dur = Math.max(0.05, b.e - b.s);
    const f = Math.min(1, (t - b.s) / dur);
    const w = (f * 100).toFixed(1);
    const edge = Math.min(100, f * 100 + 6).toFixed(1);
    const lit = rgba(GOLD);
    if (sp._c !== "transparent") st.color = sp._c = "transparent";
    const bg = "linear-gradient(" + (sp.dir === "rtl" ? "to left," : "to right,") + lit + " " + w + "%," + rgba(AHEAD) + " " + edge + "%)";
    if (sp._bg !== bg) st.backgroundImage = sp._bg = bg;
    const sh = "0 0 8px rgba(255,214,51,.45)";
    if (sp._sh !== sh) st.textShadow = sp._sh = sh;
  };

  const RTL_RE = /[֐-ࣿיִ-﷿ﹰ-﻿]/;

  // [Ambient Sounds], as Recense shows it: while the media plays and no line is up
  const ambient = (host, el, gap, always) => {
    if (host.querySelector(".txamb")) return;
    const a = mkEl("div", "txamb");
    a.textContent = "[Ambient Sounds]";
    a.hidden = true;
    host.appendChild(a);
    const tick = () => {
      if (!a.isConnected) return;
      const on = (always || (!el.paused && !el.ended)) && gap();
      if (a.hidden === on) a.hidden = !on;
      setTimeout(tick, 250);
    };
    tick();
  };

  const TX_LH = 1.45; // the subtitles' line height (.txp): stacked Vietnamese marks never touch the line above

  const showTranscript = async (f) => {
    const el = stageMedia();
    const host = el && (el.getRootNode().host || el).closest(".vw, .aw");
    if (!el || !host) return;

    const t = await txFetch(f);
    if (items[cur] !== f || !el.isConnected) return;
    if (!t || !Array.isArray(t.lines) || !t.lines.length) {
      if (t && t.pending) {
        f.tx = null; // ask again next time: Recense may have finished meanwhile
        awaitTranscript(f, el, host, t);
      } else if (t) ambient(host, el, () => true, true); // an instrumental: [Ambient Sounds], playing or paused
      return;
    }
    if (host.querySelector(".tx.learn")) return;

    let lines = t.lines;
    if (f.txv === undefined || (t.version || 0) > f.txv) f.txv = t.version || 0;
    const w = txWrite(f);
    let editing = null; // the whole transcript is open
    const player = activePlayer;
    // the time being heard: the deck's clock on Safari, less what is still on its way to the speakers
    // media time is coarse on Firefox and jittery through the deck: interpolate with the frame clock,
    // and never step backwards a little (a seek, a real jump, resets it)
    let ck = { m: -1, at: 0, out: 0 };
    const clock = () => {
      const m = player && player.heard ? player.heard() : el.currentTime;
      const now = performance.now();
      if (el.paused) return (ck = { m, at: now, out: m }).out;
      if (m !== ck.m) ck = { m, at: now, out: ck.out };
      let v = ck.m + ((now - ck.at) / 1000) * (el.playbackRate || 1);
      if (v < ck.out && ck.out - v < 0.3) v = ck.out;
      ck.out = v;
      return v;
    };

    const box = mkEl("div", "tx learn");
    const places = [0, 1].map(() => {
      const p = mkEl("button", "txp");
      p.type = "button";
      p.hidden = true;
      box.appendChild(p);
      return { el: p, line: -1, cells: [] };
    });
    host.appendChild(box);
    txsPill.hidden = false;
    // spec §2: audio with a transcript shows its lyrics on black (mode 2) instead of the cover (mode 1)
    if (host.classList.contains("aw")) host.classList.add("lyrics");

    const fits = new Map(); // line → font scale that keeps it to two rows, at this width

    // a line in its place: each phrase a cell holding its words and, stacked in the same slot, its English
    const build = (pl, j) => {
      const l = lines[j];
      const L = learnOf(l);
      pl.line = j;
      pl.lang = nativeLang();
      pl.cells = [];
      pl.el.replaceChildren();
      pl.el.onclick = (ev) => {
        ev.stopPropagation();
        el.currentTime = Math.max(0, l.s - 0.05);
        openAll();
      };

      const rtl = RTL_RE.test(l.text || "");
      pl.el.dir = rtl ? "rtl" : "ltr";
      const parts = L.parts || L.beats.map((_, i) => ({ src: [i, i + 1], en: null }));

      for (const p of parts) {
        const cell = mkEl("span", "txc");
        const src = mkEl("span", "txs");
        const words = [];
        for (let i = p.src[0]; i < p.src[1]; i++) {
          const sp = mkEl("span", "txw");
          sp.textContent = L.beats[i].t;
          sp.dir = rtl ? "rtl" : "ltr";
          src.appendChild(sp);
          if (i + 1 < p.src[1]) src.appendChild(document.createTextNode(" "));
          words.push({ sp, b: L.beats[i] });
        }
        cell.appendChild(src);
        let en = null;
        const native = p.text != null ? p.text : p.en ? l.enw.slice(p.en[0], p.en[1]).map((w) => w.w).join(" ") : null;
        if (native != null) {
          en = mkEl("span", "txe");
          en.dir = RTL_RE.test(native) ? "rtl" : "ltr";
          en.textContent = native;
          cell.appendChild(en);
        }
        pl.el.appendChild(cell);
        pl.cells.push({ cell, src, en, words, end: L.beats[p.src[1] - 1].e, w: 0, p: -1 });
      }

      // one size for every line and both languages: clamp(22px, 3vw, 30px) times the reader's Text Size;
      // only a line too long for two rows is made smaller
      const width = box.clientWidth;
      const base = Math.max(22, Math.min(30, innerWidth * 0.03)) * prefs.txScale;
      pl.sc = prefs.txScale;
      const key = j + "/" + width + "/" + pl.sc;
      let scale = fits.get(key) || 1;
      pl.el.style.fontSize = base * scale + "px";
      if (!fits.has(key)) {
        while (scale > 0.4 && (pl.el.scrollHeight > 2 * base * scale * TX_LH + 14 || pl.el.scrollWidth > pl.el.clientWidth + 1)) {
          scale *= 0.92;
          pl.el.style.fontSize = base * scale + "px";
        }
        fits.set(key, scale);
      }
      pl.cells.forEach((c) => (c.w = c.cell.offsetWidth));
    };

    // the soft edge that turns a phrase into its English, the way it is read
    const turn = (c, raw, rtl, h) => {
      const p = raw * raw * (3 - 2 * raw);
      if (Math.abs(p - c.p) < 0.002) return;
      c.p = p;
      const w = c.w || c.cell.offsetWidth;
      const fe = Math.min(w, 1.5 * h);
      const e = -fe + (w + 2 * fe) * p;
      const dir = rtl ? "to left" : "to right";
      const so = p <= 0 ? "none" : "linear-gradient(" + dir + ",transparent " + e + "px,#000 " + (e + fe) + "px)";
      const eo = "linear-gradient(" + dir + ",#000 " + (e - fe) + "px,transparent " + e + "px)";
      c.src.style.webkitMaskImage = c.src.style.maskImage = so;
      c.src.style.visibility = p >= 1 ? "hidden" : "visible";
      c.en.style.webkitMaskImage = c.en.style.maskImage = p >= 1 ? "none" : eo;
      c.en.style.visibility = p <= 0 ? "hidden" : "visible";
    };

    // Tap a line: the whole transcript opens over the media, scrolled to that line. Only the line being
    // heard is a field (Return or leaving it saves, Escape puts it back); any other line takes you to its
    // time and plays from there, and is then the one you can correct. Changes lists every correction made
    // to this transcript, by anyone, with what it replaced; Restore puts that back (itself a correction).
    const mmss = (x) => {
      x = Math.max(0, Math.floor(x));
      return Math.floor(x / 60) + ":" + String(x % 60).padStart(2, "0");
    };
    const lineAt = (t) => {
      let k = -1;
      lines.forEach((l, i) => l.s <= t + 0.05 && (k = i));
      return k;
    };
    const openAll = () => {
      if (editing) return;
      editing = true;
      box.hidden = true;
      const sheet = mkEl("div", "txall");
      const bar = mkEl("div", "txbar txallbar");
      const list = mkEl("div", "txlist");
      const btn = (label, fn) => {
        const b = mkEl("button", "lnk txbtn");
        b.type = "button";
        b.textContent = label;
        b.onpointerdown = (e) => e.preventDefault(); // keep the field's focus, so its blur doesn't save first
        b.onclick = (e) => {
          e.stopPropagation();
          fn();
        };
        bar.appendChild(b);
        return b;
      };
      let cur = -1;
      let field = null;
      let rows = [];
      const save = (l, ta) => {
        const text = ta.value.replace(/\s+/g, " ").trim();
        if (text === l.text) return;
        l.text = text;
        l.words = spreadWords(text, l);
        l.fixed = true;
        delete l._learn;
        fits.clear();
        queueEdit(f, { segId: l.id, field: "text", to: text, updatedAt: Date.now() }).onLines = onLines;
        if (!text) say("Line removed — Changes has it if you want it back");
      };
      const row = (l, i) => {
        const r = mkEl("div", "txrow" + (i === cur ? " cur" : ""));
        const time = mkEl("span", "txt");
        time.textContent = mmss(l.s);
        r.appendChild(time);
        if (i === cur && w) {
          const ta = mkEl("textarea", "txin");
          ta.value = l.text;
          ta.rows = 2;
          ta.maxLength = 2000;
          ta.setAttribute("aria-label", "Correct this line");
          ta.onfocus = () => el.pause();
          ta.onkeydown = (e) => {
            if (e.key === "Enter" && !e.shiftKey) {
              e.preventDefault();
              ta.blur();
            } else if (e.key === "Escape") {
              e.preventDefault();
              e.stopPropagation();
              ta.value = l.text;
              ta.blur();
            }
          };
          ta.onblur = () => save(l, ta);
          ta.onclick = (e) => e.stopPropagation();
          field = ta;
          r.appendChild(ta);
        } else {
          const b = mkEl("button", "txline");
          b.type = "button";
          b.textContent = l.text;
          b.dir = RTL_RE.test(l.text || "") ? "rtl" : "ltr";
          b.onclick = (e) => {
            e.stopPropagation();
            el.currentTime = Math.max(0, l.s - 0.05);
            el.play().catch(() => {});
            follow(i);
          };
          r.appendChild(b);
        }
        return r;
      };
      const render = () => {
        if (field && document.activeElement === field) field.blur();
        field = null;
        rows = lines.map(row);
        list.replaceChildren(...rows);
      };
      const follow = (i, scroll = true) => {
        if (i === cur) return;
        if (field && document.activeElement === field) field.blur(); // saves it
        const old = cur;
        cur = i;
        field = null;
        [old, cur].forEach((k) => {
          if (k < 0 || !rows[k]) return;
          const r = row(lines[k], k);
          rows[k].replaceWith(r);
          rows[k] = r;
        });
        if (scroll && rows[cur]) rows[cur].scrollIntoView({ block: "center", behavior: "smooth" });
      };
      const showChanges = async () => {
        const u = txWrite(f);
        list.replaceChildren(mkEl("div", "txmsg"));
        list.firstChild.textContent = "Loading changes…";
        changesBtn.hidden = true;
        backBtn.hidden = false;
        await flushEdits(f);
        const r = await fetch(u.changes, { headers: { "x-gallery": "1" }, cache: "no-store" }).catch(() => null);
        const j = r && r.ok ? await r.json().catch(() => null) : null;
        if (!sheet.isConnected || backBtn.hidden) return;
        const cs = ((j && j.changes) || []).filter((c) => c.field === "text");
        if (!cs.length) {
          list.firstChild.textContent = j ? "No corrections yet" : "Couldn’t load the changes";
          return;
        }
        const byId = new Map(lines.map((l) => [String(l.id), l]));
        list.replaceChildren(
          ...cs.map((c) => {
            const r = mkEl("div", "txrow txchg");
            const meta = mkEl("span", "txt");
            const l = byId.get(String(c.segId));
            meta.textContent = (l ? mmss(l.s) + " · " : "") + new Date(c.at).toLocaleString([], { dateStyle: "short", timeStyle: "short" });
            const was = mkEl("del", "txwas");
            was.textContent = c.from || "(empty)";
            const now = mkEl("ins", "txnow");
            now.textContent = c.to || "(line removed)";
            const body = mkEl("div", "txdiff");
            body.append(was, now);
            r.append(meta, body);
            const live = l ? l.text : "";
            if (live !== c.from) {
              const b = mkEl("button", "lnk txbtn");
              b.type = "button";
              b.textContent = "Restore";
              b.onclick = async (e) => {
                e.stopPropagation();
                b.disabled = true;
                queueEdit(f, { segId: c.segId, field: "text", to: c.from, updatedAt: Date.now() }).onLines = onLines;
                await flushEdits(f);
                b.textContent = "Restored";
              };
              r.appendChild(b);
            }
            return r;
          })
        );
      };
      const backToLines = () => {
        backBtn.hidden = true;
        changesBtn.hidden = !w;
        cur = lineAt(clock());
        render();
        if (rows[cur]) rows[cur].scrollIntoView({ block: "center" });
      };
      const changesBtn = btn("Changes", showChanges);
      const backBtn = btn("Transcript", backToLines);
      backBtn.hidden = true;
      changesBtn.hidden = !w;
      if (G.main && w)
        btn("Retranscribe", async () => {
          close();
          const r = await txSend(w.run, "POST", { retranscribe: true });
          if (r && r.ok) {
            say("Retranscribing; your corrections stay");
            f.tx = null;
            box.remove();
            awaitTranscript(f, el, host, { run: await r.json().catch(() => ({ state: "queued" })) });
          } else say("Couldn’t ask for a new transcript", true);
        });
      const close = () => {
        if (!sheet.isConnected) return;
        if (field && document.activeElement === field) field.blur();
        sheet.remove();
        box.hidden = false;
        places.forEach((pl) => (pl.line = -1));
        editing = null;
        reRender = null;
        document.removeEventListener("keydown", onKey, true);
      };
      const onKey = (e) => {
        if (e.key === "Escape" && document.activeElement !== field) {
          e.preventDefault();
          e.stopPropagation();
          close();
        }
      };
      document.addEventListener("keydown", onKey, true);
      btn("Done", close);
      sheet.onclick = (e) => e.stopPropagation();
      sheet.append(bar, list);
      host.appendChild(sheet);
      cur = lineAt(clock());
      render();
      if (rows[cur]) rows[cur].scrollIntoView({ block: "center" });
      // the field follows what is heard, unless you are typing in it
      const tick = () => {
        if (!sheet.isConnected) return;
        if (backBtn.hidden && !(field && document.activeElement === field)) {
          const i = lineAt(clock());
          if (i !== cur) follow(i, !el.paused);
        }
        setTimeout(tick, 200);
      };
      tick();
      reRender = () => backBtn.hidden && render();
    };
    let reRender = null;

    // the server's corrected lines (its timing, glossary applied to other lines) replace the page's
    const onLines = (fresh) => {
      if (!box.isConnected || !Array.isArray(fresh)) return;
      lines = fresh;
      places.forEach((pl) => (pl.line = -1));
      fits.clear();
      if (reRender) reRender();
    };
    const q = txQueues.get(f);
    if (q) q.onLines = onLines;

    let gapNow = false;
    ambient(host, el, () => gapNow);
    const paint = () => {
      if (!box.isConnected) return;
      if (editing) return requestAnimationFrame(paint);

      const now = clock();
      const shown = learningPlaces(lines, now, el.paused);
      gapNow = !shown.length;
      const want = [null, null];
      for (const s of shown) if (!want[s.place] || s.alpha > want[s.place].alpha) want[s.place] = s;

      places.forEach((pl, k) => {
        const s = want[k];
        if (!s) {
          pl.el.hidden = true;
          return;
        }
        pl.el.hidden = false;
        if (pl.line !== s.line || pl.lang !== nativeLang() || pl.sc !== prefs.txScale) build(pl, s.line);
        pl.el.style.opacity = s.alpha.toFixed(3);

        const rtl = pl.el.dir === "rtl";
        const h = parseFloat(pl.el.style.fontSize) * TX_LH;
        for (const c of pl.cells) {
          const raw = c.en ? Math.max(0, Math.min(1, (now - c.end) / TURN)) : 0;
          if (raw < 1) c.words.forEach((w) => paintWord(w.sp, w.b, now));
          if (c.en) turn(c, raw, rtl, h);
        }
      });

      requestAnimationFrame(paint);
    };

    requestAnimationFrame(paint);
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
    owner = true;
    paintCap();
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

    if (G.invite && clash.length) {
      say((clash.length === 1 ? "“" + clash[0].name + "” is" : clash.length + " files are") + " already here. Rename and try again.", true);
      return;
    }

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

        const mtime = String(file.lastModified || Date.now());
        // an invited person adds new files only, into their one folder (the server picks the folder)
        const to = G.invite
          ? API + "/file?" + new URLSearchParams({ name: file.name, mtime })
          : "/main/api/file?" + new URLSearchParams({ key: keyOf(file), mtime });
        const r = await fetch(to, {
          method: "PUT",
          headers: { "content-type": file.type || "application/octet-stream", "x-gallery": "1" },
          body: file,
        });

        if (!r.ok) throw new Error((await r.text()) || "Upload failed");
        done++;

        // the owner's audio: find its original key now, for the Key slider's labels (best effort)
        if (!G.invite && kind({ type: file.type || "", name: file.name }) === "aud" && file.size <= DETECT_BYTES) {
          say("Finding the key of " + file.name + "…");
          await detectKey(file)
            .then((k) => k && saveKey(keyOf(file), k, "auto"))
            .catch(() => {});
        }
      }

      location.reload();
    } catch (e) {
      say("Upload stopped after " + done + " of " + files.length + ": " + (e.message || e), true);
      up.disabled = false;
    }
  };

  // ----- the original key (Key slider labels) -----
  //
  // Found from the sound: the middle two minutes, mixed to mono at 22.05 kHz, folded into a chroma
  // vector and matched against the 24 Krumhansl-Kessler key profiles (keylabel.js). Done for the
  // owner's audio uploads, and on demand from Info. What the owner types in Info wins over it.
  const DETECT_BYTES = 80 * 1024 * 1024;
  const DETECT_SECONDS = 120;
  const DETECT_SR = 22050;

  const detectKey = async (from) => {
    const Off = window.OfflineAudioContext || window.webkitOfflineAudioContext;
    if (!Off) return "";

    const data = from instanceof Blob ? await from.arrayBuffer() : await (await fetch(from)).arrayBuffer();
    const ctx = new Off(1, 1, DETECT_SR);
    const audio = await new Promise((ok, no) => {
      const p = ctx.decodeAudioData(data, ok, no);
      if (p && p.then) p.then(ok, no);
    });

    const sr = audio.sampleRate;
    const n = Math.min(audio.length, DETECT_SECONDS * sr);
    const start = Math.floor((audio.length - n) / 2);
    const mono = new Float32Array(n);

    for (let c = 0; c < audio.numberOfChannels; c++) {
      const d = audio.getChannelData(c);
      for (let i = 0; i < n; i++) mono[i] += d[start + i];
    }

    return GalleryKey.keyOfChroma(GalleryKey.chromaOf(mono, sr));
  };

  const saveKey = async (path, key, src) => {
    const r = await fetch("/main/api/key", {
      method: "PUT",
      headers: { "content-type": "application/json", "x-gallery": "1" },
      body: JSON.stringify({ path, key, src }),
    });
    if (!r.ok) throw new Error((await r.text()) || "Couldn’t save the key");
    return r.json();
  };

  // an item's key changed: its labels, and Info, show it at once
  const keySaved = (f, j) => {
    f.key = j.key || "";
    f.keySrc = j.keySrc || "";
    if (items[cur] === f) {
      if (activePlayer && activePlayer.repaintKey) activePlayer.repaintKey();
      // refresh Info only if it is open: a key found in the background never pops it up
      if (!meta.hidden) {
        meta.hidden = true;
        $("info").onclick();
      }
    }
  };

  const keyName = (k) => GalleryKey.label(0, 0, k, "en").lines[0];

  // a key in words, for the prompt: "D minor", and in the language in use too ("D minor / Ré mineur")
  const KEY_WORDS = {
    en: [{ C: "C", D: "D", E: "E", F: "F", G: "G", A: "A", B: "B" }, "major", "minor"],
    fr: [{ C: "Do", D: "Ré", E: "Mi", F: "Fa", G: "Sol", A: "La", B: "Si" }, "majeur", "mineur"],
    vi: [{ C: "Đô", D: "Rê", E: "Mi", F: "Fa", G: "Sol", A: "La", B: "Si" }, "trưởng", "thứ"],
  };
  const keyWords = (key, lang) => {
    const k = GalleryKey.parse(key);
    if (!k) return "";
    const w = KEY_WORDS[lang] || KEY_WORDS.en;
    return w[0][k.letter] + (k.acc === "♮" ? "" : k.acc) + " " + (k.minor ? w[2] : w[1]);
  };
  const keySpoken = (key) => {
    const en = keyWords(key, "en");
    const own = prefs.nativeLang !== "en" ? keyWords(key, prefs.nativeLang) : "";
    return own && own !== en ? en + " / " + own : en;
  };

  const setKeyOf = async (f) => {
    // the original key, found now if the background detection hasn't finished yet
    if (!f.autoKey && !(f.key && f.keySrc !== "manual")) {
      tell("Finding the original key…");
      await autoKey(f, true);
    }
    const orig = f.keySrc === "manual" ? f.autoKey || "" : f.key || f.autoKey || "";
    const typed = prompt(
      "Enter a starting key. " + (orig ? "Leave blank to keep " + keySpoken(orig) + "." : "Leave blank to keep the original key."),
      f.keySrc === "manual" && f.key ? keyName(f.key) : ""
    );
    if (typed === null) return;
    if (!typed.trim()) return clearKeyOf(f);

    const k = GalleryKey.canon(GalleryKey.parseAny(typed));
    if (!k) return tell("That isn’t a key (try E♭m, Rém, fis, ニ短, 6=D)", true);

    try {
      keySaved(f, await saveKey(f.path, k, "manual"));
      tell("Starting key: " + keyName(f.key));
    } catch (e) {
      tell(e.message || "Couldn’t save the key", true);
    }
  };

  // back to the original key: found from the sound again and applied
  const clearKeyOf = async (f) => {
    if (f.size > DETECT_BYTES) return tell("Too big to find the key of here; set it by hand", true);
    tell("Finding the original key…");
    try {
      const k = f.autoKey || (await detectKey(src(f)));
      if (!k) return tell("Couldn’t find a key in this sound", true);
      keySaved(f, await saveKey(f.path, k, "auto"));
      tell("Original key: " + keyName(k));
    } catch (e) {
      tell(e.message || "Couldn’t find the key", true);
    }
  };

  // Key names need the original key: an audio file without one has it found quietly as soon as it is
  // opened (a link onto one item: as the page loads), before Info or Transpose is ever touched, so the
  // Key slider names keys (E♭m, Rê t, Ré♭maj …) instead of counting semitones (+1, +2 …). Main keeps
  // what it finds; a share link keeps it for the visit. force: also when a key was typed by hand
  // (the prompt names the original).
  const autoTried = new Map(); // item → its detection
  const autoKey = (f, force) => {
    if ((f.key && !force) || f.size > DETECT_BYTES || f.pending) return Promise.resolve();
    const id = f.path || f.n || f.name;
    if (!autoTried.has(id)) {
      autoTried.set(
        id,
        detectKey(src(f))
          .then(async (k) => {
            if (!k) return;
            f.autoKey = k;
            if (f.key) return; // a key typed by hand stays
            if (G.main && f.path) keySaved(f, await saveKey(f.path, k, "auto"));
            else keySaved(f, { key: k, keySrc: "auto" });
          })
          .catch(() => {})
      );
    }
    return autoTried.get(id);
  };

  $("back").onclick = () => history.back();


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
    if (set.mix) bits.push((set.mix < 0 ? "Reversed " : "") + ROOMS[set.room].label + " " + Math.round(Math.abs(set.mix) * 100) + "%");

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

    // the same headroom as the player: the EQ's highest peak is taken back off, so a boost never clips
    let peak = 0;
    for (let i = 0; eqs.length && i < 96; i++) {
      const w = (2 * Math.PI * 20 * Math.pow(1000, i / 95)) / sr;
      if (w >= Math.PI) break;
      let db = 0;
      eqs.forEach(({ k: [b0, b1, b2, a1, a2] }) => {
        const nr = b0 + b1 * Math.cos(w) + b2 * Math.cos(2 * w);
        const ni = -(b1 * Math.sin(w) + b2 * Math.sin(2 * w));
        const dr = 1 + a1 * Math.cos(w) + a2 * Math.cos(2 * w);
        const di = -(a1 * Math.sin(w) + a2 * Math.sin(2 * w));
        db += 10 * Math.log10((nr * nr + ni * ni) / (dr * dr + di * di));
      });
      peak = Math.max(peak, db);
    }
    const trimG = Math.pow(10, -peak / 20);

    const eq = (x, c) => {
      if (eqs.length && trimG < 1) for (let i = 0; i < x.length; i++) x[i] *= trimG;
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
    const ir = set.mix ? (set.mix < 0 ? reverseIR(irData(set.room, sr)) : irData(set.room, sr)) : null;

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
      dry.gain.value = spaceGain(Math.abs(set.mix)).dry;
      wet.gain.value = spaceGain(Math.abs(set.mix)).wet;
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
    const btn = meta.querySelector(".mdl") || mkEl("button"); // Info's Download (spec §5)

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

  // Download lives in the Info panel (spec §5): with your sound baked in when it is changed
  const download = () => {
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
    s.textContent = f.pending ? "Uploading…" : sz(f.size);
    b.className = "mname";
    s.className = "msize";

    meta.append(b, s);

    // the owner, on Main: tap the name to rename it
    if (G.main && !f.pending) {
      b.classList.add("mrn");
      b.title = "Rename";
      b.setAttribute("role", "button");
      b.tabIndex = 0;
      b.onclick = () => renameItem(f);
      b.onkeydown = (e) => e.key === "Enter" && renameItem(f);
    }

    // everyone: Download (spec §5)
    if (!f.pending) {
      const ops = mkEl("span", "mops");
      const dl = mkBtn("lnk mdl", "Download", "Download");
      dl.onclick = download;
      ops.appendChild(dl);
      meta.appendChild(ops);
    }

    // the native language (spec §1): the trailing language of Learn mode and the Key label's second line
    if (kind(f) === "aud" || kind(f) === "vid") meta.append(langPicker(), textSizeRow());

    // the owner, on Main: new cover art (written to R2, so the Gallery mount on the Mac shows it too)
    if (G.main && !f.pending && kind(f) === "aud") {
      const ops = mkEl("span", "mops");
      const cv = mkBtn("lnk", "Change cover art", "Change Cover");
      ops.appendChild(cv);
      cv.onclick = () => pickCover(f);

      const dc = mkBtn("lnk", "Delete cover art", "Delete Cover");
      ops.appendChild(dc);
      dc.onclick = () => deleteCover(f);
      meta.appendChild(ops);
    }

    // the owner, on Main: the starting key the Key slider's labels count from, last, on a row of its own
    if (G.main && !f.pending && (kind(f) === "aud" || kind(f) === "vid")) {
      const kops = mkEl("span", "mops mkey");
      const tp = mkBtn("lnk", "Set the starting key", "Transpose");
      tp.onclick = () => setKeyOf(f);
      kops.appendChild(tp);
      meta.appendChild(kops);
    }

    meta.hidden = !meta.hidden;
  };

  // The native language picker, the same segmented control as Create Share Link's 1/7/30 days.
  // A tap applies at once: the Key label's second line (State 0) and Learn mode's trailing line
  // redraw; the Key state itself is left alone.
  const langPicker = () => {
    const wrap = mkEl("div", "mlang");
    const cap = mkEl("span", "mlcap");
    const seg = mkEl("div", "seg");
    cap.textContent = "Language";
    seg.setAttribute("role", "radiogroup");
    seg.setAttribute("aria-label", "Language");
    for (const [v, name] of NATIVE_LANGS) {
      const l = mkEl("label");
      const i = mkEl("input");
      const t = mkEl("span");
      i.type = "radio";
      i.name = "nlang";
      i.value = v;
      i.checked = prefs.nativeLang === v;
      t.textContent = name;
      i.onchange = () => setNativeLang(v);
      l.append(i, t);
      seg.appendChild(l);
    }
    wrap.append(cap, seg);
    return wrap;
  };

  // Text Size: smaller | larger, in steps of a tenth; the ends dim. The same control three ways
  // (top-right pill, this Info row, a pinch over the lyrics), all one value.
  const textSizeButtons = (cls, small, big) => {
    const seg = mkEl("div", cls);
    seg.setAttribute("role", "group");
    seg.setAttribute("aria-label", "Text size");
    const dn = mkBtn("txs-dn", "Smaller text", small);
    const up = mkBtn("txs-up", "Larger text", big);
    const pct = mkEl("span", "txs-pct");
    pct.setAttribute("aria-live", "polite");
    const pulse = (b) => {
      b.classList.remove("pulse");
      void b.offsetWidth;
      b.classList.add("pulse");
    };
    dn.onclick = (e) => {
      e.stopPropagation();
      setTextScale(prefs.txScale - TXS_STEP);
      pulse(dn);
    };
    up.onclick = (e) => {
      e.stopPropagation();
      setTextScale(prefs.txScale + TXS_STEP);
      pulse(up);
    };
    let pctT = 0;
    const paint = (live) => {
      dn.disabled = prefs.txScale <= TXS_MIN + 1e-6;
      up.disabled = prefs.txScale >= TXS_MAX - 1e-6;
      pct.textContent = Math.round(prefs.txScale * 100) + "%";
      // the size shows while it changes, then folds away
      seg.classList.add("live");
      clearTimeout(pctT);
      if (!live) pctT = setTimeout(() => seg.classList.remove("live"), 1100);
    };
    seg.append(dn, pct, up);
    dn.disabled = prefs.txScale <= TXS_MIN + 1e-6;
    up.disabled = prefs.txScale >= TXS_MAX - 1e-6;
    pct.textContent = Math.round(prefs.txScale * 100) + "%";
    return { seg, paint };
  };

  const textSizeRow = () => {
    const wrap = mkEl("div", "mlang mtsz");
    const cap = mkEl("span", "mlcap");
    cap.textContent = "Text Size";
    const t = textSizeButtons("tsz", "a<sup>−</sup>", "A<sup>+</sup>");
    txsViews.add(t.paint);
    // dropped once Info closes or is rebuilt
    const gone = () => {
      if (!wrap.isConnected) txsViews.delete(t.paint);
      else setTimeout(gone, 2000);
    };
    setTimeout(gone, 2000);
    wrap.append(cap, t.seg);
    return wrap;
  };

  // the top-right pill, opposite Back: shown while subtitles are on screen
  const txsPill = (() => {
    const t = textSizeButtons("tsz tpill", '<span class="sm">a</span>', '<span class="lg">A</span>');
    t.seg.hidden = true;
    txsViews.add(t.paint);
    $("topr").prepend(t.seg);
    return t.seg;
  })();

  // A pinch over the player scales the subtitles in place, not the page: two fingers on a touch
  // screen, or a trackpad pinch (ctrl + wheel). The pill shows the size while it moves.
  {
    const lb = $("lb");
    const onLyrics = () => !txsPill.hidden && !$("lb").hidden;
    let pinch = null;
    const dist = (t) => Math.hypot(t[0].clientX - t[1].clientX, t[0].clientY - t[1].clientY);
    lb.addEventListener(
      "touchstart",
      (e) => {
        if (e.touches.length !== 2 || !onLyrics() || !e.target.closest("#stage")) return;
        pinch = { d0: dist(e.touches), s0: prefs.txScale };
      },
      { passive: true }
    );
    lb.addEventListener(
      "touchmove",
      (e) => {
        if (!pinch || e.touches.length !== 2) return;
        e.preventDefault(); // not the browser's zoom
        setTextScale(pinch.s0 * (dist(e.touches) / pinch.d0), true);
      },
      { passive: false }
    );
    const pinchEnd = (e) => {
      if (!pinch || e.touches.length >= 2) return;
      pinch = null;
      setTextScale(prefs.txScale);
    };
    lb.addEventListener("touchend", pinchEnd);
    lb.addEventListener("touchcancel", pinchEnd);
    // Safari's own pinch gesture events: kept from zooming the page while the lyrics are up
    ["gesturestart", "gesturechange"].forEach((n) =>
      lb.addEventListener(n, (e) => {
        if (onLyrics()) e.preventDefault();
      })
    );
    let wheelT = 0;
    lb.addEventListener(
      "wheel",
      (e) => {
        if (!e.ctrlKey || !onLyrics() || !e.target.closest("#stage")) return;
        e.preventDefault();
        e.stopPropagation();
        setTextScale(prefs.txScale * Math.exp(-e.deltaY * 0.01), true);
        clearTimeout(wheelT);
        wheelT = setTimeout(() => setTextScale(prefs.txScale), 250);
      },
      { passive: false, capture: true }
    );
  }

  const setNativeLang = (v) => {
    if (!isLang(v)) return;
    prefs.nativeLang = v;
    const n = notationFor(v, prefs.keyNotation);
    if (n !== prefs.keyNotation) {
      // Ton. ⇄ Tông: same step, so the key itself stays where it is
      if (activePlayer && activePlayer.setNotation) activePlayer.setNotation(n);
      else prefs.keyNotation = n;
    }
    if (!SHARED) {
      try {
        localStorage.setItem(NATIVE_LANG, v);
        localStorage.setItem(KEY_NOTATION, String(prefs.keyNotation));
      } catch (e) {}
    }
    if (activePlayer && activePlayer.repaintKey) activePlayer.repaintKey();
    // Learn mode picks the new language up on its next frame (its paint loop watches prefs.nativeLang)
  };

  const renameItem = async (f) => {
    const old = String(f.path || f.name).split("/").pop();
    const name = prompt("Rename", old);
    if (!name || name.trim() === old) return;

    try {
      const r = await fetch("/main/api/rename", {
        method: "POST",
        headers: { "content-type": "application/json", "x-gallery": "1" },
        body: JSON.stringify({ path: f.path, name: name.trim() }),
      });
      if (!r.ok) throw new Error((await r.text()) || "Couldn’t rename it");
      const j = await r.json();
      const oldPath = f.path;

      f.path = j.path;
      f.name = j.name.replace(/\.[^/.]+$/, (x) => x.toUpperCase());
      f.src = j.src;
      if (f.art) f.art = j.src + "?art=1";
      f.tx = null;
      meta.hidden = true;
      $("info").onclick();
      const t = tileOf(f);
      if (t) t.setAttribute("aria-label", f.name);
      // every same-origin page (the shell and its frames) retitles its now-playing pill
      const wins = [];
      for (let i = 0; i < window.top.frames.length; i++) wins.push(window.top.frames[i]);
      wins.push(window.top); // last: the shell asks its frames what's playing
      for (const w of wins) {
        try {
          if (w !== window && w.__galleryRetitle) w.__galleryRetitle(oldPath, j.path, f.name);
        } catch (x) {}
      }
      if (window !== window.top && window.__galleryRetitle) window.__galleryRetitle(oldPath, j.path, f.name);
      tell("Renamed to " + j.name);
    } catch (e) {
      tell(e.message || "Couldn’t rename it", true);
    }
  };

  const pickCover = (f) => {
    const inp = document.createElement("input");
    inp.type = "file";
    inp.accept = "image/jpeg,image/png";
    inp.onchange = async () => {
      const file = inp.files && inp.files[0];
      if (!file) return;
      tell("Saving the cover…");

      try {
        const r = await fetch("/main/api/cover?" + new URLSearchParams({ path: f.path }), {
          method: "PUT",
          headers: { "content-type": file.type || "application/octet-stream", "x-gallery": "1" },
          body: file,
        });
        if (!r.ok) throw new Error((await r.text()) || "Couldn’t save the cover");
        const j = await r.json();

        f.art = j.art;
        f.noart = false;
        f.nocover = false;
        const t = tileOf(f);
        if (t) fillTile(t, f);
        if (items[cur] === f) show(cur);
        tell(j.embedded ? "Cover saved into the file" : "Cover saved (shown in Gallery; this file type keeps it beside the file)");
      } catch (e) {
        tell(e.message || "Couldn’t save the cover", true);
      }
    };
    inp.click();
  };

  // Delete cover: the file shows the file tile from now on, here, on reload and in its share links
  const deleteCover = async (f) => {
    if (!confirm("Delete the cover of " + f.name + "?")) return;

    try {
      const r = await fetch("/main/api/cover?" + new URLSearchParams({ path: f.path }), {
        method: "DELETE",
        headers: { "x-gallery": "1" },
      });
      if (!r.ok) throw new Error((await r.text()) || "Couldn’t delete the cover");

      f.art = null;
      f.nocover = true;
      const t = tileOf(f);
      if (t) fillTile(t, f);
      if (items[cur] === f) show(cur);
      tell("Cover deleted");
    } catch (e) {
      tell(e.message || "Couldn’t delete the cover", true);
    }
  };

  // Share from inside the viewer: a private link to just this item, with its own expiry, revocable
  if (G.main) {
    $("vshare").hidden = false;
    $("vshare").onclick = () => {
      const f = items[cur];
      if (f && !f.pending && window.galleryInvite) window.galleryInvite([f]);
    };
  }

  addEventListener("popstate", hide);

  addEventListener("keydown", (e) => {
    if (lb.hidden) return;

    if (e.target.closest && e.target.closest("textarea,input")) return; // typing a note

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
      y0 = e.touches[0].clientY;
    },
    { passive: true }
  );

  stage.addEventListener(
    "touchend",
    (e) => {
      if (x0 === null) return;

      const dx = e.changedTouches[0].clientX - x0;
      const dy = e.changedTouches[0].clientY - y0;
      x0 = null;

      const onControls = e.target.closest(".p-hb, .p-eq, .p-eqwrap, .pdfv, .p-ctrl");

      // a mostly vertical swipe: up opens the comments, down closes them; down with them closed goes Back
      if (Math.abs(dy) > 60 && Math.abs(dy) > Math.abs(dx) * 1.5 && !onControls) {
        if (dy > 0 && !document.body.classList.contains("comments-open")) history.back();
        else setOpen(dy < 0);
        return;
      }

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
    const addBtn = document.getElementById("addtile");
    grid.replaceChildren(...items.map(buildTile));
    if (addBtn) grid.appendChild(addBtn);

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

  // a room of one item opens straight onto it
  if (typeof G.start === "number" && items[G.start]) openAt(G.start);
  else {
    // ?open=<n>: a window opened onto one item (a link onto one item)
    const want = new URLSearchParams(location.search).get("open");
    const at = want ? items.findIndex((x) => x.n === want) : -1;
    if (at >= 0) openAt(at);
  }
})();