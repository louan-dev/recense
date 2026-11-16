// Derived from Spec: UI-04 P6 — palm rejection for finger and trackpad.
// A pure gate: each pointer gets a state, and every event returns what the ink layer should do.
// The numbers are DEFAULTS (assumed, not measured on the owner's devices); tune them here.
export const TWO_FINGER_MS = 250;     // a second touch within this of the first's stroke start scrolls instead
export const PALM_CONTACT_PX = 50;    // contact width or height above this is a palm
export const TOUCH_SLOP_PX = 4;       // a touch must move this far…
export const REST_MS = 300;           // …within this long of landing, or it is a resting palm/thumb
export const MIN_STROKE_PX = 3;       // touch and mouse strokes smaller than this are dropped
export const BRUSH_MS = 60;           // a mouse stroke shorter than this…
export const BRUSH_PX = 8;            // …and smaller than this is an accidental trackpad brush
export const EDGE_BOTTOM_PX = 34;     // home-indicator band
export const PEN_GRACE_MS = 30000;    // after the Pencil's last event, one finger scrolls instead of inking

const now = e => (typeof e.timeStamp === 'number' && e.timeStamp > 0 ? e.timeStamp : Date.now());
const isPalmSized = e => (Number(e.width) || 0) > PALM_CONTACT_PX || (Number(e.height) || 0) > PALM_CONTACT_PX;

/** True when every point lies within `px` of the first: a tap, not a stroke. */
export function isTinyStroke(points, px = MIN_STROKE_PX) {
  if (!Array.isArray(points) || points.length === 0) return true;
  const [x0, y0] = points[0];
  return !points.some(p => Math.hypot(p[0] - x0, p[1] - y0) >= px);
}

/** True when a mouse/trackpad stroke is a brush: very short in time and small in size. */
export function isBrush(points, upTime) {
  if (!Array.isArray(points) || points.length === 0) return true;
  const dt = (upTime ?? points[points.length - 1][3]) - points[0][3];
  return dt < BRUSH_MS && isTinyStroke(points, BRUSH_PX);
}

/**
 * viewport() → { w, h } in CSS px, for the system-edge bands.
 * Returns { down, move, up, cancel }; each takes a pointer event and returns
 * { act: 'ink' | 'wait' | 'start' | 'scroll' | 'ignore', dx?, dy?, cancel? }.
 *   ink    — draw with this pointer (mouse, pen, or a touch already drawing)
 *   wait   — a touch on probation: buffer its points, draw nothing yet
 *   start  — the waiting touch moved: draw it from where it landed
 *   scroll — move the page by (dx, dy)
 *   cancel — drop the stroke being drawn now
 */
export function createPalmGate({ viewport = () => ({ w: Infinity, h: Infinity }) } = {}) {
  const touches = new Map();   // pointerId → { x, y, t, state, inkAt }
  let penDown = false;
  let lastPenAt = -Infinity;

  const idOf = e => (e.pointerId === undefined ? 'touch' : e.pointerId);
  const counting = () => [...touches.values()].filter(t => t.state !== 'ignore');

  function inEdge(e) {
    const { h } = viewport() || {};
    const y = Number(e.clientY) || 0;
    // Only the bottom: Draftpad's web view enables no back-swipe, so the side edges are page margin.
    return h > 0 && y > h - EDGE_BOTTOM_PX;
  }

  function down(e) {
    const t = now(e);
    if (e.pointerType === 'pen') {
      penDown = true;
      lastPenAt = t;
      const inking = [...touches.values()].some(s => s.state === 'ink' || s.state === 'wait');
      for (const s of touches.values()) s.state = 'ignore';
      return { act: 'ink', cancel: inking };
    }
    if (e.pointerType !== 'touch') return { act: 'ink' };

    const id = idOf(e);
    const x0 = Number(e.clientX) || 0, y0 = Number(e.clientY) || 0;
    const rec = { x0, y0, x: x0, y: y0, t, state: 'ignore', inkAt: null };
    touches.set(id, rec);

    // A waiting touch that never moved within REST_MS is a resting palm: it doesn't count toward two.
    for (const s of touches.values()) if (s !== rec && s.state === 'wait' && t - s.t > REST_MS) s.state = 'ignore';

    if (penDown || isPalmSized(e) || inEdge(e)) return { act: 'ignore' };

    const others = counting().filter(s => s !== rec);
    if (others.some(s => s.state === 'scroll')) return { act: 'ignore' };
    if (others.length > 0) {
      const first = others[0];
      const young = first.state === 'wait' || first.state === 'pan'
        || (first.state === 'ink' && t - first.inkAt < TWO_FINGER_MS);
      if (!young) return { act: 'ignore' };   // a palm landing mid-stroke
      const cancel = first.state === 'ink' || first.state === 'wait';
      first.state = 'scroll';
      rec.state = 'scroll';
      return { act: 'scroll', dx: 0, dy: 0, cancel };
    }
    if (t - lastPenAt < PEN_GRACE_MS) { rec.state = 'pan'; return { act: 'scroll', dx: 0, dy: 0 }; }
    rec.state = 'wait';
    return { act: 'wait' };
  }

  function move(e) {
    if (e.pointerType === 'pen') { lastPenAt = now(e); return { act: 'ink' }; }
    if (e.pointerType !== 'touch') return { act: 'ink' };
    const rec = touches.get(idOf(e));
    if (!rec) return { act: 'ignore' };
    const x = Number(e.clientX) || 0, y = Number(e.clientY) || 0, t = now(e);
    const dx = x - rec.x, dy = y - rec.y;
    rec.x = x; rec.y = y;
    switch (rec.state) {
      case 'wait': {
        if (isPalmSized(e) || t - rec.t > REST_MS) { rec.state = 'ignore'; return { act: 'ignore', cancel: true }; }
        if (Math.hypot(x - rec.x0, y - rec.y0) < TOUCH_SLOP_PX) return { act: 'wait' };
        rec.state = 'ink';
        rec.inkAt = t;
        return { act: 'start' };
      }
      case 'ink': return { act: 'ink' };
      case 'pan': return { act: 'scroll', dx, dy };
      case 'scroll': {
        const n = [...touches.values()].filter(s => s.state === 'scroll').length || 1;
        return { act: 'scroll', dx: dx / n, dy: dy / n };   // the pair's centroid moves by the mean
      }
      default: return { act: 'ignore' };
    }
  }

  function up(e) {
    if (e.pointerType === 'pen') {
      penDown = false;
      lastPenAt = now(e);
      return { act: 'ink' };
    }
    if (e.pointerType !== 'touch') return { act: 'ink' };
    const id = idOf(e);
    const rec = touches.get(id);
    touches.delete(id);
    if (!rec) return { act: 'ignore' };
    // One finger of a scrolling pair lifted: the other only scrolls on, never inks.
    if (rec.state === 'scroll') for (const s of touches.values()) if (s.state === 'scroll') s.state = 'ignore';
    if (rec.state === 'ink') return { act: 'ink' };
    if (rec.state === 'wait') return { act: 'ignore', cancel: true };
    return { act: 'ignore' };
  }

  const cancel = up;
  return { down, move, up, cancel, state: id => touches.get(id)?.state };
}
