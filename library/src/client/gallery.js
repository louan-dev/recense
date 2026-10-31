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
  // where the owner's API lives: Main's, or the archive's (G.mainApi), which answers reads only and refuses every write
  const MAIN_API = G.mainApi || "/main/api";
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

  // A link's expiry always carries the time (a 1-hour link ends today, not just "27 October"),
  // in the viewer's own clock, like the owner's invite list.
  const expiresAt = (t) => {
    const day = (d) => new Date(d).setHours(0, 0, 0, 0);
    const n = Math.round((day(t) - day(Date.now())) / 86400000);
    const when = n === 0 ? "today" : n === 1 ? "tomorrow" : D(t, { day: "numeric", month: "long" });
    return when + " at " + new Date(t).toLocaleTimeString([], { hour: "numeric", minute: "2-digit" });
  };

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

  // SPEC 14: a text document's tile shows its first page, like a PDF's: the opening text drawn on a white
  // page to a small JPEG (cached with the PDF thumbnails). Text kinds only fetch their first 16 KB; Word
  // goes through mammoth's plain text. A file that fails keeps the icon tile.
  const isDocx = (f) => DOCX_RE.test(f.name) || /wordprocessingml/.test(f.type || "");
  const docThumbText = async (f) => {
    if (isDocx(f)) {
      const r = await fetch(src(f));
      if (!r.ok) throw new Error("couldn’t load");
      const lib = await loadMammoth();
      return { text: (await lib.extractRawText({ arrayBuffer: await r.arrayBuffer() })).value, md: false };
    }
    const r = await fetch(src(f), { headers: { Range: "bytes=0-16383" } });
    if (!r.ok) throw new Error("couldn’t load");
    const raw = new TextDecoder().decode(new Uint8Array(await r.arrayBuffer()).subarray(0, 16384));
    return { text: /\.rtf$/i.test(f.name) ? rtfText(raw) : raw, md: MD_RE.test(f.name) || f.type === "text/markdown" };
  };
  const textThumb = (f) =>
    thumbCache[f.n] ||
    (thumbCache[f.n] = docThumbText(f).then(({ text, md }) => {
      const W = 420, H = Math.round(W * 1.294), pad = 30, maxW = W - pad * 2; // A4/Letter-ish page
      const c = document.createElement("canvas");
      c.width = W;
      c.height = H;
      const g = c.getContext("2d");
      g.fillStyle = "#fff";
      g.fillRect(0, 0, W, H);
      g.textBaseline = "top";
      const SANS = '-apple-system,BlinkMacSystemFont,"Helvetica Neue",sans-serif';
      const MONO = "ui-monospace,SFMono-Regular,Menlo,monospace";
      const prose = md || isDocx(f);
      let y = pad;
      const lines = text.replace(/\r\n?/g, "\n").split("\n").slice(0, 400);
      for (let l of lines) {
        if (y > H - pad) break;
        let size = prose ? 15 : 12, weight = "400", color = "#1d1d1f";
        if (md) {
          const h = l.match(/^(#{1,6})\s+(.*)$/);
          if (h) {
            size = [26, 21, 18, 16, 15, 15][h[1].length - 1];
            weight = "700";
            l = h[2];
          } else if (/^```/.test(l) || /^\s*([-*_])(\s*\1){2,}\s*$/.test(l)) continue;
          l = l.replace(/^\s*>\s?/, "").replace(/^\s*[-*+]\s+/, "• ").replace(/!?\[([^\]]*)\]\([^)]*\)/g, "$1")
            .replace(/\*\*|__|~~|`/g, "").replace(/(^|\W)[*_]([^*_]+)[*_](?=\W|$)/g, "$1$2");
        }
        g.font = weight + " " + size + "px " + (prose ? SANS : MONO);
        g.fillStyle = color;
        const lh = Math.round(size * (prose ? 1.45 : 1.4));
        if (!l.trim()) {
          y += Math.round(lh * (prose ? 0.6 : 1));
          continue;
        }
        // wrap by width (break long words too)
        let rest = l.replace(/\t/g, "    ");
        while (rest && y <= H - pad) {
          let n = rest.length;
          if (g.measureText(rest).width > maxW) {
            let lo = 1, hi = rest.length;
            while (lo < hi) {
              const mid = (lo + hi + 1) >> 1;
              if (g.measureText(rest.slice(0, mid)).width <= maxW) lo = mid;
              else hi = mid - 1;
            }
            n = lo;
            const sp = rest.lastIndexOf(" ", n);
            if (prose && sp > n * 0.5) n = sp + 1;
          }
          g.fillText(rest.slice(0, n).trimEnd(), pad, y);
          y += lh;
          rest = prose ? rest.slice(n).trimStart() : rest.slice(n);
        }
        if (prose) y += Math.round(size * 0.5);
      }
      return c.toDataURL("image/jpeg", 0.82);
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
    key: 0, // semitones, -12 to +12; 0 is the original key (halves in Key state 8, cents in state 9)
    keyNotation: 0, // the Key slider's label state, 0–9 (see keylabel.js); kept in this browser
    nativeLang: "en", // the trailing language, "en" | "vi" | "fr": the second line of Key state 0
    vol: 1, // playback level, 0 to 1
    vox: 0, // the extractor (SPEC 30): -1 the vocals out, 1 the vocals alone, 0 as recorded; not kept between items
    space: { mix: 0, on: false, room: "room" }, // reverb, -100 to +100: + is the room, − the same room reversed; 0 is dry
    txScale: 1, // subtitle size, times the base size (the a|A pill, Info › Text Size, a pinch over the lyrics)
  };
  const SPEEDS = [0.5, 0.75, 1, 1.25, 1.5, 1.75, 2];
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

  // What is drawn between a line and its translation (item 20), cycled by the toggle under the vertical bar:
  // p = the prosody ribbon, c = the chord progression, n = the sung notes; "" = nothing. Kept in this browser.
  const NOTATION_MODE = "gallery.notationMode";
  prefs.notationMode = "p";
  try {
    const m = localStorage.getItem(NOTATION_MODE);
    if (m !== null && /^(p|c|n|pc|pn|cn|)$/.test(m)) prefs.notationMode = m;
  } catch (e) {}
  // read by prosogram-mount.js every frame: the mode, the chords heard so far on this item (time → name), and a
  // note's name in the notation the chords are spelled in (English: C/do, as the Key label; else the language's)
  const notation = (globalThis.GalleryNotation = {
    mode: () => prefs.notationMode,
    chords: [],
    media: null,
    noteName: (midi) => {
      const pc = ((Math.round(midi) % 12) + 12) % 12;
      const st = GalleryKey.chordState(prefs.nativeLang, prefs.keyNotation, prefs.notationLast);
      const name = GalleryKey.chordName({ pc, minor: false }, st);
      return st === 0 ? name + "/" + GalleryKey.chordName({ pc, minor: false }, 1).toLowerCase() : name;
    },
    heard: (text) => {
      const c = globalThis.GalleryClock;
      if (!text || !c || typeof c.now !== "function") return;
      if (notation.media !== c.media) (notation.media = c.media), (notation.chords = []);
      const t = c.now();
      if (!Number.isFinite(t)) return;
      const log = notation.chords.filter((x) => Math.abs(x.t - t) > 0.4);
      const last = log.filter((x) => x.t < t).pop();
      if (last && last.text === text) return; // the same chord held on
      log.push({ t, text });
      log.sort((a, b) => a.t - b.t);
      notation.chords = log;
    },
  });
  const applyNotation = () => {
    const m = prefs.notationMode, root = document.documentElement;
    root.classList.toggle("nt-off", !m);
    root.classList.toggle("nt-p", m.includes("p"));
  };
  applyNotation();

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

  // Original-language prominence (the vertical bar, homebar.js): null at rest (Learn mode as it is),
  // else 0…1. Kept in this browser like Text Size. On the lyrics it is two opacities, --po for the
  // original and --pt for the trailing language, with the original stacked over its translation.
  // The view the transcript shows in (chosen in the editor, SPEC 57): Learn, the two places the lines take in
  // turn (the default, SPEC 23), or Follow, the line being heard with its trailing language under it.
  const VIEW = "gallery.view";
  prefs.view = "learn";
  try {
    if (localStorage.getItem(VIEW) === "follow") prefs.view = "follow";
  } catch (e) {}
  const setView = (v) => {
    prefs.view = v === "follow" ? "follow" : "learn";
    try {
      localStorage.setItem(VIEW, prefs.view);
    } catch (e) {}
  };

  const PROMINENCE = "gallery.prominence";
  const promViews = new Set(); // () => repaint
  // Learn is the default view on every load: a prominence lasts while it's on screen, never across loads (a stray
  // two-finger swipe left 0.43 stored, and the translation stacked under the notation, lit, from then on)
  prefs.prominence = null;
  try {
    localStorage.removeItem(PROMINENCE);
  } catch (e) {}

  const paintProminence = () => {
    const m = Homebar.prominence(prefs.prominence);
    const r = document.documentElement;
    r.classList.toggle("prom", !!m);
    r.classList.toggle("prom-o0", !!m && m.orig === 0);
    r.classList.toggle("prom-t0", !!m && m.trail === 0);
    r.style.setProperty("--po", m ? String(m.orig) : "1");
    r.style.setProperty("--pt", m ? String(m.trail) : "1");
  };
  paintProminence();

  const setProminence = (p) => {
    prefs.prominence = p == null ? null : Homebar.snapProminence(p);
    paintProminence();
    promViews.forEach((f) => f());
  };

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

  // the bands, and the ranges of the bands and of Key, are the tray's (homebar.js), the same for the sound here and for downloads
  const { EQ_BANDS, KEY_MAX } = Homebar;

  // Key: transposition in semitones, by a phase vocoder in an AudioWorklet (see keyProcessor in
  // the Worker). Tempo and Speed are untouched by it. Loaded once per viewer, on first use.
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

  // Space: a convolution reverb (the rooms and their sound are room.js's, shared with Recense). One per
  // viewer, built on first use.
  const { ROOMS, irData, reverseIR, spaceGain } = GalleryRoom;
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
  // an iPhone or iPad (every browser there is WebKit), and its built-in speaker's output path when nothing reports one:
  // the hardware latency and I/O buffer an iPhone's speaker route reports to the iOS app (Player.swift), with the
  // WebKit render buffer on top
  const IOS = /iPad|iPhone|iPod/.test(navigator.userAgent) || (/Macintosh/.test(navigator.userAgent) && navigator.maxTouchPoints > 1);
  const IOS_ROUTE = 0.06;
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
  // A compressed file's sample rate from its header (MP3, AAC in ADTS or MP4, FLAC, Ogg), or 0.
  const nativeRate = (b) => {
    try {
      const n = b.length;
      const u32 = (o) => ((b[o] << 24) | (b[o + 1] << 16) | (b[o + 2] << 8) | b[o + 3]) >>> 0;
      const tag = (o, t) => [...t].every((c, i) => b[o + i] === c.charCodeAt(0));

      if (tag(0, "fLaC")) return (b[18] << 12) | (b[19] << 4) | (b[20] >> 4);
      if (tag(0, "OggS")) {
        for (let o = 0; o < Math.min(n - 16, 512); o++) {
          if (tag(o, "\x01vorbis")) return (b[o + 12] | (b[o + 13] << 8) | (b[o + 14] << 16)) >>> 0;
          if (tag(o, "OpusHead")) return 48000;
        }
      }
      // MP4: the first audio sample entry's rate (16.16 at +32 of mp4a/alac/...)
      for (let o = 4; o < n - 40; o++) {
        if (tag(o, "mp4a") || tag(o, "alac") || tag(o, "ac-3") || tag(o, "Opus")) {
          const r = (b[o + 28] << 8) | b[o + 29];
          if (r >= 8000 && r <= 192000) return r;
        }
      }
      let o = 0;
      if (tag(0, "ID3")) o = 10 + ((b[6] << 21) | (b[7] << 14) | (b[8] << 7) | b[9]);
      const end = Math.min(n - 4, o + 65536);
      for (; o < end; o++) {
        if (b[o] !== 0xff) continue;
        if ((b[o + 1] & 0xf6) === 0xf0) return [96000, 88200, 64000, 48000, 44100, 32000, 24000, 22050, 16000, 12000, 11025, 8000][(b[o + 2] >> 2) & 15] || 0; // ADTS
        if ((b[o + 1] & 0xe0) === 0xe0) {
          const v = (b[o + 1] >> 3) & 3;
          const i = (b[o + 2] >> 2) & 3;
          if (v === 1 || i === 3) continue;
          return [44100, 48000, 32000][i] / (v === 3 ? 1 : v === 2 ? 2 : 4);
        }
      }
    } catch (e) {}
    return 0;
  };

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
    // no context given (bake): one at the file's own rate, so nothing is resampled
    const dc = ctx || new (window.OfflineAudioContext || window.webkitOfflineAudioContext)(2, 1, nativeRate(first) || 44100);
    const ab = await new Promise((ok, no) => dc.decodeAudioData(all, ok, no));
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

  // The safety stage at the very end, live (a WaveShaper) and in a download (bake's write()): the sound
  // is untouched up to SAFE_KNEE and bent smoothly (tanh, slope 1 at the knee) above it so it never
  // passes 0.99. The EQ trim only knows the response's peak; a boost's filters still overshoot on
  // dense sound (measured to 1.57), and a big room at full mix to 1.21: this catches both.
  // the worklets' true delays in frames (player-key.js PDC_DELAY, measured by noise cross-correlation):
  // Key and the deck a whole 2048-frame frame, the extractor a whole 4096-frame frame
  const DELAY = { key: 2048, deck: 2048, vox: 4096 };

  const SAFE_KNEE = 0.9;
  const safeBend = (a) => SAFE_KNEE + (0.99 - SAFE_KNEE) * Math.tanh((a - SAFE_KNEE) / (0.99 - SAFE_KNEE));
  // the shaper's curve over -2..2 (it is fed half the level, see the graph)
  const safeCurve = () => {
    const n = 8193;
    const c = new Float32Array(n);
    for (let i = 0; i < n; i++) {
      const x = (4 * i) / (n - 1) - 2;
      const a = Math.abs(x);
      c[i] = a <= SAFE_KNEE ? x : Math.sign(x) * safeBend(a);
    }
    return c;
  };

  const soundOn = () => !!prefs.key || !!prefs.vox || !!(prefs.eq.low || prefs.eq.mid || prefs.eq.high) || spaceOn();

  // One EQ band's biquad coefficients: the Audio EQ Cookbook formulas, which are the ones Web
  // Audio's BiquadFilterNode uses, so a download has the sound you heard.
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

  let activePlayer = null;
  let galleryComments = () => null; // the comment count for the home bar (set with the comments, below)
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

  let nowEl = null; // the element the lock screen's Now Playing speaks for (SPEC 69)
  let nowGo = false; // the lock screen's ⏮ / ⏭ opened this item: it plays as soon as it is built

  // ⏮ / ⏭ on the lock screen step to the previous or next sound or video in this folder (photos are
  // skipped) and play it; ⏮ more than 3 s in starts this one over, as Apple Music does (notes item 11)
  const nowTrack = (d) => {
    for (let n = 1; n <= items.length; n++) {
      const j = (((cur + d * n) % items.length) + items.length) % items.length;
      const k = kind(items[j]);
      if (k === "aud" || k === "vid") {
        nowGo = true;
        return show(j);
      }
    }
  };

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
    if (nowGo) {
      nowGo = false;
      el.play().catch(() => {});
    }

    // ----- state: the home bar (below) keeps Track Loop, A–B and speed; this is what it last said -----

    let bar = null;
    let loopNow = { track: false, ab: false, a: null, b: null };
    let dragging = false; // a seek is under way: A–B holds off

    el.preservesPitch = true;   // speed changes tempo, never pitch
    el.playbackRate = prefs.speed;

    const toggle = () => {
      if (el.paused) {
        // at the end, play starts the track over: some engines leave a finished element stuck there (notes 42)
        if (el.ended || (el.duration && el.currentTime >= el.duration - 0.05)) el.currentTime = 0;
        // the context is woken here, inside the tap: Safari lets it start only on a gesture, and
        // `play` arrives after it (notes 20261029 item 10)
        unlockAudio();
        el.play().catch(() => {});
      } else el.pause();
    };

    const sync = () => bar && bar.paint();

    const ctrl = mkEl("div", "p-ctrl");

    // ----- toast -----

    const toast = mkEl("div", "p-toast");
    let toastT;

    const say = (t) => {
      toast.textContent = t;
      toast.classList.add("on");
      clearTimeout(toastT);
      toastT = setTimeout(() => toast.classList.remove("on"), 1300);
    };

    // ----- the home bar (homebar.js, shared with Recense) -----
    //
    // The bar owns Track Loop, A–B and speed and hands them here; nothing else in the player moves
    // the playhead. A–B does its own looping (it jumps at B); the native repeat is for the whole track.

    let raf = 0;

    const atB = () => {
      if (loopNow.ab && !el.paused && !dragging && el.currentTime >= loopNow.b) el.currentTime = loopNow.a; // (not while you are seeking)
    };

    const tick = () => {
      if (loopNow.ab && !el.paused) {
        atB();
        raf = requestAnimationFrame(tick);
      }
    };

    // A tab out of sight gets no animation frames, so A–B stopped looping as soon as another tab or
    // another app was in front: there the element's own timeupdate (a few times a second) jumps back.
    el.addEventListener("timeupdate", atB);

    const watch = () => {
      cancelAnimationFrame(raf);
      if (loopNow.ab && !el.paused) raf = requestAnimationFrame(tick);
    };

    el.onended = () => {
      if (loopNow.ab) {
        el.currentTime = loopNow.a;
        el.play().catch(() => {});
      }
    };

    bar = Homebar.horizontal({
      time: () => el.currentTime,
      duration: () => el.duration,
      paused: () => el.paused,
      seek: (t) => {
        el.currentTime = t;
      },
      toggle,
      skip: (d) => {
        el.currentTime = clamp(el.currentTime + d, 0, el.duration || 0);
      },
      setRate: (v) => {
        // see startDeck: a file Safari plays through the element itself, with Sound on
        if (v !== 1 && DECK && nodes && nodes.mode === "tap") {
          say("Speed is 1× with Sound on, for this file");
          v = 1;
        }
        prefs.speed = v;
        el.playbackRate = v;
        return v;
      },
      setLoop: (l) => {
        loopNow = l;
        prefs.loop = l.track ? "track" : "off";
        el.loop = l.track && !l.ab; // the only loop flag painted onto the media element
        watch();
        if (nowEl === el && ms) nowMeta(); // (nowEl first: ms is declared below) the lock screen says which loop is on
      },
      scrub: (on) => {
        dragging = on;
      },
      say: (t) => say(t),
      wake: () => wake(),
      onOpen: (on) => {
        w.classList.toggle("tools", on);
        if (on && tray.isOpen()) tray.hide(); // one tray at a time
      },
      onSeekStart: () => {
        if (tray.isOpen()) tray.hide();
      },
      lang: { get: () => prefs.nativeLang, set: (v) => setNativeLang(v) },
      size: { get: () => prefs.txScale, set: (v) => setTextScale(v), min: TXS_MIN, max: TXS_MAX, step: TXS_STEP },
      // (no hover slide: the language moved into the transcript editor, SPEC 57; hovering unfolds the first slide)
      frost: kind(item) === "vid", // frosted glass for videos only (SPEC 38)
      slides: () => barSlides(item),
    });

    const hb = bar.el;

    // ----- lock screen / Control Center Now Playing (SPEC 69) -----
    //
    // The file's own title and cover instead of "Music", and a scrubber that works: Play, Pause and
    // Seek act on this element, and its position, length and speed are kept current. No ±15 s (the
    // scrubber does that): ⏮ / ⏭ either side of Play, as in Apple Music. The web can't add buttons
    // there, so the loop is set in the player and the lock screen's second line says which is on.
    // Whichever element last started playing has it; a parked track keeps it while it plays on.

    const ms = navigator.mediaSession;

    const nowPos = () => {
      if (!ms || nowEl !== el) return;
      try {
        ms.playbackState = el.paused ? "paused" : "playing";
        const d = el.duration;
        if (!isFinite(d) || d <= 0) return;
        ms.setPositionState({ duration: d, playbackRate: el.playbackRate || 1, position: clamp(el.currentTime || 0, 0, d) });
      } catch (x) {}
    };

    const nowAct = (a, h) => {
      try {
        ms.setActionHandler(a, h);
      } catch (x) {}
    };

    const nowLoop = () =>
      loopNow.ab && loopNow.a != null && loopNow.b != null ? "A–B loop · " + dur(loopNow.a) + " – " + dur(loopNow.b) : loopNow.track ? "Loop" : "";

    const nowMeta = () => {
      const title = String(item.name || item.path || "").replace(/\.[^/.]+$/, "") || "Gallery";
      const art = artUrl || artSrc(item);
      const meta = { title, artist: nowLoop(), album: "" };

      try {
        if (art) meta.artwork = [{ src: new URL(art, location.href).href }];
      } catch (x) {}

      try {
        ms.metadata = new MediaMetadata(meta);
      } catch (x) {}
    };

    const nowClaim = () => {
      // a playback session, not ambient sound: it goes on with the browser left or the phone locked (notes 27)
      try {
        if (navigator.audioSession && navigator.audioSession.type !== "playback") navigator.audioSession.type = "playback";
      } catch (x) {}
      if (!ms) return;
      nowEl = el;
      nowMeta();

      nowAct("play", () => {
        unlockAudio(); // the lock screen's Play is a gesture too
        el.play().catch(() => {});
      });
      nowAct("pause", () => el.pause());
      nowAct("seekto", (e) => {
        if (typeof e.seekTime !== "number") return;
        if (e.fastSeek && el.fastSeek) el.fastSeek(e.seekTime);
        else el.currentTime = e.seekTime;
        nowPos();
      });
      nowAct("seekbackward", null);
      nowAct("seekforward", null);
      nowAct("previoustrack", () => {
        if (el.currentTime > 3) {
          el.currentTime = loopNow.ab ? loopNow.a : 0;
          nowPos();
        } else nowTrack(-1);
      });
      nowAct("nexttrack", () => nowTrack(1));
      nowPos();
    };

    const nowDrop = () => {
      if (!ms || nowEl !== el) return;
      nowEl = null;
      try {
        ms.metadata = null;
        ms.playbackState = "none";
        ms.setPositionState();
      } catch (x) {}
      ["play", "pause", "seekto", "previoustrack", "nexttrack"].forEach((a) => nowAct(a, null));
    };

    el.addEventListener("play", nowClaim);
    ["pause", "ratechange", "durationchange", "seeked", "timeupdate"].forEach((ev) => el.addEventListener(ev, nowPos));

    // ----- the EQ island: Gallery's tray on the shared vertical bar -----
    //
    // The bar itself (homebar.js) is the original language's prominence: swipe or drag it. A tap opens
    // and closes the tray, as hovering it does, however many times the sound is reshaped (SPEC 52).
    // Press and hold puts everything changed (text size, prominence, EQ, C/Đô, reverb) back; a tap
    // right after brings it all back again.

    const vbar = Homebar.vertical({
      prominence: { get: () => prefs.prominence, set: (v) => setProminence(v) },
      notation: {
        get: () => prefs.notationMode,
        set: (m) => {
          prefs.notationMode = m;
          try {
            localStorage.setItem(NOTATION_MODE, m);
          } catch (e) {}
          applyNotation();
          if (tray && tray.setChords) tray.setChords(m.includes("c"));
        },
      },
      shaped: () => !soundPlain() || prefs.txScale !== 1 || prefs.prominence != null,
      tap: () => (tray.isOpen() ? tray.hide() : tray.show(5000)),
      tare: () => {
        const snap = { eq: { ...prefs.eq }, key: prefs.key, vox: prefs.vox, space: { ...prefs.space }, txScale: prefs.txScale, prominence: prefs.prominence };
        resetAll();
        tray.bump();
        return snap;
      },
      untare: (s) => {
        restoreAll(s);
        tray.bump();
      },
      say: (t) => say(t),
      wake: () => wake(),
      onGestureEnd: () => unlockAudio(),
    });
    let chordAn = null;
    const tray = Homebar.tray({
      state: prefs,
      vbar,
      rooms: ROOMS,
      keyName: () => (item && item.key) || "",
      // the chord detector (SPEC 40): a live chroma off the sound engine's output; it starts the engine
      chroma: () => {
        if (!nodes && !ensureEq()) return null;
        if (!nodes || el.paused) return null;
        if (!chordAn || chordAn.n !== nodes) {
          const a = audioCtx.createAnalyser();
          a.fftSize = 8192;
          a.smoothingTimeConstant = 0.6;
          nodes.master.connect(a);
          chordAn = { n: nodes, a, db: new Float32Array(a.frequencyBinCount) };
        }
        chordAn.a.getFloatFrequencyData(chordAn.db);
        return GalleryKey.chromaOfSpectrum(chordAn.db, audioCtx.sampleRate);
      },
      // directly above the transcript's lines; with no transcript, where the lines would be
      chords: (t) => {
        const st = el.closest(".vw, .aw") || w;
        let c = st.querySelector(".txchord");
        notation.heard(t);
        // with a transcript on screen the progression is drawn in the notation lane, under the words (item 20)
        if (t && st.querySelector("canvas.pg-lane") && prefs.notationMode.includes("c")) t = null;
        if (!t) return c && (c.hidden = true);
        if (!c) {
          c = document.createElement("div");
          c.className = "txchord";
          c.setAttribute("aria-live", "polite");
        }
        const box = st.querySelector(".tx.learn");
        if (box ? c.parentNode !== box || box.firstChild !== c : c.parentNode !== st) box ? box.prepend(c) : st.appendChild(c);
        c.classList.toggle("over", !!box);
        c.textContent = t;
        c.hidden = false;
      },
      notation: () => {
        if (!SHARED) {
          try {
            localStorage.setItem(KEY_NOTATION, String(prefs.keyNotation));
          } catch (e) {}
        }
      },
      sound: {
        band: (id, db) => {
          // back to flat with no Web Audio yet: nothing to change but the setting
          if (!db && !nodes) return true;
          if (!ensureEq()) return false;
          if (!nodes) return true; // taken up with the graph once the sound engine runs

          // the trim comes down with the boost, never after it, and goes back up as the boost eases
          const t = audioCtx.currentTime;
          const g = eqTrim();
          nodes.f[id].gain.cancelScheduledValues(t);
          nodes.f[id].gain.setTargetAtTime(db, t, 0.03);
          nodes.trim.gain.cancelScheduledValues(t);
          nodes.trim.gain.setTargetAtTime(g, t, g < nodes.trim.gain.value ? 0.005 : 0.06);
          return true;
        },
        key: (st) => {
          if (!st && !nodes) return true; // back to 0 with no Web Audio yet: just the setting
          if (!ensureEq()) return false;
          if (nodes) applyKey();
          return true;
        },
        space: () => {
          if (!ensureEq()) return false;
          if (nodes) applySpace();
          return true;
        },
        vox: (v) => {
          if (!v && !nodes) return true; // back to off with no Web Audio yet: just the setting
          if (!window.AudioWorkletNode && !DECK) return false;
          if (!ensureEq()) return false;
          if (nodes) applyVox();
          return true;
        },
        live: () => !!nodes,
      },
      onOpen: (on) => hb.classList.toggle("away", on),
      onShow: () => {
        if (bar.open) bar.hide();
      },
      say: (t) => say(t),
      wake: () => wake(),
    });

    ctrl.append(tray.el);
    // a saved mode with chords: the detector starts with the first play (it starts the sound engine, which wants a gesture)
    if (prefs.notationMode.includes("c") && tray.setChords) el.addEventListener("play", () => prefs.notationMode.includes("c") && tray.setChords(true), { once: true });

    // Recense's tray (note 30) is its own controller: while Recense follows this tab its values drive this
    // chain (not saved as Gallery's prefs), and the bridge is told so it never takes the element a second time
    if (document.documentElement.dataset.recenseFx === "1") {
      window.addEventListener("message", (e) => {
        const fx = e.source === window && e.data && e.data.recenseFx;
        if (!fx) return;
        window.postMessage({ recenseFxAck: true }, location.origin);
        EQ_BANDS.forEach((b) => (prefs.eq[b.id] = Number(fx.eq && fx.eq[b.id]) || 0));
        prefs.key = Number(fx.key) || 0;
        prefs.space.mix = Math.max(-100, Math.min(100, Number(fx.mix) || 0));
        prefs.space.on = !!prefs.space.mix;
        if (fx.room && ROOMS[fx.room]) prefs.space.room = fx.room;
        if (!ensureEq() || !nodes) return tray.bump();
        const t = audioCtx.currentTime;
        EQ_BANDS.forEach((b) => {
          nodes.f[b.id].gain.cancelScheduledValues(t);
          nodes.f[b.id].gain.setTargetAtTime(prefs.eq[b.id], t, 0.03);
        });
        const g = eqTrim();
        nodes.trim.gain.cancelScheduledValues(t);
        nodes.trim.gain.setTargetAtTime(g, t, g < nodes.trim.gain.value ? 0.005 : 0.06);
        applyKey();
        applySpace();
        tray.bump();
      });
    }

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
    const soundPlain = () => eqIsFlat() && !prefs.key && !spaceOn() && !prefs.vox;

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
          // Out of the browser or locked (notes 27): iOS interrupts Web Audio; whatever is still playing
          // asks for it back, now and when the page is seen again, so the sound carries on in the background.
          const c = audioCtx;
          const back = () => {
            if (audioCtx === c && c.state !== "running" && c.state !== "closed" && ((nowEl && !nowEl.paused) || [...ctxEls].some((e) => !e.paused))) c.resume().catch(() => {});
          };
          c.onstatechange = back;
          document.addEventListener("visibilitychange", back);
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
        if (!DECK) el.dataset.galleryFx = "1"; // Recense's bridge drives this chain instead of taking the element twice
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

        // the extractor (SPEC 30): dry until it is asked for, then crossfaded to the worklet
        const voxDry = audioCtx.createGain();
        const voxWet = audioCtx.createGain();
        const voxSum = audioCtx.createGain();
        voxWet.gain.value = 0;
        // The dry paths run as late as the worklets do (Vox a 4096-frame frame, Key 2048), so a crossfade
        // joins the same moment of the sound, not two 46-85 ms apart. That delay is there all the time
        // (moving it would be the same jump), so it is only on a sound-only element: a video keeps its
        // dry path undelayed, lips in sync, and its crossfades jump.
        const lag = el.tagName === "VIDEO" ? 0 : 1;
        const voxDly = audioCtx.createDelay(1);
        voxDly.delayTime.value = (lag * DELAY.vox) / audioCtx.sampleRate;
        prev.connect(voxDly);
        voxDly.connect(voxDry);
        voxDry.connect(voxSum);
        voxWet.connect(voxSum);
        prev = voxSum;

        const keyDry = audioCtx.createGain();
        const keyWet = audioCtx.createGain();
        const mix = audioCtx.createGain();
        const spDry = audioCtx.createGain();
        const master = audioCtx.createGain();

        keyWet.gain.value = 0;
        master.gain.value = volGain();
        const keyDly = audioCtx.createDelay(1);
        // (on the deck the Key stage here stays dry: the deck shifts the key itself)
        const klag = DECK ? 0 : lag;
        keyDly.delayTime.value = (klag * DELAY.key) / audioCtx.sampleRate;
        const dryLag = (lag * DELAY.vox + klag * DELAY.key) / audioCtx.sampleRate;
        prev.connect(keyDly);
        keyDly.connect(keyDry);
        keyDry.connect(mix);
        keyWet.connect(mix);
        mix.connect(spDry);
        spDry.connect(master);

        // the safety stage (see safeCurve()): half the level in, the curve gives it back whole
        const half = audioCtx.createGain();
        const safe = audioCtx.createWaveShaper();
        half.gain.value = 0.5;
        safe.curve = safeCurve();
        master.connect(half);
        half.connect(safe);
        safe.connect(audioCtx.destination);

        if (!DECK) ctxEls.add(el);
        nodes = { src, mode: DECK ? "deck" : "tap", tap: null, f, trim, last: prev, half, safe, keyDly, voxDly, dryLag, keyDry, keyWet, mix, spDry, master, key: null, keyState: "off", sp: null, voxDry, voxWet, voxSum, vox: null, voxState: "off" };

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

        if (DECK) {
          startDeck();

          // The element plays on while a context iOS stopped stays down, its sound silenced with it: the
          // scrubber moved with nothing heard. After three seconds of that it pauses, so the player and the
          // lock screen say so, and the next Play (a gesture) starts the context again.
          const n = nodes;
          let down = 0;
          const watch = setInterval(() => {
            if (nodes !== n || !audioCtx) return clearInterval(watch);
            if (el.paused || el.ended || audioCtx.state === "running") return void (down = 0);
            audioCtx.resume().catch(() => {});
            if (++down < 3) return;
            down = 0;
            el.pause();
            if (!document.hidden) say("Sound was stopped by the system: press play");
          }, 1000);
        }

        // a later player picks Key and Space up where you left them
        if (prefs.key) applyKey();
        if (spaceOn()) applySpace();
        if (prefs.vox) applyVox();

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

      // Now Playing (lock screen, Control Center) follows only an audible element, and a muted
      // one drops out of it (SPEC 69). So the element's own sound is taken into Web Audio and let
      // out at nothing instead: the element stays what the lock screen shows and scrubs.
      if (!deck.hush) {
        try {
          const t = audioCtx.createMediaElementSource(el);
          const z = audioCtx.createGain();
          z.gain.value = 0;
          t.connect(z);
          z.connect(audioCtx.destination);
          deck.hush = { t, z };
        } catch (x) {
          el.muted = true;
        }
      }

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
      d.ctx = typeof m.ctx === "number" ? m.ctx : null;
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
      // (WebKit reports no output latency: the iOS app hands the page its audio route's, AirPods' ~0.2 s included; a
      // browser on the iPhone or iPad, Firefox and Safari alike, gets nothing, so it assumes the built-in speaker's path,
      // IOS_ROUTE: without it the light ran ahead of the voice there, owner 2026-10-30)
      const route = +globalThis.galleryOutputLatency || (IOS ? IOS_ROUTE : 0);
      const out = audioCtx ? Math.max((audioCtx.outputLatency || 0) + (audioCtx.baseLatency || 0), route) : 0;
      const d = deck;

      if (d && d.live && typeof d.at === "number" && !el.paused && !el.seeking) {
        // Where the speakers are, from the context itself (getOutputTimestamp: the context time being played now): the
        // device's output latency in it whether or not outputLatency is reported, which iOS Safari never does (the
        // light ran ahead of the voice on the iPhone, Sororité, item 27). The app's route latency covers what it misses.
        const ts = d.ctx != null && audioCtx.getOutputTimestamp ? audioCtx.getOutputTimestamp() : null;
        if (ts && ts.contextTime > 0 && ts.performanceTime > 0) {
          const outNow = ts.contextTime + (performance.now() - ts.performanceTime) / 1000;
          const known = Math.max(0, audioCtx.currentTime - outNow);
          const more = Math.max(0, route - known);
          const ran = d.playing ? Math.max(-0.5, Math.min(outNow - d.ctx, 0.5)) : 0;
          const t = d.at + (ran - more - DELAY.deck / audioCtx.sampleRate - (nodes ? nodes.dryLag || 0 : 0)) * r;
          if (Math.abs(t - el.currentTime) < 1.5) return Math.max(0, t);
        }
        const ran = d.playing ? (performance.now() - d.atWall) / 1000 : 0;
        const t = d.at + (Math.min(ran, 0.5) - out - DELAY.deck / audioCtx.sampleRate - (nodes ? nodes.dryLag || 0 : 0)) * r;
        if (Math.abs(t - el.currentTime) < 1.5) return Math.max(0, t);
      }

      return Math.max(0, el.currentTime - (nodes && !el.paused ? (out + (nodes.dryLag || 0)) * r : 0));
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

          if (bar.speed !== 1) {
            bar.setSpeed(1);
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

    // --- the extractor (SPEC 30) ---
    //
    // Like Key: the worklet (player-key.js, "pdc-vox") is crossfaded in once it has had a frame to
    // work on, and out to the dry path at 0. A recording with no stereo (all centre) says so once.

    const applyVox = () => {
      const n = nodes;
      const v = prefs.vox;

      if (!v) {
        if (n.voxState === "off") return;
        n.voxState = "off";
        n.voxDry.gain.setTargetAtTime(1, audioCtx.currentTime, 0.012);
        n.voxWet.gain.setTargetAtTime(0, audioCtx.currentTime, 0.012);
        setTimeout(() => {
          if (nodes === n && n.voxState === "off" && n.vox) {
            n.vox.port.postMessage({ end: true });
            n.vox.disconnect();
            n.vox = null;
          }
        }, 150);
        return;
      }

      if (n.vox) {
        n.vox.port.postMessage({ amount: v });
        return;
      }

      workletReady().then(
        () => {
          if (nodes !== n || !prefs.vox || n.vox) return;

          const x = new AudioWorkletNode(audioCtx, "pdc-vox", {
            numberOfInputs: 1,
            numberOfOutputs: 1,
            outputChannelCount: [2],
            channelCount: 2,
            channelCountMode: "explicit",
            channelInterpretation: "speakers",
            processorOptions: { amount: prefs.vox },
          });

          x.port.onmessage = (e) => {
            if (e.data && e.data.mono && nodes === n && prefs.vox < 0) say("This recording is mono: there is no centre to take the vocals out of");
          };

          n.trim.connect(x);
          x.connect(n.voxWet);
          n.vox = x;
          n.voxState = "warming";

          setTimeout(() => {
            if (nodes !== n || n.voxState !== "warming") return;
            n.voxState = "on";
            n.voxDry.gain.setTargetAtTime(0, audioCtx.currentTime, 0.012);
            n.voxWet.gain.setTargetAtTime(1, audioCtx.currentTime, 0.012);
          }, 120);
        },
        () => {
          if (nodes !== n) return;
          prefs.vox = 0;
          tray.paint();
          say("The extractor isn’t available in this browser");
        }
      );
    };

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
          tray.paintKey();
          tray.paintEq();
          say("Key isn’t available in this browser");
        }
      );
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

    // ----- the vertical bar's gestures are homebar.js's -----
    //
    // Safari and iPhone only let a context start (or restart) on a finger lifting or a click, so
    // the end of a swipe on the vertical bar is where a graph the swipe had to start is brought to life.
    const unlockAudio = () => {
      if (audioCtx && audioCtx.state !== "running") audioCtx.resume().catch(() => {});
    };

    // Holding the vertical bar while it is blue puts everything it stands for back: the sound, the
    // text size and the original's prominence. It turns white again.
    const resetAll = () => {
      if (!soundPlain()) tray.reset();
      if (prefs.txScale !== 1) setTextScale(1);
      if (prefs.prominence != null) setProminence(null);
      vbar.paint();
    };

    // the undo of a tare: everything as it was just before
    const restoreAll = (s) => {
      tray.restore(s);
      if (prefs.txScale !== s.txScale) setTextScale(s.txScale);
      if (prefs.prominence !== s.prominence) setProminence(s.prominence);
      vbar.paint();
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
    // the bar's blue follows text size and prominence, wherever they are changed
    const onReading = () => {
      vbar.paint();
      bar.paintSize();
    };
    txsViews.add(onReading);
    promViews.add(onReading);
    let hideT;

    const wake = () => {
      chrome.forEach((c) => {
        c.style.opacity = "1";
      });

      clearTimeout(hideT);

      if (!el.paused && !dragging && !bar.busy && !tray.busy() && !bar.open && !tray.isOpen()) {
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
      if (performance.now() - bar.seekEndAt < 450) return; // the tail of a seek drag is not a tap

      const inTools = e.target.closest(".p-hb") || e.target.closest(".p-eq") || e.target.closest(".p-eqbtn");

      if ((bar.open || tray.isOpen()) && !inTools) {
        // tapping away only folds the trays back
        if (bar.open) bar.hide();
        if (tray.isOpen()) tray.hide();
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

    // the bar starts where the last player left it
    bar.setSpeed(prefs.speed);
    if (prefs.loop === "track") bar.report({ loop: { track: true, ab: false, a: null, b: null } });
    tray.paintKey();
    tray.paintSpace();
    tray.paintEq();
    sync();

    activePlayer = {
      el,
      wrap: w,
      item,
      toggle,
      heard,
      note: say,
      repaintKey: () => tray.paintKey(), // after the item's original key, or the native language, changes
      setNotation: (n) => tray.setKeyNotation(n),
      paintChord: () => tray.paintChord(),
      bar, // the home bar's own surface (homebar.js): paint() after an item's menus change
      toggleLoop: () => {
        bar.pressLoop();
        wake();
      },
      captureA: () => {
        bar.captureA();
        wake();
      },
      captureB: () => {
        bar.captureB();
        wake();
      },
      speedStep: (dir) => bar.speedStep(dir),
      // Escape folds an open tray first; returns true if it did, so the viewer stays open
      closeTools: () => {
        if (bar.close()) return true;

        if (tray.isOpen()) {
          tray.hide();
          return true;
        }

        return false;
      },
      kill: () => {
        // A player that's gone lets go of its file too (SPEC 35). Left as it was, a paused element out of the page
        // could still be played by whatever held on to it (the Recense bridge on the global ⏯, the browser's
        // media keys): unseen, out of reach of Pause and of the next track, and the ⏯ went to it, not the file open.
        try {
          el.pause();
          el.removeAttribute("src");
          el.load();
        } catch (x) {}
        nowDrop();
        clearTimeout(hideT);
        clearTimeout(toastT);
        tray.kill();
        bar.kill();
        vbar.kill();
        txsViews.delete(onReading);
        promViews.delete(onReading);
        cancelAnimationFrame(raf);
        if (pipBtn) pipBtn.remove();

        if (deck) {
          try {
            deck.node.port.postMessage({ end: true });
            deck.node.disconnect();
            if (deck.hush) {
              deck.hush.t.disconnect();
              deck.hush.z.disconnect();
            }
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
            [n.voxDry, n.voxWet, n.voxSum, n.keyDry, n.keyWet, n.mix, n.spDry, n.master, n.half, n.safe, n.keyDly, n.voxDly].forEach((x) => x && x.disconnect());

            if (n.vox) {
              n.vox.port.postMessage({ end: true });
              n.vox.disconnect();
            }

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

    if (isPdf(f) || isTextDoc(f)) {
      (isPdf(f) ? pdfThumb(f) : textThumb(f))
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
    if (ownsLink()) arrangeTile(b, f);
    return b;
  };

  const tileOf = (f) => grid.querySelector('[data-n="' + f.n + '"]');

  // the owner's order on a share link (notes item 4), then the rest by number
  const byOrder = (a, b) => {
    const o = G.order || [];
    const at = (f) => (o.includes(f.n) ? o.indexOf(f.n) : 1e6 + Number(f.n));
    return at(a) - at(b) || (a.n < b.n ? -1 : a.n > b.n ? 1 : 0);
  };

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
    $("exp").textContent = G.exp ? "Expires " + expiresAt(G.exp) : "";

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
    remember(f);

    if (killPdf) {
      killPdf();
      killPdf = null;
    }

    endPlayer();
    if (prefs.prominence != null) setProminence(null); // each item opens in Learn
    stage.replaceChildren();
    meta.hidden = true;
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

    // audio and video carry Info, the comments and Share in the home bar (homebar.js); photos and
    // documents keep them in the bottom bar
    lb.classList.toggle("hasbar", !f.pending && (k === "aud" || k === "vid"));

    if (thumbs) {
      thumbs.forEach((t, j) => t.classList.toggle("on", j === cur));
      strip.scrollLeft = thumbs[cur].offsetLeft - (strip.clientWidth - 30) / 2;
    }
  };

  // The open item is in the address (?open=<n>, which a load opens onto), so a refresh stays on it instead of
  // landing on the folder; in a shelled folder the top window's address follows too, as it is what reloads.
  const remember = (f) => {
    try {
      const u = new URL(location.href);
      if (f) u.searchParams.set("open", G.main && f.path ? f.path : f.n);
      else u.searchParams.delete("open");
      history.replaceState(history.state, "", u);
      if (parent !== window && parent.location.origin === location.origin) parent.history.replaceState(parent.history.state, "", u);
    } catch (x) {}
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
    remember(null);

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
  // The two bars stand just above the bottom bar (the thumbnail strip and the comment label), whatever its real
  // height on this screen and in this orientation (SPEC 55): --botH feeds the bars' --bb0 (gallery.css).
  if (botBar && window.ResizeObserver) {
    const fitBars = () => lb.style.setProperty("--botH", Math.round(botBar.getBoundingClientRect().height) + "px");
    new ResizeObserver(fitBars).observe(botBar);
    fitBars();
  }
  const ownerName = String(G.owner || "").split(" ")[0] || "Owner";
  const me = G.invite ? G.invite.name : G.owner;
  const API = G.api || MAIN_API;
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

  // someone who opened a share link (not the owner): they comment under a name they choose once, and the server knows
  // them by a cookie; G.you is its hash, the vid on their comments and likes (public.js guestCommentApi)
  const GUEST_NAME = "gallery.guestName";
  const guest = () => !owner && !G.main && !G.invite && !G.readOnly && !!G.id;
  const guestName = () => {
    try { return localStorage.getItem(GUEST_NAME) || ""; } catch (_) { return ""; }
  };
  const askName = () => {
    const n = (prompt("Your name, so " + (String(G.owner || "").split(" ")[0] || "the owner") + " knows who commented", guestName()) || "").trim();
    if (n) try { localStorage.setItem(GUEST_NAME, n); } catch (_) {}
    return n;
  };
  const isMe = (x) => (guest() ? !!G.you && x.vid === G.you : !x.vid && (G.invite ? x.by === me : !x.by || x.by === G.owner));
  const canWrite = () => (G.invite ? !!(G.invite.perms && G.invite.perms.comment) : owner || guest());
  const listOf = (f) => (f && Array.isArray(f.comments) ? f.comments : f && f.caption ? [{ id: "c0", text: f.caption, at: f.capAt, by: G.owner }] : []);
  const mine = isMe;
  const nameOf = (c) => (mine(c) ? "You" : c.by === G.owner || !c.by ? ownerName : c.by);
  const postedAt = (t) => D(t, { day: "numeric", month: "short", year: "numeric" }) + " at " + T(t);
  const isOpen = () => document.body.classList.contains("comments-open");

  const send = async (f, body) => {
    const asGuest = guest();
    const name = asGuest ? guestName() || askName() : "";
    if (asGuest && !name) throw new Error("Add your name to comment");
    const r = await fetch(asGuest ? "/api/caption" : API + "/caption", {
      method: "PUT",
      headers: { "content-type": "application/json", "x-gallery": "1" },
      body: JSON.stringify({ ...commentScope(f), ...body, ...(asGuest ? { name } : {}) }),
    });

    if (!r.ok) {
      const t = await r.text();
      if (asGuest && r.status === 400 && /name/i.test(t)) try { localStorage.removeItem(GUEST_NAME); } catch (_) {}
      throw new Error(t || "Couldn’t save the comment");
    }

    const j = await r.json();
    if (j.you) G.you = j.you;
    f.comments = j.comments || [];
    f.caption = j.caption || "";
    f.capAt = j.capAt || 0;
    f.likes = j.likes || [];
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
  // the comments, as the home bar's slide shows them: null when there is nothing to show or write
  galleryComments = (f) => {
    const n = listOf(f).length;
    if (!f || f.pending || (!n && !canWrite())) return null;
    return { n, text: n ? n + (n === 1 ? " comment" : " comments") : "Add a comment…", open: () => setOpen(true) };
  };

  const paintLabel = (f) => {
    const n = listOf(f).length;

    cmEl.replaceChildren();
    cmEl.hidden = !f || f.pending || (!n && !canWrite());
    if (cmEl.hidden) return;

    const label = mkEl("button", "cmlabel");
    label.type = "button";
    label.textContent = n ? n + (n === 1 ? " comment" : " comments") : "Add a comment…";
    label.classList.toggle("has", !!n); // white with none, blue with comments (SPEC 41)
    label.onclick = () => setOpen(true);
    // item 18: a horizontal swipe over the label slides to "Share" (right to left) and back (left to right)
    const share = mkEl("button", "cmlabel cmshare");
    share.type = "button";
    share.textContent = "Share";
    share.onclick = () => shareMenu(f, share);
    const track = mkEl("div", "cmtrack");
    track.append(label, share);
    track.classList.toggle("on", cmShare);
    cmEl.appendChild(track);
    const go = (on) => {
      cmShare = on;
      track.classList.toggle("on", on);
    };
    let x0 = null;
    track.addEventListener("touchstart", (e) => (x0 = e.touches.length === 1 ? [e.touches[0].clientX, e.touches[0].clientY] : null), { passive: true });
    track.addEventListener(
      "touchend",
      (e) => {
        if (!x0) return;
        const t = e.changedTouches[0], dx = t.clientX - x0[0], dy = t.clientY - x0[1];
        x0 = null;
        if (Math.abs(dx) > 30 && Math.abs(dx) > Math.abs(dy) * 1.5) {
          e.preventDefault(); // the swipe is not a tap
          go(dx < 0);
        }
      },
      { passive: false },
    );
    let wheelAt = 0;
    track.addEventListener(
      "wheel",
      (e) => {
        if (Math.abs(e.deltaX) < 12 || Math.abs(e.deltaX) < Math.abs(e.deltaY)) return;
        e.preventDefault();
        if (Date.now() - wheelAt < 500) return; // one trackpad swipe, one step
        wheelAt = Date.now();
        go(e.deltaX > 0);
      },
      { passive: false },
    );
  };

  // "Share" in the home bar: Create a Share Link, AirDrop, Invite for the item on screen
  let cmShare = false;
  const shareMenu = (f, at) => {
    document.querySelectorAll(".cmmenu").forEach((m) => m.remove());
    if (!f) return;
    const menu = mkEl("div", "mnu cmmenu");
    menu.setAttribute("role", "menu");
    const close = () => {
      menu.remove();
      document.removeEventListener("pointerdown", away, true);
    };
    const away = (e) => !menu.contains(e.target) && close();
    const row = (text, act) => {
      const b = mkEl("button", "mi");
      b.type = "button";
      b.setAttribute("role", "menuitem");
      b.textContent = text;
      b.onclick = () => (close(), act());
      menu.appendChild(b);
    };
    row("Create a Share Link", () => (window.galleryShareLink ? window.galleryShareLink([f]) : (location.href = "/main/share")));
    row("AirDrop", async () => {
      const url = location.href;
      try {
        if (navigator.share) return await navigator.share({ title: f.name || document.title, url });
        await navigator.clipboard.writeText(url);
        tell("Link copied");
      } catch (e) {
        if (!e || e.name !== "AbortError") tell("Open this page in Safari to use AirDrop");
      }
    });
    if (window.galleryInvite) row("Invite", () => window.galleryInvite([f]));
    document.body.appendChild(menu);
    const r = at.getBoundingClientRect();
    menu.style.left = Math.max(8, Math.min(innerWidth - menu.offsetWidth - 8, r.left + r.width / 2 - menu.offsetWidth / 2)) + "px";
    menu.style.bottom = innerHeight - r.top + 8 + "px";
    menu.hidden = false;
    setTimeout(() => document.addEventListener("pointerdown", away, true));
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
    rm.querySelectorAll("button").forEach((b) => b.addEventListener("focus", () => swSet(row, true)));
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
    // Like, left of Hide Comments (ui/README §3.2); the Shared section's Activity shows it (notes item 15)
    const likes = Array.isArray(f.likes) ? f.likes : [];
    const iLike = likes.some(isMe);
    if (can) {
      const likeBtn = mkEl("button", "lnk tlike");
      likeBtn.type = "button";
      likeBtn.textContent = iLike ? "Liked" : "Like";
      likeBtn.setAttribute("aria-pressed", String(iLike));
      likeBtn.onclick = async () => {
        likeBtn.disabled = true;
        try {
          await send(f, { op: "like" });
          paintComment();
        } catch (e) {
          likeBtn.disabled = false;
          tell(e.message, true);
        }
      };
      actions.appendChild(likeBtn);
    }
    actions.appendChild(hideBtn);
    thread.appendChild(actions);
    if (likes.length) {
      const others = likes.filter((l) => !isMe(l)).map((l) => (l.by === G.owner && !l.vid ? ownerName : l.by));
      const lr = mkEl("p", "tliked");
      const b = mkEl("b");
      b.textContent = iLike ? "You" : others.shift();
      lr.append(b, (others.length ? ", " + others.join(", ") : "") + " liked this");
      thread.appendChild(lr);
    }

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
        const edb = mkBtn("cedb", "Edit comment", "Edit"); // left of Delete, revealed with it (notes 29)
        const acts = mkEl("div", "cacts");
        acts.append(edb, rm);
        p.classList.add("cmine");
        p.title = "Tap to edit";
        swipeToDelete(row, acts);
        edb.addEventListener("focus", () => swSet(row, true));
        edb.onclick = () => !ed.disabled && ed.onclick(); // only the words change: the comment keeps its time
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
          ed.disabled = rm.disabled = edb.disabled = true;
          try {
            await send(f, { op: "del", cid: c.id });
            paintComment();
          } catch (e) {
            ed.disabled = rm.disabled = edb.disabled = false;
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
    if (activePlayer && activePlayer.bar) activePlayer.bar.paint();
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
      ? MAIN_API + "/transcript?" + new URLSearchParams({ path: f.path })
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
    const base = G.main ? MAIN_API + "/transcript" : "/api/transcript";
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
    const ws = tokens(text);
    // over the words they replace, each where the same share of the characters falls (corrections.js layOver)
    const heard = (l.words || []).filter((w) => Number.isFinite(w.s) && Number.isFinite(w.e));
    if (heard.length && ws.length) {
      const hc = heard.map((w) => [...w.t].length + 1), totalH = hc.reduce((a, b) => a + b, 0);
      const totalL = ws.reduce((a, w) => a + [...w].length + 1, 0);
      const time = (x) => {
        let at = 0;
        for (let i = 0; i < heard.length; i++) {
          if (x <= at + hc[i]) return heard[i].s + ((x - at) / hc[i]) * (heard[i].e - heard[i].s);
          at += hc[i];
        }
        return heard[heard.length - 1].e;
      };
      const out = [];
      let x = 0;
      for (const t of ws) {
        const c = (([...t].length + 1) * totalH) / totalL;
        const s = Math.max(time(x), (out.length ? out[out.length - 1].s : -1) + 0.02);
        out.push({ t, s, e: Math.max(s + 0.05, time(x + c - 1)) });
        x += c;
      }
      return out;
    }
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
    st.style.pointerEvents = "auto";
    st.onclick = (ev) => {
      ev.stopPropagation();
      toolsSheet(f, host, el, msg.textContent || "Waiting for the transcript…");
    };
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

  // (and the stops of Chinese, Arabic and Ge'ez: ，。；：？！、 ، ؛ ؟ ። ፣ ፤ ፧)
  const endsClause = (w) => /[,.;:?!…，。；：？！、،؛؟።፣፤፧]$/.test(String(w).replace(/["'»”’)」』]+$/, ""));
  // (a Chinese or Thai word is short without leaning on the next)
  const leansOn = (w) => !endsClause(w) && !U_ANY.test(w) && (String(w).match(/\p{L}/gu) || []).length <= 3;
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
      return { t: w.t, s: w.s, e: w.k !== undefined ? w.e : Math.max(w.s + 0.05, Math.min(e, next)), h: w.h, syl: w.syl, un: w.un, k: w.k, tm: w.tm };
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

  // Learn's two places, one over the other, which the lines take in turn (karaoke's way, SPEC 59). The
  // light crosses the bottom line; when it has crossed it, that line stays and the next one fades in
  // slowly at the top, in the place of the line before last (once that one has been read); then the
  // light crosses the top line, and the next fades in at the bottom. A line always arrives a moment
  // before it is spoken. A silence clears both; paused, the screen never clears. (Recense's
  // learningPlaces in recense.swift is the same.)
  const learningPlaces = (lines, t, held) => {
    const n = lines.length;
    const lead = 0.5;
    const fadeOut = 0.15;
    const fadeIn = 0.4;
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
      return Math.max(Math.min(Math.max(lines[j - 1].e, freed), lines[j].s - lead), spoken); // once the light has crossed the line between
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
  const UPCOMING = [255, 255, 255, 0.35]; // the ghost: every word of a line on screen is preloaded at 35 % (item 20)
  const AHEAD = [255, 255, 255, 0.35];
  const mix = (a, b, f) => {
    f = Math.max(0, Math.min(1, f));
    return a.map((v, i) => v + (b[i] - v) * f);
  };
  const rgba = (c) => "rgba(" + Math.round(c[0]) + "," + Math.round(c[1]) + "," + Math.round(c[2]) + "," + c[3].toFixed(3) + ")";

  // ----- the voice under the light (notes 33) -----
  //
  // Recense measures each song's voice frame by frame on its vocal stem (keep/<key>/features.json: loudness, onset,
  // pitch, clarity, voiced, every 10 ms). The words are timed to it (cadence.js) and the ribbon under the line draws
  // it (prosogram.js); the light itself stays steady (item 20: shaped frame by frame, it flickered).
  let curVoice = null; // { f, shift, top, notes } for the item on stage, or null: the plain light

  // (resolves to the voice once it's here, else null: the transcript's words are then timed to it, cadence.js)
  const voiceLoad = (f, url) => {
    curVoice = null;
    if (!url) return Promise.resolve(null);
    return fetch(url + "&f=features", { headers: { "x-gallery": "1" } })
      .then((r) => (r.ok ? r.json() : null))
      .then((v) => {
        if (!v || !Array.isArray(v.db) || v.source !== "vocals" || v.db.length < 20 || items[cur] !== f) return null;
        const loud = v.db.filter((_, i) => v.voiced[i] === 1).sort((a, b) => a - b);
        curVoice = { f: v, shift: Number(v.shift) || 0, top: loud.length ? loud[Math.floor(loud.length * 0.95)] : v.floor + 20, notes: new Map(), item: f };
        return curVoice;
      })
      .catch(() => null);
  };


  // Styles are only written when they change: a page that rewrites them every frame keeps style-watching
  // extensions (Dark Reader, translators) recomputing the whole page, which froze Firefox.
  // How much of a word is lit at t. A sung word timed syllable by syllable (Cadence's melody: { c, s, e }, c where it
  // ends in the letters) sweeps through its letters without stopping: each syllable's letters are spread over the time
  // it's sung, up to where the next one comes in (or a quarter second past its end, so a breath isn't swept through),
  // so the light slows on a held "on" and hurries through a quick var-i-a. Else evenly.
  const fillOf = (b, t, sp) =>
    globalThis.Cadence ? globalThis.Cadence.fill(b, t, b.syl && b.syl.length ? Array.from(b.t || sp.textContent || "").length : 0) : t >= b.e ? 1 : Math.min(1, Math.max(0, (t - b.s) / Math.max(0.05, b.e - b.s)));


  const paintWord = (sp, b, t) => {
    const st = sp.style;
    // written but not sung (Cadence found no voice for it): never lit
    if (b.un) {
      const col = rgba(UPCOMING);
      if (sp._c !== col) st.color = sp._c = col;
      if (sp._bg) st.backgroundImage = st.textShadow = sp._bg = sp._sh = "";
      return;
    }
    // a made liaison's letters (prosogram-mount.js sets sp._lz): turquoise as the light reaches them, like the tie
    if (sp._lz && t >= b.s && sp._dir !== "rtl") {
      const f = fillOf(b, t, sp), lit = rgba(t >= b.e ? mix(GOLD, SPOKEN, (t - b.e) / 0.45) : GOLD), TQ = rgba(t >= b.e ? mix([64, 224, 208, 1], SPOKEN, (t - b.e) / 0.45) : [64, 224, 208, 1]);   // eases to white as the gold does
      const stops = [];
      let at = 0;
      for (const [u0, u1] of sp._lz) {
        const a = Math.min(u0, f) * 100, z = Math.min(u1, f) * 100;
        if (z <= a) continue;
        stops.push(lit + " " + at + "%", lit + " " + a + "%", TQ + " " + a + "%", TQ + " " + z + "%"); at = z;
      }
      stops.push(lit + " " + at + "%", lit + " " + (f * 100).toFixed(1) + "%", rgba(AHEAD) + " " + Math.min(100, f * 100 + (f < 1 ? 6 : 0)).toFixed(1) + "%");
      const bg = "linear-gradient(to right," + stops.join(",") + ")";
      if (sp._c !== "transparent") st.color = sp._c = "transparent";
      if (sp._bg !== bg) st.backgroundImage = sp._bg = bg;
      const sh = t >= b.e ? "" : "0 0 8px rgba(255,214,51,.45)";
      if (sp._sh !== sh) st.textShadow = sp._sh = sh;
      return;
    }
    if (t >= b.e || t < b.s) {
      const c = t >= b.e ? mix(GOLD, SPOKEN, (t - b.e) / 0.45) : UPCOMING;
      const col = rgba(c);
      if (sp._c !== col) st.color = sp._c = col;
      if (sp._bg) {
        st.backgroundImage = st.textShadow = sp._bg = sp._sh = "";
      }
      if (sp._y) st.top = sp._y = "";
      return;
    }
    // the light stays full gold for the whole word and wipes across all of it at the voice's speed, with a steady
    // soft edge and a steady glow: the frame-to-frame voice measures no longer change its opacity, edge or glow,
    // which made it flicker (item 20). The ribbon under the line carries the voice's stress and pitch instead.
    const f = fillOf(b, t, sp);
    const w = (f * 100).toFixed(1);
    const edge = Math.min(100, f * 100 + 6).toFixed(1);
    if (sp._c !== "transparent") st.color = sp._c = "transparent";
    const bg = "linear-gradient(" + (sp._dir === "rtl" ? "to left," : "to right,") + rgba(GOLD) + " " + w + "%," + rgba(AHEAD) + " " + edge + "%)";
    if (sp._bg !== bg) st.backgroundImage = sp._bg = bg;
    const sh = "0 0 8px rgba(255,214,51,.45)";
    if (sp._sh !== sh) st.textShadow = sp._sh = sh;
    // (the light no longer moves with the pitch or vibrato: the word stays put, the owner found it shaking)
  };

  const RTL_RE = /[֐-ࣿיִ-﷿ﹰ-﻿]/;
  // A line's direction by most of its letters (an Arabic line with a name in Latin letters reads right to left; an
  // English line with one Arabic word left to right); a word's by its own letters, none: the line's.
  const RTL_L = new RegExp(RTL_RE.source, "gu");
  const LTR_L = new RegExp("(?!" + RTL_RE.source + ")[\\p{L}\\p{N}]", "gu");
  const dirOf = (s, or = "ltr") => {
    const r = (String(s || "").match(RTL_L) || []).length, l = (String(s || "").match(LTR_L) || []).length;
    return r + l === 0 ? or : r >= l ? "rtl" : "ltr";
  };
  // a line's language for the page (lang=, which picks the font: Chinese and Japanese letters differ), by most of its words
  const langOf = (words) => {
    const n = {};
    for (const w of words || []) if (w.lang) n[w.lang] = (n[w.lang] || 0) + 1;
    return Object.keys(n).sort((a, b) => n[b] - n[a])[0] || "";
  };
  // Scripts written without spaces between words (Chinese, Japanese, Thai, Lao, Khmer, Burmese, Tibetan): their words
  // come cut, so nothing goes between them (a space only after a Tibetan shad), and a correction typed the way they're
  // written is cut into words again. corrections.js (unspaced, joinWords, tokens) is the same.
  const UNSPACED = "[\\u0E00-\\u0EFF\\u0F00-\\u0FFF\\u1000-\\u109F\\u1780-\\u17FF\\u2E80-\\u2FFF\\u3000-\\u30FF\\u3100-\\u312F\\u31A0-\\u31FF\\u3400-\\u4DBF\\u4E00-\\u9FFF\\uF900-\\uFAFF\\uFE30-\\uFE4F\\uFF00-\\uFFEF\\u{20000}-\\u{3134F}]";
  const U_ENDS = new RegExp(UNSPACED + "$", "u"), U_OPENS = new RegExp("^" + UNSPACED, "u"), U_ANY = new RegExp(UNSPACED, "u");
  const unspaced = (a, b) => U_ENDS.test(a) && U_OPENS.test(b) && !/[།-༑༔]$/u.test(a);
  const U_SEG = typeof Intl !== "undefined" && Intl.Segmenter ? new Intl.Segmenter(undefined, { granularity: "word" }) : null;
  const tokens = (s) =>
    String(s || "").trim().split(/\s+/).filter(Boolean).flatMap((t) => {
      if (!U_SEG || !U_ANY.test(t)) return [t];
      const out = [];
      for (const { segment, isWordLike } of U_SEG.segment(t)) {
        if (!isWordLike && out.length) out[out.length - 1] += segment; // a stop or a tsheg stays with the word before it
        else out.push(segment);
      }
      return out;
    });

  // [Ambient Sounds], as Recense shows it: while the media plays and no line is up
  const ambient = (host, el, gap, always, onTap) => {
    if (host.querySelector(".txamb")) return;
    const a = mkEl("div", "txamb");
    a.textContent = "[Ambient Sounds]";
    a.hidden = true;
    if (onTap) {
      a.style.pointerEvents = "auto";
      a.style.cursor = "pointer";
      a.onclick = (ev) => {
        ev.stopPropagation();
        onTap();
      };
    }
    host.appendChild(a);
    // [Ambient Sounds] only ever sits on black: the cover goes to the thumbnail strip (mode 2), as with lyrics
    if (host.classList.contains("aw")) host.classList.add("lyrics");
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
      } else if (t && t.complete) ambient(host, el, () => true, true, () => toolsSheet(f, host, el, "No words in this one: [Ambient Sounds]")); // heard through and no words: an instrumental, playing or paused
      // (an unfinished one with no lines yet claims nothing: its words may still come)
      return;
    }
    if (host.querySelector(".tx.learn")) return;

    let lines = t.lines;
    // The words timed to the singer's voice once it's measured (cadence.js: the rules Sill's light follows, so the
    // same word lights at the same moment in Sill, here and in the iOS app). Always from the server's lines.
    let voice = null;
    const timed = (ls) => {
      if (!globalThis.Cadence) return ls;
      try {
        return globalThis.Cadence.pin(voice ? globalThis.Cadence.fit(ls, voice.f, voice.shift) : ls);
      } catch (e) {
        return ls;
      }
    };
    lines = timed(lines); // (the listener's own timing, before the voice is here)
    const voiceWait = voiceLoad(f, txUrl(f));
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
    // The prosogram (prosogram-mount.js) draws on this same clock: the notation and the light are both on the time
    // being heard, at every speed, through Safari's deck and the output latency alike (item 22).
    // It reads the lines the captions show too (`version` changes whenever they do), so both draw the same times.
    const hook = { media: el, now: clock, lines: () => lines, version: 0 };
    globalThis.GalleryClock = hook;

    const box = mkEl("div", "tx learn");
    const places = [0, 1].map(() => {
      const p = mkEl("button", "txp");
      p.type = "button";
      p.hidden = true;
      box.appendChild(p);
      return { el: p, line: -1, cells: [] };
    });
    host.appendChild(box);
    box.onclick = (ev) => {
      ev.stopPropagation();
      openAll();
    };
    // Dense, complex tracks (a choir, few words heard surely): the words and the notation start Off, with Show for
    // this item, remembered (item 22; Cadence.confidence, the same rule as Sill's). The notation draws only under
    // visible caption cells, so hiding the box turns it off too.
    const SHOWN = "gallery.txShown";
    const itemId = txUrl(f) || String(f.path || f.name || "");
    const shown = () => {
      try {
        return new Set(JSON.parse(localStorage.getItem(SHOWN) || "[]"));
      } catch (e) {
        return new Set();
      }
    };
    let quiet = null;
    const gate = () => {
      if (!globalThis.Cadence || !box.isConnected) return;
      let off = false;
      try {
        // still being transcribed: words a minute over what's heard so far, not the whole track
        const d = t.complete === false ? 0 : el.duration;
        off = globalThis.Cadence.confidence(lines, voice && voice.f, d).off && !shown().has(itemId);
      } catch (e) {}
      box.classList.toggle("txoff", off);
      if (off && !quiet) {
        quiet = mkEl("div", "txq");
        quiet.appendChild(document.createTextNode("Captions off · dense texture"));
        const b = mkEl("button", "lnk");
        b.type = "button";
        b.textContent = "Show";
        b.onclick = (ev) => {
          ev.stopPropagation();
          const s = shown();
          s.add(itemId);
          try {
            localStorage.setItem(SHOWN, JSON.stringify([...s].slice(-500)));
          } catch (e) {}
          gate();
        };
        quiet.appendChild(b);
        quiet.onclick = (ev) => ev.stopPropagation();
        host.appendChild(quiet);
      } else if (!off && quiet) {
        quiet.remove();
        quiet = null;
      }
    };
    gate();
    // spec §2: audio with a transcript shows its lyrics on black (mode 2) instead of the cover (mode 1)
    if (host.classList.contains("aw")) host.classList.add("lyrics");

    const fits = new Map(); // (width, size, language, view) → the transcript's one font size

    // The transcript's one size: clamp(22px, 3vw, 30px) times Text Size, unless its longest line (original or
    // trailing language, whichever is wider) would need more than three rows at that size; then every line is
    // made smaller together, never below 60%. Measured once per width, size, language and view.
    // The lyrics live in a band between the top bar (its day and time) and the two bars (gallery.css .tx.learn), so in
    // landscape on a phone the size also comes down until the longest line fits its place in that band (SPEC 56).
    const measure = document.createElement("canvas").getContext("2d");
    const uniformSize = () => {
      const base = Math.max(22, Math.min(30, innerWidth * 0.03)) * prefs.txScale;
      const width = Math.max(120, box.clientWidth - 24);
      const band = box.clientHeight || innerHeight / 2;
      const stacked = prefs.view === "follow" || prefs.prominence != null; // the trailing line under the original
      const key = [width, band, base, nativeLang(), prefs.view, stacked, lines.length].join("/");
      if (fits.has(key)) return fits.get(key);
      measure.font = "600 " + base + "px -apple-system,BlinkMacSystemFont,'SF Pro Text',sans-serif";
      let wo = 0;
      let wt = 0;
      for (const l of lines) {
        wo = Math.max(wo, measure.measureText(l.text || "").width);
        const tr = trailOf(l);
        if (tr) wt = Math.max(wt, measure.measureText(tr).width * 0.95); // (the trailing language is set lighter)
      }
      const placeH = (prefs.view === "follow" ? band : (band - 6) / 2) - 12;
      const rows = (w, k) => (w ? Math.max(1, Math.ceil((w * k) / (width * 0.9))) : 0);
      let size = base;
      // the floor is the unscaled size's, so a Text Size too big for two lines to fit is held back: past that point
      // it magnifies no further, and nothing is clipped (notes 2026-10-26: text above 100%)
      const floor = Math.min(base, base / prefs.txScale) * 0.55;
      // larger text may wrap onto more rows, or it was shrunk straight back to the 100% size (notes 43)
      const cap = Math.max(3, Math.round(3 * prefs.txScale));
      for (; size > floor; size *= 0.95) {
        const k = size / base;
        const need = (stacked ? rows(wo, k) + rows(wt, k) : Math.max(rows(wo, k), rows(wt, k), 1)) * size * TX_LH;
        if (need <= placeH && (stacked ? rows(wo, k) <= cap : rows(Math.max(wo, wt), k) <= cap)) break;
      }
      fits.set(key, size);
      return size;
    };
    // turned or resized: the band changes, and with it the size
    const onResize = () => {
      if (!box.isConnected) return removeEventListener("resize", onResize);
      fits.clear();
      places.forEach((pl) => (pl.line = -1));
    };
    addEventListener("resize", onResize);

    // a line in its place: each phrase a cell holding its words and, stacked in the same slot, its English
    const build = (pl, j) => {
      const l = lines[j];
      const L = learnOf(l);
      pl.line = j;
      pl.lang = nativeLang();
      pl.cells = [];
      box.classList.toggle("follow", prefs.view === "follow");
      pl.el.replaceChildren();
      pl.el.onclick = (ev) => {
        ev.stopPropagation();
        el.currentTime = Math.max(0, l.s - 0.05);
        openAll(j);
      };

      const rtl = dirOf(l.text) === "rtl";
      pl.el.dir = rtl ? "rtl" : "ltr";
      pl.el.lang = langOf(l.words);
      pl.el.classList.toggle("txother", /[^\p{Script=Latin}\p{Script=Greek}\p{Script=Cyrillic}\P{L}]/u.test(l.text || ""));
      const parts = L.parts || L.beats.map((_, i) => ({ src: [i, i + 1], en: null }));
      // a line of Chinese, Thai or Tibetan reads with no gap between its phrases either
      pl.el.classList.toggle("txglued", parts.length > 1 && parts.every((p, k) => k === 0 || unspaced(L.beats[p.src[0] - 1].t, L.beats[p.src[0]].t)));

      for (const p of parts) {
        const cell = mkEl("span", "txc");
        const src = mkEl("span", "txs");
        const words = [];
        for (let i = p.src[0]; i < p.src[1]; i++) {
          const sp = mkEl("span", "txw");
          sp.textContent = L.beats[i].t;
          sp.dataset.s = String(L.beats[i].s); // its start: the prosogram matches the word by time, not by its text
          // written from what a correction taught Recense, where the recognizer heard something else: correct it back to unteach it
          if (L.beats[i].h) {
            sp.classList.add("txl");
            sp.title = "Learned from your corrections (heard \u201c" + L.beats[i].h + "\u201d)";
          }
          // a word in another direction than its line (a name in Latin letters in Arabic) is lit the way it reads; no dir=
          // on the word, which would make each word its own island and "New York" in an Arabic line read "York New"
          sp._dir = dirOf(L.beats[i].t, rtl ? "rtl" : "ltr");
          const lw = l.words[i];
          if (lw && lw.lang && lw.lang !== pl.el.lang) sp.lang = lw.lang;
          src.appendChild(sp);
          if (i + 1 < p.src[1] && !unspaced(L.beats[i].t, L.beats[i + 1].t)) src.appendChild(document.createTextNode(" "));
          words.push({ sp, b: L.beats[i] });
        }
        cell.appendChild(src);
        let en = null;
        const native = p.text != null ? p.text : p.en ? l.enw.slice(p.en[0], p.en[1]).map((w) => w.w).join(" ") : null;
        if (native != null) {
          en = mkEl("span", "txe");
          en.dir = dirOf(native);
          en.textContent = native;
          cell.appendChild(en);
        }
        pl.el.appendChild(cell);
        pl.cells.push({ cell, src, en, words, start: L.beats[p.src[0]].s, end: L.beats[p.src[1] - 1].e, w: 0, p: -1 });
      }

      // One size for every line and both languages, from the first line to the last (SPEC 59): never one line
      // bigger or smaller than another. The size is the transcript's (uniformSize: the reader's Text Size, made
      // smaller only as far as the longest line needs to fit where the lines are shown); a long line wraps.
      pl.sc = prefs.txScale;
      pl.view = prefs.view;
      pl.el.style.fontSize = uniformSize() + "px";
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
    // the line at t; for the editor (`ahead`), between lines the next when it comes within a second
    const lineAt = (t, ahead) => {
      let k = -1;
      lines.forEach((l, i) => l.s <= t + 0.05 && (k = i));
      if (ahead && k + 1 < lines.length && (k < 0 || lines[k].e < t) && lines[k + 1].s - t < 1) k++;
      return k;
    };
    // `at`: the line tapped, opened on as it is (the time heard runs a little behind the seek to it, which opened the
    // line before: an edit to the second "Variations on a dream" at 2:35 went to the first)
    const openAll = (at) => {
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
        // and sung as the voice sings them, at once: the light keeps the cadence over the corrected words
        if (voice && l.words.length) {
          const [fit] = timed([{ ...l, words: l.words }]);
          if (fit && fit.words) l.words = fit.words;
        }
        l.fixed = true;
        delete l._learn;
        fits.clear();
        queueEdit(f, { segId: l.id, field: "text", to: text, updatedAt: Date.now() }).onLines = onLines;
        if (!text) say("Line removed — Changes has it if you want it back");
      };
      const saveTr = (l, ta, lang) => {
        const text = ta.value.replace(/\s+/g, " ").trim();
        if (text === trailOf(l, lang)) return;
        l.tr = { ...(l.tr || {}), [lang]: text };
        delete l._learn;
        fits.clear();
        queueEdit(f, { segId: l.id, field: "tr." + lang, to: text, updatedAt: Date.now() }).onLines = onLines;
      };
      // Timing by ear (notes 20261029 row 35): the voice can't always tell how a word is sung, the listener can. Pick a
      // word, then set where its light starts and ends and how it sweeps (lingering on the start, even, or hurrying
      // through it first) while that stretch plays round; Auto gives it back to the voice's measure (cadence.js pin).
      const sec = (x) => Math.floor(x / 60) + ":" + (x % 60).toFixed(2).padStart(5, "0");
      let looping = null;
      const unloop = () => {
        if (looping) el.removeEventListener("timeupdate", looping);
        looping = null;
      };
      const timer = (l) => {
        const wrap = mkEl("div", "txtime");
        const chips = mkEl("div", "txchips");
        const panel = mkEl("div", "txpanel");
        panel.hidden = true;
        wrap.append(chips, panel);
        wrap.onclick = (e) => e.stopPropagation();
        const shift = Number(t.shift) || 0;
        const r3 = (x) => Math.round(x * 1000) / 1000;
        const savePins = () => {
          const pins = l.words.map((w, i) => (w.tm ? [i, r3(w.tm.s - shift), r3(w.tm.e - shift), Math.round(w.tm.k * 100) / 100 || 0] : null)).filter(Boolean);
          queueEdit(f, { segId: l.id, field: "time", to: pins.length ? JSON.stringify(pins) : "", updatedAt: Date.now() }).onLines = onLines;
        };
        const relight = () => {
          l.words = globalThis.Cadence ? globalThis.Cadence.pin([l])[0].words : l.words;
          delete l._learn;
          fits.clear();
          places.forEach((pl) => (pl.line = -1));
        };
        const open = (i, chip) => {
          chips.querySelectorAll(".on").forEach((c) => c.classList.remove("on"));
          chip.classList.add("on");
          const w = l.words[i];
          const s0 = w.s, e0 = Math.max(w.e, w.s + 0.05);
          const tm = w.tm ? { ...w.tm } : { s: s0, e: e0, k: 0 };
          panel.hidden = false;
          panel.replaceChildren();
          const slide = (label, min, max, step, val, show, set) => {
            const r = mkEl("label", "txslide");
            const name = mkEl("span", "txsname");
            name.textContent = label;
            const inp = document.createElement("input");
            inp.type = "range";
            inp.min = min;
            inp.max = max;
            inp.step = step;
            inp.value = val;
            const out = mkEl("span", "txsval");
            out.textContent = show(val);
            inp.oninput = () => {
              set(Number(inp.value));
              out.textContent = show(Number(inp.value));
              w.tm = { ...tm };
              chip.classList.add("set");
              relight();
            };
            inp.onchange = savePins;
            r.append(name, inp, out);
            panel.appendChild(r);
            return inp;
          };
          const startIn = slide("Starts", r3(s0 - 1.5), r3(s0 + 1.5), 0.01, tm.s, sec, (v) => {
            tm.s = Math.min(v, tm.e - 0.05);
          });
          slide("Ends", r3(e0 - 1.5), r3(e0 + 3), 0.01, tm.e, sec, (v) => {
            tm.e = Math.max(v, tm.s + 0.05);
          });
          slide("Sweep", -1, 1, 0.05, tm.k, (v) => (v < -0.05 ? "lingers first" : v > 0.05 ? "hurries first" : "even"), (v) => {
            tm.k = v;
          });
          const btns = mkEl("div", "txsbtns");
          const hear = mkEl("button", "lnk txbtn");
          hear.type = "button";
          hear.textContent = looping ? "Stop" : "Hear it";
          hear.onclick = () => {
            if (looping) {
              unloop();
              el.pause();
              hear.textContent = "Hear it";
              return;
            }
            looping = () => {
              const x = w.tm || tm;
              if (el.currentTime > x.e + 0.5 || el.currentTime < x.s - 1.5) el.currentTime = Math.max(0, x.s - 0.8);
            };
            el.addEventListener("timeupdate", looping);
            el.currentTime = Math.max(0, tm.s - 0.8);
            el.play().catch(() => {});
            hear.textContent = "Stop";
          };
          const auto = mkEl("button", "lnk txbtn");
          auto.type = "button";
          auto.textContent = "Auto";
          auto.onclick = () => {
            delete w.tm;
            delete w.k;
            chip.classList.remove("set");
            savePins();
            panel.hidden = true;
            chip.classList.remove("on");
          };
          btns.append(hear, auto);
          panel.appendChild(btns);
          startIn.focus({ preventScroll: true });
        };
        l.words.forEach((w, i) => {
          if (w.un && !w.tm) return;
          const c = mkEl("button", "txchip" + (w.tm ? " set" : ""));
          c.type = "button";
          c.textContent = w.t;
          c.onpointerdown = (e) => e.preventDefault();
          c.onclick = () => open(i, c);
          chips.appendChild(c);
        });
        return wrap;
      };
      const row = (l, i) => {
        const r = mkEl("div", "txrow" + (i === cur ? " cur" : ""));
        const time = mkEl("span", "txt");
        time.textContent = mmss(l.s);
        r.appendChild(time);
        const lang = nativeLang();
        const tr = trailOf(l, lang);
        const body = mkEl("div", "txbody");
        r.appendChild(body);
        // the trailing side (P3 4): the same line in the chosen language, its own field under the original's
        const trField = () => {
          const tb = mkEl("textarea", "txin txtr");
          tb.value = tr;
          tb.dir = "auto";
          tb.rows = 1;
          tb.maxLength = 2000;
          tb.placeholder = langName(lang);
          tb.setAttribute("aria-label", "Correct this line in " + langName(lang));
          tb.onfocus = () => el.pause();
          tb.onkeydown = (e) => {
            if (e.key === "Enter" && !e.shiftKey) {
              e.preventDefault();
              tb.blur();
            } else if (e.key === "Escape") {
              e.preventDefault();
              e.stopPropagation();
              tb.value = tr;
              tb.blur();
            }
          };
          tb.onblur = () => saveTr(l, tb, lang);
          tb.onclick = (e) => e.stopPropagation();
          return tb;
        };
        if (i === cur && w) {
          const ta = mkEl("textarea", "txin");
          ta.value = l.text;
          ta.dir = "auto"; // typed in Arabic, it runs right to left
          ta.lang = langOf(l.words);
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
          body.append(ta, trField());
          if (l.words.length) body.appendChild(timer(l));
        } else {
          const b = mkEl("button", "txline");
          b.type = "button";
          b.textContent = l.text;
          b.dir = dirOf(l.text);
          b.lang = langOf(l.words);
          b.onclick = (e) => {
            e.stopPropagation();
            el.currentTime = Math.max(0, l.s - 0.05);
            el.play().catch(() => {});
            follow(i);
          };
          body.appendChild(b);
          if (tr && tr !== (l.text || "").trim()) {
            const t = mkEl("div", "txtrl");
            t.textContent = tr;
            t.dir = dirOf(tr);
            body.appendChild(t);
          }
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
      // Retranscribe: a new transcript and its translations, the chosen language first (SPEC 9, 57)
      const redo = async () => {
        close();
        const r = await txSend(w.run, "POST", { retranscribe: true, lang: prefs.nativeLang });
        if (r && r.ok) {
          say("Retranscribing and retranslating; your corrections stay");
          f.tx = null;
          box.remove();
          awaitTranscript(f, el, host, { run: await r.json().catch(() => ({ state: "queued" })) });
        } else say("Couldn’t ask for a new transcript", true);
      };
      // Clear: every line goes; the cover (or [Ambient Sounds]) comes back
      const wipe = async () => {
        if (!(await clearTranscript(f, lines))) return;
        close();
        f.tx = null;
        box.remove();
        host.querySelectorAll(".txamb").forEach((x) => x.remove()); // its label went with the lines
        host.classList.remove("lyrics");
        showTranscript(f);
      };
      const tools = editorToolsFor(f, {
        lines: () => lines,
        relang: () => {
          fits.clear();
          if (backBtn.hidden) render();
        },
        clear: wipe,
        redo,
      });
      bar.prepend(tools.el);
      const close = () => {
        if (!sheet.isConnected) return;
        if (field && document.activeElement === field) field.blur();
        unloop();
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
      let heardAt = lineAt(clock(), true);
      cur = Number.isInteger(at) && lines[at] ? at : heardAt;
      render();
      if (rows[cur]) rows[cur].scrollIntoView({ block: "center" });
      // the field follows what is heard once that moves on, unless you are typing in it
      const tick = () => {
        if (!sheet.isConnected) return;
        if (backBtn.hidden && !(field && document.activeElement === field)) {
          const i = lineAt(clock(), true);
          if (i !== heardAt) {
            heardAt = i;
            if (i !== cur) follow(i, !el.paused);
          }
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
      lines = timed(fresh);
      hook.version++;
      places.forEach((pl) => (pl.line = -1));
      fits.clear();
      if (reRender) reRender();
      gate();
    };
    const q = txQueues.get(f);
    if (q) q.onLines = onLines;
    // the voice measured: the same lines, timed to it
    voiceWait.then((V) => {
      if (!V || voice || !box.isConnected) return;
      voice = V;
      onLines(lines);
    });

    // Follow (chosen in the editor): the line being heard in the first place, its trailing language under it,
    // until the next one begins (or a moment after it ends, before a silence); paused, it stays.
    const followPlaces = (t) => {
      const k = lineAt(t);
      if (k < 0) return [];
      const l = lines[k];
      const next = lines[k + 1];
      if (t > l.e + 2.5 && (!next || next.s - t > 0.6) && !(el.paused && t <= l.e + 6)) return [];
      return [{ line: k, place: 0, alpha: 1 }];
    };

    let gapNow = false;
    ambient(host, el, () => gapNow, false, () => openAll()); // between lines too, a tap is the editor
    const paint = () => {
      if (!box.isConnected) {
        if (globalThis.GalleryClock === hook) globalThis.GalleryClock = null;
        if (quiet) quiet.remove();
        return;
      }
      if (editing) return requestAnimationFrame(paint);

      const now = clock();
      const follow = prefs.view === "follow";
      const shown = follow ? followPlaces(now) : learningPlaces(lines, now, el.paused);
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
        if (pl.line !== s.line || pl.lang !== nativeLang() || pl.sc !== prefs.txScale || pl.view !== prefs.view) build(pl, s.line);
        pl.el.style.opacity = s.alpha.toFixed(3);

        const rtl = pl.el.dir === "rtl";
        const h = parseFloat(pl.el.style.fontSize) * TX_LH;
        // Prominence under 50%: the light follows the selected language, wiping across its phrase while the
        // original is pronounced; 50% to 90%: the original's words, as at rest; past 90% nothing is shown.
        const trailLit = prefs.prominence != null && prefs.prominence < 0.5;
        for (const c of pl.cells) {
          if (follow && !trailLit) {
            c.words.forEach((w) => paintWord(w.sp, w.b, now)); // Follow: the light on the original; its translation stays under it
            continue;
          }
          const raw = c.en ? Math.max(0, Math.min(1, (now - c.end) / TURN)) : 0;
          if (trailLit && c.en) {
            paintWord(c.en, { s: c.start, e: c.end }, now);
            c.words.forEach((w) => paintWord(w.sp, { s: w.b.s, e: w.b.s }, now)); // no wipe on the original
          } else if (raw < 1) {
            c.words.forEach((w) => paintWord(w.sp, w.b, now));
            if (c.en && c.en._c) (c.en.style.color = c.en.style.backgroundImage = c.en.style.textShadow = ""), (c.en._c = c.en._bg = c.en._sh = undefined);
          } else {
            // turned: its words are settled, never left mid-fade (a last word stuck faded yellow, item 20)
            c.words.forEach((w) => paintWord(w.sp, w.b, Math.max(now, w.b.e + 1)));
          }
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
    if (ownsLink()) rebuildGrid(); // the tiles take their drag handles and Pin as Cover
  };

  // ----- a share link's order and its preview card's cover (notes item 4) -----
  //
  // The owner drags tiles into order; the first picture is then the card iMessage shows, unless a
  // tile's pin chose another. Pinning copies the link with ?v=<stamp>: iMessage keys its cached
  // card by the address, so a new address shows the new cover.

  const ownsLink = () => owner && !G.main && !G.invite && !G.readOnly && !!G.id;
  const linkUrl = (v) => location.origin + "/s/" + G.id + (v ? "?v=" + v : "");

  const arrange = async (body) => {
    const r = await fetch(MAIN_API + "/link?" + new URLSearchParams({ action: "arrange", id: G.id }), {
      method: "POST",
      headers: { "content-type": "application/json", "x-gallery": "1" },
      body: JSON.stringify(body),
    });
    if (!r.ok) throw new Error((await r.text()) || "Couldn’t save");
    return r.json();
  };

  const pinCover = (f) => {
    const off = G.coverItem === f.n;
    const v = Date.now();
    const url = linkUrl(v);
    // copied inside the tap (Safari allows the clipboard only there), then saved
    if (navigator.clipboard) navigator.clipboard.writeText(url).catch(() => {});
    G.coverItem = off ? null : f.n;
    G.coverAt = v;
    grid.querySelectorAll(".tile").forEach((b) => b.classList.toggle("cover", b.dataset.n === G.coverItem));
    arrange({ cover: G.coverItem, v })
      .then(() => (window.galleryToast || say)(off ? "Cover unpinned · link copied" : "Pinned as cover · link copied"))
      .catch((e) => say(e.message || String(e), true));
  };

  let dragN = null;

  const arrangeTile = (b, f) => {
    b.classList.toggle("cover", G.coverItem === f.n);
    if (f.pending) return;

    const pin = mkEl("span", "pin");
    pin.setAttribute("role", "button");
    pin.setAttribute("aria-label", "Pin as Cover");
    pin.title = "Pin as Cover";
    pin.innerHTML = SVG('<path d="M12 17v5"/><path d="M9 10.8V4h6v6.8l2.5 3.2h-11z"/>');
    pin.onclick = (e) => {
      e.stopPropagation();
      pinCover(f);
    };
    b.appendChild(pin);

    b.draggable = true;
    b.addEventListener("dragstart", (e) => {
      if (selecting) return e.preventDefault();
      dragN = f.n;
      e.dataTransfer.effectAllowed = "move";
      e.dataTransfer.setData("text/plain", f.n);
      b.classList.add("lift");
    });
    b.addEventListener("dragend", () => {
      dragN = null;
      b.classList.remove("lift");
    });
    b.addEventListener("dragover", (e) => {
      if (dragN === null || dragN === f.n) return;
      e.preventDefault();
      const from = items.findIndex((x) => x.n === dragN);
      const to = items.indexOf(f);
      const moving = tileOf(items[from]);
      items.splice(to, 0, items.splice(from, 1)[0]);
      if (moving) grid.insertBefore(moving, from < to ? b.nextSibling : b);
    });
    b.addEventListener("drop", (e) => {
      if (dragN === null) return;
      e.preventDefault();
      e.stopPropagation();
      G.order = items.map((x) => x.n);
      if (thumbs) {
        thumbs = null;
        strip.replaceChildren();
      }
      arrange({ order: G.order }).catch((x) => say(x.message || String(x), true));
    });
  };

  // a read-only library (the archive) never gets the owner's controls
  if (G.main && !G.readOnly) showOwner();
  else if (!G.readOnly)
    fetch(MAIN_API + "/whoami", { redirect: "manual", cache: "no-store" })
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
          const r = await fetch(MAIN_API + "/file?" + new URLSearchParams({ key: f.path }), { method: "DELETE" });
          if (!r.ok) throw new Error((await r.text()) || "Delete failed");
          done++;
        }
      } else {
        const q = new URLSearchParams({ id: G.id });
        list.forEach((f) => q.append("item", f.path || f.n));
        const r = await fetch(MAIN_API + "/link?" + q, { method: "DELETE" });
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

  upin.onchange = () => {
    const files = Array.from(upin.files || []);
    upin.value = "";
    addFiles(files);
  };

  // Files dropped anywhere on the page, no drop box (notes item 14): the owner on Main, or an
  // invited person allowed to upload. Not while the viewer is open.
  const canDrop = () =>
    !G.readOnly && lb.hidden && ((G.main && owner) || !!(G.invite && G.invite.perms && G.invite.perms.upload));
  const hasFiles = (e) => !!e.dataTransfer && Array.from(e.dataTransfer.types || []).includes("Files");

  document.addEventListener("dragover", (e) => {
    if (!hasFiles(e)) return;
    e.preventDefault(); // a file dropped where we don't take it must not open in the tab either
    e.dataTransfer.dropEffect = canDrop() ? "copy" : "none";
  });
  document.addEventListener("drop", (e) => {
    if (!hasFiles(e)) return;
    e.preventDefault();
    if (canDrop()) addFiles(Array.from(e.dataTransfer.files || []));
  });

  let upSeq = 0;

  // one PUT with progress (fetch has none for uploads)
  const putFile = (to, file, onp) =>
    new Promise((ok, bad) => {
      const x = new XMLHttpRequest();
      x.open("PUT", to);
      x.setRequestHeader("content-type", file.type || "application/octet-stream");
      x.setRequestHeader("x-gallery", "1");
      x.upload.onprogress = (e) => e.lengthComputable && onp(e.loaded / e.total);
      x.onload = () => (x.status >= 200 && x.status < 300 ? ok() : bad(new Error(x.responseText || "Upload failed")));
      x.onerror = () => bad(new Error("Upload failed"));
      x.send(file);
    });

  // Each file shows as a tile in the grid at once and fills its ring as it goes, as on a share
  // link; no message when it's done, and a failed one keeps its red ring.
  const addFiles = async (files) => {
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

    say("");

    // a replaced file's old tile goes; the new one comes in uploading
    clash.forEach((f) => {
      const i = items.findIndex((x) => x.path === keyOf(f));
      if (i >= 0) items.splice(i, 1);
    });

    const jobs = files.map((file) => ({
      file,
      it: { n: "up" + ++upSeq + "-" + Date.now(), name: file.name, type: file.type || "", pending: true, progress: 0 },
    }));
    jobs.forEach((j) => items.push(j.it));
    rebuildGrid();
    refreshInfo();

    let failed = 0;

    for (const { file, it } of jobs) {
      const mtime = String(file.lastModified || Date.now());
      // an invited person adds new files only, into their one folder (the server picks the folder)
      const to = G.invite
        ? API + "/file?" + new URLSearchParams({ name: file.name, mtime })
        : MAIN_API + "/file?" + new URLSearchParams({ key: keyOf(file), mtime });

      try {
        await putFile(to, file, (p) => {
          it.progress = p;
          const b = tileOf(it);
          if (b) paintPending(b, it);
        });
      } catch (e) {
        failed++;
        it.failed = true;
        const b = tileOf(it);
        if (b) paintPending(b, it);
        refreshInfo();
        continue;
      }

      if (G.invite) continue; // its address comes from the share; the page is reloaded below

      const path = keyOf(file);
      becameReady(it, {
        name: file.name.replace(/\.[^/.]+$/, (x) => x.toUpperCase()),
        path,
        type: file.type || "application/octet-stream",
        size: file.size,
        taken: Number(mtime),
        src: MAIN_API.replace(/\/api$/, "/f/") + path.split("/").map(encodeURIComponent).join("/"),
      });
      refreshInfo();

      // the owner's audio: find its original key now, for the Key slider's labels (best effort)
      if (kind({ type: file.type || "", name: file.name }) === "aud" && file.size <= DETECT_BYTES) {
        detectKey(file)
          .then((k) => k && saveKey(path, k, "auto"))
          .catch(() => {});
      }
    }

    if (G.invite && !failed) location.reload();
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
    const r = await fetch(MAIN_API + "/key", {
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



  // ----- downloads with the sound baked in -----
  //
  // With Key, EQ or Space on, downloading an audio file gives it as you hear it: EQ, then Key,
  // then Space, the same stages and settings as the player, worked out here a stretch at a time
  // (so a long recording never has to be held whole) into a WAV at the file's own sample rate
  // and length. EQ and Key run straight in this page, carrying on from one stretch to the next
  // (Key with the player's own phase vocoder); Space is rendered by the browser, each stretch
  // given the sound before it so the room's tail carries over. Speed is baked in too (SPEC P3 12):
  // away from 1x the player's deck reads the file at that pace and its phase vocoder keeps the
  // key (and moves it by Key), exactly as Safari's player does, so the file comes out shorter or
  // longer by the speed. Video always downloads as it is.
  const OAC = window.OfflineAudioContext || window.webkitOfflineAudioContext;
  const procs = {}; // by sample rate: the deck reads the worklet's sampleRate

  // the player's Key processor ("pdc-key") or deck ("pdc-deck"), run here instead of in an AudioWorklet
  const pageKey = async (sr, which = "pdc-key") => {
    if (!procs[sr]) {
      const code = await (await fetch("/player/key.js?v=" + G.version)).text();
      const got = {};

      class Shim {
        constructor() {
          this.port = { postMessage() {}, onmessage: null };
        }
      }

      new Function("AudioWorkletProcessor", "registerProcessor", "sampleRate", code)(Shim, (name, c) => (got[name] = c), sr);
      procs[sr] = got;
      if (globalThis.PDC_DELAY) Object.assign(DELAY, globalThis.PDC_DELAY);
    }

    return procs[sr][which];
  };

  const bakeName = (f, set) => {
    const bits = [];

    if (set.vox) bits.push(set.vox < 0 ? "No vocals" : "Vocals only");
    if (set.key) bits.push("Key " + (set.key > 0 ? "+" : "−") + Math.abs(set.key));
    if (set.eq.low || set.eq.mid || set.eq.high) bits.push("EQ");
    if (set.mix) bits.push((set.mix < 0 ? "Reversed " : "") + ROOMS[set.room].label + " " + Math.round(Math.abs(set.mix) * 100) + "%");
    if (set.speed && set.speed !== 1) bits.push(set.speed + "×");

    return f.name.replace(/\.[^.]+$/, "") + " (" + bits.join(", ") + ").wav";
  };

  const bake = async (f, set, progress) => {
    // decoded at the file's own rate (a compressed file's rate read from its header), not the context's:
    // decodeAudioData resamples to the context it is given
    const s = await openSound(src(f), null);
    if (!s) return null;

    const sr = s.sr;
    const speed = set.speed > 0 ? set.speed : 1;
    const total = speed === 1 ? s.total : Math.ceil(s.total / speed); // frames out
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

    // Key: its output runs LAT frames behind (a whole frame, measured), so the first LAT are skipped
    // and LAT of silence pushed through at the end
    await pageKey(sr); // (loads DELAY too)
    const LAT = DELAY.key;
    let kp = null;
    let skip = 0;

    if (set.key && speed === 1) {
      const K = await pageKey(sr);
      kp = new K({ processorOptions: { ratio: Math.pow(2, set.key / 12), on: true } });
      skip = LAT;
    }

    // the extractor, as the player has it (after the EQ, before Key): VLAT behind, skipped the same way
    const VLAT = DELAY.vox;
    let vp = null;
    let vskip = 0;

    if (set.vox) {
      const V = await pageKey(sr, "pdc-vox");
      vp = new V({ processorOptions: { amount: set.vox } });
      vskip = VLAT;
    }

    const vox = (L, R) => {
      if (!vp) return [L, R];

      const oL = new Float32Array(L.length);
      const oR = new Float32Array(L.length);

      for (let i = 0; i < L.length; i += 128) {
        const e = Math.min(L.length, i + 128);
        vp.process([[L.subarray(i, e), R.subarray(i, e)]], [[oL.subarray(i, e), oR.subarray(i, e)]]);
      }

      const k = Math.min(vskip, oL.length);
      vskip -= k;
      return [oL.subarray(k), oR.subarray(k)];
    };

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

    // the dither's noise from a seeded generator, so the same settings make the same file
    let seed = 0x9e3779b9;
    const rnd = () => {
      seed ^= seed << 13;
      seed ^= seed >>> 17;
      seed ^= seed << 5;
      return (seed >>> 0) / 4294967296;
    };

    // the last stage, as the player's (see safeCurve()): untouched up to KNEE, then bent smoothly to
    // stay under 0.99, so an EQ boost's overshoot or a big room never hard-clips. Counted, and said.
    let bent = 0;
    const safe = (x) => {
      const a = Math.abs(x);
      if (a <= SAFE_KNEE) return x;
      bent++;
      return Math.sign(x) * safeBend(a);
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
      const tpdf = bytes === 2; // hi-fi (SPEC 58): 16-bit gets TPDF dither, so quiet tails fade into noise, not distortion

      for (let i = 0; i < 2 * n; i++) {
        const x = safe((i & 1 ? R : L)[i >> 1]);
        const d = tpdf ? rnd() - rnd() : 0;
        const v = x * full + d;
        const q = Math.round(v > full ? full : v < -full - 1 ? -full - 1 : v);

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

    // Speed (and Key with it): the deck pulls the file through at that pace, each chunk EQ'd as it
    // is fed in. Its output runs LAT frames behind, so the first LAT are skipped and it runs on
    // until the whole stretched length is out.
    if (speed !== 1) {
      const D = await pageKey(sr, "pdc-deck");
      const dk = new D({ processorOptions: { chunk: CHUNK, total: s.total, sr } });
      const msg = (m) => dk.port.onmessage({ data: m });
      const last = Math.ceil(s.total / CHUNK) - 1;
      let fed = -1;
      let lead = DELAY.deck;

      msg({ speed, key: set.key || 0, play: true });
      // in the vocoder from the first frame (the player crossfades into it; a file just starts there)
      Object.assign(dk, { g: 1, pv: true, w: 1, warm: 0 });

      while (written < total) {
        const need = Math.min(last, Math.floor((dk.pos + (SEG + 8) * speed) / CHUNK));

        while (fed < need) {
          const d = await s.get(++fed);
          const L = d[0];
          const R = d[1] || d[0].slice();

          eq(L, 0);
          eq(R, 1);
          msg({ chunk: fed, data: [L, R] });
        }

        const lo = Math.floor(dk.pos / CHUNK) - 1;
        msg({ drop: [...dk.chunks.keys()].filter((i) => i < lo) });

        const oL = new Float32Array(SEG);
        const oR = new Float32Array(SEG);
        dk.process([], [[oL, oR]]);

        const k = Math.min(lead, SEG);
        lead -= k;

        const [vL, vR] = vox(oL.subarray(k), oR.subarray(k));
        const [sL, sR] = await space(vL, vR);
        write(sL, sR);
        progress(Math.min(1, written / total));
        await new Promise((ok) => setTimeout(ok, 0));
      }
    }

    for (let a = 0; speed === 1 && a < total; a += SEG) {
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

      const [xL, xR] = vox(L, R);
      const [kL, kR] = key(xL, xR);
      const [sL, sR] = await space(kL, kR);

      write(sL, sR);
      progress(end / total);
      await new Promise((ok) => setTimeout(ok, 0)); // let the page breathe between stretches
    }

    // what is still in the worklets: silence pushed through until the whole length is out
    if (vp || kp) {
      const z = (vp ? VLAT : 0) + (kp ? LAT : 0) + 128;
      const [xL, xR] = vox(new Float32Array(z), new Float32Array(z));
      const [kL, kR] = key(xL, xR);
      const [sL, sR] = await space(kL, kR);
      write(sL, sR);
    }

    if (bent) console.info("[bake] the safety stage bent " + bent + " samples (" + ((100 * bent) / Math.max(1, 2 * written)).toFixed(3) + "%) that would have clipped");

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

  const bakeDownload = async (f, from) => {
    const set = { key: prefs.key, vox: prefs.vox || 0, eq: Object.assign({}, prefs.eq), mix: spaceOn() ? prefs.space.mix / 100 : 0, room: prefs.space.room, speed: prefs.speed };
    const id = f.n + JSON.stringify(set);
    const btn = from || meta.querySelector(".mdl") || mkEl("button"); // the bar's Download, or Info's (spec §5)

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
  const download = (from) => {
    const f = items[cur];
    if (!f || f.pending) return;

    if (kind(f) === "aud" && (soundOn() || prefs.speed !== 1) && OAC) {
      bakeDownload(f, from);
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

    meta.hidden = !meta.hidden;
  };

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
    prefs.notationLast = false; // the chords follow the language again until a notation is picked (SPEC 40)
    if (activePlayer && activePlayer.repaintKey) activePlayer.repaintKey();
    if (activePlayer && activePlayer.paintChord) activePlayer.paintChord();
    // Learn mode picks the new language up on its next frame (its paint loop watches prefs.nativeLang)
  };

  // The home bar's slides (homebar.js), in the order a swipe reaches them: Text size; Rename · Change
  // Cover · Delete Cover (the owner, on Main); and Loop · A · B, Speed and Play · ±15s, which Recense
  // has too. Language, Download, Retranscribe, Transpose, Share and the exports live in the transcript
  // editor (SPEC 57); the comments stay below the thumbnail strip (SPEC 41). Each slide is rebuilt as the
  // bar unfolds, so it always fits the item on screen.
  const barSlides = (f) => {
    const I = Homebar.ICONS;
    const out = ["size"];
    const owner = G.main && f && !f.pending;

    if (owner) {
      out.push({
        id: "item",
        label: "Rename and cover art",
        items: [
          { label: "Rename", text: "Rename", icon: I.rename, cls: "p-stack", act: () => renameItem(f) },
          kind(f) === "aud" ? { label: "Change cover art", text: "Change Cover", icon: I.cover, cls: "p-stack", act: () => pickCover(f) } : null,
          kind(f) === "aud" ? { label: "Delete cover art", text: "Delete Cover", icon: I.nocover, cls: "p-stack", act: () => deleteCover(f) } : null,
        ],
      });
    }

    // a share link's preview card: this item is its cover, or not (notes item 4)
    if (ownsLink() && f && !f.pending && (kind(f) !== "doc")) {
      out.push({
        id: "linkcover",
        label: "Link preview cover",
        items: [
          null,
          { label: "Use as the link preview’s cover", text: "Link Cover", icon: I.cover, cls: "p-stack", on: () => G.coverItem === f.n, act: () => pinCover(f) },
          null,
        ],
      });
    }

    return out.concat(["loop", "speed"]); // no Play ±15 trio (notes 2026-10-26): a tap on the picture plays and pauses
  };

  // ---------- the transcript editor's own (SPEC 57) ----------

  const fileTitle = (f) => String(f.name || f.path || "Transcript").replace(/\.[^/.]+$/, "");
  const langName = (code) => (NATIVE_LANGS.find((x) => x[0] === code) || [code, code])[1];
  const trailOf = (l, lang = nativeLang()) => {
    const tr = l.tr || {};
    const ok = (x) => typeof x === "string" && x.trim() && x.trim() !== "…";
    if (ok(tr[lang])) return tr[lang].trim();
    if (lang === "en") return [tr.en, l.en].find(ok) || "";
    return "";
  };
  const saveFile = (name, text, type) => {
    const a = document.createElement("a");
    a.href = URL.createObjectURL(new Blob([text], { type }));
    a.download = name;
    document.body.appendChild(a);
    a.click();
    a.remove();
    setTimeout(() => URL.revokeObjectURL(a.href), 30000);
  };
  const clockOf = (x) => {
    x = Math.max(0, Math.floor(x));
    const h = Math.floor(x / 3600);
    const m = Math.floor((x % 3600) / 60);
    const s = String(x % 60).padStart(2, "0");
    return h ? h + ":" + String(m).padStart(2, "0") + ":" + s : m + ":" + s;
  };

  // Export as MD: the same note Recense writes (front matter, then each line at its time with the trailing
  // language under it as a quote), in the language chosen in the editor.
  const exportMd = (f, lines) => {
    const lang = nativeLang();
    const title = fileTitle(f);
    const shown = lines.filter((l) => (l.text || "").trim());
    if (!shown.length) return tell("Nothing to export yet");
    const d = shown[shown.length - 1].e || 0;
    let md = "---\ntitle: \"" + title.replace(/"/g, "'") + "\"\nsource: \"" + location.origin + "/main?open=" + encodeURIComponent(f.path || f.name) + "\"\n";
    md += "duration: " + clockOf(d) + "\nlanguage: " + lang + "\nexported: " + new Date().toISOString() + "\n---\n\n# " + title + "\n\n";
    for (const l of shown) {
      md += "**" + clockOf(l.s) + "** " + l.text.trim() + "\n";
      const tr = trailOf(l, lang);
      if (tr && tr !== l.text.trim()) md += "> " + tr + "\n";
      md += "\n";
    }
    saveFile(title + ".md", md, "text/markdown");
    tell("Exported " + title + ".md");
  };

  // Export as M4B: one audiobook file is the endpoint. Building it (AAC, chapters, the transcript inside)
  // needs Recense's ffmpeg, so on the Mac the request goes to Recense (127.0.0.1:47123/export), which
  // fetches this file from the bucket and saves the .m4b; anywhere else it says so.
  const exportM4b = async (f) => {
    tell("Asking Recense for the audiobook…");
    try {
      const r = await fetch("http://127.0.0.1:47123/export", {
        method: "POST",
        headers: { "content-type": "text/plain" }, // (a simple request: no preflight to a server that has none)
        body: JSON.stringify({ as: "m4b", gallery: "files/" + f.path, title: fileTitle(f), lang: nativeLang() }),
        signal: AbortSignal.timeout(4000),
      });
      const j = r.ok ? await r.json().catch(() => ({})) : {};
      if (j.handled) return tell("Recense is making " + fileTitle(f) + ".m4b");
      tell(j.reason || "Recense couldn’t export this one");
    } catch (e) {
      tell("Export as M4B runs in Recense on the Mac");
    }
  };

  // The editor's tools for item f (SPEC 57), the same in the full editor and in the tools-only sheet. hooks:
  // lines() (Export as MD; none: no transcript yet), relang() after a language change, clear(), redo().
  const editorToolsFor = (f, hooks) => {
    const I = Homebar.ICONS;
    const w = txWrite(f);
    const own = G.main && !f.pending;
    return Homebar.tools({
      lang: {
        get: () => prefs.nativeLang,
        set: (v) => {
          setNativeLang(v);
          if (hooks.relang) hooks.relang();
        },
      },
      view: { get: () => prefs.view, set: (v) => setView(v) },
      items: [
        w && hooks.clear ? { id: "clear", label: "Clear the whole transcript", icon: I.clear, act: hooks.clear } : null,
        { id: "download", label: "Download", icon: I.download, act: (b) => download(b) },
        own && window.galleryInvite ? { id: "share", label: "Share", icon: I.share, act: () => window.galleryInvite([f]) } : null,
        own ? { id: "transpose", label: "Transpose: set the starting key", icon: I.transpose, act: () => setKeyOf(f) } : null,
        G.main && w && hooks.redo ? { id: "retranscribe", label: "Retranscribe and retranslate", icon: I.retranscribe, act: hooks.redo } : null,
        hooks.lines ? { id: "md", label: "Export as MD", icon: I.markdown, act: () => exportMd(f, hooks.lines()) } : null,
        G.main && hooks.lines ? { id: "m4b", label: "Export as M4B", icon: I.book, act: () => exportM4b(f) } : null,
      ],
    });
  };

  // No lines to open the editor from (an instrumental's [Ambient Sounds], a transcript on its way): a tap
  // on that label opens the editor's tools alone, so Download, Share, Transpose and Retranscribe stay a tap away.
  const toolsSheet = (f, host, el, msg) => {
    if (host.querySelector(".txall")) return;
    const sheet = mkEl("div", "txall");
    const bar = mkEl("div", "txbar txallbar");
    const list = mkEl("div", "txlist");
    const m = mkEl("div", "txmsg");
    m.textContent = msg;
    list.appendChild(m);
    const onKey = (e) => {
      if (e.key !== "Escape") return;
      e.preventDefault();
      e.stopPropagation();
      close();
    };
    const close = () => {
      sheet.remove();
      document.removeEventListener("keydown", onKey, true);
    };
    const w = txWrite(f);
    const redo = async () => {
      close();
      const r = await txSend(w.run, "POST", { retranscribe: true, lang: prefs.nativeLang });
      if (!r || !r.ok) return tell("Couldn’t ask for a new transcript");
      tell("Retranscribing and retranslating");
      f.tx = null;
      host.querySelectorAll(".txst, .txamb").forEach((x) => x.remove());
      awaitTranscript(f, el, host, { run: await r.json().catch(() => ({ state: "queued" })) });
    };
    const done = mkEl("button", "lnk txbtn");
    done.type = "button";
    done.textContent = "Done";
    done.onclick = (e) => {
      e.stopPropagation();
      close();
    };
    bar.append(editorToolsFor(f, { redo: w ? redo : null }).el, done);
    sheet.onclick = (e) => e.stopPropagation();
    sheet.append(bar, list);
    host.appendChild(sheet);
    document.addEventListener("keydown", onKey, true);
  };

  // Clear: the whole transcript goes (an instrumental heard as words). Each line is removed as a
  // correction, so Changes still has every one of them and can put it back.
  const clearTranscript = async (f, lines) => {
    const w = txWrite(f);
    const ids = lines.filter((l) => (l.text || "").trim()).map((l) => l.id);
    if (!w || !ids.length) return false;
    if (!confirm("Clear the whole transcript? Every line is removed. Changes keeps them, so they can be put back.")) return false;
    await flushEdits(f);
    for (let i = 0; i < ids.length; i += 100) {
      const edits = ids.slice(i, i + 100).map((segId) => ({ segId, field: "text", to: "", updatedAt: Date.now() }));
      let r = await txSend(w.put, "PUT", { version: f.txv || 0, edits });
      if (r && r.status === 409) {
        const c = await r.json().catch(() => null);
        if (c) {
          f.txv = c.version;
          r = await txSend(w.put, "PUT", { version: c.version, edits });
        }
      }
      if (!r || !r.ok) {
        tell("Couldn’t clear it");
        return false;
      }
      f.txv = (await r.json().catch(() => ({}))).version || f.txv;
    }
    tell("Cleared — Changes has every line if you want them back");
    return true;
  };

  const retranscribe = async (f) => {
    const r = await txSend(txUrl(f).run, "POST", { retranscribe: true, lang: prefs.nativeLang });
    if (!r || !r.ok) return say("Couldn’t ask for a new transcript", true);
    say("Retranscribing and retranslating; your corrections stay");
    f.tx = null;
    if (items[cur] === f) show(cur);
  };

  const renameItem = async (f) => {
    const old = String(f.path || f.name).split("/").pop();
    const name = prompt("Rename", old);
    if (!name || name.trim() === old) return;

    try {
      const r = await fetch(MAIN_API + "/rename", {
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
      if (!meta.hidden) {
        meta.hidden = true;
        $("info").onclick();
      }
      if (activePlayer && activePlayer.bar) activePlayer.bar.paint();
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
        const r = await fetch(MAIN_API + "/cover?" + new URLSearchParams({ path: f.path }), {
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
      const r = await fetch(MAIN_API + "/cover?" + new URLSearchParams({ path: f.path }), {
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
      // inside the transcript editor a hard scroll is a scroll, never Back or the comments (SPEC 3)
      if (e.target.closest(".txall")) return (x0 = null);

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
      items.sort(byOrder);
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
    const at = want ? items.findIndex((x) => x.n === want || (G.main && x.path === want)) : -1;
    if (at >= 0) openAt(at);
  }
})();