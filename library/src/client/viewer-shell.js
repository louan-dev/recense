// The viewer shell (G3): one shell for every item (audio, video, image, document) over gallery.js's viewer.
//
//   A  Full-bleed   tap the stage from B. Media 100%, radius 0, all chrome faded out.
//   B  Framed       the default; tap from A, or swipe down from C. Media scale .82, radius 24px, black around.
//                   Top: a round "<" back, the folder over the date • time, "•••". Bottom: scrubber,
//                   thumbnail filmstrip, the action capsule (Share, Favorite, Info, Audio/EQ; Delete apart).
//   C  Docked       swipe up, or Info/Transcript. The media docks to the top 38% (body.comments-open, --mh),
//                   the sheet (#thread) slides up beneath it.
//
// Moves follow the finger 1:1 (requestAnimationFrame, translate3d and scale only), then a spring settles them
// (stiffness 320, damping 32, mass 1). Everything goes through window.__galleryViewer, whose onShow is the one
// active item every surface follows. Only the three playback controls are glass (.vglass); the rest are blue.
(() => {
  const V = window.__galleryViewer;
  const lb = document.getElementById("lb");
  if (!V || !lb) return;

  const SPRING = { k: 320, c: 32, m: 1 };
  const FRAMED = { scale: 0.82, radius: 24 };
  const el = (tag, cls, html) => {
    const e = document.createElement(tag);
    if (cls) e.className = cls;
    if (html != null) e.innerHTML = html;
    return e;
  };
  const btn = (cls, label, html) => {
    const b = el("button", cls, html);
    b.type = "button";
    b.setAttribute("aria-label", label);
    return b;
  };
  const ICON = {
    back: '<svg viewBox="0 0 24 24" width="22" height="22" aria-hidden="true"><path d="M15 5l-7 7 7 7" fill="none" stroke="currentColor" stroke-width="2.4" stroke-linecap="round" stroke-linejoin="round"/></svg>',
    more: '<svg viewBox="0 0 24 24" width="22" height="22" aria-hidden="true"><circle cx="5" cy="12" r="2" fill="currentColor"/><circle cx="12" cy="12" r="2" fill="currentColor"/><circle cx="19" cy="12" r="2" fill="currentColor"/></svg>',
    share: '<svg viewBox="0 0 24 24" width="22" height="22" aria-hidden="true"><path d="M12 15V3m0 0L8 7m4-4l4 4M5 11v9h14v-9" fill="none" stroke="currentColor" stroke-width="1.9" stroke-linecap="round" stroke-linejoin="round"/></svg>',
    fav: '<svg viewBox="0 0 24 24" width="22" height="22" aria-hidden="true"><path d="M12 20s-7-4.4-7-10a4 4 0 0 1 7-2.6A4 4 0 0 1 19 10c0 5.6-7 10-7 10z" fill="var(--fill,none)" stroke="currentColor" stroke-width="1.9" stroke-linejoin="round"/></svg>',
    info: '<svg viewBox="0 0 24 24" width="22" height="22" aria-hidden="true"><circle cx="12" cy="12" r="9" fill="none" stroke="currentColor" stroke-width="1.9"/><path d="M12 11v6M12 7.5v.5" stroke="currentColor" stroke-width="2.2" stroke-linecap="round"/></svg>',
    eq: '<svg viewBox="0 0 24 24" width="22" height="22" aria-hidden="true"><path d="M6 4v16M12 4v16M18 4v16" stroke="currentColor" stroke-width="1.6" stroke-linecap="round"/><rect x="4" y="13" width="4" height="3" rx="1" fill="currentColor"/><rect x="10" y="7" width="4" height="3" rx="1" fill="currentColor"/><rect x="16" y="11" width="4" height="3" rx="1" fill="currentColor"/></svg>',
    del: '<svg viewBox="0 0 24 24" width="22" height="22" aria-hidden="true"><path d="M5 7h14M10 7V5h4v2M7 7l1 13h8l1-13" fill="none" stroke="currentColor" stroke-width="1.9" stroke-linecap="round" stroke-linejoin="round"/></svg>',
    rew: '<svg viewBox="0 0 24 24" width="24" height="24" aria-hidden="true"><path d="M11 6L4 12l7 6zM20 6l-7 6 7 6z" fill="currentColor"/></svg>',
    fwd: '<svg viewBox="0 0 24 24" width="24" height="24" aria-hidden="true"><path d="M13 6l7 6-7 6zM4 6l7 6-7 6z" fill="currentColor"/></svg>',
    play: '<svg viewBox="0 0 24 24" width="24" height="24" aria-hidden="true"><path d="M8 5l11 7-11 7z" fill="currentColor"/></svg>',
    pause: '<svg viewBox="0 0 24 24" width="24" height="24" aria-hidden="true"><path d="M7 5h4v14H7zM13 5h4v14h-4z" fill="currentColor"/></svg>',
  };

  lb.dataset.shell = "1";

  // ---------- the spring: one value per state axis, all written in one frame ----------
  // f = how framed (0 = A, 1 = B), y = the media's vertical offset while it is dragged
  const S = { f: { x: 1, v: 0, to: 1 }, y: { x: 0, v: 0, to: 0 } };
  let raf = 0;
  let last = 0;
  let held = false; // a finger has the stage: it moves 1:1, the spring waits
  const paint = () => {
    const f = S.f.x;
    lb.style.setProperty("--vs", String(1 - (1 - FRAMED.scale) * f));
    lb.style.setProperty("--vr", (FRAMED.radius * f).toFixed(2) + "px");
    lb.style.setProperty("--vc", String(Math.max(0, Math.min(1, f))));
    lb.style.setProperty("--vy", S.y.x.toFixed(2) + "px");
  };
  const step = (t) => {
    const dt = Math.min(0.032, last ? (t - last) / 1000 : 0.016);
    last = t;
    let moving = false;
    for (const a of Object.values(S)) {
      if (held && a === S.y) continue;
      const acc = (-SPRING.k * (a.x - a.to) - SPRING.c * a.v) / SPRING.m;
      a.v += acc * dt;
      a.x += a.v * dt;
      if (Math.abs(a.x - a.to) < 1e-3 && Math.abs(a.v) < 1e-3) {
        a.x = a.to;
        a.v = 0;
      } else moving = true;
    }
    paint();
    raf = moving || held ? requestAnimationFrame(step) : 0;
    if (!raf) last = 0;
  };
  const kick = () => raf || (raf = requestAnimationFrame(step));

  const stateOf = () => (V.isOpen() ? "C" : S.f.to >= 0.5 ? "B" : "A");
  const setState = (st) => {
    if (st === "C") {
      V.setOpen(true);
      if (!V.isOpen()) st = "B"; // nothing to show or write: stays framed
    } else if (V.isOpen()) V.setOpen(false);
    S.f.to = st === "A" ? 0 : 1;
    S.y.to = 0;
    lb.dataset.vstate = st;
    kick();
  };
  window.__galleryShell = { state: stateOf, setState, spring: SPRING, framed: FRAMED };
  // closing the sheet any other way (Hide Comments, Delete, Cancel) lands on B
  new MutationObserver(() => {
    const st = V.isOpen() ? "C" : S.f.to >= 0.5 ? "B" : "A";
    if (lb.dataset.vstate !== st) lb.dataset.vstate = st;
  }).observe(document.body, { attributes: true, attributeFilter: ["class"] });

  // ---------- top bar: "<" · folder over date • time · "•••" ----------
  const top = lb.querySelector(".top");
  const ttl = lb.querySelector(".ttl");
  const back = btn("vback", "Back", ICON.back);
  back.onclick = () => history.back();
  const fold = el("b", "vfold");
  ttl.prepend(fold);
  const more = btn("vmore", "More", ICON.more);
  top.prepend(back);
  top.append(more);

  const menu = el("div", "vmenu");
  menu.hidden = true;
  menu.setAttribute("role", "menu");
  lb.append(menu);
  const row = (label, fn) => {
    const b = el("button", "lnk vrow");
    b.type = "button";
    b.setAttribute("role", "menuitem");
    b.textContent = label;
    b.onclick = () => {
      menu.hidden = true;
      fn();
    };
    menu.append(b);
  };
  // a click views or plays; the file itself is only ever reached on purpose
  more.onclick = (e) => {
    e.stopPropagation();
    if (!menu.hidden) return (menu.hidden = true);
    const f = V.item();
    if (!f) return;
    menu.replaceChildren();
    row("Go to File", () => window.open(V.src(f), "_blank", "noopener"));
    if (V.canDownload()) row("Download", () => (location.href = V.src(f) + (V.src(f).includes("?") ? "&" : "?") + "dl=1"));
    row(V.isOpen() ? "Hide Info" : "Info", () => setState(V.isOpen() ? "B" : "C"));
    menu.hidden = false;
  };
  document.addEventListener("pointerdown", (e) => !menu.hidden && !menu.contains(e.target) && e.target !== more && (menu.hidden = true));

  // ---------- bottom: scrubber · filmstrip · capsule ----------
  const bot = lb.querySelector(".bot");
  const scrub = el("div", "vscrub");
  scrub.innerHTML = '<div class="vrail"><div class="vfill"></div><div class="vthumb"></div></div><div class="vpills" hidden></div>';
  const rail = scrub.querySelector(".vrail");
  const fill = scrub.querySelector(".vfill");
  const thumb = scrub.querySelector(".vthumb");
  const pills = scrub.querySelector(".vpills");
  bot.prepend(scrub);

  const cap = el("div", "vcap");
  const share = btn("lnk vic vshare2", "Share", ICON.share);
  const fav = btn("lnk vic vfav", "Favorite", ICON.fav);
  const trio = el("div", "vtrio");
  const rew = btn("vglass vrew", "Back 10 seconds", ICON.rew);
  const pp = btn("vglass vpp", "Play", ICON.play);
  const fwd = btn("vglass vfwd", "Forward 10 seconds", ICON.fwd);
  trio.append(rew, pp, fwd);
  const info = btn("lnk vic vinfo", "Info and transcript", ICON.info);
  const eq = btn("lnk vic veq", "Audio and EQ", ICON.eq);
  const pillL = el("div", "vpill");
  const pillR = el("div", "vpill");
  pillL.append(share, fav);
  pillR.append(info, eq);
  const del = btn("lnk vic vdel", "Delete", ICON.del);
  cap.append(pillL, trio, pillR, del);
  bot.append(cap);

  share.onclick = () => V.share();
  fav.onclick = async () => {
    fav.disabled = true;
    try {
      await V.like();
    } catch (e) {}
    fav.disabled = false;
    paintCap();
  };
  info.onclick = () => setState(V.isOpen() ? "B" : "C");
  eq.onclick = () => {
    const b = lb.querySelector(".p-eqbtn");
    if (b) b.click();
  };
  del.onclick = () => V.del();
  const media = () => V.media();
  const seekBy = (d) => {
    const m = media();
    if (m && Number.isFinite(m.duration)) m.currentTime = Math.max(0, Math.min(m.duration, m.currentTime + d));
  };
  rew.onclick = () => seekBy(-10);
  fwd.onclick = () => seekBy(10);
  pp.onclick = () => {
    V.toggle();
    setTimeout(paintPlay, 50);
  };
  const paintPlay = () => {
    const m = media();
    const on = !!(m && !m.paused);
    if (pp.dataset.on === String(on)) return;
    pp.dataset.on = String(on);
    pp.innerHTML = on ? ICON.pause : ICON.play;
    pp.setAttribute("aria-label", on ? "Pause" : "Play");
  };
  const paintCap = () => {
    const f = V.item();
    const av = !!f && !f.pending && ["aud", "vid"].includes(V.kind(f));
    lb.classList.toggle("vav", av);
    scrub.hidden = !av;
    trio.hidden = !av;
    eq.hidden = !av;
    share.hidden = !V.canShare();
    fav.hidden = !V.canLike();
    fav.classList.toggle("on", V.liked());
    fav.setAttribute("aria-pressed", String(V.liked()));
    del.hidden = !V.canDelete();
    paintPlay();
  };

  // ---------- the 2D scrubber ----------
  // dx scrubs the timeline (coarse: the rail is the whole track). Drag up past a step: fine, a word at a time,
  // the words showing as pills over the thumb; back down: coarse again. The rail keeps the pointer
  // (setPointerCapture, touch-action: none), so drifting up or down never moves the sheet or the stage.
  let words = [];
  let wordsFor = null;
  const loadWords = async (f) => {
    wordsFor = f;
    words = [];
    const ls = await V.lines(f);
    if (wordsFor !== f) return;
    for (const l of ls) for (const w of l.words || []) if (Number.isFinite(w.s)) words.push({ t: String(w.t || w.w || ""), s: w.s, e: w.e });
    if (!words.length) for (const l of ls) if (Number.isFinite(l.s)) words.push({ t: String(l.text || l.t || ""), s: l.s, e: l.e });
  };
  const paintRail = () => {
    const m = media();
    const p = m && m.duration ? m.currentTime / m.duration : 0;
    fill.style.transform = `scaleX(${p})`;
    thumb.style.transform = `translate3d(${(p * rail.clientWidth).toFixed(1)}px,0,0)`;
  };
  const wordAt = (t) => {
    let best = -1;
    for (let i = 0; i < words.length; i++) if (words[i].s <= t + 1e-3) best = i;
    return best;
  };
  const showPills = (t) => {
    const i = Math.max(0, wordAt(t));
    pills.replaceChildren(
      ...words.slice(Math.max(0, i - 2), i + 3).map((w) => {
        const b = el("span", "vword" + (w === words[i] ? " on" : ""));
        b.textContent = w.t;
        return b;
      })
    );
    pills.style.transform = `translate3d(${thumb.style.transform.match(/[-\d.]+/)?.[0] || 0}px,0,0)`;
  };
  let sc = null;
  rail.addEventListener("pointerdown", (e) => {
    const m = media();
    if (!m || !Number.isFinite(m.duration) || !m.duration) return;
    e.preventDefault();
    e.stopPropagation();
    try {
      rail.setPointerCapture(e.pointerId);
    } catch (x) {}
    const r = rail.getBoundingClientRect();
    const t = ((e.clientX - r.left) / r.width) * m.duration;
    m.currentTime = Math.max(0, Math.min(m.duration, t));
    sc = { id: e.pointerId, x: e.clientX, y0: e.clientY, t: m.currentTime, fine: false, w: r.width };
    scrub.classList.add("held");
    paintRail();
  });
  rail.addEventListener("pointermove", (e) => {
    if (!sc || e.pointerId !== sc.id) return;
    e.stopPropagation();
    const m = media();
    const up = sc.y0 - e.clientY;
    const fine = up > 28; // up: fine; back down below the step: coarse
    if (fine !== sc.fine) {
      sc.fine = fine;
      sc.x = e.clientX;
      sc.t = m.currentTime;
      scrub.classList.toggle("fine", fine);
      pills.hidden = !fine || !words.length;
    }
    const dx = e.clientX - sc.x;
    let t;
    if (fine && words.length) {
      // a word per 24px, from the word under the thumb when fine began
      const i0 = Math.max(0, wordAt(sc.t));
      const i = Math.max(0, Math.min(words.length - 1, i0 + Math.round(dx / 24)));
      t = words[i].s;
    } else {
      t = sc.t + (dx / sc.w) * m.duration * (fine ? 0.1 : 1);
    }
    m.currentTime = Math.max(0, Math.min(m.duration, t));
    paintRail();
    if (fine && words.length) showPills(m.currentTime);
  });
  const endScrub = (e) => {
    if (!sc || e.pointerId !== sc.id) return;
    sc = null;
    scrub.classList.remove("held", "fine");
    pills.hidden = true;
  };
  rail.addEventListener("pointerup", endScrub);
  rail.addEventListener("pointercancel", endScrub);
  // the rail's touches are its own: not a swipe of the stage, not a pull of the sheet
  for (const t of ["touchstart", "touchmove", "touchend"]) scrub.addEventListener(t, (e) => e.stopPropagation(), { passive: true });

  let tick = 0;
  // the element lives in a shadow root, whose events never reach the document: read it five times a second
  // (a drag on the rail paints at once, on its own)
  const follow = () => {
    if (lb.hidden) return stopFollow();
    if (!sc) paintRail();
    paintPlay();
  };
  const stopFollow = () => {
    clearInterval(tick);
    tick = 0;
  };

  // ---------- the stage: tap A ⇄ B, drag up toward C (1:1), down from C to B ----------
  const stage = document.getElementById("stage");
  // the media itself (a picture, a video, a cover): never the lyrics, the transcript editor or a control laid over it
  const onMedia = (t) =>
    t.matches && t.matches("#stage > img, #stage .aw > img, #stage .mbox, #stage .peek, #stage .pw, #stage .pw *, #stage .dv, #stage .dv *") &&
    !t.closest(".p-hb, .p-ctrl, .p-eq, .p-eqwrap, .tx, .txall, .pdfv, button, a, input, textarea");
  let g = null;
  stage.addEventListener("pointerdown", (e) => {
    if (!e.isPrimary || e.button > 0 || !onMedia(e.target)) return;
    g = { id: e.pointerId, x: e.clientX, y: e.clientY, t: e.timeStamp, dy: 0, type: e.pointerType, vy: 0, ly: e.clientY, lt: e.timeStamp };
  });
  stage.addEventListener("pointermove", (e) => {
    if (!g || e.pointerId !== g.id) return;
    const dx = e.clientX - g.x;
    const dy = e.clientY - g.y;
    if (!g.drag && Math.abs(dy) > 10 && Math.abs(dy) > Math.abs(dx) * 1.5) g.drag = true;
    if (!g.drag) return;
    const dt = Math.max(1, e.timeStamp - g.lt);
    g.vy = (e.clientY - g.ly) / dt;
    g.ly = e.clientY;
    g.lt = e.timeStamp;
    held = true;
    // up from B, or down from C: the media follows the finger (rubber band the other way)
    const open = V.isOpen();
    S.y.x = (open ? dy > 0 : dy < 0) ? dy : dy * 0.2;
    S.y.v = 0;
    g.dy = dy;
    kick();
  });
  const release = (e) => {
    if (!g || e.pointerId !== g.id) return;
    const tap = !g.drag && e.timeStamp - g.t < 350 && Math.hypot(e.clientX - g.x, e.clientY - g.y) < 8;
    const dy = g.dy;
    const fling = g.vy;
    const type = g.type;
    g = null;
    held = false;
    if (tap) {
      if (!V.isOpen()) setState(stateOf() === "A" ? "B" : "A");
      return;
    }
    if (!dy) return;
    S.y.to = 0;
    S.y.v = fling * 1000;
    // a finger's swipe is committed by the viewer's own touch handler (gallery.js); a mouse or pen commits here
    if (type !== "touch") {
      if (!V.isOpen() && (dy < -60 || fling < -0.5)) setState("C");
      else if (V.isOpen() && (dy > 60 || fling > 0.5)) setState("B");
    }
    kick();
  };
  stage.addEventListener("pointerup", release);
  stage.addEventListener("pointercancel", release);

  // ---------- every surface follows the one active item ----------
  V.onShow((f) => {
    menu.hidden = true;
    if (!f) {
      stopFollow();
      S.f.x = S.f.to = 1;
      S.y.x = S.y.to = 0;
      paint();
      delete lb.dataset.vstate;
      return;
    }
    fold.textContent = V.folder();
    if (!lb.dataset.vstate) setState("B");
    else lb.dataset.vstate = stateOf();
    paintCap();
    if (["aud", "vid"].includes(V.kind(f))) loadWords(f);
    if (!tick) tick = setInterval(follow, 200);
    // the active thumbnail, centred
    const on = document.querySelector("#strip .th.on");
    if (on) on.scrollIntoView({ block: "nearest", inline: "center" });
  });
  paint();
})();
