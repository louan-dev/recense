// Adding files to a share link, one home (T-0142–44): the owner's album page (sharedview.js) and the link page itself
// (gallery.js, guest or owner) both send files through here, so a fix lands once.
//   linkUp.add(files, { call, who, done })   queue files; each shows a row with its own progress, error and Retry
// A file is reserved in the manifest, sent in 16 MB parts (each part tried 4 times), then completed. Two files go up
// at once. One file failing never stops the others, and a failed file stays on screen with its reason and a Retry.
//   call(params, init) -> Response   throws on a non-2xx answer (the caller knows the address and headers)
// Needs the Worker and R2 only at the moment of sending, as a share link always did.
(function () {
  var PART = 16 * 1024 * 1024;
  var TRIES = 4;
  var AT_ONCE = 2;
  var sleep = function (ms) { return new Promise(function (ok) { setTimeout(ok, ms); }); };

  var CSS =
    ".lup{position:fixed;left:12px;right:12px;bottom:calc(12px + env(safe-area-inset-bottom));max-width:460px;margin:0 auto;z-index:60;background:#1c1c1e;color:#fff;border-radius:14px;box-shadow:0 8px 30px #0008;padding:6px 12px;font:14px/1.3 -apple-system,system-ui,sans-serif;max-height:40vh;overflow:auto}" +
    ".lup[hidden]{display:none}.lup .r{display:grid;grid-template-columns:1fr auto;gap:2px 10px;padding:8px 0;border-bottom:1px solid #3a3a3c}.lup .r:last-child{border:0}" +
    ".lup .n{overflow:hidden;text-overflow:ellipsis;white-space:nowrap}.lup .s{color:#8e8e93;font-size:12px;grid-column:1}" +
    ".lup .bar{grid-column:1/3;height:3px;background:#3a3a3c;border-radius:2px;overflow:hidden}.lup .bar i{display:block;height:100%;width:0;background:#0a84ff;transition:width .2s}" +
    ".lup .r.bad .s{color:#ff9f0a}.lup button{background:none;border:0;color:#0a84ff;font:inherit;padding:0 4px;cursor:pointer}" +
    ".lup .h{display:flex;justify-content:space-between;align-items:center;padding:4px 0;color:#8e8e93;font-size:12px}" +
    "body.lupdrop::after{content:'Drop to add files';position:fixed;inset:8px;z-index:70;display:flex;align-items:center;justify-content:center;border:3px dashed #0a84ff;border-radius:18px;background:#0a84ff22;color:#fff;font:600 20px -apple-system,system-ui,sans-serif;pointer-events:none}" +
    "@media (prefers-reduced-motion:reduce){.lup .bar i{transition:none}}";

  var panel = null;
  var rows = [];
  var running = 0;
  var waiting = [];

  function mk(tag, cls, text) { var e = document.createElement(tag); if (cls) e.className = cls; if (text != null) e.textContent = text; return e; }

  function mount() {
    if (panel) return panel;
    var st = mk("style"); st.textContent = CSS; document.head.appendChild(st);
    panel = mk("div", "lup");
    panel.setAttribute("role", "status");
    panel.hidden = true;
    document.body.appendChild(panel);
    return panel;
  }

  function paint() {
    mount();
    panel.hidden = !rows.length;
    panel.replaceChildren();
    var head = mk("div", "h"), live = rows.filter(function (r) { return r.state === "wait" || r.state === "go"; }).length;
    var bad = rows.filter(function (r) { return r.state === "bad"; }).length;
    head.append(mk("span", "", live ? "Adding " + live + (live === 1 ? " file…" : " files…") : bad ? bad + " didn’t go up" : "Added"));
    var x = mk("button", "", live ? "" : "Close"); x.type = "button";
    x.hidden = !!live; x.onclick = function () { rows = rows.filter(function (r) { return r.state === "bad"; }); paint(); };
    head.append(x);
    panel.append(head);
    rows.forEach(function (r) {
      var row = mk("div", "r" + (r.state === "bad" ? " bad" : ""));
      row.append(mk("span", "n", r.file.name));
      var right = mk("span", "s", r.state === "wait" ? "Waiting" : r.state === "go" ? Math.round(r.frac * 100) + "%" : r.state === "done" ? "Added" : "");
      if (r.state === "bad") {
        var b = mk("button", "", "Retry"); b.type = "button"; b.setAttribute("aria-label", "Retry " + r.file.name);
        b.onclick = function () { r.state = "wait"; r.err = ""; r.frac = 0; waiting.push(r); paint(); pump(); };
        right = b;
        row.append(right, mk("span", "s", r.err));
      } else {
        row.append(right);
        var bar = mk("div", "bar"), fill = mk("i"); fill.style.width = Math.round(r.frac * 100) + "%"; bar.append(fill);
        row.append(bar);
      }
      panel.append(row);
    });
  }

  // one file, start to finish; throws with the reason
  async function send(r, o) {
    var f = r.file, i = null, uploadId = "";
    try {
      var res = await (await o.call({ action: "reserve" }, { body: JSON.stringify({ name: f.name, size: f.size, type: f.type, taken: f.lastModified, who: o.who }), headers: { "content-type": "application/json" } })).json();
      i = res.i;
      if (o.reserved) o.reserved(res);
      var total = Math.max(1, Math.ceil(f.size / PART));
      uploadId = await (await o.call({ action: "start", i: i, total: total })).text();
      var parts = [];
      for (var k = 0; k < total; k++) {
        var etag = "";
        for (var tries = 1; !etag; tries++) {
          try {
            etag = (await (await o.call({ action: "part", i: i, uploadId: uploadId, part: k + 1, total: total }, { method: "PUT", body: f.slice(k * PART, (k + 1) * PART) })).text()).trim();
          } catch (e) {
            if (tries >= TRIES) throw new Error("part " + (k + 1) + " of " + total + " failed: " + (e.message || e));
            await sleep(1500 * tries);
          }
        }
        parts.push({ partNumber: k + 1, etag: etag });
        r.frac = (k + 1) / total;
        paint();
      }
      await o.call({ action: "complete", i: i, uploadId: uploadId }, { body: JSON.stringify(parts), headers: { "content-type": "application/json" } });
    } catch (e) {
      // the reservation goes, so nobody sees a tile "uploading" for a file that will never come
      if (i != null) o.call({ action: "abort", i: i, uploadId: uploadId }).catch(function () {});
      throw e;
    }
  }

  function pump() {
    while (running < AT_ONCE && waiting.length) {
      (function (r) {
        running++;
        r.state = "go"; r.frac = 0; paint();
        send(r, r.o).then(function () { r.state = "done"; r.frac = 1; }, function (e) { r.state = "bad"; r.err = String((e && e.message) || e); })
          .then(function () { running--; paint(); if (r.state === "done" && r.o.done) r.o.done(r.file); pump(); });
      })(waiting.shift());
    }
  }

  function add(files, o) {
    Array.prototype.slice.call(files).forEach(function (f) {
      var r = { file: f, o: o, state: "wait", frac: 0, err: "" };
      rows.push(r); waiting.push(r);
    });
    paint(); pump();
  }

  // Files dropped from the Finder anywhere on the page. ok() says whether this page takes files right now; a drop where it
  // doesn't must not open the file in the tab either.
  function dropAnywhere(ok, take) {
    var depth = 0;
    var has = function (e) { return !!e.dataTransfer && Array.prototype.indexOf.call(e.dataTransfer.types || [], "Files") >= 0; };
    var off = function () { depth = 0; document.body.classList.remove("lupdrop"); };
    document.addEventListener("dragenter", function (e) { if (has(e) && ok()) { depth++; document.body.classList.add("lupdrop"); } });
    document.addEventListener("dragleave", function (e) { if (has(e) && --depth <= 0) off(); });
    document.addEventListener("dragover", function (e) {
      if (!has(e)) return;
      e.preventDefault();
      e.dataTransfer.dropEffect = ok() ? "copy" : "none";
    });
    document.addEventListener("drop", function (e) {
      if (!has(e)) return;
      e.preventDefault();
      off();
      if (ok()) take(Array.prototype.slice.call(e.dataTransfer.files || []));
    });
  }

  window.linkUp = { add: add, dropAnywhere: dropAnywhere, PART: PART };
})();
