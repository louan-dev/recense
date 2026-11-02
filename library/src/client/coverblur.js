// Cover blur (notes 20261029 item 16): a cover keeps its art, colours and layout, but whatever reads as text
// (dense, sharp, colourless strokes) is blurred, so lines of text show as lines you cannot read. Off, Low,
// Medium (the default) or High, per viewer; only on the cards outside a folder, never inside one.
//   coverBlur.apply(root)   blur every <img>/<video> inside [data-blur] under root
//   coverBlur.level()       "off" | "low" | "medium" | "high"
//   coverBlur.set(level)    remember it and redo the covers on the page
(function () {
  var KEY = "coverBlur", LEVELS = ["off", "low", "medium", "high"];
  // blur radius (px at 360 px wide) and how readily a tile counts as text
  var CFG = { low: { r: 2.5, edge: 0.16 }, medium: { r: 5, edge: 0.12 }, high: { r: 9, edge: 0.08 } };
  var W = 360, T = 6;

  function level() {
    try { var v = localStorage.getItem(KEY); return LEVELS.indexOf(v) >= 0 ? v : "medium"; } catch (e) { return "medium"; }
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
    var lv = level();
    (root || document).querySelectorAll("[data-blur] img,[data-blur] video").forEach(function (el) { one(el, lv); });
  }

  function set(lv) {
    try { localStorage.setItem(KEY, lv); } catch (e) {}
    apply(document);
    document.querySelectorAll(".cbctl").forEach(function (b) { b.textContent = label(); });
  }
  function label() { var l = level(); return "Blur: " + l[0].toUpperCase() + l.slice(1); }

  // a small control that steps Off → Low → Medium → High
  function control() {
    var b = document.createElement("button");
    b.type = "button";
    b.className = "cbctl";
    b.textContent = label();
    b.onclick = function () { set(LEVELS[(LEVELS.indexOf(level()) + 1) % LEVELS.length]); };
    return b;
  }

  window.coverBlur = { apply: apply, level: level, set: set, control: control };
})();
