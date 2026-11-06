// The viewer shell (G3): the framing states of the viewer, over gallery.js's viewer.
//
//   A  Full-bleed   tap the media from B. Media 100%, radius 0, the chrome faded out.
//   B  Framed       the default; tap from A, or swipe down from C. Media scale .82, radius 24px, black around.
//   C  Docked       swipe up, or Info / Add a comment. The media docks above the sheet (body.comments-open).
//
// The top bar, the filmstrip, the Info / comment / Share row and the home bar are the viewer's own (gallery.js,
// homebar.js): this file does not draw them. Moves follow the finger 1:1 (requestAnimationFrame, translate3d and
// scale only), then a spring settles them (stiffness 320, damping 32, mass 1). Everything goes through
// window.__galleryViewer, whose onShow is the one active item every surface follows.
(() => {
  const V = window.__galleryViewer;
  const lb = document.getElementById("lb");
  if (!V || !lb) return;

  const SPRING = { k: 320, c: 32, m: 1 };
  const FRAMED = { scale: 0.82, radius: 24 };

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
    if (!f) {
      S.f.x = S.f.to = 1;
      S.y.x = S.y.to = 0;
      paint();
      delete lb.dataset.vstate;
      return;
    }
    if (!lb.dataset.vstate) setState("B");
    else lb.dataset.vstate = stateOf();
    // the glow takes its colours from the item's own art
    const art = V.thumbOf(f);
    lb.style.setProperty("--vart", art ? 'url("' + art.replace(/"/g, "%22") + '")' : "none");
    lb.style.setProperty("--vglow", art ? "1" : "0");
  });
  paint();
})();
