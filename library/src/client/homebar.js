// The home bar and the vertical bar: ONE implementation for Gallery's player (gallery.js) and
// Recense's window (a WKWebView over its subtitles, recense/homebar/index.html, which build.sh
// copies this file into). Any change here reaches both apps; never fork it (SPEC P2).
//
// The horizontal bar handles sight and time, the vertical bar handles hearing.
//
//          Vietnamese      English       French      hover (mouse) or first tap: the hover slide
//          ↻ Loop          A ●──────────● B          (Gallery: language; Recense: bookmarks)
//        ───────────────────────────────────────    click / tap: the barrel rolls to the next slide
//          left third      middle third  right third Every slide holds at most three things, one
//                                                    above each third, where Loop, A and B stand.
//
//        0:00     5:00     10:00     15:00   press and HOLD (or drag with a mouse, or two fingers along
//        ────┬───────┬────────┬────────┬───   it): Time Seeking, a ruler for the whole length with the
//                        ● 19:03             playhead where you are; slide to move, slide up to zoom.
//
//   │  the vertical bar: original-language prominence. Two fingers (or a mouse drag) along it:
//   │  bottom 0% only the trailing language · 50% both crisp · 90% only the original · 100% blank.
//   │  Blue once anything it stands for is changed; a press puts everything back and it is white.
//
// Loop rules (unchanged from Gallery): A–B needs Track Loop, so turning A–B on turns Track Loop on;
// turning Track Loop off turns A–B off. Disable A–B keeps the points; Clear forgets them. Only Time
// Seeking moves the playhead.
//
// The host (Gallery's player, or Recense's bridge) is everything app-specific:
//   time() duration() paused()            the media, as it is now
//   seek(t) toggle() skip(dt)             moving it
//   setRate(v) → the rate it took         (Gallery refuses some; Recense forwards it)
//   setLoop({track, ab, a, b})            apply the loop state (the bar owns it)
//   scrub(on)                             a seek is under way (A–B holds off)
//   say(text) wake() onOpen(on)           toast, chrome, the bar unfolding
//   lang: {get, set}                      the trailing language, "vi" | "en" | "fr"
//   size: {get, set, min, max, step}      subtitle size, times the base size
//   volume: {get, set, min, max, step}    the playing source's own volume, 0…1 (get: null while unknown);
//                                         only for a host that lists the "volume" slide (Recense)
//   hover: "lang" | "bookmarks"           what hovering (or the first tap) shows
//   bookmarks() [{t, note}], jump(t), addBookmark()   (hover "bookmarks", and a firm press)
//   slides() [id | {id, label, items:[item|null ×3]}]  the barrel, in order; built-in ids are
//           "lang", "size", "loop", "speed", "volume", "play"; an item is
//           {label, text, icon, on(), blue(), act(button, event)}
globalThis.Homebar = (() => {
  "use strict";

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

  const dur = (s) => {
    if (!isFinite(s) || s < 0) return "0:00";
    const h = Math.floor(s / 3600);
    const m = Math.floor((s % 3600) / 60);
    const sec = Math.floor(s % 60);
    const pad = (n) => String(n).padStart(2, "0");
    return h > 0 ? pad(h) + ":" + pad(m) + ":" + pad(sec) : m + ":" + pad(sec);
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

  const FIFTEEN =
    '<text x="12" y="16" font-size="7" font-weight="bold" fill="currentColor" text-anchor="middle" stroke="none">15</text>';
  const PLAY_PATH = '<path d="M8 5.14v13.72a1 1 0 0 0 1.5.86l11-6.86a1 1 0 0 0 0-1.72l-11-6.86A1 1 0 0 0 8 5.14z"/>';
  const PAUSE_PATH = '<rect x="6" y="4.5" width="4.2" height="15" rx="1.4"/><rect x="13.8" y="4.5" width="4.2" height="15" rx="1.4"/>';
  const I = {
    back15: SVG('<path d="M3 12a9 9 0 1 0 9-9 9.75 9.75 0 0 0-6.74 2.74L3 8"/><path d="M3 3v5h5"/>' + FIFTEEN),
    fwd15: SVG('<path d="M21 12a9 9 0 1 1-9-9 9.75 9.75 0 0 1 6.74 2.74L21 8"/><path d="M21 3v5h-5"/>' + FIFTEEN),
    repeat: SVG('<path d="m17 2 4 4-4 4"/><path d="M3 11v-1a4 4 0 0 1 4-4h14"/><path d="m7 22-4-4 4-4"/><path d="M21 13v1a4 4 0 0 1-4 4H3"/>'),
    download: SVG('<path d="M12 3v12"/><path d="m7 10 5 5 5-5"/><path d="M5 21h14"/>'),
    // Transpose: two staff lines and a note stepping up a tone
    transpose: SVG('<path d="M3 17h8"/><path d="M3 21h8"/><circle cx="16.5" cy="16.5" r="2.5"/><path d="M19 16.5V4l3 2"/><path d="m9 9 3-3 3 3"/><path d="M12 6v7"/>'),
    share: SVG('<path d="M12 3v12"/><path d="m8 7 4-4 4 4"/><path d="M6 11H5a2 2 0 0 0-2 2v6a2 2 0 0 0 2 2h14a2 2 0 0 0 2-2v-6a2 2 0 0 0-2-2h-1"/>'),
    rename: SVG('<path d="M4 20h4L19 9l-4-4L4 16z"/><path d="m13.5 6.5 4 4"/>'),
    cover: SVG('<rect x="3" y="3" width="18" height="18" rx="3"/><circle cx="9" cy="9" r="2"/><path d="m21 15-4.5-4.5L6 21"/>'),
    nocover: SVG('<rect x="3" y="3" width="18" height="18" rx="3"/><path d="m3 3 18 18"/>'),
    timing: SVG('<circle cx="12" cy="13" r="8"/><path d="M12 9v4l2.5 2.5"/><path d="M9.5 2h5"/><path d="M12 2v3"/>'),
    retranscribe: SVG('<path d="M21 12a9 9 0 0 1-15.5 6.2L3 16"/><path d="M3 21v-5h5"/><path d="M3 12a9 9 0 0 1 15.5-6.2L21 8"/><path d="M21 3v5h-5"/>'),
    markdown: SVG('<rect x="2" y="5" width="20" height="14" rx="2"/><path d="M6 15V9l3 3 3-3v6"/><path d="M17 9v6"/><path d="m15 13 2 2 2-2"/>'),
    book: SVG('<path d="M4 19.5V5a2 2 0 0 1 2-2h14v16H6.5a2.5 2.5 0 0 0 0 5H20"/><path d="M10 8l5 3-5 3z"/>'),
    bookmark: SVG('<path d="M6 3h12v18l-6-4-6 4z"/>'),
    // Clear: an eraser wiping a line away
    clear: SVG('<path d="m7 21-4.3-4.3a1 1 0 0 1 0-1.4l10-10a1 1 0 0 1 1.4 0l5.6 5.6a1 1 0 0 1 0 1.4L13 21"/><path d="M22 21H7"/><path d="m5 11 9 9"/>'),
    // Changes: a clock turning back
    changes: SVG('<path d="M3 12a9 9 0 1 0 3-6.7L3 8"/><path d="M3 3v5h5"/><path d="M12 7v5l4 2"/>'),
  };

  const SPEEDS = [0.5, 0.75, 1, 1.25, 1.5, 1.75, 2];
  // left → middle → right, above Loop · A · B
  const LANGS = [
    ["vi", "Vietnamese"],
    ["en", "English"],
    ["fr", "French"],
  ];

  const still = () => !!(window.matchMedia && matchMedia("(prefers-reduced-motion: reduce)").matches);

  // ----- original-language prominence (the vertical bar) -----
  //
  // p is 0…1 from the bottom of the bar, or null at rest (each app's own reading view, untouched).
  //   0         only the trailing language
  //   0 → .5    the original fades in above it; at .5 both are crisp
  //   .5 → .9   the trailing language fades out; at .9 only the original
  //   .9 → 1    a detent: anything past it drops to a blank canvas, for blind listening
  const snapProminence = (r) => (r == null ? null : r <= 0.9 ? clamp(r) : r < 0.95 ? 0.9 : 1);
  const prominence = (p) => {
    if (p == null) return null;
    if (p >= 1) return { orig: 0, trail: 0 };
    return { orig: clamp(p / 0.5), trail: p <= 0.5 ? 1 : clamp(1 - (p - 0.5) / 0.4) };
  };

  // a quick glow on whatever just changed, so a selection can never go unnoticed
  const flash = (...nodes) => {
    nodes.forEach((node) => {
      if (!node) return;
      node.classList.remove("ripple");
      void node.offsetWidth; // restart the animation
      node.classList.add("ripple");
      setTimeout(() => node.classList.remove("ripple"), 800);
    });
  };

  // ---------- text size: three segments, one shape ----------
  //
  //    ◁ a−  ⟩⟨  100%  ⟩⟨  A+ ▷      a wedge, a lens, a wedge, nested into each other with a hair
  //                                  between them. They slide out of the middle when the slide arrives.
  // Left smaller, right larger, the middle is the size (tap: back to 100%). No fill: an iridescent
  // hairline, white type, blue under the pointer.
  const SEG = {
    l: "M3 20 L17 2 H97 L87 20 L97 38 H17 Z",
    m: "M13 2 H87 L97 20 L87 38 H13 L3 20 Z",
    r: "M3 2 H83 L97 20 L83 38 H3 L13 20 Z",
  };
  let holoN = 0;

  // Three segments: less · the value (a tap puts it back to 100%) · more. Text size, and Recense's volume (the
  // playing source's own: ctl.get() is null while the source doesn't say, and the value reads "–").
  const SPEAKER = '<svg viewBox="0 0 24 24" width="15" height="15" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round" aria-hidden="true"><path d="M11 5 6 9H3v6h3l5 4z"/>';
  const SEG_TEXT = {
    group: "Text size", less: "Smaller text", value: "Text size — tap for 100%", more: "Larger text",
    lessHtml: "a<sup>−</sup>", moreHtml: "A<sup>+</sup>",
  };
  const SEG_VOLUME = {
    group: "Volume", less: "Quieter", value: "Volume — tap for 100%", more: "Louder",
    lessHtml: SPEAKER + '<path d="M15.5 9.5a3.5 3.5 0 0 1 0 5"/></svg>',
    moreHtml: SPEAKER + '<path d="M15.5 9.5a3.5 3.5 0 0 1 0 5"/><path d="M18.5 6.5a8 8 0 0 1 0 11"/></svg>',
  };

  const sizeControl = (host, onChange) => segControl(host.size, SEG_TEXT, onChange);

  const segControl = (ctl, t, onChange) => {
    const id = "hb-holo" + ++holoN;
    const wrap = mkEl("div", "p-tsz");
    wrap.setAttribute("role", "group");
    wrap.setAttribute("aria-label", t.group);

    const seg = (k, cls, label, html) => {
      const b = mkBtn("p-tseg " + cls, label, "");
      b.innerHTML =
        '<svg class="p-tsh" viewBox="0 0 100 40" preserveAspectRatio="none" aria-hidden="true">' +
        (k === "l"
          ? '<defs><linearGradient id="' + id + '" x1="0" y1="0" x2="1" y2="1">' +
            '<stop offset="0" stop-color="#7fbcff"/><stop offset=".5" stop-color="#c7a6ff"/><stop offset="1" stop-color="#7fffe0"/>' +
            "</linearGradient></defs>"
          : "") +
        '<path d="' + SEG[k] + '" stroke="url(#' + id + ')" vector-effect="non-scaling-stroke"/></svg>' +
        '<span class="p-tsg">' + html + "</span>";
      return b;
    };

    const dn = seg("l", "dn", t.less, t.lessHtml);
    const pct = seg("m", "pct", t.value, "100%");
    const up = seg("r", "up", t.more, t.moreHtml);
    wrap.append(dn, pct, up);

    const paint = () => {
      const v = ctl.get();
      const known = typeof v === "number" && isFinite(v);
      dn.disabled = !known || v <= ctl.min + 1e-6;
      up.disabled = !known || v >= ctl.max - 1e-6;
      pct.disabled = !known;
      pct.querySelector(".p-tsg").textContent = known ? Math.round(v * 100) + "%" : "–";
      pct.classList.toggle("on", known && Math.abs(v - 1) > 1e-6);
    };

    const step = (d, b) => (e) => {
      e.stopPropagation();
      const v = ctl.get();
      if (typeof v !== "number") return;
      ctl.set(d ? v + d * ctl.step : 1);
      paint();
      flash(b);
      onChange();
    };

    dn.onclick = step(-1, dn);
    up.onclick = step(1, up);
    pct.onclick = step(0, pct);
    paint();
    return { el: wrap, paint };
  };

  // ---------- the horizontal bar ----------

  const horizontal = (host) => {
    const say = (t) => host.say && host.say(t);
    const wake = () => host.wake && host.wake();

    let speed = 1;
    let track = false;
    let abEn = false;
    let A = null;
    let B = null;

    const ready = () => A !== null && B !== null;

    const hb = mkEl("div", "p-hb");
    const box = mkEl("div", "p-hbbox");
    const holo = mkEl("div", "p-hbholo"); // the transparent, iridescent sheen under the unfolded bar (no blur)
    const line = mkBtn("p-hline", "Open play controls", "<i></i>");
    const bead = mkEl("i", "p-sbead");
    const sval = mkBtn("p-hbval", "Speed — tap to reset to 1×", "");
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
    const barrel = mkEl("div", "p-hbbarrel");

    line.setAttribute("aria-expanded", "false");
    hb.dataset.open = "false";
    hb.dataset.mode = "";
    if (host.frost) hb.classList.add("frost"); // videos: frosted glass behind the unfolded bar (SPEC 38)
    mkA.innerHTML = "<b>A</b>";
    mkB.innerHTML = "<b>B</b>";
    skTrack.append(skHint, skRead, skTicks);
    seekL.appendChild(skTrack);
    seekL.setAttribute("aria-hidden", "true");
    barrel.setAttribute("role", "group");

    // the stroke goes in before the slides, so a control in a slide always sits on top of it
    box.append(holo, line, skReg, bead, tbead, mkA, mkB, sval, tval, barrel, seekL);
    hb.appendChild(box);

    // ----- the built-in slides -----

    // Loop · A · B, one to a third. The connector between A and B is the A–B switch; hold it to clear.
    const loopBtn = mkBtn("p-hloop", "Track loop", I.repeat + '<span class="n">Loop</span>');
    const aBtn = mkBtn("p-pa", "Set loop start A", '<span class="l">A</span><i class="dot"></i>');
    const bBtn = mkBtn("p-pb", "Set loop end B", '<i class="dot"></i><span class="l">B</span>');
    const conn = mkBtn("p-pc", "A–B loop", "<i></i>");

    const bPlay = mkBtn("p-hplay", "Play", SVG(PLAY_PATH, true, "pl") + SVG(PAUSE_PATH, true, "pa"));
    const bBack = mkBtn("p-pa", "Back 15 seconds", I.back15);
    const bFwd = mkBtn("p-pb", "Forward 15 seconds", I.fwd15);

    const sTrack = mkEl("div", "p-strack");
    const cells = SPEEDS.map((v) => {
      const c = mkEl("span", "p-sv");
      c.textContent = v + "×";
      sTrack.appendChild(c);
      return c;
    });

    sTrack.tabIndex = 0;
    sTrack.setAttribute("role", "slider");
    sTrack.setAttribute("aria-label", "Playback speed");
    sTrack.setAttribute("aria-valuemin", String(SPEEDS[0]));
    sTrack.setAttribute("aria-valuemax", String(SPEEDS[SPEEDS.length - 1]));

    let size = null; // the text-size control, made with its slide
    let vol = null; // the volume control (Recense: the playing source's own volume), made with its slide

    // ----- the barrel -----

    let order = []; // [{id, el, paint}], the hover slide first when there is one
    let cur = 0;
    let hbOpen = false;
    let mode = ""; // the slide on show, or "seek"

    const slideEl = (id, label) => {
      const s = mkEl("div", "p-slide");
      s.dataset.slide = id;
      s.dataset.pos = "off";
      s.setAttribute("role", "group");
      s.setAttribute("aria-label", label);
      return s;
    };

    const third = (s, node, k) => {
      const c = mkEl("div", "p-third");
      c.dataset.k = String(k);
      if (node) c.appendChild(node);
      s.appendChild(c);
      return c;
    };

    // an app's own item: white, no fill, no border; blue on hover, or while it is "on"
    const itemBtn = (it) => {
      const b = mkBtn("p-hbi" + (it.cls ? " " + it.cls : ""), it.label, (it.icon || "") + (it.text ? '<span class="n"></span>' : ""));
      if (it.title) b.title = it.title;
      b.onclick = (e) => {
        e.stopPropagation();
        it.act(b, e);
        flash(b);
        paintSlides();
        bump();
        wake();
      };
      return b;
    };

    // More than three things for one slide: fold them onto each other in one third. The stack shows
    // its icons fanned together; a click spreads them out above it, one click on any runs it.
    const foldBtn = (it) => {
      const w = mkEl("div", "p-fold");
      const subs = it.fold.filter(Boolean);
      const b = mkBtn("p-hbi p-stack p-foldb", it.label, '<span class="p-foldi">' + subs.map((x) => x.icon || "").join("") + "</span>" + (it.text ? '<span class="n"></span>' : ""));
      const row = mkEl("div", "p-foldrow");
      const kids = subs.map((x) => {
        const k = itemBtn(x);
        const run = k.onclick;
        k.onclick = (e) => {
          run(e);
          w.classList.remove("open");
        };
        row.appendChild(k);
        return { b: k, it: x };
      });
      b.onclick = (e) => {
        e.stopPropagation();
        w.classList.toggle("open");
        bump();
        wake();
      };
      w.append(row, b);
      w.kids = kids;
      w.main = b;
      return w;
    };

    const makeSlide = (spec) => {
      if (spec === "loop") {
        const s = slideEl("loop", "Track loop and A–B loop");
        third(s, loopBtn, 0);
        third(s, aBtn, 1);
        third(s, bBtn, 2);
        s.appendChild(conn);
        return { id: "loop", el: s, paint: () => {} };
      }

      if (spec === "play") {
        const s = slideEl("play", "Play and skip");
        third(s, bBack, 0);
        third(s, bPlay, 1);
        third(s, bFwd, 2);
        return { id: "play", el: s, paint: syncPlay };
      }

      if (spec === "speed") {
        const s = slideEl("speed", "Playback speed");
        s.classList.add("p-wide");
        s.appendChild(sTrack);
        return { id: "speed", el: s, paint: paintSpeed };
      }

      if (spec === "size") {
        const s = slideEl("size", "Text size");
        s.classList.add("p-wide");
        size = sizeControl(host, () => host.onSize && host.onSize());
        s.appendChild(size.el);
        return { id: "size", el: s, paint: size.paint };
      }

      // host.volume: {get, set, min, max, step}, the same three segments: quieter · the level · louder
      if (spec === "volume") {
        const s = slideEl("volume", "Volume");
        s.classList.add("p-wide");
        vol = segControl(host.volume, SEG_VOLUME, () => {});
        s.appendChild(vol.el);
        return { id: "volume", el: s, paint: vol.paint };
      }

      if (spec === "lang") {
        const s = slideEl("lang", "Language");
        const bs = LANGS.map(([code, name], k) => {
          const b = mkBtn("p-hbi p-lang", name, '<span class="n"></span>');
          b.querySelector(".n").textContent = name;
          b.dataset.lang = code;
          b.onclick = (e) => {
            e.stopPropagation();
            host.lang.set(code);
            flash(b);
            paintSlides();
            bump();
            wake();
          };
          third(s, b, k);
          return b;
        });
        const paint = () => {
          const l = host.lang.get();
          bs.forEach((b) => {
            b.classList.toggle("on", b.dataset.lang === l);
            b.setAttribute("aria-pressed", String(b.dataset.lang === l));
          });
        };
        return { id: "lang", el: s, paint };
      }

      // bookmarks: the three nearest the playhead, in time order; none yet: the way to make one
      if (spec === "bookmarks") {
        const s = slideEl("bookmarks", "Bookmarks");
        const paint = () => {
          s.replaceChildren();
          const now = host.time();
          const all = (host.bookmarks && host.bookmarks()) || [];
          const near = all
            .map((b, i) => ({ b, i }))
            .sort((x, y) => Math.abs(x.b.t - now) - Math.abs(y.b.t - now))
            .slice(0, 3)
            .sort((x, y) => x.b.t - y.b.t);
          if (!near.length) {
            third(s, null, 0);
            third(
              s,
              itemBtn({ label: "Bookmark this moment", icon: I.bookmark, text: true, act: () => host.addBookmark() }),
              1
            ).querySelector(".n").textContent = "Bookmark";
            third(s, null, 2);
            return;
          }
          const slots = near.length === 1 ? [null, near[0], null] : near.length === 2 ? [near[0], null, near[1]] : near;
          slots.forEach((n, k) => {
            if (!n) return third(s, null, k);
            const b = mkBtn("p-hbi p-bm", "Go to " + (n.b.note || "") + " " + dur(n.b.t), "");
            b.innerHTML = '<span class="n"></span><span class="t"></span>';
            b.querySelector(".n").textContent = n.b.note || "Bookmark";
            b.querySelector(".t").textContent = dur(n.b.t);
            b.onclick = (e) => {
              e.stopPropagation();
              host.jump(n.b.t);
              flash(b);
              bump();
              wake();
            };
            third(s, b, k);
          });
        };
        return { id: "bookmarks", el: s, paint };
      }

      // an app's own slide: up to three items, each above its third
      const s = slideEl(spec.id, spec.label || spec.id);
      const its = (spec.items || []).slice(0, 3);
      while (its.length < 3) its.push(null);
      const btns = its.map((it, k) => {
        const b = it ? (it.fold ? foldBtn(it) : itemBtn(it)) : null;
        third(s, b, k);
        if (b && it.fold) return { b: b.main, it, kids: b.kids };
        return b && { b, it };
      });
      if (spec.cls) s.classList.add(spec.cls);
      const paint = () => {
        btns.concat(...btns.map((x) => (x && x.kids) || [])).forEach((x) => {
          if (!x) return;
          const t = typeof x.it.text === "function" ? x.it.text() : x.it.text;
          if (t != null) x.b.querySelector(".n").textContent = t;
          x.b.classList.toggle("on", !!(x.it.on && x.it.on()));
          x.b.classList.toggle("blue", !!(x.it.blue && x.it.blue()));
          if (x.it.disabled) x.b.disabled = !!x.it.disabled();
        });
      };
      return { id: spec.id, el: s, paint };
    };

    const hasHover = () => !!host.hover;

    // The barrel is rebuilt each time the bar unfolds, so what is offered follows the item (an
    // owner's file, a photo, a comment count) without the host having to say so.
    const buildSlides = () => {
      const specs = (host.hover ? [host.hover] : []).concat((host.slides && host.slides()) || []);
      size = null;
      order = specs.map(makeSlide);
      barrel.replaceChildren(...order.map((o) => o.el));
      cur = clamp(cur, 0, Math.max(0, order.length - 1));
      order.forEach((o, i) => (o.el.dataset.pos = i === cur ? "cur" : "off"));
      paintSlides();
    };

    const paintSlides = () => order.forEach((o) => o.paint());

    const place = (o, pos, instant) => {
      if (instant) o.el.classList.add("snap");
      o.el.dataset.pos = pos;
      if (instant) {
        void o.el.offsetWidth;
        o.el.classList.remove("snap");
      }
    };

    // the barrel rolls: the slide on show turns away to one side as the next turns in from the other
    const roll = (to, dir) => {
      if (!order.length) return;
      to = ((to % order.length) + order.length) % order.length;
      const from = cur;
      cur = to;
      mode = order[to].id;
      if (to !== from) {
        order.forEach((o, i) => {
          if (i !== from && i !== to) o.el.dataset.pos = "off";
        });
        place(order[to], dir > 0 ? "next" : "prev", true);
        place(order[from], dir > 0 ? "prev" : "next");
        order[to].el.dataset.pos = "cur";
      }
      order[to].paint();
      paintMode();
    };

    const indexOf = (id) => order.findIndex((o) => o.id === id);

    // ----- painting -----

    const paintMode = () => {
      hb.dataset.mode = mode;
      order.forEach((o, i) => o.el.setAttribute("aria-hidden", String(!hbOpen || mode === "seek" || i !== cur)));
      line.setAttribute("aria-label", !hbOpen ? "Open play controls" : mode === "seek" ? "Seeking" : "Next controls");
    };

    const syncPlay = () => {
      const p = host.paused();
      bPlay.classList.toggle("playing", !p);
      bPlay.setAttribute("aria-label", p ? "Play" : "Pause");
    };

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

    // The only place the loop state is painted.
    //   hb.lp   Track Loop is on      → the bar turns blue
    //   hb.pa   A is set              → a bead at the left end
    //   hb.pb   B is set              → a bead at the right end
    //   hb.ab   A–B is on             → both beads lit and the connector glows (Track Loop is on too)
    //   hb.kept A and B are remembered but A–B is off → hollow beads, dashed connector
    const paintLoop = () => {
      if (abEn && !ready()) abEn = false; // A–B needs both points…
      if (abEn) track = true; //           …and needs Track Loop

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
        abEn ? "A–B loop on — press to turn off, hold to clear" : ready() ? "A–B loop off — press to turn on, hold to clear" : "A–B loop: set A and B first"
      );
      conn.title = ready() ? dur(A) + " – " + dur(B) + " · hold to clear" : "A–B loop";

      host.setLoop({ track, ab: abEn, a: A, b: B });
    };

    // ----- speed: six detents -----
    // Changing it only sets the playback rate: no pause, no seek, no restart.

    const setSpeed = (v) => {
      const got = host.setRate(v);
      speed = typeof got === "number" ? got : v;
      paintSpeed();
    };

    const sDrag = false; // (speed is a tap now: never dragged)

    const fracOf = (node, e) => {
      const r = node.getBoundingClientRect();
      return r.width ? clamp((e.clientX - r.left) / r.width) : 0;
    };

    const speedFrom = (e) => setSpeed(SPEEDS[Math.min(SPEEDS.length - 1, Math.floor(fracOf(sTrack, e) * SPEEDS.length))]);

    // Only a tap on a speed sets it (notes 25): a swipe over the speeds is the slides' swipe, never a change of
    // speed, so nothing happens on the way down or while moving; the tap's release picks the speed under it.
    let sTap = null;
    sTrack.onpointerdown = (e) => {
      sTap = { id: e.pointerId, x: e.clientX, y: e.clientY, at: performance.now() };
    };
    sTrack.onpointermove = (e) => {
      if (sTap && e.pointerId === sTap.id && Math.hypot(e.clientX - sTap.x, e.clientY - sTap.y) > 8) sTap = null;
    };
    sTrack.onpointerup = (e) => {
      const t = sTap;
      sTap = null;
      if (!t || e.pointerId !== t.id || Math.hypot(e.clientX - t.x, e.clientY - t.y) > 8 || performance.now() - t.at > 700) return;
      speedFrom(e);
      bump();
      wake();
    };
    sTrack.onpointercancel = () => (sTap = null);
    sTrack.onclick = (e) => e.stopPropagation();

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
      bump();
    };

    sval.onclick = (e) => {
      e.stopPropagation();
      setSpeed(1);
      flash(line);
      say("Speed 1×");
      bump();
      wake();
    };

    // ----- looping (bookkeeping only: the host applies it) -----

    const changed = (...nodes) => {
      paintLoop();
      flash(line, ...nodes);
    };

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

    const enableAB = () => {
      if (!ready()) return;
      abEn = true;
      track = true;
    };

    const pressConn = () => {
      if (abEn) {
        abEn = false;
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
      A = null;
      B = null;
      abEn = false;
      say("A–B cleared");
      changed(conn);
    };

    const captureA = () => {
      A = host.time();
      if (B !== null && B <= A + 0.3) B = null;
      if (ready()) enableAB(); // both points are there: A–B starts
      else abEn = false;
      say("A set · " + dur(A));
      changed(aBtn);
    };

    const captureB = () => {
      const now = host.time();
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

    // ----- unfolding -----

    let hbT = 0;
    let hbEnterT = 0;
    let hbEnterArmed = false;
    let hbHover = false;
    let g = null; // the press that is on the stroke right now
    let holdT = 0;
    let ptype = ""; // who pressed last: "mouse", "touch", or "" for the keyboard
    let suppressClick = false; // a press that turned into a seek (or a swipe, or a firm press) is not also a click
    let tDrag = false;
    let sk = null; // the seek session (ruler geometry, window, position)
    let seekT = 0;
    let liveT = 0;
    let lastSeekAt = 0;
    let tFlashT = 0;
    let seekEndAt = -1e9;

    const setHb = (on) => {
      const was = hbOpen;
      hbOpen = on;
      hb.dataset.open = on ? "true" : "false";
      line.setAttribute("aria-expanded", String(on));
      if (host.onOpen && was !== on) host.onOpen(on);
      paintMode();
    };

    const hideHb = () => {
      clearTimeout(hbT);
      setHb(false);
      wake();
    };

    // slide: which slide to show (an id, or an index); none: the hover slide, or what was there
    const showHb = (ms = 4500, slide) => {
      if (!hbOpen) {
        buildSlides();
        cur = 0;
        order.forEach((o, i) => (o.el.dataset.pos = i === 0 ? "cur" : "off"));
        mode = order.length ? order[0].id : "";
      }
      if (slide !== undefined) {
        const i = typeof slide === "number" ? slide : indexOf(slide);
        if (i >= 0 && i !== cur) {
          if (hbOpen) roll(i, i > cur ? 1 : -1);
          else {
            order.forEach((o, k) => (o.el.dataset.pos = k === i ? "cur" : "off"));
            cur = i;
            mode = order[i].id;
          }
        }
      }
      setHb(true);
      clearTimeout(hbT);
      hbT = setTimeout(() => {
        if (hbHover || sDrag || tDrag) showHb(1200);
        else hideHb();
      }, ms);
      wake();
    };

    const bump = () => {
      if (hbOpen && mode !== "seek") showHb(4500);
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

    // moving the mouse away closes it
    box.addEventListener("pointerleave", (e) => {
      if (e.pointerType !== "mouse") return;
      hbHover = false;
      cancelEnter();
      if (hbOpen && !sk) showHb(900);
    });

    // "entered" and "left" can be stale while the bar changes size under a resting pointer; any
    // movement over it is proof the pointer is on it
    box.addEventListener("pointermove", (e) => {
      if (e.pointerType !== "mouse" || sk || g) return;
      hbHover = true;
      if (!hbOpen && performance.now() - seekEndAt > 250) armEnter();
    });

    // ----- Time Seeking -----
    //
    // Press and hold the stroke and it becomes a temporary time ruler for the media's own length,
    // showing where you are right now; slide along it to move through time from there. Until you
    // move, the ruler is LIVE (letting go changes nothing). One pixel of finger is one pixel of
    // ruler; sliding up zooms in around the playhead (4×, 16×, 64×); A and B pull it like magnets.

    const NICE = [1, 2, 5, 10, 15, 30, 60, 120, 300, 600, 900, 1200, 1800, 3600, 7200, 14400, 28800];
    const MINOR = { 1: 1, 2: 2, 5: 5, 10: 5, 15: 3, 30: 6, 60: 6, 120: 4, 300: 5, 600: 5, 900: 3, 1200: 4, 1800: 6, 3600: 6, 7200: 4, 14400: 4, 28800: 4 };
    const ZOOMS = [1, 4, 16, 64];
    // longer than any ordinary click or tap, so those never get taken for a hold
    const HOLD = { mouse: 220, touch: 400 };

    const buildRuler = () => {
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
      skHint.textContent = sk.live ? "slide to seek" : sk.maxLvl === 0 ? "" : sk.lvl === 0 ? "slide up for finer control" : "finer · " + ZOOMS[sk.lvl] + "×";
    };

    const markOnRuler = (node, t) => {
      const x = t === null ? -1 : (t - sk.win0) / sk.L;
      const on = x >= 0 && x <= 1;
      node.classList.toggle("on", on);
      if (on) node.style.setProperty("--x", String(x));
    };

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
        host.seek(t);
      } else {
        seekT = setTimeout(() => {
          lastSeekAt = performance.now();
          host.seek(t);
        }, 90);
      }
    };

    const rezoom = (lvl, clientX) => {
      const f = clamp((sk.t - sk.win0) / sk.L);
      sk.lvl = lvl;
      sk.L = lvl === 0 ? sk.d : sk.d / ZOOMS[lvl];
      sk.win0 = lvl === 0 ? 0 : clamp(sk.t - f * sk.L, 0, sk.d - sk.L);
      sk.x0 = clientX;
      sk.t0 = sk.t;
      buildRuler();
      paintHint();
    };

    const seekMove = (e) => {
      if (sk.live) {
        // a held finger is never perfectly still: smaller movement is the finger settling
        const slop = g && g.kind === "mouse" ? 3 : 6;
        if (Math.abs(e.clientX - sk.x0) < slop && Math.abs(e.clientY - (g ? g.y0 : sk.lineY)) < slop) return;
        // the first real movement: from here your finger decides, measured from where playback is now
        sk.live = false;
        clearInterval(liveT);
        sk.t = sk.t0 = host.time();
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

    // Every way of seeking comes through here, so they all get the same ruler, zoom and snapping.
    // Returns false if there is no time to move through (a live stream, or nothing loaded yet).
    const beginSeek = (x0, live) => {
      const d = host.duration();
      if (!isFinite(d) || d <= 0) return false;

      tDrag = true;
      host.scrub && host.scrub(true); // A–B stops jumping back while you are seeking
      clearTimeout(hbT);
      clearTimeout(tFlashT);
      hb.classList.remove("tshow");
      host.onSeekStart && host.onSeekStart();

      const cs = getComputedStyle(hb);
      const padL = parseFloat(cs.paddingLeft) || 0;
      const padR = parseFloat(cs.paddingRight) || 0;
      const room = hb.clientWidth - padL - padR;
      const target = Math.min(parseFloat(cs.getPropertyValue("--hbs")) || 640, room);
      const pad = Math.max(26, Math.ceil(dur(d).length * 3.6) + 10);
      const lr = line.getBoundingClientRect();
      const t = host.time();

      sk = {
        d,
        pad,
        W: Math.max(120, target - pad * 2),
        lvl: 0,
        win0: 0,
        L: d,
        maxLvl: ZOOMS.reduce((m, z, i) => (d / z >= 10 ? i : m), 0),
        t,
        t0: t,
        x0,
        lineY: lr.top + lr.height / 2,
        u: clamp(innerHeight * 0.1, 34, 64),
        snap: "",
        live: !!live,
      };

      hb.style.setProperty("--skpad", pad + "px");
      mode = "seek";
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
          sk.t = sk.t0 = host.time();
          paintSeek();
        }, 100);
      }
      return true;
    };

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
      if (!s.live) host.seek(clamp(s.t, 0, s.d)); // land exactly where the finger let go
      tDrag = false;
      host.scrub && host.scrub(false);
      seekEndAt = performance.now();
      hb.classList.remove("seeking", "hasreg");
      hbHover = false; // the bar is about to shrink under the pointer: don't trust the old hover
      cancelEnter();
      hideHb();
      flashTime(s.live ? host.time() : s.t);
    };

    // ----- the press itself -----

    const centroid = () => {
      const p = Object.keys(g.pos).map((k) => g.pos[k]);
      return {
        clientX: p.reduce((a, q) => a + q.x, 0) / p.length,
        clientY: p.reduce((a, q) => a + q.y, 0) / p.length,
      };
    };

    line.addEventListener("pointerdown", (e) => {
      if (e.button) return;

      // a second finger on the stroke: two fingers swiping along it are hold-and-drag, no hold needed
      if (g && g.kind === "touch" && e.pointerType !== "mouse" && !g.two && !ws) {
        g.pos[e.pointerId] = { x: e.clientX, y: e.clientY };
        g.two = true;
        suppressClick = true;
        clearTimeout(holdT);
        try {
          line.setPointerCapture(e.pointerId);
        } catch (x) {}
        const c = centroid();
        g.cx0 = c.clientX;
        g.cy0 = c.clientY;
        if (g.seeking) {
          sk.x0 = c.clientX;
          sk.t0 = sk.t;
        }
        return;
      }

      ptype = e.pointerType === "mouse" ? "mouse" : "touch"; // a pen behaves like a finger
      suppressClick = false;
      clearTimeout(holdT);
      g = { id: e.pointerId, kind: ptype, x0: e.clientX, y0: e.clientY, seeking: false, dead: false, two: false, pos: {} };
      g.pos[e.pointerId] = { x: e.clientX, y: e.clientY };
      try {
        line.setPointerCapture(e.pointerId);
      } catch (x) {}
      window.addEventListener("pointermove", winMove);
      window.addEventListener("pointerup", winEnd);
      window.addEventListener("pointercancel", winEnd);
      holdT = setTimeout(() => {
        if (!g || g.dead || g.seeking || g.two) return;
        startSeek(true);
      }, HOLD[ptype]);
    });

    // A firm press (Force Touch on a Mac trackpad) is its own gesture: Recense bookmarks the moment.
    line.addEventListener("webkitmouseforcedown", () => {
      if (!host.firmPress || (g && g.seeking)) return;
      suppressClick = true;
      if (g) g.dead = true;
      clearTimeout(holdT);
      host.firmPress();
      flash(line);
    });

    const onLineMove = (e) => {
      if (!g || !g.pos[e.pointerId]) return;
      if (e.pointerType === "mouse" && e.buttons === 0) return endPress(e);
      g.pos[e.pointerId] = { x: e.clientX, y: e.clientY };

      if (g.two) {
        const c = centroid();
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

    const winMove = (e) => {
      if (g && !line.contains(e.target)) onLineMove(e);
    };

    const winEnd = (e) => {
      if (g && !line.contains(e.target)) endPress(e);
    };

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
      if (!g || !g.pos[e.pointerId]) return;
      g.recaptured = (g.recaptured || 0) + 1;
      if (g.recaptured <= 3) {
        try {
          line.setPointerCapture(e.pointerId);
          return;
        } catch (x) {}
      }
      endPress(e);
    });
    line.addEventListener("contextmenu", (e) => e.preventDefault());

    // ----- two fingers on a trackpad -----
    //
    // Sideways over the bar: Time Seeking, as hold-and-drag (the swipe's own speed gives coarse and
    // fine). Upright over the unfolded bar: the barrel rolls, one slide per notch. It follows the
    // fingers, not the scroll direction (Firefox doesn't say: natural scrolling is assumed).

    let ws = null; // the sideways swipe in progress: { sum, up, x0, seeking, t, since }
    let roller = null; // the upright one: { sum, t }
    // The fingers still rest on the trackpad. A page can't see that (the wheel just stops), so only a host
    // that can tell says so (Recense, from the swipe's phases). Swipe, then hold: exactly a press held on the
    // stroke after a drag. The ruler stays up and keeps the place where the fingers stopped while the media
    // plays on, and letting go lands there (SPEC 60).
    let fingersOn = false;
    let fingersUpAt = -1e9; // when the host last said they lifted
    let hostFingers = false; // the host has said so at least once; otherwise the page guesses (below)

    const endWheel = () => {
      if (!ws) return;
      const w = ws;
      ws = null;
      clearTimeout(w.t);
      if (w.release) w.release();
      if (w.seeking) finishSeek();
    };

    // A page alone (Gallery in a browser, notes 35) can't see fingers resting, so it guesses: a swipe that
    // dies away in a momentum tail (each step no bigger than the last, down to a pixel or two) was let go;
    // one that stops short is held. A held swipe ends at the next sign of a hand: the pointer moving, a
    // click, a key, or two minutes. A new swipe simply carries on from where it stopped.
    const tailed = (d) => d.length >= 5 && d.slice(-5).every((v, i, a) => !i || v <= a[i - 1] + 0.5) && d[d.length - 1] <= 2;
    const holdUntilHand = (w) => {
      if (w.release) return;
      const end = () => ws === w && endWheel();
      const move = (e) => Math.hypot(e.clientX - w.px, e.clientY - w.py) > 3 && end(); // (where the swipe was)
      addEventListener("pointermove", move, true);
      addEventListener("pointerdown", end, true);
      addEventListener("keydown", end, true);
      w.release = () => {
        removeEventListener("pointermove", move, true);
        removeEventListener("pointerdown", end, true);
        removeEventListener("keydown", end, true);
      };
    };

    // the swipe stopped: over, unless its fingers are still down; then it is held
    const restWheel = () => {
      if (!ws) return;
      if (!ws.seeking || !sk || performance.now() - ws.since > 120000) return endWheel();
      if (hostFingers ? !fingersOn : tailed(ws.d)) return endWheel();
      if (!hostFingers) holdUntilHand(ws);
      ws.t = setTimeout(restWheel, 180);
    };

    box.addEventListener(
      "wheel",
      (e) => {
        if (e.ctrlKey || g) return; // a pinch arrives as ctrl+wheel; a press is already in charge
        if (wroll && !ws) return e.preventDefault(); // the rest of a swipe that rolled the slides (notes 26)
        // just after the host said the fingers lifted, what still arrives is that swipe's tail, not a new one
        if (!ws && !fingersOn && performance.now() - fingersUpAt < 300) return e.preventDefault();
        const k = e.deltaMode === 1 ? 16 : e.deltaMode === 2 ? 400 : 1;
        const dx = e.deltaX * k;
        const dy = e.deltaY * k;
        const inverted = e.webkitDirectionInvertedFromDevice !== false;
        const fingerX = inverted ? -dx : dx; // + = the fingers moved right
        const fingerUp = inverted ? dy : -dy; // + = the fingers moved up
        const sideways = Math.abs(dx) > Math.abs(dy) * 1.2;

        if (!ws && !sideways) {
          // upright: roll the barrel, while it is out (plain scrolling is otherwise none of ours)
          if (!hbOpen || mode === "seek" || order.length < 2) return;
          e.preventDefault();
          if (!roller) roller = { sum: 0, t: 0 };
          roller.sum += fingerUp;
          if (Math.abs(roller.sum) >= 36) {
            const dir = roller.sum > 0 ? 1 : -1;
            roller.sum = 0;
            roll(cur + dir, dir);
            bump();
          }
          clearTimeout(roller.t);
          roller.t = setTimeout(() => (roller = null), 220);
          return;
        }

        if (!ws) {
          const d = host.duration();
          if (!isFinite(d) || d <= 0) return;
          ws = { sum: 0, up: 0, x0: 0, seeking: false, t: 0, since: performance.now(), d: [] };
        }
        if (ws.release) {
          // a held swipe moving again: the fingers never left
          ws.release();
          ws.release = null;
          ws.since = performance.now();
        }
        ws.px = e.clientX;
        ws.py = e.clientY;
        ws.d.push(Math.hypot(dx, dy));
        if (ws.d.length > 8) ws.d.shift();

        e.preventDefault(); // (also stops the browser turning a two-finger swipe into Back / Forward)
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
        ws.t = setTimeout(restWheel, 180);
      },
      { passive: false }
    );

    // Swiping over the slides (not the stroke): left brings the next slide, right the one before.
    // A finger or a mouse drags; a trackpad's two fingers arrive as sideways wheel over the barrel.
    let sw = null;
    barrel.addEventListener("pointerdown", (e) => {
      if (!hbOpen || mode === "seek" || order.length < 2) return;
      sw = { x: e.clientX, y: e.clientY, done: false };
    });
    barrel.addEventListener("pointermove", (e) => {
      if (!sw || sw.done) return;
      const dx = e.clientX - sw.x;
      if (Math.abs(dx) < 36 || Math.abs(dx) < Math.abs(e.clientY - sw.y) * 1.2) return;
      sw.done = true;
      const dir = dx < 0 ? 1 : -1;
      roll(cur + dir, dir);
      bump();
      wake();
    });
    const swEnd = (e) => {
      if (sw && sw.done) {
        // the drag that rolled the barrel is not also a click on what it started over
        const stop = (c) => {
          c.stopPropagation();
          c.preventDefault();
        };
        barrel.addEventListener("click", stop, { capture: true, once: true });
        setTimeout(() => barrel.removeEventListener("click", stop, { capture: true }), 0);
      }
      sw = null;
    };
    barrel.addEventListener("pointerup", swEnd);
    barrel.addEventListener("pointercancel", () => (sw = null));
    let wroll = null;
    barrel.addEventListener(
      "wheel",
      (e) => {
        if (!hbOpen || mode === "seek" || ws || order.length < 2 || e.ctrlKey) return;
        const dx = e.deltaX * (e.deltaMode === 1 ? 16 : 1);
        // A swipe that began over the slides is the slides' to the end (notes 26): its sideways steps roll them,
        // however the fingers wander, and none of it ever reaches the stroke's Time Seeking.
        if (!wroll && Math.abs(dx) <= Math.abs(e.deltaY) * 1.2) return;
        e.preventDefault();
        e.stopPropagation();
        const inverted = e.webkitDirectionInvertedFromDevice !== false;
        const fingerX = inverted ? -dx : dx;
        if (!wroll) wroll = { sum: 0, t: 0, used: false };
        wroll.sum += fingerX;
        if (!wroll.used && Math.abs(wroll.sum) >= 16) { // a light swipe is enough
          wroll.used = true; // one slide per swipe
          const dir = wroll.sum < 0 ? 1 : -1;
          roll(cur + dir, dir);
          bump();
        }
        clearTimeout(wroll.t);
        wroll.t = setTimeout(() => (wroll = null), 240);
      },
      { passive: false }
    );

    // Keyboard: with the stroke focused, ← and → move 5 seconds and Home and End go to the ends.
    line.addEventListener("keydown", (e) => {
      const d = host.duration();
      if (!isFinite(d) || !d) return;
      let t = null;
      if (e.key === "ArrowLeft") t = host.time() - 5;
      else if (e.key === "ArrowRight") t = host.time() + 5;
      else if (e.key === "Home") t = 0;
      else if (e.key === "End") t = d;
      if (t === null) return;
      e.preventDefault();
      e.stopPropagation();
      t = clamp(t, 0, d);
      host.seek(t);
      flashTime(t);
      wake();
    });

    // A click is a tap that did not turn into anything else, and it rolls the barrel. With a pointer,
    // hovering already showed the hover slide, so the first click brings the first slide; with a
    // finger (or the keyboard) the first tap shows the hover slide.
    line.onclick = (e) => {
      e.stopPropagation();
      const kind = ptype;
      ptype = "";
      if (suppressClick) {
        suppressClick = false;
        return;
      }
      // slides change by swiping over them (SPEC 39), not by counting taps on the stroke
      if (!hbOpen) showHb(4500);
      else bump();
      wake();
    };

    const act = (fn) => (e) => {
      e.stopPropagation();
      fn();
      bump();
      wake();
    };

    loopBtn.onclick = act(pressLoop);
    aBtn.onclick = act(captureA);
    bBtn.onclick = act(captureB);
    bPlay.onclick = act(() => {
      host.toggle();
      setTimeout(syncPlay, 60);
    });
    bBack.onclick = act(() => host.skip(-15));
    bFwd.onclick = act(() => host.skip(15));

    // the connector: a tap turns A–B on and off; held, it clears both points
    let connHold = 0;
    let connHeld = false;
    conn.addEventListener("pointerdown", () => {
      connHeld = false;
      clearTimeout(connHold);
      connHold = setTimeout(() => {
        connHeld = true;
        pressClear();
        bump();
      }, 550);
    });
    ["pointerup", "pointercancel", "pointerleave"].forEach((n) => conn.addEventListener(n, () => clearTimeout(connHold)));
    conn.onclick = act(() => {
      if (connHeld) connHeld = false;
      else pressConn();
    });
    conn.addEventListener("contextmenu", (e) => e.preventDefault());

    paintSpeed();
    paintLoop();

    return {
      el: hb,
      line,
      get open() {
        return hbOpen;
      },
      get mode() {
        return mode;
      },
      get busy() {
        return sDrag || tDrag;
      },
      get seekEndAt() {
        return seekEndAt;
      },
      get speed() {
        return speed;
      },
      get loop() {
        return { track, ab: abEn, a: A, b: B };
      },
      show: showHb,
      hide: hideHb,
      bump,
      paint: () => {
        paintSlides();
        syncPlay();
      },
      paintSize: () => size && size.paint(),
      paintVolume: () => vol && vol.paint(),
      captureA,
      captureB,
      pressLoop,
      pressClear,
      setSpeed: (v) => {
        setSpeed(v);
      },
      speedStep: (dir) => {
        setSpeed(SPEEDS[clamp(SPEEDS.indexOf(speed) + dir, 0, SPEEDS.length - 1)]);
        // speed appears where you can see it, then folds away
        showHb(hbOpen && mode !== "speed" ? 4500 : 2400, "speed");
      },
      // Escape folds an open bar; true if it did
      close: () => {
        if (!hbOpen) return false;
        hideHb();
        return true;
      },
      // the trackpad's fingers came down or lifted (a host that can tell: Recense); lifting ends a held swipe
      fingers: (on) => {
        hostFingers = true;
        fingersOn = !!on;
        if (fingersOn) return;
        fingersUpAt = performance.now();
        if (ws) endWheel();
      },
      // two fingers held still on the trackpad (a host that can tell: Recense): the ruler comes up on where the media
      // is, its playhead and time moving on with it; lifting folds it away without a seek (item 21)
      hold: (on) => {
        if (on) {
          if (sk || g || ws) return;
          if (beginSeek(0, true)) sk.held = true;
        } else if (sk && sk.held && sk.live) finishSeek();
      },
      // what the player says, for a host whose media lives elsewhere (Recense)
      report: (s) => {
        if (s.rate != null && s.rate !== speed) {
          speed = s.rate;
          paintSpeed();
        }
        if (s.loop) {
          const l = s.loop;
          if (l.track !== track || l.ab !== abEn || l.a !== A || l.b !== B) {
            track = !!l.track;
            abEn = !!l.ab;
            A = l.a == null ? null : l.a;
            B = l.b == null ? null : l.b;
            paintLoop();
          }
        }
        if (sk && sk.live) {
          sk.t = sk.t0 = host.time();
          paintSeek();
        }
        syncPlay();
      },
      kill: () => {
        [hbT, hbEnterT, holdT, seekT, tFlashT, connHold].forEach(clearTimeout);
        clearInterval(liveT);
        if (ws) clearTimeout(ws.t);
        window.removeEventListener("pointermove", winMove);
        window.removeEventListener("pointerup", winEnd);
        window.removeEventListener("pointercancel", winEnd);
      },
    };
  };

  // ---------- the vertical bar ----------
  //
  // The vertical twin of the home bar, at the same sensitivity: two fingers along it (on a screen,
  // or a trackpad), or a mouse dragging it, set the original language's prominence; a ruler of 0 to
  // 100% stands beside it while it moves. It is blue while anything it stands for is changed.
  //
  // A tap opens and closes the tray (the EQ, C/Đô, Reverb), however often, blue or white: shaping the
  // sound is trial and error (SPEC 52). Putting everything back (the tare) is a deliberate press and
  // HOLD: a light fills the stroke while you hold, and letting go early does nothing. A tap within a
  // few seconds of a tare undoes it. The host:
  //   prominence: {get, set}     0…1, or null at rest
  //   shaped()                   anything changed (the host's own list: text size, EQ, Key, reverb…)
  //   tap()                      a tap: open or close the host's tray
  //   tare() → snapshot | null   put everything back; returns what it was (null: nothing to put back)
  //   untare(snapshot)           the undo: everything as it was before the tare
  //   list()  [{label, sub, act}]  optional: shown on hover as a vertical barrel

  const VPX = 90; // the whole range in 90 px: a light swipe moves it, so it is not taken for a hold (notes 46)
  const HOLD_MS = 700; // press and hold this long to tare
  const HOLD_SHOW = 150; // the light starts filling after this, so a plain tap never flickers
  const UNDO_MS = 6000; // after a tare, a tap this soon undoes it

  // the notation toggle's cycle: p = prosody ribbon, c = chords, n = single notes; "" = all off.
  // [code, name, the short label that fits under the 44 px bar]
  const NOTATION_MODES = [
    ["p", "Prosody", "Prosody"],
    ["c", "Chords", "Chords"],
    ["n", "Notes", "Notes"],
    ["pc", "Prosody + Chords", "P + C"],
    ["pn", "Prosody + Notes", "P + N"],
    ["cn", "Chords + Notes", "C + N"],
    ["", "All Off", "Off"],
  ];

  const vertical = (host) => {
    const wrap = mkEl("div", "p-vbar");
    const btn = mkBtn("p-eqbtn", "Original language: drag or swipe up and down · press to reset", "<i></i>");
    const ruler = mkEl("span", "p-vol");
    const read = mkEl("span", "p-vr");

    ruler.append(mkEl("span", "p-vt"), mkEl("span", "p-vf"), mkEl("span", "p-vb"), mkEl("span", "p-vm m50"), mkEl("span", "p-vm m90"), read);
    btn.appendChild(ruler);
    btn.appendChild(mkEl("b", "p-vhold")); // the light that fills the stroke during a hold
    btn.style.setProperty("--hold", HOLD_MS - HOLD_SHOW + "ms");
    wrap.appendChild(btn);

    let rulerT = 0;
    let endAt = -1e9;
    let touch = null; // two fingers down: { y0, p0 }
    let wheel = null; // a trackpad swipe: { p0, sum, t }
    let drag = null; // a mouse: { y0, p0, moved }
    let hold = null; // one finger or the mouse held still on it: { id, x, y, t, show }
    let undo = null; // just tared: { snap, until }

    const start = () => {
      const p = host.prominence.get();
      return p == null ? 0.5 : p; // from rest, the first move starts with both crisp
    };

    const paintRuler = () => {
      const p = host.prominence.get();
      ruler.style.setProperty("--v", String(p == null ? 0.5 : p));
      read.textContent = p == null ? "" : p >= 1 ? "Blank" : Math.round(p * 100) + "%";
    };

    const show = () => {
      paintRuler();
      ruler.classList.add("on");
      clearTimeout(rulerT);
      rulerT = setTimeout(() => ruler.classList.remove("on"), 900);
      host.wake && host.wake();
    };

    const set = (raw) => {
      const was = host.prominence.get();
      const p = snapProminence(clamp(raw));
      if (p === was) return;
      host.prominence.set(p);
      if ((was == null || was < 1) && p >= 1) flash(btn); // the detent: blackout
      paint();
      show();
    };

    const paint = () => {
      btn.classList.toggle("on", !!host.shaped());
      paintRuler();
    };

    const avgY = (ts) => (ts[0].clientY + ts[1].clientY) / 2;

    // ----- the tare: press and hold; a tap soon after undoes it -----

    const cancelHold = () => {
      if (!hold) return;
      clearTimeout(hold.t);
      clearTimeout(hold.show);
      hold = null;
      btn.classList.remove("holding");
    };

    const tare = () => {
      hold = null;
      btn.classList.remove("holding");
      endAt = performance.now(); // the click that comes with letting go is not a tap
      const snap = host.shaped() && host.tare ? host.tare() : null;
      if (snap == null) return host.say && host.say("Nothing to reset");
      undo = { snap, until: performance.now() + UNDO_MS };
      flash(btn);
      paint();
      host.say && host.say("Reset · tap the bar to undo");
    };

    btn.addEventListener("pointerdown", (e) => {
      if (!e.isPrimary || e.button) return;
      cancelHold();
      hold = {
        id: e.pointerId,
        x: e.clientX,
        y: e.clientY,
        t: setTimeout(tare, HOLD_MS),
        show: setTimeout(() => btn.classList.add("holding"), HOLD_SHOW),
      };
    });
    btn.addEventListener("pointermove", (e) => {
      if (hold && e.pointerId === hold.id && Math.hypot(e.clientX - hold.x, e.clientY - hold.y) > 8) cancelHold();
    });
    ["pointerup", "pointercancel", "pointerleave"].forEach((t) => btn.addEventListener(t, (e) => hold && e.pointerId === hold.id && cancelHold()));
    btn.addEventListener("contextmenu", (e) => hold && e.preventDefault()); // a long touch is a tare, not the page's menu

    btn.addEventListener(
      "touchstart",
      (e) => {
        if (e.touches.length !== 2) return;
        cancelHold(); // two fingers: the prominence, never a tare
        touch = { y0: avgY(e.touches), p0: start() };
        e.preventDefault();
      },
      { passive: false }
    );

    btn.addEventListener(
      "touchmove",
      (e) => {
        if (!touch || e.touches.length !== 2) return;
        e.preventDefault();
        set(touch.p0 + (touch.y0 - avgY(e.touches)) / VPX);
      },
      { passive: false }
    );

    const endTouch = (e) => {
      if (!touch || e.touches.length >= 2) return;
      touch = null;
      endAt = performance.now();
      host.onGestureEnd && host.onGestureEnd();
    };

    btn.addEventListener("touchend", endTouch);
    btn.addEventListener("touchcancel", endTouch);

    // a mouse, or one finger on a phone: press and drag up or down. Two fingers on a 44 px bar were all a phone had,
    // and they rarely both landed on it, so the bar never moved there (notes 40).
    btn.addEventListener("pointerdown", (e) => {
      if (!e.isPrimary || e.button) return;
      drag = { y0: e.clientY, p0: start(), moved: false, id: e.pointerId };
      try {
        btn.setPointerCapture(e.pointerId);
      } catch (x) {}
    });

    btn.addEventListener("pointermove", (e) => {
      if (!drag || e.pointerId !== drag.id || touch) return; // two fingers have it
      if (e.pointerType === "mouse" && e.buttons === 0) {
        drag = null;
        return;
      }
      if (!drag.moved) {
        if (Math.abs(e.clientY - drag.y0) < 3) return; // a light swipe is a drag before the hold can become a tare (notes 46)
        drag.moved = true;
        cancelHold(); // a drag is never a tare, however slowly it starts
        drag.y0 = e.clientY; // measured from here, so the slop that told a drag from a press moves nothing
      }
      set(drag.p0 + (drag.y0 - e.clientY) / VPX);
    });

    const endDrag = (e) => {
      if (!drag || e.pointerId !== drag.id) return;
      if (drag.moved) endAt = performance.now();
      drag = null;
    };

    btn.addEventListener("pointerup", endDrag);
    btn.addEventListener("pointercancel", endDrag);

    btn.addEventListener(
      "wheel",
      (e) => {
        if (e.ctrlKey) return;
        const k = e.deltaMode === 1 ? 16 : e.deltaMode === 2 ? 400 : 1;
        const inverted = e.webkitDirectionInvertedFromDevice !== false;
        if (Math.abs(e.deltaX) > Math.abs(e.deltaY) * 1.2) return;
        e.preventDefault();
        e.stopPropagation();
        cancelHold();
        if (!wheel) wheel = { p0: start(), sum: 0, t: 0 };
        wheel.sum += (inverted ? e.deltaY : -e.deltaY) * k;
        set(wheel.p0 + wheel.sum / VPX);
        clearTimeout(wheel.t);
        wheel.t = setTimeout(() => {
          wheel = null;
          endAt = performance.now();
        }, 180);
      },
      { passive: false }
    );

    // a tap: the tray, or the undo right after a tare. The end of a swipe, a drag or a hold is not one.
    btn.addEventListener("click", (e) => {
      e.stopPropagation();
      cancelHold();
      if (performance.now() - endAt < 450) return;
      if (undo && performance.now() < undo.until) {
        const s = undo.snap;
        undo = null;
        host.untare && host.untare(s);
        flash(btn);
        paint();
        host.say && host.say("Back as it was");
        return;
      }
      undo = null;
      host.tap && host.tap();
    });

    // ----- the hover list: a vertical barrel, front-facing and flat -----

    let list = null;
    if (host.list) {
      list = mkEl("div", "p-vlist");
      list.setAttribute("role", "listbox");
      list.setAttribute("aria-label", host.listLabel || "Bookmarks");
      const reel = mkEl("div", "p-vreel");
      list.appendChild(reel);
      wrap.appendChild(list);

      let at = 0; // the row in front
      let items = [];
      let hideT = 0;
      let wsum = 0;

      const paintReel = () => {
        reel.querySelectorAll(".p-vrow").forEach((r, i) => {
          const d = i - at;
          r.style.setProperty("--d", String(d));
          r.classList.toggle("front", d === 0);
          r.setAttribute("aria-selected", String(d === 0));
        });
      };

      const fill = () => {
        items = host.list() || [];
        reel.replaceChildren(
          ...(items.length
            ? items.map((it, i) => {
                const r = mkBtn("p-vrow", it.label + (it.sub ? " " + it.sub : ""), '<span class="n"></span><span class="t"></span>');
                r.querySelector(".n").textContent = it.label;
                r.querySelector(".t").textContent = it.sub || "";
                r.setAttribute("role", "option");
                r.onclick = (e) => {
                  e.stopPropagation();
                  if (i !== at) {
                    at = i;
                    paintReel();
                    return;
                  }
                  it.act();
                  list.classList.remove("on");
                };
                return r;
              })
            : [Object.assign(mkEl("span", "p-vrow front"), { textContent: host.listEmpty || "No bookmarks" })])
        );
        at = clamp(host.listAt ? host.listAt(items) : 0, 0, Math.max(0, items.length - 1));
        paintReel();
      };

      const open = () => {
        clearTimeout(hideT);
        if (!list.classList.contains("on")) fill();
        list.classList.add("on");
      };

      const close = (ms) => {
        clearTimeout(hideT);
        hideT = setTimeout(() => list.classList.remove("on"), ms);
      };

      [btn, list].forEach((n) => {
        n.addEventListener("pointerenter", (e) => e.pointerType === "mouse" && open());
        n.addEventListener("pointerleave", (e) => e.pointerType === "mouse" && close(600));
      });

      // two fingers over the list turn it, one row per notch
      list.addEventListener(
        "wheel",
        (e) => {
          if (e.ctrlKey || !items.length) return;
          e.preventDefault();
          e.stopPropagation();
          const k = e.deltaMode === 1 ? 16 : e.deltaMode === 2 ? 400 : 1;
          wsum += e.deltaY * k;
          if (Math.abs(wsum) >= 28) {
            at = clamp(at + (wsum > 0 ? 1 : -1), 0, items.length - 1);
            wsum = 0;
            paintReel();
          }
        },
        { passive: false }
      );
    }

    paintRuler(); // (the blue waits for the host's first paint(): what it stands for may not exist yet)

    // the notation toggle under the stroke (item 20): a tap cycles what is drawn between a line and its translation
    // (the prosody ribbon, the chord progression, the sung notes), alone, in pairs, or nothing
    let modeBtn = null;
    const paintMode = () => {
      if (!modeBtn) return;
      const m = NOTATION_MODES.find((x) => x[0] === host.notation.get()) || NOTATION_MODES[0];
      modeBtn.textContent = m[2];
      modeBtn.title = m[1];
      modeBtn.classList.toggle("off", !m[0]);
      modeBtn.setAttribute("aria-label", "Notation: " + m[1] + " · tap for the next");
    };
    if (host.notation) {
      modeBtn = mkBtn("p-nmode", "Notation", "");
      wrap.appendChild(modeBtn);
      modeBtn.addEventListener("click", (e) => {
        e.stopPropagation();
        const i = NOTATION_MODES.findIndex((x) => x[0] === host.notation.get());
        const next = NOTATION_MODES[(i + 1) % NOTATION_MODES.length];
        host.notation.set(next[0]);
        paintMode();
        host.say && host.say("Notation: " + next[1]);
      });
      paintMode();
    }

    return {
      el: wrap,
      btn,
      paint,
      paintMode,
      // the end of a gesture on it (so a click right after isn't taken for a press)
      get recent() {
        return performance.now() - endAt < 450;
      },
      tare,
      kill: () => {
        clearTimeout(rulerT);
        cancelHold();
      },
    };
  };

  // ---------- the transcript editor's tools (SPEC 57): one implementation for both apps ----------
  //
  //   Vietnamese · English · French        Follow · Learn         what the lines trail in, and how they show
  //   ⌫   ⤓   ⇪   ♯   ↻   MD   M4B   …                              the host's own, icons only, white, blue on hover
  //
  // They live in the editor that tapping the transcript opens, not in the home bar. The host:
  //   lang: {get, set}     the trailing language, "vi" | "en" | "fr"
  //   view: {get, set}     "follow" | "learn"
  //   items: [{id, label, icon, act(button, event), show(), on()} | null]   in order; null and show() false leave it out

  const tools = (host) => {
    const el = mkEl("div", "p-tools");
    const top = mkEl("div", "p-ttop");
    const row = mkEl("div", "p-trow");
    el.append(top, row);
    el.addEventListener("pointerdown", (e) => e.stopPropagation()); // the editor's own, never the player's

    const choice = (cls, label, opts, ctl) => {
      const g = mkEl("div", "p-tchoice " + cls);
      g.setAttribute("role", "radiogroup");
      g.setAttribute("aria-label", label);
      const bs = opts.map(([v, name]) => {
        const b = mkBtn("p-ti p-tword", name, "");
        b.textContent = name;
        b.dataset.v = v;
        b.setAttribute("role", "radio");
        b.onclick = (e) => {
          e.stopPropagation();
          ctl.set(v);
          flash(b);
          paint();
        };
        g.appendChild(b);
        return b;
      });
      top.appendChild(g);
      return () =>
        bs.forEach((b) => {
          const on = b.dataset.v === ctl.get();
          b.classList.toggle("on", on);
          b.setAttribute("aria-checked", String(on));
        });
    };

    const paints = [];
    if (host.lang) paints.push(choice("p-tlang", "Language", LANGS, host.lang));
    if (host.view)
      paints.push(
        choice(
          "p-tview",
          "View",
          [
            ["follow", "Follow"],
            ["learn", "Learn"],
          ],
          host.view
        )
      );

    const icons = (host.items || []).filter(Boolean).map((it) => {
      const b = mkBtn("p-ti p-ticon", it.label, it.icon || "");
      b.title = it.label;
      b.dataset.id = it.id;
      b.onclick = (e) => {
        e.stopPropagation();
        it.act(b, e);
        flash(b);
        paint();
      };
      row.appendChild(b);
      return { b, it };
    });

    const paint = () => {
      paints.forEach((p) => p());
      icons.forEach(({ b, it }) => {
        b.hidden = !!(it.show && !it.show());
        b.classList.toggle("on", !!(it.on && it.on()));
      });
    };
    paint();
    return { el, paint };
  };

  // ---------- the sound tray: what the vertical bar holds (SPEC 54) ----------
  //
  // EQ (Low · Mid · High), Key (C/Đô) and Reverb, one curve through all five beads. One implementation for
  // Gallery's player and Recense's window: the tray owns how it looks and the settings; the host makes them heard.
  //   state                 { eq: {low, mid, high}, key, keyNotation, nativeLang, space: {mix, on, room} },
  //                         read and changed in place (Gallery's prefs)
  //   sound.band(id, db)    sound.key(st)    sound.space(mix, on)    apply it; false: it can't be heard here
  //   sound.vox(amount)     optional: the extractor, -1 the vocals out, 1 the vocals alone, 0 off (state.vox)
  //   sound.live()          the sound is already running (a reset then goes through it, else it is just the setting)
  //   sound.why(what)       optional: why "EQ", "Key" or "Space" can't be heard here (else "… isn’t available in this browser")
  //   vbar                  the Homebar.vertical() the tray unfolds from (its stroke opens and closes it)
  //   rooms                 { room: {label}, hall: {label} }
  //   keyName()             the item's original key, for the Key label;   notation(n): keep the chosen notation
  //   chroma()              optional: a live 12-bin chroma of what is playing (the chord detector, SPEC 40)
  //   chords(text|null)     optional: show the chord above the transcript (or in its place), null: none
  //   onOpen(on)            it opened or closed;   onShow(): it is about to show
  //   say(t)  wake()
  // Key labels come from keylabel.js (GalleryKey), which the host loads first.

  const EQ_MAX = 15;

  const EQ_BANDS = [
    { id: "low", label: "Low", type: "lowshelf", f: 160, q: 0.7 },
    { id: "mid", label: "Mid", type: "peaking", f: 1000, q: 0.7 },
    { id: "high", label: "High", type: "highshelf", f: 5000, q: 0.7 },
  ];

  const KEY_MAX = 12;
  let trayN = 0;

  const tray = (host) => {
    const S = host.state;
    const vbar = host.vbar;
    const say = (t) => host.say(t);
    const wake = () => host.wake && host.wake();
    const spaceOn = () => S.space.on && S.space.mix !== 0;
    const eqIsFlat = () => !S.eq.low && !S.eq.mid && !S.eq.high;
    const cant = (what) => say((host.sound.why && host.sound.why(what)) || what + " isn’t available in this browser");

    const eqWrap = mkEl("div", "p-eqwrap");
    const eqBtn = vbar.btn;
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
    eqBtn.title = "Original language: swipe or drag · Sound: EQ, C/Đô, Reverb";

    // the extractor (SPEC 30): the voice out (an instrumental), the voice alone, or the recording as it is.
    // Only where the host can do it (sound.vox); a tap steps through the three.
    const VOX = [
      { v: 0, txt: "Vocals", say: "Vocals as recorded" },
      { v: -1, txt: "No vocals", say: "Instrumental: the vocals taken out" },
      { v: 1, txt: "Vocals only", say: "Vocals alone" },
    ];
    const voxBtn = mkBtn("p-eqflat p-vox", "Extractor: take the vocals out or keep them alone", "Vocals");
    voxBtn.hidden = !host.sound.vox;
    const paintVox = () => {
      const o = VOX.find((x) => x.v === (S.vox || 0)) || VOX[0];
      voxBtn.textContent = o.txt;
      voxBtn.classList.toggle("on", !!S.vox);
      voxBtn.setAttribute("aria-pressed", S.vox ? "true" : "false");
    };
    const setVox = (v) => {
      if (!host.sound.vox) return false;
      const old = S.vox || 0;
      S.vox = v;
      if (!host.sound.vox(v)) {
        S.vox = old;
        cant("The extractor");
        return false;
      }
      paintVox();
      return true;
    };

    eqTop.append(voxBtn, eqFlat);

    // the curve the three bands make together
    const SVGNS = "http://www.w3.org/2000/svg";
    const gradId = "p-eqgrad" + ++trayN;
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

    // ----- the widget menu (SPEC 40): pages within the tray, one at a time -----
    // Page 1 is the sound (EQ, Key, Reverb); page 2 the chord detector. Swiping up and down inside
    // the menu (not on a slider, not on the stroke) brings the next page forward or the last one back;
    // the dots at the top go straight to one.
    const chordPage = mkEl("div", "p-wpage p-chordpage");
    const chordNow = mkEl("div", "p-chordnow");
    const chordBtn = mkBtn("p-eqflat p-chordon", "Chord detector: show the chords above the words", "Chords");
    chordNow.textContent = "—";
    chordPage.hidden = true;
    chordPage.append(chordNow, chordBtn);
    const pages = [eqCols, chordPage];
    const dots = mkEl("div", "p-wdots");
    let page = 0;
    const dotBtns = pages.map((_, i) => {
      const d = mkBtn("p-wdot", i ? "Chord detector" : "Sound", "");
      d.addEventListener("click", (e) => {
        e.stopPropagation();
        setPage(i);
      });
      dots.appendChild(d);
      return d;
    });
    const setPage = (i) => {
      i = clamp(i, 0, pages.length - 1);
      page = i;
      pages.forEach((p, j) => (p.hidden = j !== i));
      dotBtns.forEach((d, j) => {
        d.classList.toggle("on", j === i);
        d.setAttribute("aria-current", j === i ? "true" : "false");
      });
      eq.classList.toggle("p-onchords", i === 1);
    };
    setPage(0);
    eqTop.prepend(dots);

    // the chord detector: while on, the host's live chroma every 250 ms, a chord named once it has
    // held two readings (no flicker), spelled in the notation chordState() picks; the host places it
    // above the transcript, or where the transcript would be when there is none
    let chordsOn = false;
    let chordT = 0;
    let chordLast = null;
    let chordSeen = 0;
    let chordShown = "";
    const chordText = (c) => (c ? GalleryKey.chordName(c, GalleryKey.chordState(S.nativeLang, S.keyNotation, S.notationLast)) : "");
    const showChord = (t) => {
      chordShown = t;
      chordNow.textContent = t || "—";
      if (host.chords) host.chords(chordsOn ? t : null);
    };
    const chordTick = () => {
      const v = host.chroma && host.chroma();
      const c = v ? GalleryKey.chordOf(v) : null;
      const same = (a, b) => (!a && !b) || (a && b && a.pc === b.pc && a.minor === b.minor);
      chordSeen = same(c, chordLast) ? chordSeen + 1 : 0;
      chordLast = c;
      if (chordSeen >= 1 && c) showChord(chordText(c)); // a chord holds until the next one
    };
    const setChords = (on) => {
      if (on && !host.chroma) return say("Chords aren’t available here");
      chordsOn = on;
      clearInterval(chordT);
      chordBtn.classList.toggle("on", on);
      chordBtn.setAttribute("aria-pressed", String(on));
      if (on) chordT = setInterval(chordTick, 250);
      showChord(on ? chordShown : "");
      if (!on) chordLast = null;
    };
    chordBtn.hidden = !host.chroma;
    chordBtn.addEventListener("click", (e) => {
      e.stopPropagation();
      setChords(!chordsOn);
      say(chordsOn ? "Chords on" : "Chords off");
    });
    // the notation or the language changed: respell what is up
    const paintChord = () => chordsOn && chordLast && showChord(chordText(chordLast));

    // swiping the menu: a finger (or mouse) up or down 36 px inside it, or two fingers on a trackpad
    const inMenu = (t) => t && t.closest && !t.closest(".p-band, .kpop, button, input");
    let pg = null;
    eq.addEventListener("pointerdown", (e) => {
      if (inMenu(e.target)) pg = { id: e.pointerId, y: e.clientY, x: e.clientX };
    });
    eq.addEventListener("pointermove", (e) => {
      if (!pg || pg.id !== e.pointerId) return;
      const dy = e.clientY - pg.y;
      if (Math.abs(dy) >= 36 && Math.abs(dy) > Math.abs(e.clientX - pg.x)) {
        setPage(page + (dy < 0 ? 1 : -1)); // up: forward; down: back
        pg = null;
      }
    });
    const pgEnd = () => (pg = null);
    eq.addEventListener("pointerup", pgEnd);
    eq.addEventListener("pointercancel", pgEnd);
    let pgWheel = 0;
    let pgWheelT = 0;
    eq.addEventListener(
      "wheel",
      (e) => {
        if (e.ctrlKey || !inMenu(e.target) || Math.abs(e.deltaX) > Math.abs(e.deltaY)) return;
        e.preventDefault();
        e.stopPropagation(); // not a slider's own wheel
        pgWheel += e.deltaY * (e.deltaMode === 1 ? 16 : e.deltaMode === 2 ? 400 : 1);
        clearTimeout(pgWheelT);
        pgWheelT = setTimeout(() => (pgWheel = 0), 180);
        if (Math.abs(pgWheel) >= 60) {
          setPage(page + (pgWheel > 0 ? 1 : -1));
          pgWheel = -Math.sign(pgWheel) * 1e4; // one page per swipe
        }
      },
      { passive: false }
    );

    eqIn.append(eqTop, eqCols, chordPage);
    eq.appendChild(eqIn);
    eqWrap.append(vbar.el, eq);

    // The curve: x is frequency (low to high, each band's column at its own frequency), y is
    // level on the same ±15 dB scale as the beads. Drawn from the real filter response.
    const FLAT = { low: 0, mid: 0, high: 0, key: 0, space: 0 };
    const curveNow = () => ({ ...S.eq, key: S.key, space: spaceOn() ? S.space.mix : 0 });
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

    const paintBand = (id) => {
      const db = S.eq[id];
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
      const st = S.key;
      const L = GalleryKey.label(st, S.keyNotation, (host.keyName && host.keyName()) || "", S.nativeLang);
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
        const on = Number(r.dataset.state) === S.keyNotation;
        r.classList.toggle("on", on);
        r.setAttribute("aria-selected", String(on));
      });
      key.col.classList.toggle("on", st !== 0);
      key.trk.setAttribute("aria-valuenow", String(st));
      key.trk.setAttribute("aria-valuetext", st ? said : "original key, " + said);
    };

    const paintSpace = () => {
      const m = S.space.mix;
      const on = spaceOn();
      const room = host.rooms[S.space.room].label;
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
      const plain = flat && !S.key && !spaceOn() && !S.vox;

      vbar.paint();
      paintVox();
      eqFlat.hidden = flat;
      graph.classList.toggle("on", !plain);

      if (!keepCurve && !eq.hidden) {
        cancelAnimationFrame(curveRaf);
        shown = curveNow();
        drawCurve(shown);
      }
    };

    // The settings change here; the host's sound(...) makes them heard, and false means it can't.
    const setBand = (id, db) => {
      db = Math.round(clamp(db, -EQ_MAX, EQ_MAX));

      const old = S.eq[id];
      S.eq[id] = db;

      if (!host.sound.band(id, db)) {
        S.eq[id] = old;
        paintEq();
        cant("EQ");
        return;
      }

      paintEq();
    };

    // snapped to the active Key state's step: whole semitones, halves (state 8) or cents (state 9)
    const setKey = (st) => {
      st = GalleryKey.quantize(clamp(st, -KEY_MAX, KEY_MAX), S.keyNotation);
      if (st === S.key) return;

      S.key = st;

      if (!host.sound.key(st)) {
        S.key = 0;
        cant("Key");
      }

      paintKey();
      paintEq();
    };

    const setSpace = (mix, on) => {
      const old = { ...S.space };

      S.space.mix = Math.round(clamp(mix, -100, 100));
      S.space.on = on;

      if (!host.sound.space(S.space.mix, on)) {
        S.space = old;
        cant("Space");
      }

      paintSpace();
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
        const db = S.eq[b.id];
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

    voxBtn.onclick = (e) => {
      e.stopPropagation();
      const i = VOX.findIndex((x) => x.v === (S.vox || 0));
      const o = VOX[(i + 1) % VOX.length];
      if (setVox(o.v)) say(o.say);
      bumpEq();
    };

    eqFlat.onclick = (e) => {
      e.stopPropagation();
      EQ_BANDS.forEach((b) => setBand(b.id, 0));
      say("EQ flat");
      bumpEq();
    };

    const KEY_PX = 9; // finger travel per semitone
    let kg = null;

    key.trk.onpointerdown = (e) => {
      kg = { id: e.pointerId, y: e.clientY, st: S.key, moved: false };
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

    const keyStep = () => GalleryKey.STEPS[S.keyNotation];

    key.trk.onpointerup = (e) => {
      if (kg && !kg.moved) {
        // a tap: one step towards where you tapped
        const r = key.knob.getBoundingClientRect();
        const mid = r.top + r.height / 2;

        if (e.clientY < mid - 3) setKey(S.key + keyStep());
        else if (e.clientY > mid + 3) setKey(S.key - keyStep());
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

      if (e.key === "ArrowUp") n = S.key + keyStep();
      else if (e.key === "ArrowDown") n = S.key - keyStep();
      else if (e.key === "PageUp") n = S.key + 12;
      else if (e.key === "PageDown") n = S.key - 12;
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
      S.keyNotation = n;
      S.notationLast = true; // chosen after the trailing language: the chords follow it (SPEC 40)

      if (host.notation) host.notation(n); // kept where the host keeps it
      paintChord();

      const snapped = GalleryKey.quantize(S.key, n);
      if (snapped !== S.key) setKey(snapped);
      paintKey();
      bumpEq();
    };

    const KEY_HOLD_MS = 350;
    let capHold = 0; // the long-press timer
    let capHeld = false; // it fired: the click that follows is not a tap
    let capTouch = false; // the last press was a finger (its long-press contextmenu is not "back")
    let capWheelAt = 0;
    let capRolled = false; // a held press slid the barrel

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
      rollKeyPop(S.keyNotation);
    };

    // The notation tags are a vertical barrel: one rectangle at a time. Sliding up shows the previous
    // one, sliding down the next (a finger, a held press, or two fingers on a trackpad); a tap on the
    // one in view chooses it.
    const KEY_ROW_PX = 22;
    let kpAt = 0;
    const rollKeyPop = (i) => {
      kpAt = clamp(Math.round(i), 0, GalleryKey.STATES - 1);
      key.pop.style.setProperty("--ki", String(kpAt));
      key.pop.querySelectorAll(".krow").forEach((r, j) => r.classList.toggle("hover", j === kpAt));
    };
    let kpY = null; // a finger or a held press sliding over the barrel: where the last step was taken
    let kpSlidAt = -1e9; // a slide easily runs off a barrel one row tall: the pointer leaving then is not leaving
    const kpSlide = (y) => {
      if (kpY === null) kpY = y;
      kpSlidAt = performance.now();
      const d = y - kpY;
      if (Math.abs(d) < KEY_ROW_PX) return false;
      rollKeyPop(kpAt + (d > 0 ? 1 : -1)); // down: the next; up: the previous
      kpY = y;
      return true;
    };

    function closeKeyPop() {
      if (key.pop.hidden) return;
      key.pop.hidden = true;
      eqWrap.classList.remove("kpop");
      if (bDrag === "keypop") bDrag = null;
      bumpEq();
    }

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
      if (kpSlide(e.clientY)) capRolled = true;
    });

    key.lab.addEventListener("pointerup", (e) => {
      clearTimeout(capHold);
      capY = null;
      kpY = null;
      if (!capHeld || key.pop.hidden) return;

      // press, slide the barrel, let go: the one in view. Let go without sliding: it stays for a tap.
      if (capRolled) {
        capRolled = false;
        setKeyNotation(kpAt);
        closeKeyPop();
      }
    });

    key.lab.addEventListener("pointercancel", () => {
      clearTimeout(capHold);
      capY = null;
      kpY = null;
      capRolled = false;
    });

    // a finger on the barrel itself
    key.pop.addEventListener("pointerdown", (e) => {
      kpY = e.clientY;
      key.pop.dataset.slid = "";
      try {
        key.pop.setPointerCapture(e.pointerId);
      } catch (x) {}
    });
    key.pop.addEventListener("pointermove", (e) => {
      if (kpY === null || (e.pointerType === "mouse" && !e.buttons)) return;
      if (kpSlide(e.clientY)) key.pop.dataset.slid = "1";
    });
    ["pointerup", "pointercancel"].forEach((n) => key.pop.addEventListener(n, () => (kpY = null)));

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
        if (kpY !== null || performance.now() - kpSlidAt < 600) return;
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
      setKeyNotation(S.keyNotation - 1);
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
        else setKeyNotation(S.keyNotation - 1);
      },
      { passive: false }
    );

    // a tap (not the end of a slide) chooses the one in view
    key.pop.addEventListener("click", (e) => {
      e.stopPropagation();
      if (key.pop.dataset.slid) {
        key.pop.dataset.slid = "";
        return;
      }
      setKeyNotation(kpAt);
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
      const m = spaceOn() ? S.space.mix : 0;
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
      if (!S.space.mix) return;
      setSpace(S.space.mix, !S.space.on);
      say(spaceOn() ? "Space on" : "Space bypassed");
      flash(sp.col);
      bumpEq();
    };

    // tap the name to put the reverb back to 0
    sp.lab.onclick = (e) => {
      e.stopPropagation();
      // nothing to undo without Web Audio: just the setting (no AudioContext for a reset)
      if (host.sound.live()) setSpace(0, S.space.on);
      else S.space.mix = 0;
      paintSpace();
      flash(sp.col);
      bumpEq();
    };

    // ----- the sound tray -----

    let eqOpen = false;
    let eqT = 0;
    let eqEnterT = 0;
    let hoverEqBtn = false;
    let hoverEq = false;

    // Opening: the stroke rises to the height of what it holds; the controls are uncovered
    // leftwards out of it; the beads travel up from rest and the curve swells out of the flat
    // line, so the shaping you left reappears as if it had been inside the stroke all along.
    // Closing runs the same story backwards, quicker.
    let eqShowT = 0;
    let travels = [];
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
      if (host.onOpen) host.onOpen(on);
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
    // ----- two fingers on a trackpad, upright -----
    //
    // The vertical twin of the swipe on the home bar, at the same sensitivity: one pixel of
    // fingers is one pixel of control, exactly as one pixel is one pixel of ruler there. Over a
    // band, Key or Space, swiping up raises it and down lowers it, following the fingers whatever
    // "natural scrolling" is set to. Over the folded stroke, swiping up unfolds it. The swipe is
    // over when the wheel events stop coming. Sideways swipes are left alone.

    let vs = null; // { col, from, sum, t }
    let kpWheel = 0;
    let kpWheelT = 0;

    const colOf = (t) => {
      const c = t && t.closest && t.closest(".p-band");
      if (!c) return null;
      if (c === key.col) return "key";
      if (c === sp.col) return "space";
      const b = EQ_BANDS.find((x) => bands[x.id].col === c);
      return b ? b.id : null;
    };

    const valueOf = (c) => (c === "key" ? S.key : c === "space" ? (spaceOn() ? S.space.mix : 0) : S.eq[c]);

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


        if (!eqOpen) return;

        // two fingers on the notation barrel only roll the barrel, never the Key
        if (e.target.closest(".kpop")) {
          if (vs && vs.col === "key") vs = null;
          if (!w2.side) {
            e.preventDefault();
            kpWheel += w2.up;
            if (Math.abs(kpWheel) >= KEY_ROW_PX) {
              rollKeyPop(kpAt + (kpWheel > 0 ? -1 : 1)); // fingers up: the previous; down: the next
              kpWheel = 0;
            }
            clearTimeout(kpWheelT);
            kpWheelT = setTimeout(() => (kpWheel = 0), 180);
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
      clearTimeout(eqEnterT); // a hover that was about to open it is over too
      setEq(false);
      wake();
    };

    const showEq = (ms = 4000) => {
      if (host.onShow) host.onShow();
      setEq(true);
      clearTimeout(eqT);

      eqT = setTimeout(() => {
        if (hoverEqBtn || hoverEq || bDrag) showEq(1200);
        else hideEq();
      }, ms);

      wake();
    };

    const bumpEq = () => {
      if (eqOpen) showEq(4000);
    };

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
        if (S.eq[b.id]) setBand(b.id, 0);
      });

      setKey(0);
      if (S.space.mix) setSpace(0, false);
      if (S.vox) setVox(0);

      shown = was;
      morph(FLAT, 380);
    };

    // Holding the vertical bar while it is blue puts everything it stands for back: the sound, the
    // text size and the original's prominence. It turns white again.

    // the undo of a tare: the sound as it was just before
    const restore = (s) => {
      const was = { ...shown };
      EQ_BANDS.forEach((b) => {
        if (S.eq[b.id] !== s.eq[b.id]) setBand(b.id, s.eq[b.id]);
      });
      if (S.key !== s.key) setKey(s.key);
      if (S.space.mix !== s.space.mix || S.space.on !== s.space.on) setSpace(s.space.mix, s.space.on);
      if ((s.vox || 0) !== (S.vox || 0)) setVox(s.vox || 0);
      shown = was;
      morph(curveNow(), 380);
    };

    return {
      el: eqWrap,
      isOpen: () => eqOpen,
      busy: () => !!bDrag, // a finger on a slider (or the Key list up): the tray stays
      show: showEq,
      hide: hideEq,
      bump: bumpEq,
      paint: paintSound,
      paintEq,
      paintKey,
      paintSpace,
      setKeyNotation,
      paintChord,
      setChords,
      page: setPage,
      reset: resetSound,
      restore,
      kill: () => {
        clearTimeout(capHold);
        clearTimeout(eqT);
        clearTimeout(eqEnterT);
        clearInterval(chordT);
        if (host.chords) host.chords(null);
        document.removeEventListener("pointerdown", keyPopAway, true);
      },
    };
  };

  return { horizontal, vertical, tools, tray, prominence, snapProminence, SPEEDS, LANGS, ICONS: I, dur, mkBtn, EQ_BANDS, EQ_MAX, KEY_MAX };
})();
