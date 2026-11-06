// Cover blur (notes 20261029 item 16): a cover keeps its art, colours and layout, but whatever reads as text
// (dense, sharp, colourless strokes) is blurred, so lines of text show as lines you cannot read. Each card has its
// own level (Off, Low, Medium the default, High), set in the Edit Cover panel and carried as data-lv on the card;
// only on the cards outside a folder, never inside one.
//   coverBlur.apply(root)      blur every <img>/<video> inside [data-blur] under root, each at its card's level
//   coverBlur.one(el, level)   redo one cover at a level (the panel's preview)
(function () {
  var LEVELS = ["off", "low", "medium", "high"];
  // blur radius (px at 360 px wide) and how readily a tile counts as text
  var CFG = { low: { r: 2.5, edge: 0.16 }, medium: { r: 5, edge: 0.12 }, high: { r: 9, edge: 0.08 } };
  var W = 360, T = 6;

  function level(el) {
    var c = el.closest && el.closest("[data-lv]"), v = c && c.dataset.lv;
    return LEVELS.indexOf(v) >= 0 ? v : "medium";
  }

  // which tiles look like text: many strong edges, little colour
  function mask(px, w, h, cfg) {
    var tw = Math.ceil(w / T), th = Math.ceil(h / T), g = new Float32Array(w * h), on = new Uint8Array(tw * th);
    for (var i = 0, p = 0; i < w * h; i++, p += 4) g[i] = 0.299 * px[p] + 0.587 * px[p + 1] + 0.114 * px[p + 2];
    for (var ty = 0; ty < th; ty++) for (var tx = 0; tx < tw; tx++) {
      var edges = 0, n = 0, sat = 0;
      for (var y = ty * T; y < Math.min(h - 1, ty * T + T); y++) for (var x = tx * T; x < Math.min(w - 1, tx * T + T); x++) {
        var k = y * w + x, d = Math.abs(g[k + 1] - g[k]) + Math.abs(g[k + w] - g[k]), q = k * 4;
        var mx = Math.max(px[q], px[q + 1], px[q + 2]), mn = Math.min(px[q], px[q + 1], px[q + 2]);
        sat += mx ? (mx - mn) / mx : 0;
        if (d > 48) edges++;
        n++;
      }
      if (n && edges / n > cfg.edge && sat / n < 0.16) on[ty * tw + tx] = 1;
    }
    // a lone tile is texture, not text: keep tiles with a neighbour on the same line, then grow by one tile
    var keep = new Uint8Array(tw * th);
    for (var j = 0; j < tw * th; j++) {
      var x0 = j % tw;
      if (on[j] && ((x0 > 0 && on[j - 1]) || (x0 < tw - 1 && on[j + 1]))) keep[j] = 1;
    }
    var m = document.createElement("canvas");
    m.width = w; m.height = h;
    var c = m.getContext("2d");
    c.fillStyle = "#000";
    for (var t = 0; t < tw * th; t++) if (keep[t]) c.fillRect((t % tw) * T - T, Math.floor(t / tw) * T - T / 2, T * 3, T * 2);
    return m;
  }

  function paint(src, el, lv) {
    var cfg = CFG[lv], sw = src.naturalWidth || src.videoWidth, sh = src.naturalHeight || src.videoHeight;
    if (!cfg || !sw || !sh) return;
    var w = Math.min(W, sw), h = Math.round((sh * w) / sw);
    var cv = document.createElement("canvas");
    cv.width = w; cv.height = h;
    var c = cv.getContext("2d", { willReadFrequently: true });
    c.drawImage(src, 0, 0, w, h);
    var px;
    try { px = c.getImageData(0, 0, w, h).data; } catch (e) { return; }
    var m = mask(px, w, h, cfg);
    // the blurred copy, kept only where the (softened) mask is
    var b = document.createElement("canvas");
    b.width = w; b.height = h;
    var bc = b.getContext("2d");
    bc.filter = "blur(" + cfg.r + "px)";
    bc.drawImage(cv, 0, 0);
    bc.filter = "blur(" + T / 2 + "px)";
    bc.globalCompositeOperation = "destination-in";
    bc.drawImage(m, 0, 0);
    c.drawImage(b, 0, 0);
    cv.className = "cb";
    cv.setAttribute("aria-hidden", "true");
    el.parentNode.insertBefore(cv, el.nextSibling);
    el.style.visibility = "hidden";
  }

  function one(el, lv) {
    var old = el.parentNode && el.parentNode.querySelector("canvas.cb");
    if (old) old.remove();
    el.style.visibility = "";
    if (lv === "off") return;
    if (el.tagName === "VIDEO") {
      if (el.readyState >= 2) paint(el, el, lv);
      else el.addEventListener("loadeddata", function () { paint(el, el, lv); }, { once: true });
    } else if (el.complete && el.naturalWidth) paint(el, el, lv);
    else el.addEventListener("load", function () { paint(el, el, lv); }, { once: true });
  }

  function apply(root) {
    (root || document).querySelectorAll("[data-blur] img,[data-blur] video").forEach(function (el) { one(el, level(el)); });
  }

  window.coverBlur = { apply: apply, one: one, LEVELS: LEVELS };

  // Edit Cover: a panel to pick the file a card wears and how much that cover's text is blurred (notes item 16).
  //   coverEditor.open({ title, folders?: [names], folder?, load(folder) -> {files, file, blur}, save(folder, {file?, blur}) })
  // files: [{ value, src, video, name }]. With folders, a row of chips switches card.
  var CSS = ".cved{position:fixed;inset:0;z-index:300;background:rgba(0,0,0,.55);display:flex;align-items:flex-end;justify-content:center}" +
    ".cved>div{background:#1c1c1e;color:#fff;width:100%;max-width:560px;max-height:86vh;border-radius:16px 16px 0 0;padding:14px 16px calc(14px + env(safe-area-inset-bottom));display:flex;flex-direction:column;gap:12px;font:15px -apple-system,BlinkMacSystemFont,sans-serif}" +
    "@media(min-width:700px){.cved{align-items:center}.cved>div{border-radius:16px}}" +
    ".cved header{display:flex;align-items:center;gap:10px}.cved header b{flex:1;font-size:17px}" +
    ".cved button{border:0;background:none;color:#fff;font:inherit;cursor:pointer}.cved button:hover,.cved button.on{color:#0a84ff}" +
    ".cved .pv{position:relative;width:160px;height:160px;align-self:center;border-radius:24px;overflow:hidden;background:#2c2c2e}" +
    ".cved .pv img,.cved .pv video,.cved .pv canvas{position:absolute;inset:0;width:100%;height:100%;object-fit:cover}" +
    ".cved .seg{display:flex;background:#2c2c2e;border-radius:9px;padding:2px}.cved .seg button{flex:1;padding:6px 0;border-radius:7px}.cved .seg button.on{background:#636366;color:#fff}" +
    ".cved .fl{display:flex;gap:8px;overflow-x:auto;scrollbar-width:none}.cved .fl button{white-space:nowrap;padding:6px 12px;border-radius:16px;background:#2c2c2e}.cved .fl button.on{background:#0a84ff;color:#fff}" +
    ".cved .gr{display:grid;grid-template-columns:repeat(4,1fr);gap:4px;overflow-y:auto;min-height:80px}.cved .gr button{position:relative;aspect-ratio:1;padding:0;border-radius:8px;overflow:hidden;background:#2c2c2e}" +
    ".cved .gr img,.cved .gr video{width:100%;height:100%;object-fit:cover;pointer-events:none}.cved .gr button.on{outline:3px solid #0a84ff;outline-offset:-3px}" +
    ".cved small{color:#8e8e93}";

  function mk(tag, cls, text) { var e = document.createElement(tag); if (cls) e.className = cls; if (text != null) e.textContent = text; return e; }
  function media(f) {
    var m = mk(f.video ? "video" : "img");
    m.src = f.video ? f.src + "#t=0.1" : f.src;
    if (f.video) { m.muted = true; m.playsInline = true; m.preload = "metadata"; } else m.loading = "lazy";
    m.alt = "";
    return m;
  }

  function open(o) {
    if (!document.getElementById("cvedcss")) { var st = mk("style"); st.id = "cvedcss"; st.textContent = CSS; document.head.appendChild(st); }
    var bg = mk("div", "cved"), box = mk("div"), head = mk("header"), title = mk("b", "", "Edit Cover");
    var cancel = mk("button", "", "Cancel"), done = mk("button", "", "Done");
    done.style.fontWeight = "600";
    head.append(cancel, title, done);
    var fl = mk("div", "fl"), pv = mk("div", "pv"), seg = mk("div", "seg"), lab = mk("small", "", "Blur on this cover's text"), gr = mk("div", "gr"), pick = mk("small", "", "Pick the cover");
    box.append(head);
    if (o.folders && o.folders.length > 1) box.append(fl);
    box.append(pv, lab, seg, pick, gr);
    bg.appendChild(box);
    document.body.appendChild(bg);
    var st0 = null, cur = { folder: o.folder || (o.folders || [])[0], file: null, blur: "medium", files: [] };
    var close = function () { bg.remove(); };
    cancel.onclick = close;
    bg.onclick = function (e) { if (e.target === bg) close(); };

    var preview = function () {
      pv.innerHTML = "";
      var f = cur.files.filter(function (x) { return x.value === cur.file; })[0] || cur.files[0];
      if (!f) return;
      var m = media(f);
      pv.dataset.lv = cur.blur;
      pv.appendChild(m);
      one(m, cur.blur);
    };
    LEVELS.forEach(function (lv) {
      var b = mk("button", "", lv[0].toUpperCase() + lv.slice(1));
      b.type = "button";
      b.onclick = function () { cur.blur = lv; [].forEach.call(seg.children, function (x) { x.classList.toggle("on", x === b); }); preview(); };
      b.dataset.lv = lv;
      seg.appendChild(b);
    });
    var load = function (folder) {
      cur.folder = folder;
      [].forEach.call(fl.children, function (x) { x.classList.toggle("on", x.textContent === folder); });
      gr.innerHTML = "<small>Loading…</small>";
      Promise.resolve(o.load(folder)).then(function (d) {
        cur.files = d.files || []; cur.file = d.file || null; cur.blur = d.blur || "medium";
        st0 = { file: cur.file, blur: cur.blur };
        [].forEach.call(seg.children, function (x) { x.classList.toggle("on", x.dataset.lv === cur.blur); });
        gr.innerHTML = "";
        if (!cur.files.length) gr.appendChild(mk("small", "", "No pictures or videos in here."));
        cur.files.forEach(function (f, i) {
          var b = mk("button");
          b.type = "button"; b.title = f.name || "";
          b.appendChild(media(f));
          if (f.value === cur.file || (!cur.file && i === 0)) b.classList.add("on");
          b.onclick = function () { cur.file = f.value; [].forEach.call(gr.children, function (x) { x.classList.toggle("on", x === b); }); preview(); };
          gr.appendChild(b);
        });
        preview();
      }, function () { gr.innerHTML = "<small>Couldn't load this folder.</small>"; });
    };
    (o.folders || []).forEach(function (n) { var b = mk("button", "", n); b.type = "button"; b.onclick = function () { load(n); }; fl.appendChild(b); });
    done.onclick = function () {
      var ch = {};
      if (st0 && cur.file !== st0.file && cur.file != null) ch.file = cur.file;
      ch.blur = cur.blur;
      done.disabled = true;
      Promise.resolve(o.save(cur.folder, ch)).then(close, function () { done.disabled = false; alert("Couldn't save the cover"); });
    };
    load(cur.folder);
  }
  window.coverEditor = { open: open };
})();
