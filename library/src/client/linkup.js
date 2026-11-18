// Adding files to a share link, one home (T-0142–44): the owner's album page (sharedview.js) and the link page itself
// (gallery.js, guest or owner) both send files through here, so a fix lands once.
//   linkUp.add(files, { call, who, done })   queue files; each shows a row with its own progress, error and Retry
// A file is reserved in the manifest, sent in 16 MB parts (each part tried 4 times, cut off after 5 min without an answer),
// then completed; what was sent is remembered on this device, so a Retry or the same file added again carries on (T-0148). Two files go up
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
      var right = mk("span", "s", r.state === "wait" ? "Waiting" : r.state === "go" ? Math.round(r.frac * 100) + "%" : r.state === "done" ? r.note || "Added" : "");
      if (r.state === "bad") {
        var b = mk("button", "", "Retry"); b.type = "button"; b.setAttribute("aria-label", "Retry " + r.file.name);
        b.onclick = function () { r.state = "wait"; r.err = ""; r.frac = 0; waiting.push(r); paint(); pump(); };
        // T-0148: a file that won't go up can be taken back: its reservation and what was sent go, the tile with them
        var rm = mk("button", "", "Remove"); rm.type = "button"; rm.setAttribute("aria-label", "Remove " + r.file.name);
        rm.onclick = function () { removeRow(r); };
        right = mk("span", "");
        right.append(b, rm);
        row.append(right, mk("span", "s", r.err));
      } else {
        if (r.state === "go") {
          // T-0148: a row that looks stuck can be nudged (this part again, now) or taken back, while it goes
          var nu = mk("button", "", "Refresh"); nu.type = "button"; nu.setAttribute("aria-label", "Refresh " + r.file.name);
          nu.onclick = function () { if (r.ac) { r.nudged = true; r.ac.abort(); } };
          var rm2 = mk("button", "", "Remove"); rm2.type = "button"; rm2.setAttribute("aria-label", "Remove " + r.file.name);
          rm2.onclick = function () { removeRow(r); };
          var pc = right;
          right = mk("span", "");
          right.append(pc, nu, rm2);
        }
        row.append(right);
        var bar = mk("div", "bar"), fill = mk("i"); fill.style.width = Math.round(r.frac * 100) + "%"; bar.append(fill);
        row.append(bar);
      }
      panel.append(row);
    });
  }

  // one file, start to finish; throws with the reason.
  // T-0148: a part that gets no answer is cut off after PART_MS and tried again (before, a fetch on a stuck connection
  // waited forever and the tile sat "paused"). Progress is kept on this device (localStorage: the reservation, the
  // multipart id, each part's etag), so Retry, a reload or adding the same file again continues from the next part
  // instead of reserving a second copy (026 and 027 were one 863 MB recording, twice). A file that fails keeps its
  // reservation for that reason; only an answer from the server that the upload is gone starts it over.
  var PART_MS = window.__lupPartMs || 5 * 60 * 1000; // 16 MB at 0.5 Mbit/s is ~4.5 min (the tests shorten it)
  var store = function (key, v) {
    try { if (v) localStorage.setItem(key, JSON.stringify(v)); else localStorage.removeItem(key); } catch (e) {}
  };
  var load = function (key) {
    try { return JSON.parse(localStorage.getItem(key) || "null"); } catch (e) { return null; }
  };
  var keyOf = function (f, o) {
    return "lup|" + (o.id || location.pathname) + "|" + f.name + "|" + f.size + "|" + f.lastModified;
  };
  // the network or the timer, not the server: keep what was sent
  var lost = function (e) { return !!e && (e instanceof TypeError || e.name === "AbortError"); };

  async function send(r, o) {
    var f = r.file, key = keyOf(f, o), saved = load(key);
    var total = Math.max(1, Math.ceil(f.size / PART));
    if (saved && saved.total !== total) saved = null;
    // Continue on a stalled tile (o.resume = its slot): the server kept the upload id and each part's etag, so any
    // device holding the same file carries on from the next part; with nothing kept, the same slot starts over
    if (!saved && o.resume != null) {
      saved = { i: o.resume, uploadId: "", total: total, parts: [] };
      try {
        var j = await (await o.call({ action: "resume", i: o.resume })).json();
        if (j && j.uploadId && Number(j.total) === total) saved = { i: o.resume, uploadId: j.uploadId, total: total, parts: j.parts || [] };
      } catch (e) {}
    }
    try {
      return await sendFrom(r, o, key, total, saved);
    } catch (e) {
      if (!saved || r.removed || lost(e) || !e.partFailed) throw e;
      store(key, null); // the server no longer knows that upload: once, from the start
      // review 11-17 item 2: the old slot is taken back first, so it doesn't stay an "uploading" tile
      await o.call({ action: "abort", i: saved.i, uploadId: saved.uploadId || "none" }).catch(function () {});
      return await sendFrom(r, o, key, total, null);
    }
  }

  async function sendFrom(r, o, key, total, saved) {
    var f = r.file, i = null, uploadId = "", parts = [];
    try {
      if (saved) {
        i = saved.i; uploadId = saved.uploadId; parts = saved.parts.slice();
        if (!uploadId) {
          uploadId = await (await o.call({ action: "start", i: i, total: total })).text();
          store(key, { i: i, uploadId: uploadId, total: total, parts: [] });
        }
      } else {
        var res = await (await o.call({ action: "reserve" }, { body: JSON.stringify({ name: f.name, size: f.size, type: f.type, taken: f.lastModified, who: o.who }), headers: { "content-type": "application/json" } })).json();
        i = res.i;
        if (o.reserved) o.reserved(res);
        uploadId = await (await o.call({ action: "start", i: i, total: total })).text();
        store(key, { i: i, uploadId: uploadId, total: total, parts: [] });
      }
      r.frac = parts.length / total;
      paint();
      for (var k = parts.length; k < total; k++) {
        var etag = "";
        for (var tries = 1; !etag; tries++) {
          var ac = typeof AbortController === "function" ? new AbortController() : null;
          r.ac = ac;
          var timer = ac ? setTimeout(function () { ac.abort(); }, PART_MS) : 0;
          try {
            var init = { method: "PUT", body: f.slice(k * PART, (k + 1) * PART) };
            if (ac) init.signal = ac.signal;
            etag = (await (await o.call({ action: "part", i: i, uploadId: uploadId, part: k + 1, total: total }, init)).text()).trim();
          } catch (e) {
            if (r.removed) throw e;
            // Refresh on a row that looks stuck: this part again at once, not counted as a failed try
            if (r.nudged) { r.nudged = false; tries--; continue; }
            if (tries >= TRIES) {
              var msg = "part " + (k + 1) + " of " + total + " failed: " + (lost(e) ? "no answer" : (e && e.message) || e);
              var err = lost(e) ? new TypeError(msg) : new Error(msg); // a TypeError: Retry by itself when back online
              err.partFailed = !lost(e);
              throw err;
            }
            await sleep(1500 * tries);
          } finally {
            clearTimeout(timer);
            r.ac = null;
          }
        }
        parts.push({ partNumber: k + 1, etag: etag });
        store(key, { i: i, uploadId: uploadId, total: total, parts: parts });
        r.frac = (k + 1) / total;
        paint();
      }
      try {
        await o.call({ action: "complete", i: i, uploadId: uploadId }, { body: JSON.stringify(parts), headers: { "content-type": "application/json" } });
      } catch (e) {
        // review 11-17: a resumed upload whose earlier `complete` landed but whose answer was lost gets a 400 here
        // forever; forget it and say so instead of a Retry that can never pass
        if (!saved || lost(e)) throw e;
        store(key, null);
        var maybe = new Error("May already be added: check the album");
        maybe.mayBeDone = true;
        throw maybe;
      }
      store(key, null);
    } catch (e) {
      // nothing sent yet: the reservation goes, so nobody sees a tile "uploading" for a file that never comes.
      // Some parts sent: it stays, so Retry continues (the tile shows paused meanwhile)
      if (i != null && !parts.length) {
        store(key, null);
        o.call({ action: "abort", i: i, uploadId: uploadId }).catch(function () {});
      }
      throw e;
    }
  }

  // Remove, while it goes or after it failed: the part in flight is cut off, the reservation and what was sent go
  async function removeRow(r) {
    var key = keyOf(r.file, r.o), saved = load(key);
    r.removed = true;
    if (r.ac) r.ac.abort();
    waiting = waiting.filter(function (x) { return x !== r; });
    store(key, null);
    rows = rows.filter(function (x) { return x !== r; });
    paint();
    if (saved) await r.o.call({ action: "abort", i: saved.i, uploadId: saved.uploadId }).catch(function () {});
    if (r.o.done) r.o.done(r.file); // the page looks again: the tile is gone
  }

  // the screen stays on while files go up (a phone that locks drops the upload); released when the last one ends
  var lock = null;
  async function wake(on) {
    try {
      if (on && !lock && navigator.wakeLock && document.visibilityState === "visible") {
        lock = await navigator.wakeLock.request("screen");
        lock.addEventListener("release", function () { lock = null; });
      } else if (!on && lock) { var l = lock; lock = null; await l.release(); }
    } catch (e) {}
  }
  // back on screen or back online: files that failed for want of a network carry on by themselves
  function again() {
    if (document.visibilityState !== "visible") return;
    if (running) wake(true);
    rows.forEach(function (r) {
      if (r.state === "bad" && r.lost && waiting.indexOf(r) < 0) { r.state = "wait"; r.err = ""; waiting.push(r); }
    });
    pump();
  }
  document.addEventListener("visibilitychange", again);
  window.addEventListener("online", again);

  function pump() {
    while (running < AT_ONCE && waiting.length) {
      (function (r) {
        running++;
        wake(true);
        r.state = "go"; r.frac = 0; r.lost = false; paint();
        send(r, r.o).then(function () { r.state = "done"; r.frac = 1; r.note = ""; }, function (e) { if (r.removed) return; if (e && e.mayBeDone) { r.state = "done"; r.frac = 1; r.note = e.message; return; } r.state = "bad"; r.lost = lost(e); r.err = String((e && e.message) || e); })
          .then(function () { running--; if (!running) wake(false); paint(); if (r.state === "done" && r.o.done) r.o.done(r.file); pump(); });
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

  // a stalled upload this page did not start (another visit, another device): take it back by its slot
  async function drop(o, i) {
    var j = null;
    try { j = await (await o.call({ action: "resume", i: i })).json(); } catch (e) {}
    await o.call({ action: "abort", i: i, uploadId: (j && j.uploadId) || "none" });
  }

  window.linkUp = { drop: drop, add: add, dropAnywhere: dropAnywhere, PART: PART };
})();
