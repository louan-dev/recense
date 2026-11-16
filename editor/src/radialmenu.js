// Derived from Spec: UI-04 P2 — radial menu opened by a held squeeze (P1).
// Geometry and hit-test are pure; the DOM part is a thin shell over them.
// Rings (CSS px = pt in the web view): deadzone < 28, inner ring (ink tools) 28..90 around radius 68,
// outer ring (`::` macros) 90..140 around radius 112. Release in the deadzone picks nothing.

export const RADIAL_DEADZONE = 28;
export const RADIAL_INNER_R = 68;
export const RADIAL_OUTER_R = 112;
// Ring bounds: halfway between the two ring radii, and as far past the outer ring as the inner ring's half-width.
export const RADIAL_SPLIT = (RADIAL_INNER_R + RADIAL_OUTER_R) / 2;   // 90
export const RADIAL_MAX = RADIAL_OUTER_R + (RADIAL_SPLIT - RADIAL_INNER_R) + 6;   // 140

/**
 * Angle (radians) of item i of n on a ring, item 0 straight up, going clockwise (screen y grows down).
 */
export function radialItemAngle(i, n) {
  return -Math.PI / 2 + (2 * Math.PI * i) / Math.max(1, n);
}

/** Centre of item i of n on a ring of radius r, relative to the menu centre. */
export function radialItemPos(i, n, r) {
  const a = radialItemAngle(i, n);
  return { x: r * Math.cos(a), y: r * Math.sin(a) };
}

/**
 * Which item is under (dx, dy) from the menu centre.
 * inner, outer: item counts. Returns { ring: 'inner' | 'outer', index } or null (deadzone, empty ring, too far).
 */
export function radialHitTest(dx, dy, inner, outer = 0) {
  const d = Math.hypot(dx, dy);
  if (!(d >= RADIAL_DEADZONE) || d > RADIAL_MAX) return null;
  const ring = d < RADIAL_SPLIT ? 'inner' : 'outer';
  const n = ring === 'inner' ? inner : outer;
  if (!n) return null;
  // Angle measured clockwise from straight up, in [0, 2π).
  let a = Math.atan2(dy, dx) + Math.PI / 2;
  a = ((a % (2 * Math.PI)) + 2 * Math.PI) % (2 * Math.PI);
  const sector = (2 * Math.PI) / n;
  const index = Math.floor((a + sector / 2) / sector) % n;
  return { ring, index };
}

/**
 * Where the menu centres for a requested point: inside the viewport by the menu's reach, and the viewport's centre
 * when the host had no hover point (the Pencil out of range sends 0, 0). Pure.
 */
export function radialCentre(x, y, vw, vh, reach = RADIAL_MAX) {
  if (!(vw > 0) || !(vh > 0)) return [x, y];
  if (x === 0 && y === 0) return [vw / 2, vh / 2];
  const clamp = (v, lo, hi) => (lo > hi ? (lo + hi) / 2 : Math.max(lo, Math.min(hi, v)));
  return [clamp(x, reach, vw - reach), clamp(y, reach, vh - reach)];
}

/**
 * The DOM menu. items: { inner: [{ id, label, icon }], outer: [...] }; onPick(item, ring).
 * Returns { open(x, y), move(x, y), release(x, y), close(), isOpen() } — the shape `squeezeHost` expects.
 * x, y are viewport (client) coordinates; the menu is fixed-positioned.
 */
export function createRadialMenu({ doc, mount, items, onPick = () => {}, reduceMotion = () => false, viewport = () => null } = {}) {
  let el = null;
  let cx = 0, cy = 0;
  let open = false;
  let hot = null;
  const nodes = { inner: [], outer: [] };
  const list = () => ({ inner: items?.inner || [], outer: items?.outer || [] });

  function build() {
    if (el || !doc || typeof doc.createElement !== 'function') return;
    el = doc.createElement('div');
    el.className = 'rc-radial';
    el.setAttribute('role', 'menu');
    el.setAttribute('aria-label', 'Tools');
    el.hidden = true;
    const host = mount || doc.body;
    if (host && typeof host.appendChild === 'function') host.appendChild(el);
  }

  function fill() {
    el.innerHTML = '';
    nodes.inner = []; nodes.outer = [];
    const all = list();
    for (const ring of ['inner', 'outer']) {
      const r = ring === 'inner' ? RADIAL_INNER_R : RADIAL_OUTER_R;
      all[ring].forEach((it, i) => {
        const b = doc.createElement('div');
        b.className = `rc-radial-item rc-radial-${ring}`;
        b.setAttribute('role', 'menuitem');
        b.setAttribute('aria-label', it.label || it.id);
        b.setAttribute('data-id', it.id);
        const p = radialItemPos(i, all[ring].length, r);
        b.style.left = `${p.x}px`;
        b.style.top = `${p.y}px`;
        b.innerHTML = it.icon || '';
        if (!it.icon) b.textContent = it.label || it.id;
        el.appendChild(b);
        nodes[ring].push(b);
      });
    }
  }

  function setHot(h) {
    hot = h;
    for (const ring of ['inner', 'outer']) {
      nodes[ring].forEach((b, i) => {
        const on = Boolean(h && h.ring === ring && h.index === i);
        if (b.classList) b.classList.toggle('rc-hot', on);
      });
    }
  }

  function hitAt(x, y) {
    const all = list();
    return radialHitTest(x - cx, y - cy, all.inner.length, all.outer.length);
  }

  return {
    open(x, y) {
      build();
      const vp = viewport() || {};
      [cx, cy] = radialCentre(Number(x) || 0, Number(y) || 0, vp.w, vp.h);
      open = true;
      if (!el) return;
      fill();
      el.style.left = `${cx}px`;
      el.style.top = `${cy}px`;
      // Reduce Motion: the menu appears and closes without motion.
      if (el.classList) el.classList.toggle('rc-still', Boolean(reduceMotion()));
      // No `::` macros yet: the disc ends at the inner ring.
      if (el.classList) el.classList.toggle('rc-radial-inner-only', list().outer.length === 0);
      el.hidden = false;
      setHot(null);
    },
    move(x, y) {
      if (!open) return;
      setHot(hitAt(x, y));
    },
    release(x, y) {
      if (!open) return null;
      const h = Number.isFinite(Number(x)) ? hitAt(Number(x), Number(y)) : hot;
      this.close();
      if (!h) return null;
      const item = list()[h.ring][h.index];
      if (item) onPick(item, h.ring);
      return item || null;
    },
    close() {
      open = false;
      hot = null;
      if (el) el.hidden = true;
    },
    isOpen: () => open,
    element: () => el
  };
}
