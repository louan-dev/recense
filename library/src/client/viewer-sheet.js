// The State C sheet (G5), top to bottom, the same for audio, video and pictures:
//   1. the comments (gallery.js paints them into #thread): each collapsed to three lines with a blue "more";
//      tapping a word of your own opens it with the caret on that word (gallery.js, P0 bug 2)
//   2. the inspector: Transcript | Info. Transcript lines with their times (audio, video); editing a line
//      loops it, so playback never runs on into the next one mid-edit. Info: what the file says (EXIF).
//   3. the metadata card: "Day • Date • Time", blue Adjust. Adjust writes a non-destructive override (meta.js),
//      shown "edited"; Revoke drops it (the file's own value again); Clear blanks it, a revision first;
//      Changes lists every revision with Restore.
//   4. the map (Leaflet, OpenStreetMap tiles, no key; dark): the item as a rounded thumbnail pin, the folder's
//      other items inside the view as pins (clusters with a count), asked of the Worker on every move. A tap on a
//      pin opens that item. The map keeps its own fingers: nothing in it moves the sheet. No place, no card.
(() => {
  const V = window.__galleryViewer;
  const thread = document.getElementById("thread");
  if (!V || !thread) return;

  const LEAFLET = "https://unpkg.com/leaflet@1.9.4/dist/";
  const el = (tag, cls, text) => {
    const e = document.createElement(tag);
    if (cls) e.className = cls;
    if (text != null) e.textContent = text;
    return e;
  };
  const btn = (cls, text, fn) => {
    const b = el("button", cls, text);
    b.type = "button";
    if (fn) b.onclick = fn;
    return b;
  };
  const fmtT = (s) => {
    s = Math.max(0, Math.floor(s || 0));
    return Math.floor(s / 60) + ":" + String(s % 60).padStart(2, "0");
  };
  const day = (ms) => new Date(ms).toLocaleDateString([], { weekday: "long" });
  const date = (ms) => new Date(ms).toLocaleDateString([], { day: "numeric", month: "short", year: "numeric" });
  const time = (ms) => new Date(ms).toLocaleTimeString([], { hour: "numeric", minute: "2-digit" });
  const size = (n) => (n >= 1e9 ? (n / 1e9).toFixed(1) + " GB" : n >= 1e6 ? (n / 1e6).toFixed(1) + " MB" : n >= 1e3 ? Math.round(n / 1e3) + " KB" : n + " B");

  // ---------- 1. comments: three lines, then "more" ----------
  const ro = new ResizeObserver((es) => {
    for (const e of es) {
      const p = e.target;
      const row = p.parentElement;
      if (!row) continue;
      const over = !p.classList.contains("full") && p.scrollHeight > p.clientHeight + 1;
      let more = row.querySelector(":scope > .cmore");
      if (over && !more) {
        more = btn("lnk cmore", "more", () => {
          p.classList.add("full");
          more.remove();
        });
        p.after(more);
      } else if (!over && more) more.remove();
    }
  });
  const clampAll = () => {
    for (const p of thread.querySelectorAll(".ctext:not([data-clamp])")) {
      p.dataset.clamp = "1";
      // a tap on the words opens them in full first (the edit then takes the caret where the tap was)
      p.addEventListener("pointerdown", () => p.classList.add("full"));
      ro.observe(p);
    }
  };

  // ---------- the sheet's own part, kept under whatever gallery.js paints ----------
  const sheet = el("div", "vsheet");
  const keep = () => {
    clampAll();
    if (!thread.hidden && sheet.parentElement !== thread) thread.append(sheet);
  };
  new MutationObserver(keep).observe(thread, { childList: true });

  let cur = null; // the item the sheet shows
  let meta = null;
  let loopStop = null;

  const getMeta = async (f) => {
    const u = V.metaUrl(f);
    if (!u) return null;
    try {
      const r = await fetch(u, { headers: { "x-gallery": "1" } });
      return r.ok ? r.json() : null;
    } catch (e) {
      return null;
    }
  };

  // ---------- 2. inspector ----------
  const inspector = async (f, m) => {
    const box = el("section", "vcard vinsp");
    const av = ["aud", "vid"].includes(V.kind(f));
    const seg = el("div", "vseg");
    seg.setAttribute("role", "tablist");
    const tabs = av ? ["Transcript", "Info"] : ["Info"];
    const body = el("div", "vinspb");
    const pick = (name) => {
      for (const b of seg.children) b.setAttribute("aria-selected", String(b.textContent === name));
      body.replaceChildren();
      if (name === "Info") body.append(infoOf(f, m));
      else transcriptOf(f, m, body);
    };
    for (const t of tabs) {
      const b = btn("lnk vsegb", t, () => pick(t));
      b.setAttribute("role", "tab");
      seg.append(b);
    }
    box.append(seg, body);
    pick(tabs[0]);
    return box;
  };

  const infoOf = (f, m) => {
    const o = (m && m.original) || {};
    const dl = el("dl", "vexif");
    const add = (k, v) => v && dl.append(el("dt", null, k), el("dd", null, v));
    const ext = (o.name || f.name || "").split(".").pop().toUpperCase();
    add("Name", o.name || f.name);
    add("Type", (o.type || "").split("/")[1]?.toUpperCase() || ext);
    add("Size", o.width && o.height ? o.width + " × " + o.height : "");
    add("File", o.size ? size(o.size) : "");
    const a = V.media();
    add("Length", a && Number.isFinite(a.duration) ? fmtT(a.duration) : "");
    add("Camera", [o.make, o.model].filter(Boolean).join(" "));
    add("Taken", o.taken ? date(o.taken) + " " + time(o.taken) : "");
    add("Place", o.lat != null ? o.lat.toFixed(5) + ", " + o.lon.toFixed(5) : "");
    if (!dl.children.length) dl.append(el("dd", "vmuted", "Nothing more in this file."));
    return dl;
  };

  // each line with its time; tap = play from it; edit = that line loops until Save or Cancel
  const transcriptOf = async (f, m, body) => {
    const lines = await V.lines(f);
    if (cur !== f) return;
    if (!lines.length) return body.append(el("p", "vmuted", "No transcript yet."));
    const ov = (m && m.overrides) || {};
    const list = el("ol", "vlines");
    lines.forEach((raw, i) => {
      // a line as the Worker hands it over: its words { t, s, e } (or Recense's { text, start, end })
      const w = (raw.words || []).map((x) => ({ t: x.t ?? x.text ?? "", s: x.s ?? x.start, e: x.e ?? x.end }));
      const s0 = w.length && Number.isFinite(w[0].s) ? w[0].s : 0;
      const e0 = w.length && Number.isFinite(w[w.length - 1].e) ? w[w.length - 1].e : s0 + 4;
      const l = { s: s0, e: e0, text: raw.fixed && raw.text ? raw.text : w.map((x) => x.t).join(" ") };
      const li = el("li", "vline");
      const ts = btn("lnk vts", fmtT(l.s), () => {
        const a = V.media();
        if (a) a.currentTime = l.s;
      });
      const text = ov["line:" + i] != null ? ov["line:" + i] : l.text;
      const tx = el("span", "vltext", text);
      li.append(ts, tx);
      if ("line:" + i in ov) li.append(el("span", "vbadge", "edited"));
      if (V.canAdjust()) tx.onclick = () => editLine(f, l, i, li, tx);
      list.append(li);
    });
    body.append(list);
  };

  const loopLine = (l) => {
    const a = V.media();
    if (!a) return () => {};
    const end = Number.isFinite(l.e) ? l.e : l.s + 4;
    a.currentTime = l.s;
    const t = setInterval(() => {
      if (a.currentTime >= end || a.currentTime < l.s - 0.25) a.currentTime = l.s;
    }, 40);
    return () => clearInterval(t);
  };

  const editLine = (f, l, i, li, tx) => {
    if (li.querySelector("textarea")) return;
    if (loopStop) loopStop();
    loopStop = loopLine(l);
    li.classList.add("looping");
    const box = el("textarea", "vledit");
    box.value = tx.textContent;
    const bar = el("div", "vbtns");
    const done = () => {
      if (loopStop) loopStop();
      loopStop = null;
      li.classList.remove("looping");
    };
    bar.append(
      btn("lnk", "Save", async () => {
        try {
          meta = await V.adjust(f, { field: "line:" + i, action: "adjust", value: box.value });
          done();
          render(f);
        } catch (e) {}
      }),
      btn("lnk", "Cancel", () => {
        done();
        render(f);
      })
    );
    tx.replaceWith(box);
    li.append(bar);
    box.focus();
  };

  // ---------- 3. metadata card ----------
  const card = (f, m) => {
    const box = el("section", "vcard vmeta");
    const e = (m && m.effective) || {};
    const o = (m && m.original) || {};
    const ov = (m && m.overrides) || {};
    const head = el("div", "vmhead");
    const when = el("b", "vwhen", e.taken ? day(e.taken) + " • " + date(e.taken) + " • " + time(e.taken) : "No date");
    head.append(when);
    if ("time" in ov || "location" in ov) head.append(el("span", "vbadge", "edited"));
    if (V.canAdjust()) head.append(btn("lnk vadj", "Adjust", () => adjustPanel(f, m, box)));
    box.append(head);
    return box;
  };

  const adjustPanel = (f, m, box) => {
    let p = box.querySelector(".vadjp");
    if (p) return p.remove();
    p = el("div", "vadjp");
    const ov = m.overrides || {};
    const e = m.effective || {};
    const save = async (body) => {
      try {
        meta = await V.adjust(f, body);
        render(f);
      } catch (x) {
        msg.textContent = x.message;
      }
    };
    const msg = el("p", "vmuted");
    // time
    const tRow = el("div", "vrow2");
    const tIn = el("input", "vin");
    tIn.type = "datetime-local";
    tIn.setAttribute("aria-label", "Date and time");
    if (e.taken) tIn.value = new Date(e.taken - new Date(e.taken).getTimezoneOffset() * 60000).toISOString().slice(0, 16);
    tRow.append(
      el("span", "vlab", "Time"),
      tIn,
      btn("lnk vtsave", "Save", () => tIn.value && save({ field: "time", action: "adjust", value: new Date(tIn.value).getTime() })),
      "time" in ov ? btn("lnk vtrev", "Revoke", () => save({ field: "time", action: "revoke" })) : "",
      btn("lnk vtclr", "Clear", () => save({ field: "time", action: "clear" }))
    );
    // location
    const lRow = el("div", "vrow2");
    const lat = el("input", "vin vnum");
    const lon = el("input", "vin vnum");
    const name = el("input", "vin");
    lat.placeholder = "Latitude";
    lon.placeholder = "Longitude";
    name.placeholder = "Place name";
    if (e.lat != null) [lat.value, lon.value] = [e.lat, e.lon];
    name.value = e.place || "";
    lRow.append(
      el("span", "vlab", "Location"),
      lat,
      lon,
      name,
      btn("lnk vlsave", "Save", () => save({ field: "location", action: "adjust", value: { lat: Number(lat.value), lon: Number(lon.value), name: name.value } })),
      "location" in ov ? btn("lnk vlrev", "Revoke", () => save({ field: "location", action: "revoke" })) : "",
      btn("lnk vlclr", "Clear", () => save({ field: "location", action: "clear" }))
    );
    // every change, newest first, each restorable
    const ch = el("div", "vchanges");
    ch.append(el("b", null, "Changes"));
    const ul = el("ul");
    for (const r of m.revisions || []) {
      const li = el("li", "vchg");
      li.append(el("span", null, r.field + " · " + r.action + " · " + date(r.at) + " " + time(r.at)));
      li.append(btn("lnk vrestore", "Restore", () => save({ field: r.field, action: "restore", rev: r.id })));
      ul.append(li);
    }
    if (!ul.children.length) ul.append(el("li", "vmuted", "No changes yet."));
    ch.append(ul);
    p.append(tRow, lRow, ch, msg);
    box.append(p);
  };

  // ---------- 4. the map ----------
  let L = null;
  let map = null;
  let pins = null;
  let pinT = 0;
  const leaflet = () =>
    L
      ? Promise.resolve(L)
      : new Promise((ok, no) => {
          if (!document.querySelector("link[data-leaflet]")) {
            const css = el("link");
            css.rel = "stylesheet";
            css.href = LEAFLET + "leaflet.css";
            css.dataset.leaflet = "1";
            document.head.append(css);
          }
          const s = el("script");
          s.src = LEAFLET + "leaflet.js";
          s.onload = () => ok((L = window.L));
          s.onerror = no;
          document.head.append(s);
          setTimeout(() => no(new Error("offline")), 8000);
        });

  const pinIcon = (src, n, on) =>
    L.divIcon({
      className: "vpin" + (on ? " on" : ""),
      html: (src ? '<img alt="" src="' + src.replace(/"/g, "&quot;") + '">' : "<i></i>") + (n > 1 ? "<b>" + n + "</b>" : ""),
      iconSize: on ? [52, 52] : [40, 40],
      iconAnchor: on ? [26, 26] : [20, 20],
    });

  // the folder's items in view, one pin for those close together, with a count
  const refreshPins = async () => {
    if (!map || !cur) return;
    const b = map.getBounds();
    const u = V.geoUrl({ s: b.getSouth(), w: b.getWest(), n: b.getNorth(), e: b.getEast() });
    if (!u) return;
    const f = cur;
    let items = [];
    try {
      items = (await (await fetch(u, { headers: { "x-gallery": "1" } })).json()).items || [];
    } catch (e) {}
    if (f !== cur || !map) return;
    pins.clearLayers();
    // pins closer than 48px share one, with a count (greedy: each joins the first group near enough)
    const groups = [];
    for (const it of items) {
      const pt = map.latLngToContainerPoint([it.lat, it.lon]);
      const g = groups.find((g) => Math.hypot(g.x - pt.x, g.y - pt.y) < 48);
      if (g) g.items.push(it);
      else groups.push({ x: pt.x, y: pt.y, items: [it] });
    }
    const ix = (it) => (V.indexOf(it.path) >= 0 ? V.indexOf(it.path) : V.indexOf(it.name));
    for (const { items: group } of groups) {
      const it = group.find((x) => ix(x) === V.index()) || group[0];
      const i = ix(it);
      const on = i === V.index();
      const mk = L.marker([it.lat, it.lon], { icon: pinIcon(V.thumbOf(V.at(i)), group.length, on), keyboard: false });
      mk.on("click", () => i >= 0 && V.show(i));
      mk.addTo(pins);
    }
    mapEl().dataset.pins = String(pins.getLayers().length);
  };
  const mapEl = () => sheet.querySelector(".vmapc");

  const mapCard = (f, m) => {
    const e = (m && m.effective) || {};
    if (e.lat == null || e.lon == null) return null; // no place, no card
    const box = el("section", "vcard vmap");
    const c = el("div", "vmapc");
    c.setAttribute("aria-label", "Map");
    // the map's fingers are its own: never a pull of the sheet or a swipe of the viewer
    for (const t of ["pointerdown", "touchstart", "wheel"]) c.addEventListener(t, (ev) => ev.stopPropagation(), { passive: true });
    const barEl = el("div", "vmapbar");
    barEl.append(el("span", "vplace", e.place || e.lat.toFixed(4) + ", " + e.lon.toFixed(4)));
    if (V.canAdjust()) {
      const adj = btn("lnk vmapadj", "Adjust", () => {
        c.classList.toggle("moving");
        adj.textContent = c.classList.contains("moving") ? "Tap the map" : "Adjust";
      });
      barEl.append(adj);
      if ("location" in ((m && m.overrides) || {})) barEl.append(btn("lnk vmaprev", "Revoke", async () => ((meta = await V.adjust(f, { field: "location", action: "revoke" })), render(f))));
    }
    box.append(c, barEl);
    leaflet()
      .then(() => {
        if (cur !== f || !c.isConnected) return;
        if (map) map.remove();
        map = L.map(c, { zoomControl: false, attributionControl: true, dragging: true, touchZoom: true, scrollWheelZoom: true, tap: false }).setView([e.lat, e.lon], 13);
        L.tileLayer("https://tile.openstreetmap.org/{z}/{x}/{y}.png", { maxZoom: 19, attribution: "© OpenStreetMap" }).addTo(map);
        pins = L.layerGroup().addTo(map);
        L.marker([e.lat, e.lon], { icon: pinIcon(V.thumbOf(f), 1, true), keyboard: false, zIndexOffset: 1000 }).addTo(map);
        map.on("moveend", () => (clearTimeout(pinT), (pinT = setTimeout(refreshPins, 120)))); // a zoom ends in a moveend too
        map.on("click", async (ev) => {
          if (!c.classList.contains("moving")) return;
          meta = await V.adjust(f, { field: "location", action: "adjust", value: { lat: ev.latlng.lat, lon: ev.latlng.lng, name: e.place || "" } });
          render(f);
        });
        c.dataset.ready = "1";
        refreshPins();
      })
      .catch(() => c.replaceChildren(el("p", "vmuted", "The map needs a connection.")));
    return box;
  };

  // ---------- the sheet for one item ----------
  const render = async (f) => {
    if (loopStop) loopStop();
    loopStop = null;
    cur = f;
    if (map) {
      map.remove();
      map = null;
    }
    sheet.replaceChildren();
    if (!f || f.pending) return;
    const m = meta && meta.path && (meta.path === f.path || meta.path === (f.path || "").split("/").pop()) ? meta : await getMeta(f);
    meta = null;
    if (cur !== f) return;
    sheet.append(await inspector(f, m));
    if (m) sheet.append(card(f, m));
    const mc = m && mapCard(f, m);
    if (mc) sheet.append(mc);
    keep();
  };

  V.onShow((f) => {
    meta = null;
    if (!f) return render(null);
    if (V.isOpen()) render(f);
    else cur = null;
  });
  // the sheet is drawn when C opens (not for every item swiped past)
  new MutationObserver(() => {
    const f = V.item();
    if (V.isOpen() && f && cur !== f) render(f);
  }).observe(document.body, { attributes: true, attributeFilter: ["class"] });
  window.__gallerySheet = { render: () => render(V.item()) };
})();
